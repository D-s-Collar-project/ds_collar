--[[--------------------
MODULE: collar_kernel.lua  (SLua port)
VERSION: 1.10
REVISION: 7  (SLua port rev 1)
PURPOSE: Plugin registry, lifecycle management, heartbeat monitoring
ARCHITECTURE: Consolidated message bus lanes

SLUA PORT NOTES:
- Ported from collar_kernel.lsl rev 7. Behaviour and the KERNEL_LIFECYCLE
  (500) wire protocol are preserved exactly so this kernel interoperates
  with not-yet-ported LSL plugins on the same link set. All link_message
  payloads remain JSON strings built/parsed via ll.List2Json / ll.JsonGetValue.
- The LSL original kept three parallel stride-lists (PluginRegistry,
  PluginContexts, PluginScripts) plus manual backward in-place deletes
  to avoid O(N^2) heap churn under Mono — the whole point of LSL rev 7.
  SLua has real tables, so the registry and the registration queue are
  now plain maps keyed by context: O(1) find/upsert/remove, no strides,
  no index arithmetic, no allocation-pressure contortions.
- Events are top-level global functions (SLua has no states / no default{}).
  state_entry is not a real event here; it is a normal function invoked
  once at the bottom of the script.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500

--[[ -------------------- CONSTANTS -------------------- ]]
local PING_INTERVAL_SEC     = 10.0
local PING_TIMEOUT_SEC      = 30
local INV_SWEEP_INTERVAL    = 3.0
local BATCH_WINDOW_SEC      = 0.1   -- small batch window during startup burst
local DISCOVERY_INTERVAL_SEC = 5.0  -- active plugin discovery interval

--[[ -------------------- STATE -------------------- ]]
-- Registry: context -> { label, script, uuid, last_seen }
local Registry = {}
-- Pending operations queue: context -> { op = "REG"|"UNREG", label, script, ts }
-- Keyed by context so a later op for the same context replaces the earlier
-- one automatically (the LSL version deduplicated by hand).
local Queue = {}
-- Set of script UUIDs (as strings) seen on the last discovery pass.
local KnownUUIDs = {}

local PendingBatchTimer = false
local LastPingUnix = 0
local LastInvSweepUnix = 0
local LastDiscoveryUnix = 0
local LastOwner = NULL_KEY
local LastScriptCount = 0
local LastRegionCrossUnix = 0

--[[ -------------------- HELPERS -------------------- ]]

local function get_msg_type(msg: string): string
    local t = ll.JsonGetValue(msg, {"type"})
    if t == JSON_INVALID then return "" end
    return t
end

local function now(): number
    return ll.GetUnixTime()
end

local function count_scripts(): number
    return ll.GetInventoryNumber(INVENTORY_SCRIPT)
end

--[[ -------------------- TIMER SHIM (LSL single-timer over SLua LLTimers) -------------------- ]]
-- SLua has no ll.SetTimerEvent and no manually-managed timer event. LLTimers
-- runs multiple independent timers via callbacks. This shim reproduces the LSL
-- single-timer contract: set_timer(t>0) starts/replaces the one recurring timer;
-- set_timer(0) stops it. The old timer() body lives in _on_timer (assigned below
-- where LLEvents.timer used to be).
local _timerHandle = nil
local _on_timer  -- forward declaration; assigned further down
local function set_timer(interval: number)
    if _timerHandle then
        LLTimers:off(_timerHandle)
        _timerHandle = nil
    end
    if interval > 0 then
        _timerHandle = LLTimers:every(interval, _on_timer)
    end
end

--[[ -------------------- BROADCASTING -------------------- ]]

-- Request all plugins to register (no time window - event-driven).
local function broadcast_register_now()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE,
        ll.List2Json(JSON_OBJECT, {"type", "kernel.register.refresh"}), NULL_KEY)
end

-- Heartbeat ping to all plugins.
local function broadcast_ping()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE,
        ll.List2Json(JSON_OBJECT, {"type", "kernel.ping"}), NULL_KEY)
end

--[[ -------------------- REGISTRY MANAGEMENT -------------------- ]]

-- Add or update a plugin in the registry.
-- Returns true if newly added OR the script UUID changed (recompiled/updated),
-- false when re-registering with an identical UUID. The UUID check is the only
-- way to detect a script being recompiled or replaced in inventory.
local function registry_upsert(context: string, label: string, script: string): boolean
    local script_uuid = ll.GetInventoryKey(script)
    local rec = Registry[context]
    if rec == nil then
        Registry[context] = { label = label, script = script, uuid = script_uuid, last_seen = now() }
        return true
    end
    local uuid_changed = (rec.uuid ~= script_uuid)
    rec.label = label
    rec.script = script
    rec.uuid = script_uuid
    rec.last_seen = now()
    return uuid_changed
end

-- Remove a plugin. Returns true if it existed.
local function registry_remove(context: string): boolean
    if Registry[context] == nil then return false end
    Registry[context] = nil
    return true
end

-- Refresh the last_seen timestamp for a plugin (no-op if unknown).
local function update_last_seen(context: string)
    local rec = Registry[context]
    if rec then rec.last_seen = now() end
end

-- Remove plugins that have not answered a ping within PING_TIMEOUT_SEC.
local function prune_dead_plugins(): number
    local now_unix = ll.GetUnixTime()

    -- Skip pruning during the region-crossing grace window.
    if LastRegionCrossUnix > 0 and (now_unix - LastRegionCrossUnix) < PING_TIMEOUT_SEC then
        return 0
    end
    LastRegionCrossUnix = 0

    local cutoff = now_unix - PING_TIMEOUT_SEC
    local pruned = 0
    -- Clearing the current key during pairs() iteration is well-defined in Lua.
    for ctx, rec in pairs(Registry) do
        if rec.last_seen < cutoff then
            Registry[ctx] = nil
            pruned += 1
        end
    end
    return pruned
end

-- Remove plugins whose scripts are gone from inventory, and sweep orphaned
-- plugin.reg.<ctx> / acl.policycontext:<ctx> LSD entries left behind by a
-- script that can no longer run its own cleanup.
local function prune_missing_scripts(): number
    local pruned = 0
    for ctx, rec in pairs(Registry) do
        if ll.GetInventoryType(rec.script) ~= INVENTORY_SCRIPT then
            Registry[ctx] = nil
            pruned += 1
        end
    end

    -- LSD sweep. kmod_ui's linkset_data handler picks up the deletions.
    local reg_keys = ll.LinksetDataFindKeys("^plugin\\.reg\\.", 1, -1)  -- SLua: start is 1-based
    for _, k in ipairs(reg_keys) do
        local entry = ll.LinksetDataRead(k)
        local scr = ll.JsonGetValue(entry, {"script"})
        if scr ~= JSON_INVALID and ll.GetInventoryType(scr) ~= INVENTORY_SCRIPT then
            local ctx = string.sub(k, 12)  -- strip "plugin.reg." (11 chars)
            ll.LinksetDataDelete(k)
            ll.LinksetDataDelete("acl.policycontext:" .. ctx)
        end
    end
    return pruned
end

--[[ -------------------- QUEUE (modprobe-style batch) -------------------- ]]

-- Enqueue an operation (deduplicated by context: newest wins) and arm the
-- short batch window so a startup burst of registrations is applied together.
local function queue_add(op_type: string, context: string, label: string, script: string)
    Queue[context] = { op = op_type, label = label, script = script, ts = now() }
    if not PendingBatchTimer then
        PendingBatchTimer = true
        set_timer(BATCH_WINDOW_SEC)
    end
end

-- Apply every queued operation atomically. Returns true if the registry
-- changed. Always returns the timer to heartbeat cadence afterwards.
local function process_queue(): boolean
    if next(Queue) == nil then
        if PendingBatchTimer then
            PendingBatchTimer = false
            set_timer(PING_INTERVAL_SEC)
        end
        return false
    end

    local changes_made = false
    for context, op in pairs(Queue) do
        if op.op == "REG" then
            if registry_upsert(context, op.label, op.script) then changes_made = true end
        elseif op.op == "UNREG" then
            if registry_remove(context) then changes_made = true end
        end
    end

    Queue = {}
    PendingBatchTimer = false
    set_timer(PING_INTERVAL_SEC)
    return changes_made
end

--[[ -------------------- PLUGIN DISCOVERY (pull-based) -------------------- ]]

-- Name-agnostic discovery: any script whose UUID we have not seen triggers a
-- register.refresh so plugins self-identify. Rebuilds the known-UUID set only
-- when something new appears (removals are handled by prune_missing_scripts).
local function discover_plugins(): boolean
    local inv_count = ll.GetInventoryNumber(INVENTORY_SCRIPT)
    local self_name = ll.GetScriptName()
    local current = {}
    local found_new = false

    for i = 1, inv_count do  -- SLua inventory is 1-based
        local name = ll.GetInventoryName(INVENTORY_SCRIPT, i)
        if name ~= self_name then
            local u = tostring(ll.GetInventoryKey(name))
            current[u] = true
            if not KnownUUIDs[u] then found_new = true end
        end
    end

    if found_new then
        KnownUUIDs = current
        broadcast_register_now()
    end
    return found_new
end

--[[ -------------------- OWNER CHANGE DETECTION -------------------- ]]

-- LSD sentinel carrying the owner at the last successful state_entry. Compared
-- on cold start to catch an inventory-transfer ownership change (CHANGED_OWNER
-- does not fire when the owner changes while the script is not running).
local KEY_LAST_OWNER = "safeguard.last_owner"

-- Wipe all LSD, tell plugins to clear in-memory state, and reset. Does not return.
local function do_owner_change_wipe()
    ll.LinksetDataReset()
    ll.LinksetDataWrite(KEY_LAST_OWNER, tostring(ll.GetOwner()))
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE,
        ll.List2Json(JSON_OBJECT, {"type", "kernel.reset.factory"}), NULL_KEY)
    ll.ResetScript()
end

local function check_owner_changed(): boolean
    local current_owner = ll.GetOwner()
    if current_owner == NULL_KEY then return false end

    if LastOwner ~= NULL_KEY and current_owner ~= LastOwner then
        LastOwner = current_owner
        do_owner_change_wipe()  -- resets; does not return
        return true
    end

    LastOwner = current_owner
    return false
end

--[[ -------------------- MESSAGE HANDLERS -------------------- ]]

local function handle_register(msg: string)
    local context = ll.JsonGetValue(msg, {"context"})
    if context == JSON_INVALID then return end
    local label = ll.JsonGetValue(msg, {"label"})
    if label == JSON_INVALID then return end
    local script = ll.JsonGetValue(msg, {"script"})
    if script == JSON_INVALID then return end
    queue_add("REG", context, label, script)
end

local function handle_pong(msg: string)
    local context = ll.JsonGetValue(msg, {"context"})
    if context == JSON_INVALID then return end
    update_last_seen(context)
end

local function handle_soft_reset()
    Registry = {}
    Queue = {}
    KnownUUIDs = {}
    PendingBatchTimer = false
    LastPingUnix = now()
    LastInvSweepUnix = now()
    LastDiscoveryUnix = now()
    set_timer(PING_INTERVAL_SEC)
    broadcast_register_now()
end

--[[ -------------------- EVENTS -------------------- ]]
-- In SLua these top-level global functions are the event handlers (no states).

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end

    -- Cold-start owner-change detection via the persistent LSD sentinel.
    local saved = ll.LinksetDataRead(KEY_LAST_OWNER)
    local current = tostring(ll.GetOwner())
    if saved == "" then
        ll.LinksetDataWrite(KEY_LAST_OWNER, current)
    elseif saved ~= current then
        do_owner_change_wipe()  -- resets; does not return
        return
    end

    LastOwner = ll.GetOwner()
    Registry = {}
    Queue = {}
    KnownUUIDs = {}
    PendingBatchTimer = false
    LastPingUnix = now()
    LastInvSweepUnix = now()
    LastDiscoveryUnix = now()
    LastScriptCount = count_scripts()

    broadcast_register_now()
    set_timer(PING_INTERVAL_SEC)
end

function LLEvents.on_rez(start_param: number)
    check_owner_changed()
end

function LLEvents.attach(id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    if id == NULL_KEY then return end
    check_owner_changed()
end

_on_timer = function()
    local t = ll.GetUnixTime()
    if t == 0 then return end  -- overflow protection

    if PendingBatchTimer then
        -- Batch mode: drain the registration queue (auto-returns to heartbeat).
        process_queue()
    else
        -- Heartbeat mode: periodic maintenance only.
        local ping_elapsed = t - LastPingUnix
        if ping_elapsed < 0 then ping_elapsed = 0 end
        if ping_elapsed >= PING_INTERVAL_SEC then
            broadcast_ping()
            prune_dead_plugins()
            LastPingUnix = t
        end

        local inv_elapsed = t - LastInvSweepUnix
        if inv_elapsed < 0 then inv_elapsed = 0 end
        if inv_elapsed >= INV_SWEEP_INTERVAL then
            prune_missing_scripts()
            LastInvSweepUnix = t
        end

        local discovery_elapsed = t - LastDiscoveryUnix
        if discovery_elapsed < 0 then discovery_elapsed = 0 end
        if discovery_elapsed >= DISCOVERY_INTERVAL_SEC then
            discover_plugins()
            LastDiscoveryUnix = t
        end
    end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    local msg_type = get_msg_type(msg)
    if msg_type == "" then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.register.declare" then
            handle_register(msg)
        elseif msg_type == "kernel.pong" then
            handle_pong(msg)
        elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            handle_soft_reset()
        end
    end
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        check_owner_changed()
    end

    if bit32.band(change, CHANGED_REGION) ~= 0 then
        -- Region crossing: link messages may drop. Defer pruning for one full
        -- timeout window; the registry and LSD-based menu presence both survive
        -- the crossing, so no re-registration broadcast is needed.
        LastRegionCrossUnix = ll.GetUnixTime()
        LastPingUnix = LastRegionCrossUnix
        LastInvSweepUnix = LastRegionCrossUnix
        LastDiscoveryUnix = LastRegionCrossUnix
    end

    if bit32.band(change, CHANGED_INVENTORY) ~= 0 then
        local current_script_count = count_scripts()
        if current_script_count ~= LastScriptCount then
            LastScriptCount = current_script_count
            Registry = {}
            Queue = {}
            KnownUUIDs = {}
            PendingBatchTimer = false
            set_timer(PING_INTERVAL_SEC)
            broadcast_register_now()
        end
    end
end

-- Top-level init: SLua runs this once at script start in place of state_entry.
main()

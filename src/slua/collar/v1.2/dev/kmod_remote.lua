--[[--------------------
MODULE: kmod_remote.lua  (SLua port)
VERSION: 1.2
REVISION: 6  (SLua port rev 1)
PURPOSE: External HUD communication bridge — answers remote ACL scans/queries,
         triggers menus for external users (ACL-gated), and runs the updater
         discovery/scan handshake for plugin_maint.
ARCHITECTURE: Consolidated message bus lanes, namespaced internal protocol.

SLUA PORT NOTES:
- Ported from kmod_remote.lsl v1.2 rev 6. External protocol preserved exactly:
  listens on the -8675309 (ACL/scan) and -8675311 (menu) HUD channels, replies on
  -8675310; consumes remote.updaterscan.start/confirm/cancel (REMOTE_BUS 600) and
  auth.acl.result (AUTH_BUS 700); emits auth.acl.query (AUTH_BUS), ui.menu.start
  (UI_BUS) and the remote.* external broadcasts. JSON shapes unchanged.
- IDIOMATIC: stride lists -> records/dicts. The two parallel wearer-keyed lists
  PendingQueries + QueryTimestamps merge into one array of {wearer, object, ts}
  records; PendingMenuRequests -> {wearer, context} records; the stride-3
  RateLimitTimestamps -> a dict keyed "wearer|type" -> ts. (The LSL's 120-entry
  size-cap prune is dropped: the dict dedups by key, the same growth profile as the
  LSL's replace-in-place update.)
- GOTCHA: jump labels. The AUTH_BUS handler's found_menu_request / not_menu_request
  jumps (the LSL no-break workaround) become a plain if/else on whether a pending
  menu request matched the avatar.
- GOTCHA: single dynamic timer. llSetTimerEvent(60/1) -> set_timer shim over LLTimers
  (60s prune cadence, tightened to 1s during an updater scan, restored on finalise).
- GOTCHA: no integer cast / wire fidelity. The random PIN is math.floor(ll.Frand(1e8)).
  Fields that travel as "1"/"0" (found / has_kernel / has_receiver) are converted with
  `and "1" or "0"` (KernelAlive stays a 0/1 number, never branched on, so tostring
  yields "1"/"0") — a bare Lua boolean would serialize as "true"/"false".
- vectors: ll.GetObjectDetails' position element is read natively (data[1]); range via
  ll.VecDist / ll.GetPos. uuid() normalizes JSON key strings; user notices go through
  ll.RegionSayTo (never OwnerSay).
- Single LSL state -> top-level LLEvents.*; state_entry becomes main().
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local REMOTE_BUS       = 600
local AUTH_BUS         = 700
local UI_BUS           = 900

--[[ -------------------- EXTERNAL PROTOCOL CHANNELS -------------------- ]]
local EXTERNAL_ACL_QUERY_CHAN = -8675309  -- listen for ACL queries/scans
local EXTERNAL_ACL_REPLY_CHAN = -8675310  -- send ACL responses
local EXTERNAL_MENU_CHAN      = -8675311  -- listen for menu requests

local MAX_DETECTION_RANGE = 20.0  -- meters

--[[ -------------------- PROTOCOL MESSAGE TYPES -------------------- ]]
local ROOT_CONTEXT = "ui.core.root"
local SOS_CONTEXT  = "ui.sos.root"

--[[ -------------------- STATE -------------------- ]]
local AclQueryListenHandle    = 0
local MenuRequestListenHandle = 0
local CollarOwner = NULL_KEY

-- Pending external ACL queries: {wearer, object, ts} (merges PendingQueries +
-- QueryTimestamps, both wearer-keyed in the LSL).
local PendingQueries: {{ wearer: any, object: any, ts: number }} = {}
local MAX_PENDING_QUERIES = 20
local QUERY_TIMEOUT = 30.0

-- Pending menu requests awaiting ACL verification: {wearer, context}.
local PendingMenuRequests: {{ wearer: any, context: string }} = {}

-- Kernel presence — 1 once any heartbeat/lifecycle message arrives (0/1 number,
-- never branched on, so it serializes as "1"/"0" on the wire).
local KernelAlive = 0

-- Updater scan state.
local UpdateScanActive    = false
local UpdateScanStart     = 0
local UpdateScanSession   = ""
local _UpdateScanRequester = NULL_KEY  -- write-only in the LSL too (vestigial state); kept for shape, _-prefixed to mark intentionally-unused
local UpdateScanWinner    = NULL_KEY
local UpdateScanWinnerVer = ""
local UPDATER_SCAN_TIMEOUT = 5.0

-- Per-(requester,type) rate limiting: "wearer|type" -> last ts.
local RateLimits: { [string]: number } = {}
local REQUEST_COOLDOWN = 2.0  -- seconds between requests per user per type

local REQUEST_TYPE_SCAN      = 1
local REQUEST_TYPE_ACL_QUERY = 2
local REQUEST_TYPE_MENU      = 3

--[[ -------------------- TIMER SHIM (single dynamic timer) -------------------- ]]
local _timerHandle = nil
local _on_timer  -- forward declaration
local function set_timer(interval: number)
    if _timerHandle then
        LLTimers:off(_timerHandle)
        _timerHandle = nil
    end
    if interval > 0 then
        _timerHandle = LLTimers:every(interval, _on_timer)
    end
end

--[[ -------------------- HELPERS -------------------- ]]

local function now(): number
    return ll.GetUnixTime()
end

local function csv_lead_int(s: string): number
    return tonumber(string.match(s, "^%s*(-?%d+)") or "") or 0
end

--[[ -------------------- RATE LIMITING (per-request-type) -------------------- ]]

local function check_rate_limit(requester, request_type: number): boolean
    local now_time = ll.GetUnixTime()
    local rk = tostring(requester) .. "|" .. tostring(request_type)
    local last = RateLimits[rk]
    if last ~= nil then
        if (now_time - last) < REQUEST_COOLDOWN then return false end
        RateLimits[rk] = now_time
        return true
    end
    RateLimits[rk] = now_time
    return true
end

--[[ -------------------- QUERY MANAGEMENT -------------------- ]]

local function find_pending_query(hud_wearer): number?
    for i, q in ipairs(PendingQueries) do
        if q.wearer == hud_wearer then return i end
    end
    return nil
end

local function remove_pending_query(hud_wearer)
    local idx = find_pending_query(hud_wearer)
    if idx ~= nil then table.remove(PendingQueries, idx) end
end

local function prune_expired_queries(now_time: number)
    for i = #PendingQueries, 1, -1 do
        if (now_time - PendingQueries[i].ts) > QUERY_TIMEOUT then
            table.remove(PendingQueries, i)
        end
    end
end

local function add_pending_query(hud_wearer, hud_object)
    local now_time = ll.GetUnixTime()

    local idx = find_pending_query(hud_wearer)
    if idx ~= nil then
        -- Update existing query's object key + timestamp.
        PendingQueries[idx].object = hud_object
        PendingQueries[idx].ts = now_time
        return
    end

    prune_expired_queries(now_time)

    if #PendingQueries >= MAX_PENDING_QUERIES then
        table.remove(PendingQueries, 1)  -- FIFO oldest
    end

    PendingQueries[#PendingQueries + 1] = { wearer = hud_wearer, object = hud_object, ts = now_time }
end

local function find_menu_request(hud_wearer): number?
    for i, m in ipairs(PendingMenuRequests) do
        if m.wearer == hud_wearer then return i end
    end
    return nil
end

--[[ -------------------- INTERNAL ACL COMMUNICATION -------------------- ]]

local function request_internal_acl(avatar_key)
    ll.MessageLinked(LINK_SET, AUTH_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "auth.acl.query",
        "avatar", tostring(avatar_key),
        "id", "remote_" .. tostring(avatar_key),
    }), NULL_KEY)
end

local function send_external_acl_response(hud_wearer, level: number)
    -- Region channel; the HUD filters by collar owner.
    ll.RegionSay(EXTERNAL_ACL_REPLY_CHAN, ll.List2Json(JSON_OBJECT, {
        "type", "auth.aclresultexternal",
        "avatar", tostring(hud_wearer),
        "level", tostring(level),
        "collar_owner", tostring(CollarOwner),
    }))
end

--[[ -------------------- MENU TRIGGERING -------------------- ]]

local function trigger_menu_for_external_user(user_key, context: string)
    -- The external user's key rides as the id parameter.
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.start",
        "context", context,
    }), user_key)
end

--[[ -------------------- EXTERNAL PROTOCOL HANDLERS -------------------- ]]

local function handle_collar_scan(message: string)
    if ll.JsonGetValue(message, {"hud_wearer"}) == JSON_INVALID then return end
    local hud_wearer = uuid(ll.JsonGetValue(message, {"hud_wearer"}))
    if hud_wearer == NULL_KEY then return end

    if not check_rate_limit(hud_wearer, REQUEST_TYPE_SCAN) then return end

    local agent_data = ll.GetObjectDetails(hud_wearer, {OBJECT_POS})
    if #agent_data == 0 then return end

    local distance = ll.VecDist(agent_data[1], ll.GetPos())
    if distance > MAX_DETECTION_RANGE then return end

    ll.RegionSay(EXTERNAL_ACL_REPLY_CHAN, ll.List2Json(JSON_OBJECT, {
        "type", "remote.collarscanresponse",
        "collar_owner", tostring(CollarOwner),
    }))
end

local function handle_acl_query_external(message: string)
    if ll.JsonGetValue(message, {"avatar"}) == JSON_INVALID then return end
    if ll.JsonGetValue(message, {"hud"}) == JSON_INVALID then return end
    if ll.JsonGetValue(message, {"target_avatar"}) == JSON_INVALID then return end

    local hud_wearer = uuid(ll.JsonGetValue(message, {"avatar"}))
    local hud_object = uuid(ll.JsonGetValue(message, {"hud"}))
    local target_avatar = uuid(ll.JsonGetValue(message, {"target_avatar"}))

    if hud_wearer == NULL_KEY then return end
    if hud_object == NULL_KEY then return end
    if target_avatar == NULL_KEY then return end

    -- If the HUD scoped the query to a specific collar prim, only that prim replies.
    local target_collar_str = ll.JsonGetValue(message, {"target_collar"})
    if target_collar_str ~= JSON_INVALID then
        if uuid(target_collar_str) ~= ll.GetKey() then return end
    end

    if not check_rate_limit(hud_wearer, REQUEST_TYPE_ACL_QUERY) then return end

    -- Only answer if the target matches our owner.
    if target_avatar ~= CollarOwner then return end

    add_pending_query(hud_wearer, hud_object)
    request_internal_acl(hud_wearer)
end

local function handle_menu_request_external(message: string)
    local hud_wearer_str = ll.JsonGetValue(message, {"avatar"})
    if hud_wearer_str == JSON_INVALID then return end
    local hud_wearer = uuid(hud_wearer_str)
    if hud_wearer == NULL_KEY then return end

    local context = ROOT_CONTEXT
    local tmp = ll.JsonGetValue(message, {"context"})
    if tmp ~= JSON_INVALID then context = tmp end

    if not check_rate_limit(hud_wearer, REQUEST_TYPE_MENU) then return end

    local agent_data = ll.GetObjectDetails(hud_wearer, {OBJECT_POS})
    if #agent_data == 0 then return end

    local distance = ll.VecDist(agent_data[1], ll.GetPos())
    if distance > MAX_DETECTION_RANGE then return end

    -- Already pending for this user?
    if find_menu_request(hud_wearer) ~= nil then return end

    -- ACL check before triggering the menu.
    PendingMenuRequests[#PendingMenuRequests + 1] = { wearer = hud_wearer, context = context }
    request_internal_acl(hud_wearer)
end

--[[ -------------------- UPDATE PROTOCOL HANDLERS -------------------- ]]

local function clear_scan_state()
    UpdateScanActive = false
    UpdateScanStart = 0
    UpdateScanSession = ""
    _UpdateScanRequester = NULL_KEY
    UpdateScanWinner = NULL_KEY
    UpdateScanWinnerVer = ""
end

-- Send the scan result to plugin_maint. Clears state when not found; keeps it on
-- found until plugin_maint confirms/cancels.
local function report_scan_result(found: boolean)
    ll.MessageLinked(LINK_SET, REMOTE_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "remote.updaterscan.result",
        "found", (found and "1" or "0"),
        "updater", tostring(UpdateScanWinner),
        "version", UpdateScanWinnerVer,
    }), NULL_KEY)

    if not found then clear_scan_state() end
end

local function start_update_scan(requester)
    if UpdateScanActive then return end  -- serialise

    _UpdateScanRequester = requester
    UpdateScanWinner = NULL_KEY
    UpdateScanWinnerVer = ""
    UpdateScanStart = ll.GetUnixTime()
    UpdateScanSession = "scan_" .. tostring(ll.GetKey()) .. "_" .. tostring(UpdateScanStart)
    UpdateScanActive = true

    ll.RegionSay(EXTERNAL_ACL_REPLY_CHAN, ll.List2Json(JSON_OBJECT, {
        "type", "remote.updateravailable",
        "collar", tostring(ll.GetKey()),
        "owner", tostring(CollarOwner),
        "wearer", tostring(ll.GetOwner()),
        "session", UpdateScanSession,
    }))

    -- Tighten cadence so the 5s scan deadline isn't blocked behind the 60s prune.
    set_timer(1.0)
end

local function handle_updater_here(message: string)
    if not UpdateScanActive then return end
    if UpdateScanWinner ~= NULL_KEY then return end  -- first responder wins

    local sess = ll.JsonGetValue(message, {"session"})
    if sess == JSON_INVALID then return end
    if sess ~= UpdateScanSession then return end

    local updater_str = ll.JsonGetValue(message, {"updater"})
    if updater_str == JSON_INVALID then return end
    local updater = uuid(updater_str)
    if updater == NULL_KEY then return end

    local ver = ll.JsonGetValue(message, {"version"})
    if ver == JSON_INVALID then ver = "?" end

    UpdateScanWinner = updater
    UpdateScanWinnerVer = ver

    report_scan_result(true)
    -- State retained for the upcoming confirm/cancel; restore default cadence.
    set_timer(60.0)
end

local function confirm_update_scan()
    if not UpdateScanActive then return end
    if UpdateScanWinner == NULL_KEY then return end

    local pin = math.floor(ll.Frand(1.0e8))
    ll.SetRemoteScriptAccessPin(pin)

    local has_receiver = (ll.GetInventoryType("ds_collar_receiver") == INVENTORY_SCRIPT) and "1" or "0"

    ll.RegionSayTo(UpdateScanWinner, EXTERNAL_ACL_REPLY_CHAN, ll.List2Json(JSON_OBJECT, {
        "type", "remote.collarready",
        "collar", tostring(ll.GetKey()),
        "owner", tostring(CollarOwner),
        "wearer", tostring(ll.GetOwner()),
        "session", UpdateScanSession,
        "pin", tostring(pin),
        "has_kernel", tostring(KernelAlive),
        "has_receiver", has_receiver,
    }))
    ll.RegionSayTo(ll.GetOwner(), 0, "Update authorised. PIN issued; updater is taking over.")

    clear_scan_state()
end

local function cancel_update_scan()
    if not UpdateScanActive then return end
    clear_scan_state()
    set_timer(60.0)
end

local function handle_update_discover(message: string)
    if ll.JsonGetValue(message, {"updater"}) == JSON_INVALID then return end
    if ll.JsonGetValue(message, {"session"}) == JSON_INVALID then return end

    local updater = uuid(ll.JsonGetValue(message, {"updater"}))
    local session = ll.JsonGetValue(message, {"session"})

    local details = ll.GetObjectDetails(updater, {OBJECT_POS})
    if #details == 0 then return end

    local distance = ll.VecDist(ll.GetPos(), details[1])
    if distance > MAX_DETECTION_RANGE then return end

    -- install vs update: kernel presence via heartbeat, receiver via inventory.
    local has_receiver = (ll.GetInventoryType("ds_collar_receiver") == INVENTORY_SCRIPT) and "1" or "0"

    local script_pin = math.floor(ll.Frand(1.0e8))
    ll.SetRemoteScriptAccessPin(script_pin)

    ll.RegionSayTo(updater, EXTERNAL_ACL_REPLY_CHAN, ll.List2Json(JSON_OBJECT, {
        "type", "remote.collarready",
        "collar", tostring(ll.GetKey()),
        "owner", tostring(CollarOwner),
        "wearer", tostring(ll.GetOwner()),
        "session", session,
        "pin", tostring(script_pin),
        "has_kernel", tostring(KernelAlive),
        "has_receiver", has_receiver,
    }))
    ll.RegionSayTo(ll.GetOwner(), 0, "Update ready. PIN generated for secure transfer.")
end

--[[ -------------------- TICK BODY -------------------- ]]

_on_timer = function()
    local t = now()

    -- Updater-scan deadline (timer tightened to 1s during a scan).
    if UpdateScanActive and UpdateScanWinner == NULL_KEY then
        if (t - UpdateScanStart) >= UPDATER_SCAN_TIMEOUT then
            report_scan_result(false)
            set_timer(60.0)
        end
    end

    prune_expired_queries(t)
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    -- Clean up any existing listens.
    if AclQueryListenHandle ~= 0 then ll.ListenRemove(AclQueryListenHandle) end
    if MenuRequestListenHandle ~= 0 then ll.ListenRemove(MenuRequestListenHandle) end

    PendingQueries = {}
    PendingMenuRequests = {}
    RateLimits = {}
    CollarOwner = ll.GetOwner()

    AclQueryListenHandle = ll.Listen(EXTERNAL_ACL_QUERY_CHAN, "", NULL_KEY, "")
    MenuRequestListenHandle = ll.Listen(EXTERNAL_MENU_CHAN, "", NULL_KEY, "")

    set_timer(60.0)  -- periodic query pruning
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.changed(change_mask: number)
    if bit32.band(change_mask, CHANGED_OWNER) ~= 0 then
        ll.ResetScript()
    end
end

function LLEvents.listen(channel: number, name: string, speaker_id, message: string)
    if channel == EXTERNAL_ACL_QUERY_CHAN then
        local msg_type = ll.JsonGetValue(message, {"type"})
        if msg_type == JSON_INVALID then return end

        if msg_type == "remote.collarscan" then
            handle_collar_scan(message)
        elseif msg_type == "auth.aclqueryexternal" then
            handle_acl_query_external(message)
        elseif msg_type == "remote.updatediscover" then
            handle_update_discover(message)
        elseif msg_type == "remote.updaterhere" then
            handle_updater_here(message)
        end
        return
    end

    if channel == EXTERNAL_MENU_CHAN then
        local msg_type = ll.JsonGetValue(message, {"type"})
        if msg_type == JSON_INVALID then return end
        if msg_type == "remote.menurequest" then
            handle_menu_request_external(message)
        end
    end
end

function LLEvents.link_message(sender_num: number, num: number, str: string, id)
    local msg_type = ll.JsonGetValue(str, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        KernelAlive = 1  -- any kernel message proves the kernel is present
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
        return
    end

    if num == REMOTE_BUS then
        if msg_type == "remote.updaterscan.start" then
            local requester = NULL_KEY
            local ru = ll.JsonGetValue(str, {"user"})
            if ru ~= JSON_INVALID then requester = uuid(ru) end
            start_update_scan(requester)
        elseif msg_type == "remote.updaterscan.confirm" then
            confirm_update_scan()
        elseif msg_type == "remote.updaterscan.cancel" then
            cancel_update_scan()
        end
        return
    end

    if num == AUTH_BUS then
        if msg_type ~= "auth.acl.result" then return end

        local avatar_key_str = ll.JsonGetValue(str, {"avatar"})
        if avatar_key_str == JSON_INVALID then return end
        local avatar_key = uuid(avatar_key_str)

        local level = 0
        local tmp = ll.JsonGetValue(str, {"level"})
        if tmp ~= JSON_INVALID then level = csv_lead_int(tmp) end

        -- Was this ACL result for a pending MENU request? (replaces the LSL jumps)
        local menu_idx = find_menu_request(avatar_key)
        if menu_idx ~= nil then
            local requested_context = PendingMenuRequests[menu_idx].context
            table.remove(PendingMenuRequests, menu_idx)

            -- TPE emergency access: the wearer reaches SOS even at ACL 0.
            local is_wearer = (avatar_key == ll.GetOwner())
            local emergency_access = (level == 0 and requested_context == SOS_CONTEXT and is_wearer)

            if level >= 1 or emergency_access then
                local final_context = requested_context
                -- Only the wearer can access SOS; others get downgraded to root.
                if requested_context == SOS_CONTEXT and not is_wearer then
                    final_context = ROOT_CONTEXT
                    ll.RegionSayTo(avatar_key, 0, "Only the collar wearer can access the SOS menu. Showing main menu instead.")
                end
                trigger_menu_for_external_user(avatar_key, final_context)
            end
            return
        end

        -- Otherwise: a response to a pending external ACL query?
        if find_pending_query(avatar_key) == nil then return end
        send_external_acl_response(avatar_key, level)
        remove_pending_query(avatar_key)
    end
end

main()

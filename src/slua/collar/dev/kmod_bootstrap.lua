--[[--------------------
MODULE: kmod_bootstrap.lua  (SLua port)
VERSION: 1.10
REVISION: 9  (SLua port rev 1)
PURPOSE: Startup coordination, RLV detection, status announcement
ARCHITECTURE: Consolidated message bus lanes

SLUA PORT NOTES:
- Ported from kmod_bootstrap.lsl rev 9. Bus wire formats (KERNEL_LIFECYCLE 500,
  REMOTE_BUS 600, SETTINGS_BUS 800) and the RLV @versionnew probe are unchanged.
- SLua has no states. The LSL default/starting/running states are modeled with a
  `State` variable; event handlers branch on it, and `state running;` becomes
  enter_running(). The trivial default state (set flags, then `state starting`)
  is folded into top-level init.
- RLV probe channels (two parallel lists) become an array of {ch, handle}.
- RLV commands still go through ll.OwnerSay (the project reserves OwnerSay for
  RLV; user-facing text uses ll.InstantMessage here, matching the LSL original).
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local REMOTE_BUS       = 600
local SETTINGS_BUS     = 800

--[[ -------------------- RLV DETECTION CONFIG -------------------- ]]
local RLV_PROBE_TIMEOUT_SEC  = 60
local RLV_RETRY_INTERVAL_SEC = 5
local RLV_MAX_RETRIES        = 10
local RLV_INITIAL_DELAY_SEC  = 5

local RELAY_CHAN = -1812221819

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_MULTI_OWNER_MODE = "access.multiowner"
local KEY_OWNER            = "access.owner"
local KEY_OWNER_NAME       = "access.ownername"
local KEY_OWNER_HONORIFIC  = "access.ownerhonorific"
local KEY_OWNER_UUIDS      = "access.owneruuids"
local KEY_OWNER_NAMES      = "access.ownernames"
local KEY_OWNER_HONORIFICS = "access.ownerhonorifics"

local NAME_LOADING = "(loading...)"

--[[ -------------------- BOOTSTRAP CONFIG -------------------- ]]
local BOOTSTRAP_TIMEOUT_SEC       = 90
local SETTINGS_RETRY_INTERVAL_SEC = 5
local SETTINGS_MAX_RETRIES        = 3
local SETTINGS_INITIAL_DELAY_SEC  = 5
local NAMES_READY_TIMEOUT_SEC     = 10

--[[ -------------------- STATE -------------------- ]]
local State = "starting"  -- "starting" | "running"

-- RLV probe channel toggles (set at init).
local UseFixed4711 = false
local UseRelayChan = false
local ProbeRelayBothSigns = false

local BootstrapComplete = false
local BootstrapDeadline = 0
local LastOwner = NULL_KEY

local RlvProbes = {}      -- array of { ch, handle }
local RlvProbing = false
local RlvActive = false
local RlvVersion = ""
local RlvProbeDeadline = 0
local RlvNextRetry = 0
local RlvRetryCount = 0
local RlvReady = false

local SettingsReceived = false
local SettingsRetryCount = 0
local SettingsNextRetry = 0

local NamesReadyDeadline = 0

--[[ -------------------- HELPERS -------------------- ]]

local function get_msg_type(msg: string): string
    local t = ll.JsonGetValue(msg, {"type"})
    if t == JSON_INVALID then return "" end
    return t
end

local function now(): number
    return ll.GetUnixTime()
end

local function sendIM(msg: string)
    local wearer = ll.GetOwner()
    if wearer ~= NULL_KEY and msg ~= "" then
        ll.InstantMessage(wearer, msg)
    end
end

local function is_attached(): boolean
    return ll.GetAttached() ~= 0
end

-- ll.CSV2List("") yields {""} (length 1); return a truly empty array for unset keys.
local function csv_read(lsd_key: string)
    local raw = ll.LinksetDataRead(lsd_key)
    if raw == "" then return {} end
    return ll.CSV2List(raw)
end

-- Owner-change detection (avoids unnecessary resets on teleport).
local function check_owner_changed(): boolean
    local current_owner = ll.GetOwner()
    if current_owner == NULL_KEY then return false end
    if LastOwner ~= NULL_KEY and current_owner ~= LastOwner then
        LastOwner = current_owner
        ll.ResetScript()
        return true
    end
    LastOwner = current_owner
    return false
end

--[[ -------------------- RLV DETECTION (multi-channel) -------------------- ]]

local function probe_has_channel(ch: number): boolean
    for _, p in ipairs(RlvProbes) do
        if p.ch == ch then return true end
    end
    return false
end

local function add_probe_channel(ch: number)
    if ch == 0 then return end
    if probe_has_channel(ch) then return end
    local handle = ll.Listen(ch, "", NULL_KEY, "")  -- accept from anyone
    RlvProbes[#RlvProbes + 1] = { ch = ch, handle = handle }
end

local function clear_probe_channels()
    for _, p in ipairs(RlvProbes) do
        if p.handle ~= 0 then ll.ListenRemove(p.handle) end
    end
    RlvProbes = {}
end

local function send_rlv_queries()
    for _, p in ipairs(RlvProbes) do
        ll.OwnerSay("@versionnew=" .. tostring(p.ch))
    end
end

local function start_rlv_probe()
    if RlvProbing then return end

    if not is_attached() then
        RlvReady = true
        RlvActive = false
        RlvVersion = ""
        return
    end

    RlvProbing = true
    RlvActive = false
    RlvVersion = ""
    RlvRetryCount = 0
    RlvReady = false

    clear_probe_channels()

    if UseFixed4711 then add_probe_channel(4711) end
    if UseRelayChan then
        add_probe_channel(RELAY_CHAN)
        if ProbeRelayBothSigns then add_probe_channel(-RELAY_CHAN) end
    end

    RlvProbeDeadline = now() + RLV_PROBE_TIMEOUT_SEC
    RlvNextRetry = now() + RLV_INITIAL_DELAY_SEC
    sendIM("Detecting RLV...")
end

local function stop_rlv_probe()
    clear_probe_channels()
    RlvProbing = false
    RlvReady = true
end

--[[ -------------------- SETTINGS LOADING -------------------- ]]

-- Mark settings received; reads happen at announcement time directly from LSD.
local function apply_settings_sync()
    SettingsReceived = true
    NamesReadyDeadline = now() + NAMES_READY_TIMEOUT_SEC
end

-- True if all owner names in LSD are resolved (no NAME_LOADING placeholders).
local function names_ready(): boolean
    local multi_mode = integer(ll.LinksetDataRead(KEY_MULTI_OWNER_MODE)) ~= 0
    if multi_mode then
        for _, nm in ipairs(csv_read(KEY_OWNER_NAMES)) do
            if nm == NAME_LOADING then return false end
        end
        return true
    end
    if ll.LinksetDataRead(KEY_OWNER) == "" then return true end
    return ll.LinksetDataRead(KEY_OWNER_NAME) ~= NAME_LOADING
end

--[[ -------------------- STATUS ANNOUNCEMENT -------------------- ]]

local function announce_status()
    if RlvActive then
        sendIM("RLV: " .. RlvVersion)
    else
        sendIM("RLV: Not detected")
    end

    if not SettingsReceived then
        sendIM("WARNING: Settings timed out. Using defaults.")
    end

    local multi_mode = integer(ll.LinksetDataRead(KEY_MULTI_OWNER_MODE)) ~= 0
    if multi_mode then
        local uuids = csv_read(KEY_OWNER_UUIDS)
        local names = csv_read(KEY_OWNER_NAMES)
        local hons  = csv_read(KEY_OWNER_HONORIFICS)
        local owner_count = #uuids

        sendIM("Mode: Multi-Owner (" .. tostring(owner_count) .. ")")

        if owner_count > 0 then
            local owner_parts = {}
            for i = 1, owner_count do
                local nm = names[i] or ""
                local hn = hons[i] or ""
                if hn ~= "" then
                    owner_parts[#owner_parts + 1] = hn .. " " .. nm
                else
                    owner_parts[#owner_parts + 1] = nm
                end
            end
            sendIM("Owned by " .. ll.DumpList2String(owner_parts, ", "))
        else
            sendIM("Uncommitted")
        end
    else
        sendIM("Mode: Single-Owner")
        local owner_uuid = ll.LinksetDataRead(KEY_OWNER)
        if owner_uuid ~= "" then
            local nm = ll.LinksetDataRead(KEY_OWNER_NAME)
            local hn = ll.LinksetDataRead(KEY_OWNER_HONORIFIC)
            local owner_line = "Owned by "
            if hn ~= "" then owner_line = owner_line .. hn .. " " end
            sendIM(owner_line .. nm)
        else
            sendIM("Uncommitted")
        end
    end

    sendIM("Collar startup complete.")
end

local function check_bootstrap_complete()
    if BootstrapComplete then return end
    if RlvReady and SettingsReceived and names_ready() then
        BootstrapComplete = true
        announce_status()
    end
end

--[[ -------------------- BOOTSTRAP INITIATION -------------------- ]]

local function start_bootstrap()
    State = "starting"
    BootstrapComplete = false
    SettingsReceived = false
    SettingsRetryCount = 0
    NamesReadyDeadline = 0

    BootstrapDeadline = now() + BOOTSTRAP_TIMEOUT_SEC
    sendIM("D/s Collar starting up. Please wait...")

    start_rlv_probe()

    SettingsNextRetry = now() + SETTINGS_INITIAL_DELAY_SEC  -- allow notecard loading
    ll.SetTimerEvent(1.0)
end

local function enter_running()
    State = "running"
    ll.SetTimerEvent(0.0)
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end

    -- Folded-in LSL default state: set probe toggles + owner, then start.
    UseFixed4711 = true
    UseRelayChan = true
    ProbeRelayBothSigns = true
    LastOwner = ll.GetOwner()

    start_bootstrap()
end

function LLEvents.on_rez(start_param: number)
    check_owner_changed()
end

function LLEvents.attach(id)
    if id == NULL_KEY then return end
    ll.ResetScript()  -- bootstrap on attach (covers logon and initial attach)
end

function LLEvents.timer()
    if State ~= "starting" then return end

    local current_time = ll.GetUnixTime()
    if current_time == 0 then return end  -- overflow protection

    -- Global timeout.
    if not BootstrapComplete and BootstrapDeadline > 0 and current_time >= BootstrapDeadline then
        sendIM("WARNING: Bootstrap timed out. Forcing completion.")
        if not RlvReady then stop_rlv_probe() end
        if not SettingsReceived then SettingsReceived = true end
        BootstrapComplete = true
        announce_status()
        enter_running()
        return
    end

    -- Settings retries (read directly from LSD).
    if not SettingsReceived and current_time >= SettingsNextRetry then
        if SettingsRetryCount < SETTINGS_MAX_RETRIES then
            apply_settings_sync()
            SettingsRetryCount += 1
            SettingsNextRetry = current_time + SETTINGS_RETRY_INTERVAL_SEC
        end
    end

    -- RLV probe retries.
    if RlvProbing and not RlvReady then
        if RlvNextRetry > 0 and current_time >= RlvNextRetry then
            if RlvRetryCount < RLV_MAX_RETRIES then
                send_rlv_queries()
                RlvRetryCount += 1
                RlvNextRetry = current_time + RLV_RETRY_INTERVAL_SEC
            end
        end
        if RlvProbeDeadline > 0 and current_time >= RlvProbeDeadline then
            stop_rlv_probe()
            check_bootstrap_complete()
        end
    end

    -- Names-ready check (kmod_settings resolves them async).
    if SettingsReceived and RlvReady and not BootstrapComplete then
        if names_ready() or (NamesReadyDeadline > 0 and current_time >= NamesReadyDeadline) then
            check_bootstrap_complete()
        end
    end

    if BootstrapComplete and not RlvProbing then
        enter_running()
    end
end

function LLEvents.listen(channel: number, name: string, id, message: string)
    if State ~= "starting" then return end
    if not probe_has_channel(channel) then return end

    local wearer = ll.GetOwner()
    if id ~= wearer and id ~= NULL_KEY then return end

    RlvActive = true
    RlvVersion = ll.StringTrim(message, STRING_TRIM)

    stop_rlv_probe()
    check_bootstrap_complete()
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local msg_type = get_msg_type(msg)
    if msg_type == "" then return end

    if State == "starting" then
        if num == SETTINGS_BUS then
            if msg_type == "settings.sync" then apply_settings_sync() end
        elseif num == KERNEL_LIFECYCLE then
            if msg_type == "settings.notecard.loaded" then
                start_bootstrap()  -- card (re)loaded — re-run bootstrap
            elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
                ll.ResetScript()
            end
        elseif num == REMOTE_BUS then
            if msg_type == "remote.update.complete" then ll.ResetScript() end
        end
    else  -- running
        if num == KERNEL_LIFECYCLE then
            if msg_type == "settings.notecard.loaded"
                or msg_type == "kernel.reset.soft"
                or msg_type == "kernel.reset.factory" then
                ll.ResetScript()
            end
        elseif num == REMOTE_BUS then
            if msg_type == "remote.update.complete" then ll.ResetScript() end
        end
    end
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        check_owner_changed()
    end
end

-- Top-level init.
main()

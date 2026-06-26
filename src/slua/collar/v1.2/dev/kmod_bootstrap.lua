--[[--------------------
MODULE: kmod_bootstrap.lua  (SLua port)
VERSION: 1.2
REVISION: 8  (SLua port rev 1)
PURPOSE: Startup coordination, RLV detection, status announcement, and settings-
         notecard streaming. Streams the card verbatim into LSD (dumb deposit) and
         lets kmod_settings convert it; publishes the rlv.active / boot.ready facts.
ARCHITECTURE: Consolidated message bus lanes.

SLUA PORT NOTES:
- Ported from kmod_bootstrap.lsl v1.2 rev 8. Cross-module contracts preserved
  exactly: deposits card lines as raw key=value into LSD + emits
  settings.card.streamed; consumes settings.sync / settings.card.restream
  (SETTINGS_BUS 800), settings.notecard.loaded / kernel.reset.* (KERNEL_LIFECYCLE
  500), remote.update.complete (REMOTE_BUS 600); publishes rlv.active and boot.ready
  LSD facts. The streamed key names are unchanged.
- GOTCHA (the structural one): STATES. The LSL's three states (default -> starting
  -> running) have no SLua equivalent, so they are modeled with a CurrentState
  string. default's one-shot config folds into main(); the only live transition
  (starting -> running) is enter_running(), which sets CurrentState and stops the
  timer. Handlers that DIFFER by state (link_message: settings.sync is honoured only
  while starting; settings.notecard.loaded re-runs bootstrap while starting but
  hard-resets while running) branch on CurrentState. Handlers IDENTICAL across both
  states (dataserver / listen / on_rez / attach / changed) are single — the listen
  RlvProbes guard makes it naturally state-safe (channels are empty once running).
- IDIOMATIC: the parallel RlvChannels / RlvListenHandles lists become a channel->
  handle dict; owner_rows' strided [rank, name, honorific] list becomes an array of
  records, rank-sorted via table.sort.
- GOTCHA: single timer. llSetTimerEvent(1.0) / llSetTimerEvent(0) become the
  set_timer shim over LLTimers; the tick body guards on CurrentState == "starting".
- csv_lead_int stands in for the (integer) casts (record acl, rank, multiowner flag).
  ll.OwnerSay carries the @versionnew RLV probe — an RLV command, the one sanctioned
  use of OwnerSay. Keys come from ll.GetOwner / events, so no uuid() needed.
- Notecard streaming is ll.GetNotecardLine + the dataserver event; the "^user\\."
  find-keys regex string is unchanged.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local REMOTE_BUS       = 600
local SETTINGS_BUS     = 800

--[[ -------------------- RLV DETECTION CONFIG -------------------- ]]
-- 3 probes, first at +2s (then +7s, +12s), give up at the 30s deadline.
local RLV_PROBE_TIMEOUT_SEC  = 30
local RLV_RETRY_INTERVAL_SEC = 5
local RLV_MAX_RETRIES        = 3
local RLV_INITIAL_DELAY_SEC  = 2

local UseFixed4711        = false
local UseRelayChan        = false
local RELAY_CHAN          = -1812221819
local ProbeRelayBothSigns = false

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local NAME_LOADING = "(loading...)"

-- Card-override applied marker (written by kmod_settings once the streamed card has
-- been converted). We stream only while THIS is unset — NOT the readiness sentinel:
-- the notecard is an override, never a requirement. CROSS-MODULE CONTRACT.
local KEY_CARD_APPLIED = "settings.cardapplied"

-- Touch-guard flag. Cleared at boot start, set "1" once startup finishes; kmod_ui
-- ignores touches while unset. CROSS-MODULE CONTRACT with kmod_ui.
local KEY_BOOT_READY = "boot.ready"

--[[ -------------------- NOTECARD STREAMING -------------------- ]]
local NOTECARD_NAME  = "settings"
local COMMENT_PREFIX = "#"
local SEPARATOR      = "="
local USER_PREFIX    = "user."

local CardQuery = NULL_KEY
local CardLine  = 0
local Streaming = false

--[[ -------------------- BOOTSTRAP CONFIG -------------------- ]]
local BOOTSTRAP_TIMEOUT_SEC        = 90
local SETTINGS_RETRY_INTERVAL_SEC  = 5
local SETTINGS_MAX_RETRIES         = 3
local SETTINGS_INITIAL_DELAY_SEC   = 5  -- wait for LSD + notecard load

--[[ -------------------- STATE -------------------- ]]
local CurrentState = "starting"  -- "starting" | "running" (replaces LSL states)

local BootstrapComplete = false
local BootstrapDeadline = 0

local LastOwner = NULL_KEY

-- RLV detection: channel -> listen handle (replaces the two parallel lists).
local RlvProbes: { [number]: number } = {}
local RlvProbing      = false
local RlvActive       = false
local RlvVersion      = ""
local RlvProbeDeadline = 0
local RlvNextRetry    = 0
local RlvRetryCount   = 0
local RlvReady        = false

-- Settings
local SettingsReceived  = false
local SettingsRetryCount = 0
local SettingsNextRetry = 0

-- Name-resolution wait.
local NamesReadyDeadline = 0
local NAMES_READY_TIMEOUT_SEC = 10

--[[ -------------------- TIMER SHIM (single timer) -------------------- ]]
local _timerHandle = nil
local _on_timer  -- forward declaration; assigned below
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

local function get_msg_type(msg: string): string
    local t = ll.JsonGetValue(msg, {"type"})
    if t == JSON_INVALID then return "" end
    return t
end

local function csv_lead_int(s: string): number
    return tonumber(string.match(s, "^%s*(-?%d+)") or "") or 0
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

local function isAttached(): boolean
    return ll.GetAttached() ~= 0
end

-- Owner change detection (prevents unnecessary resets on teleport).
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

local function addProbeChannel(ch: number)
    if ch == 0 then return end
    if RlvProbes[ch] ~= nil then return end  -- already added
    RlvProbes[ch] = ll.Listen(ch, "", NULL_KEY, "")  -- accept from anyone
end

local function clearProbeChannels()
    for _, handle in pairs(RlvProbes) do
        if handle ~= 0 then ll.ListenRemove(handle) end
    end
    RlvProbes = {}
end

local function sendRlvQueries()
    for ch in pairs(RlvProbes) do
        ll.OwnerSay("@versionnew=" .. tostring(ch))
    end
end

local function start_rlv_probe()
    if RlvProbing then return end

    if not isAttached() then
        -- Not attached, can't detect RLV.
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

    clearProbeChannels()

    if UseFixed4711 then addProbeChannel(4711) end
    if UseRelayChan then
        addProbeChannel(RELAY_CHAN)
        if ProbeRelayBothSigns then addProbeChannel(-RELAY_CHAN) end
    end

    RlvProbeDeadline = now() + RLV_PROBE_TIMEOUT_SEC
    RlvNextRetry = now() + RLV_INITIAL_DELAY_SEC

    sendIM("Detecting RLV...")
end

local function stop_rlv_probe()
    clearProbeChannels()
    RlvProbing = false
    RlvReady = true
end

--[[ -------------------- SETTINGS LOADING -------------------- ]]

-- Mark settings received and start the names-ready countdown. Reading happens at
-- announcement time directly from LSD.
local function apply_settings_sync()
    SettingsReceived = true
    NamesReadyDeadline = now() + NAMES_READY_TIMEOUT_SEC
end

-- Owner records (user.<uuid> with acl 5) as rank-sorted {rank, name, honorific}
-- records. The record's leading field is the acl; fields 2/3/4 are rank/name/honorific.
local function owner_rows(): {{ rank: number, name: string, honorific: string }}
    local rows = {}
    local ks = ll.LinksetDataFindKeys("^user\\.", 0, -1)
    for _, k in ipairs(ks) do
        local rec = ll.LinksetDataRead(k)
        if csv_lead_int(rec) == 5 then
            local f = ll.CSV2List(rec)
            rows[#rows + 1] = {
                rank = csv_lead_int(f[2] or "0"),
                name = f[3] or "",
                honorific = f[4] or "",
            }
        end
    end
    table.sort(rows, function(a, b) return a.rank < b.rank end)
    return rows
end

-- TRUE if all owner names are resolved (no (loading...) placeholders).
local function names_ready(): boolean
    for _, r in ipairs(owner_rows()) do
        if r.name == NAME_LOADING then return false end
    end
    return true
end

--[[ -------------------- NOTECARD STREAMING -------------------- ]]

-- Deposit one card line into LSD as a raw key=value. Comments/blanks skipped;
-- user.* refused (a card may never forge records); only dotted keys accepted. No
-- parsing/record-building — kmod_settings does that on settings.card.streamed.
local function stream_line(line: string)
    line = ll.StringTrim(line, STRING_TRIM)
    if line == "" then return end
    if ll.GetSubString(line, 0, 0) == COMMENT_PREFIX then return end

    local sep = ll.SubStringIndex(line, SEPARATOR)
    if sep == -1 then return end

    local k = ll.StringTrim(ll.GetSubString(line, 0, sep - 1), STRING_TRIM)
    local v = ll.StringTrim(ll.GetSubString(line, sep + 1, -1), STRING_TRIM)
    if k == "" then return end
    if ll.SubStringIndex(k, USER_PREFIX) == 0 then return end  -- never card-write records
    if ll.SubStringIndex(k, ".") == -1 then return end          -- dotted keys only

    ll.LinksetDataWrite(k, v)
end

-- Begin streaming the settings notecard (idempotent while in flight).
local function stream_card()
    if Streaming then return end
    if ll.GetInventoryType(NOTECARD_NAME) ~= INVENTORY_NOTECARD then return end
    Streaming = true
    CardLine = 0
    CardQuery = ll.GetNotecardLine(NOTECARD_NAME, CardLine)
end

-- Tell kmod_settings the raw deposit is complete.
local function emit_card_streamed()
    Streaming = false
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "settings.card.streamed",
    }), NULL_KEY)
end

--[[ -------------------- BOOTSTRAP COMPLETION -------------------- ]]

local function announce_status()
    -- RLV status (publish rlv.active for kmod_ui's mask-bit-0x40 gating).
    if RlvActive then
        sendIM("RLV: " .. RlvVersion)
        ll.LinksetDataWrite("rlv.active", "1")
    else
        sendIM("RLV: Not detected")
        ll.LinksetDataWrite("rlv.active", "0")
    end

    if not SettingsReceived then
        sendIM("WARNING: Settings timed out. Using defaults.")
    end

    -- Owner announcement from the roster; the mode line shows the access.multiowner
    -- POLICY flag (notecard-only), not the count.
    local rows = owner_rows()
    local owner_count = #rows

    if csv_lead_int(ll.LinksetDataRead("access.multiowner")) ~= 0 then
        sendIM("Mode: Multi-Owner (" .. tostring(owner_count) .. ")")
    else
        sendIM("Mode: Single-Owner")
    end

    if owner_count > 0 then
        local owner_parts = {}
        for _, r in ipairs(rows) do
            if r.honorific ~= "" then
                owner_parts[#owner_parts + 1] = r.honorific .. " " .. r.name
            else
                owner_parts[#owner_parts + 1] = r.name
            end
        end
        sendIM("Owned by " .. table.concat(owner_parts, ", "))
    else
        sendIM("Uncommitted")
    end

    sendIM("Collar startup complete.")

    -- Lift the touch-guard — registrations have long since settled.
    ll.LinksetDataWrite(KEY_BOOT_READY, "1")
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
    BootstrapComplete = false
    SettingsReceived = false
    SettingsRetryCount = 0
    NamesReadyDeadline = 0

    -- Arm the touch-guard.
    ll.LinksetDataDelete(KEY_BOOT_READY)

    BootstrapDeadline = now() + BOOTSTRAP_TIMEOUT_SEC

    sendIM("D/s Collar starting up. Please wait...")

    start_rlv_probe()

    -- Stream the settings card as an OVERRIDE on a fresh boot only: card present AND
    -- the override not yet applied. Gated on the card marker, NOT readiness.
    if ll.GetInventoryType(NOTECARD_NAME) == INVENTORY_NOTECARD
        and ll.LinksetDataRead(KEY_CARD_APPLIED) == "" then
        stream_card()
    end

    SettingsNextRetry = now() + SETTINGS_INITIAL_DELAY_SEC

    set_timer(1.0)
end

--[[ -------------------- UPDATE COMPLETION -------------------- ]]

-- Cross-version (v1.x -> v1.2) self-heal. A normal reset restarts only bootstrap, but
-- a cross-schema update leaves the old roster unreadable (wearer comes up
-- "uncommitted"). If the roster is empty (the brick), clear the card marker and
-- broadcast a full soft reset so every script restarts together and the card
-- re-streams. A healthy collar (roster present) just restarts.
local function handle_update_complete()
    if #ll.LinksetDataFindKeys("^user\\.", 0, -1) == 0 then
        ll.LinksetDataDelete(KEY_CARD_APPLIED)
        ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
            "type", "kernel.reset.soft",
        }), NULL_KEY)
    end
    ll.ResetScript()
end

--[[ -------------------- STATE TRANSITION -------------------- ]]

-- starting -> running: stop the bootstrap tick.
local function enter_running()
    CurrentState = "running"
    set_timer(0)
end

--[[ -------------------- TICK BODY (starting state) -------------------- ]]

_on_timer = function()
    if CurrentState ~= "starting" then return end

    local current_time = ll.GetUnixTime()
    if current_time == 0 then return end  -- overflow protection

    -- GLOBAL TIMEOUT.
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
            SettingsRetryCount = SettingsRetryCount + 1
            SettingsNextRetry = current_time + SETTINGS_RETRY_INTERVAL_SEC
        end
    end

    -- Self-heal the card-override handshake (non-fatal; bounded by marker + timeout).
    if not Streaming
        and ll.LinksetDataRead(KEY_CARD_APPLIED) == ""
        and ll.GetInventoryType(NOTECARD_NAME) == INVENTORY_NOTECARD then
        stream_card()
    end

    -- RLV probe retries.
    if RlvProbing and not RlvReady then
        if RlvNextRetry > 0 and current_time >= RlvNextRetry then
            if RlvRetryCount < RLV_MAX_RETRIES then
                sendRlvQueries()
                RlvRetryCount = RlvRetryCount + 1
                local next_retry_time = current_time + RLV_RETRY_INTERVAL_SEC
                if next_retry_time < current_time then next_retry_time = current_time end
                RlvNextRetry = next_retry_time
            end
        end
        if RlvProbeDeadline > 0 and current_time >= RlvProbeDeadline then
            stop_rlv_probe()
            check_bootstrap_complete()
        end
    end

    -- Names-ready check.
    if SettingsReceived and RlvReady and not BootstrapComplete then
        if names_ready() or (NamesReadyDeadline > 0 and current_time >= NamesReadyDeadline) then
            check_bootstrap_complete()
        end
    end

    -- Stop the timer once bootstrap is complete.
    if BootstrapComplete and not RlvProbing then
        enter_running()
    end
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    UseFixed4711 = true
    UseRelayChan = true
    ProbeRelayBothSigns = true

    LastOwner = ll.GetOwner()

    CurrentState = "starting"
    start_bootstrap()
end

function LLEvents.on_rez(start_param: number)
    -- Only reset if owner changed — prevents bootstrap on every teleport.
    check_owner_changed()
end

function LLEvents.attach(id)
    if id == NULL_KEY then return end
    -- Bootstrap on attach (covers logon and initial attach).
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        check_owner_changed()
    end
end

-- RLV probe responses. State-safe: RlvProbes is empty once running, so this returns
-- early outside the probe window.
function LLEvents.listen(channel: number, name: string, id, message: string)
    if RlvProbes[channel] == nil then return end

    local wearer = ll.GetOwner()
    if id ~= wearer and id ~= NULL_KEY then return end

    RlvActive = true
    RlvVersion = ll.StringTrim(message, STRING_TRIM)

    stop_rlv_probe()
    check_bootstrap_complete()
end

-- Notecard streaming chain (identical in both states).
function LLEvents.dataserver(query_id, data: string)
    if query_id ~= CardQuery then return end
    if data ~= EOF then
        stream_line(data)
        CardLine = CardLine + 1
        CardQuery = ll.GetNotecardLine(NOTECARD_NAME, CardLine)
    else
        emit_card_streamed()
    end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local msg_type = get_msg_type(msg)
    if msg_type == "" then return end

    if num == SETTINGS_BUS then
        if msg_type == "settings.sync" then
            -- Honoured only while starting; running ignores it.
            if CurrentState == "starting" then apply_settings_sync() end
        elseif msg_type == "settings.card.restream" then
            -- Reload / Reset Config / card edit cleared the sentinel and wants the
            -- card re-deposited (both states deposit).
            stream_card()
        end
    elseif num == KERNEL_LIFECYCLE then
        if msg_type == "settings.notecard.loaded" then
            if CurrentState == "starting" then
                start_bootstrap()  -- re-run bootstrap
            else
                ll.ResetScript()   -- running: hard reset to re-announce
            end
        elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
    elseif num == REMOTE_BUS then
        if msg_type == "remote.update.complete" then
            handle_update_complete()
        end
    end
end

main()

--[[--------------------
MODULE: kmod_remote.lua  (SLua port)
VERSION: 1.10
REVISION: 9  (SLua port rev 1)
PURPOSE: External HUD communication bridge for remote control + update broker
ARCHITECTURE: Consolidated message bus lanes, namespaced internal message protocol

SLUA PORT NOTES:
- Ported from kmod_remote.lsl rev 9. External region-channel protocol
  (EXTERNAL_* channels), the JSON message shapes, and the REMOTE_BUS/AUTH_BUS/
  UI_BUS/KERNEL_LIFECYCLE contracts are byte-compatible for HUD/updater interop.
- Idiomatic SLua: the stride-2/3 lists (pending queries + timestamps, pending
  menu requests, per-type rate limits) become maps. The query FIFO eviction is
  now oldest-timestamp eviction (equivalent — timestamps tracked insertion).
  The two AUTH-result `jump` labels become a clean menu-vs-query branch.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local REMOTE_BUS = 600
local AUTH_BUS = 700
local UI_BUS = 900

--[[ -------------------- EXTERNAL PROTOCOL CHANNELS -------------------- ]]
local EXTERNAL_ACL_QUERY_CHAN = -8675309
local EXTERNAL_ACL_REPLY_CHAN = -8675310
local EXTERNAL_MENU_CHAN      = -8675311

local MAX_DETECTION_RANGE = 20.0

--[[ -------------------- CONTEXT CONSTANTS -------------------- ]]
local ROOT_CONTEXT = "ui.core.root"
local SOS_CONTEXT = "ui.sos.root"

--[[ -------------------- TUNABLES -------------------- ]]
local MAX_PENDING_QUERIES = 20
local QUERY_TIMEOUT = 30.0
local REQUEST_COOLDOWN = 2.0
local UPDATER_SCAN_TIMEOUT = 5.0

-- Request type identifiers (rate-limit buckets).
local REQUEST_TYPE_SCAN = 1
local REQUEST_TYPE_ACL_QUERY = 2
local REQUEST_TYPE_MENU = 3

--[[ -------------------- STATE -------------------- ]]
local AclQueryListenHandle = 0
local MenuRequestListenHandle = 0
local CollarOwner = NULL_KEY

-- tostring(hud_wearer) -> { object = uuid, ts = number }
local PendingQueries = {}
-- tostring(hud_wearer) -> requested context
local PendingMenuRequests = {}
-- "tostring(avatar)|type" -> last-request unix time
local RateLimits = {}

local KernelAlive = false

-- Updater scan state.
local UpdateScanActive = false
local UpdateScanStart = 0
local UpdateScanSession = ""
local UpdateScanWinner = NULL_KEY
local UpdateScanWinnerVer = ""

--[[ -------------------- HELPERS -------------------- ]]

local function now(): number
    return ll.GetUnixTime()
end

local function bnum(b: boolean): string
    if b then return "1" end
    return "0"
end

--[[ -------------------- RATE LIMITING (per request type) -------------------- ]]

local function check_rate_limit(requester, request_type: number): boolean
    local now_time = now()
    local k = tostring(requester) .. "|" .. tostring(request_type)
    local last = RateLimits[k]
    if last ~= nil then
        if (now_time - last) < REQUEST_COOLDOWN then return false end
        RateLimits[k] = now_time
        return true
    end
    -- New bucket: opportunistically drop stale entries to bound growth.
    for kk, ts in pairs(RateLimits) do
        if (now_time - ts) >= REQUEST_COOLDOWN then RateLimits[kk] = nil end
    end
    RateLimits[k] = now_time
    return true
end

--[[ -------------------- PENDING QUERY MANAGEMENT -------------------- ]]

local function prune_expired_queries(now_time: number)
    for k, q in pairs(PendingQueries) do
        if (now_time - q.ts) > QUERY_TIMEOUT then PendingQueries[k] = nil end
    end
end

local function pending_query_count(): number
    local n = 0
    for _ in pairs(PendingQueries) do n += 1 end
    return n
end

local function add_pending_query(hud_wearer, hud_object)
    local now_time = now()
    local k = tostring(hud_wearer)
    local existing = PendingQueries[k]
    if existing ~= nil then
        existing.object = hud_object
        existing.ts = now_time
        return
    end

    prune_expired_queries(now_time)

    if pending_query_count() >= MAX_PENDING_QUERIES then
        -- Evict oldest (smallest timestamp).
        local oldest_k, oldest_ts = nil, nil
        for kk, q in pairs(PendingQueries) do
            if oldest_ts == nil or q.ts < oldest_ts then oldest_ts = q.ts; oldest_k = kk end
        end
        if oldest_k ~= nil then PendingQueries[oldest_k] = nil end
    end

    PendingQueries[k] = { object = hud_object, ts = now_time }
end

local function find_pending_query(hud_wearer): boolean
    return PendingQueries[tostring(hud_wearer)] ~= nil
end

local function remove_pending_query(hud_wearer)
    PendingQueries[tostring(hud_wearer)] = nil
end

--[[ -------------------- INTERNAL ACL / MENU -------------------- ]]

local function request_internal_acl(avatar_key)
    ll.MessageLinked(LINK_SET, AUTH_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "auth.acl.query",
        "avatar", tostring(avatar_key),
        "id", "remote_" .. tostring(avatar_key),
    }), NULL_KEY)
end

local function send_external_acl_response(hud_wearer, level: number)
    -- HUD filters by collar owner; sent on the region reply channel.
    ll.RegionSay(EXTERNAL_ACL_REPLY_CHAN, ll.List2Json(JSON_OBJECT, {
        "type", "auth.aclresultexternal",
        "avatar", tostring(hud_wearer),
        "level", tostring(level),
        "collar_owner", tostring(CollarOwner),
    }))
end

local function trigger_menu_for_external_user(user_key, context: string)
    -- External user's key rides as the id parameter.
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.start",
        "context", context,
    }), user_key)
end

--[[ -------------------- EXTERNAL PROTOCOL HANDLERS -------------------- ]]

local function in_range(target): boolean
    local data = ll.GetObjectDetails(target, {OBJECT_POS})
    if #data == 0 then return false end
    return ll.VecDist(data[1], ll.GetPos()) <= MAX_DETECTION_RANGE
end

local function handle_collar_scan(message: string)
    if ll.JsonGetValue(message, {"hud_wearer"}) == JSON_INVALID then return end
    local hud_wearer = uuid(ll.JsonGetValue(message, {"hud_wearer"}))
    if hud_wearer == NULL_KEY then return end

    if not check_rate_limit(hud_wearer, REQUEST_TYPE_SCAN) then return end
    if not in_range(hud_wearer) then return end

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

    if hud_wearer == NULL_KEY or hud_object == NULL_KEY or target_avatar == NULL_KEY then return end

    -- Optional collar-scoped query: only the named collar replies.
    local target_collar_str = ll.JsonGetValue(message, {"target_collar"})
    if target_collar_str ~= JSON_INVALID then
        if uuid(target_collar_str) ~= ll.GetKey() then return end
    end

    if not check_rate_limit(hud_wearer, REQUEST_TYPE_ACL_QUERY) then return end
    if target_avatar ~= CollarOwner then return end  -- not our collar

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
    if not in_range(hud_wearer) then return end

    if PendingMenuRequests[tostring(hud_wearer)] ~= nil then return end

    PendingMenuRequests[tostring(hud_wearer)] = context
    request_internal_acl(hud_wearer)
end

--[[ -------------------- UPDATE PROTOCOL HANDLERS -------------------- ]]

local function clear_scan_state()
    UpdateScanActive = false
    UpdateScanStart = 0
    UpdateScanSession = ""
    UpdateScanWinner = NULL_KEY
    UpdateScanWinnerVer = ""
end

-- Report scan result to plugin_maint. Clears state when not found; keeps it on
-- found until plugin_maint confirms/cancels.
local function report_scan_result(found: boolean)
    ll.MessageLinked(LINK_SET, REMOTE_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "remote.updaterscan.result",
        "found", bnum(found),
        "updater", tostring(UpdateScanWinner),
        "version", UpdateScanWinnerVer,
    }), NULL_KEY)
    if not found then clear_scan_state() end
end

local function start_update_scan()
    if UpdateScanActive then return end  -- serialise

    UpdateScanWinner = NULL_KEY
    UpdateScanWinnerVer = ""
    UpdateScanStart = now()
    UpdateScanSession = "scan_" .. tostring(ll.GetKey()) .. "_" .. tostring(UpdateScanStart)
    UpdateScanActive = true

    ll.RegionSay(EXTERNAL_ACL_REPLY_CHAN, ll.List2Json(JSON_OBJECT, {
        "type", "remote.updateravailable",
        "collar", tostring(ll.GetKey()),
        "owner", tostring(CollarOwner),
        "wearer", tostring(ll.GetOwner()),
        "session", UpdateScanSession,
    }))

    -- Tighten cadence so the 5s deadline isn't blocked behind the 60s prune.
    ll.SetTimerEvent(1.0)
end

local function handle_updater_here(message: string)
    if not UpdateScanActive then return end
    if UpdateScanWinner ~= NULL_KEY then return end  -- first responder wins

    local sess = ll.JsonGetValue(message, {"session"})
    if sess == JSON_INVALID or sess ~= UpdateScanSession then return end

    local updater_str = ll.JsonGetValue(message, {"updater"})
    if updater_str == JSON_INVALID then return end
    local updater = uuid(updater_str)
    if updater == NULL_KEY then return end

    local ver = ll.JsonGetValue(message, {"version"})
    if ver == JSON_INVALID then ver = "?" end

    UpdateScanWinner = updater
    UpdateScanWinnerVer = ver

    report_scan_result(true)
    ll.SetTimerEvent(60.0)  -- restore default cadence
end

local function confirm_update_scan()
    if not UpdateScanActive then return end
    if UpdateScanWinner == NULL_KEY then return end

    local pin = integer(ll.Frand(1.0e8))
    ll.SetRemoteScriptAccessPin(pin)

    local has_receiver = ll.GetInventoryType("ds_collar_receiver") == INVENTORY_SCRIPT

    ll.RegionSayTo(UpdateScanWinner, EXTERNAL_ACL_REPLY_CHAN, ll.List2Json(JSON_OBJECT, {
        "type", "remote.collarready",
        "collar", tostring(ll.GetKey()),
        "owner", tostring(CollarOwner),
        "wearer", tostring(ll.GetOwner()),
        "session", UpdateScanSession,
        "pin", tostring(pin),
        "has_kernel", bnum(KernelAlive),
        "has_receiver", bnum(has_receiver),
    }))
    ll.RegionSayTo(ll.GetOwner(), 0, "Update authorised. PIN issued; updater is taking over.")

    clear_scan_state()
end

local function cancel_update_scan()
    if not UpdateScanActive then return end
    clear_scan_state()
    ll.SetTimerEvent(60.0)
end

local function handle_update_discover(message: string)
    if ll.JsonGetValue(message, {"updater"}) == JSON_INVALID then return end
    if ll.JsonGetValue(message, {"session"}) == JSON_INVALID then return end

    local updater = uuid(ll.JsonGetValue(message, {"updater"}))
    local session = ll.JsonGetValue(message, {"session"})

    if not in_range(updater) then return end

    local has_receiver = ll.GetInventoryType("ds_collar_receiver") == INVENTORY_SCRIPT

    local script_pin = integer(ll.Frand(1.0e8))
    ll.SetRemoteScriptAccessPin(script_pin)

    ll.RegionSayTo(updater, EXTERNAL_ACL_REPLY_CHAN, ll.List2Json(JSON_OBJECT, {
        "type", "remote.collarready",
        "collar", tostring(ll.GetKey()),
        "owner", tostring(CollarOwner),
        "wearer", tostring(ll.GetOwner()),
        "session", session,
        "pin", tostring(script_pin),
        "has_kernel", bnum(KernelAlive),
        "has_receiver", bnum(has_receiver),
    }))
    ll.RegionSayTo(ll.GetOwner(), 0, "Update ready. PIN generated for secure transfer.")
end

--[[ -------------------- AUTH RESULT -------------------- ]]

local function handle_acl_result(str: string)
    local avatar_key_str = ll.JsonGetValue(str, {"avatar"})
    if avatar_key_str == JSON_INVALID then return end
    local avatar_key = uuid(avatar_key_str)

    local level = 0
    local tmp = ll.JsonGetValue(str, {"level"})
    if tmp ~= JSON_INVALID then level = integer(tmp) end

    -- Menu-request ACL verification?
    local mkey = tostring(avatar_key)
    local requested_context = PendingMenuRequests[mkey]
    if requested_context ~= nil then
        PendingMenuRequests[mkey] = nil

        local is_wearer = (avatar_key == ll.GetOwner())
        -- TPE emergency: wearer may reach SOS even at ACL 0.
        local emergency_access = (level == 0 and requested_context == SOS_CONTEXT and is_wearer)

        if level >= 1 or emergency_access then
            local final_context = requested_context
            if requested_context == SOS_CONTEXT and not is_wearer then
                final_context = ROOT_CONTEXT
                ll.RegionSayTo(avatar_key, 0, "Only the collar wearer can access the SOS menu. Showing main menu instead.")
            end
            trigger_menu_for_external_user(avatar_key, final_context)
        end
        return
    end

    -- Otherwise: response to a pending external query.
    if not find_pending_query(avatar_key) then return end
    send_external_acl_response(avatar_key, level)
    remove_pending_query(avatar_key)
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end

    if AclQueryListenHandle ~= 0 then ll.ListenRemove(AclQueryListenHandle) end
    if MenuRequestListenHandle ~= 0 then ll.ListenRemove(MenuRequestListenHandle) end

    PendingQueries = {}
    PendingMenuRequests = {}
    RateLimits = {}
    CollarOwner = ll.GetOwner()

    AclQueryListenHandle = ll.Listen(EXTERNAL_ACL_QUERY_CHAN, "", NULL_KEY, "")
    MenuRequestListenHandle = ll.Listen(EXTERNAL_MENU_CHAN, "", NULL_KEY, "")

    ll.SetTimerEvent(60.0)
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.changed(change_mask: number)
    if bit32.band(change_mask, CHANGED_OWNER) ~= 0 then
        ll.ResetScript()
    end
end

function LLEvents.timer()
    local t = now()

    -- Updater-scan deadline (timer tightened to 1s while scanning).
    if UpdateScanActive and UpdateScanWinner == NULL_KEY then
        if (t - UpdateScanStart) >= integer(UPDATER_SCAN_TIMEOUT) then
            report_scan_result(false)
            ll.SetTimerEvent(60.0)
        end
    end

    prune_expired_queries(t)
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
        KernelAlive = true  -- any kernel message proves presence
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
        return
    end

    if num == REMOTE_BUS then
        if msg_type == "remote.updaterscan.start" then
            start_update_scan()
        elseif msg_type == "remote.updaterscan.confirm" then
            confirm_update_scan()
        elseif msg_type == "remote.updaterscan.cancel" then
            cancel_update_scan()
        end
        return
    end

    if num == AUTH_BUS then
        if msg_type == "auth.acl.result" then
            handle_acl_result(str)
        end
    end
end

-- Top-level init.
main()

--[[--------------------
MODULE: kmod_leash_proto.lua  (SLua port)
VERSION: 1.10
REVISION: 7  (SLua port rev 1)
PURPOSE: Holder-discovery handshake protocol for the leashing engine
ARCHITECTURE: Three-phase handshake state machine —
                "default"      — idle / coffle responder
                "proto_native" — sent plugin.leash.request, awaiting reply
                "proto_oc_lm"  — native timed out, sent LM ping, awaiting reply

SLUA PORT NOTES:
- Ported from kmod_leash_proto.lsl rev 7. The native handshake (LEASH_CHAN_NATIVE
  plugin.leash.request/target), the OC/LM fallback (LEASH_CHAN_LM), and the
  leash.proto.* IPC over SETTINGS_BUS are byte-compatible for OC/LM interop.
- SLua has no states. The three LSL states become a `State` variable plus
  enter_default/enter_proto_native/enter_proto_oc_lm transition functions.
  Because SLua does NOT auto-clear listeners on a state change (LSL does), each
  transition explicitly removes the previous listeners before opening the new
  state's — replicating the LSL teardown the original relied on.
----------------------]]

--[[ -------------------- BUS CHANNELS -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS     = 800

--[[ -------------------- PROTOCOL CONSTANTS -------------------- ]]
local LEASH_CHAN_LM     = -8888
local LEASH_CHAN_NATIVE = -192837465

local NATIVE_PHASE_DURATION = 2.0
local OC_PHASE_DURATION     = 2.0

--[[ -------------------- STATE -------------------- ]]
local State = "default"

local HolderListen   = 0
local HolderListenOC = 0
local HolderSession  = 0

local Controller       = NULL_KEY
local ModeStr          = ""
local ValidationTarget = NULL_KEY
local OCPingTarget     = NULL_KEY

--[[ -------------------- GENERIC HELPERS -------------------- ]]

-- This collar's LeashPoint prim (child named "leashpoint"), or root.
--[[ -------------------- TIMER SHIM (LSL single-timer over SLua LLTimers) -------------------- ]]
local _timerHandle = nil
local _on_timer  -- forward declaration; assigned where the timer body lives
--[[ integer(): SLua has no LSL-style (integer) cast; emulate it (truncate toward zero; non-numeric -> 0). ]]
local function integer(v): number
    local n = tonumber(v)
    if n == nil then return 0 end
    if n < 0 then return math.ceil(n) end
    return math.floor(n)
end

local function set_timer(interval: number)
    if _timerHandle then
        LLTimers:off(_timerHandle)
        _timerHandle = nil
    end
    if interval > 0 then
        _timerHandle = LLTimers:every(interval, _on_timer)
    end
end

local function findLeashpointPrim()
    local n = ll.GetNumberOfPrims()
    for i = 2, n do
        local nm = string.lower(ll.StringTrim(ll.GetLinkName(i), STRING_TRIM))
        if nm == "leashpoint" then return ll.GetLinkKey(i) end
    end
    local ln = ll.GetLinkNumber()
    if ln <= 0 then ln = 1 end
    return ll.GetLinkKey(ln)
end

--[[ -------------------- ENGINE NOTIFICATION -------------------- ]]

local function notifyHolder(holder)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "leash.proto.holder",
        "holder", tostring(holder),
    }), NULL_KEY)
end

local function notifyFallback(target)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "leash.proto.fallback",
        "target", tostring(target),
    }), NULL_KEY)
end

--[[ -------------------- IPC PARAM CAPTURE -------------------- ]]

-- Defensive guard against malformed leash.proto.start (missing field would
-- otherwise feed the literal "JSON_INVALID" into controller/mode).
local function validProtoStart(msg: string): boolean
    if ll.JsonGetValue(msg, {"controller"})        == JSON_INVALID then return false end
    if ll.JsonGetValue(msg, {"mode"})              == JSON_INVALID then return false end
    if ll.JsonGetValue(msg, {"validation_target"}) == JSON_INVALID then return false end
    if ll.JsonGetValue(msg, {"oc_ping_target"})    == JSON_INVALID then return false end
    return true
end

local function captureProtoStart(msg: string)
    Controller       = uuid(ll.JsonGetValue(msg, {"controller"}))
    ModeStr          = ll.JsonGetValue(msg, {"mode"})
    ValidationTarget = uuid(ll.JsonGetValue(msg, {"validation_target"}))
    OCPingTarget     = uuid(ll.JsonGetValue(msg, {"oc_ping_target"}))
end

-- Fresh nonce, send the native request, arm the phase timer.
local function restartNativeProbe()
    HolderSession = integer(ll.Frand(9.0e6))
    ll.RegionSay(LEASH_CHAN_NATIVE, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.request",
        "wearer", tostring(ll.GetOwner()),
        "collar", tostring(ll.GetKey()),
        "controller", tostring(Controller),
        "session", tostring(HolderSession),
        "origin", "leashpoint",
        "mode", ModeStr,
    }))
    set_timer(NATIVE_PHASE_DURATION)
end

--[[ -------------------- NATIVE RESPONDER -------------------- ]]

-- Reply to plugin.leash.request from OTHER collars (coffle role). Always active.
local function leashProtoNativeRequest(msg: string)
    local requesting_collar = uuid(ll.JsonGetValue(msg, {"collar"}))
    if requesting_collar == NULL_KEY then return end
    if requesting_collar == ll.GetKey() then return end  -- ignore self-broadcast
    local session_str = ll.JsonGetValue(msg, {"session"})
    if session_str == JSON_INVALID then return end

    -- Only answer coffle requests (grab/post belong to the hand-held holder).
    local requester_mode = ll.JsonGetValue(msg, {"mode"})
    if requester_mode ~= JSON_INVALID and requester_mode ~= "coffle" then return end

    ll.RegionSayTo(requesting_collar, LEASH_CHAN_NATIVE, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.target",
        "ok", "1",
        "holder", tostring(findLeashpointPrim()),
        "root", tostring(ll.GetLinkKey(1)),
        "name", ll.GetObjectName(),
        "session", session_str,
    }))
end

--[[ -------------------- HANDSHAKE-REPLY VALIDATION -------------------- ]]

-- Candidate holder key on a valid plugin.leash.target reply, else NULL_KEY.
local function validateAndExtractHolder(msg: string)
    if ll.JsonGetValue(msg, {"type"}) ~= "plugin.leash.target" then return NULL_KEY end
    if ll.JsonGetValue(msg, {"ok"}) ~= "1" then return NULL_KEY end
    if integer(ll.JsonGetValue(msg, {"session"})) ~= HolderSession then return NULL_KEY end

    local candidate = uuid(ll.JsonGetValue(msg, {"holder"}))
    if candidate == NULL_KEY then return NULL_KEY end

    if ModeStr == "post" then
        -- Post: responder's linkset root must equal the clicked post UUID.
        local root_str = ll.JsonGetValue(msg, {"root"})
        if root_str == JSON_INVALID then return NULL_KEY end
        if uuid(root_str) ~= ValidationTarget then return NULL_KEY end
    else
        -- Avatar/coffle: responder must be an attachment owned by the expected
        -- wearer. Validate against the linkset ROOT (a child prim reports
        -- OBJECT_ATTACHED_POINT = 0), but still return the candidate for docking.
        local root_str = ll.JsonGetValue(msg, {"root"})
        local validate_key = candidate
        if root_str ~= JSON_INVALID and uuid(root_str) ~= NULL_KEY then
            validate_key = uuid(root_str)
        end
        local odetails = ll.GetObjectDetails(validate_key, {OBJECT_ATTACHED_POINT, OBJECT_OWNER})
        if #odetails < 2 then return NULL_KEY end
        if odetails[1] == 0 then return NULL_KEY end
        if odetails[2] ~= ValidationTarget then return NULL_KEY end
    end
    return candidate
end

--[[ -------------------- STATE TRANSITIONS -------------------- ]]
-- SLua does not auto-clear listeners on transition; do it explicitly.

local function remove_listeners()
    if HolderListen ~= 0 then ll.ListenRemove(HolderListen); HolderListen = 0 end
    if HolderListenOC ~= 0 then ll.ListenRemove(HolderListenOC); HolderListenOC = 0 end
end

local function enter_default()
    remove_listeners()
    State = "default"
    Controller = NULL_KEY
    ModeStr = ""
    ValidationTarget = NULL_KEY
    OCPingTarget = NULL_KEY
    HolderSession = 0
    -- Persistent responder listener (answers other collars' coffle requests).
    HolderListen = ll.Listen(LEASH_CHAN_NATIVE, "", NULL_KEY, "")
    set_timer(0.0)
end

local function enter_proto_native()
    remove_listeners()
    State = "proto_native"
    HolderListen = ll.Listen(LEASH_CHAN_NATIVE, "", NULL_KEY, "")
    restartNativeProbe()
end

local function enter_proto_oc_lm()
    remove_listeners()
    State = "proto_oc_lm"
    HolderListen   = ll.Listen(LEASH_CHAN_NATIVE, "", NULL_KEY, "")
    HolderListenOC = ll.Listen(LEASH_CHAN_LM,     "", NULL_KEY, "")
    -- Legacy LM ping. OCPingTarget = leasher avatar (grab), target collar
    -- (coffle), or post root (post).
    if OCPingTarget ~= NULL_KEY then
        ll.RegionSayTo(OCPingTarget, LEASH_CHAN_LM, tostring(OCPingTarget) .. "collar")
        ll.RegionSayTo(OCPingTarget, LEASH_CHAN_LM, tostring(OCPingTarget) .. "handle")
    end
    set_timer(OC_PHASE_DURATION)
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
    enter_default()
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

_on_timer = function()
    if State == "proto_native" then
        enter_proto_oc_lm()  -- native phase timed out
    elseif State == "proto_oc_lm" then
        if OCPingTarget ~= NULL_KEY then notifyFallback(OCPingTarget) end
        enter_default()
    end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
        return
    end

    if num ~= SETTINGS_BUS then return end

    if State == "default" then
        if msg_type == "leash.proto.start" then
            if not validProtoStart(msg) then return end
            captureProtoStart(msg)
            enter_proto_native()
        end
        -- leash.proto.shutdown is a no-op when idle.
    elseif State == "proto_native" then
        if msg_type == "leash.proto.shutdown" then
            enter_default()
        elseif msg_type == "leash.proto.start" then
            -- Restart mid-probe: keep the listener open, just re-arm.
            if not validProtoStart(msg) then return end
            captureProtoStart(msg)
            restartNativeProbe()
        end
    elseif State == "proto_oc_lm" then
        if msg_type == "leash.proto.shutdown" then
            enter_default()
        elseif msg_type == "leash.proto.start" then
            if not validProtoStart(msg) then return end
            captureProtoStart(msg)
            enter_proto_native()
        end
    end
end

function LLEvents.listen(channel: number, name: string, id, msg: string)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    if channel == LEASH_CHAN_NATIVE then
        local mtype = ll.JsonGetValue(msg, {"type"})
        if mtype == "plugin.leash.request" then
            leashProtoNativeRequest(msg)
        elseif mtype == "plugin.leash.target" then
            -- Only when awaiting a reply (default ignores stray/late replies).
            if State == "proto_native" or State == "proto_oc_lm" then
                local holder = validateAndExtractHolder(msg)
                if holder ~= NULL_KEY then
                    notifyHolder(holder)
                    enter_default()
                end
            end
        end
    elseif channel == LEASH_CHAN_LM then
        if State == "proto_oc_lm" then
            -- `<UUID>handle ok` where UUID is the OCPingTarget we addressed.
            if msg == tostring(OCPingTarget) .. "handle ok" then
                notifyHolder(id)
                enter_default()
            end
        end
    end
end

-- Top-level init.
main()

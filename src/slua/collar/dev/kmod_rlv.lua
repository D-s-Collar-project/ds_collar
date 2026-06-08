--[[--------------------
SCRIPT: kmod_rlv.lua  (SLua port)
VERSION: 1.10
REVISION: 4  (SLua port rev 1)
PURPOSE: RLV subsystem. Single point of @-command emission for refcount-stateful
  RLV restrictions; owns the third-party relay protocol (RELAY_CHANNEL listen,
  auth queue, ASK dialog, per-source bookkeeping) plus a multi-consumer
  apply/release claims API for other plugins.

SLUA PORT NOTES:
- Ported from kmod_rlv.lsl rev 4. The relay protocol, RELAY_CHANNEL/4711
  wire format, ack format (<ident>,<wearer>,<command>,<ack>), and all @-command
  emission are preserved EXACTLY — OpenCollar/relay interop is non-negotiable.
- @-commands still go through ll.OwnerSay (project reserves OwnerSay for RLV);
  user-facing notices use ll.RegionSayTo.
- Idiomatic SLua:
  * 4 parallel source lists -> source records {key,name,chan,restr={behav,...}};
  * stride-2 Claims -> nested map behav -> {consumer=true}; this makes the LSL's
    separate `Baked` refcount list redundant, so it is dropped (no external reads);
  * Temp white/black lists -> sets keyed by tostring(key);
  * stride-3 Queue -> array of {ident,obj,command} records;
  * handle_command / clean_queue `jump` labels -> `continue`;
  * the dead `Hardcore` mirror (assigned, never read here) is dropped — the
    relay.hardcoremode LSD key is still persisted via SETTINGS_BUS.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900

--[[ -------------------- KMOD IDENTITY -------------------- ]]
local KMOD_CONTEXT = "kmod.rlv"

--[[ -------------------- RELAY CONSTANTS -------------------- ]]
local RELAY_CHANNEL = -1812221819
local RLV_RESP_CHANNEL = 4711

local MAX_SOURCES = 8
local MAX_QUEUE = 8

local MODE_OFF = 0
local MODE_ON  = 1
local MODE_ASK = 2

local ASK_TIMEOUT_SEC = 120
local GC_INTERVAL = 10.0
local DISTANCE_MAX = 100.0

local END_MARKER = "$$"

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_RELAY_MODE = "relay.mode"
local KEY_RELAY_HARDCORE = "relay.hardcoremode"

local RELAY_CONSUMER_PREFIX = "relay:"

--[[ -------------------- STATE -------------------- ]]
local Mode = MODE_ASK
local IsAttached = false
local RelayListenHandle = 0
local WearerKey = NULL_KEY

-- Sources: array of { key, name, chan, restr = {behav, ...} }
local Sources = {}

-- Claims: behav -> { consumer -> true }. A behav is applied iff its set is
-- non-empty (this replaces the LSL's separate Baked refcount list).
local Claims = {}

-- Session-only trust sets keyed by tostring(key).
local TempObjWhite = {}
local TempObjBlack = {}
local TempAvWhite = {}
local TempAvBlack = {}

-- Auth queue: array of { ident, obj = uuid, command }
local Queue = {}

-- Auth dialog state.
local AskListenHandle = 0
local AskDialogChan = 0
local AskExpireAt = 0

--[[ -------------------- FORWARD DECLARATIONS -------------------- ]]
local rearm_timer, behav_has_claim, claim_add, claim_remove, claim_clear
local source_consumer, find_source, add_source, add_restriction, rem_restriction
local release_source, relay_safeword_clear, auth, handle_command
local drop_queue_item, drop_queue, enqueue, dequeue, clean_queue
local show_ask_dialog, accept_ask, decline_ask, clear_pending_ask
local gc_distant_sources, apply_settings_sync, handle_relay_message
local respond_list_request, handle_ground_rez
local start_relay_listen, stop_relay_listen, update_relay_listen_state
local say_to_source, ack_source

--[[ -------------------- HELPERS -------------------- ]]

local function lsd_int(lsd_key: string, fallback: number): number
    local v = ll.LinksetDataRead(lsd_key)
    if v == "" then return fallback end
    return integer(v)
end

local function starts_with(s: string, prefix: string): boolean
    return string.sub(s, 1, #prefix) == prefix
end

local function list_find(t, v)
    for i, x in ipairs(t) do
        if x == v then return i end
    end
    return nil
end

local function slice(t, a: number, b: number)  -- 1-based inclusive
    local out = {}
    for i = a, b do out[#out + 1] = t[i] end
    return out
end

--[[ -------------------- LIFECYCLE -------------------- ]]

local function register_self()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", KMOD_CONTEXT,
        "label", "RLV Subsystem",
        "script", ll.GetScriptName(),
    }), NULL_KEY)
end

local function send_pong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.pong",
        "context", KMOD_CONTEXT,
    }), NULL_KEY)
end

--[[ -------------------- RELAY LISTEN MANAGEMENT -------------------- ]]

function start_relay_listen()
    if RelayListenHandle ~= 0 then return end
    RelayListenHandle = ll.Listen(RELAY_CHANNEL, "", NULL_KEY, "")
end

function stop_relay_listen()
    if RelayListenHandle ~= 0 then
        ll.ListenRemove(RelayListenHandle)
        RelayListenHandle = 0
    end
end

function update_relay_listen_state()
    if Mode ~= MODE_OFF and IsAttached then start_relay_listen() else stop_relay_listen() end
end

--[[ -------------------- TIMER MANAGEMENT -------------------- ]]

function rearm_timer()
    if #Sources > 0 or AskExpireAt ~= 0 then
        ll.SetTimerEvent(GC_INTERVAL)
    else
        ll.SetTimerEvent(0.0)
    end
end

--[[ -------------------- OUTBOUND CHAT -------------------- ]]

-- Region-wide targeted ack, silent in the wearer's local chat history.
function say_to_source(src, chan: number, text: string)
    ll.RegionSayTo(src, chan, text)
end

function ack_source(ident: string, src, chan: number, command: string, ack: string)
    say_to_source(src, chan, ident .. "," .. tostring(WearerKey) .. "," .. command .. "," .. ack)
end

--[[ -------------------- CLAIMS / REFCOUNT -------------------- ]]

function behav_has_claim(behav: string): boolean
    local s = Claims[behav]
    return s ~= nil and next(s) ~= nil
end

-- Add a claim; emit @behav=n if this is the first claim on behav.
function claim_add(consumer: string, behav: string)
    local s = Claims[behav]
    if s ~= nil and s[consumer] then return end  -- idempotent
    local first = (s == nil or next(s) == nil)
    if s == nil then s = {}; Claims[behav] = s end
    s[consumer] = true
    if first then ll.OwnerSay("@" .. behav .. "=n") end
end

-- Remove one claim; emit @behav=y if no claims remain.
function claim_remove(consumer: string, behav: string)
    local s = Claims[behav]
    if s == nil or not s[consumer] then return end
    s[consumer] = nil
    if next(s) == nil then
        Claims[behav] = nil
        ll.OwnerSay("@" .. behav .. "=y")
    end
end

-- Drop every claim from one consumer; emit =y for each behav that empties.
function claim_clear(consumer: string)
    for behav, s in pairs(Claims) do
        if s[consumer] then
            s[consumer] = nil
            if next(s) == nil then
                Claims[behav] = nil
                ll.OwnerSay("@" .. behav .. "=y")
            end
        end
    end
end

--[[ -------------------- RELAY-SIDE RESTRICTION TRACKING -------------------- ]]

function source_consumer(obj): string
    return RELAY_CONSUMER_PREFIX .. tostring(obj)
end

function find_source(obj)
    for i, s in ipairs(Sources) do
        if s.key == obj then return i end
    end
    return nil
end

function add_source(obj, obj_name: string, chan: number): boolean
    local idx = find_source(obj)
    if idx ~= nil then
        Sources[idx].name = obj_name
        Sources[idx].chan = chan
        return true
    end
    if #Sources >= MAX_SOURCES then return false end
    Sources[#Sources + 1] = { key = obj, name = obj_name, chan = chan, restr = {} }
    rearm_timer()
    return true
end

function add_restriction(src, behav: string)
    local idx = find_source(src)
    if idx == nil then return end
    local restr = Sources[idx].restr
    if list_find(restr, behav) == nil then restr[#restr + 1] = behav end
    claim_add(source_consumer(src), behav)
end

function rem_restriction(src, behav: string)
    local idx = find_source(src)
    if idx == nil then return end
    local restr = Sources[idx].restr
    local pos = list_find(restr, behav)
    if pos == nil then return end
    table.remove(restr, pos)
    claim_remove(source_consumer(src), behav)
end

-- Release ALL restrictions held by one source, then drop the source.
function release_source(src)
    local idx = find_source(src)
    if idx == nil then return end
    table.remove(Sources, idx)
    claim_clear(source_consumer(src))
    rearm_timer()
end

-- Wearer safeword: clear ONLY relay-sourced restrictions (per Satomi MR
-- semantics). Co-claimed behavs (plugin_restrict etc.) stay applied.
function relay_safeword_clear()
    clear_pending_ask()
    drop_queue()

    -- Snapshot keys because release_source mutates Sources.
    local snapshot = {}
    for _, s in ipairs(Sources) do snapshot[#snapshot + 1] = s.key end
    for _, k in ipairs(snapshot) do release_source(k) end

    TempObjWhite = {}
    TempObjBlack = {}
    TempAvWhite = {}
    TempAvBlack = {}

    rearm_timer()
end

--[[ -------------------- AUTH DECISION -------------------- ]]

-- Returns -1 deny, 0 ask, 1 allow.
function auth(obj_key): number
    if find_source(obj_key) ~= nil then return 1 end
    local owner = ll.GetOwnerKey(obj_key)
    if TempObjBlack[tostring(obj_key)] then return -1 end
    if TempAvBlack[tostring(owner)] then return -1 end
    if TempObjWhite[tostring(obj_key)] then return 1 end
    if TempAvWhite[tostring(owner)] then return 1 end
    if Mode == MODE_ON then return 1 end
    return 0
end

--[[ -------------------- COMMAND HANDLER (MR-style) -------------------- ]]

function handle_command(ident: string, src, chan: number, com: string, auth_ok: boolean): string
    local commands = ll.ParseString2List(com, {"|"}, {})
    local n = #commands
    local i = 1
    while i <= n do
        local command = commands[i]

        if command == END_MARKER then
            ack_source(ident, src, chan, END_MARKER, END_MARKER)
            return ""
        end

        if command == "!release" or command == "!release_fail" then
            release_source(src)
            ack_source(ident, src, chan, command, "ok")
            i += 1; continue
        end
        if command == "!version" then
            ack_source(ident, src, chan, command, "1100")
            i += 1; continue
        end
        if command == "!implversion" then
            ack_source(ident, src, chan, command, "ORG=0003/D/s Collar Relay v1.1")
            i += 1; continue
        end
        if command == "!x-orgversions" then
            ack_source(ident, src, chan, command, "ORG=0003")
            i += 1; continue
        end
        if string.sub(command, 1, 1) == "!" then
            ack_source(ident, src, chan, command, "ko")
            i += 1; continue
        end
        if string.sub(command, 1, 1) ~= "@" then
            return ll.DumpList2String(slice(commands, i, n), "|")
        end

        -- Channel commands — auto-allow.
        local is_chan_cmd = starts_with(command, "@version")
            or starts_with(command, "@get")
            or starts_with(command, "@findfolder")
        if is_chan_cmd then
            local eq = string.find(command, "=", 1, true)
            local chan_val = 0
            if eq ~= nil then chan_val = integer(string.sub(command, eq + 1)) end
            if chan_val > 0 then
                ll.OwnerSay(command)
                ack_source(ident, src, chan, command, "ok")
            else
                ack_source(ident, src, chan, command, "ko")
            end
            i += 1; continue
        end

        if command == "@clear" then
            release_source(src)
            ack_source(ident, src, chan, command, "ok")
            i += 1; continue
        end

        local subargs = ll.ParseString2List(command, {"="}, {})
        if #subargs ~= 2 then
            return ll.DumpList2String(slice(commands, i, n), "|")
        end
        local behav = string.sub(subargs[1], 2)  -- strip leading '@'
        local val = subargs[2]

        if val == "y" or val == "rem" then
            rem_restriction(src, behav)
            ack_source(ident, src, chan, command, "ok")
            i += 1; continue
        end

        if not auth_ok then
            return ll.DumpList2String(slice(commands, i, n), "|")
        end

        if val == "force" then
            ll.OwnerSay(command)
            ack_source(ident, src, chan, command, "ok")
            i += 1; continue
        end
        if val == "n" or val == "add" then
            add_source(src, ll.Key2Name(src), chan)
            add_restriction(src, behav)
            ack_source(ident, src, chan, command, "ok")
            i += 1; continue
        end

        ack_source(ident, src, chan, command, "ko")
        i += 1
    end
    return ""
end

--[[ -------------------- QUEUE -------------------- ]]

function drop_queue_item(i: number)
    table.remove(Queue, i)
end

function drop_queue()
    Queue = {}
end

function enqueue(ident: string, src, chan: number, command_chain: string)
    local decision = auth(src)
    if decision == 1 then
        handle_command(ident, src, chan, command_chain, true)
        return
    end
    if decision == -1 or #Queue >= MAX_QUEUE then
        ack_source(ident, src, chan, command_chain, "ko")
        ack_source(ident, src, chan, END_MARKER, "")
        return
    end
    Queue[#Queue + 1] = { ident = ident, obj = src, command = command_chain }
    if AskListenHandle == 0 then dequeue() end
end

function dequeue()
    local remainder = ""
    local cur_ident, cur_src
    while remainder == "" do
        if #Queue == 0 then return end
        local item = Queue[1]
        cur_ident = item.ident
        cur_src = item.obj
        local cur_chan = RLV_RESP_CHANNEL
        local sidx = find_source(cur_src)
        if sidx ~= nil then cur_chan = Sources[sidx].chan end
        remainder = handle_command(cur_ident, cur_src, cur_chan, item.command, false)
        table.remove(Queue, 1)
    end
    table.insert(Queue, 1, { ident = cur_ident, obj = cur_src, command = remainder })
    show_ask_dialog()
end

function clean_queue()
    local on_hold = {}  -- set keyed by tostring(obj)
    local i = 1
    while i <= #Queue do
        local item = Queue[i]
        local objs = tostring(item.obj)
        if on_hold[objs] then
            i += 1
        else
            local decision = auth(item.obj)
            local chan = RLV_RESP_CHANNEL
            local sidx = find_source(item.obj)
            if sidx ~= nil then chan = Sources[sidx].chan end
            if decision == 1 then
                table.remove(Queue, i)
                handle_command(item.ident, item.obj, chan, item.command, true)
            elseif decision == -1 then
                table.remove(Queue, i)
                ack_source(item.ident, item.obj, chan, item.command, "ko")
                ack_source(item.ident, item.obj, chan, END_MARKER, "")
            else
                i += 1
                on_hold[objs] = true
            end
        end
    end
end

--[[ -------------------- ASK DIALOG -------------------- ]]

function show_ask_dialog()
    AskDialogChan = -1000000 - integer(ll.Frand(1000000000.0))
    if AskListenHandle ~= 0 then ll.ListenRemove(AskListenHandle) end
    AskListenHandle = ll.Listen(AskDialogChan, "", WearerKey, "")

    local src = Queue[1].obj
    local obj_name = ll.Key2Name(src)
    local owner_name = ll.Key2Name(ll.GetOwnerKey(src))
    local body = obj_name
    if owner_name ~= "" then body = body .. ", owned by " .. owner_name .. "," end
    body = body .. " wants to apply RLV restrictions.\n\nAllow this?"

    local buttons = {
        "No", " ", "Yes",
        "Ban Object", " ", "Trust Object",
        "Ban Owner", " ", "Trust Owner",
    }

    AskExpireAt = ll.GetUnixTime() + ASK_TIMEOUT_SEC
    ll.Dialog(WearerKey, body, buttons, AskDialogChan)
    rearm_timer()
end

function accept_ask()
    local cur_src = Queue[1].obj
    TempObjWhite[tostring(cur_src)] = true
    clean_queue()
    clear_pending_ask()
    if #Queue > 0 then dequeue() end
end

function decline_ask()
    if #Queue > 0 then
        local item = Queue[1]
        local chan = RLV_RESP_CHANNEL
        local sidx = find_source(item.obj)
        if sidx ~= nil then chan = Sources[sidx].chan end
        ack_source(item.ident, item.obj, chan, item.command, "ko")
        ack_source(item.ident, item.obj, chan, END_MARKER, "")
        table.remove(Queue, 1)
    end
    clean_queue()
    clear_pending_ask()
    if #Queue > 0 then dequeue() end
end

function clear_pending_ask()
    if AskListenHandle ~= 0 then
        ll.ListenRemove(AskListenHandle)
        AskListenHandle = 0
    end
    AskDialogChan = 0
    AskExpireAt = 0
    rearm_timer()
end

--[[ -------------------- DISTANCE-BASED LIVENESS GC -------------------- ]]

function gc_distant_sources()
    local me = ll.GetRootPosition()
    -- Snapshot keys: release_source mutates Sources.
    local keys = {}
    for _, s in ipairs(Sources) do keys[#keys + 1] = s.key end
    for _, src in ipairs(keys) do
        local det = ll.GetObjectDetails(src, {OBJECT_POS})
        local pos = det[1]
        local drop = false
        if pos == nil or pos == ZERO_VECTOR then drop = true
        elseif ll.VecDist(pos, me) > DISTANCE_MAX then drop = true end
        if drop then release_source(src) end
    end
end

--[[ -------------------- SETTINGS SYNC -------------------- ]]

function apply_settings_sync()
    local prev_mode = Mode
    Mode = lsd_int(KEY_RELAY_MODE, Mode)
    if Mode ~= prev_mode then
        clear_pending_ask()
        drop_queue()
        if Mode == MODE_OFF then
            TempObjWhite = {}
            TempObjBlack = {}
            TempAvWhite = {}
            TempAvBlack = {}
        end
        update_relay_listen_state()
    end
end

--[[ -------------------- RELAY PROTOCOL ENTRY -------------------- ]]

function handle_relay_message(sender_id, raw_msg: string)
    if not IsAttached then return end

    local parsed = ll.ParseString2List(raw_msg, {"|"}, {})
    local raw_cmd = parsed[1]
    local session_chan = RLV_RESP_CHANNEL
    if #parsed > 1 then session_chan = integer(parsed[2]) end

    local parts = ll.ParseString2List(raw_cmd, {","}, {})
    if #parts ~= 3 then return end
    local ident = parts[1]
    local potential_uuid = parts[2]
    if #potential_uuid ~= 36 then return end
    if string.sub(potential_uuid, 9, 9) ~= "-" then return end
    if string.sub(potential_uuid, 14, 14) ~= "-" then return end
    if string.sub(potential_uuid, 19, 19) ~= "-" then return end
    if string.sub(potential_uuid, 24, 24) ~= "-" then return end
    local target_uuid = uuid(potential_uuid)
    local command = parts[3]

    -- Wildcard target reserved for capability probes.
    if target_uuid == uuid("ffffffff-ffff-ffff-ffff-ffffffffffff") then
        if command ~= "@version"
            and command ~= "@versionnew"
            and command ~= "!version"
            and command ~= "!implversion"
            and command ~= "!x-orgversions" then return end
    elseif target_uuid ~= WearerKey then
        return
    end

    enqueue(ident, sender_id, session_chan, string.lower(command) .. "|" .. END_MARKER)
end

--[[ -------------------- UI_BUS HANDLERS (external API) -------------------- ]]

function respond_list_request()
    local arr = {}
    for _, s in ipairs(Sources) do
        arr[#arr + 1] = ll.List2Json(JSON_OBJECT, {
            "name", s.name,
            "restr_count", tostring(#s.restr),
        })
    end
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "relay.list.response",
        "sources", ll.List2Json(JSON_ARRAY, arr),
    }), NULL_KEY)
end

function handle_ground_rez(reason: string)
    clear_pending_ask()
    drop_queue()
    TempObjWhite = {}
    TempObjBlack = {}
    TempAvWhite = {}
    TempAvBlack = {}

    Mode = MODE_OFF
    -- Persist via SETTINGS_BUS so kmod_settings owns the LSD writes.
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "settings.set", "key", KEY_RELAY_MODE, "value", tostring(MODE_OFF),
    }), NULL_KEY)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "settings.set", "key", KEY_RELAY_HARDCORE, "value", "0",
    }), NULL_KEY)

    if #Sources > 0 then relay_safeword_clear() end

    update_relay_listen_state()

    if reason ~= "" then ll.RegionSayTo(ll.GetOwner(), 0, reason .. " - Relay turned OFF") end
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end

    clear_pending_ask()
    drop_queue()
    Sources = {}
    Claims = {}
    TempObjWhite = {}
    TempObjBlack = {}
    TempAvWhite = {}
    TempAvBlack = {}

    IsAttached = ll.GetAttached() ~= 0
    WearerKey = ll.GetOwner()

    if not IsAttached then
        handle_ground_rez("Collar rezzed on ground")
    else
        Mode = lsd_int(KEY_RELAY_MODE, MODE_ASK)
        update_relay_listen_state()
    end

    register_self()
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.timer()
    if AskExpireAt ~= 0 and ll.GetUnixTime() >= AskExpireAt then
        ll.RegionSayTo(WearerKey, 0, "Auth request timed out")
        decline_ask()
    end
    if #Sources > 0 then gc_distant_sources() end
    rearm_timer()
end

function LLEvents.attach(id)
    if id == NULL_KEY then
        clear_pending_ask()
        drop_queue()
        TempObjWhite = {}
        TempObjBlack = {}
        TempAvWhite = {}
        TempAvBlack = {}
        IsAttached = false
        handle_ground_rez("")
    else
        IsAttached = true
        WearerKey = id
        update_relay_listen_state()
    end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.register.refresh" then
            register_self()
        elseif msg_type == "kernel.ping" then
            send_pong()
        elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            local ctx = ll.JsonGetValue(msg, {"context"})
            if ctx ~= JSON_INVALID and ctx ~= "" and ctx ~= KMOD_CONTEXT then return end
            ll.ResetScript()
        end
        return
    end

    if num == SETTINGS_BUS then
        if msg_type == "settings.sync" then apply_settings_sync() end
        return
    end

    if num == UI_BUS then
        if msg_type == "rlv.apply" then
            local consumer = ll.JsonGetValue(msg, {"consumer"})
            local behav = ll.JsonGetValue(msg, {"behav"})
            if consumer == JSON_INVALID or behav == JSON_INVALID then return end
            claim_add(consumer, behav)
        elseif msg_type == "rlv.release" then
            local consumer = ll.JsonGetValue(msg, {"consumer"})
            local behav = ll.JsonGetValue(msg, {"behav"})
            if consumer == JSON_INVALID or behav == JSON_INVALID then return end
            claim_remove(consumer, behav)
        elseif msg_type == "rlv.clear" then
            local consumer = ll.JsonGetValue(msg, {"consumer"})
            if consumer == JSON_INVALID then return end
            claim_clear(consumer)
        elseif msg_type == "rlv.force" then
            local command = ll.JsonGetValue(msg, {"command"})
            if command == JSON_INVALID then return end
            ll.OwnerSay(command)
        elseif msg_type == "relay.list.request" then
            respond_list_request()
        elseif msg_type == "relay.safeword" then
            relay_safeword_clear()
        elseif msg_type == "relay.ground_rez" then
            local reason = ll.JsonGetValue(msg, {"reason"})
            if reason == JSON_INVALID then reason = "" end
            handle_ground_rez(reason)
        elseif msg_type == "sos.relay.clear" then
            relay_safeword_clear()
            ll.RegionSayTo(ll.GetOwner(), 0, "Relay restrictions cleared.")
        end
        return
    end
end

function LLEvents.listen(chan: number, name: string, id, msg: string)
    if chan == RELAY_CHANNEL then
        handle_relay_message(id, msg)
        return
    end
    if chan == AskDialogChan and id == WearerKey then
        local item = Queue[1]
        if item == nil then return end
        local cur_src = item.obj
        local cur_owner = ll.GetOwnerKey(cur_src)
        if msg == "Yes" then
            accept_ask()
        elseif msg == "No" then
            decline_ask()
        elseif msg == "Trust Object" then
            TempObjWhite[tostring(cur_src)] = true
            accept_ask()
        elseif msg == "Ban Object" then
            TempObjBlack[tostring(cur_src)] = true
            decline_ask()
        elseif msg == "Trust Owner" then
            TempAvWhite[tostring(cur_owner)] = true
            accept_ask()
        elseif msg == "Ban Owner" then
            TempAvBlack[tostring(cur_owner)] = true
            decline_ask()
        end
    end
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        ll.ResetScript()
    end
end

-- Top-level init.
main()

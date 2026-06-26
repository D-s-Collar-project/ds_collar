--[[--------------------
MODULE: kmod_rlv.lua  (SLua port)
VERSION: 1.2
REVISION: 8  (SLua port rev 1)
PURPOSE: RLV subsystem. Single point of @-command emission for all refcount-stateful
  RLV restrictions in the collar. Owns the third-party RLV relay protocol
  (RELAY_CHANNEL listen, auth queue, ASK dialog, per-source bookkeeping) plus a
  multi-consumer apply/release API for other plugins.
ARCHITECTURE: thin UI shell (plugin_relay) calls in over UI_BUS; Mode/Hardcore
  persisted by kmod_settings, read from LSD on settings.sync.

SLUA PORT NOTES:
- Ported from kmod_rlv.lsl v1.2 rev 8. Wire protocol preserved exactly: the relay
  channel chatter (-1812221819) and ack format (<ident>,<wearer>,<command>,<ack>),
  the rlv.apply/release/clear/force + relay.* + safeword.fired + sos.relay.clear
  consumers (UI_BUS 900), settings.sync (SETTINGS_BUS 800), the KMOD_CONTEXT reset
  filter (KERNEL 500), and relay.list.response / relay.forceoff out. @-commands are
  emitted via ll.OwnerSay exactly as the LSL (RLV commands, the sanctioned OwnerSay).
- GOTCHA: jump labels. handle_command's per-command `jump after_send` and clean_queue's
  `jump cq_continue` become Luau `continue`; the early `return remainder` paths stay
  returns. (The LSL incremented i BEFORE the jump, so each `continue` is preceded by
  the same i = i + 1.)
- IDIOMATIC: parallel/stride lists -> records. The four Source* lists -> an array of
  {obj, name, chan, restr={}} records (per-source restrictions are a native array, not
  a "/"-joined string); stride-2 Claims -> {behav, consumer} records; stride-3 Queue ->
  {ident, src, command} records; the four Temp*White/Black trust lists -> sets keyed by
  tostring(key). Baked stays a flat behav array.
- GOTCHA: single multiplexed timer. llSetTimerEvent(GC_INTERVAL/0) via rearm_timer ->
  set_timer shim over LLTimers; the tick runs auth-dialog timeout + distance GC.
- csv_lead_int backs lsd_int + the channel-value parse; the ASK dialog channel uses
  math.floor(ll.Frand(...)) (no integer cast). uuid() normalizes protocol/JSON key
  strings. The ASK dialog is a DIRECT ll.Dialog (bypasses kmod_dialogs) so its " "
  spacer buttons are kept verbatim.
- _Hardcore is write-only within this engine (read by plugin_relay, persisted by
  kmod_settings) — kept for state shape, _-prefixed to mark intentionally-unused here.
- Single LSL state -> top-level LLEvents.*; state_entry becomes main().
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS     = 800
local UI_BUS           = 900

--[[ -------------------- KMOD IDENTITY -------------------- ]]
local KMOD_CONTEXT = "kmod.rlv"

--[[ -------------------- RELAY CONSTANTS -------------------- ]]
local RELAY_CHANNEL    = -1812221819
local RLV_RESP_CHANNEL = 4711

local MAX_SOURCES = 8
local MAX_QUEUE   = 8

local MODE_OFF = 0
local MODE_ON  = 1
local MODE_ASK = 2

local ASK_TIMEOUT_SEC = 120
local GC_INTERVAL = 10.0
local DISTANCE_MAX = 100.0

local END_MARKER = "$$"

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_RELAY_MODE     = "relay.mode"
local KEY_RELAY_HARDCORE = "relay.hardcoremode"

-- Relay sources are also Claims consumers under "relay:<uuid>".
local RELAY_CONSUMER_PREFIX = "relay:"

--[[ -------------------- STATE -------------------- ]]
local Mode = MODE_ASK
local _Hardcore = 0          -- write-only here (see notes)
local IsAttached = false
local RelayListenHandle = 0
local WearerKey = NULL_KEY

-- Relay-protocol sources.
type Source = { obj: any, name: string, chan: number, restr: {string} }
local Sources: {Source} = {}

-- Refcount set: behaviours currently applied to the viewer.
local Baked: {string} = {}

-- Multi-consumer claims. A behav stays Baked iff >=1 consumer claims it.
type Claim = { behav: string, consumer: string }
local Claims: {Claim} = {}

-- Session-only trust sets (tostring(key) -> true). Cleared on safeword/off/detach/reset.
local TempObjWhite: { [string]: boolean } = {}
local TempObjBlack: { [string]: boolean } = {}
local TempAvWhite:  { [string]: boolean } = {}
local TempAvBlack:  { [string]: boolean } = {}

-- Auth queue.
type QItem = { ident: string, src: any, command: string }
local Queue: {QItem} = {}

-- Auth dialog state.
local AskListenHandle = 0
local AskDialogChan = 0
local AskExpireAt = 0          -- unix ts; 0 = no pending dialog

--[[ -------------------- TIMER SHIM (single multiplexed timer) -------------------- ]]
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

local function csv_lead_int(s: string): number
    return tonumber(string.match(s, "^%s*(-?%d+)") or "") or 0
end

local function lsd_int(lsd_key: string, fallback: number): number
    local v = ll.LinksetDataRead(lsd_key)
    if v == "" then return fallback end
    return csv_lead_int(v)
end

local function list_has(t: {string}, v: string): boolean
    for _, x in ipairs(t) do
        if x == v then return true end
    end
    return false
end

local function list_find(t: {string}, v: string): number?
    for i, x in ipairs(t) do
        if x == v then return i end
    end
    return nil
end

--[[ -------------------- RELAY LISTEN MANAGEMENT -------------------- ]]

local function start_relay_listen()
    if RelayListenHandle ~= 0 then return end
    RelayListenHandle = ll.Listen(RELAY_CHANNEL, "", NULL_KEY, "")
end

local function stop_relay_listen()
    if RelayListenHandle ~= 0 then
        ll.ListenRemove(RelayListenHandle)
        RelayListenHandle = 0
    end
end

local function update_relay_listen_state()
    if Mode ~= MODE_OFF and IsAttached then start_relay_listen()
    else stop_relay_listen() end
end

--[[ -------------------- TIMER + QUEUE PRIMITIVES -------------------- ]]

-- Single timer multiplexes auth-dialog timeout + source distance GC.
local function rearm_timer()
    if #Sources > 0 or AskExpireAt ~= 0 then
        set_timer(GC_INTERVAL)
    else
        set_timer(0)
    end
end

local function queue_length(): number
    return #Queue
end

local function drop_queue_item(i: number)
    table.remove(Queue, i)
end

local function drop_queue()
    Queue = {}
end

local function clear_pending_ask()
    if AskListenHandle ~= 0 then
        ll.ListenRemove(AskListenHandle)
        AskListenHandle = 0
    end
    AskDialogChan = 0
    AskExpireAt = 0
    rearm_timer()
end

--[[ -------------------- OUTBOUND CHAT (targeted, history-silent) -------------------- ]]

local function say_to_source(src, chan: number, text: string)
    ll.RegionSayTo(src, chan, text)
end

-- Wire-format an ack: <ident>,<wearer>,<command>,<ack>
local function ack_source(ident: string, src, chan: number, command: string, ack: string)
    say_to_source(src, chan, ident .. "," .. tostring(WearerKey) .. "," .. command .. "," .. ack)
end

--[[ -------------------- CLAIMS / REFCOUNT -------------------- ]]

local function behav_has_claim(behav: string): boolean
    for _, c in ipairs(Claims) do
        if c.behav == behav then return true end
    end
    return false
end

-- Add a claim; emit @behav=n if this is the first claim.
local function claim_add(consumer: string, behav: string)
    for _, c in ipairs(Claims) do
        if c.behav == behav and c.consumer == consumer then return end  -- idempotent
    end
    local first = not behav_has_claim(behav)
    Claims[#Claims + 1] = { behav = behav, consumer = consumer }
    if first then
        Baked[#Baked + 1] = behav
        ll.OwnerSay("@" .. behav .. "=n")
    end
end

-- Remove one claim; emit @behav=y if no claims remain.
local function claim_remove(consumer: string, behav: string)
    for i, c in ipairs(Claims) do
        if c.behav == behav and c.consumer == consumer then
            table.remove(Claims, i)
            if not behav_has_claim(behav) then
                local bi = list_find(Baked, behav)
                if bi ~= nil then table.remove(Baked, bi) end
                ll.OwnerSay("@" .. behav .. "=y")
            end
            return
        end
    end
end

-- Drop every claim from one consumer; emit =y for any behav that loses its last claim.
local function claim_clear(consumer: string)
    local freed = {}
    for i = #Claims, 1, -1 do
        if Claims[i].consumer == consumer then
            local behav = Claims[i].behav
            table.remove(Claims, i)
            if not list_has(freed, behav) then freed[#freed + 1] = behav end
        end
    end
    for _, behav in ipairs(freed) do
        if not behav_has_claim(behav) then
            local bi = list_find(Baked, behav)
            if bi ~= nil then table.remove(Baked, bi) end
            ll.OwnerSay("@" .. behav .. "=y")
        end
    end
end

-- Drop EVERY claim (system-wide safeword). @detach/@sittp are direct, not claims,
-- so they survive.
local function claim_clear_all()
    for _, behav in ipairs(Baked) do
        ll.OwnerSay("@" .. behav .. "=y")
    end
    Baked = {}
    Claims = {}
end

--[[ -------------------- RELAY-SIDE RESTRICTION TRACKING -------------------- ]]

local function source_consumer(obj): string
    return RELAY_CONSUMER_PREFIX .. tostring(obj)
end

local function source_idx(obj): number?
    for i, s in ipairs(Sources) do
        if s.obj == obj then return i end
    end
    return nil
end

local function add_source(obj, obj_name: string, chan: number): boolean
    local idx = source_idx(obj)
    if idx ~= nil then
        Sources[idx].name = obj_name
        Sources[idx].chan = chan
        return true
    end
    if #Sources >= MAX_SOURCES then return false end
    Sources[#Sources + 1] = { obj = obj, name = obj_name, chan = chan, restr = {} }
    rearm_timer()
    return true
end

local function add_restriction(src, behav: string)
    local idx = source_idx(src)
    if idx == nil then return end
    local per_src = Sources[idx].restr
    if not list_has(per_src, behav) then
        per_src[#per_src + 1] = behav
    end
    claim_add(source_consumer(src), behav)
end

local function rem_restriction(src, behav: string)
    local idx = source_idx(src)
    if idx == nil then return end
    local per_src = Sources[idx].restr
    local pos = list_find(per_src, behav)
    if pos == nil then return end
    table.remove(per_src, pos)
    claim_remove(source_consumer(src), behav)
end

-- Release ALL restrictions held by one source, then drop the source.
local function release_source(src)
    local idx = source_idx(src)
    if idx == nil then return end
    table.remove(Sources, idx)
    claim_clear(source_consumer(src))
    rearm_timer()
end

-- Wearer-initiated safeword: clear ONLY relay-sourced restrictions (release-by-source,
-- scoped — behavs co-claimed by another consumer stay applied).
local function relay_safeword_clear()
    clear_pending_ask()
    drop_queue()

    -- Snapshot the obj keys because release_source mutates Sources.
    local snapshot = {}
    for _, s in ipairs(Sources) do snapshot[#snapshot + 1] = s.obj end
    for _, obj in ipairs(snapshot) do release_source(obj) end

    TempObjWhite = {}
    TempObjBlack = {}
    TempAvWhite = {}
    TempAvBlack = {}

    rearm_timer()
end

-- Wearer safeword, scope chosen by source. system_wide additionally drops every
-- collar-internal claim and force-stands the wearer.
local function do_safeword_clear(system_wide: boolean)
    relay_safeword_clear()
    if system_wide then
        claim_clear_all()
        ll.OwnerSay("@unsit=force")
    end
end

--[[ -------------------- AUTH DECISION -------------------- ]]

-- -1 deny, 0 ask, 1 allow.
local function auth(obj_key): number
    if source_idx(obj_key) ~= nil then return 1 end
    local owner = ll.GetOwnerKey(obj_key)
    if TempObjBlack[tostring(obj_key)] then return -1 end
    if TempAvBlack[tostring(owner)] then return -1 end
    if TempObjWhite[tostring(obj_key)] then return 1 end
    if TempAvWhite[tostring(owner)] then return 1 end
    if Mode == MODE_ON then return 1 end
    return 0
end

--[[ -------------------- COMMAND HANDLER (MR-style) -------------------- ]]

-- Returns the unprocessed remainder (commands needing auth), or "" if fully handled.
local function handle_command(ident: string, src, chan: number, com: string, auth_ok: boolean): string
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
            i = i + 1
            continue
        end
        if command == "!version" then
            ack_source(ident, src, chan, command, "1100")
            i = i + 1
            continue
        end
        if command == "!implversion" then
            ack_source(ident, src, chan, command, "ORG=0003/D/s Collar Relay v1.1")
            i = i + 1
            continue
        end
        if command == "!x-orgversions" then
            ack_source(ident, src, chan, command, "ORG=0003")
            i = i + 1
            continue
        end
        if ll.GetSubString(command, 0, 0) == "!" then
            ack_source(ident, src, chan, command, "ko")
            i = i + 1
            continue
        end
        if ll.GetSubString(command, 0, 0) ~= "@" then
            return table.concat(commands, "|", i)
        end

        -- Channel commands — auto-allow.
        local is_chan_cmd = false
        if ll.SubStringIndex(command, "@version") == 0 then is_chan_cmd = true
        elseif ll.SubStringIndex(command, "@get") == 0 then is_chan_cmd = true
        elseif ll.SubStringIndex(command, "@findfolder") == 0 then is_chan_cmd = true end
        if is_chan_cmd then
            local eq = ll.SubStringIndex(command, "=")
            local chan_val = 0
            if eq ~= -1 then chan_val = csv_lead_int(ll.GetSubString(command, eq + 1, -1)) end
            if chan_val > 0 then
                ll.OwnerSay(command)
                ack_source(ident, src, chan, command, "ok")
            else
                ack_source(ident, src, chan, command, "ko")
            end
            i = i + 1
            continue
        end

        if command == "@clear" then
            release_source(src)
            ack_source(ident, src, chan, command, "ok")
            i = i + 1
            continue
        end

        local subargs = ll.ParseString2List(command, {"="}, {})
        if #subargs ~= 2 then
            return table.concat(commands, "|", i)
        end
        local behav = ll.GetSubString(subargs[1], 1, -1)
        local val = subargs[2]

        if val == "y" or val == "rem" then
            rem_restriction(src, behav)
            ack_source(ident, src, chan, command, "ok")
            i = i + 1
            continue
        end

        if not auth_ok then
            return table.concat(commands, "|", i)
        end

        if val == "force" then
            ll.OwnerSay(command)
            ack_source(ident, src, chan, command, "ok")
            i = i + 1
            continue
        end
        if val == "n" or val == "add" then
            add_source(src, ll.Key2Name(src), chan)
            add_restriction(src, behav)
            ack_source(ident, src, chan, command, "ok")
            i = i + 1
            continue
        end
        ack_source(ident, src, chan, command, "ko")
        i = i + 1
    end
    return ""
end

--[[ -------------------- ASK DIALOG + QUEUE DRAIN -------------------- ]]

local function show_ask_dialog()
    AskDialogChan = -1000000 - math.floor(ll.Frand(1000000000.0))
    if AskListenHandle ~= 0 then ll.ListenRemove(AskListenHandle) end
    AskListenHandle = ll.Listen(AskDialogChan, "", WearerKey, "")

    local src = Queue[1].src
    local obj_name = ll.Key2Name(src)
    local owner_name = ll.Key2Name(ll.GetOwnerKey(src))
    local body = obj_name
    if owner_name ~= "" then body = body .. ", owned by " .. owner_name .. "," end
    body = body .. " wants to apply RLV restrictions.\n\nAllow this?"

    -- DIRECT dialog (not via kmod_dialogs): " " spacer buttons kept verbatim.
    local buttons = {"No", " ", "Yes",
                     "Ban Object", " ", "Trust Object",
                     "Ban Owner", " ", "Trust Owner"}

    AskExpireAt = ll.GetUnixTime() + ASK_TIMEOUT_SEC
    ll.Dialog(WearerKey, body, buttons, AskDialogChan)
    rearm_timer()
end

local function dequeue()
    local remainder = ""
    local cur_ident = ""
    local cur_src = NULL_KEY
    local cur_chan = RLV_RESP_CHANNEL
    while remainder == "" do
        if queue_length() == 0 then return end
        local item = Queue[1]
        cur_ident = item.ident
        cur_src = item.src
        local sidx = source_idx(cur_src)
        if sidx ~= nil then cur_chan = Sources[sidx].chan
        else cur_chan = RLV_RESP_CHANNEL end
        remainder = handle_command(cur_ident, cur_src, cur_chan, item.command, false)
        drop_queue_item(1)
    end
    -- Re-insert the partially-processed item at the front, then ask.
    table.insert(Queue, 1, { ident = cur_ident, src = cur_src, command = remainder })
    show_ask_dialog()
end

local function enqueue(ident: string, src, chan: number, command_chain: string)
    local decision = auth(src)
    if decision == 1 then
        handle_command(ident, src, chan, command_chain, true)
        return
    end
    if decision == -1 or queue_length() >= MAX_QUEUE then
        ack_source(ident, src, chan, command_chain, "ko")
        ack_source(ident, src, chan, END_MARKER, "")
        return
    end
    Queue[#Queue + 1] = { ident = ident, src = src, command = command_chain }
    if AskListenHandle == 0 then dequeue() end
end

local function clean_queue()
    local on_hold: { [string]: boolean } = {}
    local i = 1
    while i <= queue_length() do
        local item = Queue[i]
        local ident = item.ident
        local obj = item.src
        local command = item.command
        if on_hold[tostring(obj)] then
            i = i + 1
            continue
        end
        local decision = auth(obj)
        local chan = RLV_RESP_CHANNEL
        local sidx = source_idx(obj)
        if sidx ~= nil then chan = Sources[sidx].chan end
        if decision == 1 then
            drop_queue_item(i)
            handle_command(ident, obj, chan, command, true)
        elseif decision == -1 then
            drop_queue_item(i)
            ack_source(ident, obj, chan, command, "ko")
            ack_source(ident, obj, chan, END_MARKER, "")
        else
            i = i + 1
            on_hold[tostring(obj)] = true
        end
    end
end

local function accept_ask()
    local cur_src = Queue[1].src
    TempObjWhite[tostring(cur_src)] = true
    clean_queue()
    clear_pending_ask()
    if queue_length() > 0 then dequeue() end
end

local function decline_ask()
    local chan = RLV_RESP_CHANNEL
    if queue_length() > 0 then
        local item = Queue[1]
        local sidx = source_idx(item.src)
        if sidx ~= nil then chan = Sources[sidx].chan end
        ack_source(item.ident, item.src, chan, item.command, "ko")
        ack_source(item.ident, item.src, chan, END_MARKER, "")
        drop_queue_item(1)
    end
    clean_queue()
    clear_pending_ask()
    if queue_length() > 0 then dequeue() end
end

--[[ -------------------- DISTANCE-BASED LIVENESS GC -------------------- ]]

local function gc_distant_sources()
    local me = ll.GetRootPosition()
    for i = #Sources, 1, -1 do
        local src = Sources[i].obj
        local det = ll.GetObjectDetails(src, {OBJECT_POS})
        local drop = false
        if #det == 0 then
            drop = true
        else
            local pos = det[1]
            if pos == ZERO_VECTOR then drop = true
            elseif ll.VecDist(pos, me) > DISTANCE_MAX then drop = true end
        end
        if drop then release_source(src) end
    end
end

--[[ -------------------- SETTINGS SYNC -------------------- ]]

local function apply_settings_sync()
    local prev_mode = Mode
    Mode = lsd_int(KEY_RELAY_MODE, Mode)
    _Hardcore = lsd_int(KEY_RELAY_HARDCORE, _Hardcore)
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

local function handle_relay_message(sender_id, raw_msg: string)
    if not IsAttached then return end

    local parsed = ll.ParseString2List(raw_msg, {"|"}, {})
    local raw_cmd = parsed[1]
    local session_chan = RLV_RESP_CHANNEL
    if #parsed > 1 then session_chan = csv_lead_int(parsed[2]) end

    local parts = ll.ParseString2List(raw_cmd, {","}, {})
    if #parts ~= 3 then return end
    local ident = parts[1]
    local potential_uuid = parts[2]
    if ll.StringLength(potential_uuid) ~= 36 then return end
    if ll.GetSubString(potential_uuid,  8,  8) ~= "-" then return end
    if ll.GetSubString(potential_uuid, 13, 13) ~= "-" then return end
    if ll.GetSubString(potential_uuid, 18, 18) ~= "-" then return end
    if ll.GetSubString(potential_uuid, 23, 23) ~= "-" then return end
    local target_uuid = uuid(potential_uuid)
    local command = parts[3]

    -- Wildcard target reserved for capability probes.
    if target_uuid == uuid("ffffffff-ffff-ffff-ffff-ffffffffffff") then
        if command ~= "@version" and command ~= "@versionnew" and command ~= "!version"
            and command ~= "!implversion" and command ~= "!x-orgversions" then return end
    elseif target_uuid ~= WearerKey then
        return
    end

    local command_chain = ll.ToLower(command) .. "|" .. END_MARKER
    enqueue(ident, sender_id, session_chan, command_chain)
end

--[[ -------------------- UI_BUS HANDLERS (external API) -------------------- ]]

local function respond_list_request()
    local arr = {}
    for _, s in ipairs(Sources) do
        arr[#arr + 1] = ll.List2Json(JSON_OBJECT, {"name", s.name, "restr_count", tostring(#s.restr)})
    end
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "relay.list.response",
        "sources", ll.List2Json(JSON_ARRAY, arr),
    }), NULL_KEY)
end

local function handle_ground_rez(reason: string)
    clear_pending_ask()
    drop_queue()
    TempObjWhite = {}
    TempObjBlack = {}
    TempAvWhite = {}
    TempAvBlack = {}

    -- React in-memory at once but do NOT persist relay config (plugin_relay owns it).
    Mode = MODE_OFF
    _Hardcore = 0
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "relay.forceoff",
    }), NULL_KEY)

    if #Sources > 0 then relay_safeword_clear() end

    update_relay_listen_state()

    if reason ~= "" then ll.RegionSayTo(ll.GetOwner(), 0, reason .. " - Relay turned OFF") end
end

--[[ -------------------- TICK BODY -------------------- ]]

_on_timer = function()
    if AskExpireAt ~= 0 and ll.GetUnixTime() >= AskExpireAt then
        ll.RegionSayTo(WearerKey, 0, "Auth request timed out")
        decline_ask()
    end
    if #Sources > 0 then gc_distant_sources() end
    rearm_timer()
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    clear_pending_ask()
    drop_queue()
    Sources = {}
    Baked = {}
    Claims = {}
    TempObjWhite = {}
    TempObjBlack = {}
    TempAvWhite = {}
    TempAvBlack = {}

    IsAttached = (ll.GetAttached() ~= 0)
    WearerKey = ll.GetOwner()

    if not IsAttached then
        handle_ground_rez("Collar rezzed on ground")
    else
        Mode = lsd_int(KEY_RELAY_MODE, MODE_ASK)
        _Hardcore = lsd_int(KEY_RELAY_HARDCORE, 0)
        update_relay_listen_state()
    end
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
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
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
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
            -- Relay menu Safeword/Unbind: relay-only.
            do_safeword_clear(false)
        elseif msg_type == "safeword.fired" then
            -- The wearer's safeword: system-wide.
            do_safeword_clear(true)
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
        if Queue[1] == nil then return end  -- no pending item (defensive)
        local cur_src = Queue[1].src
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

main()

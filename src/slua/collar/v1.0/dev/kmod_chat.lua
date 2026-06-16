--[[--------------------
MODULE: kmod_chat.lua  (SLua port)
VERSION: 1.10
REVISION: 20  (SLua port rev 1)
PURPOSE: Local chat command receiver. Listens on the secondary channel (always)
         and optionally channel 0 for prefixed commands from authorised speakers,
         dispatching ui.chat.command to UI_BUS.
ARCHITECTURE: Consolidated message bus lanes

SLUA PORT NOTES:
- Ported from kmod_chat.lsl rev 20. Wire formats unchanged: ui.chat.command JSON
  on UI_BUS, the CSV settings.delta envelope to SETTINGS_BUS, and the
  "<level>|<unix>" ACL cache contract.
- Idiomatic SLua: the stride-2 CommandAliases list becomes an alias->context
  map; split_head_tail returns two values; integer-predicates return booleans.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS     = 800
local UI_BUS           = 900

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_PREFIX      = "chat.prefix"
local KEY_PUBLIC_CHAT = "chat.public"
local KEY_CHAT_CHAN   = "chat.channel"

--[[ -------------------- STATE -------------------- ]]
local ChatPrefix = ""
local PublicChat = false
local ChatChan = 1

local ListenChan0 = 0
local ListenChan1 = 0

-- alias (lowercase label) -> context. Built from kernel.register.declare and
-- chat.alias.declare broadcasts.
local Aliases = {}

--[[ -------------------- HELPERS -------------------- ]]

-- Default prefix = first two chars of the wearer's username (no spaces).
--[[ integer(): SLua has no LSL-style (integer) cast; emulate it (truncate toward zero; non-numeric -> 0). ]]
local function integer(v): number
    local n = tonumber(v)
    if n == nil then return 0 end
    if n < 0 then return math.ceil(n) end
    return math.floor(n)
end

local function derive_default_prefix(): string
    local username = ll.GetUsername(ll.GetOwner())
    if #username >= 2 then return string.lower(string.sub(username, 1, 2)) end
    if #username == 1 then return string.lower(username) end
    return "c"
end

local function reset_listeners()
    if ListenChan0 ~= 0 then ll.ListenRemove(ListenChan0); ListenChan0 = 0 end
    if ListenChan1 ~= 0 then ll.ListenRemove(ListenChan1); ListenChan1 = 0 end

    if ChatPrefix == "" then return end

    ListenChan1 = ll.Listen(ChatChan, "", NULL_KEY, "")  -- secondary always on
    if PublicChat then
        ListenChan0 = ll.Listen(0, "", NULL_KEY, "")
    end
end

--[[ -------------------- SETTINGS -------------------- ]]

local function apply_settings_sync()
    local stored_prefix = ll.LinksetDataRead(KEY_PREFIX)
    local stored_public = ll.LinksetDataRead(KEY_PUBLIC_CHAT)

    if stored_prefix ~= "" then
        ChatPrefix = stored_prefix
    else
        -- First run: derive and ask kmod_settings (sole LSD writer) to persist.
        ChatPrefix = derive_default_prefix()
        ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delta:" .. KEY_PREFIX .. ":" .. ChatPrefix, NULL_KEY)
    end

    if stored_public ~= "" then
        PublicChat = integer(stored_public) ~= 0
    else
        PublicChat = true
        ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delta:" .. KEY_PUBLIC_CHAT .. ":1", NULL_KEY)
    end

    local stored_chan = ll.LinksetDataRead(KEY_CHAT_CHAN)
    if stored_chan ~= "" then
        local parsed_chan = integer(stored_chan)
        if parsed_chan >= 1 and parsed_chan <= 9 then ChatChan = parsed_chan end
    end

    reset_listeners()
end

--[[ -------------------- COMMAND DISPATCH -------------------- ]]

-- Strip the prefix (immediately-following or whitespace-separated form);
-- return the trimmed remainder, or "" if the message doesn't start with it.
local function strip_prefix(message: string): string
    local prefix_len = #ChatPrefix
    if #message <= prefix_len then return "" end
    local head = string.lower(string.sub(message, 1, prefix_len))
    if head ~= string.lower(ChatPrefix) then return "" end
    return ll.StringTrim(string.sub(message, prefix_len + 1), STRING_TRIM)
end

-- Register a label->context alias. First registrant wins; collisions warn.
local function register_alias(label: string, context: string)
    if label == "" or context == "" then return end
    local alias = string.lower(label)
    local existing = Aliases[alias]
    if existing == nil then
        Aliases[alias] = context
    elseif existing ~= context then
        ll.RegionSayTo(ll.GetOwner(), 0, "Alias collision: '" .. alias .. "' already bound to '"
            .. existing .. "', refusing rebind to '" .. context .. "'. Namespaced form still works.")
    end
end

-- Split "pose nadu down" into head "pose" and dot-joined tail "nadu.down".
local function split_head_tail(remainder: string): (string, string)
    local tokens = ll.ParseString2List(remainder, {" ", "\t"}, {})
    local n = #tokens
    if n == 0 then return "", "" end
    if n == 1 then return tokens[1], "" end
    local tail_tokens = {}
    for i = 2, n do tail_tokens[#tail_tokens + 1] = tokens[i] end
    return tokens[1], ll.DumpList2String(tail_tokens, ".")
end

-- True if head is a known alias or an already dot-namespaced context.
local function command_is_known(head: string): boolean
    if Aliases[string.lower(head)] ~= nil then return true end
    if string.find(head, ".", 1, true) ~= nil then return true end
    return false
end

-- Resolve head via the alias table; append tail as a dot-path.
local function build_dispatched_context(head: string, tail: string): string
    local base = Aliases[string.lower(head)] or head
    if tail == "" then return base end
    return base .. "." .. tail
end

local function dispatch_command(speaker, head: string, tail: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.chat.command",
        "context", build_dispatched_context(head, tail),
        "source", "chat",
    }), speaker)
end

-- Wearer always allowed; every non-wearer needs a cache-fresh ACL >= 1.
local function speaker_authorised(speaker): boolean
    if speaker == ll.GetOwner() then return true end

    local raw = ll.LinksetDataRead("acl." .. tostring(speaker) .. ".cache")
    if raw == "" then return false end
    local sep = string.find(raw, "|", 1, true)
    if sep == nil then return false end
    local cache_ts = integer(string.sub(raw, sep + 1))
    local global_ts = integer(ll.LinksetDataRead("acl.timestamp"))
    if cache_ts < global_ts then return false end  -- stale
    return integer(string.sub(raw, 1, sep - 1)) >= 1
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end

    ListenChan0 = 0
    ListenChan1 = 0
    Aliases = {}
    apply_settings_sync()

    -- Force re-broadcast of registrations so the alias table populates
    -- regardless of startup order.
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE,
        ll.List2Json(JSON_OBJECT, {"type", "kernel.register.refresh"}), NULL_KEY)
end

function LLEvents.on_rez(param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        ll.ResetScript()
    end
end

function LLEvents.listen(channel: number, name: string, id, message: string)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    if id == ll.GetKey() then return end  -- ignore own messages

    if channel == 0 and not PublicChat then return end
    if channel ~= 0 and channel ~= ChatChan then return end

    local remainder = strip_prefix(message)
    if remainder == "" then return end

    local head, tail = split_head_tail(remainder)
    if head == "" then return end
    if not command_is_known(head) then return end
    if not speaker_authorised(id) then return end

    dispatch_command(id, head, tail)
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        elseif msg_type == "kernel.register.declare" then
            local reg_label = ll.JsonGetValue(msg, {"label"})
            local reg_context = ll.JsonGetValue(msg, {"context"})
            if reg_label ~= JSON_INVALID and reg_context ~= JSON_INVALID then
                register_alias(reg_label, reg_context)
            end
        elseif msg_type == "chat.alias.declare" then
            local a = ll.JsonGetValue(msg, {"alias"})
            local c = ll.JsonGetValue(msg, {"context"})
            if a ~= JSON_INVALID and c ~= JSON_INVALID then
                register_alias(a, c)
            end
        end
    elseif num == SETTINGS_BUS then
        if msg_type == "settings.sync" then
            apply_settings_sync()
        end
    end
end

-- Top-level init.
main()

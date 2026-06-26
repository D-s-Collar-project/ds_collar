--[[--------------------
MODULE: kmod_chat.lua  (SLua port)
VERSION: 1.2
REVISION: 7  (SLua port rev 1)
PURPOSE: Local chat command receiver. Listens on the secondary channel (always)
         and channel 0 (public chat, or wearer-scoped when public is off) for
         prefixed commands from authorised speakers, plus the wearer's prefix-free
         safeword on any heard channel. Emits ui.chat.command to UI_BUS for kmod_ui
         to route; plugins never receive the raw dispatch.
ARCHITECTURE: Consolidated message bus lanes.

SLUA PORT NOTES:
- Ported from kmod_chat.lsl v1.2 rev 7. Wire protocol preserved exactly:
  ui.chat.command (UI_BUS 900), safeword.fired / safeword.set, and the inbound
  kernel.register.refresh / kernel.register.declare / chat.alias.declare
  (KERNEL_LIFECYCLE 500) keep their JSON shapes, so LSL plugins and kmod_ui
  interoperate unchanged during the incremental port.
- IDIOMATIC: the stride-2 CommandAliases list ([alias, context, ...]) becomes a
  string-keyed dict { [alias] = context }. Every llListFindList scan collapses to
  an O(1) lookup; "first registrant wins + collision notice" falls straight out of
  a nil check; command_is_known and build_dispatched_context are now one table
  read each.
- IDIOMATIC: split_head_tail returns two values (head, tail) instead of a 2-list.
  ll.ParseString2List returns a native 1-based Lua table — indexed with t[1]/#t,
  and the dot-joined tail is table.concat(t, ".", 2).
- GOTCHA (the big one): Lua treats 0 as TRUTHY, so LSL integer-as-boolean flags
  cannot survive as numbers. PublicChat is a real Lua boolean
  (PublicChat = csv_lead_int(stored) ~= 0); a bare number would make `if PublicChat`
  always pass. csv_lead_int (the same leading-int parse kmod_auth uses) stands in
  for LSL's lenient (integer) cast, which Lua's strict tonumber() does not match.
- GOTCHA: string ops stay on ll.* (ll.GetSubString / ll.StringLength / ll.ToLower)
  to keep LSL's 0-based indexing, character (not byte) counts, and unicode-aware
  lowercasing, rather than native Lua 1-based/byte string functions.
- Listeners use ll.Listen / ll.ListenRemove + LLEvents.listen, mirroring the LSL;
  the channel-0-always-on safeword design is preserved verbatim.
- Events are top-level LLEvents.* (no states); state_entry becomes main(), called
  once at the bottom.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS     = 800
local UI_BUS           = 900

--[[ -------------------- SETTINGS KEYS -------------------- ]]
-- Must match plugin_chat.lua KEY_* constants.
local KEY_PREFIX       = "chat.prefix"
local KEY_PUBLIC_CHAT  = "chat.public"   -- "1" = enabled, "0" = disabled
local KEY_CHAT_CHAN    = "chat.channel"  -- secondary channel number (default 1)
local KEY_SAFEWORD     = "safeword.word" -- wearer's personal safeword (default "safeword")

--[[ -------------------- STATE -------------------- ]]
local ChatPrefix   = ""        -- set from settings or derived on first run
local PublicChat   = false     -- channel 0 listening enabled (REAL boolean — see notes)
local ChatChan     = 1         -- secondary channel (default 1)
local SafewordWord = "safeword"-- matched prefix-free from the wearer; absent key -> this default

local ListenChan0  = 0         -- handle for channel 0 listener (0 = inactive)
local ListenChan1  = 0         -- handle for secondary channel listener (0 = inactive)

-- alias -> context. Populated by intercepting kernel.register.declare /
-- chat.alias.declare; alias = ll.ToLower(label), context = PLUGIN_CONTEXT.
local CommandAliases: { [string]: string } = {}

--[[ -------------------- HELPERS -------------------- ]]

-- LSL (integer) cast equivalent for a leading signed integer; 0 when the string
-- has no leading int (absent record / blank flag). Same parse as kmod_auth.
local function csv_lead_int(s: string): number
    return tonumber(string.match(s, "^%s*(-?%d+)") or "") or 0
end

-- Derive a default prefix from the first two characters of the wearer's username.
-- ll.GetUsername returns "firstname.lastname" or "firstname" (no spaces).
local function derive_default_prefix(): string
    local username = ll.GetUsername(ll.GetOwner())
    local len = ll.StringLength(username)
    if len >= 2 then
        return ll.ToLower(ll.GetSubString(username, 0, 1))
    end
    if len == 1 then
        return ll.ToLower(username)
    end
    return "c"  -- fallback
end

-- Remove old listeners and establish fresh ones based on current settings.
local function reset_listeners()
    if ListenChan0 ~= 0 then
        ll.ListenRemove(ListenChan0)
        ListenChan0 = 0
    end
    if ListenChan1 ~= 0 then
        ll.ListenRemove(ListenChan1)
        ListenChan1 = 0
    end

    if ChatPrefix == "" then return end

    -- Secondary channel is always active when a prefix is set.
    ListenChan1 = ll.Listen(ChatChan, "", NULL_KEY, "")

    -- Channel 0 is ALWAYS listened so the prefix-free safeword can be heard
    -- openly / in ((ooc)) even when public commands are off. Public on -> carry
    -- everyone (for prefixed commands); public off -> scope to the wearer, so the
    -- only thing channel 0 conveys is the wearer's own safeword.
    if PublicChat then
        ListenChan0 = ll.Listen(0, "", NULL_KEY, "")
    else
        ListenChan0 = ll.Listen(0, "", ll.GetOwner(), "")
    end
end

--[[ -------------------- SETTINGS -------------------- ]]

local function apply_settings_sync()
    local stored_prefix = ll.LinksetDataRead(KEY_PREFIX)
    local stored_public = ll.LinksetDataRead(KEY_PUBLIC_CHAT)

    -- kmod_chat is a pure consumer of chat config: it READS and processes
    -- (listeners/dispatch) but never WRITES. plugin_chat owns and seeds
    -- chat.prefix/public/channel. While a key is still absent (the brief
    -- bootstrap window before plugin_chat's seed lands — seeds do not broadcast),
    -- fall back to the same in-memory default plugin_chat will seed, so listening
    -- works immediately.
    if stored_prefix ~= "" then
        ChatPrefix = stored_prefix
    else
        ChatPrefix = derive_default_prefix()
    end

    if stored_public ~= "" then
        PublicChat = (csv_lead_int(stored_public) ~= 0)
    else
        PublicChat = true
    end

    local stored_chan = ll.LinksetDataRead(KEY_CHAT_CHAN)
    if stored_chan ~= "" then
        local parsed_chan = csv_lead_int(stored_chan)
        if parsed_chan >= 1 and parsed_chan <= 9 then
            ChatChan = parsed_chan
        end
    end
    -- else: ChatChan keeps its in-script default (1).

    -- Safeword: wearer-owned (plugin_maint writes it). An absent key falls back
    -- to the default word, so the safeword works even before it's ever changed.
    local stored_sw = ll.LinksetDataRead(KEY_SAFEWORD)
    if stored_sw ~= "" then
        SafewordWord = stored_sw
    else
        SafewordWord = "safeword"
    end

    reset_listeners()
end

--[[ -------------------- COMMAND DISPATCH -------------------- ]]

-- Strip prefix from message, trim whitespace, return remainder. Prefix may be
-- immediately followed by the command ("anmenu") or separated by whitespace
-- ("an menu"). Returns "" if the message does not start with the prefix.
local function strip_prefix(message: string): string
    local prefix_len = ll.StringLength(ChatPrefix)
    if ll.StringLength(message) <= prefix_len then return "" end
    local head = ll.ToLower(ll.GetSubString(message, 0, prefix_len - 1))
    if head ~= ll.ToLower(ChatPrefix) then return "" end
    return ll.StringTrim(ll.GetSubString(message, prefix_len, -1), STRING_TRIM)
end

-- TRUE if `message` IS the wearer's safeword: whole-utterance match, a surrounding
-- (( )) OOC wrapper stripped, case-insensitive. Deliberately NOT a substring match
-- — the whole line must be the word, so conversational use never fires it.
local function is_safeword(message: string): boolean
    local s = ll.StringTrim(message, STRING_TRIM)
    if ll.StringLength(s) >= 4 and ll.GetSubString(s, 0, 1) == "((" and ll.GetSubString(s, -2, -1) == "))" then
        s = ll.StringTrim(ll.GetSubString(s, 2, -3), STRING_TRIM)
    end
    return ll.ToLower(s) == ll.ToLower(SafewordWord)
end

-- Register a label->context alias. First registrant wins; a collision surfaces as
-- an owner notice so it can be fixed at the plugin level. Namespacing makes command
-- ownership explicit, so collisions indicate a developer-side bug, not a runtime one.
local function register_alias(label: string, context: string)
    if label == "" or context == "" then return end
    local alias = ll.ToLower(label)
    local existing = CommandAliases[alias]
    if existing == nil then
        CommandAliases[alias] = context
        return
    end
    if existing ~= context then
        ll.RegionSayTo(ll.GetOwner(), 0, "Alias collision: '" .. alias ..
            "' already bound to '" .. existing .. "', refusing rebind to '" ..
            context .. "'. Namespaced form still works.")
    end
end

-- Split a command remainder into head (first whitespace-separated token) and
-- dot-joined tail tokens. "pose nadu down" -> "pose", "nadu.down". Multiple spaces
-- collapse; an empty tail returns "".
local function split_head_tail(remainder: string): (string, string)
    local tokens = ll.ParseString2List(remainder, {" ", "\t"}, {})
    local n = #tokens
    if n == 0 then return "", "" end
    if n == 1 then return tokens[1], "" end
    return tokens[1], table.concat(tokens, ".", 2)
end

-- TRUE if the head token is a known alias or itself a dot-namespaced context
-- string. Rejects natural-language false positives on chat.
local function command_is_known(head: string): boolean
    if CommandAliases[ll.ToLower(head)] ~= nil then return true end
    if ll.SubStringIndex(head, ".") ~= -1 then return true end
    return false
end

-- Resolve head via the alias table and append the tail as a dot-path.
-- "pose" + "nadu" -> "ui.core.animate.pose.nadu". Head passes through unchanged if
-- no alias matches (allows full context passthrough).
local function build_dispatched_context(head: string, tail: string): string
    local base = CommandAliases[ll.ToLower(head)] or head
    if tail == "" then return base end
    return base .. "." .. tail
end

-- Dispatch a recognised command from an authorised speaker. kmod_ui does
-- longest-prefix plugin routing and passes the remainder as subpath.
local function dispatch_command(speaker, head: string, tail: string)
    local context = build_dispatched_context(head, tail)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.chat.command",
        "context", context,
        "source", "chat",
    }), speaker)
end

-- Validate that a speaker is authorised to send chat commands (ACL >= 1), computed
-- live from the user-record roster. Wearer is always allowed. A user.<uuid> record's
-- leading field is the acl; strangers without a record pass only when public mode is
-- on. No cache, no staleness window.
local function speaker_authorised(speaker): boolean
    if speaker == ll.GetOwner() then return true end
    local rec = ll.LinksetDataRead("user." .. tostring(speaker))
    if rec ~= "" then return csv_lead_int(rec) >= 1 end
    return csv_lead_int(ll.LinksetDataRead("public.mode")) ~= 0
end

--[[ -------------------- EVENTS -------------------- ]]
-- In SLua these top-level functions are the event handlers (no states).

local function main()
    ListenChan0    = 0
    ListenChan1    = 0
    CommandAliases = {}
    apply_settings_sync()
    -- Force all scripts to re-broadcast kernel.register so the alias table is
    -- populated regardless of startup order.
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.refresh",
    }), NULL_KEY)
end

function LLEvents.listen(channel: number, name: string, id, message: string)
    -- Ignore own messages.
    if id == ll.GetKey() then return end
    if channel ~= 0 and channel ~= ChatChan then return end

    -- -------- Safeword (wearer only, prefix-free, ACL-bypassing) --------
    -- Heard before any prefix/dispatch logic, so it works at ANY ACL — TPE
    -- included — on every channel we hear (public 0 + private).
    if id == ll.GetOwner() then
        -- The bare safeword word (OOC-tolerant: ((red)) survives @sendchat=n) is a
        -- symbolic link to "<prefix> safeword" — both invoke the FULL safeword.
        if is_safeword(message) then
            ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
                "type", "safeword.fired",
            }), ll.GetOwner())
            return
        end
        -- "<prefix> safeword"        -> invoke the full safeword.
        -- "<prefix> safeword <word>" -> change the safeword word (plugin_maint
        -- writes). Both bypass the ACL-gated dispatch on purpose (TPE-proof).
        local sw_rem = strip_prefix(message)
        if sw_rem ~= "" then
            local sw_tok = ll.ParseString2List(sw_rem, {" ", "\t"}, {})
            if ll.ToLower(sw_tok[1] or "") == "safeword" then
                if #sw_tok >= 2 then
                    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
                        "type", "safeword.set",
                        "word", sw_tok[2],
                    }), ll.GetOwner())
                else
                    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
                        "type", "safeword.fired",
                    }), ll.GetOwner())
                end
                return
            end
        end
    end

    -- -------- Normal prefixed command dispatch (ACL-gated) --------
    -- Channel 0 carries commands only when public chat is on; when off it conveyed
    -- only the safeword above.
    if channel == 0 and not PublicChat then return end

    local remainder = strip_prefix(message)
    if remainder == "" then return end

    -- Split into head + dot-joined tail tokens. Validate the head: a known alias or
    -- an already dot-namespaced context passes. Rejects natural words on both channels.
    local head, tail = split_head_tail(remainder)
    if head == "" then return end
    if not command_is_known(head) then return end

    if not speaker_authorised(id) then return end

    dispatch_command(id, head, tail)
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        elseif msg_type == "kernel.register.declare" then
            local reg_label   = ll.JsonGetValue(msg, {"label"})
            local reg_context = ll.JsonGetValue(msg, {"context"})
            if reg_label ~= JSON_INVALID and reg_context ~= JSON_INVALID then
                register_alias(reg_label, reg_context)
            end
        elseif msg_type == "chat.alias.declare" then
            -- Plugin-declared subcommand alias (e.g. "pose" for animate). Consumed
            -- only by kmod_chat; invisible to the kernel plugin list.
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

function LLEvents.on_rez(param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        ll.ResetScript()
    end
end

-- Top-level init: SLua runs this once at script start in place of state_entry.
main()

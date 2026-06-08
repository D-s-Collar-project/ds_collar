/*--------------------
MODULE: kmod_chat.lsl
VERSION: 1.2
REVISION: 0
PURPOSE: Local chat command receiver. Listens on channel 1 (always) and
         optionally channel 0 (public chat) for prefixed commands from
         authorised speakers. Sends ui.chat.command to UI_BUS so kmod_ui
         can route the request; plugins never receive the raw dispatch.
ARCHITECTURE: Consolidated message bus lanes
--------------------*/

/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS     = 800;
integer UI_BUS           = 900;

/* -------------------- SETTINGS KEYS -------------------- */
// Must match plugin_chat.lsl KEY_* constants.
string KEY_PREFIX       = "chat.prefix";
string KEY_PUBLIC_CHAT  = "chat.public";  // "1" = enabled, "0" = disabled
string KEY_CHAT_CHAN    = "chat.channel"; // secondary channel number (default 1)

/* -------------------- STATE -------------------- */
string ChatPrefix    = "";   // Set from settings or derived on first run
integer PublicChat   = FALSE; // Channel 0 listening enabled
integer ChatChan     = 1;    // Secondary channel (default 1)

integer ListenChan0  = 0;    // Handle for channel 0 listener (0 = inactive)
integer ListenChan1  = 0;    // Handle for secondary channel listener (0 = inactive)

// Stride-2 list: [alias, context, alias, context, ...]
// Populated by intercepting kernel.register broadcasts from plugins and kmod_ui.
// alias = llToLower(label), context = PLUGIN_CONTEXT.
list CommandAliases = [];

/* -------------------- HELPERS -------------------- */

// Derive a default prefix from the first two characters of the wearer's username.
// llGetUsername() returns "firstname.lastname" or "firstname" (no spaces).
string derive_default_prefix() {
    string username = llGetUsername(llGetOwner());
    if (llStringLength(username) >= 2) {
        return llToLower(llGetSubString(username, 0, 1));
    }
    if (llStringLength(username) == 1) {
        return llToLower(username);
    }
    return "c";  // fallback
}

// Remove old listeners and establish fresh ones based on current settings.
reset_listeners() {
    if (ListenChan0 != 0) {
        llListenRemove(ListenChan0);
        ListenChan0 = 0;
    }
    if (ListenChan1 != 0) {
        llListenRemove(ListenChan1);
        ListenChan1 = 0;
    }

    if (ChatPrefix == "") return;

    // Secondary channel is always active when a prefix is set
    ListenChan1 = llListen(ChatChan, "", NULL_KEY, "");

    // Channel 0 only if explicitly enabled
    if (PublicChat) {
        ListenChan0 = llListen(0, "", NULL_KEY, "");
    }
}

/* -------------------- SETTINGS -------------------- */

apply_settings_sync() {
    string stored_prefix = llLinksetDataRead(KEY_PREFIX);
    string stored_public  = llLinksetDataRead(KEY_PUBLIC_CHAT);

    if (stored_prefix != "") {
        ChatPrefix = stored_prefix;
    }
    else {
        // First run: derive from username and request kmod_settings persist it.
        // Single-writer settings.delta CSV protocol — kmod_settings sole LSD writer.
        ChatPrefix = derive_default_prefix();
        llMessageLinked(LINK_SET, SETTINGS_BUS,
            "settings.delta:" + KEY_PREFIX + ":" + ChatPrefix, NULL_KEY);
    }

    if (stored_public != "") {
        PublicChat = (integer)stored_public;
    }
    else {
        PublicChat = TRUE;
        llMessageLinked(LINK_SET, SETTINGS_BUS,
            "settings.delta:" + KEY_PUBLIC_CHAT + ":1", NULL_KEY);
    }

    string stored_chan = llLinksetDataRead(KEY_CHAT_CHAN);
    if (stored_chan != "") {
        integer parsed_chan = (integer)stored_chan;
        if (parsed_chan >= 1 && parsed_chan <= 9) {
            ChatChan = parsed_chan;
        }
    }

    reset_listeners();
}

/* -------------------- COMMAND DISPATCH -------------------- */

// Strip prefix from message, trim whitespace, return remainder.
// Prefix may be immediately followed by the command ("anmenu") or separated
// by whitespace ("an menu") — both forms are accepted.
// Returns "" if message does not start with the prefix.
string strip_prefix(string message) {
    integer prefix_len = llStringLength(ChatPrefix);
    if (llStringLength(message) <= prefix_len) return "";
    string head = llToLower(llGetSubString(message, 0, prefix_len - 1));
    if (head != llToLower(ChatPrefix)) return "";
    return llStringTrim(llGetSubString(message, prefix_len, -1), STRING_TRIM);
}

// Register a label→context alias. First registrant wins; a collision
// surfaces as an owner notice so it can be fixed at the plugin level.
// Namespacing makes command ownership explicit (e.g. "pose" belongs to
// animate), so collisions indicate a developer-side bug rather than a
// runtime concern.
register_alias(string label, string context) {
    if (label == "" || context == "") return;
    string alias = llToLower(label);
    integer idx = llListFindList(CommandAliases, [alias]);
    if (idx == -1) {
        CommandAliases += [alias, context];
        return;
    }
    string existing = llList2String(CommandAliases, idx + 1);
    if (existing != context) {
        llRegionSayTo(llGetOwner(), 0, "Alias collision: '" + alias + "' already bound to '" +
                   existing + "', refusing rebind to '" + context +
                   "'. Namespaced form still works.");
    }
}

// Split a command remainder into head (first whitespace-separated token)
// and dot-joined tail tokens. "pose nadu down" -> ["pose", "nadu.down"].
// Multiple spaces collapse; an empty tail returns "".
list split_head_tail(string remainder) {
    list tokens = llParseString2List(remainder, [" ", "\t"], []);
    integer n = llGetListLength(tokens);
    if (n == 0) return ["", ""];
    if (n == 1) return [llList2String(tokens, 0), ""];
    string head = llList2String(tokens, 0);
    string tail = llDumpList2String(llList2List(tokens, 1, -1), ".");
    return [head, tail];
}

// Returns TRUE if the head token is a known alias or itself a dot-namespaced
// context string. Used to reject natural-language false positives on chat.
integer command_is_known(string head) {
    string lower = llToLower(head);
    if (llListFindList(CommandAliases, [lower]) != -1) return TRUE;
    if (llSubStringIndex(head, ".") != -1) return TRUE;
    return FALSE;
}

// Resolve head via alias table and append the tail as a dot-path.
// "pose" + "nadu" -> "ui.core.animate.pose.nadu"
// Head unchanged if no alias matches (allows full context passthrough).
string build_dispatched_context(string head, string tail) {
    string lower = llToLower(head);
    string base = head;
    integer idx = llListFindList(CommandAliases, [lower]);
    if (idx != -1) base = llList2String(CommandAliases, idx + 1);
    if (tail == "") return base;
    return base + "." + tail;
}

// Dispatch a recognised command from an authorised speaker.
// Head resolves through the alias table; tail tokens are appended as a
// dot-path so "pose nadu" becomes "ui.core.animate.pose.nadu". kmod_ui
// does longest-prefix plugin routing and passes the remainder as subpath.
dispatch_command(key speaker, string head, string tail) {
    string context = build_dispatched_context(head, tail);

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "ui.chat.command",
        "context", context,
        "source",  "chat"
    ]), speaker);
}

// Validate that a speaker is authorised to send chat commands.
// Wearer is always allowed. Every non-wearer must have a CACHE-FRESH cached
// ACL >= 1 (public or higher), regardless of channel — protects the private
// channel from griefers who guess the channel number, as well as public
// chat. A cache entry is fresh when its timestamp >= the global
// acl.timestamp epoch written by kmod_auth on every settings change. Stale
// entries (e.g. left over if the wipe chain ever regresses) are rejected.
integer speaker_authorised(key speaker) {
    key wearer = llGetOwner();
    if (speaker == wearer) return TRUE;

    string raw = llLinksetDataRead("acl." + (string)speaker + ".cache");
    if (raw == "") return FALSE;
    integer sep = llSubStringIndex(raw, "|");
    if (sep == -1) return FALSE;
    integer cache_ts = (integer)llGetSubString(raw, sep + 1, -1);
    integer global_ts = (integer)llLinksetDataRead("acl.timestamp");
    if (cache_ts < global_ts) return FALSE;  // pre-dates last ACL change
    integer level = (integer)llGetSubString(raw, 0, sep - 1);
    return (level >= 1);
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        if (llGetObjectDesc() == "COLLAR_UPDATER") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        ListenChan0 = 0;
        ListenChan1 = 0;
        CommandAliases = [];
        apply_settings_sync();
        // Force all scripts to re-broadcast kernel.register so the alias table
        // is populated regardless of startup order.
        llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
            "type", "kernel.register.refresh"
        ]), NULL_KEY);
    }

    on_rez(integer param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }

    listen(integer channel, string name, key id, string message) {
        // Ignore own messages
        if (id == llGetKey()) return;

        // Validate channel scope
        if (channel == 0 && !PublicChat) return;
        if (channel != 0 && channel != ChatChan) return;

        // Strip prefix
        string remainder = strip_prefix(message);
        if (remainder == "") return;

        // Split into head + dot-joined tail tokens. Validate the head:
        // a known alias or an already dot-namespaced context passes.
        // This rejects natural words on both channels (e.g. "and").
        list parts = split_head_tail(remainder);
        string head = llList2String(parts, 0);
        string tail = llList2String(parts, 1);
        if (head == "") return;
        if (!command_is_known(head)) return;

        // Validate speaker authorisation
        if (!speaker_authorised(id)) return;

        dispatch_command(id, head, tail);
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
            else if (msg_type == "kernel.register.declare") {
                string reg_label   = llJsonGetValue(msg, ["label"]);
                string reg_context = llJsonGetValue(msg, ["context"]);
                if (reg_label != JSON_INVALID && reg_context != JSON_INVALID) {
                    register_alias(reg_label, reg_context);
                }
            }
            else if (msg_type == "chat.alias.declare") {
                // Plugin-declared subcommand alias (e.g. "pose" for animate).
                // Consumed only by kmod_chat; invisible to the kernel plugin list.
                string a = llJsonGetValue(msg, ["alias"]);
                string c = llJsonGetValue(msg, ["context"]);
                if (a != JSON_INVALID && c != JSON_INVALID) {
                    register_alias(a, c);
                }
            }
        }
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync") {
                apply_settings_sync();
            }
        }
    }
}

/*--------------------
MODULE: kmod_chat.lsl
VERSION: 1.2
REVISION: 7
CHANGES:
- v1.2 rev 7: personal safeword. The wearer's configured safeword.word (prefix-free, whole-utterance, (( ))-stripped so ((red)) survives @sendchat=n, case-insensitive) on any heard channel → emits safeword.fired (the full release — kmod_rlv + leash engine + restrict/outfit/folder + plugin_maint each handle their own slice; no central orchestrator). "<prefix> safeword" (no arg) is a symbolic link to the bare word (also safeword.fired); "<prefix> safeword <word>" → safeword.set (plugin_maint writes the new word). All three are intercepted BEFORE the ACL-gated dispatch so they work at any ACL incl TPE. Channel 0 is now ALWAYS listened — scoped to the wearer when public chat is off — so the open/((ooc)) safeword can't be disabled by turning public commands off.
- v1.2 rev 6: revision baseline normalized to rev 6 (no functional change this rev).
- v1.2 rev 1: speaker_authorised computes live from the user-record roster (user.<uuid> leading acl field; strangers pass only with public.mode on) — replaces the acl.<uuid>.cache + acl.timestamp freshness check, which no longer exists.
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
string KEY_SAFEWORD     = "safeword.word"; // wearer's personal safeword (default "safeword")

/* -------------------- STATE -------------------- */
string ChatPrefix    = "";   // Set from settings or derived on first run
integer PublicChat   = FALSE; // Channel 0 listening enabled
integer ChatChan     = 1;    // Secondary channel (default 1)
string SafewordWord  = "safeword"; // matched prefix-free from the wearer; absent key -> this default

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

    // Channel 0 is ALWAYS listened so the prefix-free safeword can be heard
    // openly / in ((ooc)) even when public commands are off. Public on -> carry
    // everyone (for prefixed commands); public off -> scope to the wearer, so the
    // only thing channel 0 conveys is the wearer's own safeword.
    if (PublicChat) {
        ListenChan0 = llListen(0, "", NULL_KEY, "");
    }
    else {
        ListenChan0 = llListen(0, "", llGetOwner(), "");
    }
}

/* -------------------- SETTINGS -------------------- */

apply_settings_sync() {
    string stored_prefix = llLinksetDataRead(KEY_PREFIX);
    string stored_public  = llLinksetDataRead(KEY_PUBLIC_CHAT);

    // kmod_chat is a pure consumer of chat config: it READS the values and
    // processes them (listeners/dispatch) but never WRITES them. plugin_chat
    // owns and seeds chat.prefix/public/channel. When a key is still absent
    // (the brief bootstrap window before plugin_chat's seed lands — seeds do
    // not broadcast, so we are not notified of it), fall back to the same
    // in-memory default plugin_chat will seed, so listening works immediately.
    if (stored_prefix != "") {
        ChatPrefix = stored_prefix;
    }
    else {
        ChatPrefix = derive_default_prefix();
    }

    if (stored_public != "") {
        PublicChat = (integer)stored_public;
    }
    else {
        PublicChat = TRUE;
    }

    string stored_chan = llLinksetDataRead(KEY_CHAT_CHAN);
    if (stored_chan != "") {
        integer parsed_chan = (integer)stored_chan;
        if (parsed_chan >= 1 && parsed_chan <= 9) {
            ChatChan = parsed_chan;
        }
    }
    // else: ChatChan keeps its in-script default (1).

    // Safeword: wearer-owned (plugin_maint writes it). An absent key falls back
    // to the default word, so the safeword works even before it's ever changed.
    string stored_sw = llLinksetDataRead(KEY_SAFEWORD);
    if (stored_sw != "") SafewordWord = stored_sw;
    else                 SafewordWord = "safeword";

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

// TRUE if `message` IS the wearer's safeword: whole-utterance match, a
// surrounding (( )) OOC wrapper stripped, case-insensitive. Deliberately NOT a
// substring match — the whole line must be the word, so conversational use
// ("I might red out") never fires it.
integer is_safeword(string message) {
    string s = llStringTrim(message, STRING_TRIM);
    if (llStringLength(s) >= 4 && llGetSubString(s, 0, 1) == "((" && llGetSubString(s, -2, -1) == "))") {
        s = llStringTrim(llGetSubString(s, 2, -3), STRING_TRIM);
    }
    return (llToLower(s) == llToLower(SafewordWord));
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

// Validate that a speaker is authorised to send chat commands (ACL >= 1),
// computed live from the user-record roster — protects the private channel
// from griefers who guess the channel number, as well as public chat.
// Wearer is always allowed. A user.<uuid> record's leading field is the
// acl (5 owner / 3 trustee / -1 blacklist); strangers without a record
// pass only when public mode is on. No cache, no staleness window.
integer speaker_authorised(key speaker) {
    key wearer = llGetOwner();
    if (speaker == wearer) return TRUE;

    string rec = llLinksetDataRead("user." + (string)speaker);
    if (rec != "") return ((integer)rec >= 1);
    return (integer)llLinksetDataRead("public.mode");
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {

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
        if (channel != 0 && channel != ChatChan) return;

        // -------- Safeword (wearer only, prefix-free, ACL-bypassing) --------
        // Heard before any prefix/dispatch logic, so it works at ANY ACL — TPE
        // included — on every channel we hear (public 0 + private).
        if (id == llGetOwner()) {
            // The bare safeword word (OOC-tolerant: ((red)) survives @sendchat=n)
            // is a symbolic link to "<prefix> safeword" — both invoke the FULL
            // safeword. The RLV/leash engines + plugin_maint listen for it.
            if (is_safeword(message)) {
                llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                    "type", "safeword.fired"
                ]), llGetOwner());
                return;
            }
            // "<prefix> safeword"        -> invoke the full safeword.
            // "<prefix> safeword <word>" -> change the safeword word (plugin_maint
            // writes). Both bypass the ACL-gated dispatch on purpose (TPE-proof).
            string sw_rem = strip_prefix(message);
            if (sw_rem != "") {
                list sw_tok = llParseString2List(sw_rem, [" ", "\t"], []);
                if (llToLower(llList2String(sw_tok, 0)) == "safeword") {
                    if (llGetListLength(sw_tok) >= 2) {
                        llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                            "type", "safeword.set",
                            "word", llList2String(sw_tok, 1)
                        ]), llGetOwner());
                    }
                    else {
                        llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                            "type", "safeword.fired"
                        ]), llGetOwner());
                    }
                    return;
                }
            }
        }

        // -------- Normal prefixed command dispatch (ACL-gated) --------
        // Channel 0 carries commands only when public chat is on; when off it
        // conveyed only the safeword above.
        if (channel == 0 && !PublicChat) return;

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

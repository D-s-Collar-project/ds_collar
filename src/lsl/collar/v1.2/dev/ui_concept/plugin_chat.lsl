/*--------------------
PLUGIN: plugin_chat.lsl
VERSION: 1.2
REVISION: 8
PURPOSE: Configuration UI for kmod_chat — change command prefix and toggle
         public chat (channel 0) listening.
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.2 rev 8 (sandbox): has_nav 0 → 1 so the menu service reserves the full nav row (<< >> Back) — Set Prefix/Channel/Toggle no longer spill into row0 (all menus need nav). Added a fallback redraw in handle_dialog_response for the now-present inert <</>> on this single-page menu.
- v1.2 rev 7 (sandbox): render via kmod_menu (ui.menu.render) instead of ui.dialog.open — the plugin_bell model. show_main hands over content buttons only; kmod_menu adds the Back nav + layout. handle_dialog_response falls back to the button label for the nav Back (was the "back" context). Textbox prompts (Set Prefix/Channel) unchanged.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. See collar_kernel rev 6.
--------------------*/

/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS     = 800;
integer UI_BUS           = 900;
integer DIALOG_BUS       = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.chat";
string PLUGIN_LABEL   = "Chat";

/* -------------------- SETTINGS KEYS -------------------- */
// Must match kmod_chat.lsl KEY_* constants.
string KEY_PREFIX      = "chat.prefix";
string KEY_PUBLIC_CHAT = "chat.public";
string KEY_CHAT_CHAN   = "chat.channel";

/* -------------------- CONSTANTS -------------------- */
float   INPUT_TIMEOUT = 30.0;

/* -------------------- STATE -------------------- */
string  ChatPrefix   = "";
integer PublicChat   = FALSE;
integer ChatChan     = 1;

key    CurrentUser    = NULL_KEY;
integer UserAcl       = 0;
list   gPolicyButtons = [];
string SessionId      = "";
string MenuContext    = "";
integer InputListen   = 0;

/* -------------------- HELPERS -------------------- */

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

list get_policy_buttons(string ctx, integer acl) {
    string policy = llLinksetDataRead("acl.policycontext:" + ctx);
    if (policy == "") return [];
    string csv = llJsonGetValue(policy, [(string)acl]);
    if (csv == JSON_INVALID) return [];
    return llCSV2List(csv);
}

integer btn_allowed(string label) {
    return (llListFindList(gPolicyButtons, [label]) != -1);
}

/* -------------------- LIFECYCLE -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "Options";
integer PLUGIN_ACL_MASK = 48;

register_self() {
    // Per-button visibility policy. Was written straight to LSD here; now
    // announced to the kernel, which is the SOLE writer of acl.policycontext
    // (and reg.<ctx>) — see collar_kernel rev 6.
    string policy = llList2Json(JSON_OBJECT, [
        "4", "Set Prefix,Set Channel,Toggle Public",
        "5", "Set Prefix,Set Channel,Toggle Public"
    ]);

    // Register with kernel (for ping/pong health tracking and alias table).
    // The kernel writes reg.<ctx> + the policy to LSD itself, draining its
    // queue serially — no concurrent write burst.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName(),
        "cat", PLUGIN_CATEGORY,
        "mask", (string)PLUGIN_ACL_MASK,
        "policy", policy
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

cleanup_session() {
    if (InputListen != 0) {
        llListenRemove(InputListen);
        InputListen = 0;
    }
    llSetTimerEvent(0.0);

    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }

    SessionId     = "";
    CurrentUser   = NULL_KEY;
    UserAcl       = 0;
    gPolicyButtons = [];
    MenuContext   = "";
}

/* -------------------- SETTINGS -------------------- */

// Derive the default prefix from the first two characters of the wearer's
// username. llGetUsername() returns "firstname.lastname" or "firstname" (no
// spaces). kmod_chat keeps an identical derive for its own in-memory fallback;
// duplication across scripts is the LSL norm (no shared code).
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

// v1.2 seed-default: write this plugin's default into LSD only if absent
// (no broadcast). plugin_chat OWNS chat.* config — the engine kmod_chat only
// reads and processes it. chat.prefix's default is computed (the wearer's
// initials), so we derive it here and seed the result.
seed_def(string lsd_key, string value) {
    if (llLinksetDataRead(lsd_key) == "")
        llMessageLinked(LINK_SET, SETTINGS_BUS, "settings.seed:" + lsd_key + ":" + value, NULL_KEY);
}

apply_settings_sync() {
    seed_def(KEY_PREFIX, derive_default_prefix());
    seed_def(KEY_PUBLIC_CHAT, "1");
    seed_def(KEY_CHAT_CHAN, "1");

    string stored_prefix = llLinksetDataRead(KEY_PREFIX);
    string stored_public  = llLinksetDataRead(KEY_PUBLIC_CHAT);

    if (stored_prefix != "") ChatPrefix = stored_prefix;
    if (stored_public != "") PublicChat = (integer)stored_public;
    string stored_chan = llLinksetDataRead(KEY_CHAT_CHAN);
    if (stored_chan != "") ChatChan = (integer)stored_chan;
}

persist_prefix(string new_prefix) {
    ChatPrefix = new_prefix;
    // Single-writer settings.delta CSV protocol — kmod_settings sole LSD writer.
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + KEY_PREFIX + ":" + new_prefix, NULL_KEY);
}

persist_chat_chan(integer new_chan) {
    ChatChan = new_chan;
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + KEY_CHAT_CHAN + ":" + (string)new_chan, NULL_KEY);
}

persist_public_chat(integer enabled) {
    PublicChat = enabled;
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + KEY_PUBLIC_CHAT + ":" + (string)enabled, NULL_KEY);
}

/* -------------------- UI -------------------- */

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user", (string)CurrentUser
    ]), NULL_KEY);
    cleanup_session();
}

show_main() {
    SessionId    = generate_session_id();
    MenuContext  = "main";
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    string public_label;
    if (PublicChat) {
        public_label = "Public: ON";
    }
    else {
        public_label = "Public: OFF";
    }

    string prefix_display = ChatPrefix;
    if (prefix_display == "") prefix_display = "(none)";

    string body = "Chat Commands\n\nPrefix: " + prefix_display +
                  "\nChannel: " + (string)ChatChan +
                  "\nPublic chat: " + public_label +
                  "\n\nChannel " + (string)ChatChan + " is the private channel." +
                  "\nChannel 0 allows public commands.";

    // Content buttons only — kmod_menu adds the Back nav and lays out the rows.
    list button_data = [];
    if (btn_allowed("Set Prefix"))    button_data += [btn("Set Prefix",   "set_prefix")];
    if (btn_allowed("Set Channel"))   button_data += [btn("Set Channel",  "set_channel")];
    if (btn_allowed("Toggle Public")) button_data += [btn(public_label,   "toggle_public")];

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.render",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "menu_type", PLUGIN_CONTEXT,
        "title", PLUGIN_LABEL,
        "body", body,
        "category", PLUGIN_CATEGORY,
        "has_nav", 1,
        "buttons", llList2Json(JSON_ARRAY, button_data)
    ]), NULL_KEY);
}

prompt_for_channel() {
    MenuContext = "input_channel";

    if (InputListen != 0) llListenRemove(InputListen);
    integer input_chan = -1 - (integer)llFrand(2000000);
    InputListen = llListen(input_chan, "", CurrentUser, "");
    llSetTimerEvent(INPUT_TIMEOUT);

    llTextBox(CurrentUser,
        "Enter secondary channel number (1-9, not 0).\nLeave blank or type 'cancel' to abort.",
        input_chan);
}

prompt_for_prefix() {
    MenuContext = "input_prefix";

    if (InputListen != 0) llListenRemove(InputListen);
    // Use a random negative channel so concurrent textboxes don't collide
    integer input_chan = -1 - (integer)llFrand(2000000);
    InputListen = llListen(input_chan, "", CurrentUser, "");
    llSetTimerEvent(INPUT_TIMEOUT);

    llTextBox(CurrentUser,
        "Enter new prefix (1-8 characters).\nLeave blank or type 'cancel' to abort.",
        input_chan);
}

/* -------------------- DIALOG HANDLER -------------------- */

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

    key user = (key)llJsonGetValue(msg, ["user"]);
    if (user != CurrentUser) return;

    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";
    // The nav Back arrives with an empty context — fall back to the label.
    if (ctx == "") {
        string navb = llJsonGetValue(msg, ["button"]);
        if (navb != JSON_INVALID) ctx = navb;
    }

    if (MenuContext == "main") {
        if (ctx == "Back") {
            return_to_root();
        }
        else if (ctx == "set_channel") {
            if (!btn_allowed("Set Channel")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            prompt_for_channel();
        }
        else if (ctx == "set_prefix") {
            if (!btn_allowed("Set Prefix")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            prompt_for_prefix();
        }
        else if (ctx == "toggle_public") {
            if (!btn_allowed("Toggle Public")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            if (PublicChat) {
                persist_public_chat(FALSE);
                llRegionSayTo(CurrentUser, 0, "Public chat commands disabled.");
            }
            else {
                persist_public_chat(TRUE);
                llRegionSayTo(CurrentUser, 0, "Public chat commands enabled.");
            }
            show_main();
        }
        else {
            // Unknown button (e.g. the inert << >> on a single-page menu) —
            // just redraw.
            show_main();
        }
    }
}

handle_dialog_timeout(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
    cleanup_session();
}

/* -------------------- CHAT INPUT HANDLER -------------------- */

handle_channel_input(string raw) {
    if (InputListen != 0) {
        llListenRemove(InputListen);
        InputListen = 0;
    }
    llSetTimerEvent(0.0);

    raw = llStringTrim(raw, STRING_TRIM);

    if (raw == "cancel" || raw == "") {
        llRegionSayTo(CurrentUser, 0, "Cancelled.");
        show_main();
        return;
    }

    integer new_chan = (integer)raw;
    if (new_chan < 1 || new_chan > 9) {
        llRegionSayTo(CurrentUser, 0, "Invalid channel. Must be 1-9.");
        show_main();
        return;
    }

    persist_chat_chan(new_chan);
    llRegionSayTo(CurrentUser, 0, "Channel set to: " + (string)new_chan);
    show_main();
}

handle_prefix_input(string new_prefix) {
    if (InputListen != 0) {
        llListenRemove(InputListen);
        InputListen = 0;
    }
    llSetTimerEvent(0.0);

    new_prefix = llStringTrim(new_prefix, STRING_TRIM);

    if (new_prefix == "cancel" || new_prefix == "") {
        llRegionSayTo(CurrentUser, 0, "Cancelled.");
        show_main();
        return;
    }

    if (llStringLength(new_prefix) > 8) {
        llRegionSayTo(CurrentUser, 0, "Prefix too long (max 8 characters). Try again.");
        show_main();
        return;
    }

    persist_prefix(new_prefix);
    llRegionSayTo(CurrentUser, 0, "Prefix set to: " + new_prefix);
    show_main();
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {

        cleanup_session();
        apply_settings_sync();
        register_self();
    }

    on_rez(integer param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }

    timer() {
        if (InputListen != 0) {
            llListenRemove(InputListen);
            InputListen = 0;
        }
        llSetTimerEvent(0.0);
        if (CurrentUser != NULL_KEY) {
            llRegionSayTo(CurrentUser, 0, "Input timed out.");
        }
        show_main();
    }

    listen(integer channel, string name, key id, string message) {
        if (id != CurrentUser) return;
        if (MenuContext == "input_prefix")  handle_prefix_input(message);
        else if (MenuContext == "input_channel") handle_channel_input(message);
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.register.refresh") {
                register_self();
                apply_settings_sync();
            }
            else if (msg_type == "kernel.ping") {
                send_pong();
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync") {
                apply_settings_sync();
            }
        }
        else if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                string context = llJsonGetValue(msg, ["context"]);
                if (context != PLUGIN_CONTEXT) return;
                // Ignore raw dispatches from kmod_chat (no acl field).
                // Only process messages already routed through kmod_ui.
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                integer req_acl = (integer)llJsonGetValue(msg, ["acl"]);
                if (req_acl < 4) {
                    llRegionSayTo(id, 0, "Access denied.");
                    return;
                }
                CurrentUser = id;
                UserAcl = req_acl;
                show_main();
            }
        }
        else if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                handle_dialog_response(msg);
            }
            else if (msg_type == "ui.dialog.timeout") {
                handle_dialog_timeout(msg);
            }
        }
    }
}

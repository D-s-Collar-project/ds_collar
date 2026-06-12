/*--------------------
PLUGIN: plugin_status.lsl
VERSION: 1.2
REVISION: 0
PURPOSE: Read-only collar status display for owners and observers
ARCHITECTURE: Consolidated message bus lanes. Access gated by the primary
  collar ACL check (kmod_ui visibility + dispatch against acl.policycontext);
  no per-button policy — view-only, the sole button is Back.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.status";
string PLUGIN_LABEL = "Status";

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_MULTI_OWNER_MODE  = "access.multiowner";
string KEY_OWNER             = "access.owner";
string KEY_OWNER_NAME        = "access.ownername";
string KEY_OWNER_HONORIFIC   = "access.ownerhonorific";
string KEY_OWNER_UUIDS       = "access.owneruuids";
string KEY_OWNER_NAMES       = "access.ownernames";
string KEY_OWNER_HONORIFICS  = "access.ownerhonorifics";
string KEY_TRUSTEE_UUIDS     = "access.trusteeuuids";
string KEY_TRUSTEE_NAMES     = "access.trusteenames";
string KEY_TRUSTEE_HONORIFICS = "access.trusteehonorifics";
string KEY_PUBLIC_ACCESS     = "public.mode";
string KEY_LOCKED            = "lock.locked";
string KEY_TPE_MODE          = "tpe.mode";
string KEY_CHAT_PREFIX       = "chat.prefix";
string KEY_CHAT_PUBLIC       = "chat.public";
string KEY_CHAT_CHAN         = "chat.channel";

/* -------------------- STATE -------------------- */
// Session management
key CurrentUser = NULL_KEY;
string SessionId = "";

/* -------------------- HELPERS -------------------- */

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

// llCSV2List("") returns [""] (length 1), not []. This wrapper returns a
// truly empty list when the LSD key is unset/empty.
list csv_read(string lsd_key) {
    string raw = llLinksetDataRead(lsd_key);
    if (raw == "") return [];
    return llCSV2List(raw);
}

/* -------------------- LIFECYCLE MANAGEMENT -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "Standalone";
integer PLUGIN_ACL_MASK = 62;

write_plugin_reg(string label) {
    string k = "reg." + PLUGIN_CONTEXT;
    string v = llList2Json(JSON_OBJECT, [
        "cat",    PLUGIN_CATEGORY,
        "label",  label,
        "script", llGetScriptName(),
        "mask",   PLUGIN_ACL_MASK
    ]);
    // Skip the write (and its linkset_data event) when the stored value
    // is already what we would write. Idempotent re-registrations on
    // state_entry or kernel.register.refresh then no longer trigger
    // kmod_ui's debounced rebuild + session invalidation.
    if (llLinksetDataRead(k) == v) return;
    llLinksetDataWrite(k, v);
}

register_self() {
    // Write button visibility policy to LSD (view-only, empty button lists for all ACL levels)
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "",
        "2", "",
        "3", "",
        "4", "",
        "5", ""
    ]));

    // Self-declared menu presence for kmod_ui.
    write_plugin_reg(PLUGIN_LABEL);

    // Register with kernel (for ping/pong health tracking and alias table).
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);

    // Declare chat alias.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "status",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* -------------------- STATUS REPORT BUILDING -------------------- */

// Reads all data fresh from LSD on each call. No cache, no async name
// resolution — kmod_settings keeps names current in LSD.
string build_status_report() {
    string status_text = "Collar Status:\n\n";

    integer multi_mode = (integer)llLinksetDataRead(KEY_MULTI_OWNER_MODE);

    // Owner information
    if (multi_mode) {
        list uuids = csv_read(KEY_OWNER_UUIDS);
        list names = csv_read(KEY_OWNER_NAMES);
        list hons  = csv_read(KEY_OWNER_HONORIFICS);
        integer owner_count = llGetListLength(uuids);

        if (owner_count > 0) {
            status_text += "Owners:\n";
            integer i;
            for (i = 0; i < owner_count; i++) {
                string nm = "";
                if (i < llGetListLength(names)) nm = llList2String(names, i);
                string hn = "";
                if (i < llGetListLength(hons)) hn = llList2String(hons, i);
                if (hn != "") status_text += "  " + hn + " " + nm + "\n";
                else          status_text += "  " + nm + "\n";
            }
        }
        else {
            status_text += "Owners: Uncommitted\n";
        }
    }
    else {
        string owner_uuid = llLinksetDataRead(KEY_OWNER);
        if (owner_uuid != "") {
            string nm = llLinksetDataRead(KEY_OWNER_NAME);
            string hn = llLinksetDataRead(KEY_OWNER_HONORIFIC);
            if (hn != "") status_text += "Owner: " + hn + " " + nm + "\n";
            else          status_text += "Owner: " + nm + "\n";
        }
        else {
            status_text += "Owner: Uncommitted\n";
        }
    }

    // Trustee information
    list trustee_uuids = csv_read(KEY_TRUSTEE_UUIDS);
    list trustee_names = csv_read(KEY_TRUSTEE_NAMES);
    list trustee_hons  = csv_read(KEY_TRUSTEE_HONORIFICS);
    integer trustee_count = llGetListLength(trustee_uuids);

    if (trustee_count > 0) {
        status_text += "Trustees:\n";
        integer i;
        for (i = 0; i < trustee_count; i++) {
            string nm = "";
            if (i < llGetListLength(trustee_names)) nm = llList2String(trustee_names, i);
            string hn = "";
            if (i < llGetListLength(trustee_hons)) hn = llList2String(trustee_hons, i);
            if (hn != "") status_text += "  " + hn + " " + nm + "\n";
            else          status_text += "  " + nm + "\n";
        }
    }
    else {
        status_text += "Trustees: none\n";
    }

    // Public access
    if ((integer)llLinksetDataRead(KEY_PUBLIC_ACCESS)) status_text += "Public Access: On\n";
    else                                                status_text += "Public Access: Off\n";

    // Lock status
    if ((integer)llLinksetDataRead(KEY_LOCKED)) status_text += "Collar locked: Yes\n";
    else                                         status_text += "Collar locked: No\n";

    // TPE mode
    if ((integer)llLinksetDataRead(KEY_TPE_MODE)) status_text += "TPE Mode: On\n";
    else                                           status_text += "TPE Mode: Off\n";

    // Chat commands
    string chat_prefix = llLinksetDataRead(KEY_CHAT_PREFIX);
    if (chat_prefix == "") chat_prefix = "(auto)";
    string chat_chan_raw = llLinksetDataRead(KEY_CHAT_CHAN);
    string chat_chan;
    if (chat_chan_raw == "") chat_chan = "1";
    else chat_chan = chat_chan_raw;
    string chat_public_label;
    if ((integer)llLinksetDataRead(KEY_CHAT_PUBLIC)) chat_public_label = "on";
    else chat_public_label = "off";
    status_text += "Chat prefix: " + chat_prefix + "  channel: " + chat_chan + "  public: " + chat_public_label + "\n";

    return status_text;
}

/* -------------------- UI / MENU SYSTEM -------------------- */

show_status_menu() {
    SessionId = generate_session_id();

    string status_report = build_status_report();

    list buttons = ["Back"];
    string buttons_json = llList2Json(JSON_ARRAY, buttons);

    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL,
        "message", status_report,
        "buttons", buttons_json,
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(string button) {
    if (button == "Back") {
        ui_return_root();
        cleanup_session();
        return;
    }

    // Unknown button - shouldn't happen
}

/* -------------------- UI NAVIGATION -------------------- */

ui_return_root() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- SESSION CLEANUP -------------------- */

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    CurrentUser = NULL_KEY;
    SessionId = "";
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {

        cleanup_session();
        register_self();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num == KERNEL_LIFECYCLE) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "kernel.register.refresh") {
                register_self();
                return;
            }

            if (msg_type == "kernel.ping") {
                send_pong();
                return;
            }

            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) return;
                }
                llLinksetDataDelete("reg." + PLUGIN_CONTEXT);
                llLinksetDataDelete("acl.policycontext:" + PLUGIN_CONTEXT);
                llResetScript();
            }

            return;
        }

        if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                if (id == NULL_KEY) return;

                // Reject non-empty subpath — no action-level subcommands here.
                string sp = llJsonGetValue(msg, ["subpath"]);
                if (sp != JSON_INVALID && sp != "") {
                    llRegionSayTo(id, 0, "Unknown status subcommand: " + sp);
                    return;
                }

                CurrentUser = id;
                show_status_menu();
                return;
            }

            return;
        }

        if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.dialog.response") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

                string button = llJsonGetValue(msg, ["button"]);
                if (button == JSON_INVALID) return;

                string user_str = llJsonGetValue(msg, ["user"]);
                if (user_str == JSON_INVALID) return;
                key user = (key)user_str;

                if (user != CurrentUser) return;

                handle_button_click(button);
                return;
            }

            if (msg_type == "ui.dialog.timeout") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

                cleanup_session();
                return;
            }

            return;
        }
    }
}

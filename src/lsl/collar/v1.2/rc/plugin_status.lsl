/*--------------------
PLUGIN: plugin_status.lsl
VERSION: 1.2
REVISION: 8
CHANGES:
- v1.2 rev 8: status is an informational dialog, not a navigable menu — render via the new kmod_menu "info" mode (single OK, no nav row; see kmod_menu rev 13); OK closes the UI. Dropped the dead ui_return_root.
- v1.2 rev 7: render via kmod_menu (ui.menu.render) instead of building ui.dialog.open directly — the plugin_bell model. Hands over title + body only; kmod_menu owns the Back nav + layout. No behavior change (kmod_dialogs renders body, falls back to message); sheds the local button assembly.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. Status STILL declares its present-but-empty per-ACL policy (levels 1-5) — the kmod_ui dispatch gate authorizes on policy presence, so omitting it denied all access. See collar_kernel rev 6.
- v1.2 rev 1: Owner/trustee display enumerates the user-record roster (user.<uuid>, rank-ordered) instead of the retired access.owner-/trustee- keys; mode label stays on the notecard-only access.multiowner policy flag.
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
// Rosters enumerate from user.<uuid> records (see role_lines). The mode
// label reads the notecard-only multi-owner policy flag.
string KEY_MULTI_OWNER_MODE  = "access.multiowner";
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

/* -------------------- LIFECYCLE MANAGEMENT -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "Standalone";
integer PLUGIN_ACL_MASK = 62;

register_self() {
    // Status is view-only (no action buttons), BUT kmod_ui's dispatch gate
    // authorizes on acl.policycontext PRESENCE plus a per-ACL entry — it is
    // NOT driven by the view mask. So we must still declare a policy carrying
    // an (empty) entry for every ACL level allowed to open it: mask 62 = ACL
    // 1-5. Omitting it = "Access denied" for everyone. Empty CSV = "may view,
    // zero action buttons."
    string policy = llList2Json(JSON_OBJECT, [
        "1", "", "2", "", "3", "", "4", "", "5", ""
    ]);

    // The kernel is the SOLE writer of reg.<ctx> + acl.policycontext (rev 6).
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName(),
        "cat", PLUGIN_CATEGORY,
        "mask", (string)PLUGIN_ACL_MASK,
        "policy", policy
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

// Format every "<Honorific> Name" line for one role from the user-record
// roster (user.<uuid> = "<acl>,<rank>,<name>,<honorific>"), rank-sorted.
string role_lines(integer want_acl) {
    list rows = [];   // strided [rank, name, honorific]
    list ks = llLinksetDataFindKeys("^user\\.", 0, -1);
    integer i = 0;
    integer n = llGetListLength(ks);
    while (i < n) {
        string rec = llLinksetDataRead(llList2String(ks, i));
        if ((integer)rec == want_acl) {
            list f = llCSV2List(rec);
            rows += [(integer)llList2String(f, 1), llList2String(f, 2), llList2String(f, 3)];
        }
        i += 1;
    }
    if (llGetListLength(rows) > 3) rows = llListSortStrided(rows, 3, 0, TRUE);

    string out = "";
    n = llGetListLength(rows);
    i = 0;
    while (i < n) {
        string nm = llList2String(rows, i + 1);
        string hn = llList2String(rows, i + 2);
        if (hn != "") out += "  " + hn + " " + nm + "\n";
        else          out += "  " + nm + "\n";
        i += 3;
    }
    return out;
}

// Reads all data fresh from LSD on each call. No cache, no async name
// resolution — kmod_settings keeps record names current.
string build_status_report() {
    string status_text = "Collar Status:\n\n";

    // Owner information (mode label = the notecard-only policy flag)
    string owner_block = role_lines(5);
    if (owner_block != "") {
        if ((integer)llLinksetDataRead(KEY_MULTI_OWNER_MODE)) {
            status_text += "Owners:\n" + owner_block;
        }
        else {
            // Single-owner: one line, inline label
            status_text += "Owner:" + llGetSubString(owner_block, 2, -1);
        }
    }
    else {
        status_text += "Owner: Uncommitted\n";
    }

    // Trustee information
    string trustee_block = role_lines(3);
    if (trustee_block != "") {
        status_text += "Trustees:\n" + trustee_block;
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

    // Status is a view-only INFO dialog, not a navigable menu: render via the
    // kmod_menu info mode — title + body + a single OK, no nav row. OK returns
    // context "ok" on DIALOG_BUS and we close the UI.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.render",
        "mode", "info",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "menu_type", PLUGIN_CONTEXT,
        "title", PLUGIN_LABEL,
        "body", status_report
    ]), NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(string button) {
    // The info dialog's single OK closes the UI (info dialogs aren't navigable).
    if (button == "OK") cleanup_session();
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
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
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

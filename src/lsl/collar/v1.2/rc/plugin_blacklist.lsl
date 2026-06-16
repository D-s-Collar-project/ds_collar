/*--------------------
PLUGIN: plugin_blacklist.lsl
VERSION: 1.2
REVISION: 6
PURPOSE: Blacklist management with sensor-based avatar selection
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. See collar_kernel rev 6.
- v1.2 rev 2: Read the user-record roster (kmod_settings rev 2): blacklist = user.<uuid> records with acl -1, enumerated name-sorted into parallel Blacklist/BlacklistNames caches on settings.sync. Names come from the record (no fallback chain needed). Mutation messages unchanged.
- v1.2 rev 1: Show Blklst button (policy-gated, ACL 2-5); names captured at add-time ("name" field on settings.blacklist.add); sensor radius 5 → 20 m.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.blacklist";
string PLUGIN_LABEL = "Blacklist";

/* -------------------- CONSTANTS -------------------- */
integer MAX_NUMBERED_LIST_ITEMS = 11;  // 12 dialog buttons - 1 Back button

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner
*/

/* -------------------- SETTINGS KEYS -------------------- */
// The roster lives in user.<uuid> = "<acl>,<rank>,<name>,<honorific>"
// records (kmod_settings rev 2); blacklist entries carry acl -1. This
// plugin enumerates them read-only (see apply_settings_sync); mutations
// go through the settings.blacklist.add/remove messages as before.

/* -------------------- UI CONSTANTS -------------------- */
string BTN_BACK = "Back";
string BTN_ADD = "+Blacklist";
string BTN_REMOVE = "-Blacklist";
string BTN_SHOW = "Show Blklst";
float BLACKLIST_RADIUS = 20.0;

/* -------------------- STATE -------------------- */
// Roster cache (rebuilt from user.* records on settings.sync): parallel
// uuid/name lists, name-sorted for stable display order.
list Blacklist = [];
list BlacklistNames = [];

// Session management
key CurrentUser = NULL_KEY;
integer CurrentUserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";
string MenuContext = "";  // "main", "add_scan", "add_pick", "remove"

// Sensor results
list CandidateKeys = [];

/* -------------------- HELPERS -------------------- */

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

string generate_session_id() {
    return "blacklist_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

/* -------------------- LSD POLICY HELPER -------------------- */
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

// Entry labels for list/remove dialogs — the names cached from the user
// records by apply_settings_sync, parallel to Blacklist.
list blacklist_names() {
    return BlacklistNames;
}

/* -------------------- LIFECYCLE -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "Access";
integer PLUGIN_ACL_MASK = 60;

register_self() {
    // Per-button visibility policy. Was written straight to LSD here; now
    // announced to the kernel, which is the SOLE writer of acl.policycontext
    // (and reg.<ctx>) — see collar_kernel rev 6. Owned+ can manage blacklist.
    string policy = llList2Json(JSON_OBJECT, [
        "2", "+Blacklist,-Blacklist,Show Blklst",
        "3", "+Blacklist,-Blacklist,Show Blklst",
        "4", "+Blacklist,-Blacklist,Show Blklst",
        "5", "+Blacklist,-Blacklist,Show Blklst"
    ]);

    // Announce full registration. The kernel writes reg.<ctx> + the policy to
    // LSD itself, draining its queue serially — no concurrent write burst.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName(),
        "cat", PLUGIN_CATEGORY,
        "mask", (string)PLUGIN_ACL_MASK,
        "policy", policy
    ]), NULL_KEY);

    // Declare chat alias.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "blacklist",
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

/* -------------------- SETTINGS MANAGEMENT -------------------- */

apply_settings_sync() {
    // Enumerate blacklist records (acl -1), name-sorted via a strided
    // [name, uuid] sort so display order is stable and human-friendly.
    list ranked = [];
    list ks = llLinksetDataFindKeys("^user\\.", 0, -1);
    integer i = 0;
    integer n = llGetListLength(ks);
    while (i < n) {
        string k = llList2String(ks, i);
        string rec = llLinksetDataRead(k);
        if ((integer)rec == -1) {
            list f = llCSV2List(rec);
            ranked += [llList2String(f, 2), llGetSubString(k, 5, -1)];
        }
        i += 1;
    }
    if (llGetListLength(ranked) > 2) {
        ranked = llListSortStrided(ranked, 2, 0, TRUE);
    }
    Blacklist = [];
    BlacklistNames = [];
    n = llGetListLength(ranked);
    i = 0;
    while (i < n) {
        BlacklistNames += [llList2String(ranked, i)];
        Blacklist += [llList2String(ranked, i + 1)];
        i += 2;
    }
}

// name_str: resolved at add-time while the avatar is in-region (display
// name, username fallback); kmod_settings persists it parallel to the UUID.
send_blacklist_add(string uuid_str, string name_str) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.blacklist.add",
        "uuid", uuid_str,
        "name", name_str
    ]), NULL_KEY);
}

send_blacklist_remove(string uuid_str) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.blacklist.remove",
        "uuid", uuid_str
    ]), NULL_KEY);
}

/* -------------------- MENU DISPLAY -------------------- */

show_main_menu() {
    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, CurrentUserAcl);

    integer count = llGetListLength(Blacklist);
    string body = "Blacklist Management\n\n";
    body += "Currently blacklisted: " + (string)count;

    list button_data = [btn(BTN_BACK, "back")];
    if (btn_allowed("+Blacklist")) button_data += [btn(BTN_ADD, "add")];
    if (btn_allowed("-Blacklist")) button_data += [btn(BTN_REMOVE, "remove")];
    if (btn_allowed("Show Blklst")) button_data += [btn(BTN_SHOW, "show")];

    SessionId = generate_session_id();
    MenuContext = "main";

    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Blacklist",
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

// Chat subcommand handler. Enters the add-scan or remove-list flow as
// if the corresponding main-menu button was clicked.
handle_subpath(key user, integer acl_level, string subpath) {
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);

    CurrentUser = user;
    CurrentUserAcl = acl_level;
    MenuContext = "main";

    if (subpath == "add") {
        if (!btn_allowed("+Blacklist")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        gPolicyButtons = [];
        MenuContext = "add_scan";
        CandidateKeys = [];
        llSensor("", NULL_KEY, AGENT, BLACKLIST_RADIUS, PI);
        return;
    }
    if (subpath == "rem") {
        if (!btn_allowed("-Blacklist")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        gPolicyButtons = [];
        show_remove_menu();
        return;
    }

    gPolicyButtons = [];
    llRegionSayTo(user, 0, "Unknown blacklist subcommand: " + subpath);
}

// Read-only listing of the blacklist (Show Blklst). Names from the
// persisted CSV via blacklist_names(); truncated near llDialog's ~511-byte
// body cap with a "… and N more" summary line. Back returns to main.
show_list_menu() {
    integer count = llGetListLength(Blacklist);
    string body = "Blacklisted avatars: " + (string)count + "\n";

    if (count == 0) {
        body += "\n(none)";
    }
    else {
        list names = blacklist_names();
        integer i = 0;
        while (i < count) {
            string line = "\n• " + llList2String(names, i);
            if (llStringLength(body) + llStringLength(line) > 440) {
                body += "\n… and " + (string)(count - i) + " more";
                i = count;
            }
            else {
                body += line;
                i += 1;
            }
        }
    }

    SessionId = generate_session_id();
    MenuContext = "show";

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Blacklist",
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, [btn(BTN_BACK, "back")]),
        "timeout", 60
    ]), NULL_KEY);
}

show_remove_menu() {
    if (llGetListLength(Blacklist) == 0) {
        llRegionSayTo(CurrentUser, 0, "Blacklist is empty.");
        show_main_menu();
        return;
    }

    list names = blacklist_names();

    SessionId = generate_session_id();
    MenuContext = "remove";

    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Remove from Blacklist",
        "prompt", "Select avatar to remove:",
        "items", llList2Json(JSON_ARRAY, names),
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

show_add_candidates() {
    if (llGetListLength(CandidateKeys) == 0) {
        llRegionSayTo(CurrentUser, 0, "No nearby avatars found.");
        show_main_menu();
        return;
    }

    // Build list of names
    list names = [];
    integer i = 0;
    while (i < llGetListLength(CandidateKeys) && i < MAX_NUMBERED_LIST_ITEMS) {
        key k = (key)llList2String(CandidateKeys, i);
        string name = llGetDisplayName(k);
        if (name == "") name = (string)k;
        names += [name];
        i += 1;
    }

    SessionId = generate_session_id();
    MenuContext = "add_pick";

    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Add to Blacklist",
        "prompt", "Select avatar to blacklist:",
        "items", llList2Json(JSON_ARRAY, names),
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

/* -------------------- NAVIGATION -------------------- */

return_to_root() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
    cleanup_session();
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
    CurrentUserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
    MenuContext = "";
    CandidateKeys = [];
}

/* -------------------- DIALOG HANDLERS -------------------- */

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["button"]) == JSON_INVALID) return;

    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;

    string cmd = llJsonGetValue(msg, ["context"]);
    if (cmd == JSON_INVALID || cmd == "") cmd = llJsonGetValue(msg, ["button"]);

    // Handle Back button (context-routed or numbered_list Back)
    if (cmd == "back" || cmd == BTN_BACK) {
        if (MenuContext == "main") {
            return_to_root();
            return;
        }
        show_main_menu();
        return;
    }

    // Main menu actions
    if (MenuContext == "main") {
        if (cmd == "add") {
            MenuContext = "add_scan";
            CandidateKeys = [];
            llSensor("", NULL_KEY, AGENT, BLACKLIST_RADIUS, PI);
            return;
        }
        if (cmd == "remove") {
            show_remove_menu();
            return;
        }
        if (cmd == "show") {
            show_list_menu();
            return;
        }
    }

    // Remove menu - numbered selection
    if (MenuContext == "remove") {
        integer idx = (integer)cmd - 1;
        if (idx >= 0 && idx < llGetListLength(Blacklist)) {
            send_blacklist_remove(llList2String(Blacklist, idx));
            llRegionSayTo(CurrentUser, 0, "Removed from blacklist.");
        }
        show_main_menu();
        return;
    }

    // Add pick menu - numbered selection
    if (MenuContext == "add_pick") {
        integer idx = (integer)cmd - 1;
        if (idx >= 0 && idx < llGetListLength(CandidateKeys)) {
            string entry = llList2String(CandidateKeys, idx);
            if (entry != "") {
                // Resolve the name NOW, while the avatar is in-region from
                // the sensor pass (display name, username fallback) — this
                // is what kmod_settings persists alongside the UUID.
                string nm = llGetDisplayName((key)entry);
                if (nm == "") nm = llGetUsername((key)entry);
                send_blacklist_add(entry, nm);
                llRegionSayTo(CurrentUser, 0, "Added to blacklist.");
            }
        }
        show_main_menu();
        return;
    }

    // Unknown context - return to main
    show_main_menu();
}

handle_dialog_timeout(string msg) {
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session == JSON_INVALID) return;
    if (session != SessionId) return;
    cleanup_session();
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {

        cleanup_session();
        register_self();
        apply_settings_sync();
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
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        if (num == KERNEL_LIFECYCLE) {
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

        /* -------------------- SETTINGS BUS -------------------- */
        if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync") {
                apply_settings_sync();
                return;
            }

            return;
        }

        /* -------------------- UI START -------------------- */
        if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                integer acl = (integer)llJsonGetValue(msg, ["acl"]);

                string subpath = "";
                string sp = llJsonGetValue(msg, ["subpath"]);
                if (sp != JSON_INVALID) subpath = sp;

                if (subpath != "") {
                    handle_subpath(id, acl, subpath);
                    return;
                }

                // User wants to start this plugin
                CurrentUser = id;
                CurrentUserAcl = acl;
                show_main_menu();
                return;
            }

            return;
        }

        /* -------------------- DIALOG RESPONSES -------------------- */
        if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                handle_dialog_response(msg);
                return;
            }

            if (msg_type == "ui.dialog.timeout") {
                handle_dialog_timeout(msg);
                return;
            }

            return;
        }
    }

    sensor(integer count) {
        if (CurrentUser == NULL_KEY) return;
        if (MenuContext != "add_scan") return;

        list candidates = [];
        key owner = llGetOwner();
        integer i = 0;

        while (i < count) {
            key k = llDetectedKey(i);
            string entry = (string)k;

            if (k != owner && llListFindList(Blacklist, [entry]) == -1) {
                candidates += [entry];
            }
            i += 1;
        }

        CandidateKeys = candidates;
        show_add_candidates();
    }

    no_sensor() {
        if (CurrentUser == NULL_KEY) return;
        if (MenuContext != "add_scan") return;

        CandidateKeys = [];
        show_add_candidates();
    }
}

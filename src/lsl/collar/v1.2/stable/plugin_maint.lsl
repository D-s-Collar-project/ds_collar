/*--------------------
PLUGIN: plugin_maint.lsl
VERSION: 1.2
REVISION: 7
CHANGES:
- v1.2 rev 7: menu-service migration (last raw-dialog plugin). show_main_menu → pager (ui.menu.render, has_nav=1; the maintenance actions are content, local Back dropped to the service nav row); the three Yes/No confirms (Reset Config / Clear Leash / Update Collar) → modal mode (No-first, returns confirm/cancel — unchanged routing). Sends moved DIALOG_BUS→UI_BUS; response handler falls back to the button label for nav, routes Back via "back"/"Back", and redraws on the inert << >>. View Settings / Access List stay on chat (long dumps exceed a dialog's 511-char body). Action logic untouched.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. See collar_kernel rev 6.
- v1.2 rev 1: Settings view enumerates owners/trustees from the user-record roster (user.<uuid>, rank-ordered, fmt_role_person_lines) instead of the retired access.owner-/trustee- keys; mode label stays on the notecard-only access.multiowner policy flag.
PURPOSE: Maintenance and utility functions for collar management
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer REMOTE_BUS = 600;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.maintenance";
string PLUGIN_LABEL = "Maintenance";

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner
*/

/* -------------------- INVENTORY ITEMS -------------------- */
string HUD_ITEM = "Control HUD";
string MANUAL_NOTECARD = "D/s Collar User Manual";

/* -------------------- STATE -------------------- */
key CurrentUser = NULL_KEY;
integer CurrentUserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";
string MenuContext = "main";

// Carries the first-responder updater key and version between scan result
// and user confirmation. Cleared by cleanup_session.
key UpdateScanUpdater = NULL_KEY;
string UpdateScanVersion = "";

/* -------------------- HELPERS -------------------- */

string generate_session_id() {
    return "maint_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
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

/* -------------------- LIFECYCLE -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "Options";
integer PLUGIN_ACL_MASK = 62;

register_self() {
    // Per-button visibility policy (default-deny per ACL level). Was written
    // straight to LSD here; now announced to the kernel, which is the SOLE
    // writer of acl.policycontext (and reg.<ctx>) — see collar_kernel rev 6.
    // Update Collar gated to wearer (ACL 2/4) and primary owner (ACL 5).
    // Trustees (ACL 3) deliberately excluded — updates rewrite scripts and
    // are wearer/owner business. TPE wearer becomes ACL 0 and gets nothing
    // here, so no runtime tpe.mode check is needed.
    string policy = llList2Json(JSON_OBJECT, [
        "1", "Get HUD,User Manual",
        "2", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual,Reset Config,Update Collar",
        "3", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual",
        "4", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual,Reset Config,Update Collar",
        "5", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual,Update Collar"
    ]);

    // Announce full registration. The kernel writes reg.<ctx> + the policy to
    // LSD itself, draining its queue serially — no concurrent write burst.
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
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* -------------------- MENU DISPLAY -------------------- */

// Helper: create a button_data entry with label and command context
string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

show_main_menu() {
    MenuContext = "main";
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, CurrentUserAcl);

    string body = "Maintenance:\n\n";
    list button_data = [];

    if (btn_allowed("View Settings"))    button_data += [btn("View Settings", "view_settings")];
    if (btn_allowed("Reload Settings"))  button_data += [btn("Reload Settings", "reload_settings")];
    if (btn_allowed("Access List"))      button_data += [btn("Access List", "access_list")];
    if (btn_allowed("Reload Collar"))    button_data += [btn("Reload Collar", "reload_collar")];
    if (btn_allowed("Clear Leash"))      button_data += [btn("Clear Leash", "clear_leash")];
    if (btn_allowed("Get HUD"))          button_data += [btn("Get HUD", "get_hud")];
    if (btn_allowed("User Manual"))      button_data += [btn("User Manual", "user_manual")];
    if (btn_allowed("Reset Config"))     button_data += [btn("Reset Config", "reset_config")];
    if (btn_allowed("Update Collar"))    button_data += [btn("Update Collar", "update_collar")];

    if (btn_allowed("View Settings")) {
        body += "System utilities and documentation.";
    }
    else {
        body += "Get HUD or user manual.";
    }

    SessionId = generate_session_id();

    // Pager (has_nav=1): the service supplies the << >> Back nav row; content =
    // the maintenance actions.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      "Maintenance",
        "body",       body,
        "category",   PLUGIN_CATEGORY,
        "has_nav",    1,
        "buttons",    llList2Json(JSON_ARRAY, button_data),
        "page",       0
    ]), NULL_KEY);
}

/* -------------------- ACTIONS -------------------- */

// Format a boolean as ON/OFF; unset defaults to OFF (matches runtime behaviour)
string fmt_bool(string raw) {
    if ((integer)raw) return "ON";
    return "OFF";
}

// fmt_bool with an explicit default for an absent key. Some settings default ON
// in their owning plugin and aren't persisted to LSD until toggled, so the raw
// read is "" — show the owning plugin's effective default, not OFF.
string fmt_bool_def(string raw, integer def_on) {
    if (raw == "") {
        if (def_on) return "ON";
        return "OFF";
    }
    if ((integer)raw) return "ON";
    return "OFF";
}

// Format relay.mode integer as label. Absent key = plugin_relay's effective
// default (ASK), not OFF.
string fmt_relay_mode(string raw) {
    if (raw == "") return "ASK";
    integer m = (integer)raw;
    if (m == 1) return "ON";
    if (m == 2) return "ASK";
    return "OFF";
}

// Format every "<Honorific> Name (uuid)" line for one role from the
// user-record roster (user.<uuid> = "<acl>,<rank>,<name>,<honorific>"),
// rank-sorted. Returns the block, or fallback_str when the role is empty.
string fmt_role_person_lines(integer want_acl, string fallback_str) {
    list rows = [];   // strided [rank, uuid, name, honorific]
    list ks = llLinksetDataFindKeys("^user\\.", 0, -1);
    integer i = 0;
    integer n = llGetListLength(ks);
    while (i < n) {
        string k = llList2String(ks, i);
        string rec = llLinksetDataRead(k);
        if ((integer)rec == want_acl) {
            list f = llCSV2List(rec);
            rows += [(integer)llList2String(f, 1), llGetSubString(k, 5, -1),
                     llList2String(f, 2), llList2String(f, 3)];
        }
        i += 1;
    }
    integer count = llGetListLength(rows) / 4;
    if (count == 0) return fallback_str;
    if (count > 1) rows = llListSortStrided(rows, 4, 0, TRUE);

    string block = "";
    i = 0;
    while (i < count) {
        string p_uuid = llList2String(rows, i * 4 + 1);
        string p_name = llList2String(rows, i * 4 + 2);
        string p_hon  = llList2String(rows, i * 4 + 3);
        if (p_hon != "") block += "  " + p_hon + " " + p_name + " (" + p_uuid + ")\n";
        else             block += "  " + p_name + " (" + p_uuid + ")\n";
        i += 1;
    }
    return block;
}

do_view_settings() {
    integer multi = (integer)llLinksetDataRead("access.multiowner");

    string locked = llLinksetDataRead("lock.locked");
    string lock_str;
    if ((integer)locked) lock_str = "LOCKED";
    else                 lock_str = "UNLOCKED";

    string restr_csv = llLinksetDataRead("restrict.list");
    string restr_str;
    if (restr_csv != "") {
        list restr_list = llParseString2List(restr_csv, [","], []);
        restr_str = (string)llGetListLength(restr_list) + " active";
    }
    else {
        restr_str = "none";
    }

    string output = "\n=== Collar Settings ===\n";

    // --- Owner(s) — from the user-record roster ---
    string owner_block = fmt_role_person_lines(5, "");
    if (owner_block == "") {
        output += "Owner: Uncommitted\n";
    }
    else if (multi) {
        output += "Owners:\n" + owner_block;
    }
    else {
        // Single-owner: one entry, inline label (strip the leading indent).
        output += "Owner:" + llGetSubString(owner_block, 2, -1);
    }

    // --- Trustees ---
    string trustee_block = fmt_role_person_lines(3, "");
    if (trustee_block == "") {
        output += "Trustees: none\n";
    }
    else {
        output += "Trustees:\n" + trustee_block;
    }

    // --- Behavioural settings ---
    output += "Access: multi-owner " + fmt_bool(llLinksetDataRead("access.multiowner"));
    output += " | runaway " + fmt_bool_def(llLinksetDataRead("access.enablerunaway"), TRUE) + "\n";
    output += "Lock: " + lock_str;
    output += " | public " + fmt_bool(llLinksetDataRead("public.mode"));
    output += " | TPE " + fmt_bool(llLinksetDataRead("tpe.mode")) + "\n";
    output += "Relay: " + fmt_relay_mode(llLinksetDataRead("relay.mode"));
    output += " | hardcore " + fmt_bool(llLinksetDataRead("relay.hardcoremode")) + "\n";
    output += "Owner TP/IM: " + fmt_bool(llLinksetDataRead("rlvex.ownertp"));
    output += "/" + fmt_bool(llLinksetDataRead("rlvex.ownerim")) + "\n";
    output += "Trustee TP/IM: " + fmt_bool(llLinksetDataRead("rlvex.trusteetp"));
    output += "/" + fmt_bool(llLinksetDataRead("rlvex.trusteeim")) + "\n";
    output += "Restrictions: " + restr_str;

    llRegionSayTo(CurrentUser, 0, output);
}

do_display_access_list() {
    string output = "=== Access Control List ===\n\n";

    // Owner(s) — from the user-record roster.
    if ((integer)llLinksetDataRead("access.multiowner")) {
        output += "OWNERS:\n";
    }
    else {
        output += "OWNER:\n";
    }
    string owner_block = fmt_role_person_lines(5, "  (none)\n");
    output += owner_block;

    // Trustees
    output += "\nTRUSTEES:\n";
    output += fmt_role_person_lines(3, "  (none)\n");

    // Blacklist
    output += "\nBLACKLISTED:\n";
    output += fmt_role_person_lines(-1, "  (none)\n");

    llRegionSayTo(CurrentUser, 0, output);
}

show_reset_config_confirm() {
    MenuContext = "reset_config";
    SessionId = generate_session_id();

    // Modal confirm: No-first, returns confirm/cancel (handler routes by context).
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "modal",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "title",      "Reset Config",
        "body",       "This will reset all settings except for ownership and lock state.\n\nIf you need out of an abusive collar, please use Runaway."
    ]), NULL_KEY);
}

do_reset_config() {
    llRegionSayTo(CurrentUser, 0, "Resetting configuration...");
    cleanup_session();

    // kmod_settings owns the reset semantics: snapshot owner+lock, wipe LSD,
    // re-parse notecard, restore preserved keys for card-silent slots, set
    // bootstrap sentinel, broadcast kernel.reset.factory once LSD is final.
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.reset.config"
    ]), NULL_KEY);
}

do_reload_settings() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings.get"
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);

    llRegionSayTo(CurrentUser, 0, "Settings reload requested.");
}

show_clear_leash_confirm() {
    MenuContext = "clear_leash";
    SessionId = generate_session_id();

    // Modal confirm: No-first, returns confirm/cancel.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "modal",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "title",      "Clear Leash",
        "body",       "Force-release the current leash?\n\nThis bypasses normal permission checks and clears any leash, including one held by a bad actor.\n\nAre you sure?"
    ]), NULL_KEY);
}

do_clear_leash() {
    // Use force_release rather than the normal release action.
    // release requires the user to be the active leasher or hold Unclip
    // policy; force_release is authorized by wearer identity or ACL >= 3,
    // allowing an owned wearer (ACL 2) to escape a bad-actor leash and
    // clearing stray leash particles in all cases.
    string msg = llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.action",
        "action", "force_release"
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, CurrentUser);

    llRegionSayTo(CurrentUser, 0, "Leash cleared.");
}

do_reload_collar() {
    // Broadcast soft reset to all plugins
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.reset.soft",
        "from", "maintenance"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);

    llRegionSayTo(CurrentUser, 0, "Collar reload initiated.");
}

/* -------------------- UPDATE FLOW -------------------- */

// Asks kmod_remote to broadcast remote.updateravailable and watch for the
// first remote.updaterhere reply. We park MenuContext in update_scan_waiting
// and leave no dialog open; result arrives within 5s via REMOTE_BUS and
// either opens the confirm dialog or notifies the user there's nothing.
do_start_update_scan() {
    MenuContext = "update_scan_waiting";
    UpdateScanUpdater = NULL_KEY;
    UpdateScanVersion = "";

    string msg = llList2Json(JSON_OBJECT, [
        "type", "remote.updaterscan.start",
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, REMOTE_BUS, msg, NULL_KEY);

    llRegionSayTo(CurrentUser, 0, "Scanning for an updater in range...");
}

show_update_confirm() {
    MenuContext = "update_confirm";
    SessionId = generate_session_id();

    string body = "Updater found.\n\n";
    body += "Updater: " + (string)UpdateScanUpdater + "\n";
    body += "Version: " + UpdateScanVersion + "\n\n";
    body += "Begin update? Your collar will receive new scripts.";

    // Modal confirm: No-first, returns confirm/cancel.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "modal",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "title",      "Update Collar",
        "body",       body
    ]), NULL_KEY);
}

do_confirm_update() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "remote.updaterscan.confirm",
        "updater", (string)UpdateScanUpdater
    ]);
    llMessageLinked(LINK_SET, REMOTE_BUS, msg, NULL_KEY);

    llRegionSayTo(CurrentUser, 0, "Update started. Please leave your collar attached.");
    cleanup_session();
}

do_cancel_update() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "remote.updaterscan.cancel"
    ]);
    llMessageLinked(LINK_SET, REMOTE_BUS, msg, NULL_KEY);
}

handle_scan_result(string msg) {
    // Only honour scan results while the user is still in the waiting state.
    // If they navigated away, drop it.
    if (MenuContext != "update_scan_waiting") return;

    integer found = (integer)llJsonGetValue(msg, ["found"]);

    if (!found) {
        llRegionSayTo(CurrentUser, 0, "No updater responded. Make sure your updater object is rezzed and within 20m.");
        cleanup_session();
        return;
    }

    string updater_str = llJsonGetValue(msg, ["updater"]);
    if (updater_str == JSON_INVALID) {
        cleanup_session();
        return;
    }
    UpdateScanUpdater = (key)updater_str;

    string ver = llJsonGetValue(msg, ["version"]);
    if (ver == JSON_INVALID) ver = "?";
    UpdateScanVersion = ver;

    show_update_confirm();
}

do_give_hud() {
    if (llGetInventoryType(HUD_ITEM) != INVENTORY_OBJECT) {
        llRegionSayTo(CurrentUser, 0, "HUD not found in inventory.");
    }
    else {
        llGiveInventory(CurrentUser, HUD_ITEM);
        llRegionSayTo(CurrentUser, 0, "HUD sent.");
    }
}

do_give_manual() {
    if (llGetInventoryType(MANUAL_NOTECARD) != INVENTORY_NOTECARD) {
        llRegionSayTo(CurrentUser, 0, "Manual not found in inventory.");
    }
    else {
        llGiveInventory(CurrentUser, MANUAL_NOTECARD);
        llRegionSayTo(CurrentUser, 0, "Manual sent.");
    }
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
    // Close the dialog session in the dialog manager
    if (SessionId != "") {
        string msg = llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]);
        llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
    }

    CurrentUser = NULL_KEY;
    CurrentUserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
    MenuContext = "main";
    UpdateScanUpdater = NULL_KEY;
    UpdateScanVersion = "";
}

/* -------------------- DIALOG HANDLERS -------------------- */

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["button"]) == JSON_INVALID) return;

    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;

    string cmd = llJsonGetValue(msg, ["context"]);
    // Nav (<< >> Back) renders as plain buttons with empty context → fall back
    // to the button label so the handler can route them.
    if (cmd == JSON_INVALID || cmd == "") cmd = llJsonGetValue(msg, ["button"]);

    // Navigation
    if (cmd == "back" || cmd == "Back") {
        if (MenuContext != "main") {
            show_main_menu();
        }
        else {
            return_to_root();
        }
        return;
    }

    // Confirmation dialogs — route by menu context
    if (MenuContext == "reset_config") {
        if (cmd == "confirm") {
            do_reset_config();
            return;
        }
        show_main_menu();
        return;
    }

    if (MenuContext == "clear_leash") {
        if (cmd == "confirm") {
            do_clear_leash();
            return;
        }
        show_main_menu();
        return;
    }

    if (MenuContext == "update_confirm") {
        if (cmd == "confirm") {
            do_confirm_update();
            return;
        }
        do_cancel_update();
        show_main_menu();
        return;
    }

    // Main menu commands
    if (cmd == "view_settings") {
        do_view_settings();
        show_main_menu();
        return;
    }
    if (cmd == "access_list") {
        do_display_access_list();
        show_main_menu();
        return;
    }
    if (cmd == "reload_settings") {
        do_reload_settings();
        show_main_menu();
        return;
    }
    if (cmd == "clear_leash") {
        show_clear_leash_confirm();
        return;
    }
    if (cmd == "reload_collar") {
        do_reload_collar();
        show_main_menu();
        return;
    }
    if (cmd == "get_hud") {
        do_give_hud();
        show_main_menu();
        return;
    }
    if (cmd == "user_manual") {
        do_give_manual();
        show_main_menu();
        return;
    }
    if (cmd == "reset_config") {
        show_reset_config_confirm();
        return;
    }
    if (cmd == "update_collar") {
        do_start_update_scan();
        return;
    }

    // Inert << >> on the main pager — redraw.
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
        /* -------------------- KERNEL LIFECYCLE -------------------- */if (num == KERNEL_LIFECYCLE) {
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
                // Check if this is a targeted reset
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) {
                        return; // Not for us, ignore
                    }
                }
                // Either no context (broadcast) or matches our context.
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
                llResetScript();
            }

            return;
        }

        /* -------------------- REMOTE BUS -------------------- */if (num == REMOTE_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "remote.updaterscan.result") {
                handle_scan_result(msg);
                return;
            }

            return;
        }

        /* -------------------- UI START -------------------- */if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                if (id == NULL_KEY) return;

                CurrentUser = id;
                CurrentUserAcl = (integer)llJsonGetValue(msg, ["acl"]);
                show_main_menu();
                return;
            }

            return;
        }

        /* -------------------- DIALOG RESPONSE -------------------- */if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.dialog.response") {
                handle_dialog_response(msg);
                return;
            }

            if (msg_type == "ui.dialog.timeout") {
                handle_dialog_timeout(msg);
                return;
            }

            if (msg_type == "ui.dialog.close") {
                // Dialog was closed externally (e.g., replaced by another dialog)
                // Clean up our session if it matches
                string session = llJsonGetValue(msg, ["session_id"]);
                if (session != JSON_INVALID) {
                    if (session == SessionId) {
                        // Don't send another dialog_close since we're responding to one
                        CurrentUser = NULL_KEY;
                        CurrentUserAcl = -999;
                        gPolicyButtons = [];
                        SessionId = "";
                    }
                }
                return;
            }

            return;
        }
    }
}

/*--------------------
PLUGIN: plugin_rlvex.lsl
VERSION: 1.2
REVISION: 9
CHANGES:
- v1.2 rev 9: nav-row consistency — has_nav 0→1 on all four menus so the << >> Back row matches the rest of the UI; added catch-all redraws in main/owner/trustee for the now-inert << >> (toggle menus already self-redraw to the parent).
- v1.2 rev 8: menu-service migration. show_main / show_owner_menu / show_trustee_menu / show_toggle now render via the pager (ui.menu.render, has_nav=0; the service supplies Back), sends moved DIALOG_BUS→UI_BUS, local "Back" button dropped from each list. Content buttons keep their {label,context} so handle_button's ctx-routing is unchanged; the response handler maps the service's plain Back (button="Back", empty ctx) → "back" so the context-aware up-navigation (toggle→role menu→main→exit) is preserved. Exception logic untouched.
- v1.2 rev 7: RLV gating — ORed bit 0x40 into PLUGIN_ACL_MASK (56→120) so kmod_ui drops this RLV-dependent plugin from the menu when rlv.active=0 (published by kmod_bootstrap). No ACL-visibility change — bit 6 sits above the level bits 1-5.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. See collar_kernel rev 6.
- v1.2 rev 1: Enumerate owners/trustees from the user-record roster (user.<uuid> acl 5/3) instead of the retired access.owner-/trustee- keys; single/multi owner mode branching collapses (OwnerKeys always holds every owner).
PURPOSE: Manage RLV teleport and IM exceptions for owners and trustees
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
--------------------*/


/* -------------------- ISP CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.rlv_exceptions";
string PLUGIN_LABEL = "Exceptions";

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_EX_OWNER_TP    = "rlvex.ownertp";
string KEY_EX_OWNER_IM    = "rlvex.ownerim";
string KEY_EX_TRUSTEE_TP  = "rlvex.trusteetp";
string KEY_EX_TRUSTEE_IM  = "rlvex.trusteeim";
// Owners/trustees enumerate from user.<uuid> records (kmod_settings rev 2):
// the record's leading field is the acl (5 owner / 3 trustee).

/* -------------------- STATE -------------------- */
integer ExOwnerTp = TRUE;
integer ExOwnerIm = TRUE;
integer ExTrusteeTp = FALSE;
integer ExTrusteeIm = FALSE;

list OwnerKeys;     // ALL owner uuids (single owner = one-entry list)
list TrusteeKeys;

key CurrentUser;
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId;
string MenuContext;

integer PendingReconcile = FALSE;

/* -------------------- HELPERS -------------------- */

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

integer lsd_int(string lsd_key, integer fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (integer)v;
}

string gen_session() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
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

/* -------------------- RLV COMMANDS -------------------- */

apply_tp_exception(key k, integer allow) {
    if (k == NULL_KEY) return;
    string sk = (string)k;
    string op = "=add";
    if (!allow) op = "=rem";
    llOwnerSay("@accepttp:" + sk + op + ",tplure:" + sk + op);
}

apply_im_exception(key k, integer allow) {
    if (k == NULL_KEY) return;
    string sk = (string)k;
    string op = "=add";
    if (!allow) op = "=rem";
    llOwnerSay("@sendim:" + sk + op + ",recvim:" + sk + op);
}

reconcile_all() {
    if (llGetListLength(OwnerKeys) == 0 && llGetListLength(TrusteeKeys) == 0) return;

    // Owner exceptions — OwnerKeys holds every owner (a single owner is a
    // one-entry list), so no mode branching.
    integer i = 0;
    integer owner_count = llGetListLength(OwnerKeys);
    while (i < owner_count) {
        key k = (key)llList2String(OwnerKeys, i);
        apply_tp_exception(k, ExOwnerTp);
        apply_im_exception(k, ExOwnerIm);
        i++;
    }

    // Trustee exceptions
    i = 0;
    integer trustee_count = llGetListLength(TrusteeKeys);
    while (i < trustee_count) {
        key k = (key)llList2String(TrusteeKeys, i);
        apply_tp_exception(k, ExTrusteeTp);
        apply_im_exception(k, ExTrusteeIm);
        i++;
    }
}

/* -------------------- LIFECYCLE -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "RLV";
integer PLUGIN_ACL_MASK = 120;  // 56 (ACL 3-5) | 0x40 RLV-required: kmod_ui hides when rlv.active=0

register_self() {
    // Per-button visibility policy (default-deny per ACL level). Was written
    // straight to LSD here; now announced to the kernel, which is the SOLE
    // writer of acl.policycontext (and reg.<ctx>) — see collar_kernel rev 6.
    string policy = llList2Json(JSON_OBJECT, [
        "3", "Owner,Trustee,TP,IM",
        "4", "Owner,Trustee,TP,IM",
        "5", "Owner,Trustee,TP,IM"
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
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

/* -------------------- SETTINGS -------------------- */

// v1.2 seed-default: write this plugin's default into LSD only if absent
// (no broadcast). Makes LSD the complete, self-describing collar state and
// self-heals if the notecard manifest later drops the key. See kmod_settings
// settings.seed.
seed_def(string lsd_key, string value) {
    if (llLinksetDataRead(lsd_key) == "")
        llMessageLinked(LINK_SET, SETTINGS_BUS, "settings.seed:" + lsd_key + ":" + value, NULL_KEY);
}

apply_settings_sync() {
    // Seed exception defaults: owner TP/IM exempt by default, trustees not.
    // Supersedes the old owners-exist auto-init (the exception is harmless
    // until an owner exists to be its subject).
    seed_def(KEY_EX_OWNER_TP, "1");
    seed_def(KEY_EX_OWNER_IM, "1");
    seed_def(KEY_EX_TRUSTEE_TP, "0");
    seed_def(KEY_EX_TRUSTEE_IM, "0");

    // Save previous state for change detection
    list prev_owners = OwnerKeys;
    list prev_trustees = TrusteeKeys;
    integer prev_ex_otp = ExOwnerTp;
    integer prev_ex_oim = ExOwnerIm;
    integer prev_ex_ttp = ExTrusteeTp;
    integer prev_ex_tim = ExTrusteeIm;

    // Reset state
    OwnerKeys = [];
    TrusteeKeys = [];

    // Read exception settings from LSD
    ExOwnerTp = lsd_int(KEY_EX_OWNER_TP, TRUE);
    ExOwnerIm = lsd_int(KEY_EX_OWNER_IM, TRUE);
    ExTrusteeTp = lsd_int(KEY_EX_TRUSTEE_TP, FALSE);
    ExTrusteeIm = lsd_int(KEY_EX_TRUSTEE_IM, FALSE);

    // Enumerate owners/trustees from the user records (record's leading
    // field is the acl). Order doesn't matter for exceptions.
    list ks = llLinksetDataFindKeys("^user\\.", 0, -1);
    integer ki = 0;
    integer kn = llGetListLength(ks);
    while (ki < kn) {
        string k = llList2String(ks, ki);
        integer acl = (integer)llLinksetDataRead(k);
        if (acl == 5) OwnerKeys += [llGetSubString(k, 5, -1)];
        else if (acl == 3) TrusteeKeys += [llGetSubString(k, 5, -1)];
        ki += 1;
    }

    // Detect changes: clear old exceptions for removed owners/trustees
    integer need_reconcile = FALSE;

    if (ExOwnerTp != prev_ex_otp || ExOwnerIm != prev_ex_oim
        || ExTrusteeTp != prev_ex_ttp || ExTrusteeIm != prev_ex_tim) {
        need_reconcile = TRUE;
    }

    // Owner set changed
    if (llList2CSV(OwnerKeys) != llList2CSV(prev_owners)) {
        integer ci = 0;
        integer old_count = llGetListLength(prev_owners);
        while (ci < old_count) {
            key old_k = (key)llList2String(prev_owners, ci);
            apply_tp_exception(old_k, FALSE);
            apply_im_exception(old_k, FALSE);
            ci++;
        }
        need_reconcile = TRUE;
    }

    // Trustee list changed
    if (llList2CSV(TrusteeKeys) != llList2CSV(prev_trustees)) {
        integer ci = 0;
        integer old_count = llGetListLength(prev_trustees);
        while (ci < old_count) {
            key old_k = (key)llList2String(prev_trustees, ci);
            apply_tp_exception(old_k, FALSE);
            apply_im_exception(old_k, FALSE);
            ci++;
        }
        need_reconcile = TRUE;
    }

    if (need_reconcile) {
        PendingReconcile = TRUE;
        llSetTimerEvent(1.0);
    }
}

persist_setting(string setting_key, integer value) {
    // Single-writer settings.delta CSV protocol — kmod_settings sole LSD writer.
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + setting_key + ":" + (string)value, NULL_KEY);
}

/* -------------------- MENUS -------------------- */

show_main() {
    SessionId = gen_session();
    MenuContext = "main";

    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    string body = "RLV Exceptions\n\nManage which restrictions can be bypassed by owners and trustees.";

    // Pager (has_nav=1; full << >> Back nav row, inert << >> redraw). Content =the roles.
    list button_data = [];
    if (btn_allowed("Owner"))   button_data += [btn("Owner", "owner")];
    if (btn_allowed("Trustee")) button_data += [btn("Trustee", "trustee")];

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      PLUGIN_LABEL,
        "body",       body,
        "category",   PLUGIN_CATEGORY,
        "has_nav",    1,
        "buttons",    llList2Json(JSON_ARRAY, button_data),
        "page",       0
    ]), NULL_KEY);
}

show_owner_menu() {
    SessionId = gen_session();
    MenuContext = "owner";

    string body = "Owner Exceptions\n\nCurrent settings:\n";
    if (ExOwnerTp) body += "TP: Allowed\n";
    else body += "TP: Denied\n";
    if (ExOwnerIm) body += "IM: Allowed";
    else body += "IM: Denied";

    // Pager (has_nav=1; full << >> Back nav row, inert << >> redraw). Content =the toggles.
    list button_data = [];
    if (btn_allowed("TP")) button_data += [btn("TP", "tp")];
    if (btn_allowed("IM")) button_data += [btn("IM", "im")];

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      "Owner Exceptions",
        "body",       body,
        "category",   PLUGIN_CATEGORY,
        "has_nav",    1,
        "buttons",    llList2Json(JSON_ARRAY, button_data),
        "page",       0
    ]), NULL_KEY);
}

show_trustee_menu() {
    SessionId = gen_session();
    MenuContext = "trustee";

    string body = "Trustee Exceptions\n\nCurrent settings:\n";
    if (ExTrusteeTp) body += "TP: Allowed\n";
    else body += "TP: Denied\n";
    if (ExTrusteeIm) body += "IM: Allowed";
    else body += "IM: Denied";

    // Pager (has_nav=1; full << >> Back nav row, inert << >> redraw). Content =the toggles.
    list button_data = [];
    if (btn_allowed("TP")) button_data += [btn("TP", "tp")];
    if (btn_allowed("IM")) button_data += [btn("IM", "im")];

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      "Trustee Exceptions",
        "body",       body,
        "category",   PLUGIN_CATEGORY,
        "has_nav",    1,
        "buttons",    llList2Json(JSON_ARRAY, button_data),
        "page",       0
    ]), NULL_KEY);
}

show_toggle(string role, string exception_type, integer current) {
    SessionId = gen_session();
    MenuContext = role + "_" + exception_type;

    string body = role + " " + exception_type + " Exception\n\n";
    if (current) body += "Current: Allowed\n\n";
    else body += "Current: Denied\n\n";
    body += "Allow = Owner/trustee can bypass restrictions\n";
    body += "Deny = Normal restrictions apply";

    // Pager (has_nav=1; full << >> Back nav row, inert << >> redraw). Content =Allow / Deny.
    list button_data = [btn("Allow", "allow"), btn("Deny", "deny")];

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      role + " " + exception_type,
        "body",       body,
        "category",   PLUGIN_CATEGORY,
        "has_nav",    1,
        "buttons",    llList2Json(JSON_ARRAY, button_data),
        "page",       0
    ]), NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button(string ctx) {
    if (ctx == "back") {
        if (MenuContext == "main") {
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "ui.menu.return", "user", (string)CurrentUser
            ]), NULL_KEY);
            cleanup();
        }
        else if (MenuContext == "owner" || MenuContext == "trustee") {
            show_main();
        }
        else {
            if (llSubStringIndex(MenuContext, "Owner") == 0) show_owner_menu();
            else if (llSubStringIndex(MenuContext, "Trustee") == 0) show_trustee_menu();
            else show_main();
        }
        return;
    }

    if (MenuContext == "main") {
        if (ctx == "owner") show_owner_menu();
        else if (ctx == "trustee") show_trustee_menu();
        else show_main();                 // inert << >> — redraw
    }
    else if (MenuContext == "owner") {
        if (ctx == "tp") show_toggle("Owner", "TP", ExOwnerTp);
        else if (ctx == "im") show_toggle("Owner", "IM", ExOwnerIm);
        else show_owner_menu();           // inert << >> — redraw
    }
    else if (MenuContext == "trustee") {
        if (ctx == "tp") show_toggle("Trustee", "TP", ExTrusteeTp);
        else if (ctx == "im") show_toggle("Trustee", "IM", ExTrusteeIm);
        else show_trustee_menu();         // inert << >> — redraw
    }
    else if (MenuContext == "Owner_TP") {
        if (ctx == "allow") {
            ExOwnerTp = TRUE;
            persist_setting(KEY_EX_OWNER_TP, TRUE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Owner TP exception allowed.");
        }
        else if (ctx == "deny") {
            ExOwnerTp = FALSE;
            persist_setting(KEY_EX_OWNER_TP, FALSE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Owner TP exception denied.");
        }
        show_owner_menu();
    }
    else if (MenuContext == "Owner_IM") {
        if (ctx == "allow") {
            ExOwnerIm = TRUE;
            persist_setting(KEY_EX_OWNER_IM, TRUE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Owner IM exception allowed.");
        }
        else if (ctx == "deny") {
            ExOwnerIm = FALSE;
            persist_setting(KEY_EX_OWNER_IM, FALSE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Owner IM exception denied.");
        }
        show_owner_menu();
    }
    else if (MenuContext == "Trustee_TP") {
        if (ctx == "allow") {
            ExTrusteeTp = TRUE;
            persist_setting(KEY_EX_TRUSTEE_TP, TRUE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Trustee TP exception allowed.");
        }
        else if (ctx == "deny") {
            ExTrusteeTp = FALSE;
            persist_setting(KEY_EX_TRUSTEE_TP, FALSE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Trustee TP exception denied.");
        }
        show_trustee_menu();
    }
    else if (MenuContext == "Trustee_IM") {
        if (ctx == "allow") {
            ExTrusteeIm = TRUE;
            persist_setting(KEY_EX_TRUSTEE_IM, TRUE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Trustee IM exception allowed.");
        }
        else if (ctx == "deny") {
            ExTrusteeIm = FALSE;
            persist_setting(KEY_EX_TRUSTEE_IM, FALSE);
            reconcile_all();
            llRegionSayTo(CurrentUser, 0, "Trustee IM exception denied.");
        }
        show_trustee_menu();
    }
}

/* -------------------- CLEANUP -------------------- */

cleanup() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    llSetTimerEvent(0.0);
    PendingReconcile = FALSE;
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
    MenuContext = "";
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {

        cleanup();
        register_self();
        apply_settings_sync();

        // apply_settings_sync defers reconcile_all() via a 1-second timer
        // (debouncing rapid settings.sync cascades). On the initial
        // state_entry we want it immediate — RLV exceptions are
        // session-scoped to the script's UUID and the viewer wipes the
        // old script's entries on reset, so there's a 1+ second window
        // after recompile where trustees / owners lose their exception
        // privileges. Any menu interaction or session timeout during
        // that window calls cleanup() which cancels the pending timer
        // outright, making the wipe permanent until next settings.sync.
        // Force an immediate emit and clear the deferred path.
        if (PendingReconcile) {
            PendingReconcile = FALSE;
            llSetTimerEvent(0.0);
            reconcile_all();
        }
    }

    on_rez(integer p) {
        llResetScript();
    }

    changed(integer c) {
        if (c & CHANGED_OWNER) llResetScript();
    }

    timer() {
        llSetTimerEvent(0.0);
        if (PendingReconcile) {
            PendingReconcile = FALSE;
            reconcile_all();
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        string type = llJsonGetValue(msg, ["type"]);
        if (type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (type == "kernel.register.refresh") {
                register_self();
                apply_settings_sync();
            }
            else if (type == "kernel.ping") send_pong();
            else if (type == "kernel.reset.soft" || type == "kernel.reset.factory") {
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) return;
                }
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            if (type == "settings.sync") apply_settings_sync();
        }
        else if (num == UI_BUS) {
            if (type == "ui.menu.start" && (llJsonGetValue(msg, ["context"]) != JSON_INVALID)) {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    CurrentUser = id;
                    UserAcl = (integer)llJsonGetValue(msg, ["acl"]);
                    show_main();
                }
            }
        }
        else if (num == DIALOG_BUS) {
            if (type == "ui.dialog.response") {
                if ((llJsonGetValue(msg, ["session_id"]) != JSON_INVALID) && (llJsonGetValue(msg, ["context"]) != JSON_INVALID)) {
                    if (llJsonGetValue(msg, ["session_id"]) == SessionId) {
                        // The menu service renders nav (Back) as a plain button →
                        // empty context; map it to the legacy "back" context so
                        // handle_button's context-aware up-navigation still fires.
                        string resp_ctx = llJsonGetValue(msg, ["context"]);
                        if (resp_ctx == "" && llJsonGetValue(msg, ["button"]) == "Back") resp_ctx = "back";
                        handle_button(resp_ctx);
                    }
                }
            }
            else if (type == "ui.dialog.timeout") {
                if ((llJsonGetValue(msg, ["session_id"]) != JSON_INVALID)) {
                    if (llJsonGetValue(msg, ["session_id"]) == SessionId) cleanup();
                }
            }
        }
    }
}

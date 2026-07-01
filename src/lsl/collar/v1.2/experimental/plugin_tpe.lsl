/*--------------------
PLUGIN: plugin_tpe.lsl
VERSION: 1.2
REVISION: 8
PURPOSE: Manage TPE mode with wearer confirmation and owner oversight
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility,
  namespaced internal message protocol
CHANGES:
- v1.2 rev 8: confirm dialog mode renamed modal to dialog.modal (menu-mode taxonomy; No-first layout unchanged).
- v1.2 rev 7: menu-service migration. The OFF→ON wearer-consent dialog now renders via the modal shape (ui.menu.render mode=modal, DIALOG_BUS→UI_BUS) — which keeps the arbitrary-user target (the prompt still goes to the WEARER, not the clicking owner) and returns context confirm/cancel, so handle_button_click is unchanged. The modal enforces No-first, correcting the old Yes-first ordering to match the project confirm convention. ON→OFF stays a silent direct toggle (no dialog). Dropped the now-unused btn() helper.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (the self-declare reset write-storm); register now announces cat/mask/policy via kernel.register.declare and the kernel is the sole serial writer. Removed write_plugin_reg + the reset-handler reg/policy deletes (kept the plugin.<x>.state delete). Revision baseline normalized to rev 6. See collar_kernel rev 6.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.tpe";
string PLUGIN_LABEL_ON = "TPE: Y";
string PLUGIN_LABEL_OFF = "TPE: N";

/* ACL levels for reference:
   -1 = Blacklisted
    0 = No Access (wearer in TPE mode)
    1 = Public
    2 = Owned (wearer when owner set)
    3 = Trustee
    4 = Unowned (wearer when no owner)
    5 = Primary Owner (ONLY ACL that can manage TPE)
*/

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_TPE_MODE = "tpe.mode";

/* -------------------- STATE -------------------- */
integer TpeModeEnabled = FALSE;

// Session management for confirmation dialog
key CurrentUser = NULL_KEY;        // Who initiated the action
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";
key WearerKey = NULL_KEY;          // Owner of the collar (for confirmation)

/* -------------------- HELPERS -------------------- */

string gen_session() {
    return (string)llGetKey() + "_" + (string)llGetUnixTime();
}

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
}

close_ui_for_user(key user) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.menu.close",
        "context", PLUGIN_CONTEXT,
        "user", (string)user
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, user);
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

/* -------------------- KERNEL MESSAGES -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "Access";
integer PLUGIN_ACL_MASK = 32;

// Tell kmod_dialogs how to render this plugin's button based on state:
//   state == 0 → PLUGIN_LABEL_OFF
//   state != 0 → PLUGIN_LABEL_ON
register_button_config() {
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type",     "ui.dialog.buttonconfig.register",
        "context",  PLUGIN_CONTEXT,
        "button_a", PLUGIN_LABEL_OFF,
        "button_b", PLUGIN_LABEL_ON
    ]), NULL_KEY);
}

// Write the current toggle state to LSD at plugin.tpe.state. kmod_dialogs
// reads this at render time (via buttonconfig) to pick the right label.
// Key convention: "plugin.<short>.state" where <short> is the trailing
// dotted segment of the plugin context. Idempotent read-before-write
// skips the linkset_data event when the stored value already matches.
send_state_update() {
    string k = "plugin.tpe.state";
    string v = (string)TpeModeEnabled;
    if (llLinksetDataRead(k) == v) return;
    llLinksetDataWrite(k, v);
}

register_with_kernel() {
    // Button visibility policy (only primary owner ACL 5 gets toggle).
    // Announced to the kernel — sole writer of acl.policycontext/reg.<ctx>
    // (collar_kernel rev 6) — instead of being written here (the reset storm).
    string policy = llList2Json(JSON_OBJECT, [
        "5", "toggle"
    ]);

    // State-based label resolution (separate buttonconfig path — unchanged).
    register_button_config();
    send_state_update();

    // Announce full registration. The kernel writes reg.<ctx> + policy serially.
    // The declared label is the kmod_dialogs cold-start fallback — a stable
    // default, never rewritten on toggle (live label rides buttonconfig).
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL_OFF,
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

/* -------------------- SETTINGS MANAGEMENT -------------------- */

persist_tpe_mode(integer new_value) {
    if (new_value != 0) new_value = 1;

    // Single-writer settings.delta CSV protocol. kmod_settings validates
    // against MANAGED_SETTINGS_KEYS, writes LSD, broadcasts settings.sync.
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + KEY_TPE_MODE + ":" + (string)new_value, NULL_KEY);
}

/* -------------------- UI LABEL UPDATE -------------------- */

// Forwarder kept under the old name so existing callers keep working; the
// underlying path now pushes state (not a label) and lets kmod_dialogs
// resolve the final button text via its registered buttonconfig.
update_ui_label() {
    send_state_update();
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(string cmd) {
    if (cmd == "confirm") {
        // Wearer confirmed - enable TPE
        TpeModeEnabled = TRUE;
        persist_tpe_mode(TRUE);

        llRegionSayTo(WearerKey, 0, "TPE mode enabled. You have relinquished collar control.");
        if (CurrentUser != WearerKey) {
            llRegionSayTo(CurrentUser, 0, "TPE mode enabled with wearer consent.");
        }

        // Update UI label
        update_ui_label();

        // Close UI for wearer (who clicked the dialog)
        close_ui_for_user(WearerKey);

        // Return owner to root menu to see updated button (if different from wearer)
        if (CurrentUser != WearerKey) {
            string msg = llList2Json(JSON_OBJECT, [
                "type", "ui.menu.return",
                "user", (string)CurrentUser
            ]);
            llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
        }

        cleanup_session();
    }
    else if (cmd == "cancel") {
        // Wearer declined - cancel TPE activation
        llRegionSayTo(WearerKey, 0, "TPE activation cancelled.");
        if (CurrentUser != WearerKey) {
            llRegionSayTo(CurrentUser, 0, "Wearer declined TPE activation.");
        }

        // Close UI for wearer (who clicked the dialog)
        close_ui_for_user(WearerKey);

        // Return owner to root menu (if different from wearer)
        if (CurrentUser != WearerKey) {
            string msg = llList2Json(JSON_OBJECT, [
                "type", "ui.menu.return",
                "user", (string)CurrentUser
            ]);
            llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
        }

        cleanup_session();
    }
}

/* -------------------- TPE TOGGLE LOGIC -------------------- */

handle_tpe_click(key user, integer acl_level) {
    // Load policy buttons and verify toggle is allowed for this ACL
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);
    if (!btn_allowed("toggle")) {
        llRegionSayTo(user, 0, "Access denied. Only primary owner can manage TPE mode.");
        cleanup_session();
        return;
    }

    CurrentUser = user;
    UserAcl = acl_level;
    WearerKey = llGetOwner();

    if (TpeModeEnabled) {
        // TPE is currently ON - disable it directly (no confirmation needed)
        // This allows owner to release TPE without wearer consent
        TpeModeEnabled = FALSE;
        persist_tpe_mode(FALSE);

        llRegionSayTo(user, 0, "TPE mode disabled. Wearer regains collar access.");
        // Notify wearer their access has been restored
        if (user != WearerKey) {
            llRegionSayTo(WearerKey, 0, "Your collar access has been restored.");
        }

        // Update UI label
        update_ui_label();

        // Return owner to root menu (so they see the updated button)
        string msg = llList2Json(JSON_OBJECT, [
            "type", "ui.menu.return",
            "user", (string)user
        ]);
        llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);

        cleanup_session();
    }
    else {
        // TPE is currently OFF - requires wearer consent
        // Send dialog to WEARER, not CurrentUser

        string msg_body = "Your owner wants to enable TPE mode.\n\n";
        msg_body += "By clicking Yes, you relinquish control of this collar. ";
        msg_body += "The normal collar menu will be locked out.\n\n";
        msg_body += "A SOS menu remains available through long touch as a safety hatch.\n\n";
        msg_body += "Do you consent?";

        SessionId = gen_session();

        // Modal confirm rendered to the WEARER (not the clicking owner): the menu
        // service forces No-first and returns context confirm/cancel — which is
        // exactly what handle_button_click already routes on, so it's unchanged.
        llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
            "type",       "ui.menu.render",
            "mode",       "dialog.modal",
            "session_id", SessionId,
            "user",       (string)llGetOwner(),
            "title",      "TPE Confirmation",
            "body",       msg_body
        ]), NULL_KEY);
    }
}

/* -------------------- SETTINGS CONSUMPTION -------------------- */

// v1.2 seed-default: write this plugin's default into LSD only if absent
// (no broadcast). Makes LSD the complete, self-describing collar state and
// self-heals if the notecard manifest later drops the key. See kmod_settings
// settings.seed.
seed_def(string lsd_key, string value) {
    if (llLinksetDataRead(lsd_key) == "")
        llMessageLinked(LINK_SET, SETTINGS_BUS, "settings.seed:" + lsd_key + ":" + value, NULL_KEY);
}

apply_settings_sync() {
    seed_def(KEY_TPE_MODE, "0");
    integer prev = TpeModeEnabled;
    string lsd_val = llLinksetDataRead(KEY_TPE_MODE);
    if (lsd_val != "") {
        TpeModeEnabled = (integer)lsd_val;
    }

    // If TPE mode changed, fire the state-update notification. kmod_settings
    // is the sole LSD writer; no LSD echo here.
    if (TpeModeEnabled != prev) {
        send_state_update();
    }
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {

        WearerKey = llGetOwner();
        cleanup_session();
        apply_settings_sync();
        register_with_kernel();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }

    link_message(integer sender_num, integer num, string str, key id) {
        // Skip logging kernel lifecycle messages (too noisy)
        // if (num != KERNEL_LIFECYCLE) {
        // }

        if (num == KERNEL_LIFECYCLE) {
            string msg_type = llJsonGetValue(str, ["type"]);

            if (msg_type == "kernel.register.refresh") {
                register_with_kernel();
            }
            else if (msg_type == "kernel.ping") {
                send_pong();
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                // Check if this is a targeted reset
                string target_context = llJsonGetValue(str, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) {
                        return; // Not for us, ignore
                    }
                }
                // Either no context (broadcast) or matches our context
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
                llLinksetDataDelete("plugin.tpe.state");
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            string msg_type = llJsonGetValue(str, ["type"]);

            if (msg_type == "settings.sync") {
                apply_settings_sync();
            }
        }
        else if (num == UI_BUS) {
            string msg_type = llJsonGetValue(str, ["type"]);

            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(str, ["acl"]) == JSON_INVALID) return;
                string context = llJsonGetValue(str, ["context"]);
                if (context != PLUGIN_CONTEXT) return;

                // User key is passed as the id parameter to link_message, not in JSON
                CurrentUser = id;

                // ACL level provided by UI module
                UserAcl = (integer)llJsonGetValue(str, ["acl"]);

                // Handle click - may show confirmation dialog or toggle directly
                handle_tpe_click(CurrentUser, UserAcl);
            }
        }
        else if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(str, ["type"]);

            if (msg_type == "ui.dialog.response") {
                string session_id = llJsonGetValue(str, ["session_id"]);
                if (session_id != SessionId) return;

                string cmd = llJsonGetValue(str, ["context"]);
                if (cmd == JSON_INVALID) cmd = "";

                handle_button_click(cmd);
            }
            else if (msg_type == "ui.dialog.timeout") {
                string session_id = llJsonGetValue(str, ["session_id"]);
                if (session_id != SessionId) return;
                llRegionSayTo(WearerKey, 0, "TPE confirmation timed out.");
                if (CurrentUser != WearerKey) {
                    llRegionSayTo(CurrentUser, 0, "TPE confirmation timed out.");
                }

                // Close UI for wearer
                close_ui_for_user(WearerKey);

                // Return owner to root menu (if different from wearer)
                if (CurrentUser != WearerKey) {
                    string msg = llList2Json(JSON_OBJECT, [
                        "type", "ui.menu.return",
                        "user", (string)CurrentUser
                    ]);
                    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
                }

                cleanup_session();
            }
        }
    }
}

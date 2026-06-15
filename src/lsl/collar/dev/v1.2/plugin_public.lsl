/*--------------------
PLUGIN: plugin_public.lsl
VERSION: 1.2
REVISION: 6
PURPOSE: Toggle public access mode directly from main menu
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility,
  namespaced internal message protocol
CHANGES:
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (the self-declare reset write-storm); register now announces cat/mask/policy via kernel.register.declare and the kernel is the sole serial writer. Removed write_plugin_reg + the reset-handler reg/policy deletes (kept the plugin.<x>.state delete). Revision baseline normalized to rev 6. See collar_kernel rev 6.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.public";
string PLUGIN_LABEL_ON = "Public: Y";
string PLUGIN_LABEL_OFF = "Public: N";

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
string KEY_PUBLIC_MODE = "public.mode";

/* -------------------- STATE -------------------- */
integer PublicModeEnabled = FALSE;
list gPolicyButtons = [];

/* -------------------- HELPERS -------------------- */


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

/* -------------------- LIFECYCLE MANAGEMENT -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "Access";
integer PLUGIN_ACL_MASK = 56;

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

// Write the current toggle state to LSD at plugin.public.state. kmod_ui
// reads this at render time; kmod_dialogs resolves the final button
// label via its registered buttonconfig. Key convention:
// "plugin.<short>.state" where <short> is the trailing dotted segment of
// the plugin context. Idempotent read-before-write skips the
// linkset_data event when the stored value already matches.
send_state_update() {
    string k = "plugin.public.state";
    string v = (string)PublicModeEnabled;
    if (llLinksetDataRead(k) == v) return;
    llLinksetDataWrite(k, v);
}

register_self() {
    // Button visibility policy (default-deny per ACL level). Announced to the
    // kernel — sole writer of acl.policycontext/reg.<ctx> (collar_kernel rev 6)
    // — instead of being written here, which caused the reset storm.
    string policy = llList2Json(JSON_OBJECT, [
        "3", "toggle",
        "4", "toggle",
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

    // Declare chat alias.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "public",
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
    seed_def(KEY_PUBLIC_MODE, "0");
    integer old_state = PublicModeEnabled;

    string lsd_val = llLinksetDataRead(KEY_PUBLIC_MODE);
    if (lsd_val != "") {
        PublicModeEnabled = (integer)lsd_val;
    }

    if (old_state != PublicModeEnabled) {
        send_state_update();
    }
}

/* -------------------- SETTINGS MODIFICATION -------------------- */

persist_public_mode(integer new_value) {
    if (new_value != 0) new_value = 1;

    // kmod_settings is the canonical writer. Single-writer settings.delta CSV
    // protocol — kmod_settings validates against MANAGED_SETTINGS_KEYS, writes
    // LSD, broadcasts settings.sync; our apply_settings_sync receives the
    // notification and reconciles.
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + KEY_PUBLIC_MODE + ":" + (string)new_value, NULL_KEY);
}

/* -------------------- UI LABEL UPDATE -------------------- */

update_ui_label_and_return(key user) {
    send_state_update();

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "user", (string)user
    ]), NULL_KEY);
}

/* -------------------- DIRECT STATE ACTIONS -------------------- */

// Set public mode to a specific state. No-op with notice if already there.
set_public_mode(key user, integer acl_level, integer target_enabled) {
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);
    if (!btn_allowed("toggle")) {
        llRegionSayTo(user, 0, "Access denied.");
        gPolicyButtons = [];
        return;
    }
    gPolicyButtons = [];

    if (PublicModeEnabled == target_enabled) {
        if (target_enabled) llRegionSayTo(user, 0, "Public access already enabled.");
        else llRegionSayTo(user, 0, "Public access already disabled.");
        return;
    }

    PublicModeEnabled = target_enabled;
    persist_public_mode(PublicModeEnabled);

    if (PublicModeEnabled) llRegionSayTo(user, 0, "Public access enabled.");
    else llRegionSayTo(user, 0, "Public access disabled.");

    send_state_update();
}

handle_subpath(key user, integer acl_level, string subpath) {
    if (subpath == "on") {
        set_public_mode(user, acl_level, TRUE);
        return;
    }
    if (subpath == "off") {
        set_public_mode(user, acl_level, FALSE);
        return;
    }
    llRegionSayTo(user, 0, "Unknown public subcommand: " + subpath);
}

toggle_public_access(key user, integer acl_level) {
    // Verify ACL via policy
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);
    if (!btn_allowed("toggle")) {
        llRegionSayTo(user, 0, "Access denied.");
        gPolicyButtons = [];
        return;
    }
    gPolicyButtons = [];

    // Toggle state
    PublicModeEnabled = !PublicModeEnabled;

    // Persist change
    persist_public_mode(PublicModeEnabled);

    // Notify user
    if (PublicModeEnabled) {
        llRegionSayTo(user, 0, "Public access enabled.");
    }
    else {
        llRegionSayTo(user, 0, "Public access disabled.");
    }

    // Update UI label and return to root menu
    update_ui_label_and_return(user);
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {

        gPolicyButtons = [];
        apply_settings_sync();
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
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) {
                        return;
                    }
                }
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
                llLinksetDataDelete("plugin.public.state");
                llResetScript();
            }

            return;
        }

        /* -------------------- SETTINGS SYNC/DELTA -------------------- */if (num == SETTINGS_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "settings.sync") {
                apply_settings_sync();
                return;
            }

            return;
        }

        /* -------------------- UI DIRECT TOGGLE -------------------- */if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                if (id == NULL_KEY) return;

                integer acl = (integer)llJsonGetValue(msg, ["acl"]);

                string subpath = "";
                string sp = llJsonGetValue(msg, ["subpath"]);
                if (sp != JSON_INVALID) subpath = sp;

                if (subpath != "") {
                    handle_subpath(id, acl, subpath);
                    return;
                }

                // Empty subpath: toggle (matches menu-click behavior).
                toggle_public_access(id, acl);
                return;
            }

            return;
        }

    }
}

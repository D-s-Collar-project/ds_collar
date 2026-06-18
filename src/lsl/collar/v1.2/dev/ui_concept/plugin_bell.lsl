/*--------------------
PLUGIN: plugin_bell.lsl
VERSION: 1.2
REVISION: 9
PURPOSE: Bell visibility and jingling control for the collar
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility,
  namespaced internal message protocol
CHANGES:
- v1.2 rev 9 (sandbox): has_nav 0 → 1 so the menu service reserves the full nav row (<< >> Back) — toggle buttons no longer spill into row0 (all menus need nav). Added a fallback redraw in handle_button_click for the now-present inert <</>> on this single-page menu.
- v1.2 rev 8: show/hide ALL prims whose description contains "bell", not just the first. set_bell_visibility walked the linkset once, cached the first match in BellLink, and only toggled that one prim — so a multi-prim bell only half-showed. Now toggles every match each call (mirrors plugin_lock's set_lock_prims); removed the BellLink cache + its CHANGED_LINK invalidation.
- v1.2 rev 7: bell prim now matched by DESCRIPTION (case-insensitive substring "bell") instead of link name == "bell", the same convention as the leashpoint prim — frees the prim NAME for designers.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (the self-declare write-storm that stranded plugins on reset). register_self now ANNOUNCES cat/mask/policy in kernel.register.declare; the kernel is the sole serial writer. Removed write_plugin_reg helper + the reset-handler LSD deletes (kernel owns clearing). See collar_kernel rev 6.
--------------------*/

integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

string PLUGIN_CONTEXT = "ui.core.bell";
string PLUGIN_LABEL = "Bell";

// Settings keys
string KEY_BELL_VISIBLE = "bell.visible";
string KEY_BELL_SOUND_ENABLED = "bell.enablesound";
string KEY_BELL_VOLUME = "bell.volume";
string KEY_BELL_SOUND = "bell.sound";

// State
integer BellVisible = FALSE;
integer BellSoundEnabled = FALSE;
float BellVolume = 0.3;
string BellSound = "16fcf579-82cb-b110-c1a4-5fa5e1385406";
integer IsMoving = FALSE;

// Jingle timing
float JINGLE_INTERVAL = 1.75;  // Play sound every 1.75 seconds while moving

// Session state
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";
string MenuContext = "";

/* -------------------- HELPERS -------------------- */

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* -------------------- LSD PERSISTENCE HELPERS -------------------- */
integer lsd_int(string lsd_key, integer fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (integer)v;
}

float lsd_float(string lsd_key, float fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (float)v;
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

// Show/hide EVERY prim whose description contains "bell" (case-insensitive) —
// a bell can be built from several prims. Walks the linkset each toggle (toggles
// are infrequent, so the cost is negligible). Mirrors plugin_lock's
// set_lock_prims; replaces the old single cached BellLink that only ever
// toggled the first matching prim.
set_bell_visibility(integer visible) {
    float alpha = 0.0;
    if (visible) alpha = 1.0;
    integer count = llGetNumberOfPrims();
    integer i = 1;
    while (i <= count) {
        string desc = llToLower(llList2String(
            llGetLinkPrimitiveParams(i, [PRIM_DESC]), 0));
        if (llSubStringIndex(desc, "bell") != -1) {
            llSetLinkAlpha(i, alpha, ALL_SIDES);
        }
        i += 1;
    }
    BellVisible = visible;
}

play_jingle() {
    if (BellSound == "" || BellSound == "00000000-0000-0000-0000-000000000000") {
        return;
    }

    if (!BellSoundEnabled) {
        return;
    }

    llTriggerSound(BellSound, BellVolume);
}

/* -------------------- UNIFIED MENU DISPLAY -------------------- */
show_menu(string context, string title, string body, list button_data) {
    SessionId = generate_session_id();
    MenuContext = context;

    // UI-CONCEPT: route through kmod_menu instead of building the dialog
    // ourselves. We hand over only the CONTENT buttons + title/body; kmod_menu
    // adds the Back nav, reverse-orders the content per the dialog convention,
    // and forwards to kmod_dialogs. "category" non-empty makes the nav a Back
    // (vs Close). The click still returns by session_id.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.render",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "menu_type", PLUGIN_CONTEXT,
        "title", title,
        "body", body,
        "category", PLUGIN_CATEGORY,
        "has_nav", 1,
        "buttons", llList2Json(JSON_ARRAY, button_data)
    ]), NULL_KEY);
}

/* -------------------- PLUGIN REGISTRATION -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "Appearance";
integer PLUGIN_ACL_MASK = 56;

register_self() {
    // Per-button visibility policy. Was written straight to LSD here; now
    // announced to the kernel, which is the SOLE writer of acl.policycontext
    // (and reg.<ctx>) — see collar_kernel rev 6. ACL 1 (Public) and ACL 2
    // (Owned wearer) are excluded — bell settings are owner-imposed controls.
    string policy = llList2Json(JSON_OBJECT, [
        "3", "Show,Sound,Volume +,Volume -",
        "4", "Show,Sound,Volume +,Volume -",
        "5", "Show,Sound,Volume +,Volume -"
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
        "alias",   "bell",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

/* -------------------- MENU SYSTEM -------------------- */
show_main_menu() {
    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    string visible_label;
    if (BellVisible) {
        visible_label = "Show: Y";
    } else {
        visible_label = "Show: N";
    }

    string sound_label;
    if (BellSoundEnabled) {
        sound_label = "Sound: On";
    } else {
        sound_label = "Sound: Off";
    }

    // CONTENT buttons only, in top-to-bottom reading order — kmod_menu adds the
    // Back nav and reverse-orders these. No per-plugin layout work anymore.
    list button_data = [];
    if (btn_allowed("Show")) button_data += [btn(visible_label, "toggle_visible")];
    if (btn_allowed("Sound")) button_data += [btn(sound_label, "toggle_sound")];
    if (btn_allowed("Volume +")) button_data += [btn("Volume +", "vol_up")];
    if (btn_allowed("Volume -")) button_data += [btn("Volume -", "vol_down")];

    string body = "Bell Control\n\n";
    body += "Visibility: " + (string)BellVisible + "\n";
    body += "Sound: " + (string)BellSoundEnabled + "\n";
    body += "Volume: " + (string)((integer)(BellVolume * 100)) + "%";

    show_menu("main", "Bell", body, button_data);
}

/* -------------------- SETTINGS MODIFICATION -------------------- */
persist_bell_setting(string setting_key, string value) {
    // Single-writer settings.delta CSV protocol — kmod_settings sole LSD writer.
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + setting_key + ":" + value, NULL_KEY);
}

/* -------------------- CHAT SUBCOMMAND HANDLING -------------------- */

// Set bell visibility idempotently; gated by "Show" policy.
set_bell_visible_state(key user, integer acl_level, integer target_visible) {
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);
    if (!btn_allowed("Show")) {
        llRegionSayTo(user, 0, "Access denied.");
        gPolicyButtons = [];
        return;
    }
    gPolicyButtons = [];

    if (BellVisible == target_visible) {
        if (target_visible) llRegionSayTo(user, 0, "Bell already shown.");
        else llRegionSayTo(user, 0, "Bell already hidden.");
        return;
    }

    BellVisible = target_visible;
    set_bell_visibility(BellVisible);
    persist_bell_setting(KEY_BELL_VISIBLE, (string)BellVisible);
    if (BellVisible) llRegionSayTo(user, 0, "Bell shown.");
    else llRegionSayTo(user, 0, "Bell hidden.");
}

// Set bell sound enabled state idempotently; gated by "Sound" policy.
set_bell_sound_state(key user, integer acl_level, integer target_enabled) {
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);
    if (!btn_allowed("Sound")) {
        llRegionSayTo(user, 0, "Access denied.");
        gPolicyButtons = [];
        return;
    }
    gPolicyButtons = [];

    if (BellSoundEnabled == target_enabled) {
        if (target_enabled) llRegionSayTo(user, 0, "Bell sound already enabled.");
        else llRegionSayTo(user, 0, "Bell sound already disabled.");
        return;
    }

    BellSoundEnabled = target_enabled;
    persist_bell_setting(KEY_BELL_SOUND_ENABLED, (string)BellSoundEnabled);
    if (BellSoundEnabled) llRegionSayTo(user, 0, "Bell sound enabled.");
    else llRegionSayTo(user, 0, "Bell sound disabled.");
}

// Adjust bell volume by delta; gated by the matching "Volume +/-" policy.
adjust_bell_volume(key user, integer acl_level, float delta, string policy_label) {
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);
    if (!btn_allowed(policy_label)) {
        llRegionSayTo(user, 0, "Access denied.");
        gPolicyButtons = [];
        return;
    }
    gPolicyButtons = [];

    BellVolume = BellVolume + delta;
    if (BellVolume > 1.0) BellVolume = 1.0;
    if (BellVolume < 0.0) BellVolume = 0.0;
    persist_bell_setting(KEY_BELL_VOLUME, (string)BellVolume);
    llRegionSayTo(user, 0, "Volume: " + (string)((integer)(BellVolume * 100)) + "%");
}

handle_subpath(key user, integer acl_level, string subpath) {
    if (subpath == "show") {
        set_bell_visible_state(user, acl_level, TRUE);
        return;
    }
    if (subpath == "hide") {
        set_bell_visible_state(user, acl_level, FALSE);
        return;
    }
    if (subpath == "sound") {
        set_bell_sound_state(user, acl_level, TRUE);
        return;
    }
    if (subpath == "silent") {
        set_bell_sound_state(user, acl_level, FALSE);
        return;
    }
    if (subpath == "vol.up") {
        adjust_bell_volume(user, acl_level, 0.1, "Volume +");
        return;
    }
    if (subpath == "vol.dn") {
        adjust_bell_volume(user, acl_level, -0.1, "Volume -");
        return;
    }
    if (subpath == "jingle") {
        if (!BellSoundEnabled) {
            llRegionSayTo(user, 0, "Bell sound is disabled.");
            return;
        }
        play_jingle();
        return;
    }
    llRegionSayTo(user, 0, "Unknown bell subcommand: " + subpath);
}

/* -------------------- BUTTON HANDLER -------------------- */
handle_button_click(string msg) {
    // Content buttons carry a context; nav buttons (Back) arrive with an empty
    // context, so fall back to the button label for those.
    string cmd = llJsonGetValue(msg, ["context"]);
    if (cmd == JSON_INVALID || cmd == "") cmd = llJsonGetValue(msg, ["button"]);

    if (MenuContext == "main") {
        if (cmd == "Back") {
            return_to_root();
        }
        else if (cmd == "vol_up") {
            BellVolume = BellVolume + 0.1;
            if (BellVolume > 1.0) BellVolume = 1.0;
            persist_bell_setting(KEY_BELL_VOLUME, (string)BellVolume);
            llRegionSayTo(CurrentUser, 0, "Volume: " + (string)((integer)(BellVolume * 100)) + "%");
            show_main_menu();
        }
        else if (cmd == "vol_down") {
            BellVolume = BellVolume - 0.1;
            if (BellVolume < 0.0) BellVolume = 0.0;
            persist_bell_setting(KEY_BELL_VOLUME, (string)BellVolume);
            llRegionSayTo(CurrentUser, 0, "Volume: " + (string)((integer)(BellVolume * 100)) + "%");
            show_main_menu();
        }
        else if (cmd == "toggle_visible") {
            BellVisible = !BellVisible;
            set_bell_visibility(BellVisible);
            persist_bell_setting(KEY_BELL_VISIBLE, (string)BellVisible);
            if (BellVisible) {
                llRegionSayTo(CurrentUser, 0, "Bell shown.");
            } else {
                llRegionSayTo(CurrentUser, 0, "Bell hidden.");
            }
            show_main_menu();
        }
        else if (cmd == "toggle_sound") {
            BellSoundEnabled = !BellSoundEnabled;
            persist_bell_setting(KEY_BELL_SOUND_ENABLED, (string)BellSoundEnabled);
            if (BellSoundEnabled) {
                llRegionSayTo(CurrentUser, 0, "Bell sound enabled.");
            } else {
                llRegionSayTo(CurrentUser, 0, "Bell sound disabled.");
            }
            show_main_menu();
        }
        else {
            // Unknown button (e.g. the inert << >> on a single-page menu) —
            // just redraw.
            show_main_menu();
        }
    }
}

/* -------------------- NAVIGATION -------------------- */
return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "user", (string)CurrentUser
    ]), NULL_KEY);
    cleanup_session();
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
    MenuContext = "";
}

/* -------------------- SETTINGS HANDLING -------------------- */

// v1.2 seed-default: write this plugin's default into LSD only if absent
// (no broadcast). Makes LSD the complete, self-describing collar state and
// self-heals if the notecard manifest later drops the key. See kmod_settings
// settings.seed.
seed_def(string lsd_key, string value) {
    if (llLinksetDataRead(lsd_key) == "")
        llMessageLinked(LINK_SET, SETTINGS_BUS, "settings.seed:" + lsd_key + ":" + value, NULL_KEY);
}

apply_settings_sync() {
    seed_def(KEY_BELL_VISIBLE, "0");
    seed_def(KEY_BELL_SOUND_ENABLED, "0");
    seed_def(KEY_BELL_VOLUME, "0.3");
    seed_def(KEY_BELL_SOUND, "16fcf579-82cb-b110-c1a4-5fa5e1385406");

    // Read all settings directly from LSD; compare with previous state
    // and trigger side effects only when values actually change.

    integer prev_visible = BellVisible;

    BellVisible = lsd_int(KEY_BELL_VISIBLE, BellVisible);
    BellSoundEnabled = lsd_int(KEY_BELL_SOUND_ENABLED, BellSoundEnabled);
    BellVolume = lsd_float(KEY_BELL_VOLUME, BellVolume);

    string tmp = llLinksetDataRead(KEY_BELL_SOUND);
    if (tmp != "") BellSound = tmp;

    // Side effect: visibility changed — update prim alpha
    if (BellVisible != prev_visible) {
        set_bell_visibility(BellVisible);
    }
}

/* -------------------- EVENT HANDLERS -------------------- */
default {
    state_entry() {

        cleanup_session();

        // Restore from LSD (persists through relog); fall back to safe defaults on first wear
        BellVisible = lsd_int(KEY_BELL_VISIBLE, FALSE);
        BellSoundEnabled = lsd_int(KEY_BELL_SOUND_ENABLED, FALSE);
        BellVolume = lsd_float(KEY_BELL_VOLUME, 0.3);
        set_bell_visibility(BellVisible);

        // Apply any LSD-persisted settings (e.g. BellSound from notecard seeding)
        apply_settings_sync();

        register_self();
    }

    // No on_rez handler — bell state survives attach/detach by design.
    // settings.sync from kmod_settings re-applies anything stale on reload.

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }

    timer() {
        // Continuous jingling while moving
        if (IsMoving && BellVisible && BellSoundEnabled) {
            play_jingle();
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
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) return;
                }
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
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

        /* -------------------- UI START -------------------- */if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                CurrentUser = id;
                UserAcl = (integer)llJsonGetValue(msg, ["acl"]);

                string subpath = "";
                string sp = llJsonGetValue(msg, ["subpath"]);
                if (sp != JSON_INVALID) subpath = sp;

                if (subpath != "") {
                    handle_subpath(id, UserAcl, subpath);
                    return;
                }

                show_main_menu();
                return;
            }

            return;
        }

        /* -------------------- DIALOG RESPONSE -------------------- */if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.dialog.response") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID || llJsonGetValue(msg, ["button"]) == JSON_INVALID) return;
                string response_session = llJsonGetValue(msg, ["session_id"]);
                if (response_session != SessionId) return;

                handle_button_click(msg);
                return;
            }

            if (msg_type == "ui.dialog.timeout") {
                string timeout_session = llJsonGetValue(msg, ["session_id"]);
                if (timeout_session == JSON_INVALID) return;
                if (timeout_session != SessionId) return;
                cleanup_session();
                return;
            }

            return;
        }
    }

    moving_start() {
        if (!IsMoving) {
            IsMoving = TRUE;

            // Play first jingle immediately
            if (BellVisible && BellSoundEnabled) {
                play_jingle();
            }

            // Start timer for continuous jingling
            llSetTimerEvent(JINGLE_INTERVAL);
        }
    }

    moving_end() {
        if (IsMoving) {
            IsMoving = FALSE;

            // Stop the timer
            llSetTimerEvent(0.0);
        }
    }
}

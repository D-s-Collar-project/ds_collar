/*--------------------
PLUGIN: plugin_relay.lsl
VERSION: 1.2
REVISION: 12
PURPOSE: Wearer-facing UI for the collar's RLV relay.
ARCHITECTURE: Menu/chat-alias front-end on top of kmod_rlv. The relay
  protocol engine (RELAY_CHANNEL listen, auth queue, ASK dialog, source
  bookkeeping, refcount, distance GC, TempObj/Av lists) lives in
  kmod_rlv; this script just renders the wearer menu, persists Mode /
  Hardcore via SETTINGS_BUS, and signals kmod_rlv on UI_BUS for safeword
  / ground-rez / source-list lookups.
CHANGES:
- v1.2 rev 12: main + mode menus to menu.fixed, bound-by list to dialog.info (dropped the MainPage cursor + nav:prev/next); cleans up on the new ui.dialog.close.
- v1.2 rev 11: FULL migration to context routing + pagination. Every button now carries a context via a new btn() helper (main: mode/bound/safeword/unbind; mode: off/ask/on/hc_on/hc_off) and the handler routes by context, not the raw button label — closes the last label-router (the all-by-context invariant). Added a MenuContext (main/mode/list) so nav pages/redraws the right menu, and a MainPage cursor paginating the main menu (clamp/wrap, nav:prev/nav:next, single-page redraw). Response handler reads context not button.
- v1.2 rev 10: retired the "safeword" chat alias + its now-dead handle_subpath branch — the chat safeword family (the bare word, "<prefix> safeword", "<prefix> safeword <word>") is special-cased in kmod_chat so it bypasses the ACL-gated dispatch and works in TPE / lockdown. The relay menu Safeword/Unbind buttons are UNCHANGED: they still fire relay.safeword, which kmod_rlv routes to do_safeword_clear(FALSE) = relay-only — the bit-flip (relay source → relay-only; the safeword word → system-wide). The relay-clear chat verb is gone (that verb is the safeword now); relay-only clear stays on the menu button.
- v1.2 rev 9: nav-row consistency — has_nav 0→1 on all three menus so the << >> Back row matches the rest of the UI (was a lone Back); the handler's existing catch-all redraws the inert << >>.
- v1.2 rev 8: menu-service migration. show_main_menu / show_mode_menu / render_object_list now render via the pager (ui.menu.render, has_nav=0; the "Bound by" source list is an info pager — body + Back, no content buttons). message→body, the local "Back" dropped from each list (the service supplies it), sends moved DIALOG_BUS→UI_BUS. Buttons stay plain label strings — render_menu treats the list opaquely and the handler already routes by button label — so handle_button_click is unchanged. Mode/hardcore/safeword/source logic untouched. (Back still exits to root from every relay screen, as before.)
- v1.2 rev 7: RLV gating — ORed bit 0x40 into PLUGIN_ACL_MASK (60→124) so kmod_ui drops this RLV-dependent plugin from the menu when rlv.active=0 (published by kmod_bootstrap). No ACL-visibility change — bit 6 sits above the level bits 1-5.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. See collar_kernel rev 6.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.relay";
string PLUGIN_LABEL = "RLV Relay";

/* -------------------- RELAY MODE CONSTANTS -------------------- */
integer MODE_OFF = 0;
integer MODE_ON  = 1;
integer MODE_ASK = 2;

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_RELAY_MODE = "relay.mode";
string KEY_RELAY_HARDCORE = "relay.hardcoremode";

/* -------------------- STATE -------------------- */

// Cached display state, read from LSD. Refreshed on menu open and on
// settings.delta.
integer Mode = MODE_ASK;
integer Hardcore = FALSE;
integer IsAttached = FALSE;

// Menu session.
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";
string MenuContext = "";  // "main" | "mode" | "list" — which menu is showing

// Pending "Bound by..." request — TRUE while we're waiting for kmod_rlv's
// relay.list.response. We render once it arrives.
integer AwaitingList = FALSE;


/* -------------------- HELPERS -------------------- */

integer lsd_int(string lsd_key, integer fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (integer)v;
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

string truncate_name(string name, integer max_len) {
    if (llStringLength(name) <= max_len) return name;
    return llGetSubString(name, 0, max_len - 4) + "...";
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

string mode_str() {
    if (!IsAttached)              return "OFF (not worn)";
    if (Mode == MODE_OFF)         return "OFF";
    if (Mode == MODE_ASK)         return "ASK";
    if (Hardcore)                 return "HARDCORE";
    return "ON";
}

// v1.2 seed-default: write this plugin's default into LSD only if absent
// (no broadcast). Makes LSD the complete, self-describing collar state and
// self-heals if the notecard manifest later drops the key. See kmod_settings
// settings.seed.
seed_def(string lsd_key, string value) {
    if (llLinksetDataRead(lsd_key) == "")
        llMessageLinked(LINK_SET, SETTINGS_BUS, "settings.seed:" + lsd_key + ":" + value, NULL_KEY);
}

refresh_mode() {
    seed_def(KEY_RELAY_MODE, (string)MODE_ASK);
    seed_def(KEY_RELAY_HARDCORE, "0");
    Mode = lsd_int(KEY_RELAY_MODE, MODE_ASK);
    Hardcore = lsd_int(KEY_RELAY_HARDCORE, FALSE);
}


/* -------------------- LIFECYCLE -------------------- */

// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "RLV";
integer PLUGIN_ACL_MASK = 124;  // 60 (ACL 2-5) | 0x40 RLV-required: kmod_ui hides when rlv.active=0

register_self() {
    string policy = llList2Json(JSON_OBJECT, [
        "2", "Mode,Bound by...,Safeword",
        "3", "Mode,Bound by...,Unbind,HC OFF,HC ON",
        "4", "Mode,Bound by...,Safeword",
        "5", "Mode,Bound by...,Unbind,HC OFF,HC ON"
    ]);

    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName(),
        "cat", PLUGIN_CATEGORY,
        "mask", (string)PLUGIN_ACL_MASK,
        "policy", policy
    ]), NULL_KEY);

    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "relay",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
    // The "safeword" alias was retired in favour of the wearer's personal
    // safeword: <prefix>safeword is now handled by kmod_chat (manage the word),
    // and the bare word triggers the full release. Relay-clear stays on the
    // relay menu (Safeword / Unbind).
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}


/* -------------------- SETTINGS -------------------- */

persist_mode(integer new_mode) {
    // Single-writer settings.delta CSV protocol — kmod_settings sole LSD writer.
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + KEY_RELAY_MODE + ":" + (string)new_mode, NULL_KEY);
}

persist_hardcore(integer new_hardcore) {
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + KEY_RELAY_HARDCORE + ":" + (string)new_hardcore, NULL_KEY);
}


/* -------------------- MENU SYSTEM -------------------- */

// Button data entry: {label, context}. Every relay button routes by its
// context (the project invariant), never the visible label.
string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

show_main_menu() {
    SessionId = generate_session_id();
    MenuContext = "main";
    refresh_mode();
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    string message = "RLV Relay Menu\nMode: " + mode_str();

    // Pager (has_nav=1): full << >> Back nav row; content = the actions.
    list buttons = [];
    if (btn_allowed("Mode"))                       buttons += [btn("Mode", "mode")];
    if (btn_allowed("Bound by..."))                buttons += [btn("Bound by...", "bound")];
    if (btn_allowed("Safeword") && !Hardcore)      buttons += [btn("Safeword", "safeword")];
    if (btn_allowed("Unbind"))                     buttons += [btn("Unbind", "unbind")];

    // menu.fixed — a small structural action set; never paginates.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "menu.fixed",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "title",      PLUGIN_LABEL + " Menu",
        "body",       message,
        "buttons",    llList2Json(JSON_ARRAY, buttons)
    ]), NULL_KEY);
}

show_mode_menu() {
    SessionId = generate_session_id();
    MenuContext = "mode";
    refresh_mode();

    string message = "RLV Relay Mode: " + mode_str();

    list buttons = [btn("OFF", "off"), btn("ASK", "ask"), btn("ON", "on")];
    if (Mode == MODE_ON) {
        if (Hardcore) {
            if (btn_allowed("HC OFF")) buttons += [btn("HC OFF", "hc_off")];
        } else {
            if (btn_allowed("HC ON"))  buttons += [btn("HC ON", "hc_on")];
        }
    }

    // menu.fixed — the mode set (OFF/ASK/ON + HC toggle); never paginates.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "menu.fixed",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "title",      "Relay Mode",
        "body",       message,
        "buttons",    llList2Json(JSON_ARRAY, buttons)
    ]), NULL_KEY);
}

// Called when relay.list.response arrives. sources_json is a JSON array
// of {name, restr_count} objects.
render_object_list(string sources_json) {
    SessionId = generate_session_id();
    MenuContext = "list";

    list arr = [];
    if (sources_json != "" && sources_json != JSON_INVALID) {
        // Parse the array by walking indices until JSON_INVALID.
        integer i = 0;
        string entry = llJsonGetValue(sources_json, [(string)i]);
        while (entry != JSON_INVALID) {
            arr += [entry];
            i += 1;
            entry = llJsonGetValue(sources_json, [(string)i]);
        }
    }

    integer source_count = llGetListLength(arr);
    string message;
    if (source_count == 0) {
        message = "No active sources.";
    } else {
        message = "Bound by:\n";
        integer i = 0;
        while (i < source_count) {
            string entry = llList2String(arr, i);
            string nm = llJsonGetValue(entry, ["name"]);
            string rcs = llJsonGetValue(entry, ["restr_count"]);
            message += (string)(i + 1) + ". " + truncate_name(nm, 24);
            if (rcs != JSON_INVALID && rcs != "0") {
                message += " [" + rcs + "]";
            }
            message += "\n";
            i += 1;
        }
    }

    // dialog.info — a terminal read-out (the source list is the body); a single
    // OK dismisses back to the main menu (handler catch-all for MenuContext "list").
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "dialog.info",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "title",      "Bound by",
        "body",       message
    ]), NULL_KEY);
}


/* -------------------- BUTTON HANDLING -------------------- */

set_mode(integer new_mode, integer clear_hardcore) {
    Mode = new_mode;
    if (clear_hardcore) Hardcore = FALSE;
    persist_mode(new_mode);
    if (clear_hardcore) persist_hardcore(FALSE);
}

// Every button routes by context (nav:* for navigation, action contexts for
// content). MenuContext tracks which menu is showing so nav pages/redraws the
// right one. Action contexts are globally unique, so no per-menu branching.
handle_button_click(string ctx) {
    // Navigation. (Close is intercepted by kmod_dialogs; the fixed menus emit
    // no << >>, so only nav:back arrives here.)
    if (ctx == "nav:back") {
        return_to_root();
        return;
    }

    // Main-menu actions.
    if (ctx == "mode") {
        show_mode_menu();
        return;
    }
    if (ctx == "bound") {
        AwaitingList = TRUE;
        llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
            "type", "relay.list.request"
        ]), NULL_KEY);
        return;
    }
    if (ctx == "safeword") {
        if (btn_allowed("Safeword") && !Hardcore) {
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "relay.safeword"
            ]), NULL_KEY);
            llRegionSayTo(CurrentUser, 0, "Safeword used - all restrictions cleared");
            show_main_menu();
        }
        return;
    }
    if (ctx == "unbind") {
        if (btn_allowed("Unbind")) {
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "relay.safeword"
            ]), NULL_KEY);
            llRegionSayTo(CurrentUser, 0, "Unbound - all restrictions cleared");
            show_main_menu();
        }
        return;
    }

    // Mode-menu actions.
    if (ctx == "off") {
        set_mode(MODE_OFF, TRUE);
        llRegionSayTo(CurrentUser, 0, "Mode set to OFF");
        show_mode_menu();
        return;
    }
    if (ctx == "ask") {
        set_mode(MODE_ASK, TRUE);
        llRegionSayTo(CurrentUser, 0, "Mode set to ASK");
        show_mode_menu();
        return;
    }
    if (ctx == "on") {
        Mode = MODE_ON;
        persist_mode(MODE_ON);
        if (!Hardcore) llRegionSayTo(CurrentUser, 0, "Mode set to ON");
        show_mode_menu();
        return;
    }
    if (ctx == "hc_on") {
        if (btn_allowed("HC ON")) {
            Hardcore = TRUE;
            Mode = MODE_ON;
            persist_hardcore(TRUE);
            persist_mode(MODE_ON);
            llRegionSayTo(CurrentUser, 0, "Hardcore mode ENABLED");
            show_mode_menu();
        }
        return;
    }
    if (ctx == "hc_off") {
        if (btn_allowed("HC OFF")) {
            Hardcore = FALSE;
            Mode = MODE_ON;
            persist_hardcore(FALSE);
            persist_mode(MODE_ON);
            llRegionSayTo(CurrentUser, 0, "Hardcore mode DISABLED");
            show_mode_menu();
        }
        return;
    }

    // Unknown — redraw the current menu.
    if (MenuContext == "mode") show_mode_menu();
    else                       show_main_menu();
}


/* -------------------- NAVIGATION -------------------- */

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user", (string)CurrentUser
    ]), CurrentUser);
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
    AwaitingList = FALSE;
}


/* -------------------- MENU MESSAGE HANDLERS -------------------- */

handle_start(string msg) {
    if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["user"]) == JSON_INVALID) return;

    string context = llJsonGetValue(msg, ["context"]);
    if (context != PLUGIN_CONTEXT) return;

    key user = (key)llJsonGetValue(msg, ["user"]);
    integer acl = (integer)llJsonGetValue(msg, ["acl"]);

    string subpath = "";
    string sp = llJsonGetValue(msg, ["subpath"]);
    if (sp != JSON_INVALID) subpath = sp;

    if (subpath != "") {
        handle_subpath(user, acl, subpath);
        return;
    }

    CurrentUser = user;
    UserAcl = acl;
    show_main_menu();
}

handle_subpath(key user, integer acl_level, string subpath) {
    CurrentUser = user;
    UserAcl = acl_level;
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);

    if (subpath == "on" || subpath == "off" || subpath == "ask") {
        if (!btn_allowed("Mode")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        if (subpath == "off")      set_mode(MODE_OFF, TRUE);
        else if (subpath == "ask") set_mode(MODE_ASK, TRUE);
        else                       set_mode(MODE_ON,  FALSE);
        llRegionSayTo(user, 0, "Mode set to " + llToUpper(subpath) + ".");
        gPolicyButtons = [];
        return;
    }

    llRegionSayTo(user, 0, "Unknown relay subcommand: " + subpath);
    gPolicyButtons = [];
}

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;
    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";
    handle_button_click(ctx);
}

handle_dialog_timeout(string msg) {
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session == JSON_INVALID) return;
    if (session != SessionId) return;
    cleanup_session();
}


/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {

        cleanup_session();
        IsAttached = (llGetAttached() != 0);
        refresh_mode();

        register_self();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    attach(key id) {
        // kmod_rlv owns engine response to attach/detach; we only track
        // IsAttached for menu display.
        IsAttached = (id != NULL_KEY);
        if (IsAttached) refresh_mode();
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.register.refresh") {
                register_self();
            }
            else if (msg_type == "kernel.ping") {
                send_pong();
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                string ctx = llJsonGetValue(msg, ["context"]);
                if (ctx != JSON_INVALID && ctx != "" && ctx != PLUGIN_CONTEXT) return;
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync") {
                refresh_mode();
            }
        }
        else if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                handle_start(msg);
            }
            else if (msg_type == "relay.list.response") {
                if (!AwaitingList) return;
                AwaitingList = FALSE;
                string sources = llJsonGetValue(msg, ["sources"]);
                if (sources == JSON_INVALID) sources = "";
                render_object_list(sources);
            }
            else if (msg_type == "relay.forceoff") {
                // The engine (kmod_rlv) forced the relay off (ground-rez/safeword)
                // and reacted in-memory; we own relay config, so we persist it.
                persist_mode(MODE_OFF);
                persist_hardcore(FALSE);
            }
        }
        else if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                handle_dialog_response(msg);
            }
            else if (msg_type == "ui.dialog.timeout") {
                handle_dialog_timeout(msg);
            }
            else if (msg_type == "ui.dialog.close") {
                if (llJsonGetValue(msg, ["session_id"]) == SessionId) cleanup_session();
            }
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}

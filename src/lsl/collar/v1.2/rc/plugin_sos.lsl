/*--------------------
PLUGIN: plugin_sos.lsl
VERSION: 1.2
REVISION: 7
PURPOSE: Emergency wearer-accessible actions (OOC safety hatch)
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.2 rev 7: menu-service migration. show_sos_menu → pager (ui.menu.render, has_nav=1; the GRADUATED actions — Unleash / Clear RLV / Clear Relay / Escape — are preserved as content, only the local Back drops to the service's nav row), show_runaway_confirm → modal mode (No-first, returns confirm/cancel — unchanged routing). Sends moved DIALOG_BUS→UI_BUS; the response handler now falls back to the button label for nav and redraws on the inert << >>; Back routes by "back"/"Back". Emergency action logic untouched.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. See collar_kernel rev 6.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.sos.911";
string PLUGIN_LABEL = "SOS";

/* -------------------- STATE -------------------- */
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";
string MenuContext = "main";

/* -------------------- HELPERS -------------------- */

// Helper: create a button_data entry with label and command context
string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

string generate_session_id() {
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

/* -------------------- PLUGIN REGISTRATION -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "SOS";
integer PLUGIN_ACL_MASK = 5;

register_self() {
    // SOS is the wearer's OOC safety hatch. Visibility tracks the threat
    // model, not symmetry:
    //   0 = TPE wearer: full set; SOS is their sole accessible menu, so
    //       Unleash/Clear RLV/Clear Relay are essential here. Runaway is
    //       always shown — TPE wearers cannot reach Access → Runaway.
    //   2 = Owned wearer: Runaway listed in the static policy, but stripped
    //       at runtime by show_sos_menu when access.enablerunaway is TRUE.
    //       When in-scene Runaway is enabled the wearer already has Access
    //       → Runaway, so SOS Runaway would be a redundant long-touch
    //       foot-gun. When in-scene Runaway is disabled, SOS Runaway
    //       remains the wearer's only OOC escape.
    //   4 = Unowned wearer: not exposed. No ownership to escape, no abuse
    //       vector. Reset Config in Maint covers "wipe my config" cleanly;
    //       Runaway would just be a destructive duplicate.
    // Per-button visibility policy. Was written straight to LSD here; now
    // announced to the kernel, the SOLE writer of acl.policycontext (and
    // reg.<ctx>) — see collar_kernel rev 6.
    string policy = llList2Json(JSON_OBJECT, [
        "0", "Unleash,Clear RLV,Clear Relay,Runaway",
        "2", "Runaway"
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

    // Declare chat aliases.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "sos",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "sosunleash",
        "context", PLUGIN_CONTEXT + ".unleash"
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "sosrestrict",
        "context", PLUGIN_CONTEXT + ".restrict"
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "sosrelay",
        "context", PLUGIN_CONTEXT + ".relay"
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "sosrunaway",
        "context", PLUGIN_CONTEXT + ".runaway"
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

/* -------------------- MENU DISPLAY -------------------- */
show_sos_menu() {
    MenuContext = "main";
    SessionId = generate_session_id();

    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    // Runtime filter: at ACL 2, Runaway is the OOC escape only when the
    // in-scene Access → Runaway path is unavailable. If access.enablerunaway
    // is TRUE the wearer already has it the normal way; strip the SOS
    // duplicate so long-touch isn't a redundant foot-gun.
    if (UserAcl == 2) {
        if ((integer)llLinksetDataRead("access.enablerunaway")) {
            integer idx = llListFindList(gPolicyButtons, ["Runaway"]);
            if (idx != -1) {
                gPolicyButtons = llDeleteSubList(gPolicyButtons, idx, idx);
            }
        }
    }

    // llDialog displays buttons in rows of 3, bottom-left to top-right.
    // Build buttons + matching body lines from policy so non-TPE wearers
    // (Runaway-only) don't see bullets for actions they can't take.
    list button_data = [];
    string body = "EMERGENCY ACCESS\n\nChoose an action:\n";

    if (btn_allowed("Unleash")) {
        button_data += [btn("Unleash", "unleash")];
        body += "• Unleash - Release leash\n";
    }
    if (btn_allowed("Clear RLV")) {
        button_data += [btn("Clear RLV", "clear_rlv")];
        body += "• Clear RLV - Clear RLV restrictions\n";
    }
    if (btn_allowed("Clear Relay")) {
        button_data += [btn("Clear Relay", "clear_relay")];
        body += "• Clear Relay - Clear relay restrictions\n";
    }
    if (btn_allowed("Runaway")) {
        // UI label is "Escape" (less alarmist than "Runaway" / "Nuclear");
        // routing context and policy key remain "runaway" / "Runaway" to
        // keep the wire protocol and ACL CSV stable.
        button_data += [btn("Escape", "runaway")];
        body += "• Escape - Escape an abusive setting. Resets the collar to factory settings.";
    }

    // Pager (has_nav=1): the service supplies the << >> Back nav row; content =
    // the graduated emergency actions (preserved — never collapse to one action).
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      "SOS Emergency",
        "body",       body,
        "category",   PLUGIN_CATEGORY,
        "has_nav",    1,
        "buttons",    llList2Json(JSON_ARRAY, button_data),
        "page",       0
    ]), NULL_KEY);
}

show_runaway_confirm() {
    MenuContext = "runaway_confirm";
    SessionId = generate_session_id();

    string body = "EMERGENCY ESCAPE\n\n";
    body += "This will remove ownership entirely and erase ALL collar settings. ";
    body += "The collar will return to an unowned, unlocked state.\n\n";
    body += "This cannot be undone.\n\n";
    body += "Proceed?";

    // Modal confirm: the service forces No (the safe choice) to slot 0 and
    // returns confirm/cancel — what the runaway_confirm branch already routes on.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "modal",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "title",      "Escape",
        "body",       body
    ]), NULL_KEY);
}

/* -------------------- EMERGENCY ACTIONS -------------------- */
action_unleash() {
    // Send emergency leash release on UI_BUS (bypasses ACL)
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "sos.leash.release"
    ]), CurrentUser);

    llRegionSayTo(CurrentUser, 0, "Leash released.");
}

action_clear_rlv() {
    // Structured clear (consumer-scoped via kmod_rlv), NOT a blanket @clear.
    // Drops the bad-actor-reachable restriction sources -- plugin_restrict's
    // families and any relay-routed restrictions -- while leaving the
    // CONSENTED foundational restrictions in place, chiefly the collar lock
    // (@detach is a separate consumer). A raw @clear is wrong twice over: it
    // would strip the consented lock, and it cannot reach a bad actor's own
    // object anyway (RLV @clear is scoped to the issuing object). The leash
    // is its own consumer with its own Unleash button.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "sos.restrict.clear"
    ]), CurrentUser);
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "sos.relay.clear"
    ]), CurrentUser);

    llRegionSayTo(CurrentUser, 0, "Imposed restrictions cleared -- the collar lock stands.");
}

action_clear_relay() {
    // Send emergency relay clear on UI_BUS (bypasses ACL)
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "sos.relay.clear"
    ]), CurrentUser);

    llRegionSayTo(CurrentUser, 0, "All relay restrictions cleared.");
}

// SOS Runaway: nuclear, irreversible, unconditional. settings.runaway hits
// kmod_settings.handle_runaway() → factory_reset(): notecard removed, LSD
// wiped, kernel.reset.factory broadcast, script reset. Bypasses the in-scene
// access.enablerunaway gate by design — this is the OOC safety hatch and
// must work even when an owner has trapped the wearer with runaway disabled.
action_runaway() {
    llRegionSayTo(CurrentUser, 0, "Escape initiated. Wiping collar...");

    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.runaway"
    ]), NULL_KEY);
}

/* -------------------- CHAT SUBCOMMAND HANDLING -------------------- */

handle_subpath(key user, integer acl_level, string subpath) {
    CurrentUser = user;
    UserAcl = acl_level;

    if (subpath == "unleash") {
        action_unleash();
        return;
    }
    if (subpath == "restrict") {
        action_clear_rlv();
        return;
    }
    if (subpath == "relay") {
        action_clear_relay();
        return;
    }
    if (subpath == "runaway") {
        // Same gate as the menu: an ACL 2 wearer with in-scene Runaway
        // already enabled doesn't get the SOS duplicate. Steer them to
        // the normal path. ACL 0 (TPE) and runaway-disabled ACL 2 fall
        // through to the confirm dialog.
        if (acl_level == 2 && (integer)llLinksetDataRead("access.enablerunaway")) {
            llRegionSayTo(user, 0, "Use Access → Runaway from the collar menu instead.");
            return;
        }
        // Chat-alias path: still requires confirmation. Open the dialog
        // rather than firing the nuclear option from a single chat command.
        show_runaway_confirm();
        return;
    }
    llRegionSayTo(user, 0, "Unknown SOS subcommand: " + subpath);
}

/* -------------------- BUTTON HANDLER -------------------- */
handle_button_click(string cmd) {

    // Confirmation dialog routing
    if (MenuContext == "runaway_confirm") {
        if (cmd == "confirm") {
            action_runaway();
            // Don't reopen the menu — kmod_settings is about to wipe LSD
            // and broadcast kernel.reset.factory; this script will reset.
            cleanup_session();
            return;
        }
        // Cancel → back to SOS menu
        show_sos_menu();
        return;
    }

    if (cmd == "back" || cmd == "Back") {
        return_to_root();
        return;
    }

    if (cmd == "unleash") {
        action_unleash();
        show_sos_menu();
        return;
    }

    if (cmd == "clear_rlv") {
        action_clear_rlv();
        show_sos_menu();
        return;
    }

    if (cmd == "clear_relay") {
        action_clear_relay();
        show_sos_menu();
        return;
    }

    if (cmd == "runaway") {
        show_runaway_confirm();
        return;
    }

    // Inert << >> on this single-page menu — redraw.
    show_sos_menu();
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
    MenuContext = "main";
}

/* -------------------- EVENT HANDLERS -------------------- */
default {
    state_entry() {

        cleanup_session();
        register_self();
    }

    changed(integer change_mask) {
        if (change_mask & CHANGED_OWNER) {
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
                // Check if this is a targeted reset
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) {
                        return;  // Not for us, ignore
                    }
                }
                // Either no context (broadcast) or matches our context.
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
                llResetScript();
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

                CurrentUser = id;
                UserAcl = acl;
                show_sos_menu();
                return;
            }

            return;
        }

        /* -------------------- DIALOG RESPONSE -------------------- */
        if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;

                string response_session = llJsonGetValue(msg, ["session_id"]);
                if (response_session != SessionId) return;

                string cmd = llJsonGetValue(msg, ["context"]);
                // Nav (<< >> Back) renders as plain buttons with empty context →
                // fall back to the button label so the handler can route them.
                if (cmd == JSON_INVALID || cmd == "") cmd = llJsonGetValue(msg, ["button"]);
                handle_button_click(cmd);
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
}

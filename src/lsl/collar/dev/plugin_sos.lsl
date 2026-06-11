/*--------------------
PLUGIN: plugin_sos.lsl
VERSION: 1.10
REVISION: 14
PURPOSE: Emergency wearer-accessible actions (OOC safety hatch)
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.10 rev 14: Dormancy guard widened to the renamed role-split markers ("D/s Collar updater v1.1" / "(updating)" / "(installing)").
- v1.10 rev 13: "Clear RLV" is now a STRUCTURED clear, not a catch-all. Dropped the blanket llOwnerSay("@clear") and added sos.relay.clear alongside the existing sos.restrict.clear. Both downstream clears are consumer-scoped via kmod_rlv (plugin_restrict -> remove_all_restrictions -> rlv_clear_all -> rlv.clear consumer=restrict; relay safeword clear scopes to relay sources), so they drop only the bad-actor-reachable restrictions while the CONSENTED collar lock (a separate @detach consumer) stands. Rationale: @clear stripped the consented lock too, and could not reach a bad actor's own object regardless (RLV @clear is per-issuing-object). Leash unchanged (its own Unleash button + consumer).
- v1.10 rev 12: Rename the user-facing "Runaway" label to "Escape" in the SOS menu and confirmation dialog. Button: "Escape"; bullet: "Escape an abusive setting. Resets the collar to factory settings."; confirm header "EMERGENCY ESCAPE"; confirm title "Escape"; initiation notice "Escape initiated…". Wire protocol unchanged — routing context stays "runaway", policy CSV key stays "Runaway", message type stays settings.runaway, comments / cross-reference to plugin_access's own "Runaway" path untouched. UI label only.
- v1.10 rev 11: Drop "[SOS]" source prefix from the four user-facing
  notices. Brings this plugin into line with the project convention.
- v1.10 rev 10: Gate Runaway at ACL 2 by access.enablerunaway. An owned
  wearer whose owner has left in-scene Runaway enabled already has the
  Access → Runaway path; SOS Runaway in that case is a redundant
  long-touch foot-gun. Runtime filter in show_sos_menu strips Runaway
  from the ACL 2 button set when access.enablerunaway is TRUE; the
  sosrunaway chat alias gets the same gate. ACL 0 (TPE) and ACL 2 with
  runaway disabled still get Runaway — those are the cases where the
  wearer has no other escape. ACL 4 unchanged (no exposure).
- v1.10 rev 9: Widen policy to owned-wearer ACLs (0 and 2). TPE wearer
  (ACL 0) retains the full set (Unleash, Clear RLV, Clear Relay, Runaway)
  since SOS is their sole accessible menu. Owned non-TPE wearer (ACL 2)
  gets only Runaway — the other three actions are reachable via the
  normal collar menu, and Runaway is the one action that's otherwise
  unreachable when an owner has disabled in-scene runaway. Unowned
  wearer (ACL 4) gets nothing: no ownership to escape, no abuse vector,
  Reset Config covers "wipe my config" with less collateral damage.
  Runaway sends settings.runaway on SETTINGS_BUS, bypassing the
  access.enablerunaway in-scene gate. Confirmation dialog required.
  Body text built dynamically from policy-allowed buttons. New chat
  alias sosrunaway.
- v1.10 rev 8: write_plugin_reg guards idempotent writes (read-before-
  write). Same-value re-registrations on state_entry and
  kernel.register.refresh no longer fire linkset_data, so kmod_ui's
  debounced rebuild + session invalidation stops triggering on
  register.refresh cascades — wearer's open menu survives the event.
- v1.10 rev 7: Add dormancy guard in state_entry — script parks itself
  if the prim's object description is "COLLAR_UPDATER" so it stays dormant
  when staged in an updater installer prim.
- v1.10 rev 6: Self-declare menu presence via LSD (plugin.reg.<ctx>).
  Label updates write the same LSD key directly; ui.label.update link_messages
  are gone. Reset handlers delete plugin.reg.<ctx> and acl.policycontext:<ctx>
  before llResetScript so kmod_ui drops the button immediately.
- v1.10 rev 5: Chat command support (Phase 3). Registers "sos" alias
  (opens SOS menu) plus three standalone panic aliases: "sosunleash",
  "sosrestrict", "sosrelay" — each fires its emergency action directly.
  ACL gate is automatic via the ui.sos.911 policy (ACL 0 only — the
  state you're in when locked out of normal access).
- v1.10 rev 4: Wire-type rename (Phase 2). kernel.register→kernel.register.declare,
  kernel.registernow→kernel.register.refresh, kernel.reset→kernel.reset.soft,
  kernel.resetall→kernel.reset.factory, sos.leashrelease→sos.leash.release,
  sos.restrictclear→sos.restrict.clear, sos.relayclear→sos.relay.clear.
- v1.10 rev 3: Guard ui.menu.start against raw kmod_chat broadcasts (no acl
  field). Fixes duplicate dialogs when commands are typed in chat.
- v1.10 rev 2: Namespace internal message type strings (kernel.*, ui.*, sos.*).
- v1.10 rev 1: Migrate dialog buttons to button_data format with context-based routing.
- v1.10 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded PLUGIN_MIN_ACL with policy reads.
  Button list built from get_policy_buttons() + btn_allowed().
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
write_plugin_reg(string label) {
    string k = "plugin.reg." + PLUGIN_CONTEXT;
    string v = llList2Json(JSON_OBJECT, [
        "label",  label,
        "script", llGetScriptName()
    ]);
    // Skip the write (and its linkset_data event) when the stored value
    // is already what we would write. Idempotent re-registrations on
    // state_entry or kernel.register.refresh then no longer trigger
    // kmod_ui's debounced rebuild + session invalidation.
    if (llLinksetDataRead(k) == v) return;
    llLinksetDataWrite(k, v);
}

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
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "0", "Unleash,Clear RLV,Clear Relay,Runaway",
        "2", "Runaway"
    ]));

    // Self-declared menu presence for kmod_ui.
    write_plugin_reg(PLUGIN_LABEL);

    // Register with kernel (for ping/pong health tracking and alias table).
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
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
    list button_data = [btn("Back", "back")];
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

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "SOS Emergency",
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 60
    ]), NULL_KEY);

}

show_runaway_confirm() {
    MenuContext = "runaway_confirm";
    SessionId = generate_session_id();

    list button_data = [
        btn("No", "cancel"),
        btn("Yes", "confirm")
    ];

    string body = "EMERGENCY ESCAPE\n\n";
    body += "This will remove ownership entirely and erase ALL collar settings. ";
    body += "The collar will return to an unowned, unlocked state.\n\n";
    body += "This cannot be undone.\n\n";
    body += "Proceed?";

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Escape",
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 30
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

    if (cmd == "back") {
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
        if (llGetObjectDesc() == "D/s Collar updater v1.1" || llGetObjectDesc() == "(updating)" || llGetObjectDesc() == "(installing)") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

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
                // Either no context (broadcast) or matches our context
                llLinksetDataDelete("plugin.reg." + PLUGIN_CONTEXT);
                llLinksetDataDelete("acl.policycontext:" + PLUGIN_CONTEXT);
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
                if (cmd == JSON_INVALID) cmd = "";
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

/*--------------------
PLUGIN: plugin_blacklist.lsl
VERSION: 1.2
REVISION: 18
PURPOSE: Blacklist management with sensor-based avatar selection
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.2 rev 18: add-scan migrated to kmod_menu's menu.sensor service (like plugin_restrict/owners/leash). request_add_pick sends ui.menu.render {mode:menu.sensor,kind:agents,range:20}; the picked avatar returns via ui.sensor.result → handle_add_result → send_blacklist_add (+ await_sync counter). Deleted the plugin's own llSensor + sensor()/no_sensor() events + CandidateKeys + show_add_candidates + the add_pick branch. The REMOVE picker stays on menu.picker (it lists the in-memory Blacklist, no scan). NOTE: menu.sensor doesn't pre-filter already-blacklisted/owner (the plugin used to), so they can appear — the add just rejects them via kmod_settings' guards (harmless).
- v1.2 rev 17: MEMORY — both picker item builds switched from `items +=` string concatenation to a row LIST joined ONCE via llDumpList2String. The in-loop `+=` recopies the growing string each iteration (O(n²) transient garbage Mono doesn't reclaim mid-event) — the same pattern that caused a stack-heap collision in plugin_leash's object picker (leash rev 16). Pre-emptive here (blacklist counts are smaller) but the same latent risk.
- v1.2 rev 16: FIX (supersedes rev 15's approach) — stale counter after add/remove is now handled by deferring the redraw, not double-rendering. A picker add/remove parks in "await_sync" and does NOT redraw immediately; the settings.sync handler rebuilds main ONCE with the committed count. Redraw fires only in await_sync (rev 15 redrew whenever main was open, which STACKED a second dialog on the already-showing menu — a duplicate + a UI-convention violation). Pairs with kmod_settings rev bump: blacklist add/remove now always echo a sync (even a rejected add), so the await never strands.
- v1.2 rev 15: FIX — main-menu counter was stale after an add/remove: the flow redraws main immediately, before kmod_settings persists + broadcasts settings.sync (which is when the Blacklist cache refreshes). Now the settings.sync handler redraws the main menu when it's the open view, so the count reflects the committed state.
- v1.2 rev 14: add + remove pickers migrated to menu.picker (kmod_menu rev 24). Both now hand kmod_menu key-first "uuid\tname" rows and it owns paging + the click; the pick returns as ONE ui.menu.picker.result on UI_BUS with context = the selected UUID (no JSON on any name → real display names, poison-immune). Dropped the DIALOG_BUS picker branch (nav/pick decode), the picker SessionId, the CurrentPage cursor, and OL_PAGE_SIZE. Main menu (menu.fixed) + Show listing (dialog.info) stay on DIALOG_BUS unchanged.
- v1.2 rev 13: chat command "<prefix> blacklist add <uuid|username>" for direct blacklisting without the sensor picker. Arrives as subpath "add.<arg>" (bare "add" still opens the picker); handle_subpath routes it to direct_blacklist_add. UUID works for anyone; a username resolves against region avatars (llGetAgentList, synchronous — no name2key, so absent people need a UUID). Same +Blacklist ACL gate and kmod_settings guards as the picker.
- v1.2 rev 12: main to menu.fixed (dropped MainPage cursor + main prev/next), add/remove pickers to menu.ordered, list view to dialog.info; cleans up on the new ui.dialog.close.
- v1.2 rev 11: main menu now paginates — separate MainPage cursor (distinct from CurrentPage, the OL pickers') clamped/wrapped to the button count, nav:prev/nav:next page through, single page redraws. Defensive; part of the all-pagers-operational pass.
- v1.2 rev 10: nav routes by context (nav:back/nav:prev/nav:next), not the button label; dropped the now-unused BTN_BACK constant.
- v1.2 rev 9: the read-only Show-Blklst listing now renders via the menu service's INFO mode (ui.menu.render mode="info"; kmod_menu rev 13) instead of the last raw ui.dialog.open — a single OK, no nav row (a display isn't navigated). The info "ok" routes like Back here (returns to the blacklist menu, since it's a sub-view). All blacklist dialogs now flow through kmod_menu.
- v1.2 rev 8: main menu now renders via the menu service (pager mode, has_nav=1) instead of a raw ui.dialog.open — the nav row (<< >> Back) takes row0 so the +/-/Show action buttons sit in row1, not the nav row. Sheds the local Back button + layout. Handler unchanged (Back via top check, actions via main branch, inert <</>> redraw via fallback).
- v1.2 rev 7: remove + add-scan pickers render via the menu service's ORDERED (OL) mode (ui.menu.render mode="ordered") instead of kmod_dialogs' numbered_list. Names go in the numbered body (display names exceed llDialog's 24-char button cap), buttons are index numbers, response is pick:<global-index> → Blacklist/CandidateKeys[idx] → UUID (index-keyed, no name-collision risk). Gains real paging (<</>> + CurrentPage; OL_PAGE_SIZE 9 must match kmod_menu); dropped the 11-item cap. Main menu + Show list unchanged.
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
string BTN_ADD = "+Blacklist";
string BTN_REMOVE = "-Blacklist";
string BTN_SHOW = "Show Blklst";
integer BLACKLIST_RADIUS = 20;   // metres — passed to menu.sensor as the scan range

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
string MenuContext = "";  // "main", "remove", "await_sync"


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

// Direct blacklist add from a chat command ("<prefix> blacklist add <arg>").
// arg is a UUID (works for anyone, online or off) or a username resolved against
// avatars CURRENTLY IN THE REGION (llGetAgentList — synchronous, no name2key
// service; someone not present must be given by UUID). kmod_settings' guards
// (no owner/trustee/wearer/dupe, 64 cap) still apply on the receiving side.
direct_blacklist_add(key user, string arg) {
    arg = llStringTrim(arg, STRING_TRIM);
    if (arg == "") {
        llRegionSayTo(user, 0, "Usage: blacklist add <username|uuid>");
        return;
    }

    // UUID form: a well-formed key casts non-null (usernames never do).
    if ((key)arg != NULL_KEY) {
        send_blacklist_add(arg, "");   // kmod_settings resolves the display name
        llRegionSayTo(user, 0, "Blacklisting " + arg + ".");
        return;
    }

    // Username form: match a region avatar's login name (case-insensitive).
    string want = llToLower(arg);
    list agents = llGetAgentList(AGENT_LIST_REGION, []);
    integer n = llGetListLength(agents);
    integer i = 0;
    while (i < n) {
        key a = llList2Key(agents, i);
        string uname = llGetUsername(a);
        if (uname != "" && llToLower(uname) == want) {
            send_blacklist_add((string)a, uname);
            llRegionSayTo(user, 0, "Blacklisting " + uname + ".");
            return;
        }
        i += 1;
    }
    llRegionSayTo(user, 0,
        "No one named '" + arg + "' is in the region. Blacklist someone who isn't here by their UUID.");
}

/* -------------------- MENU DISPLAY -------------------- */

show_main_menu() {
    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, CurrentUserAcl);

    integer count = llGetListLength(Blacklist);
    string body = "Blacklist Management\n\nCurrently blacklisted: " + (string)count;

    // Content buttons only (policy-gated). The menu service (pager mode) owns
    // the nav row (<< >> Back) so actions never sit in row0; has_nav=1 keeps
    // the full nav row even though this menu is a single page.
    list button_data = [];
    if (btn_allowed("+Blacklist")) button_data += [btn(BTN_ADD, "add")];
    if (btn_allowed("-Blacklist")) button_data += [btn(BTN_REMOVE, "remove")];
    if (btn_allowed("Show Blklst")) button_data += [btn(BTN_SHOW, "show")];

    SessionId = generate_session_id();
    MenuContext = "main";

    // menu.fixed — +/-/Show, a structural set; never paginates.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "menu.fixed",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "title",      "Blacklist",
        "body",       body,
        "buttons",    llList2Json(JSON_ARRAY, button_data)
    ]), NULL_KEY);
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
        request_add_pick();
        return;
    }
    // "add.<uuid|username>" — direct add from chat (bare "add" above = picker).
    // Chat dot-joins args, so a dotted username (first.last) survives as the
    // remainder after "add.".
    if (llSubStringIndex(subpath, "add.") == 0) {
        if (!btn_allowed("+Blacklist")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        gPolicyButtons = [];
        direct_blacklist_add(user, llGetSubString(subpath, 4, -1));
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

    // Read-only listing → INFO mode (single OK, no nav row). OK returns to the
    // blacklist main menu (it's a sub-view), handled in handle_dialog_response.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "dialog.info",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "title",      "Blacklist",
        "body",       body
    ]), NULL_KEY);
}

show_remove_menu() {
    if (llGetListLength(Blacklist) == 0) {
        llRegionSayTo(CurrentUser, 0, "Blacklist is empty.");
        show_main_menu();
        return;
    }

    MenuContext = "remove";

    // menu.picker: key-first "uuid\tname" rows (uuid from Blacklist, name from the
    // parallel blacklist_names()). The UUID leads each row (poison-safe) and comes
    // back verbatim as the result context; kmod_menu auto-shapes, pages, owns the
    // click. No JSON touches a name, so bracketed display names show verbatim.
    // Build the rows as a LIST and join ONCE (llDumpList2String) — never `items +=`
    // in the loop, whose O(n²) recopy garbage is a stack-heap risk (see leash r16).
    list names = blacklist_names();
    list rows = [];
    integer i = 0;
    integer n = llGetListLength(Blacklist);
    while (i < n) {
        rows += [llList2String(Blacklist, i) + "\t" + llList2String(names, i)];
        i += 1;
    }

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",      "ui.menu.render",
        "mode",      "menu.picker",
        "requester", PLUGIN_CONTEXT,
        "user",      (string)CurrentUser,
        "title",     "Remove from Blacklist",
        "prompt",    "Select an avatar to remove:",
        "items",     llDumpList2String(rows, "\n")
    ]), NULL_KEY);
}

// Ask kmod_menu's menu.sensor service to scan nearby avatars, render the picker,
// and reply ui.sensor.result with the chosen avatar's key. No llSensor /
// sensor()/no_sensor() / candidate list lives here anymore. (menu.sensor doesn't
// know the already-blacklisted/owner rule, so those can appear — the add just
// rejects them via kmod_settings' guards.)
request_add_pick() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",      "ui.menu.render",
        "mode",      "menu.sensor",
        "kind",      "agents",
        "range",     (string)BLACKLIST_RADIUS,
        "title",     "Add to Blacklist",
        "prompt",    "Select an avatar to blacklist:",
        "requester", PLUGIN_CONTEXT,
        "user",      (string)CurrentUser
    ]), NULL_KEY);
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
}

/* -------------------- DIALOG HANDLERS -------------------- */

// A mutation is NOT redrawn immediately: the count on the main menu comes from the
// Blacklist cache, which is only fresh AFTER kmod_settings persists and echoes a
// settings.sync. So we send the mutation, enter "await_sync", and let the sync
// handler rebuild the menu ONCE with the committed count — no stale-then-redraw
// double dialog. kmod_settings always syncs on add/remove (even a rejected add),
// so this never strands.

// REMOVE picker result (menu.picker — the in-memory Blacklist list). cancelled
// (Back/timeout) → back to the blacklist menu; otherwise context IS the UUID.
handle_picker_result(string context, integer cancelled) {
    if (cancelled) {
        show_main_menu();
        return;
    }
    if (MenuContext == "remove") {
        send_blacklist_remove(context);
        llRegionSayTo(CurrentUser, 0, "Removed from blacklist.");
        MenuContext = "await_sync";
        return;
    }
    show_main_menu();
}

// ADD scan result from kmod_menu's menu.sensor service. `name` is the display name
// it resolved during the scan (persist it alongside the UUID). cancelled (or a "no
// people found" it already announced) → back to the blacklist menu.
handle_add_result(string result_key, string result_name, integer cancelled) {
    if (cancelled || result_key == "") {
        show_main_menu();
        return;
    }
    string nm = result_name;
    if (nm == "") nm = llGetUsername((key)result_key);
    send_blacklist_add(result_key, nm);
    llRegionSayTo(CurrentUser, 0, "Added to blacklist.");
    MenuContext = "await_sync";
}

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["button"]) == JSON_INVALID) return;

    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;

    string cmd = llJsonGetValue(msg, ["context"]);
    if (cmd == JSON_INVALID || cmd == "") cmd = llJsonGetValue(msg, ["button"]);

    // Back / OK: the service nav Back (context nav:back) or the Show-Blklst
    // info dialog's "ok". Main-menu Back exits to root; everything else (incl.
    // the info OK, a sub-view) returns to the blacklist menu.
    if (cmd == "nav:back" || cmd == "ok") {
        if (MenuContext == "main") {
            return_to_root();
            return;
        }
        show_main_menu();
        return;
    }

    // Main menu actions (menu.fixed). The remove/add pickers run on menu.picker
    // and resolve via handle_picker_result off UI_BUS, never here.
    if (MenuContext == "main") {
        if (cmd == "add") {
            request_add_pick();
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
                // A picker add/remove parks in "await_sync" and defers its redraw
                // to here — the Blacklist cache (and its counter) is only fresh now,
                // AFTER the persist round-trip. Rebuild the main menu ONCE with the
                // committed count. Only fires in await_sync, so an unrelated sync
                // never stacks a second dialog on an already-open menu.
                if (CurrentUser != NULL_KEY && MenuContext == "await_sync") show_main_menu();
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

            // REMOVE picker result from kmod_menu (menu.picker). Filter to our
            // requester + the active user; context is the selected UUID (or a cancel).
            if (msg_type == "ui.menu.picker.result") {
                if (llJsonGetValue(msg, ["requester"]) != PLUGIN_CONTEXT) return;
                string ru = llJsonGetValue(msg, ["user"]);
                if (ru == JSON_INVALID || (key)ru != CurrentUser) return;
                integer was_cancelled = (llJsonGetValue(msg, ["cancelled"]) != JSON_INVALID);
                string pctx = llJsonGetValue(msg, ["context"]);
                if (pctx == JSON_INVALID) pctx = "";
                handle_picker_result(pctx, was_cancelled);
                return;
            }

            // ADD scan result from kmod_menu's menu.sensor service. `name` is the
            // scanned display name; `key` the picked avatar (or a cancel).
            if (msg_type == "ui.sensor.result") {
                if (llJsonGetValue(msg, ["requester"]) != PLUGIN_CONTEXT) return;
                string sru = llJsonGetValue(msg, ["user"]);
                if (sru == JSON_INVALID || (key)sru != CurrentUser) return;
                integer add_cancelled = (llJsonGetValue(msg, ["cancelled"]) != JSON_INVALID);
                string skey = llJsonGetValue(msg, ["key"]);
                if (skey == JSON_INVALID) skey = "";
                string sname = llJsonGetValue(msg, ["name"]);
                if (sname == JSON_INVALID) sname = "";
                handle_add_result(skey, sname, add_cancelled);
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

            if (msg_type == "ui.dialog.close") {
                if (llJsonGetValue(msg, ["session_id"]) == SessionId) cleanup_session();
                return;
            }

            return;
        }
    }

    // Avatar scanning is owned by kmod_menu's menu.sensor service now (see
    // request_add_pick / handle_add_result); no sensor()/no_sensor() here.
}

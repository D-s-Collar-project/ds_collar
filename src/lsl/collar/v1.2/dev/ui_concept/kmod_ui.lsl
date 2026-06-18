/*--------------------
MODULE: kmod_ui.lsl
VERSION: 1.2
REVISION: 9
CHANGES:
- v1.2 rev 9 (sandbox): RLV-gated visibility. rebuild_views drops any plugin whose mask carries bit 0x40 (RLV-required) while rlv.active=="0" (published by kmod_bootstrap); linkset_data arms a rebuild when rlv.active changes. The ACL test (mask & 1<<lvl, lvl<=5) never touches bit 6, so per-level visibility is unchanged. Fail-open: absent/"1" shows everything.
- v1.2 rev 8 (sandbox): render_session hands kmod_menu the FULL button list (not a pre-sliced page) — the menu service owns page slicing now (kmod_menu rev 7). kmod_ui still tracks current_page + total_pages for the <</>> wrap in handle_button_click; it just no longer slices. Step 1 of the shape-service split (menu service owns layout+paging).
- v1.2 rev 7 (sandbox): ACL is now read DIRECTLY off the user-record table
  (resolve_acl mirrors kmod_auth route_acl_query rung-for-rung) instead of the
  async auth.acl.query round-trip. Sessions hold navigation state only; the ACL
  level is resolved LIVE at render + dispatch, so a session survives reg.*
  rebuilds and role changes with no teardown and the next click always reflects
  the current table. Removed: SessionACLs / SessionBlacklisted /
  SessionCreatedTimes / PendingAcl* lists, handle_acl_result, start_session's
  query hop, the auth.acl.update session-invalidation, invalidate_all_sessions
  on rebuild, and the SESSION_MAX_AGE re-auth. This is the documented hot-path
  model (see kmod_auth header). Fixes the mid-session menu death traced to the
  reg.*-rebuild + acl.update teardowns. Dispatch still re-checks acl.policycontext
  live, so authorization tightens (no cached snapshot can act stale).
  CROSS-MODULE CONTRACT: resolve_acl MUST stay in lockstep with kmod_auth
  route_acl_query; the user.* record format + isowned/tpe/public flag keys are
  owned by kmod_settings.
- v1.2 rev 6: Touch-guard. touch_start ignores touches while boot.ready is unset (kmod_bootstrap clears it at boot start, sets "1" at startup complete). A touch mid-boot fires the menu render + view rebuild, piling concurrent LSD writes onto the plugin self-declare window — under load that drops registrations and strands plugins from the menu. CROSS-MODULE CONTRACT: boot.ready, written by kmod_bootstrap.
- v1.2 rev 1: User-record roster (kmod_settings rev 2): dropped the local acl.<uuid>.cache fast path + acl.timestamp staleness check entirely — every session start now round-trips auth.acl.query (one link-message hop, no staleness window, single ACL implementation in kmod_auth).
PURPOSE: Session management, categorized per-ACL menu views (LSD-resident),
         and plugin dispatch orchestration
ARCHITECTURE: BIND9-style views. Each plugin self-declares one LSD entry
  reg.<ctx> = {"cat","label","script","mask"} where mask bit L = visible at
  ACL level L. On any reg.* change a debounced rebuild composes one
  precomputed view per ACL level and stores it in LSD:
    ui.view.<acl>      = {"root":[[ctx,label],...], "<Cat>":[[ctx,label],...]}
    ui.view.<acl>.sos  = [[ctx,label],...]          (ui.sos.* contexts)
  Root tier = category buttons (context "cat:<Name>", alphabetical) followed
  by Standalone plugins (alphabetical). cat "Standalone" renders directly in
  root; empty/missing cat groups under "Other"; ui.sos.* prefix routes to
  the SOS view regardless of cat. Per touch: one LSD read (the toucher's
  view) fully describes the menu — no recompute, and views survive a script
  reset. ACL is resolved synchronously from the user-record table by
  resolve_acl (the same ladder kmod_auth runs); there is no cached snapshot.
  acl.policycontext:<ctx> is NOT used for menu visibility — it remains the
  per-button policy store inside plugins, and dispatch re-checks it (against
  the live ACL) as the authorization gate.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- ACL CONSTANTS -------------------- */
// Mirror of kmod_auth's ladder values. CROSS-MODULE CONTRACT.
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* -------------------- CONSTANTS -------------------- */
string ROOT_CONTEXT = "ui.core.root";
string SOS_CONTEXT = "ui.sos.root";
string SOS_PREFIX = "ui.sos.";  // Prefix for SOS plugin contexts
integer MAX_FUNC_BTNS = 9;
float TOUCH_RANGE_M = 5.0;
float LONG_TOUCH_THRESHOLD = 1.5;

// Touch-guard: kmod_bootstrap clears this at boot start and sets it "1" at
// "startup complete". We ignore touches while it is unset so a touch mid-boot
// can't pile a menu render onto the plugin-registration window. CROSS-MODULE.
string KEY_BOOT_READY = "boot.ready";

integer MAX_SESSIONS = 5;

// User records + flags read by resolve_acl. user.<uuid> =
// "<acl>,<rank>,<name>,<honorific>"; the leading acl field parses off the raw
// value with an integer cast. Written solely by kmod_settings. CROSS-MODULE.
string USER_PREFIX       = "user.";
string KEY_ISOWNED       = "access.isowned";
string KEY_PUBLIC_ACCESS = "public.mode";
string KEY_TPE_MODE      = "tpe.mode";

// Per-plugin self-declared registry entry. Written by plugins during
// registration: reg.<context> = {"cat","label","script","mask"}.
// kmod_ui enumerates via llLinksetDataFindKeys; plugins delete their own
// entries on soft/factory reset, and the kernel sweeps orphans when scripts
// are removed from inventory. CROSS-MODULE CONTRACT.
string LSD_REG_PREFIX = "reg.";

// Per-ACL precomputed menu views, owned (derived state) by this module.
string LSD_VIEW_PREFIX = "ui.view.";

// Category button contexts are "cat:<Name>"; plugin contexts are ui.* so
// the namespaces can never collide.
string CAT_CTX_PREFIX = "cat:";

// Reserved category names. "Standalone" renders the plugin directly in the
// root menu; entries with no/empty cat group under "Other".
string CAT_STANDALONE = "Standalone";
string CAT_OTHER = "Other";

// ACL levels that get a view. -1 (blacklist) never has one — absence of a
// view IS the barred state, handled by the empty-menu message paths.
integer VIEW_LEVEL_MIN = 0;
integer VIEW_LEVEL_MAX = 5;

// RLV gating: a plugin ORs mask bit 0x40 (bit 6, above the ACL bits 1-5) into
// its PLUGIN_ACL_MASK to declare it needs RLV. When rlv.active (published by
// kmod_bootstrap) reads "0", those plugins are dropped from every view. The
// ACL test (mask & 1<<lvl, lvl<=5) never touches bit 6, so per-level
// visibility is otherwise unchanged. Absent/"1" rlv.active = show (fail-open).
integer MASK_RLV_REQUIRED = 0x40;
string  KEY_RLV_ACTIVE    = "rlv.active";

// Debounce window for linkset_data-driven rebuilds. Small enough to feel
// instantaneous; large enough to collapse the bootstrap burst of N plugins
// registering back-to-back into a single rebuild.
float REBUILD_DEBOUNCE = 0.1;

/* -------------------- STATE -------------------- */
// Registered plugin contexts (chat dispatch + click validation). Labels,
// categories and masks live in the LSD views — not duplicated in heap.
list PluginContexts;

// Parallel lists for sessions. NAVIGATION STATE ONLY — ACL is never cached
// here; it is resolved live from the table on every render/dispatch.
list SessionUsers;
list SessionPages;
list SessionTotalPages;
list SessionIDs;
list SessionContexts;    // ROOT_CONTEXT or SOS_CONTEXT
list SessionCategories;  // "" = root tier; "<Cat>" = inside that category

// Parallel Lists for Touch Data
list TouchKeys;
list TouchStartTimes;

// Debounce flag for linkset_data-driven rebuilds.
integer ViewsStale = FALSE;


/* -------------------- HELPERS -------------------- */

string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
}

integer validate_required_fields(string json_str, list field_names) {
    integer i = 0;
    integer len = llGetListLength(field_names);
    while (i < len) {
        string field = llList2String(field_names, i);
        if (llJsonGetValue(json_str, [field]) == JSON_INVALID) {
            return FALSE;
        }
        i += 1;
    }
    return TRUE;
}

string generate_session_id(key user) {
    return "ui_" + (string)user + "_" + (string)llGetUnixTime();
}

/* -------------------- ACL RESOLUTION (TABLE READ) -------------------- */
// The hot-path ACL read: resolve a level straight off the user-record table
// and the isowned/tpe/public flags. This is the SAME ladder kmod_auth's
// route_acl_query runs (blacklist > primary owner > wearer{tpe/owned/unowned}
// > trustee > public > unauthorized stranger). kmod_auth remains the async
// responder for plugins/HUDs; kmod_ui reads directly so a session never holds
// a stale ACL snapshot. CROSS-MODULE CONTRACT: keep in lockstep with kmod_auth.
integer resolve_acl(key avatar) {
    integer role = (integer)llLinksetDataRead(USER_PREFIX + (string)avatar);  // 0 if no record

    if (role == ACL_BLACKLIST) return ACL_BLACKLIST;
    if (role == ACL_PRIMARY_OWNER) return ACL_PRIMARY_OWNER;

    // The wearer never has a record — derive from the flags.
    if (avatar == llGetOwner()) {
        if ((integer)llLinksetDataRead(KEY_TPE_MODE)) return ACL_NOACCESS;
        if ((integer)llLinksetDataRead(KEY_ISOWNED)) return ACL_OWNED;
        return ACL_UNOWNED;
    }

    if (role == ACL_TRUSTEE) return ACL_TRUSTEE;
    if ((integer)llLinksetDataRead(KEY_PUBLIC_ACCESS)) return ACL_PUBLIC;

    // Unauthorized stranger: level -1, but NOT blacklisted (no record).
    return ACL_BLACKLIST;
}

// TRUE only for an actor with an explicit blacklist (-1) record — distinguishes
// the barred case from the unauthorized-stranger case (both resolve to -1).
integer actor_is_blacklisted(key avatar) {
    return ((integer)llLinksetDataRead(USER_PREFIX + (string)avatar) == ACL_BLACKLIST);
}

/* -------------------- SESSION MANAGEMENT -------------------- */

integer find_session_idx(key user) {
    return llListFindList(SessionUsers, [user]);
}

cleanup_session(key user) {
    integer idx = find_session_idx(user);
    if (idx == -1) return;

    // Close dialog before cleaning up session
    string session_id = llList2String(SessionIDs, idx);
    string close_msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.close",
        "session_id", session_id
    ]);
    llMessageLinked(LINK_SET, DIALOG_BUS, close_msg, NULL_KEY);

    SessionUsers = llDeleteSubList(SessionUsers, idx, idx);
    SessionPages = llDeleteSubList(SessionPages, idx, idx);
    SessionTotalPages = llDeleteSubList(SessionTotalPages, idx, idx);
    SessionIDs = llDeleteSubList(SessionIDs, idx, idx);
    SessionContexts = llDeleteSubList(SessionContexts, idx, idx);
    SessionCategories = llDeleteSubList(SessionCategories, idx, idx);
}

create_session(key user, string context_filter) {
    integer existing_idx = find_session_idx(user);
    if (existing_idx != -1) {
        cleanup_session(user);
    }

    if (llGetListLength(SessionUsers) >= MAX_SESSIONS) {
        key oldest_user = llList2Key(SessionUsers, 0);
        cleanup_session(oldest_user);
    }

    string session_id = generate_session_id(user);

    SessionUsers += [user];
    SessionPages += [0];
    SessionTotalPages += [0];
    SessionIDs += [session_id];
    SessionContexts += [context_filter];
    SessionCategories += [""];
}

/* -------------------- VIEW REBUILD (registry -> LSD views) -------------------- */

// Enumerate reg.* and recompose one precomputed view per ACL level into LSD.
// Called from the debounced timer after a linkset_data event (or from
// state_entry to prime initial state). Visibility is a pure mask test —
// no policy JSON is parsed here.
rebuild_views() {
    // Wipe stale view keys first so categories/levels that disappeared
    // don't linger.
    list old = llLinksetDataFindKeys("^ui\\.view\\.", 0, -1);
    integer oi = 0;
    integer on = llGetListLength(old);
    while (oi < on) {
        llLinksetDataDelete(llList2String(old, oi));
        oi += 1;
    }

    // Registry table, strided [label, ctx, cat, mask], label-sorted so
    // member lists come out in reading order for free.
    list keys = llLinksetDataFindKeys("^reg\\.", 0, -1);
    integer prefix_len = llStringLength(LSD_REG_PREFIX);
    // RLV-required plugins (mask bit 0x40) are dropped from every view while
    // RLV is off. Read the state once; absent/"1" = show (fail-open).
    integer rlv_off = (llLinksetDataRead(KEY_RLV_ACTIVE) == "0");
    list tab = [];
    integer i = 0;
    integer n = llGetListLength(keys);
    while (i < n) {
        string k = llList2String(keys, i);
        string entry = llLinksetDataRead(k);
        string label = llJsonGetValue(entry, ["label"]);
        if (label != JSON_INVALID) {
            string cat = llJsonGetValue(entry, ["cat"]);
            if (cat == JSON_INVALID) cat = "";
            integer mask = (integer)llJsonGetValue(entry, ["mask"]);
            if (!(rlv_off && (mask & MASK_RLV_REQUIRED))) {
                tab += [label, llGetSubString(k, prefix_len, -1), cat, mask];
            }
        }
        i += 1;
    }
    integer stride = 4;
    if (llGetListLength(tab) > stride) {
        tab = llListSortStrided(tab, stride, 0, TRUE);
    }
    integer rows = llGetListLength(tab) / stride;

    // Contexts cached in heap for chat dispatch + click validation only.
    PluginContexts = [];
    i = 0;
    while (i < rows) {
        PluginContexts += [llList2String(tab, i * stride + 1)];
        i += 1;
    }

    // Compose one view per ACL level.
    integer lvl = VIEW_LEVEL_MIN;
    while (lvl <= VIEW_LEVEL_MAX) {
        list sos_pairs = [];
        list standalone_pairs = [];   // already label-ordered (tab is sorted)
        list cats = [];               // distinct visible category names

        i = 0;
        while (i < rows) {
            integer base = i * stride;
            integer mask = llList2Integer(tab, base + 3);
            if (mask & (1 << lvl)) {
                string label = llList2String(tab, base);
                string ctx = llList2String(tab, base + 1);
                string cat = llList2String(tab, base + 2);
                if (llSubStringIndex(ctx, SOS_PREFIX) == 0) {
                    sos_pairs += [llList2Json(JSON_ARRAY, [ctx, label])];
                }
                else if (cat == CAT_STANDALONE) {
                    standalone_pairs += [llList2Json(JSON_ARRAY, [ctx, label])];
                }
                else {
                    if (cat == "") cat = CAT_OTHER;
                    if (llListFindList(cats, [cat]) == -1) cats += [cat];
                }
            }
            i += 1;
        }

        // Root tier order: categories A-Z first, then Standalone plugins A-Z.
        cats = llListSort(cats, 1, TRUE);
        list root_pairs = [];
        integer ci = 0;
        integer cn = llGetListLength(cats);
        while (ci < cn) {
            string cname = llList2String(cats, ci);
            // Category buttons read "Access..." — the ellipsis signals a
            // drill-down. The category page title stays the bare name
            // (kmod_menu titles from the session's category field).
            root_pairs += [llList2Json(JSON_ARRAY, [CAT_CTX_PREFIX + cname, cname + "..."])];
            ci += 1;
        }
        root_pairs += standalone_pairs;

        // Assemble the view object: "root" + one key per category.
        list obj = [];
        if (llGetListLength(root_pairs) > 0) {
            obj += ["root", llList2Json(JSON_ARRAY, root_pairs)];
        }
        ci = 0;
        while (ci < cn) {
            string cname2 = llList2String(cats, ci);
            list members = [];
            i = 0;
            while (i < rows) {
                integer b2 = i * stride;
                if (llList2Integer(tab, b2 + 3) & (1 << lvl)) {
                    string mctx = llList2String(tab, b2 + 1);
                    string mcat = llList2String(tab, b2 + 2);
                    if (mcat == "") mcat = CAT_OTHER;
                    if (mcat == cname2 && llSubStringIndex(mctx, SOS_PREFIX) != 0
                        && mcat != CAT_STANDALONE) {
                        members += [llList2Json(JSON_ARRAY, [mctx, llList2String(tab, b2)])];
                    }
                }
                i += 1;
            }
            obj += [cname2, llList2Json(JSON_ARRAY, members)];
            ci += 1;
        }

        if (llGetListLength(obj) > 0) {
            llLinksetDataWrite(LSD_VIEW_PREFIX + (string)lvl, llList2Json(JSON_OBJECT, obj));
        }
        if (llGetListLength(sos_pairs) > 0) {
            llLinksetDataWrite(LSD_VIEW_PREFIX + (string)lvl + ".sos", llList2Json(JSON_ARRAY, sos_pairs));
        }
        lvl += 1;
    }
}

// Arm the debounce timer. Multiple linkset_data writes within the window
// collapse to a single rebuild.
schedule_rebuild() {
    if (!ViewsStale) {
        ViewsStale = TRUE;
        llSetTimerEvent(REBUILD_DEBOUNCE);
    }
}

/* -------------------- MENU RENDERING (delegated to kmod_menu.lsl) -------------------- */

// Returns "[Honorific] Name" for the primary owner (the lowest-rank acl-5
// user record), or "" when no owner is set.
string get_primary_owner_display() {
    string best_name = "";
    string best_hon = "";
    integer best_rank = 0x7FFFFFFF;
    list ks = llLinksetDataFindKeys("^user\\.", 0, -1);
    integer i = 0;
    integer n = llGetListLength(ks);
    while (i < n) {
        string rec = llLinksetDataRead(llList2String(ks, i));
        if ((integer)rec == 5) {
            list f = llCSV2List(rec);
            integer rank = (integer)llList2String(f, 1);
            if (rank < best_rank) {
                best_rank = rank;
                best_name = llList2String(f, 2);
                best_hon = llList2String(f, 3);
            }
        }
        i += 1;
    }
    if (best_name == "") return "";
    if (best_hon != "") return best_hon + " " + best_name;
    return best_name;
}

send_message(key user, string message_text) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.message.show",
        "user", (string)user,
        "message", message_text
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

// Render the session's current tier from the LSD view. ACL is resolved live
// from the table here — one read, always current. One LSD read for the view;
// pairs are [ctx,label] JSON arrays straight from the view.
render_session(key user) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) return;

    integer acl = resolve_acl(user);
    string menu_type = llList2String(SessionContexts, session_idx);
    string category = llList2String(SessionCategories, session_idx);

    string arr = "";
    if (menu_type == SOS_CONTEXT) {
        arr = llLinksetDataRead(LSD_VIEW_PREFIX + (string)acl + ".sos");
    }
    else {
        string view = llLinksetDataRead(LSD_VIEW_PREFIX + (string)acl);
        if (view != "") {
            string sub;
            if (category == "") sub = llJsonGetValue(view, ["root"]);
            else sub = llJsonGetValue(view, [category]);
            if (sub != JSON_INVALID) arr = sub;
        }
    }

    list entries = [];
    if (arr != "" && arr != "[]") entries = llJson2List(arr);
    integer entry_count = llGetListLength(entries);

    if (entry_count == 0) {
        // A category page can only be empty after a rebuild race (the
        // button existed when rendered). Fall back to the root tier.
        if (category != "" && menu_type != SOS_CONTEXT) {
            SessionCategories = llListReplaceList(SessionCategories, [""], session_idx, session_idx);
            SessionPages = llListReplaceList(SessionPages, [0], session_idx, session_idx);
            render_session(user);
            return;
        }

        if (menu_type == SOS_CONTEXT) {
            send_message(user, "No emergency options are currently available.");
        }
        else {
            if (acl == ACL_BLACKLIST) {
                if (actor_is_blacklisted(user)) {
                    send_message(user, "You have been barred from using this collar.");
                }
                else {
                    string primary_owner = get_primary_owner_display();
                    if (primary_owner != "") {
                        send_message(user, "This collar is owned by " + primary_owner + " and is exclusive to them.");
                    }
                    else {
                        send_message(user, "This collar is not available for public use.");
                    }
                }
            }
            else if (acl == ACL_NOACCESS) {
                send_message(user, "You have relinquished control of the collar.");
            }
            else {
                send_message(user, "No plugins are currently installed.");
            }
        }

        cleanup_session(user);
        return;
    }

    integer current_page = llList2Integer(SessionPages, session_idx);
    integer total_pages = (entry_count + MAX_FUNC_BTNS - 1) / MAX_FUNC_BTNS;
    if (current_page >= total_pages) current_page = 0;
    if (current_page < 0) current_page = total_pages - 1;

    SessionPages = llListReplaceList(SessionPages, [current_page], session_idx, session_idx);
    SessionTotalPages = llListReplaceList(SessionTotalPages, [total_pages], session_idx, session_idx);

    // kmod_menu owns the page slice now — hand it the FULL list. current_page
    // + total_pages are kept only for the nav wrap in handle_button_click.
    list button_data = [];
    integer i = 0;
    while (i < entry_count) {
        string pair = llList2String(entries, i);
        // button_data carries context + default label. For toggleable
        // buttons (registered buttonconfig in kmod_dialogs), kmod_dialogs
        // reads the live state from plugin.<short>.state in LSD and
        // overrides the label at render time.
        button_data += [llList2Json(JSON_OBJECT, [
            "context", llJsonGetValue(pair, [0]),
            "label", llJsonGetValue(pair, [1])
        ])];
        i += 1;
    }

    string session_id = llList2String(SessionIDs, session_idx);

    // DESIGN DECISION: Navigation row is ALWAYS present (DO NOT CHANGE)
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.menu.render",
        "user", (string)user,
        "session_id", session_id,
        "menu_type", menu_type,
        "category", category,
        "page", current_page,
        "total_pages", total_pages,
        "buttons", llList2Json(JSON_ARRAY, button_data),
        "has_nav", 1
    ]);

    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

// Match a requested context to the longest registered plugin context that
// is either an exact match or a dot-boundary prefix. Returns the matched
// plugin context, or "" if none matches.
string resolve_plugin_context(string requested) {
    integer exact = llListFindList(PluginContexts, [requested]);
    if (exact != -1) return requested;

    integer best_len = 0;
    string best = "";
    integer n = llGetListLength(PluginContexts);
    integer i = 0;
    while (i < n) {
        string pc = llList2String(PluginContexts, i);
        integer plen = llStringLength(pc);
        if (plen > best_len && llStringLength(requested) > plen) {
            if (llGetSubString(requested, 0, plen - 1) == pc &&
                llGetSubString(requested, plen, plen) == ".") {
                best = pc;
                best_len = plen;
            }
        }
        i += 1;
    }
    return best;
}

// Compute the subpath remainder after stripping a matched plugin context.
string extract_subpath(string requested, string plugin_context) {
    integer plen = llStringLength(plugin_context);
    if (llStringLength(requested) <= plen + 1) return "";
    return llGetSubString(requested, plen + 1, -1);
}

// Dispatch ui.menu.start to a specific plugin. ACL is resolved LIVE here and
// the policy (acl.policycontext:<ctx>) is re-checked against it as the
// authorization gate — the view mask only governs visibility.
dispatch_to_plugin(key user, string context, string subpath) {
    integer user_acl = resolve_acl(user);
    string policy = llLinksetDataRead("acl.policycontext:" + context);
    if (policy == "") {
        send_message(user, "Access denied.");
        return;
    }
    string csv = llJsonGetValue(policy, [(string)user_acl]);
    if (csv == JSON_INVALID) {
        send_message(user, "Access denied.");
        return;
    }
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "ui.menu.start",
        "context", context,
        "subpath", subpath,
        "user",    (string)user,
        "acl",     user_acl
    ]), user);
}

handle_button_click(key user, string button, string context) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) return;

    // Blacklist gate (resolved live).
    if (actor_is_blacklisted(user)) {
        send_message(user, "You have been barred from using this collar.");
        cleanup_session(user);
        return;
    }

    integer current_page = llList2Integer(SessionPages, session_idx);
    integer total_pages = llList2Integer(SessionTotalPages, session_idx);

    // Navigation buttons (no context)
    if (button == "<<") {
        current_page -= 1;
        if (current_page < 0) current_page = total_pages - 1;
        SessionPages = llListReplaceList(SessionPages, [current_page], session_idx, session_idx);
        render_session(user);
        return;
    }

    if (button == ">>") {
        current_page += 1;
        if (current_page >= total_pages) current_page = 0;
        SessionPages = llListReplaceList(SessionPages, [current_page], session_idx, session_idx);
        render_session(user);
        return;
    }

    if (button == "Close") {
        cleanup_session(user);
        return;
    }

    // Back on a category page returns to the root tier.
    if (button == "Back" && context == "") {
        SessionCategories = llListReplaceList(SessionCategories, [""], session_idx, session_idx);
        SessionPages = llListReplaceList(SessionPages, [0], session_idx, session_idx);
        render_session(user);
        return;
    }

    // Category button: descend into the category tier.
    if (llGetSubString(context, 0, 3) == CAT_CTX_PREFIX) {
        SessionCategories = llListReplaceList(SessionCategories, [llGetSubString(context, 4, -1)], session_idx, session_idx);
        SessionPages = llListReplaceList(SessionPages, [0], session_idx, session_idx);
        render_session(user);
        return;
    }

    // Plugin button: dispatch. The session keeps its category so the
    // plugin's Back (ui.menu.return) lands on the page it launched from.
    if (context != "") {
        integer i = llListFindList(PluginContexts, [context]);
        if (i != -1) {
            dispatch_to_plugin(user, context, "");
        }
        return;
    }
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_start(string msg, key user_key) {
    // Messages with an acl field are already routed — destined for a plugin,
    // not for kmod_ui to process again.
    if (llJsonGetValue(msg, ["acl"]) != JSON_INVALID) return;

    if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) {
        start_session(user_key, ROOT_CONTEXT);
        return;
    }

    string context = llJsonGetValue(msg, ["context"]);

    if (context == ROOT_CONTEXT) {
        start_session(user_key, ROOT_CONTEXT);
        return;
    }

    if (context == SOS_CONTEXT) {
        start_session(user_key, SOS_CONTEXT);
        return;
    }

    // Plugin-specific context from kmod_chat dispatch. Longest-prefix match
    // handles namespaced subcommands (ui.core.animate.pose.nadu → animate +
    // subpath "pose.nadu"). ACL policy is checked on the matched parent.
    string matched = resolve_plugin_context(context);
    if (matched == "") {
        // Unrecognized context — unresolved alias or typo. Fall back to root
        // menu so the user gets something useful rather than silence.
        start_session(user_key, ROOT_CONTEXT);
        return;
    }
    string subpath = extract_subpath(context, matched);

    // Ensure a root session exists so the plugin's Back has somewhere to land,
    // then dispatch immediately (ACL resolved live inside dispatch).
    if (find_session_idx(user_key) == -1) {
        create_session(user_key, ROOT_CONTEXT);
    }
    dispatch_to_plugin(user_key, matched, subpath);
}

// Open a menu session (root or SOS) for a user. ACL is resolved synchronously
// at render time — no auth round-trip, no pending queue.
start_session(key user_key, string context_filter) {
    create_session(user_key, context_filter);
    render_session(user_key);
}

handle_return(string msg) {
    string user_key_str = llJsonGetValue(msg, ["user"]);
    if (user_key_str == JSON_INVALID) return;
    key user_key = (key)user_key_str;

    // Land on the tier the plugin was launched from (its category page, or
    // root). ACL is re-resolved live by render_session, so there is no
    // staleness window to re-auth around.
    if (find_session_idx(user_key) != -1) {
        render_session(user_key);
    }
    else {
        start_session(user_key, ROOT_CONTEXT);
    }
}

// Force-close a user's open dialog and drop their session. Primary caller:
// plugin_tpe on TPE acceptance (an explicit process-end close).
handle_close(string msg) {
    string user_key_str = llJsonGetValue(msg, ["user"]);
    if (user_key_str == JSON_INVALID) return;
    cleanup_session((key)user_key_str);
}

handle_dialog_response(string msg) {
    if (!validate_required_fields(msg, ["session_id", "button", "user"])) return;

    string session_id = llJsonGetValue(msg, ["session_id"]);
    string button = llJsonGetValue(msg, ["button"]);
    key user = (key)llJsonGetValue(msg, ["user"]);

    string context = "";
    string tmp = llJsonGetValue(msg, ["context"]);
    if (tmp != JSON_INVALID) {
        context = tmp;
    }

    integer idx = llListFindList(SessionIDs, [session_id]);
    if (idx != -1) {
        handle_button_click(user, button, context);
        return;
    }
}

handle_dialog_timeout(string msg) {
    if (!validate_required_fields(msg, ["session_id", "user"])) return;

    string session_id = llJsonGetValue(msg, ["session_id"]);
    key user = (key)llJsonGetValue(msg, ["user"]);

    integer idx = llListFindList(SessionIDs, [session_id]);
    if (idx != -1) {
        cleanup_session(user);
    }
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        PluginContexts = [];

        SessionUsers = [];
        SessionPages = [];
        SessionTotalPages = [];
        SessionIDs = [];
        SessionContexts = [];
        SessionCategories = [];

        TouchKeys = [];
        TouchStartTimes = [];

        // Advertise root menu context so kmod_chat can build a 'menu' alias.
        // The root context itself is NOT a plugin and does not get a reg.*
        // LSD entry — it only exists for kmod_chat's alias table.
        llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
            "type",    "kernel.register.declare",
            "context", ROOT_CONTEXT,
            "label",   "Menu",
            "script",  llGetScriptName()
        ]), NULL_KEY);

        // Prime an initial rebuild. If plugins have already written their
        // reg.* entries, we'll pick them up on the first timer tick; late
        // registrations stream in via the linkset_data event.
        schedule_rebuild();
    }

    touch_start(integer num_detected) {
        integer i = 0;
        while (i < num_detected) {
            key toucher = llDetectedKey(i);
            vector touch_pos = llDetectedTouchPos(i);

            // Skip invalid touches
            if (touch_pos == ZERO_VECTOR) {
                i += 1;
                jump next_touch;
            }

            // Validate touch distance
            float distance = llVecDist(touch_pos, llGetPos());
            if (distance > TOUCH_RANGE_M) {
                i += 1;
                jump next_touch;
            }

            // Record touch start time
            integer idx = llListFindList(TouchKeys, [toucher]);
            if (idx != -1) {
                TouchStartTimes = llListReplaceList(TouchStartTimes, [llGetTime()], idx, idx);
            } else {
                TouchKeys += [toucher];
                TouchStartTimes += [llGetTime()];
            }

            @next_touch;
            i += 1;
        }
    }

    touch_end(integer num_detected) {
        key wearer = llGetOwner();
        integer i = 0;

        while (i < num_detected) {
            key toucher = llDetectedKey(i);

            integer idx = llListFindList(TouchKeys, [toucher]);
            if (idx != -1) {
                float start_time = llList2Float(TouchStartTimes, idx);
                float duration = llGetTime() - start_time;

                TouchKeys = llDeleteSubList(TouchKeys, idx, idx);
                TouchStartTimes = llDeleteSubList(TouchStartTimes, idx, idx);

                if (duration >= LONG_TOUCH_THRESHOLD && toucher == wearer) {
                    // SOS (emergency eject) is exempt from the touch-guard — it
                    // must work even mid-boot.
                    start_session(toucher, SOS_CONTEXT);
                }
                else {
                    // Provide feedback if non-wearer attempted long-touch (SOS is wearer-only)
                    if (duration >= LONG_TOUCH_THRESHOLD && toucher != wearer) {
                        send_message(toucher, "Long-touch SOS is only available to the wearer.");
                    }
                    // Touch-guard: swallow the normal menu while the collar is
                    // still booting, so the render + view rebuild don't contend
                    // with the plugin-registration burst.
                    if (llLinksetDataRead(KEY_BOOT_READY) != "1") {
                        send_message(toucher, "Collar is still starting up — one moment.");
                    }
                    else {
                        start_session(toucher, ROOT_CONTEXT);
                    }
                }
            }

            i += 1;
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.register.refresh") {
                // Re-emit synthetic registration so kmod_chat rebuilds its alias table.
                llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
                    "type",    "kernel.register.declare",
                    "context", ROOT_CONTEXT,
                    "label",   "Menu",
                    "script",  llGetScriptName()
                ]), NULL_KEY);
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
            return;
        }

        /* -------------------- UI BUS -------------------- */
        if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") handle_start(msg, id);
            else if (msg_type == "ui.chat.command") handle_start(msg, id);
            else if (msg_type == "ui.menu.return") handle_return(msg);
            else if (msg_type == "ui.menu.close") handle_close(msg);
            return;
        }

        /* -------------------- DIALOG BUS -------------------- */
        if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") handle_dialog_response(msg);
            else if (msg_type == "ui.dialog.timeout") handle_dialog_timeout(msg);
            return;
        }
    }

    // Registry changes: any reg.* write/delete arms a debounced rebuild.
    // Our own ui.view.* writes don't match the prefix, so the rebuild can't
    // retrigger itself. A full LSD reset (factory wipe) also forces a
    // rebuild so we don't hold onto dangling state. Active sessions are NOT
    // invalidated — they re-read the fresh view on the user's next click.
    linkset_data(integer action, string name, string value) {
        if (action == LINKSETDATA_RESET) {
            schedule_rebuild();
            return;
        }
        if (llSubStringIndex(name, LSD_REG_PREFIX) == 0) {
            schedule_rebuild();
        }
        // RLV detection result flips which RLV-gated plugins are visible.
        else if (name == KEY_RLV_ACTIVE) {
            schedule_rebuild();
        }
    }

    timer() {
        if (ViewsStale) {
            ViewsStale = FALSE;
            llSetTimerEvent(0.0);
            rebuild_views();
        }
    }

    // Reset on owner change
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}

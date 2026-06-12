/*--------------------
MODULE: kmod_ui.lsl
VERSION: 1.2
REVISION: 0
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
  reset. ACL itself comes from kmod_auth's acl.<uuid>.cache as before.
  acl.policycontext:<ctx> is NOT used for menu visibility any more — it
  remains the per-button policy store inside plugins, and dispatch still
  re-checks it as the authorization gate.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- CONSTANTS -------------------- */
string ROOT_CONTEXT = "ui.core.root";
string SOS_CONTEXT = "ui.sos.root";
string SOS_PREFIX = "ui.sos.";  // Prefix for SOS plugin contexts
integer MAX_FUNC_BTNS = 9;
float TOUCH_RANGE_M = 5.0;
float LONG_TOUCH_THRESHOLD = 1.5;

integer MAX_SESSIONS = 5;
integer SESSION_MAX_AGE = 60;  // Seconds before ACL refresh required

// Per-user ACL cache prefix written by kmod_auth.lsl.
// Reading "acl.<avatar_uuid>.cache" skips the AUTH_BUS round-trip on touch.
// Value format: "<level>|<unix_timestamp>" — must match kmod_auth.lsl's store_cached_acl().
// CROSS-MODULE CONTRACT: this format must match LSD_ACL_CACHE_PREFIX/SUFFIX in kmod_auth.lsl.
string LSD_ACL_CACHE_PREFIX = "acl.";
string LSD_ACL_CACHE_SUFFIX = ".cache";

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

// Debounce window for linkset_data-driven rebuilds. Small enough to feel
// instantaneous; large enough to collapse the bootstrap burst of N plugins
// registering back-to-back into a single rebuild.
float REBUILD_DEBOUNCE = 0.1;

/* ACL levels (mirrors auth module) */
integer ACL_BLACKLIST = -1;

// Sentinel for "no cached ACL" (-1 is a real level).
integer ACL_NONE = -999;


/* -------------------- STATE -------------------- */
// Registered plugin contexts (chat dispatch + click validation). Labels,
// categories and masks live in the LSD views — not duplicated in heap.
list PluginContexts;

// Parallel Lists for Sessions
list SessionUsers;
list SessionACLs;
list SessionBlacklisted;
list SessionPages;
list SessionTotalPages;
list SessionIDs;
list SessionCreatedTimes;
list SessionContexts;    // ROOT_CONTEXT or SOS_CONTEXT
list SessionCategories;  // "" = root tier; "<Cat>" = inside that category

// Parallel Lists for Pending ACL
list PendingAclAvatars;
list PendingAclContexts;

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

/* -------------------- ACL CACHE MANAGEMENT -------------------- */

// Parse kmod_auth's per-user ACL cache entry. Returns the level, or
// ACL_NONE on miss/stale (entry older than the acl.timestamp epoch).
// Single parser shared by the touch and chat dispatch paths.
integer read_cached_acl(key user_key) {
    string raw = llLinksetDataRead(LSD_ACL_CACHE_PREFIX + (string)user_key + LSD_ACL_CACHE_SUFFIX);
    if (raw == "") return ACL_NONE;
    integer sep = llSubStringIndex(raw, "|");
    if (sep == -1) return ACL_NONE;
    integer cache_ts = (integer)llGetSubString(raw, sep + 1, -1);
    integer global_ts = (integer)llLinksetDataRead("acl.timestamp");
    if (cache_ts < global_ts) return ACL_NONE;
    return (integer)llGetSubString(raw, 0, sep - 1);
}

integer try_cached_session(key user_key, string context_filter) {
    integer level = read_cached_acl(user_key);
    if (level == ACL_NONE) return FALSE;
    create_session(user_key, level, (level == ACL_BLACKLIST), context_filter);
    render_session(user_key);
    return TRUE;
}

integer find_pending_acl_idx(key avatar_key) {
    return llListFindList(PendingAclAvatars, [avatar_key]);
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
    SessionACLs = llDeleteSubList(SessionACLs, idx, idx);
    SessionBlacklisted = llDeleteSubList(SessionBlacklisted, idx, idx);
    SessionPages = llDeleteSubList(SessionPages, idx, idx);
    SessionTotalPages = llDeleteSubList(SessionTotalPages, idx, idx);
    SessionIDs = llDeleteSubList(SessionIDs, idx, idx);
    SessionCreatedTimes = llDeleteSubList(SessionCreatedTimes, idx, idx);
    SessionContexts = llDeleteSubList(SessionContexts, idx, idx);
    SessionCategories = llDeleteSubList(SessionCategories, idx, idx);
}

create_session(key user, integer acl, integer is_blacklisted, string context_filter) {
    integer existing_idx = find_session_idx(user);
    if (existing_idx != -1) {
        cleanup_session(user);
    }

    if (llGetListLength(SessionUsers) >= MAX_SESSIONS) {
        key oldest_user = llList2Key(SessionUsers, 0);
        cleanup_session(oldest_user);
    }

    string session_id = generate_session_id(user);
    integer created_time = llGetUnixTime();

    SessionUsers += [user];
    SessionACLs += [acl];
    SessionBlacklisted += [is_blacklisted];
    SessionPages += [0];
    SessionTotalPages += [0];
    SessionIDs += [session_id];
    SessionCreatedTimes += [created_time];
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
            tab += [label, llGetSubString(k, prefix_len, -1), cat, mask];
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

// Returns "[Honorific] Name" for the primary owner (single- or multi-owner mode),
// or "" when no owner is set.
string get_primary_owner_display() {
    string owner_uuid = llLinksetDataRead("access.owner");
    if (owner_uuid != "" && owner_uuid != NULL_KEY) {
        string owner_name = llLinksetDataRead("access.ownername");
        string honorific  = llLinksetDataRead("access.ownerhonorific");
        if (honorific != "") return honorific + " " + owner_name;
        return owner_name;
    }
    string names_csv = llLinksetDataRead("access.ownernames");
    if (names_csv != "") {
        list names_list = llCSV2List(names_csv);
        string first_name = llList2String(names_list, 0);
        if (first_name != "") {
            string hons_csv = llLinksetDataRead("access.ownerhonorifics");
            if (hons_csv != "") {
                string first_hon = llList2String(llCSV2List(hons_csv), 0);
                if (first_hon != "") return first_hon + " " + first_name;
            }
            return first_name;
        }
    }
    return "";
}

send_message(key user, string message_text) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.message.show",
        "user", (string)user,
        "message", message_text
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

// Render the session's current tier from the LSD view. One LSD read per
// render; pairs are [ctx,label] JSON arrays straight from the view.
render_session(key user) {
    integer session_idx = find_session_idx(user);
    if (session_idx == -1) return;

    integer acl = llList2Integer(SessionACLs, session_idx);
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

        integer user_acl = llList2Integer(SessionACLs, session_idx);
        integer is_blacklisted = llList2Integer(SessionBlacklisted, session_idx);

        if (menu_type == SOS_CONTEXT) {
            send_message(user, "No emergency options are currently available.");
        }
        else {
            if (user_acl == -1) {
                if (is_blacklisted) {
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
            else if (user_acl == 0) {
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

    list button_data = [];
    integer start_idx = current_page * MAX_FUNC_BTNS;
    integer end_idx = start_idx + MAX_FUNC_BTNS;
    if (end_idx > entry_count) end_idx = entry_count;

    integer i = start_idx;
    while (i < end_idx) {
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

// Dispatch ui.menu.start to a specific plugin, with ACL from an existing session.
// Policy is re-checked here (LSD read) as the authorization gate — the view
// mask only governs visibility.
dispatch_to_plugin(key user, string context, string subpath, integer session_idx) {
    integer user_acl = llList2Integer(SessionACLs, session_idx);
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

    // Blacklist gate
    integer is_blacklisted = llList2Integer(SessionBlacklisted, session_idx);
    if (is_blacklisted) {
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
            dispatch_to_plugin(user, context, "", session_idx);
        }
        return;
    }
}

/* -------------------- MESSAGE HANDLERS -------------------- */

// Called after a rebuild actually applies. Closes any open dialogs and drops
// all sessions so the next touch re-creates them against the fresh views.
invalidate_all_sessions() {
    if (llGetListLength(SessionUsers) == 0) return;

    integer i = 0;
    integer len = llGetListLength(SessionIDs);
    while (i < len) {
        string session_id = llList2String(SessionIDs, i);
        string close_msg = llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", session_id
        ]);
        llMessageLinked(LINK_SET, DIALOG_BUS, close_msg, NULL_KEY);
        i += 1;
    }

    SessionUsers = [];
    SessionACLs = [];
    SessionBlacklisted = [];
    SessionPages = [];
    SessionTotalPages = [];
    SessionIDs = [];
    SessionCreatedTimes = [];
    SessionContexts = [];
    SessionCategories = [];

    PendingAclAvatars = [];
    PendingAclContexts = [];
}

handle_acl_result(string msg) {
    if (!validate_required_fields(msg, ["avatar", "level", "is_blacklisted"])) return;

    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    integer level = (integer)llJsonGetValue(msg, ["level"]);
    integer is_blacklisted = (integer)llJsonGetValue(msg, ["is_blacklisted"]);

    integer idx = find_pending_acl_idx(avatar);
    if (idx == -1) return;

    string requested_context = llList2String(PendingAclContexts, idx);

    PendingAclAvatars = llDeleteSubList(PendingAclAvatars, idx, idx);
    PendingAclContexts = llDeleteSubList(PendingAclContexts, idx, idx);

    if (requested_context == ROOT_CONTEXT || requested_context == SOS_CONTEXT) {
        create_session(avatar, level, is_blacklisted, requested_context);
        render_session(avatar);
    }
    else {
        // Plugin context from chat dispatch — create root session for navigation,
        // then dispatch directly to the plugin (with subpath if namespaced).
        create_session(avatar, level, is_blacklisted, ROOT_CONTEXT);
        integer session_idx = find_session_idx(avatar);
        if (session_idx != -1) {
            string matched = resolve_plugin_context(requested_context);
            if (matched != "") {
                string subpath = extract_subpath(requested_context, matched);
                dispatch_to_plugin(avatar, matched, subpath, session_idx);
            }
        }
    }
}

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

    // Existing session — dispatch immediately using cached ACL.
    integer session_idx = find_session_idx(user_key);
    if (session_idx != -1) {
        dispatch_to_plugin(user_key, matched, subpath, session_idx);
        return;
    }

    // LSD cache hit — create root session for navigation then dispatch.
    integer level = read_cached_acl(user_key);
    if (level != ACL_NONE) {
        create_session(user_key, level, (level == ACL_BLACKLIST), ROOT_CONTEXT);
        session_idx = find_session_idx(user_key);
        if (session_idx != -1) dispatch_to_plugin(user_key, matched, subpath, session_idx);
        return;
    }

    // Cold miss — queue ACL query, store original requested context so the
    // subpath is preserved when handle_acl_result resumes dispatch.
    integer pending_idx = find_pending_acl_idx(user_key);
    if (pending_idx != -1) return;
    PendingAclAvatars += [user_key];
    PendingAclContexts += [context];
    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type",   "auth.acl.query",
        "avatar", (string)user_key
    ]), NULL_KEY);
}

// Open a menu session (root or SOS) for a user: cached ACL when fresh,
// AUTH_BUS round-trip otherwise.
start_session(key user_key, string context_filter) {
    integer idx = find_pending_acl_idx(user_key);
    if (idx != -1) return;

    if (try_cached_session(user_key, context_filter)) {
        return;
    }

    PendingAclAvatars += [user_key];
    PendingAclContexts += [context_filter];

    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "auth.acl.query",
        "avatar", (string)user_key
    ]), NULL_KEY);
}

handle_return(string msg) {
    string user_key_str = llJsonGetValue(msg, ["user"]);
    if (user_key_str == JSON_INVALID) return;
    key user_key = (key)user_key_str;

    // Re-validate stale sessions
    integer session_idx = find_session_idx(user_key);
    if (session_idx != -1) {
        integer created_time = llList2Integer(SessionCreatedTimes, session_idx);
        integer age = llGetUnixTime() - created_time;

        if (age > SESSION_MAX_AGE) {
            string session_context = llList2String(SessionContexts, session_idx);
            cleanup_session(user_key);
            start_session(user_key, session_context);
        }
        else {
            // Land on the tier the plugin was launched from (its category
            // page, or root for Standalone plugins).
            render_session(user_key);
        }
    }
    else {
        start_session(user_key, ROOT_CONTEXT);
    }
}

// Force-close a user's open dialog and drop their session. Cached ACL is
// dropped along with the session, so the next touch re-auths from scratch.
// Primary caller: plugin_tpe on TPE acceptance.
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
        SessionACLs = [];
        SessionBlacklisted = [];
        SessionPages = [];
        SessionTotalPages = [];
        SessionIDs = [];
        SessionCreatedTimes = [];
        SessionContexts = [];
        SessionCategories = [];

        PendingAclAvatars = [];
        PendingAclContexts = [];

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
                    start_session(toucher, SOS_CONTEXT);
                }
                else {
                    // Provide feedback if non-wearer attempted long-touch (SOS is wearer-only)
                    if (duration >= LONG_TOUCH_THRESHOLD && toucher != wearer) {
                        send_message(toucher, "Long-touch SOS is only available to the wearer.");
                    }
                    start_session(toucher, ROOT_CONTEXT);
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

        /* -------------------- AUTH BUS -------------------- */
        if (num == AUTH_BUS) {
            if (msg_type == "auth.acl.result") handle_acl_result(msg);
            else if (msg_type == "auth.acl.update") {
                // ACL roles changed (ownership, trustees, public, TPE, etc.)
                // Invalidate all active sessions so they re-create with fresh ACL
                // on next touch.
                integer si = llGetListLength(SessionUsers) - 1;
                while (si >= 0) {
                    key sess_user = llList2Key(SessionUsers, si);
                    cleanup_session(sess_user);
                    si -= 1;
                }
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
    // rebuild so we don't hold onto dangling state.
    linkset_data(integer action, string name, string value) {
        if (action == LINKSETDATA_RESET) {
            schedule_rebuild();
            return;
        }
        if (llSubStringIndex(name, LSD_REG_PREFIX) == 0) {
            schedule_rebuild();
        }
    }

    timer() {
        if (ViewsStale) {
            ViewsStale = FALSE;
            llSetTimerEvent(0.0);
            rebuild_views();
            invalidate_all_sessions();
        }
    }

    // Reset on owner change
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}

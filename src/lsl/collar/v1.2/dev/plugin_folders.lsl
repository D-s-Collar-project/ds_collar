/*--------------------
PLUGIN: plugin_folders.lsl
VERSION: 1.2
REVISION: 9
PURPOSE: Manage RLV shared folders — enumerate, attach, detach, and lock #RLV subfolders
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility.
             Uses @getinv RLV command to enumerate actual #RLV subfolders in real-time;
             no text input required. Only the locked-folder list is persisted.
             Folder locks (@detachallthis:<folder>=n/y) and force-actions are
             routed through kmod_rlv on UI_BUS so refcount coordinates with
             any relay-source that asks for the same folder lock.
             plugin_strip detects locked items live via @getstatusall:detach +
             @getpath at picker render; this plugin does NOT maintain any
             shadow lock vector.
CHANGES:
- v1.2 rev 9: on safeword.fired, clear the persisted folder-lock list (LockedNames=[] + delete folders.locked) so the locks don't re-apply on the next sync — kmod_rlv already released the detachallthis claims.
- v1.2 rev 8: RLV gating — ORed bit 0x40 into PLUGIN_ACL_MASK (60→124) so kmod_ui drops this RLV-dependent plugin from the menu when rlv.active=0 (published by kmod_bootstrap). No ACL-visibility change — bit 6 sits above the level bits 1-5.
- v1.2 rev 7: menu-service migration. show_folder_pick now renders via kmod_menu OL mode (ui.menu.render mode="ordered") + the `fixed` param for the Attach/Detach/Lock|Unlock action buttons — the first consumer of fixed-button OL, which resolves kmod_menu's deferred "flanking fixed-button" note (layout_buttons handles nav+fixed at the low slots, content above, NO padding). Shed the hand-rolled target_slots/padding block (~50 lines): worn/lock indicators now ride in each item's label, breadcrumb+legend stay as the body, the page counter moves to the title. Nav realigned from context (prev/next/back) to button-label (<< >> Back) since the service renders nav as plain buttons (empty context); actions + pick:<idx> still route by context. Browse/drill/lock logic unchanged.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. See collar_kernel rev 6.
--------------------*/

/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS     = 800;
integer UI_BUS           = 900;
integer DIALOG_BUS       = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.folders";
string PLUGIN_LABEL   = "Folders";

/* -------------------- SETTINGS KEYS & CONSTANTS -------------------- */
string  KEY_LOCKED  = "folders.locked";  // CSV of folder names locked via @detachallthis

integer RLV_CHAN          = 1888753;  // Private positive channel for @getinv responses
float   RLV_TIMEOUT       = 10.0;     // Seconds to wait for viewer RLV reply
// Page size is derived per-render in show_folder_pick as `9 - action_count`,
// because the action_buttons count varies with policy: 0 at root, 2 at a
// subfolder when the user has Attach/Detach but no Lock/Unlock, 3 when
// they have all four. Effective sizes: root=9, ACL 2 subfolder=7,
// ACL 3+ subfolder=6.

/* -------------------- STATE -------------------- */
list    LockedNames       = [];   // Folder paths locked via @detachallthis:name=n

key     CurrentUser       = NULL_KEY;
integer UserAcl           = 0;
list    gPolicyButtons    = [];
string  SessionId         = "";
string  MenuContext       = "";   // "scanning" | "pick"
string  CurrentPath       = "";   // #RLV-relative browsing path; "" = #RLV root
// Strided pairs from @getinvworn: [name0, worn0, name1, worn1, ...].
// Worn is a two-digit "<self><descendants>" code (each 0-3). Folder count
// is llGetListLength(Folders) / 2. Combined to halve heap and to allow
// pre-allocation via doubling in handle_rlv_response.
list    Folders           = [];
integer PickPage          = 0;
// Stashed by show_folder_pick so the dispatcher's prev/next wrap branches
// don't have to recompute action_count → page_size → max_page. Refreshed
// on every render; only consumed by the immediately-following click.
integer LastMaxPage       = 0;
integer RlvListenHandle   = 0;

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
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

/* -------------------- LIFECYCLE -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "Avatar";
integer PLUGIN_ACL_MASK = 124;  // 60 (ACL 2-5) | 0x40 RLV-required: kmod_ui hides when rlv.active=0

register_self() {
    // Per-button visibility policy. Was written straight to LSD here; now
    // announced to the kernel, which is the SOLE writer of acl.policycontext
    // (and reg.<ctx>) — see collar_kernel rev 6.
    string policy = llList2Json(JSON_OBJECT, [
        "2", "Attach,Detach",
        "3", "Attach,Detach,Lock,Unlock",
        "4", "Attach,Detach,Lock,Unlock",
        "5", "Attach,Detach,Lock,Unlock"
    ]);

    // Announce full registration. The kernel writes reg.<ctx> + the policy to
    // LSD itself, draining its queue serially — no concurrent write burst.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label",   PLUGIN_LABEL,
        "script",  llGetScriptName(),
        "cat",     PLUGIN_CATEGORY,
        "mask",    (string)PLUGIN_ACL_MASK,
        "policy",  policy
    ]), NULL_KEY);

    // Declare chat alias.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "folders",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

stop_rlv_listen() {
    if (RlvListenHandle != 0) {
        llListenRemove(RlvListenHandle);
        RlvListenHandle = 0;
    }
    llSetTimerEvent(0.0);
}

cleanup_session() {
    stop_rlv_listen();

    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type",       "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }

    SessionId         = "";
    CurrentUser       = NULL_KEY;
    UserAcl           = 0;
    gPolicyButtons    = [];
    MenuContext       = "";
    CurrentPath       = "";
    Folders           = [];
    PickPage          = 0;
    LastMaxPage       = 0;
}

/* -------------------- SETTINGS -------------------- */

apply_settings_sync() {
    string csv = llLinksetDataRead(KEY_LOCKED);
    list new_locked = [];
    if (csv != "") new_locked = llParseString2List(csv, [","], []);

    // Lift locks that are no longer in the persisted list
    integer i = 0;
    integer len = llGetListLength(LockedNames);
    while (i < len) {
        string folder_name = llList2String(LockedNames, i);
        if (llListFindList(new_locked, [folder_name]) == -1) {
            unlock_folder(folder_name);
        }
        i += 1;
    }

    LockedNames = new_locked;

    // Reapply all current locks. kmod_rlv's claim_add is idempotent so
    // re-claiming an already-claimed behav is a no-op; this is safe to
    // call on every settings.sync to (re)establish state after a reset.
    i = 0;
    len = llGetListLength(LockedNames);
    while (i < len) {
        lock_folder(llList2String(LockedNames, i));
        i += 1;
    }
}

persist_locked() {
    // When the list goes empty, ERASE the LSD key outright via
    // settings.delete rather than writing an empty-value settings.delta.
    // An empty key would otherwise (a) get silently dropped by older
    // kmod_settings ≤ rev 15's parser, or (b) sit as a "" LSD value
    // that future readers might still interpret as present. Either way,
    // the cleanest "no locks" representation is "key absent."
    if (llGetListLength(LockedNames) == 0) {
        llMessageLinked(LINK_SET, SETTINGS_BUS,
            "settings.delete:" + KEY_LOCKED, NULL_KEY);
        return;
    }
    string csv = llDumpList2String(LockedNames, ",");
    // Single-writer settings.delta CSV protocol — kmod_settings sole LSD writer.
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + KEY_LOCKED + ":" + csv, NULL_KEY);
}

/* -------------------- RLV FOLDER COMMANDS -------------------- */

// Common consumer-id under kmod_rlv's Claims; relay sources can ask for
// the same @detachallthis:<folder> behav and the refcount engine
// coordinates without either side seeing the other's apply/release.
string RLV_CONSUMER = "folders";

rlv_op(string op, string behav) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",     op,
        "consumer", RLV_CONSUMER,
        "behav",    behav
    ]), NULL_KEY);
}

rlv_force(string command) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "rlv.force",
        "command", command
    ]), NULL_KEY);
}

attach_folder(string folder_name) {
    rlv_force("@attachall:" + folder_name + "=force");
}

detach_folder(string folder_name) {
    rlv_force("@detachall:" + folder_name + "=force");
}

lock_folder(string folder_name) {
    rlv_op("rlv.apply", "detachallthis:" + folder_name);
}

unlock_folder(string folder_name) {
    rlv_op("rlv.release", "detachallthis:" + folder_name);
}

/* -------------------- UI -------------------- */

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user",    (string)CurrentUser
    ]), NULL_KEY);
    cleanup_session();
}

// Compose a #RLV-relative full path from CurrentPath and a folder name.
string full_path(string folder_name) {
    if (CurrentPath == "") return folder_name;
    return CurrentPath + "/" + folder_name;
}

// Pop the trailing path segment from CurrentPath; "Catsuit/Boots" → "Catsuit",
// "Catsuit" → "" (root).
pop_current_path() {
    if (CurrentPath == "") return;
    list parts = llParseString2List(CurrentPath, ["/"], []);
    integer n = llGetListLength(parts);
    if (n <= 1) {
        CurrentPath = "";
        return;
    }
    CurrentPath = llDumpList2String(llList2List(parts, 0, n - 2), "/");
}

// Issue @getinvworn for CurrentPath. Empty path = #RLV root. The viewer's
// response lands in handle_rlv_response which shows show_folder_pick(0).
scan_current_path() {
    Folders  = [];
    PickPage = 0;
    MenuContext       = "scanning";
    stop_rlv_listen();
    RlvListenHandle = llListen(RLV_CHAN, "", llGetOwner(), "");
    rlv_force("@getinvworn:" + CurrentPath + "=" + (string)RLV_CHAN);
    llSetTimerEvent(RLV_TIMEOUT);
    string where = "#RLV";
    if (CurrentPath != "") where = "#RLV/" + CurrentPath;
    llRegionSayTo(CurrentUser, 0, "Reading " + where + " ...");
}

// On menu entry, scan from #RLV root. Once the viewer responds,
// show_folder_pick() presents the list. The user then picks a folder and
// sees per-folder Attach / Detach / Lock / Unlock / Open action buttons.
show_main() {
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);
    CurrentPath    = "";
    scan_current_path();
}

// Decode a @getinvworn worn-state string into a single character indicator.
// @getinvworn returns "<self><descendants>" where each digit is:
//   0 = no items, 1 = none worn, 2 = some worn, 3 = all worn.
// We surface "[+]" if anything (self or descendants) is fully worn, "[-]"
// if anything is partial, otherwise "[ ]".
string worn_indicator(string raw) {
    string self_state = "0";
    string desc_state = "0";
    if (llStringLength(raw) >= 1) self_state = llGetSubString(raw, 0, 0);
    if (llStringLength(raw) >= 2) desc_state = llGetSubString(raw, 1, 1);
    if (self_state == "3" || desc_state == "3") return "[+]";
    if (self_state == "2" || desc_state == "2") return "[-]";
    return "[ ]";
}

// Renders the subfolders at CurrentPath via the menu service's OL mode: the
// numbered folders pack above a nav row (<< >> Back) plus, at a subfolder, the
// fixed action buttons (Attach / Detach / Lock|Unlock) that operate on
// CurrentPath. Tapping a number drills into that subfolder. The worn/lock
// indicators ride in each item's label; the service owns the slot layout.
show_folder_pick(integer page) {
    integer at_subfolder = (CurrentPath != "");

    integer current_locked = FALSE;
    if (at_subfolder) {
        if (llListFindList(LockedNames, [CurrentPath]) != -1) current_locked = TRUE;
    }

    // Action buttons computed up-front because page_size depends on
    // action_count (slot 5 is content for users without Lock/Unlock policy).
    list action_buttons = [];
    if (at_subfolder) {
        if (btn_allowed("Attach")) action_buttons += [btn("Attach", "attach")];
        if (btn_allowed("Detach")) action_buttons += [btn("Detach", "detach")];
        if (current_locked) {
            if (btn_allowed("Unlock")) action_buttons += [btn("Unlock", "unlock")];
        }
        else {
            if (btn_allowed("Lock")) action_buttons += [btn("Lock", "lock")];
        }
    }
    integer action_count = llGetListLength(action_buttons);

    // 12 dialog slots minus 3 nav minus action buttons = content capacity.
    integer page_size = 9 - action_count;

    integer total = llGetListLength(Folders) / 2;

    SessionId   = generate_session_id();
    MenuContext = "pick";

    string crumb = "#RLV";
    if (at_subfolder) crumb = "#RLV/" + CurrentPath;

    integer max_page;
    if (total == 0) max_page = 0;
    else            max_page = (total - 1) / page_size;
    if (page < 0)        page = 0;
    if (page > max_page) page = max_page;
    PickPage    = page;
    LastMaxPage = max_page;

    // Items: each label carries the worn indicator + name + lock mark; OL keys
    // the click by index (pick:<global>), so the item's own context is unused.
    list items = [];
    integer i = 0;
    while (i < total) {
        string folder_name = llList2String(Folders, 2 * i);
        string worn_ind    = worn_indicator(llList2String(Folders, 2 * i + 1));
        string lock_mark   = "";
        if (llListFindList(LockedNames, [full_path(folder_name)]) != -1) lock_mark = "*";
        items += [worn_ind + " " + folder_name + lock_mark];
        i += 1;
    }

    // Breadcrumb + legend; the menu service (OL) appends the numbered folder
    // lines and moves the page counter into the title.
    string body = crumb;
    if (at_subfolder) {
        if (current_locked) body += "  (Locked)";
        else                body += "  (Unlocked)";
    }
    body += "\n\n";
    if (total == 0) {
        body += "(no subfolders here)";
    }
    else {
        body += "Tap a number to open a subfolder.\n";
        body += "[+]=worn  [-]=partial  *=locked";
    }

    // OL via the menu service: the nav row (<< >> Back) + the fixed action
    // buttons reserve the low slots; numbered folders pack above (no padding).
    // The service slices the page off `page` and numbers them; action buttons
    // return their own context, nav returns its arrow label.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "ordered",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      PLUGIN_LABEL,
        "body",       body,
        "items",      llList2Json(JSON_ARRAY, items),
        "fixed",      llList2Json(JSON_ARRAY, action_buttons),
        "page",       page
    ]), NULL_KEY);
}

// Chat subcommand handler. subpath format: "action.foldername"
// Rejects folder names that contained dots (they'd be exploded into
// multiple trailing tokens) — those must be managed via menu.
handle_subpath(key user, integer acl_level, string subpath) {
    list tokens = llParseString2List(subpath, ["."], []);
    integer n = llGetListLength(tokens);
    if (n == 0) return;
    string action = llList2String(tokens, 0);

    if (action != "attach" && action != "detach" &&
        action != "lock" && action != "unlock") {
        llRegionSayTo(user, 0, "Unknown folders subcommand: " + action);
        return;
    }

    if (n < 2) {
        llRegionSayTo(user, 0, "Usage: folders " + action + " <foldername>");
        return;
    }
    if (n > 2) {
        llRegionSayTo(user, 0,
            "Folder names containing dots are not accessible via chat — use the menu.");
        return;
    }

    string folder_name = llList2String(tokens, 1);

    // Gate: the menu-button label is the title-cased action name.
    string btn_label = "Attach";
    if (action == "detach") btn_label = "Detach";
    else if (action == "lock") btn_label = "Lock";
    else if (action == "unlock") btn_label = "Unlock";

    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);
    if (!btn_allowed(btn_label)) {
        llRegionSayTo(user, 0, "Access denied.");
        gPolicyButtons = [];
        return;
    }
    gPolicyButtons = [];

    CurrentUser = user;
    UserAcl     = acl_level;
    // Chat invocation has no UI navigation context — treat folder_name as
    // the absolute path and act on it directly.
    apply_folder_action(folder_name, action);
}

// Executes app_action on the absolute #RLV-relative folder path. Cannot
// operate on the empty path (the #RLV root itself).
apply_folder_action(string folder_path, string app_action) {
    if (folder_path == "") {
        llRegionSayTo(CurrentUser, 0, "Cannot perform that on the #RLV root.");
        return;
    }

    if (app_action == "attach") {
        attach_folder(folder_path);
        llRegionSayTo(CurrentUser, 0, "Attaching: " + folder_path);
    }
    else if (app_action == "detach") {
        if (llListFindList(LockedNames, [folder_path]) != -1) {
            llRegionSayTo(CurrentUser, 0, folder_path + " is locked. Unlock it first.");
        }
        else {
            detach_folder(folder_path);
            llRegionSayTo(CurrentUser, 0, "Detaching: " + folder_path);
        }
    }
    else if (app_action == "lock") {
        if (llListFindList(LockedNames, [folder_path]) != -1) {
            llRegionSayTo(CurrentUser, 0, folder_path + " is already locked.");
        }
        else {
            LockedNames += [folder_path];
            lock_folder(folder_path);
            persist_locked();
            llRegionSayTo(CurrentUser, 0, "Locked: " + folder_path);
        }
    }
    else if (app_action == "unlock") {
        integer idx = llListFindList(LockedNames, [folder_path]);
        if (idx == -1) {
            llRegionSayTo(CurrentUser, 0, folder_path + " is not locked.");
        }
        else {
            LockedNames = llDeleteSubList(LockedNames, idx, idx);
            unlock_folder(folder_path);
            persist_locked();
            llRegionSayTo(CurrentUser, 0, "Unlocked: " + folder_path);
        }
    }
}

/* -------------------- DIALOG HANDLER -------------------- */

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

    key response_user = (key)llJsonGetValue(msg, ["user"]);
    if (response_user != CurrentUser) return;

    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";
    // Nav (<< >> Back) renders as plain buttons → empty context, so route nav
    // by the button LABEL; actions + folder picks carry their own context.
    string button = llJsonGetValue(msg, ["button"]);
    if (button == JSON_INVALID) button = "";

    if (MenuContext != "pick") return;

    if (button == "Back" || ctx == "back") {
        // At root, exit the plugin. At a subfolder, pop one level and
        // re-scan so Back walks the user back up the path.
        if (CurrentPath == "") {
            return_to_root();
        }
        else {
            pop_current_path();
            scan_current_path();
        }
        return;
    }

    // Wrap-around paging per plugin_animate convention. LastMaxPage was
    // stashed by the most recent show_folder_pick render — current by the
    // time a click reaches us.
    if (button == "<<") {
        if (PickPage == 0) show_folder_pick(LastMaxPage);
        else               show_folder_pick(PickPage - 1);
        return;
    }
    if (button == ">>") {
        if (PickPage >= LastMaxPage) show_folder_pick(0);
        else                         show_folder_pick(PickPage + 1);
        return;
    }

    // Action buttons act on CurrentPath itself (only present at subfolder).
    // Attach/Detach refresh the worn state via re-scan; Lock/Unlock just
    // re-render in place.
    if (ctx == "attach" || ctx == "detach") {
        apply_folder_action(CurrentPath, ctx);
        scan_current_path();
        return;
    }
    if (ctx == "lock" || ctx == "unlock") {
        apply_folder_action(CurrentPath, ctx);
        show_folder_pick(PickPage);
        return;
    }

    // Numbered folder tap: drill into that subfolder.
    if (llSubStringIndex(ctx, "pick:") == 0) {
        integer idx = (integer)llGetSubString(ctx, 5, -1);
        if (idx >= 0 && idx < llGetListLength(Folders) / 2) {
            CurrentPath = full_path(llList2String(Folders, 2 * idx));
            scan_current_path();
        }
    }
}

handle_dialog_timeout(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
    cleanup_session();
}

/* -------------------- RLV RESPONSE HANDLER -------------------- */

handle_rlv_response(string message) {
    stop_rlv_listen();
    if (CurrentUser == NULL_KEY) return;

    Folders = [];
    if (message != "") {
        // @getinvworn returns "name|wornstate" pairs separated by commas.
        // wornstate is two digits "<self><descendants>" (each 0-3).
        list raw = llParseString2List(message, [","], []);
        integer max_n = llGetListLength(raw);

        // Pre-size Folders to capacity (2 entries per folder, strided) via
        // doubling. Repeated `+= [name, worn]` would reallocate the whole
        // list per iteration (O(N²) heap churn); doubling reaches capacity
        // in O(log N) appends, and llListReplaceList then fills in O(N).
        // Net build cost: O(N log N), bounded by max_n known up-front.
        integer cap = 2 * max_n;
        if (cap > 0) {
            list buf = [""];
            while (llGetListLength(buf) < cap) buf = buf + buf;
            Folders = llList2List(buf, 0, cap - 1);
        }

        integer filled = 0;
        integer i = 0;
        while (i < max_n) {
            string entry = llStringTrim(llList2String(raw, i), STRING_TRIM);
            if (entry != "") {
                integer pipe_pos = llSubStringIndex(entry, "|");
                string folder_name;
                string worn_state;
                if (pipe_pos == -1) {
                    folder_name = entry;
                    worn_state  = "0";
                }
                else if (pipe_pos > 0) {
                    folder_name = llGetSubString(entry, 0, pipe_pos - 1);
                    worn_state  = llGetSubString(entry, pipe_pos + 1, -1);
                }
                // pipe_pos == 0 means empty name before pipe — malformed, skip.
                // Skip dot-prefixed (hidden) and tilde-prefixed folders.
                // Tilde folders are auto-created by the viewer when scripted
                // objects use Give-to-#RLV; the delivering object handles the
                // attach itself, so the wearer doesn't need to manage them
                // through this menu.
                string first = llGetSubString(folder_name, 0, 0);
                if (folder_name != "" && first != "." && first != "~") {
                    Folders = llListReplaceList(Folders, [folder_name, worn_state], filled, filled + 1);
                    filled += 2;
                }
            }
            i += 1;
        }

        // Truncate placeholder tail when entries were filtered out.
        if (filled == 0)         Folders = [];
        else if (filled < cap)   Folders = llList2List(Folders, 0, filled - 1);

        // Viewer returns @getinvworn entries in inventory-internal order, not
        // alphabetical. Sort by folder name (stride 2 = name+worn pair) so
        // the picker is browsable. Lexicographic / case-sensitive.
        if (filled > 0) Folders = llListSort(Folders, 2, TRUE);
    }

    if (llGetListLength(Folders) == 0 && CurrentPath == "") {
        // Truly empty #RLV root — nothing to browse, exit cleanly.
        llRegionSayTo(CurrentUser, 0, "No shared folders found in #RLV.");
        return_to_root();
        return;
    }

    // Non-root with no subfolders is rendered as a breadcrumb-only dialog
    // by show_folder_pick so the wearer can navigate back up.
    show_folder_pick(0);
}

/* -------------------- EVENTS -------------------- */
default
{
    state_entry() {

        cleanup_session();
        apply_settings_sync();
        register_self();
    }

    on_rez(integer param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }

    timer() {
        // RLV @getinv query timed out — viewer is not RLV-enabled or not responding
        stop_rlv_listen();
        if (CurrentUser != NULL_KEY) {
            llRegionSayTo(CurrentUser, 0, "RLV not responding. Is RLV mode enabled?");
            return_to_root();
        }
    }

    listen(integer channel, string name, key id, string message) {
        if (channel == RLV_CHAN && id == llGetOwner()) {
            handle_rlv_response(message);
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.register.refresh") {
                register_self();
                apply_settings_sync();
            }
            else if (msg_type == "kernel.ping") {
                send_pong();
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync") {
                apply_settings_sync();
            }
        }
        else if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                string ctx = llJsonGetValue(msg, ["context"]);
                if (ctx != PLUGIN_CONTEXT) return;

                integer start_acl = (integer)llJsonGetValue(msg, ["acl"]);

                string subpath = "";
                string sp = llJsonGetValue(msg, ["subpath"]);
                if (sp != JSON_INVALID) subpath = sp;

                if (subpath != "") {
                    handle_subpath(id, start_acl, subpath);
                    return;
                }

                CurrentUser = id;
                UserAcl = start_acl;
                show_main();
            }
            else if (msg_type == "safeword.fired") {
                // Wearer safeword: kmod_rlv's system-wide clear already released
                // our detachallthis claims; clear the persisted lock list so they
                // don't re-apply on the next sync.
                LockedNames = [];
                persist_locked();
            }
        }
        else if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                handle_dialog_response(msg);
            }
            else if (msg_type == "ui.dialog.timeout") {
                handle_dialog_timeout(msg);
            }
        }
    }
}

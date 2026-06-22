/*--------------------
PLUGIN: plugin_restrict.lsl
VERSION: 1.2
REVISION: 11
PURPOSE: Manage RLV restriction toggles grouped by functional category
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility.
              RLV emission routed through kmod_rlv on UI_BUS so refcount
              coordinates with relay sources that may request the same
              behav.
CHANGES:
- v1.2 rev 11: nav routes by context (nav:back/nav:prev/nav:next) across all three menu blocks (main/sit_select/category), not the button label; dropped the now-unused `button` local. Categories, toggles, and pick:<idx> already routed by context.
- v1.2 rev 10: on safeword.fired (the wearer's safeword), clear the persisted restriction config (Restrictions=[] + delete restrict.list) so it doesn't re-apply on the next sync — kmod_rlv's system-wide clear already dropped the claims.
- v1.2 rev 9: nav-row consistency — show_main has_nav 0→1 so the << >> Back row matches the rest of the UI (the category menu already paged); catch-all redraw for the inert << >>.
- v1.2 rev 8: menu-service migration. show_main → pager (has_nav=0; actions + category buttons, service supplies Back). show_category_menu → pager (has_nav=1): hands the FULL [X]/[ ] toggle list and lets the service slice/page + title-suffix the page; click returns the bare @cmd. display_sit_targets → OL mode (object names in the numbered body, pick:<global-index> into SitCandidates). Nav realigned from context (prev_page/next_page/back) to button-label (<< >> Back); category toggles + sit picks route by context. Dropped reorder_item_buttons (the service's layout_buttons now does it). Restriction/sit/sittp logic unchanged.
- v1.2 rev 7: RLV gating — ORed bit 0x40 into PLUGIN_ACL_MASK (62→126) so kmod_ui drops this RLV-dependent plugin from the menu when rlv.active=0 (published by kmod_bootstrap). No ACL-visibility change — bit 6 sits above the level bits 1-5.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. See collar_kernel rev 6.
--------------------*/


/* -------------------- CHANNELS (v2 Consolidated Architecture) -------------------- */

integer KERNEL_LIFECYCLE = 500;  // register, ping/pong, soft_reset
integer SETTINGS_BUS     = 800;  // Settings sync and delta
integer UI_BUS           = 900;  // UI navigation (start, return, close)
integer DIALOG_BUS       = 950;  // Centralized dialog management

/* -------------------- PLUGIN IDENTITY -------------------- */

string  PLUGIN_CONTEXT = "ui.core.rlvrestrict";
string  PLUGIN_LABEL   = "Restrict";

/* -------------------- SETTINGS KEYS -------------------- */

string KEY_RESTRICTIONS = "restrict.list";

/* -------------------- RESTRICTION STATE -------------------- */

integer MAX_RESTRICTIONS = 32;
list Restrictions = [];  // List of active RLV commands (e.g., "@shownames")

/* -------------------- CATEGORIES -------------------- */

string CAT_NAME_INVENTORY = "Inventory";
string CAT_NAME_SPEECH    = "Speech";
string CAT_NAME_TRAVEL    = "Travel";
string CAT_NAME_OTHER     = "Other";

// CAT_* and LABEL_* are parallel-stride lists (index-paired). Both are
// pre-sorted by displayed label so render order is alphabetical without
// per-render sorting cost. Lexicographic / case-sensitive — note that
// '+' (43) and '-' (45) sort before letters (A=65) in ASCII.
//
// Mischaracterizations cleaned up in rev 16 against the RLV API:
//   - @attachall / @detachall: not y/n restrictions; RLVa aliases to
//     @attachallthis / @detachallthis (folder lock on the collar's
//     parent folder), which is plugin_folders' domain.
//   - @stand: not in the API at all (closest is @unsit, already exposed).
//   - @accepttp: add/rem exception list, not y/n — moved to plugin_rlvex.
//   - @tptlm: typo, the correct command is @tplm.
// Touch was a single @touchall toggle; split into the full hierarchy
// (@fartouch, @touchall, @touchworld, @touchattach, @touchhud, @interact)
// so the wearer doesn't lock themselves out of their own collar by
// toggling a coarse "Touch."
list CAT_INV    = ["@addattach", "@addoutfit", "@remattach", "@remoutfit", "@showinv",    "@viewnote",    "@viewscript"];
list CAT_SPEECH = ["@sendchat",  "@recvim",    "@sendim",    "@chatshout", "@startim",    "@chatwhisper"];
list CAT_TRAVEL = ["@tploc",     "@tplm",      "@sittp",     "@tplure"];
list CAT_OTHER  = ["@edit",      "@interact",  "@shownames", "@rez",       "@sit",        "@touchattach", "@fartouch",   "@touchhud",   "@touchall",  "@touchworld", "@unsit"];

// Labels carry no trailing punctuation — the [X]/[ ] checkbox prefix
// added in show_category_menu acts as the visual delimiter.
list LABEL_INV    = ["+ Attach",  "+ Outfit",  "- Attach",  "- Outfit",  "Inv",       "Notes",       "Scripts"];
list LABEL_SPEECH = ["Chat",      "Recv IM",   "Send IM",   "Shout",     "Start IM",  "Whisper"];
list LABEL_TRAVEL = ["Loc. TP",   "Map TP",    "Sit TP",    "TP"];
list LABEL_OTHER  = ["Edit",      "Isolate",   "Names",     "Rez",       "Sit",       "Touch Att",   "Touch Far",   "Touch HUD",   "Touch Own",  "Touch Wld",   "Unsit"];

/* -------------------- UI SESSION STATE -------------------- */

string SessionId = "";
key CurrentUser = NULL_KEY;
integer UserAcl = 0;
list gPolicyButtons = [];

string MenuContext = "";      // "main", "category"
string CurrentCategory = "";
integer CurrentPage = 0;

integer DIALOG_PAGE_SIZE = 9;  // 9 items + 3 nav buttons = 12 total

/* -------------------- FORCE SIT STATE -------------------- */

list SitCandidates = [];  // Stride list: [name, key, name, key, ...]
integer SitPage = 0;
float SIT_SCAN_RANGE = 10.0;  // Scan range in meters
key ScanInitiator = NULL_KEY;  // Track who initiated the scan to prevent race conditions

/* -------------------- HELPER FUNCTIONS -------------------- */

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

string generate_session_id() {
    return llGetScriptName() + "_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
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

/* -------------------- LIFECYCLE -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "RLV";
integer PLUGIN_ACL_MASK = 126;  // 62 (ACL 1-5) | 0x40 RLV-required: kmod_ui hides when rlv.active=0

register_self() {
    // Per-button visibility policy (default-deny per ACL level). Was written
    // straight to LSD here; now announced to the kernel, which is the SOLE
    // writer of acl.policycontext (and reg.<ctx>) — see collar_kernel rev 6.
    string policy = llList2Json(JSON_OBJECT, [
        "1", "Force Sit,Force Unsit",
        "2", "Force Sit,Force Unsit",
        "3", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        "4", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        "5", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit"
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
        "alias",   "restrict",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }

    SessionId = "";
    CurrentUser = NULL_KEY;
    UserAcl = 0;
    gPolicyButtons = [];
    MenuContext = "";
    CurrentCategory = "";
    CurrentPage = 0;
}

/* -------------------- SETTINGS PERSISTENCE -------------------- */

persist_restrictions() {
    // When all restrictions are lifted, ERASE the LSD key via
    // settings.delete rather than persisting an empty-value settings.delta.
    // Per kmod_settings rev 16 the empty-value path now works defensively,
    // but explicit deletion is the semantically-correct "no restrictions
    // active" representation and protects against partial-rollback
    // scenarios where older kmod_settings would silently drop the write.
    if (llGetListLength(Restrictions) == 0) {
        llMessageLinked(LINK_SET, SETTINGS_BUS,
            "settings.delete:" + KEY_RESTRICTIONS, NULL_KEY);
        return;
    }
    string csv = llDumpList2String(Restrictions, ",");
    // Single-writer settings.delta CSV protocol — kmod_settings sole LSD writer.
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + KEY_RESTRICTIONS + ":" + csv, NULL_KEY);
}

/* -------------------- KMOD_RLV PROXY -------------------- */

string RLV_CONSUMER = "restrict";

// Restrictions list stores commands with the leading "@" (e.g., "@shownames");
// kmod_rlv expects the bare behav string. Strip the prefix on emission.
rlv_op(string op, string restr_cmd) {
    string behav = llGetSubString(restr_cmd, 1, -1);
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",     op,
        "consumer", RLV_CONSUMER,
        "behav",    behav
    ]), NULL_KEY);
}

rlv_clear_all() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",     "rlv.clear",
        "consumer", RLV_CONSUMER
    ]), NULL_KEY);
}

rlv_force(string command) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "rlv.force",
        "command", command
    ]), NULL_KEY);
}

apply_settings_sync() {
    string csv = llLinksetDataRead(KEY_RESTRICTIONS);
    list new_list = [];
    if (csv != "") {
        new_list = llParseString2List(csv, [","], []);
    }

    // Compare with current state; if unchanged, nothing to do
    if (llDumpList2String(new_list, ",") == llDumpList2String(Restrictions, ",")) return;

    // Release any current restriction not in the new list
    integer i = 0;
    integer count = llGetListLength(Restrictions);
    while (i < count) {
        string restr_cmd = llList2String(Restrictions, i);
        if (llListFindList(new_list, [restr_cmd]) == -1) {
            rlv_op("rlv.release", restr_cmd);
        }
        i = i + 1;
    }

    // Apply the new list. claim_add is idempotent in kmod_rlv so applying
    // an already-claimed behav is a no-op; safe to call on every sync.
    Restrictions = new_list;
    i = 0;
    count = llGetListLength(Restrictions);
    while (i < count) {
        rlv_op("rlv.apply", llList2String(Restrictions, i));
        i = i + 1;
    }

    // Reconcile the implicit @sittp hold from @tplm / @tploc after the
    // explicit applies are out — covers the case where neither @sittp
    // nor its implier was in the previous state but is in the new one,
    // or vice versa.
    reconcile_sittp();
}

/* -------------------- RESTRICTION LOGIC -------------------- */

integer restriction_idx(string restr_cmd) {
    return llListFindList(Restrictions, [restr_cmd]);
}

// @sittp viewer state derives from the OR of three sources: the user's
// explicit "Sit TP" toggle, plus implicit holds from @tplm and @tploc
// (a wearer who can't normally TP shouldn't be able to bypass via
// far-sit-warp either). The Restrictions list only contains @sittp when
// the user toggled it explicitly; reconcile_sittp drives the viewer
// state from the combined source. kmod_rlv claim_add/remove is
// idempotent per (consumer, behav), so repeated calls here are safe.
reconcile_sittp() {
    integer explicit = (llListFindList(Restrictions, ["@sittp"]) != -1);
    integer implied  = (llListFindList(Restrictions, ["@tplm"])  != -1)
                    || (llListFindList(Restrictions, ["@tploc"]) != -1);
    if (explicit || implied) rlv_op("rlv.apply",   "@sittp");
    else                     rlv_op("rlv.release", "@sittp");
}

toggle_restriction(string restr_cmd) {
    integer idx = restriction_idx(restr_cmd);
    // @sittp's viewer state is owned by reconcile_sittp — skip the direct
    // apply/release here for the explicit toggle so the two sources don't
    // race. The Restrictions list still reflects the user's explicit
    // choice for UI checkbox purposes.
    integer is_sittp        = (restr_cmd == "@sittp");
    integer affects_sittp   = is_sittp
                           || (restr_cmd == "@tplm")
                           || (restr_cmd == "@tploc");

    if (idx != -1) {
        // Remove restriction
        Restrictions = llDeleteSubList(Restrictions, idx, idx);
        if (!is_sittp) rlv_op("rlv.release", restr_cmd);
    }
    else {
        // Add restriction
        if (llGetListLength(Restrictions) >= MAX_RESTRICTIONS) {
            llRegionSayTo(CurrentUser, 0, "Cannot add restriction: limit reached.");
            return;
        }

        Restrictions += [restr_cmd];
        if (!is_sittp) rlv_op("rlv.apply", restr_cmd);
    }

    if (affects_sittp) reconcile_sittp();
    persist_restrictions();
}

remove_all_restrictions() {
    rlv_clear_all();
    Restrictions = [];
    persist_restrictions();
}

/* -------------------- CATEGORY HELPERS -------------------- */

list get_category_list(string cat_name) {
    if (cat_name == CAT_NAME_INVENTORY) return CAT_INV;
    if (cat_name == CAT_NAME_SPEECH) return CAT_SPEECH;
    if (cat_name == CAT_NAME_TRAVEL) return CAT_TRAVEL;
    if (cat_name == CAT_NAME_OTHER) return CAT_OTHER;
    return [];
}

list get_category_labels(string cat_name) {
    if (cat_name == CAT_NAME_INVENTORY) return LABEL_INV;
    if (cat_name == CAT_NAME_SPEECH) return LABEL_SPEECH;
    if (cat_name == CAT_NAME_TRAVEL) return LABEL_TRAVEL;
    if (cat_name == CAT_NAME_OTHER) return LABEL_OTHER;
    return [];
}

/* -------------------- FORCE SIT/UNSIT -------------------- */

start_sit_scan() {
    SitCandidates = [];
    SitPage = 0;
    MenuContext = "sit_scan";
    ScanInitiator = CurrentUser;  // Lock scan to this user

    llRegionSayTo(CurrentUser, 0, "Scanning for nearby objects...");
    llSensor("", NULL_KEY, PASSIVE | ACTIVE | SCRIPTED, SIT_SCAN_RANGE, PI);
}

display_sit_targets() {
    integer total_items = llGetListLength(SitCandidates) / 2;

    if (total_items == 0) {
        llRegionSayTo(CurrentUser, 0, "No objects found nearby.");
        show_main();
        return;
    }

    SessionId = generate_session_id();
    MenuContext = "sit_select";

    // OL picker: object names go in the numbered body (names can exceed the
    // 24-char button cap); the click returns pick:<global-index> into the
    // SitCandidates stride list. The service pages off SitPage.
    list items = [];
    integer i = 0;
    while (i < total_items) {
        string obj_name = llList2String(SitCandidates, i * 2);
        if (llStringLength(obj_name) > 28) obj_name = llGetSubString(obj_name, 0, 25) + "...";
        items += [obj_name];
        i = i + 1;
    }

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "ordered",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      "Force Sit",
        "body",       "Select an object to sit on:",
        "items",      llList2Json(JSON_ARRAY, items),
        "page",       SitPage
    ]), NULL_KEY);
}

force_sit_on(key target) {
    if (target == NULL_KEY) return;

    rlv_force("@sit:" + (string)target + "=force");
    llRegionSayTo(CurrentUser, 0, "Forcing sit...");
}

force_unsit() {
    rlv_force("@unsit=force");
    llRegionSayTo(CurrentUser, 0, "Forcing unsit...");
}

/* -------------------- UI NAVIGATION -------------------- */

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user", (string)CurrentUser
    ]), NULL_KEY);

    cleanup_session();
}

/* -------------------- MENUS -------------------- */

show_main() {
    SessionId = generate_session_id();
    MenuContext = "main";

    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    list item_buttons = [];

    // Alphabetical by displayed label.
    if (btn_allowed("Clear all"))   item_buttons += [btn("Clear all",        "clear_all")];
    if (btn_allowed("Force Sit"))   item_buttons += [btn("Force Sit",        "force_sit")];
    if (btn_allowed("Force Unsit")) item_buttons += [btn("Force Unsit",      "force_unsit")];
    if (btn_allowed("Inventory"))   item_buttons += [btn(CAT_NAME_INVENTORY, "cat_inventory")];
    if (btn_allowed("Other"))       item_buttons += [btn(CAT_NAME_OTHER,     "cat_other")];
    if (btn_allowed("Speech"))      item_buttons += [btn(CAT_NAME_SPEECH,    "cat_speech")];
    if (btn_allowed("Travel"))      item_buttons += [btn(CAT_NAME_TRAVEL,    "cat_travel")];

    string body;
    if (btn_allowed("Inventory")) {
        body = "RLV Restrictions\n\nActive: " + (string)llGetListLength(Restrictions) + "/" + (string)MAX_RESTRICTIONS;
    }
    else {
        body = "RLV Actions\n\nForce sit or unsit the wearer.";
    }

    // Pager (has_nav=1: full << >> Back nav row — the project convention; the
    // inert << >> redraw via the handler's catch-all). Content = the actions
    // + category buttons.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      PLUGIN_LABEL,
        "body",       body,
        "category",   PLUGIN_CATEGORY,
        "has_nav",    1,
        "buttons",    llList2Json(JSON_ARRAY, item_buttons),
        "page",       0
    ]), NULL_KEY);
}

show_category_menu(string cat_name, integer page_num) {
    SessionId = generate_session_id();
    MenuContext = "category";
    CurrentCategory = cat_name;
    CurrentPage = page_num;

    list cat_cmds = get_category_list(cat_name);
    list cat_labels = get_category_labels(cat_name);
    integer total_items = llGetListLength(cat_cmds);

    if (total_items == 0) {
        llRegionSayTo(CurrentUser, 0, "Empty category.");
        show_main();
        return;
    }

    // ALL toggle buttons ([X]/[ ] checkbox prefix per current state); the menu
    // service (pager, has_nav=1) slices the page, adds << >> Back, and suffixes
    // the page count onto the title. The click returns the bare @cmd context.
    list item_buttons = [];
    integer i = 0;
    while (i < total_items) {
        string cmd   = llList2String(cat_cmds, i);
        string label = llList2String(cat_labels, i);
        if (restriction_idx(cmd) != -1) label = "[X] " + label;
        else                            label = "[ ] " + label;
        item_buttons += [btn(label, cmd)];
        i = i + 1;
    }

    string body = "Active: " + (string)llGetListLength(Restrictions);

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      cat_name,
        "body",       body,
        "category",   PLUGIN_CATEGORY,
        "has_nav",    1,
        "buttons",    llList2Json(JSON_ARRAY, item_buttons),
        "page",       page_num
    ]), NULL_KEY);
}

/* -------------------- DIALOG HANDLERS -------------------- */

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID || llJsonGetValue(msg, ["context"]) == JSON_INVALID || llJsonGetValue(msg, ["user"]) == JSON_INVALID) return;

    string recv_session = llJsonGetValue(msg, ["session_id"]);
    if (recv_session != SessionId) return;

    key user = (key)llJsonGetValue(msg, ["user"]);
    if (user != CurrentUser) return;

    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";
    // Every button routes by context: nav (nav:*), categories, toggles, picks.

    // Main menu
    if (MenuContext == "main") {
        if (ctx == "nav:back") {
            return_to_root();
        }
        else if (ctx == "cat_inventory") {
            if (!btn_allowed("Inventory")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            show_category_menu(CAT_NAME_INVENTORY, 0);
        }
        else if (ctx == "cat_speech") {
            if (!btn_allowed("Speech")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            show_category_menu(CAT_NAME_SPEECH, 0);
        }
        else if (ctx == "cat_travel") {
            if (!btn_allowed("Travel")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            show_category_menu(CAT_NAME_TRAVEL, 0);
        }
        else if (ctx == "cat_other") {
            if (!btn_allowed("Other")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            show_category_menu(CAT_NAME_OTHER, 0);
        }
        else if (ctx == "clear_all") {
            if (!btn_allowed("Clear all")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_main();
                return;
            }
            remove_all_restrictions();
            llRegionSayTo(CurrentUser, 0, "All restrictions removed.");
            show_main();
        }
        else if (ctx == "force_sit") {
            start_sit_scan();
        }
        else if (ctx == "force_unsit") {
            force_unsit();
            show_main();
        }
        else {
            // Inert << >> on this single-page menu — redraw.
            show_main();
        }
    }
    // Sit selection menu
    else if (MenuContext == "sit_select") {
        if (ctx == "nav:back") {
            show_main();
        }
        else if (ctx == "nav:prev") {
            integer max_page = (llGetListLength(SitCandidates) / 2 - 1) / 9;
            if (SitPage == 0) SitPage = max_page;
            else              SitPage = SitPage - 1;
            display_sit_targets();
        }
        else if (ctx == "nav:next") {
            integer max_page = (llGetListLength(SitCandidates) / 2 - 1) / 9;
            if (SitPage >= max_page) SitPage = 0;
            else                     SitPage = SitPage + 1;
            display_sit_targets();
        }
        else if (llGetSubString(ctx, 0, 4) == "pick:") {
            // OL pick: pick:<global-index> into the SitCandidates stride list.
            integer list_idx = (integer)llGetSubString(ctx, 5, -1) * 2;
            if (list_idx + 1 < llGetListLength(SitCandidates)) {
                key target = (key)llList2String(SitCandidates, list_idx + 1);
                force_sit_on(target);
                show_main();
            }
        }
    }
    // Category menu
    else if (MenuContext == "category") {
        if (ctx == "nav:back") {
            show_main();
        }
        else if (ctx == "nav:prev") {
            integer max_page = (llGetListLength(get_category_list(CurrentCategory)) - 1) / DIALOG_PAGE_SIZE;
            if (CurrentPage == 0) show_category_menu(CurrentCategory, max_page);
            else                  show_category_menu(CurrentCategory, CurrentPage - 1);
        }
        else if (ctx == "nav:next") {
            integer max_page = (llGetListLength(get_category_list(CurrentCategory)) - 1) / DIALOG_PAGE_SIZE;
            if (CurrentPage >= max_page) show_category_menu(CurrentCategory, 0);
            else                         show_category_menu(CurrentCategory, CurrentPage + 1);
        }
        else {
            // Context is the RLV command directly (e.g., "@detachall")
            string restr_cmd = ctx;
            if (restriction_idx(restr_cmd) != -1 || llGetSubString(restr_cmd, 0, 0) == "@") {
                toggle_restriction(restr_cmd);
                show_category_menu(CurrentCategory, CurrentPage);
            }
        }
    }
}

handle_dialog_timeout(string msg) {
    string recv_session = llJsonGetValue(msg, ["session_id"]);
    if (recv_session == JSON_INVALID) return;
    if (recv_session != SessionId) return;

    cleanup_session();
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

    link_message(integer sender, integer num, string msg, key id) {
        string type = llJsonGetValue(msg, ["type"]);
        if (type == JSON_INVALID) return;

        // Kernel lifecycle
        if (num == KERNEL_LIFECYCLE) {
            if (type == "kernel.register.refresh") {
                register_self();
                apply_settings_sync();
            }
            else if (type == "kernel.ping") {
                send_pong();
            }
            else if (type == "kernel.reset.soft" || type == "kernel.reset.factory") {
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
                llResetScript();
            }
        }
        // Settings
        else if (num == SETTINGS_BUS) {
            if (type == "settings.sync") {
                apply_settings_sync();
            }
        }
        // UI
        else if (num == UI_BUS) {
            if (type == "ui.menu.start") {
                string context = llJsonGetValue(msg, ["context"]);
                if (context == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;

                if (context == PLUGIN_CONTEXT) {
                    integer acl = (integer)llJsonGetValue(msg, ["acl"]);

                    string subpath = "";
                    string sp = llJsonGetValue(msg, ["subpath"]);
                    if (sp != JSON_INVALID) subpath = sp;

                    if (subpath == "clear") {
                        // Chat: <prefix> restrict clear. Gate via menu policy.
                        gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl);
                        if (!btn_allowed("Clear all")) {
                            llRegionSayTo(id, 0, "Access denied.");
                            gPolicyButtons = [];
                            return;
                        }
                        gPolicyButtons = [];
                        remove_all_restrictions();
                        llRegionSayTo(id, 0, "All restrictions removed.");
                        return;
                    }
                    if (subpath != "") {
                        llRegionSayTo(id, 0, "Unknown restrict subcommand: " + subpath);
                        return;
                    }

                    CurrentUser = id;
                    UserAcl = acl;
                    show_main();
                }
            }
            else if (type == "sos.restrict.clear") {
                // Emergency clear from plugin_sos (wearer-only gate enforced
                // upstream). Drop every active RLV restriction.
                remove_all_restrictions();
            }
            else if (type == "safeword.fired") {
                // Wearer safeword: kmod_rlv's system-wide clear already dropped
                // our claims, so we only clear the persisted config + local list
                // so the restrictions don't re-apply on the next sync.
                Restrictions = [];
                persist_restrictions();
            }
        }
        // Dialogs
        else if (num == DIALOG_BUS) {
            if (type == "ui.dialog.response") {
                handle_dialog_response(msg);
            }
            else if (type == "ui.dialog.timeout") {
                handle_dialog_timeout(msg);
            }
        }
    }

    sensor(integer num_detected) {
        if (MenuContext != "sit_scan") return;
        if (CurrentUser == NULL_KEY) return;
        // Verify scan belongs to the user who initiated it (race condition guard)
        if (CurrentUser != ScanInitiator) return;

        key wearer = llGetOwner();
        key my_key = llGetKey();
        SitCandidates = [];

        integer i = 0;
        while (i < num_detected) {
            key detected_key = llDetectedKey(i);
            // Exclude self (collar) and wearer
            if (detected_key != my_key && detected_key != wearer) {
                string detected_name = llDetectedName(i);
                SitCandidates += [detected_name, detected_key];
            }
            i = i + 1;
        }

        display_sit_targets();
    }

    no_sensor() {
        if (MenuContext != "sit_scan") return;
        if (CurrentUser == NULL_KEY) return;
        // Verify scan belongs to the user who initiated it (race condition guard)
        if (CurrentUser != ScanInitiator) return;

        llRegionSayTo(CurrentUser, 0, "No objects found within " + (string)((integer)SIT_SCAN_RANGE) + "m.");
        show_main();
    }
}

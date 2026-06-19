/*--------------------
PLUGIN: plugin_strip.lsl
VERSION: 1.2
REVISION: 9
PURPOSE: Strip unlocked clothing layers and attachments from the wearer.
         Public to every ACL. Items in @detachallthis-locked subfolders
         (e.g. plugin_outfits's outfits/.base claim) silently survive
         the strip command; locked-folder paths are surfaced in the
         picker header so the wearer can see which folders are
         protected even though per-item folder membership is
         unknowable via RLV.
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button
             visibility. Enumerates worn items live via @getoutfit +
             llGetAttachedList; reads lock state via @getstatusall on
             three keyspaces (remoutfit, remattach, detach). The
             detach response also surfaces @detachallthis:<path>
             entries; their paths are displayed in the picker header
             but cannot be used to filter individual items — RLV's
             @getpath returns the worn item's ORIGINAL inventory
             location (typically main inventory), not the #RLV-folder
             link's location, so for the standard SL inventory-link
             outfit pattern (links in #RLV pointing to originals
             elsewhere) per-item folder filtering is structurally
             impossible. Items in locked folders appear in the picker;
             the strip command silently fails on them; the
             verify_attempted_strip + DiscoveredLocked pair catches
             the failure on first click and hides them for the rest
             of the session. parse_status uses `;|` separator so
             @detachallthis paths (which embed `/`) survive parsing.
CHANGES:
- v1.2 rev 9: nav-row consistency — show_category_menu has_nav 0→1 so the << >> Back row matches the rest of the UI; catch-all redraw for the inert << >> (the strip picker already pages).
- v1.2 rev 8: menu-service migration. show_category_menu → pager (has_nav=0, service supplies Back); show_picker → kmod_menu OL mode — per-item display (ellipsized name [+@slot]) + lock mark ride the item label, page counter moves to title, the hand-rolled target_slots/padding block shed (no fixed buttons, page_size 9). Nav realigned from context (prev/next/back) to button-label (<< >> Back); categories + pick:<idx> still route by context. Strip logic + live @getstatusall lock detection unchanged.
- v1.2 rev 7: RLV gating — ORed bit 0x40 into PLUGIN_ACL_MASK (62→126) so kmod_ui drops this RLV-dependent plugin from the menu when rlv.active=0 (published by kmod_bootstrap). No ACL-visibility change — bit 6 sits above the level bits 1-5.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. See collar_kernel rev 6.
--------------------*/

/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS           = 900;
integer DIALOG_BUS       = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.strip";
string PLUGIN_LABEL   = "Strip";

/* -------------------- RLV -------------------- */
integer RLV_CHAN    = 1888771;
float   RLV_TIMEOUT = 10.0;

/* -------------------- LAYERS -------------------- */
list LAYER_NAMES = [
    "gloves", "jacket", "pants", "shirt", "shoes", "skirt", "socks",
    "underpants", "undershirt", "skull", "eyes", "hair", "shape",
    "alpha", "tattoo", "physics", "universal"
];
list STRIPPABLE_LAYER_IDX = [0, 1, 2, 3, 4, 5, 6, 7, 8, 13, 14, 15, 16];

/* -------------------- ATTACH POINTS -------------------- */
list ATTACH_NAMES = [
    "",
    "chest", "skull", "left shoulder", "right shoulder",
    "left hand", "right hand", "left foot", "right foot",
    "spine", "pelvis",
    "mouth", "chin", "left ear", "right ear",
    "left eye", "right eye", "nose",
    "r upper arm", "r forearm", "l upper arm", "l forearm",
    "right hip", "r upper leg", "r lower leg",
    "left hip", "l upper leg", "l lower leg",
    "stomach", "left pec", "right pec",
    "center 2", "top right", "top", "top left", "center",
    "bottom left", "bottom", "bottom right",
    "neck", "root",
    "left ring finger", "right ring finger",
    "tail base", "tail tip",
    "left wing", "right wing",
    "jaw",
    "alt left ear", "alt right ear",
    "alt left eye", "alt right eye",
    "tongue",
    "groin",
    "left hind foot", "right hind foot"
];

/* -------------------- STATE -------------------- */
key     CurrentUser    = NULL_KEY;
integer UserAcl        = 0;
list    gPolicyButtons = [];
string  SessionId      = "";

// 1=@getoutfit  2=@getstatusall:remoutfit  3=:remattach  4=:detach  0=idle
integer QState = 0;

string  RawOutfit          = "";
integer GlobalOutfitLocked = FALSE;
integer GlobalAttachLocked = FALSE;
list    LockedLayers       = [];     // layer names with @remoutfit:<name>=n
list    LockedAttach       = [];     // slot names with @remattach:<slot>=n OR @detach:<slot>=n
list    LockedFolders      = [];     // @detachallthis:<path> from Q4 — shown in picker header
list    WornLayers         = [];     // stride 1
list    WornAttach         = [];     // stride 2: [slot, item_name]

string  CurrentCategory = "";        // "" = chooser, "L" = layers, "A" = attach
integer PickPage    = 0;
integer LastMaxPage = 0;

string  AttemptedItem    = "";
list    DiscoveredLocked = [];

integer RlvListenHandle = 0;

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string sid() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

string btn(string label, string ctx) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", ctx]);
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

string ellipsize(string s, integer max_len) {
    if (llStringLength(s) <= max_len) return s;
    if (max_len <= 3)                 return llGetSubString(s, 0, max_len - 1);
    return llGetSubString(s, 0, max_len - 4) + "...";
}

list prealloc(integer n) {
    if (n <= 0) return [];
    list buf = [""];
    while (llGetListLength(buf) < n) buf = buf + buf;
    return llList2List(buf, 0, n - 1);
}

/* -------------------- LIFECYCLE -------------------- */

// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "Avatar";
integer PLUGIN_ACL_MASK = 126;  // 62 (ACL 1-5) | 0x40 RLV-required: kmod_ui hides when rlv.active=0

register_self() {
    // Per-button visibility policy. Was written straight to LSD here; now
    // announced to the kernel, the SOLE writer of acl.policycontext (and
    // reg.<ctx>) — see collar_kernel rev 6. ACL 1 (public) and every higher
    // tier — Strip is open to all.
    string policy = llList2Json(JSON_OBJECT, [
        "1", "Strip",
        "2", "Strip",
        "3", "Strip",
        "4", "Strip",
        "5", "Strip"
    ]);

    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label",   PLUGIN_LABEL,
        "script",  llGetScriptName(),
        "cat",     PLUGIN_CATEGORY,
        "mask",    (string)PLUGIN_ACL_MASK,
        "policy",  policy
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
            "type", "ui.dialog.close", "session_id", SessionId
        ]), NULL_KEY);
    }
    SessionId          = "";
    CurrentUser        = NULL_KEY;
    UserAcl            = 0;
    gPolicyButtons     = [];
    QState             = 0;
    RawOutfit          = "";
    GlobalOutfitLocked = FALSE;
    GlobalAttachLocked = FALSE;
    LockedLayers       = [];
    LockedAttach       = [];
    LockedFolders      = [];
    WornLayers         = [];
    WornAttach         = [];
    CurrentCategory    = "";
    PickPage           = 0;
    LastMaxPage        = 0;
    AttemptedItem      = "";
    DiscoveredLocked   = [];
}

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return", "context", PLUGIN_CONTEXT, "user", (string)CurrentUser
    ]), NULL_KEY);
    cleanup_session();
}

/* -------------------- RLV QUERY CHAIN -------------------- */

rlv_force(string command) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "rlv.force", "command", command
    ]), NULL_KEY);
}

begin_query() {
    RawOutfit          = "";
    GlobalOutfitLocked = FALSE;
    GlobalAttachLocked = FALSE;
    LockedLayers       = [];
    LockedAttach       = [];
    LockedFolders      = [];
    WornLayers         = [];
    WornAttach         = [];

    QState = 1;
    if (RlvListenHandle == 0) RlvListenHandle = llListen(RLV_CHAN, "", llGetOwner(), "");
    llSetTimerEvent(RLV_TIMEOUT);
    rlv_force("@getoutfit=" + (string)RLV_CHAN);
}

// `;|` separator required: @detachallthis:<path> entries embed `/`,
// which the default separator would split mid-path.
advance_query() {
    llSetTimerEvent(RLV_TIMEOUT);
    if (QState == 2) { rlv_force("@getstatusall:remoutfit;|=" + (string)RLV_CHAN); return; }
    if (QState == 3) { rlv_force("@getstatusall:remattach;|=" + (string)RLV_CHAN); return; }
    if (QState == 4) { rlv_force("@getstatusall:detach;|="   + (string)RLV_CHAN); }
}

/* -------------------- RESPONSE PARSERS -------------------- */

// Parse "|key:val|key" style responses. Bare key (no `:val`) signals a
// category-level lock and is returned as a leading "" entry.
list parse_status(string raw, string key_name) {
    list out = [];
    if (raw == "") return out;
    list parts = llParseString2List(raw, ["|"], []);
    integer n = llGetListLength(parts);
    string  prefix   = key_name + ":";
    integer prefix_n = llStringLength(prefix);
    integer global_seen = FALSE;
    integer i = 0;
    while (i < n) {
        string p = llStringTrim(llList2String(parts, i), STRING_TRIM);
        if (p == key_name) global_seen = TRUE;
        else if (llSubStringIndex(p, prefix) == 0) out += [llGetSubString(p, prefix_n, -1)];
        i += 1;
    }
    if (global_seen) out = [""] + out;
    return out;
}

// Extract detachallthis:<path> entries from a Q4 response. Shown in the
// picker header so the wearer can see which folders are protected.
list parse_detachallthis(string raw) {
    list out = [];
    if (raw == "") return out;
    list parts = llParseString2List(raw, ["|"], []);
    integer n = llGetListLength(parts);
    string  prefix   = "detachallthis:";
    integer prefix_n = llStringLength(prefix);
    integer i = 0;
    while (i < n) {
        string p = llStringTrim(llList2String(parts, i), STRING_TRIM);
        if (llSubStringIndex(p, prefix) == 0) {
            string path = llGetSubString(p, prefix_n, -1);
            if (path != "") out += [path];
        }
        i += 1;
    }
    return out;
}

/* -------------------- BUILD WORN LISTS -------------------- */

build_worn_layers() {
    integer max_layers = llGetListLength(STRIPPABLE_LAYER_IDX);
    WornLayers = prealloc(max_layers);
    integer filled = 0;
    integer layer_count = llStringLength(RawOutfit);
    integer i = 0;
    while (i < max_layers) {
        integer layer_idx = llList2Integer(STRIPPABLE_LAYER_IDX, i);
        if (layer_idx < layer_count
            && llGetSubString(RawOutfit, layer_idx, layer_idx) == "1") {
            string layer_name = llList2String(LAYER_NAMES, layer_idx);
            integer skip = FALSE;
            if (GlobalOutfitLocked) skip = TRUE;
            if (!skip && llListFindList(LockedLayers, [layer_name]) != -1) skip = TRUE;
            // DiscoveredLocked layers stay visible — marked with " *" by
            // show_picker so the wearer sees the lock without item churn.
            if (!skip) {
                WornLayers = llListReplaceList(WornLayers, [layer_name], filled, filled);
                filled += 1;
            }
        }
        i += 1;
    }
    if (filled == 0)              WornLayers = [];
    else if (filled < max_layers) WornLayers = llList2List(WornLayers, 0, filled - 1);
}

// HUD attach points (31-38) skipped via the pt range check.
build_worn_attach() {
    list attached = llGetAttachedList(llGetOwner());
    integer max_n = llGetListLength(attached);
    integer cap = max_n * 2;
    WornAttach = prealloc(cap);
    integer filled = 0;
    integer attach_names_n = llGetListLength(ATTACH_NAMES);
    integer i = 0;
    while (i < max_n) {
        list details = llGetObjectDetails(llList2Key(attached, i),
            [OBJECT_NAME, OBJECT_ATTACHED_POINT]);
        if (llGetListLength(details) >= 2) {
            string  item_name = llList2String(details, 0);
            integer pt        = llList2Integer(details, 1);
            if (pt > 0 && pt < attach_names_n && (pt < 31 || pt > 38)) {
                string slot_name = llList2String(ATTACH_NAMES, pt);
                if (slot_name != "") {
                    integer skip = FALSE;
                    if (GlobalAttachLocked) skip = TRUE;
                    if (!skip && llListFindList(LockedAttach, [slot_name]) != -1) skip = TRUE;
                    // DiscoveredLocked items stay visible — marked with
                    // " *" by show_picker.
                    if (!skip) {
                        WornAttach = llListReplaceList(WornAttach,
                            [slot_name, item_name], filled, filled + 1);
                        filled += 2;
                    }
                }
            }
        }
        i += 1;
    }
    if (filled == 0)       WornAttach = [];
    else if (filled < cap) WornAttach = llList2List(WornAttach, 0, filled - 1);
}

/* -------------------- POST-STRIP VERIFY -------------------- */

integer is_layer_still_worn(string layer_name) {
    integer idx = llListFindList(LAYER_NAMES, [layer_name]);
    if (idx == -1) return FALSE;
    if (idx >= llStringLength(RawOutfit)) return FALSE;
    return (llGetSubString(RawOutfit, idx, idx) == "1");
}

integer is_attach_slot_worn(string slot_name) {
    list attached = llGetAttachedList(llGetOwner());
    integer attach_names_n = llGetListLength(ATTACH_NAMES);
    integer n = llGetListLength(attached);
    integer i = 0;
    while (i < n) {
        list det = llGetObjectDetails(llList2Key(attached, i), [OBJECT_ATTACHED_POINT]);
        if (llGetListLength(det) >= 1) {
            integer pt = llList2Integer(det, 0);
            if (pt > 0 && pt < attach_names_n && llList2String(ATTACH_NAMES, pt) == slot_name) {
                return TRUE;
            }
        }
        i += 1;
    }
    return FALSE;
}

// If the just-attempted item is still worn, the strip silently failed
// (almost always a parent-folder @detachallthis). Record the slot/layer
// so subsequent renders omit it; notify the wearer once.
verify_attempted_strip() {
    if (AttemptedItem == "") return;
    list parts = llParseString2List(AttemptedItem, [":"], []);
    if (llGetListLength(parts) != 2) {
        AttemptedItem = "";
        return;
    }
    string atype = llList2String(parts, 0);
    string aname = llList2String(parts, 1);

    integer still_worn = FALSE;
    if (atype == "L")      still_worn = is_layer_still_worn(aname);
    else if (atype == "A") still_worn = is_attach_slot_worn(aname);

    if (still_worn) {
        if (llListFindList(DiscoveredLocked, [AttemptedItem]) == -1) {
            DiscoveredLocked += [AttemptedItem];
        }
        llRegionSayTo(CurrentUser, 0, aname + " is locked — cannot strip.");
    }
    AttemptedItem = "";
}

/* -------------------- UI -------------------- */

// Format LockedFolders as a single comma-separated line for the picker
// header. Returns "" when nothing is locked.
string locked_folders_line() {
    integer n = llGetListLength(LockedFolders);
    if (n == 0) return "";
    // Bound the joined names: many/long locked folders could otherwise push
    // the picker body past llDialog's 512-char ceiling.
    return "Locked folders: " + ellipsize(llDumpList2String(LockedFolders, ", "), 48) + "\n";
}

show_category_menu() {
    SessionId       = sid();
    CurrentCategory = "";
    PickPage        = 0;
    LastMaxPage     = 0;

    string body = "Strip menu\n\n";
    body += locked_folders_line();
    body += "Layers:      " + (string)llGetListLength(WornLayers) + " strippable\n";
    body += "Attachments: " + (string)(llGetListLength(WornAttach) / 2) + " strippable\n\n";
    body += "Choose category.";

    // Pager (has_nav=1: full << >> Back nav row; inert << >> redraw). Content = categories.
    list button_data = [
        btn("Layers",      "layers"),
        btn("Attachments", "attach")
    ];

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      PLUGIN_LABEL,
        "body",       body,
        "category",   PLUGIN_CATEGORY,
        "has_nav",    1,
        "buttons",    llList2Json(JSON_ARRAY, button_data),
        "page",       0
    ]), NULL_KEY);
}

show_picker(string category, integer page) {
    integer total;
    string  header;
    if (category == "L") {
        total  = llGetListLength(WornLayers);
        header = "Strip — Layers\n";
    } else {
        total  = llGetListLength(WornAttach) / 2;
        header = "Strip — Attachments\n";
    }

    SessionId       = sid();
    CurrentCategory = category;

    integer page_size = 9;
    integer max_page  = 0;
    if (total > 0) max_page = (total - 1) / page_size;
    if (page < 0)        page = 0;
    if (page > max_page) page = max_page;
    PickPage    = page;
    LastMaxPage = max_page;

    string body = header;
    body += locked_folders_line();
    if (llGetListLength(DiscoveredLocked) > 0) body += "* = locked";
    if (total == 0) body += "\n\nNothing to strip.";

    // Items: per-item display (layer name, or "name @slot", ellipsized) + lock
    // mark; the OL service numbers them and returns pick:<global-index>. The
    // page counter moves into the title.
    list items = [];
    integer k = 0;
    while (k < total) {
        string mark = "";
        if (category == "L") {
            string layer_name = llList2String(WornLayers, k);
            if (llListFindList(DiscoveredLocked, ["L:" + layer_name]) != -1) mark = " *";
            items += [ellipsize(layer_name, 28) + mark];
        }
        else {
            string slot_name = llList2String(WornAttach, k * 2);
            if (llListFindList(DiscoveredLocked, ["A:" + slot_name]) != -1) mark = " *";
            // Bound the whole "name @slot" display (slot suffix was un-capped).
            items += [ellipsize(llList2String(WornAttach, k * 2 + 1) + " @" + slot_name, 30) + mark];
        }
        k += 1;
    }

    // OL via the menu service: nav (<< >> Back) reserves the low slots, numbered
    // items pack above. No fixed buttons here (page_size 9).
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "ordered",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      PLUGIN_LABEL,
        "body",       body,
        "items",      llList2Json(JSON_ARRAY, items),
        "page",       page
    ]), NULL_KEY);
}

apply_pick(integer item_idx) {
    if (CurrentCategory == "L") {
        if (item_idx < 0 || item_idx >= llGetListLength(WornLayers)) return;
        string layer_name = llList2String(WornLayers, item_idx);
        AttemptedItem = "L:" + layer_name;
        rlv_force("@remoutfit:" + layer_name + "=force");
    }
    else if (CurrentCategory == "A") {
        integer total = llGetListLength(WornAttach) / 2;
        if (item_idx < 0 || item_idx >= total) return;
        string slot_name = llList2String(WornAttach, item_idx * 2);
        AttemptedItem = "A:" + slot_name;
        rlv_force("@remattach:" + slot_name + "=force");
    }
    else return;

    begin_query();
}

/* -------------------- DIALOG HANDLER -------------------- */

show_current_picker(integer page) {
    if (CurrentCategory == "L" || CurrentCategory == "A") show_picker(CurrentCategory, page);
    else                                                  show_category_menu();
}

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
    if ((key)llJsonGetValue(msg, ["user"]) != CurrentUser) return;

    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";
    // Nav (<< >> Back) renders as plain buttons → empty context; route nav by
    // the button LABEL. Categories + pick:<idx> carry their own context.
    string button = llJsonGetValue(msg, ["button"]);
    if (button == JSON_INVALID) button = "";

    if (CurrentCategory == "") {
        if (ctx == "layers") { show_picker("L", 0); return; }
        if (ctx == "attach") { show_picker("A", 0); return; }
        if (button == "Back" || ctx == "back") { return_to_root(); return; }
        show_category_menu();   // inert << >> — redraw
        return;
    }

    if (button == "Back" || ctx == "back") { show_category_menu(); return; }
    if (button == "<<") {
        if (PickPage == 0) show_current_picker(LastMaxPage);
        else               show_current_picker(PickPage - 1);
        return;
    }
    if (button == ">>") {
        if (PickPage >= LastMaxPage) show_current_picker(0);
        else                         show_current_picker(PickPage + 1);
        return;
    }
    if (llSubStringIndex(ctx, "pick:") == 0) {
        apply_pick((integer)llGetSubString(ctx, 5, -1));
    }
}

handle_dialog_timeout(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
    cleanup_session();
}

/* -------------------- RLV RESPONSE -------------------- */

handle_rlv_response(string message) {
    if (CurrentUser == NULL_KEY) return;

    if (QState == 1) {
        RawOutfit = message;
        QState = 2;
        advance_query();
        return;
    }
    if (QState == 2) {
        list parsed = parse_status(message, "remoutfit");
        if (llGetListLength(parsed) > 0 && llList2String(parsed, 0) == "") {
            GlobalOutfitLocked = TRUE;
            parsed = llDeleteSubList(parsed, 0, 0);
        }
        LockedLayers = parsed;
        QState = 3;
        advance_query();
        return;
    }
    if (QState == 3) {
        list parsed = parse_status(message, "remattach");
        if (llGetListLength(parsed) > 0 && llList2String(parsed, 0) == "") {
            GlobalAttachLocked = TRUE;
            parsed = llDeleteSubList(parsed, 0, 0);
        }
        LockedAttach = parsed;
        QState = 4;
        advance_query();
        return;
    }
    if (QState == 4) {
        // Q4 detach response carries three concepts:
        //   bare detach        — ignored (normal collar self-lock state)
        //   detach:<slot>      — merged into LockedAttach (per-slot lock)
        //   detachallthis:<p>  — surfaced in LockedFolders for header display
        list parsed = parse_status(message, "detach");
        if (llGetListLength(parsed) > 0 && llList2String(parsed, 0) == "") {
            parsed = llDeleteSubList(parsed, 0, 0);
        }
        integer di = 0;
        integer dn = llGetListLength(parsed);
        while (di < dn) {
            string pt = llList2String(parsed, di);
            if (pt != "" && llListFindList(LockedAttach, [pt]) == -1) LockedAttach += [pt];
            di += 1;
        }
        LockedFolders = parse_detachallthis(message);

        verify_attempted_strip();
        build_worn_layers();
        build_worn_attach();
        QState = 0;
        stop_rlv_listen();
        show_current_picker(PickPage);
    }
}

/* -------------------- EVENTS -------------------- */
default {
    state_entry() {
        cleanup_session();
        register_self();
    }

    on_rez(integer param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    timer() {
        stop_rlv_listen();
        if (CurrentUser != NULL_KEY) {
            llRegionSayTo(CurrentUser, 0, "RLV not responding. Is RLV mode enabled?");
            return_to_root();
        }
    }

    listen(integer channel, string name, key id, string message) {
        if (channel == RLV_CHAN && id == llGetOwner()) handle_rlv_response(message);
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.register.refresh") register_self();
            else if (msg_type == "kernel.ping") send_pong();
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
                llResetScript();
            }
        }
        else if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                if (id == NULL_KEY) return;

                integer start_acl = (integer)llJsonGetValue(msg, ["acl"]);
                gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, start_acl);
                if (!btn_allowed("Strip")) {
                    llRegionSayTo(id, 0, "Access denied.");
                    gPolicyButtons = [];
                    return;
                }
                gPolicyButtons = [];

                CurrentUser     = id;
                UserAcl         = start_acl;
                CurrentCategory = "";
                PickPage        = 0;
                llRegionSayTo(CurrentUser, 0, "Reading worn items...");
                begin_query();
            }
        }
        else if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") handle_dialog_response(msg);
            else if (msg_type == "ui.dialog.timeout") handle_dialog_timeout(msg);
        }
    }
}

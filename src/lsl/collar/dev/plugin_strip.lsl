/*--------------------
PLUGIN: plugin_strip.lsl
VERSION: 1.10
REVISION: 17
PURPOSE: Strip individual unlocked attachments or layers worn from
         #RLV shared folders, excluding anything in #RLV/outfits/.base
         and anything that any active RLV restriction prevents from
         being detached.
ACL: 1 (public — available to every ACL level).
SCOPE — what the picker IS allowed to show:
- Attachments whose @getpathnew:<slot> returns a non-empty path AND
  whose path is NOT under any active @detachallthis-locked subtree
  AND whose attach point has no @detach:<slot>=n / @remattach:<slot>=n.
- Clothing layers whose @getoutfit bit is 1, whose @remoutfit:<name>
  has no per-layer lock, AND whose global @remoutfit=n is not active.
SCOPE — what the picker MUST NOT show:
- Items in outfits/.base — the dot prefix makes RLV's folder API
  (@getpathnew specifically) return empty for them, which we treat
  as DROP. The same dot-skip simultaneously hides items not in any
  #RLV shared folder (HUDs, drag-attached, mesh body parts), which
  matches the "RLV shared folders only" requirement.
- Items whose @getpathnew result falls under any active
  @detachallthis:<path>=n claim (e.g. a locked outfits/myout).
- Items at a slot with @detach:<slot>=n or @remattach:<slot>=n
  (per-slot locks visible via @getstatusall).
- Worn clothing layers when ANY @detachallthis claim is active.
  RLV exposes no per-layer source-folder query — so when even one
  folder lock is in play we conservatively hide all layers rather
  than risk surfacing a locked one.
KNOWN GAP:
- A foreign attachment that self-locks via bare @detach=n (the
  standard restraint self-lock pattern) is invisible to us — the
  RLV spec deliberately hides the issuing UUID. Such items will
  appear in the picker on first session entry; the strip command
  silently fails, verify_attempted_strip detects the still-worn
  item, and DiscoveredLocked hides it for the rest of the session.
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven
             button visibility. Five-step RLV query chain per
             picker render:
               Q1  @getoutfit                      → layer bits
               Q2  @getstatusall:remoutfit;|       → layer locks
               Q3  @getstatusall:remattach;|       → per-slot remattach
               Q4  @getstatusall:detach;|          → per-slot detach
                                                     + detachallthis paths
               Q5  @getpathnew:<slot>=<chan>, one  → item source folder(s)
                    per worn attachment slot
             Q5 is skipped entirely when there are zero detachallthis
             entries AND zero worn attachments — no point probing
             paths when there's nothing to match against.
CHANGES:
- v1.10 rev 17: DiscoveredLocked items stay visible in the picker
  marked with " *" instead of disappearing. The bare-@detach=n
  self-locked attachments we can't pre-detect (RLV spec hides UUIDs
  of issuing scripts) now appear with the asterisk after first
  click-fail. Body header gains "*=locked" legend. Click on a marked
  item still fires the strip; RLV silently fails again;
  verify_attempted_strip is a no-op for already-discovered items
  (still emits the "X is locked" warning). Same behaviour for
  layers and attachments.
- v1.10 rev 16: Full rewrite to implement the picker scope spec above.
  New: parse_detachallthis pulls detachallthis:<path> entries from the
  Q4 response into LockedFolders; Q5 @getpathnew sweep resolves each
  worn attachment's #RLV-relative path(s) and filter_worn_attach_by_folder
  drops slots whose path is empty (in .base or not under #RLV) OR
  matches any LockedFolders entry. Multi-path @getpathnew responses
  (comma-separated when an item is linked to several folders) are
  split and each path checked. normalize_path lowercases and strips
  leading/trailing slashes on both sides so RLVa formatting variation
  doesn't break the match. Layers conservatively suppressed when any
  folder lock is active (RLV provides no per-layer source-folder
  query). The bare-@detach=n blind spot stays as documented above —
  caught by DiscoveredLocked on first click.
- v1.10 rev 14: ATTACH_NAMES extended to 56 entries (Bento slots).
  Drop GlobalDetachLocked filter from build_worn_attach (bare detach
  is normal collar state).
- v1.10 rev 13: Drop @detachallthis:.outfits/.base claim — plugin_outfits
  owns it.
- v1.10 rev 12: Merge per-category pickers into show_picker(category).
- v1.10 rev 6: Category split (Layers / Attachments / Back).
- v1.10 rev 0: Initial implementation.
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

// 1=@getoutfit  2=@getstatusall:remoutfit  3=:remattach  4=:detach
// 5=per-slot @getpathnew sweep (skipped if LockedFolders empty)
integer QState = 0;

string  RawOutfit          = "";
integer GlobalOutfitLocked = FALSE;
integer GlobalAttachLocked = FALSE;
list    LockedLayers       = [];     // layer names with @remoutfit:<name>=n
list    LockedAttach       = [];     // slot names with @remattach:<slot>=n OR @detach:<slot>=n
list    LockedFolders      = [];     // detachallthis:<path> from Q4
list    WornLayers         = [];     // stride 1
list    WornAttach         = [];     // stride 2: [slot, item_name]
list    AttachPaths        = [];     // stride 2: [slot, raw_getpathnew_response]
integer PathCheckIdx       = 0;

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

// Lowercase + strip leading/trailing slashes. Applied to both sides of
// the path match so RLVa response formatting (leading "/", trailing "/",
// case differences) doesn't break it.
string normalize_path(string p) {
    p = llToLower(llStringTrim(p, STRING_TRIM));
    integer pn = llStringLength(p);
    if (pn == 0) return p;
    if (llGetSubString(p, 0, 0) == "/") {
        p = llGetSubString(p, 1, -1);
        pn -= 1;
    }
    if (pn > 0 && llGetSubString(p, -1, -1) == "/") p = llGetSubString(p, 0, -2);
    return p;
}

/* -------------------- LIFECYCLE -------------------- */

write_plugin_reg(string label) {
    string k = "plugin.reg." + PLUGIN_CONTEXT;
    string v = llList2Json(JSON_OBJECT, ["label", label, "script", llGetScriptName()]);
    if (llLinksetDataRead(k) == v) return;
    llLinksetDataWrite(k, v);
}

register_self() {
    // ACL 1 (public) and every higher tier — Strip is open to all.
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "Strip",
        "2", "Strip",
        "3", "Strip",
        "4", "Strip",
        "5", "Strip"
    ]));
    write_plugin_reg(PLUGIN_LABEL);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label",   PLUGIN_LABEL,
        "script",  llGetScriptName()
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
    AttachPaths        = [];
    PathCheckIdx       = 0;
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
    AttachPaths        = [];
    PathCheckIdx       = 0;

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

// Extract detachallthis:<path> entries from a Q4 response.
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
    // RLV exposes no per-layer source-folder query — so when ANY folder
    // lock is active we conservatively suppress all strippable layers,
    // because we can't tell which layer is from a locked subtree.
    // Wearer uses plugin_outfits Wear for layer changes in that case.
    if (llGetListLength(LockedFolders) > 0) {
        WornLayers = [];
        return;
    }

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
            // DiscoveredLocked layers are NOT skipped — they appear in the
            // picker with a " *" mark (see show_picker). Click still fires
            // the strip; RLV silently fails; verify_attempted_strip is a
            // no-op for already-discovered items.
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
                    // DiscoveredLocked items are NOT skipped — they appear
                    // in the picker with a " *" mark (see show_picker).
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

// Apply two drop rules to WornAttach:
//   1. Empty @getpathnew response → DROP. This covers both items in
//      dot-prefixed folders (incl. outfits/.base — RLV's folder API
//      treats dot folders as disabled) AND items not under #RLV at
//      all (HUDs, drag-attached, mesh body parts). Per the picker
//      spec, neither category belongs in the UI.
//   2. Any returned path falls under any LockedFolders entry → DROP.
//      @getpathnew returns comma-separated paths when an item is
//      linked into multiple #RLV folders, so we check each.
filter_worn_attach_by_folder() {
    if (llGetListLength(WornAttach) == 0) return;

    integer lf_n = llGetListLength(LockedFolders);
    list normalized_lf = [];
    integer ln = 0;
    while (ln < lf_n) {
        normalized_lf += [normalize_path(llList2String(LockedFolders, ln))];
        ln += 1;
    }

    list new_worn = [];
    integer n = llGetListLength(WornAttach);
    integer i = 0;
    while (i < n) {
        string slot = llList2String(WornAttach, i);
        string item = llList2String(WornAttach, i + 1);
        string raw_response = "";
        integer pi = llListFindList(AttachPaths, [slot]);
        if (pi != -1) raw_response = llList2String(AttachPaths, pi + 1);

        integer drop = FALSE;
        if (raw_response == "") {
            // Rule 1: empty → DROP.
            drop = TRUE;
        } else {
            // Rule 2: split comma-separated paths and check each.
            // llCSV2List("") returns [""] not [] — guarded above so we
            // only get here with non-empty input.
            list raw_paths = llCSV2List(raw_response);
            integer rp_n = llGetListLength(raw_paths);
            integer rpi = 0;
            while (rpi < rp_n && !drop) {
                string single = normalize_path(llList2String(raw_paths, rpi));
                if (single != "") {
                    integer lj = 0;
                    while (lj < lf_n) {
                        string lf = llList2String(normalized_lf, lj);
                        if (lf != "" && (single == lf || llSubStringIndex(single, lf + "/") == 0)) {
                            drop = TRUE;
                            lj = lf_n;
                        } else {
                            lj += 1;
                        }
                    }
                }
                rpi += 1;
            }
        }
        if (!drop) new_worn += [slot, item];
        i += 2;
    }
    WornAttach = new_worn;
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
// (most commonly a self-issued @detach=n that we can't pre-detect).
// Record the slot/layer so subsequent renders omit it.
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

show_category_menu() {
    SessionId       = sid();
    CurrentCategory = "";
    PickPage        = 0;
    LastMaxPage     = 0;

    string body = "Strip menu\n\n";
    body += "Layers:      " + (string)llGetListLength(WornLayers) + " strippable\n";
    body += "Attachments: " + (string)(llGetListLength(WornAttach) / 2) + " strippable\n\n";
    body += "Choose category.";

    list button_data = [
        btn("Layers",      "layers"),
        btn("Attachments", "attach"),
        btn("Back",        "back")
    ];

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type",        "ui.dialog.open",
        "session_id",  SessionId,
        "user",        (string)CurrentUser,
        "title",       PLUGIN_LABEL,
        "body",        body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout",     60
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

    // No action buttons; page_size = 9 (full content area).
    integer action_count = 0;
    integer page_size    = 9;

    integer max_page = 0;
    if (total > 0) max_page = (total - 1) / page_size;
    if (page < 0)        page = 0;
    if (page > max_page) page = max_page;
    PickPage    = page;
    LastMaxPage = max_page;

    integer start_idx = page * page_size;
    integer end_idx   = start_idx + page_size;
    if (end_idx > total) end_idx = total;
    integer count = end_idx - start_idx;

    string body = header;
    if (total == 0) {
        body += "\nNothing to strip.";
    } else {
        body += "*=locked  Page " + (string)(page + 1) + " of " + (string)(max_page + 1) + "\n\n";
        integer k = 0;
        while (k < count) {
            integer item_idx = start_idx + k;
            string mark = "";
            if (category == "L") {
                string layer_name = llList2String(WornLayers, item_idx);
                if (llListFindList(DiscoveredLocked, ["L:" + layer_name]) != -1) mark = " *";
                body += (string)(k + 1) + ". " + layer_name + mark + "\n";
            } else {
                string slot_name = llList2String(WornAttach, item_idx * 2);
                string item_name = ellipsize(llList2String(WornAttach, item_idx * 2 + 1), 30);
                if (llListFindList(DiscoveredLocked, ["A:" + slot_name]) != -1) mark = " *";
                body += (string)(k + 1) + ". " + item_name + " @" + slot_name + mark + "\n";
            }
            k += 1;
        }
    }

    // Project dialog convention (canonical: plugin_animate):
    //   slots 0-2 = nav (<<, >>, Back); slots 3-11 = content top→bottom.
    list button_data = [btn("<<", "prev"), btn(">>", "next"), btn("Back", "back")];
    integer pad_i;
    for (pad_i = 0; pad_i < count; pad_i += 1) button_data += [btn(" ", " ")];

    integer first_content_slot = 3 + action_count;
    integer total_buttons      = first_content_slot + count;

    list target_slots = [];
    if (total_buttons > 9)  target_slots += [9];
    if (total_buttons > 10) target_slots += [10];
    if (total_buttons > 11) target_slots += [11];
    if (total_buttons > 6)  target_slots += [6];
    if (total_buttons > 7)  target_slots += [7];
    if (total_buttons > 8)  target_slots += [8];
    if (first_content_slot <= 3 && total_buttons > 3) target_slots += [3];
    if (first_content_slot <= 4 && total_buttons > 4) target_slots += [4];
    if (first_content_slot <= 5 && total_buttons > 5) target_slots += [5];

    integer ci = 0;
    while (ci < count) {
        integer slot = llList2Integer(target_slots, ci);
        button_data = llListReplaceList(
            button_data,
            [btn((string)(ci + 1), "pick:" + (string)(start_idx + ci))],
            slot, slot
        );
        ci += 1;
    }

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type",        "ui.dialog.open",
        "session_id",  SessionId,
        "user",        (string)CurrentUser,
        "title",       PLUGIN_LABEL,
        "body",        body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout",     60
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

    if (CurrentCategory == "") {
        if (ctx == "layers") { show_picker("L", 0); return; }
        if (ctx == "attach") { show_picker("A", 0); return; }
        if (ctx == "back")   return_to_root();
        return;
    }

    if (ctx == "back") { show_category_menu(); return; }
    if (ctx == "prev") {
        if (PickPage == 0) show_current_picker(LastMaxPage);
        else               show_current_picker(PickPage - 1);
        return;
    }
    if (ctx == "next") {
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
        //   detachallthis:<p>  — LockedFolders (drives Q5 path sweep)
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

        // Q5 only when needed: skipped if no folder locks AND no worn
        // attachments (no point querying paths with nothing to match).
        // When folder locks ARE active we always sweep so we can apply
        // both drop rules (empty path AND path-match).
        if (llGetListLength(WornAttach) > 0
            && (llGetListLength(LockedFolders) > 0 || llGetListLength(LockedFolders) == 0)) {
            // The "always sweep when attachments exist" branch — even
            // without folder locks we still need to drop empty-path
            // items per the picker spec (Rule 1 in filter_worn_attach_by_folder).
            QState = 5;
            PathCheckIdx = 0;
            llSetTimerEvent(RLV_TIMEOUT);
            string first_slot = llList2String(WornAttach, 0);
            rlv_force("@getpathnew:" + first_slot + "=" + (string)RLV_CHAN);
            return;
        }

        QState = 0;
        stop_rlv_listen();
        show_current_picker(PickPage);
        return;
    }
    if (QState == 5) {
        integer pair_idx = PathCheckIdx * 2;
        if (pair_idx < llGetListLength(WornAttach)) {
            string slot = llList2String(WornAttach, pair_idx);
            AttachPaths += [slot, message];
        }
        PathCheckIdx += 1;
        integer next_idx = PathCheckIdx * 2;
        if (next_idx < llGetListLength(WornAttach)) {
            llSetTimerEvent(RLV_TIMEOUT);
            string next_slot = llList2String(WornAttach, next_idx);
            rlv_force("@getpathnew:" + next_slot + "=" + (string)RLV_CHAN);
            return;
        }
        filter_worn_attach_by_folder();
        QState = 0;
        stop_rlv_listen();
        show_current_picker(PickPage);
    }
}

/* -------------------- EVENTS -------------------- */
default {
    state_entry() {
        if (llGetObjectDesc() == "COLLAR_UPDATER") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }
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
                llLinksetDataDelete("plugin.reg." + PLUGIN_CONTEXT);
                llLinksetDataDelete("acl.policycontext:" + PLUGIN_CONTEXT);
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

/*--------------------
PLUGIN: plugin_strip.lsl
VERSION: 1.10
REVISION: 6
PURPOSE: Strip unlocked clothing layers and attachments from the wearer.
         Available to every ACL level (public / owned wearer / trustee /
         self-owned wearer / primary owner). Items worn from
         #RLV/.outfits/.base are folder-locked at register time and
         never appear in the picker, so the wearer cannot strip their
         outfit-system base kit regardless of the open policy. Pairs
         with plugin_outfits (#RLV/.outfits/ as the outfits library;
         the .base subfolder is the protected "non-strippable" set).
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button
             visibility. Enumerates worn items live via @getoutfit /
             @getattach; reads lock state via @getstatusall;remoutfit /
             ;remattach. Strip operations route through kmod_rlv
             (rlv.force passthrough). Locked items are filtered from
             the picker entirely — taps only ever target strippable
             items. On register the plugin claims a permanent
             @detachallthis:.base lock through kmod_rlv so anything
             worn from #RLV/.base is protected from strip and the
             folder lock is reference-counted with any other consumer.
CHANGES:
- v1.10 rev 6: UI split + free attachment names. The unified picker
  (mixed L:/A: rows) is replaced by a top-level category chooser
  (Layers / Attachments / Back) that drills into a paginated
  per-category picker. Attachments now show real item names from
  llGetAttachedList(llGetOwner()) — display reads e.g.
  "1. Maitreya Cuffs @left hand" instead of just "A: left hand".
  Internal changes:
    * @getattach RLV query is gone — llGetAttachedList is synchronous,
      faster (no roundtrip), and bundles OBJECT_NAME with the slot
      mapping so we don't need to maintain a separate attachment-to-
      name lookup.
    * Query chain shrinks from 4 RLV roundtrips to 3 (outfit + two
      getstatusall lock queries).
    * WornItems (stride-2 mixed) replaced by WornLayers (stride-1) +
      WornAttach (stride-2: point, item_name).
    * CurrentCategory tracks which picker is active so post-strip
      re-renders return to the same picker, while a fresh menu entry
      always lands on the category chooser.
    * verify_attempted_strip's bit-string check for attach is replaced
      by is_attach_slot_worn (re-queries llGetAttachedList).
  Debug scaffolding (DEBUG_STRIP + logd) is still in place pending
  in-world confirmation of the new flow; will strip in a follow-up.
- v1.10 rev 5: Fix the @getstatusall lock-detection probes. The
  syntax was inverted — `@getstatusall;remoutfit=<chan>` (semicolon)
  vs the canonical `@getstatusall:<filter>=<chan>` (colon). The
  semicolon-form is reserved for an optional custom separator
  AFTER a filter; using it as the filter-delimiter parses as an
  unrecognised command and the viewer silently drops it. Diagnosed
  via DEBUG_STRIP: @getoutfit and @getattach responded correctly,
  then QState 3 timed out at exactly the broken probe. Both
  invocations corrected to use the colon form. Debug scaffolding
  still in place pending confirmation; will strip in a follow-up rev.
- v1.10 rev 4: Move the protected-folder lock from `.base` (top-level)
  to `.outfits/.base` (nested) to match the OC-style outfit-system
  convention paired with plugin_outfits: `#RLV/.outfits/` is the
  outfits library, `#RLV/.outfits/.base/` is the non-strippable
  subfolder. Items linked from `.outfits/<name>/` (regular outfits)
  are no longer folder-locked, so plugin_outfits' Replace
  (@detachall:.outfits=force + @attachall:.outfits/<new>=force) can
  swap them; .base items are silently skipped by the force command
  because of the @detachallthis lock applied here.
- v1.10 rev 3: Open policy to all ACL levels (1/2/3/4/5). Previous
  exclusion of ACL 2/4 (owned/self-owned wearer) is dropped at the
  user's direction; the .base @detachallthis claim already prevents
  the wearer from stripping their core attachments, so policy-gating
  the entire plugin was redundant.
- v1.10 rev 2: build_worn_list pre-allocates WornItems via list
  doubling and fills with llListReplaceList instead of `+=` inside
  the layer/attach loops. Matches plugin_folders rev 26 pattern;
  clears the analyzer's O(N²) loop-concat warning.
- v1.10 rev 1: Hide locked items from the picker instead of marking
  them. @getstatusall-detected y/n locks filter immediately; locks
  applied via @detachallthis (e.g., on .base) are caught on the
  first strip attempt via DiscoveredLocked and hidden thereafter.
  Plugin now claims @detachallthis:.base on register so items worn
  from #RLV/.base cannot be stripped via this menu (or anywhere).
- v1.10 rev 0: Initial implementation.
--------------------*/

/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS           = 900;
integer DIALOG_BUS       = 950;

/* -------------------- TEMPORARY DEBUG -------------------- */
// "RLV not responding" diagnostic. Flip to FALSE to silence.
// Remove this block and all logd(...) calls once the bug is found.
integer DEBUG_STRIP = TRUE;
logd(string s) {
    if (DEBUG_STRIP) llOwnerSay("[strip-dbg] " + s);
}

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.strip";
string PLUGIN_LABEL   = "Strip";

/* -------------------- RLV -------------------- */
integer RLV_CHAN    = 1888771;
float   RLV_TIMEOUT = 10.0;
string  BASE_FOLDER = ".outfits/.base";  // #RLV-relative; items here are never strippable.
string  RLV_CONSUMER = "strip";          // kmod_rlv consumer id for our @detachallthis claim.

/* -------------------- LAYER NAMES (matches @getoutfit response order) -------------------- */
// RLV @getoutfit returns a 0/1 string with characters in this canonical
// order. Body-part layers (skull, eyes, hair, shape) are not strippable
// via @remoutfit and are excluded from the worn list below.
list LAYER_NAMES = [
    "gloves", "jacket", "pants", "shirt", "shoes", "skirt", "socks",
    "underpants", "undershirt", "skull", "eyes", "hair", "shape",
    "alpha", "tattoo", "physics", "universal"
];

// Indices into LAYER_NAMES that @remoutfit accepts as targets.
list STRIPPABLE_LAYER_IDX = [0, 1, 2, 3, 4, 5, 6, 7, 8, 13, 14, 15, 16];

/* -------------------- ATTACH POINT NAMES (matches @getattach response order) -------------------- */
// Position 0 is "none" (always 0). Positions 31-38 are HUD points and
// are excluded from the worn list — HUDs are private to the wearer and
// this plugin is operated by non-wearer parties.
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
    "neck", "root"
];

// HUD positions skipped when building the worn list.
list HUD_IDX = [31, 32, 33, 34, 35, 36, 37, 38];

/* -------------------- STATE -------------------- */
key     CurrentUser    = NULL_KEY;
integer UserAcl        = 0;
list    gPolicyButtons = [];
string  SessionId      = "";

// Query state machine for the RLV roundtrip chain:
//   1 = waiting for @getoutfit response
//   2 = waiting for @getstatusall:remoutfit response
//   3 = waiting for @getstatusall:remattach response
//   0 = idle (results assembled, category menu rendered)
//
// Note: @getattach (the bit-string attach query) is GONE — replaced by
// llGetAttachedList(llGetOwner()) which is synchronous, faster, and
// also yields real attached-object item names (not just slot names).
integer QState = 0;

string  RawOutfit          = "";
integer GlobalOutfitLocked = FALSE;
integer GlobalAttachLocked = FALSE;
list    LockedLayers       = [];
list    LockedAttach       = [];

// Per-category worn-item tables built after the RLV queries complete.
//   WornLayers : stride 1, [layer_name]                — from @getoutfit.
//   WornAttach : stride 2, [point_name, item_name]     — from llGetAttachedList.
// Locked entries are filtered out at build time so the pickers never
// display them.
list    WornLayers   = [];
list    WornAttach   = [];

// "" = nothing selected; "L" = Layers picker active; "A" = Attachments
// picker active. Set when the user picks a category, cleared on Back to
// the category menu, on session cleanup, and on a fresh begin_query.
string  CurrentCategory = "";

integer PickPage    = 0;
integer LastMaxPage = 0;
integer PageSize    = 9;

// Post-strip lock discovery. apply_pick stashes the just-attempted
// item id ("L:<name>" or "A:<name>") in AttemptedItem; after the
// re-query lands, verify_attempted_strip checks whether the item is
// still worn. If yes, the strip silently failed (locked by some
// mechanism we couldn't pre-detect — typically a parent-folder
// @detachallthis like .base) and the item id is appended to
// DiscoveredLocked, which build_worn_list then filters. The list is
// session-scoped and cleared by cleanup_session.
string  AttemptedItem    = "";
list    DiscoveredLocked = [];

integer RlvListenHandle = 0;

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
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

/* -------------------- LIFECYCLE -------------------- */

write_plugin_reg(string label) {
    string k = "plugin.reg." + PLUGIN_CONTEXT;
    string v = llList2Json(JSON_OBJECT, [
        "label",  label,
        "script", llGetScriptName()
    ]);
    if (llLinksetDataRead(k) == v) return;
    llLinksetDataWrite(k, v);
}

register_self() {
    // Open policy: every ACL level sees Strip. The wearer's core
    // attachments are protected by the @detachallthis:.base claim
    // applied below, so wearer access here only exposes strippable
    // (non-.base) items — they cannot strip their core kit even
    // though the menu is reachable.
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

    // Claim @detachallthis:<BASE_FOLDER> through kmod_rlv so items
    // worn from #RLV/.outfits/.base are non-strippable from any source.
    // claim_add in kmod_rlv is idempotent — re-applying on every
    // state_entry / kernel.register.refresh is safe and ensures the
    // lock survives any kmod_rlv reset (claims clear on factory reset;
    // we re-claim here on our own restart).
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",     "rlv.apply",
        "consumer", RLV_CONSUMER,
        "behav",    "detachallthis:" + BASE_FOLDER
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

    SessionId           = "";
    CurrentUser         = NULL_KEY;
    UserAcl             = 0;
    gPolicyButtons      = [];
    QState              = 0;
    RawOutfit           = "";
    GlobalOutfitLocked  = FALSE;
    GlobalAttachLocked  = FALSE;
    LockedLayers        = [];
    LockedAttach        = [];
    WornLayers          = [];
    WornAttach          = [];
    CurrentCategory     = "";
    PickPage            = 0;
    LastMaxPage         = 0;
    AttemptedItem       = "";
    DiscoveredLocked    = [];
}

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user",    (string)CurrentUser
    ]), NULL_KEY);
    cleanup_session();
}

/* -------------------- RLV -------------------- */

rlv_force(string command) {
    logd("SEND rlv.force command=\"" + command + "\"");
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "rlv.force",
        "command", command
    ]), NULL_KEY);
}

start_listen_if_needed() {
    if (RlvListenHandle == 0) {
        RlvListenHandle = llListen(RLV_CHAN, "", llGetOwner(), "");
        logd("LISTEN opened on RLV_CHAN=" + (string)RLV_CHAN
            + " filter=llGetOwner()=" + (string)llGetOwner()
            + " handle=" + (string)RlvListenHandle);
    }
}

// Kick off the three-step RLV query chain at QState=1. Attachments are
// enumerated synchronously via llGetAttachedList after QState 3 lands,
// so they don't burn an RLV roundtrip. Called at session start and
// after every successful strip (to refresh the data).
begin_query() {
    RawOutfit          = "";
    GlobalOutfitLocked = FALSE;
    GlobalAttachLocked = FALSE;
    LockedLayers       = [];
    LockedAttach       = [];
    WornLayers         = [];
    WornAttach         = [];

    QState = 1;
    start_listen_if_needed();
    llSetTimerEvent(RLV_TIMEOUT);
    rlv_force("@getoutfit=" + (string)RLV_CHAN);
}

advance_query() {
    llSetTimerEvent(RLV_TIMEOUT);
    if (QState == 2) {
        rlv_force("@getstatusall:remoutfit=" + (string)RLV_CHAN);
        return;
    }
    if (QState == 3) {
        rlv_force("@getstatusall:remattach=" + (string)RLV_CHAN);
    }
}

// Parse "/remoutfit:shirt/remoutfit" style responses. A bare "remoutfit"
// (no ":part") means everything is locked at the category level; the
// caller signals this by inspecting the returned head-marker "".
list parse_status(string raw, string key_name) {
    list out = [];
    if (raw == "") return out;
    list parts = llParseString2List(raw, ["/"], []);
    integer n = llGetListLength(parts);
    integer i = 0;
    string prefix = key_name + ":";
    integer global_seen = FALSE;
    while (i < n) {
        string p = llStringTrim(llList2String(parts, i), STRING_TRIM);
        if (p == key_name) {
            global_seen = TRUE;
        }
        else if (llSubStringIndex(p, prefix) == 0) {
            out += [llGetSubString(p, llStringLength(prefix), -1)];
        }
        i += 1;
    }
    if (global_seen) out = [""] + out;
    return out;
}

// Build the per-category worn lists, filtered by all known lock sources:
//   - GlobalOutfitLocked / GlobalAttachLocked (bare @remoutfit / @remattach=n)
//   - LockedLayers / LockedAttach            (specific @remoutfit:<part>=n / @remattach:<point>=n)
//   - DiscoveredLocked                       (parent-folder @detachallthis, learned post-strip)
//
// Layers are derived from the RLV @getoutfit bit string at canonical
// LAYER_NAMES offsets. The build uses list-doubling pre-allocation +
// llListReplaceList per fill to stay O(N log N) instead of the O(N²)
// `+=` pattern the project's analyzer flags (matches plugin_folders
// rev 26's idiom).
build_worn_layers() {
    integer max_layers = llGetListLength(STRIPPABLE_LAYER_IDX);

    WornLayers = [];
    if (max_layers > 0) {
        list buf = [""];
        while (llGetListLength(buf) < max_layers) buf = buf + buf;
        WornLayers = llList2List(buf, 0, max_layers - 1);
    }

    integer filled = 0;
    string  layer_name;
    integer skip_flag;

    integer layer_count = llStringLength(RawOutfit);
    integer i = 0;
    while (i < max_layers) {
        integer layer_idx = llList2Integer(STRIPPABLE_LAYER_IDX, i);
        if (layer_idx < layer_count) {
            if (llGetSubString(RawOutfit, layer_idx, layer_idx) == "1") {
                layer_name = llList2String(LAYER_NAMES, layer_idx);
                skip_flag = FALSE;
                if (GlobalOutfitLocked) skip_flag = TRUE;
                if (!skip_flag) {
                    if (llListFindList(LockedLayers, [layer_name]) != -1) skip_flag = TRUE;
                }
                if (!skip_flag) {
                    if (llListFindList(DiscoveredLocked, ["L:" + layer_name]) != -1) skip_flag = TRUE;
                }
                if (!skip_flag) {
                    WornLayers = llListReplaceList(WornLayers, [layer_name], filled, filled);
                    filled += 1;
                }
            }
        }
        i += 1;
    }

    if (filled == 0)              WornLayers = [];
    else if (filled < max_layers) WornLayers = llList2List(WornLayers, 0, filled - 1);
}

// Attachments come from llGetAttachedList(llGetOwner()), which returns
// the UUIDs of every attached object on the wearer. For each we read
// OBJECT_NAME and OBJECT_ATTACHED_POINT, map the integer attach point
// to its canonical RLV slot name (ATTACH_NAMES[pt]), filter out HUDs
// (slots 31-38) and locked slots, and store the [slot_name, item_name]
// pair. Synchronous — no RLV roundtrip needed. Bonus over @getattach:
// we get real item names for the picker labels.
build_worn_attach() {
    list attached = llGetAttachedList(llGetOwner());
    integer max_n = llGetListLength(attached);
    integer cap = max_n * 2;

    WornAttach = [];
    if (cap > 0) {
        list buf = [""];
        while (llGetListLength(buf) < cap) buf = buf + buf;
        WornAttach = llList2List(buf, 0, cap - 1);
    }

    integer filled = 0;
    integer attach_names_n = llGetListLength(ATTACH_NAMES);
    integer i = 0;
    while (i < max_n) {
        key obj_key = llList2Key(attached, i);
        list details = llGetObjectDetails(obj_key, [OBJECT_NAME, OBJECT_ATTACHED_POINT]);
        if (llGetListLength(details) >= 2) {
            string  item_name = llList2String(details, 0);
            integer attach_pt = llList2Integer(details, 1);
            if (attach_pt > 0
                && attach_pt < attach_names_n
                && llListFindList(HUD_IDX, [attach_pt]) == -1) {
                string slot_name = llList2String(ATTACH_NAMES, attach_pt);
                if (slot_name != "") {
                    integer skip_flag = FALSE;
                    if (GlobalAttachLocked) skip_flag = TRUE;
                    if (!skip_flag) {
                        if (llListFindList(LockedAttach, [slot_name]) != -1) skip_flag = TRUE;
                    }
                    if (!skip_flag) {
                        if (llListFindList(DiscoveredLocked, ["A:" + slot_name]) != -1) skip_flag = TRUE;
                    }
                    if (!skip_flag) {
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

// True if the named clothing layer is still occupied per the latest
// @getoutfit response. Used by verify_attempted_strip.
integer is_layer_still_worn(string layer_name) {
    integer layer_idx = llListFindList(LAYER_NAMES, [layer_name]);
    if (layer_idx == -1) return FALSE;
    if (layer_idx >= llStringLength(RawOutfit)) return FALSE;
    return (llGetSubString(RawOutfit, layer_idx, layer_idx) == "1");
}

// True if the named attachment slot is still occupied per a fresh
// llGetAttachedList probe. The attachment side no longer relies on
// the @getattach bit string (we dropped that query), so this is the
// canonical check.
integer is_attach_slot_worn(string slot_name) {
    list attached = llGetAttachedList(llGetOwner());
    integer attach_names_n = llGetListLength(ATTACH_NAMES);
    integer n = llGetListLength(attached);
    integer i = 0;
    while (i < n) {
        list det = llGetObjectDetails(llList2Key(attached, i), [OBJECT_ATTACHED_POINT]);
        if (llGetListLength(det) >= 1) {
            integer pt = llList2Integer(det, 0);
            if (pt > 0 && pt < attach_names_n) {
                if (llList2String(ATTACH_NAMES, pt) == slot_name) return TRUE;
            }
        }
        i += 1;
    }
    return FALSE;
}

// After a strip attempt, re-queries land here before the builders run.
// If the just-attempted item is still worn, the strip silently failed
// (RLV blocked it, almost certainly via a parent-folder @detachallthis)
// — record the slot/layer so subsequent renders omit it.
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

// Top-level category chooser. Shown when the RLV query completes from a
// fresh menu entry (CurrentCategory == ""). User picks Layers or
// Attachments to drill into a per-category picker; Back returns to the
// root menu. Three-button layout — no nav prefix, no padding.
show_category_menu() {
    SessionId       = generate_session_id();
    CurrentCategory = "";
    PickPage        = 0;
    LastMaxPage     = 0;

    integer n_layers = llGetListLength(WornLayers);
    integer n_attach = llGetListLength(WornAttach) / 2;

    string body = "Strip menu\n\n";
    body += "Layers:      " + (string)n_layers + " strippable\n";
    body += "Attachments: " + (string)n_attach + " strippable\n\n";
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

// Paginated layer picker. Body lists "1. shirt / 2. pants / ..."; buttons
// are plain numbers 1-9 placed via the project's bottom-nav top-to-bottom
// L-R convention. Back returns to the category menu.
show_layer_picker(integer page) {
    integer total = llGetListLength(WornLayers);
    SessionId       = generate_session_id();
    CurrentCategory = "L";

    integer max_page;
    if (total == 0) max_page = 0;
    else            max_page = (total - 1) / PageSize;
    if (page < 0)        page = 0;
    if (page > max_page) page = max_page;
    PickPage    = page;
    LastMaxPage = max_page;

    integer start_idx = page * PageSize;
    integer end_idx   = start_idx + PageSize;
    if (end_idx > total) end_idx = total;
    integer count = end_idx - start_idx;

    string body = "Strip — Layers\n";
    if (total == 0) {
        body += "\nNothing to strip.";
    }
    else {
        body += "Page " + (string)(page + 1) + " of " + (string)(max_page + 1) + "\n\n";
        integer k = 0;
        while (k < count) {
            body += (string)(k + 1) + ". " + llList2String(WornLayers, start_idx + k) + "\n";
            k += 1;
        }
    }

    list button_data = [
        btn("<<",   "prev"),
        btn(">>",   "next"),
        btn("Back", "back")
    ];

    integer pad_i;
    for (pad_i = 0; pad_i < count; pad_i += 1) button_data += [btn(" ", " ")];

    integer total_buttons = 3 + count;
    list target_slots = [];
    if (total_buttons > 9)  target_slots += [9];
    if (total_buttons > 10) target_slots += [10];
    if (total_buttons > 11) target_slots += [11];
    if (total_buttons > 6)  target_slots += [6];
    if (total_buttons > 7)  target_slots += [7];
    if (total_buttons > 8)  target_slots += [8];
    if (total_buttons > 3)  target_slots += [3];
    if (total_buttons > 4)  target_slots += [4];
    if (total_buttons > 5)  target_slots += [5];

    integer ci = 0;
    while (ci < count) {
        integer slot     = llList2Integer(target_slots, ci);
        integer item_idx = start_idx + ci;
        button_data = llListReplaceList(
            button_data,
            [btn((string)(ci + 1), "pick:" + (string)item_idx)],
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

// Paginated attachment picker. Body lists "1. <item_name> @<slot> / ..."
// — real attached-object names from llGetAttachedList, with slot for
// disambiguation (e.g. cuffs on left vs right hand). Buttons are
// plain numbers; Back returns to the category menu.
show_attach_picker(integer page) {
    integer total = llGetListLength(WornAttach) / 2;
    SessionId       = generate_session_id();
    CurrentCategory = "A";

    integer max_page;
    if (total == 0) max_page = 0;
    else            max_page = (total - 1) / PageSize;
    if (page < 0)        page = 0;
    if (page > max_page) page = max_page;
    PickPage    = page;
    LastMaxPage = max_page;

    integer start_idx = page * PageSize;
    integer end_idx   = start_idx + PageSize;
    if (end_idx > total) end_idx = total;
    integer count = end_idx - start_idx;

    string body = "Strip — Attachments\n";
    if (total == 0) {
        body += "\nNothing to strip.";
    }
    else {
        body += "Page " + (string)(page + 1) + " of " + (string)(max_page + 1) + "\n\n";
        integer k = 0;
        while (k < count) {
            integer item_idx = start_idx + k;
            string slot = llList2String(WornAttach, item_idx * 2);
            string name = llList2String(WornAttach, item_idx * 2 + 1);
            body += (string)(k + 1) + ". " + name + " @" + slot + "\n";
            k += 1;
        }
    }

    list button_data = [
        btn("<<",   "prev"),
        btn(">>",   "next"),
        btn("Back", "back")
    ];

    integer pad_i;
    for (pad_i = 0; pad_i < count; pad_i += 1) button_data += [btn(" ", " ")];

    integer total_buttons = 3 + count;
    list target_slots = [];
    if (total_buttons > 9)  target_slots += [9];
    if (total_buttons > 10) target_slots += [10];
    if (total_buttons > 11) target_slots += [11];
    if (total_buttons > 6)  target_slots += [6];
    if (total_buttons > 7)  target_slots += [7];
    if (total_buttons > 8)  target_slots += [8];
    if (total_buttons > 3)  target_slots += [3];
    if (total_buttons > 4)  target_slots += [4];
    if (total_buttons > 5)  target_slots += [5];

    integer ci = 0;
    while (ci < count) {
        integer slot     = llList2Integer(target_slots, ci);
        integer item_idx = start_idx + ci;
        button_data = llListReplaceList(
            button_data,
            [btn((string)(ci + 1), "pick:" + (string)item_idx)],
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

// Strip the item at item_idx in the currently-active category.
// CurrentCategory must be "L" (layers) or "A" (attachments) before
// this is called — set by show_layer_picker / show_attach_picker.
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
    else {
        return;
    }

    // Re-query so the picker reflects what RLV actually removed.
    // CurrentCategory is preserved across begin_query so the post-
    // requery render goes back to the same picker the user clicked from.
    begin_query();
}

/* -------------------- DIALOG HANDLER -------------------- */

// Re-show the picker matching the current category. Used by paginate
// and post-strip return paths so we don't repeat the if-ladder.
show_current_picker(integer page) {
    if (CurrentCategory == "L")      show_layer_picker(page);
    else if (CurrentCategory == "A") show_attach_picker(page);
    else                              show_category_menu();
}

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

    key response_user = (key)llJsonGetValue(msg, ["user"]);
    if (response_user != CurrentUser) return;

    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";

    // Category-menu branch: CurrentCategory == "" means we just rendered
    // the Layers/Attachments chooser. Layers/attach drill into the
    // corresponding picker; Back exits to the root menu.
    if (CurrentCategory == "") {
        if (ctx == "layers") {
            show_layer_picker(0);
            return;
        }
        if (ctx == "attach") {
            show_attach_picker(0);
            return;
        }
        if (ctx == "back") {
            return_to_root();
        }
        return;
    }

    // Picker branch: CurrentCategory == "L" or "A". Back returns to the
    // category menu (one level up, not to root); paginate stays in the
    // current picker; pick:<n> dispatches to apply_pick.
    if (ctx == "back") {
        show_category_menu();
        return;
    }
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
        integer idx = (integer)llGetSubString(ctx, 5, -1);
        apply_pick(idx);
    }
}

handle_dialog_timeout(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
    cleanup_session();
}

/* -------------------- RLV RESPONSE HANDLER -------------------- */

handle_rlv_response(string message) {
    logd("HANDLE QState=" + (string)QState + " msg_len=" + (string)llStringLength(message)
        + " msg=\"" + message + "\"");
    if (CurrentUser == NULL_KEY) {
        logd("HANDLE drop: CurrentUser==NULL_KEY");
        return;
    }

    if (QState == 1) {
        // @getoutfit response — raw 0/1 bit string per clothing layer.
        RawOutfit = message;
        QState = 2;
        advance_query();
        return;
    }
    if (QState == 2) {
        // @getstatusall:remoutfit response — layer locks.
        list parsed_outfit = parse_status(message, "remoutfit");
        if (llGetListLength(parsed_outfit) > 0) {
            if (llList2String(parsed_outfit, 0) == "") {
                GlobalOutfitLocked = TRUE;
                parsed_outfit = llDeleteSubList(parsed_outfit, 0, 0);
            }
        }
        LockedLayers = parsed_outfit;
        QState = 3;
        advance_query();
        return;
    }
    if (QState == 3) {
        // @getstatusall:remattach response — attach-point locks. Last
        // RLV roundtrip in the chain; build worn lists synchronously
        // and route to the appropriate view.
        list parsed_attach = parse_status(message, "remattach");
        if (llGetListLength(parsed_attach) > 0) {
            if (llList2String(parsed_attach, 0) == "") {
                GlobalAttachLocked = TRUE;
                parsed_attach = llDeleteSubList(parsed_attach, 0, 0);
            }
        }
        LockedAttach = parsed_attach;
        QState = 0;
        stop_rlv_listen();
        verify_attempted_strip();
        build_worn_layers();
        build_worn_attach();
        // After a strip attempt we return to the same picker the user
        // tapped from (CurrentCategory preserved). On a fresh menu
        // entry CurrentCategory is "" and we show the category chooser.
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
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }

    timer() {
        // RLV query timed out — viewer is not RLV-enabled or not responding.
        logd("TIMEOUT QState=" + (string)QState
            + " RLV_CHAN=" + (string)RLV_CHAN
            + " RlvListenHandle=" + (string)RlvListenHandle);
        stop_rlv_listen();
        if (CurrentUser != NULL_KEY) {
            llRegionSayTo(CurrentUser, 0, "RLV not responding. Is RLV mode enabled?");
            return_to_root();
        }
    }

    listen(integer channel, string name, key id, string message) {
        if (channel == RLV_CHAN) {
            // Pre-filter log: prints EVERY chat on RLV_CHAN regardless of
            // sender, so we can see (a) whether anything is coming back at
            // all, and (b) whether the sender UUID differs from llGetOwner.
            logd("LISTEN chan=" + (string)channel
                + " id=" + (string)id
                + " name=\"" + name + "\""
                + " owner=" + (string)llGetOwner()
                + " filter_match=" + (string)(id == llGetOwner())
                + " msg=\"" + message + "\"");
            if (id == llGetOwner()) {
                handle_rlv_response(message);
            }
        }
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
                llLinksetDataDelete("plugin.reg." + PLUGIN_CONTEXT);
                llLinksetDataDelete("acl.policycontext:" + PLUGIN_CONTEXT);
                llResetScript();
            }
        }
        else if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                string ctx = llJsonGetValue(msg, ["context"]);
                if (ctx != PLUGIN_CONTEXT) return;
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
                // Fresh menu entry: drop any drilled-in category from a
                // previous session so the RLV completion lands on the
                // category chooser, not whichever picker was last open.
                CurrentCategory = "";
                PickPage        = 0;
                llRegionSayTo(CurrentUser, 0, "Reading worn items...");
                begin_query();
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

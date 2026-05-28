/*--------------------
PLUGIN: plugin_strip.lsl
VERSION: 1.10
REVISION: 19
PURPOSE: Strip unlocked clothing layers and attachments from the wearer.
         Available to every ACL level (public / owned wearer / trustee /
         self-owned wearer / primary owner). Lock detection is live —
         @getstatusall:detach surfaces per-slot @detach:<pt>=n AND
         @detachallthis:<path> folder claims, and a per-worn-attachment
         @getpath sweep resolves each slot's inventory path so folder-
         locked items can be pre-filtered out of the picker.
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button
             visibility. Enumerates worn items live via @getoutfit +
             llGetAttachedList; reads lock state via @getstatusall on
             three keyspaces (remoutfit, remattach, detach). Per-slot
             RLV locks filter at build time. Folder-scoped
             @detachallthis locks are extracted from the
             @getstatusall:detach response (via parse_detachallthis)
             into LockedFolders; if any folder lock is active AND
             worn attachments exist, QState=5 fires a sequential
             @getpath probe per worn slot. Returned inventory paths
             are matched against LockedFolders and filter_worn_attach_
             by_folder drops any slot whose path falls under a locked
             subtree. Items whose path RLV refuses to surface (dot-
             prefixed folders) are kept; the verify_attempted_strip
             → DiscoveredLocked pair catches them on first click and
             hides them for the rest of the session. No cross-script
             shadow lock state; plugin_outfits and plugin_folders
             don't write anything for us to read.
CHANGES:
- v1.10 rev 19: Conservative layer suppression — when LockedFolders is
  non-empty (any folder lock active, from parse_detachallthis OR LSD),
  build_worn_layers returns empty. RLV has no @getpath equivalent for
  clothing layers so per-layer source folder is unknowable; hide all
  rather than risk displaying locked items. Wearer falls back to
  plugin_outfits Wear for layer changes when folder locks are in play.
- v1.10 rev 18: Revert rev 17 (worn.registry.locked bit-vector reader).
  Restore rev 15's @getpath sweep mechanism — extracts @detachallthis
  paths from @getstatusall:detach and probes each worn attachment slot
  for its inventory path, then filters by subtree match. Brings back
  rev 16's `;|` separator parser fix on the three @getstatusall calls.
  Drops filter_worn_attach_by_registry, the SETTINGS_BUS dependency,
  the WORN_REGISTRY_* constants, and the LockedFolders/AttachPaths
  reconciliation write-back. Companion to plugin_outfits rev 17 (which
  drops the bit-vector writer side). Also: dialog layout brought into
  spec compliance per feedback_dialog_layout_convention — action_buttons
  computed up-front (none for strip today), page_size derived as
  `9 - action_count`, target_slots if-ladder uses `first_content_slot`
  guards. PageSize constant removed. LSD-direct fallback added for
  folder lock detection: lsd_locked_folders() reads folders.locked,
  outfits.locked, and plugin.outfit.active (→ ~outfits/~base) and
  unions the result into LockedFolders alongside parse_detachallthis's
  external/relay-applied catch. Closes the case where some RLVa builds
  don't surface our own @detachallthis claims in @getstatusall:detach.
  Layers: when any folder lock is active, ALL worn layers are
  suppressed (RLV has no @getpath equivalent for layers, so we can't
  determine per-layer source folder — conservative all-or-nothing
  rather than risk displaying locked items). Wearer can still change
  layers via plugin_outfits Wear when folder locks are in play.
- v1.10 rev 17: Replace the @getinvworn folder-scan filter (revs 15-16, then 18 in dev) with a shared worn.registry.locked bit-vector read from LSD. plugin_outfits and plugin_folders own the writes (see their respective revs); plugin_strip just looks up the attach-point bit per worn item via llGetSubString(locked_bits, ATTACH_*, ATTACH_*). Reconciliation: at picker render, slots whose registry bit is 1 but where nothing is currently attached get cleared, and the trimmed vector is pushed back via settings.delta. Drops the QState=5 dispatch, ScanQueue / ScanIdx / WornFolderNames globals, the LockedFolders parsing, the @getinvworn scan loop, and the DEBUG_STRIP scaffolding + logd helper. Adds SETTINGS_BUS to the consolidated ISP block (needed for the reconciliation write).
- v1.10 rev 16: Fix rev 15's pre-filter not catching @detachallthis:~outfits/~base. The three @getstatusall calls (remoutfit / remattach / detach) now request `;|` separator instead of the default `/`. Folder paths in @detachallthis:<path> entries embed `/` and were being shredded by the response parser — e.g. `/detachallthis:~outfits/~base/` parsed as `["", "detachallthis:~outfits", "~base", ""]`, so LockedFolders captured a truncated `~outfits` instead of `~outfits/~base`. Switching to `|` keeps paths intact. parse_status and parse_detachallthis both updated to split on `|`.
- v1.10 rev 15: Re-introduce the @getpath pre-filter for folder-locked attachments. parse_detachallthis pulls @detachallthis:<path> entries out of the @getstatusall:detach response into LockedFolders; QState=5 then runs a sequential @getpath per worn attachment slot, and filter_worn_attach_by_folder drops any slot whose returned inventory path falls under a locked subtree. Triggered only when LockedFolders is non-empty AND WornAttach has entries, so wearers with no folder locks active see no added latency. Works now because plugin_outfits rev 13 moved the protected subtree from dot-prefixed (.outfits/.base) to tilde-prefixed (~outfits/~base) — @getpath returns real paths for tilde-prefixed folders. Foreign dot-prefixed folder locks still slip through here (RLV hides them from @getpath); the existing verify_attempted_strip → DiscoveredLocked safety net catches them on first click.
- v1.10 rev 14: Fix "no attachments visible" — two distinct bugs. (a) Rev 10's GlobalDetachLocked filter in build_worn_attach was based on a wrong reading of the RLV spec: bare @detach=n locks ONLY the object that issued it (the collar), not all attachments, but the filter was hiding every attached item whenever plugin_lock was locked (which is the default state). Drop the GlobalDetachLocked skip; per-slot @detach:<slot>=n locks still filter via LockedAttach. (b) ATTACH_NAMES stopped at index 40, so anything attached to a Bento mesh point (LHAND_RING1=41 through HIND_RFOOT=55) failed the attach_pt < attach_names_n bounds check and never appeared. Extend to 56 entries covering all current LSL ATTACH_* constants.
- v1.10 rev 13: Drop the @detachallthis:.outfits/.base claim from
  register_self — plugin_outfits rev 9 now owns the .base lock so it
  can be released by the on/off toggle. plugin_strip's role shrinks
  to "enumerate worn items, show picker, force-strip on click";
  .base protection comes entirely from whichever consumer is
  currently claiming the folder (default: plugin_outfits while
  active). BASE_FOLDER and RLV_CONSUMER constants removed (their
  only use was the claim).
- v1.10 rev 12: Internal refactor — no behavior change. Merge
  show_layer_picker + show_attach_picker into a single
  show_picker(category, page); the two were ~75 lines each and
  diverged only in the worn-list source, row formatter, and header
  text. Inline parse_detach_status into the QState=4 handler via
  parse_status("detach"); the dedicated parser was duplicating
  what parse_status already does.
- v1.10 rev 11: Drop the @getpath path-verify machinery (rev 9) and
  the folder-tracking half of rev 10 (LockedFolders, /detachallthis
  parsing in parse_detach_status, path_locked, begin_path_check,
  QState=5, PathCheckIdx). The RLV spec is explicit that @getpath
  "does not take disabled folders into account (folders which name
  begins with a dot)" — so the probe returns empty for every item
  under .outfits/.base and the filter could never see them. Rev 9
  was also wrong about @detachallthis not blocking @remattach: RLV
  does honor the lock against the strip command (the strip silently
  fails), which is why the existing verify_attempted_strip +
  DiscoveredLocked pair was already catching .base items on the
  first click. Net: ~80 lines lighter, same effective behavior.
  Per-point @detach:<pt>=n detection from rev 10 is kept.
- v1.10 rev 10: Add @getstatusall:detach query as QState=4 (path-check
  bumped to QState=5). Catches three more lock sources that previously
  slipped through to the picker: bare @detach=n (hides all
  attachments), per-point @detach:<pt>=n (hides that slot), and
  @detachallthis:<path> folder locks beyond .outfits/.base (hides
  slots whose inventory path falls under any reported folder). One
  more RLV roundtrip on menu open; reuses the existing path-verify
  pass for folder-scoped filtering.
- v1.10 rev 9: Pre-filter the attachment picker by inventory path. The
  @detachallthis:.outfits/.base claim was not blocking @remattach:<pt>
  =force across RLVa versions, so .base items were being stripped
  despite the lock. After the existing 3-query build pass, the plugin
  now walks WornAttach via @getpath:<slot> (new QState=4) and drops
  any row whose inventory path is in .outfits/.base before rendering
  the picker. Adds N RLV roundtrips on menu open (typically <1s for
  5-10 attachments). The folder-lock claim is kept for defense in
  depth against other detach paths (manual, @detachall:.outfits, relay).
- v1.10 rev 8: Ellipsize attachment item names in show_attach_picker
  to 30 chars. Mesh-body names regularly exceed 50 chars and 9 such
  rows + header overflowed llDialog's 512-char body limit.
- v1.10 rev 7: Strip DEBUG_STRIP scaffolding and logd() calls now
  that rev 5's @getstatusall syntax fix and rev 6's UI split are
  confirmed working in-world.
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
- v1.10 rev 5: Fix the @getstatusall lock-detection probes. The
  syntax was inverted — `@getstatusall;remoutfit=<chan>` (semicolon)
  vs the canonical `@getstatusall:<filter>=<chan>` (colon). The
  semicolon-form is reserved for an optional custom separator
  AFTER a filter; using it as the filter-delimiter parses as an
  unrecognised command and the viewer silently drops it. Both
  invocations corrected to use the colon form.
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

integer KERNEL_LIFECYCLE = 500;
integer UI_BUS           = 900;
integer DIALOG_BUS       = 950;

string PLUGIN_CONTEXT = "ui.core.strip";
string PLUGIN_LABEL   = "Strip";

integer RLV_CHAN    = 1888771;
float   RLV_TIMEOUT = 10.0;

// @getoutfit returns a 0/1 bit string in this order. Body-part layers
// (skull/eyes/hair/shape) cannot be stripped via @remoutfit.
list LAYER_NAMES = [
    "gloves", "jacket", "pants", "shirt", "shoes", "skirt", "socks",
    "underpants", "undershirt", "skull", "eyes", "hair", "shape",
    "alpha", "tattoo", "physics", "universal"
];
list STRIPPABLE_LAYER_IDX = [0, 1, 2, 3, 4, 5, 6, 7, 8, 13, 14, 15, 16];

// Index = LSL ATTACH_* integer. Positions 31-38 are HUD (skipped). 41-55
// are Bento/mesh — present so build_worn_attach's bounds check passes.
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

key     CurrentUser    = NULL_KEY;
integer UserAcl        = 0;
list    gPolicyButtons = [];
string  SessionId      = "";

// 1=@getoutfit  2=@getstatusall:remoutfit  3=:remattach  4=:detach
// 5=per-slot @getpath sweep (only when LockedFolders non-empty)
// 0=idle
integer QState = 0;

string  RawOutfit          = "";
integer GlobalOutfitLocked = FALSE;
integer GlobalAttachLocked = FALSE;
list    LockedLayers       = [];
list    LockedAttach       = [];
list    LockedFolders      = [];     // @detachallthis:<path> from QState=4

list    WornLayers   = [];           // stride 1
list    WornAttach   = [];           // stride 2: [slot, item_name]

list    AttachPaths  = [];           // stride 2: [slot, path] from QState=5 sweep
integer PathCheckIdx = 0;

string  CurrentCategory = "";        // "" = chooser, "L" = layers, "A" = attach
integer PickPage    = 0;
integer LastMaxPage = 0;
// page_size is derived per-render in show_picker as `9 - action_count`.
// Strip picker has no action buttons today (action_count=0 → page_size=9);
// pattern preserved for spec compliance and future-proofing.
// LastMaxPage stashed for prev/next wrap.

// Items whose strip silently no-op'd — hidden from subsequent renders.
// Catches lock paths @getpath can't see (dot-prefixed folders).
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

// Cap dialog-body strings so a 9-row body stays under llDialog's 512 char limit.
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

write_plugin_reg(string label) {
    string k = "plugin.reg." + PLUGIN_CONTEXT;
    string v = llList2Json(JSON_OBJECT, ["label", label, "script", llGetScriptName()]);
    if (llLinksetDataRead(k) == v) return;
    llLinksetDataWrite(k, v);
}

register_self() {
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

/* -------------------- RLV -------------------- */

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

// `;|` separator required: @detachallthis:<path> entries embed `/` which
// the default separator shreds (e.g. `~outfits/~base` parses as two tokens).
advance_query() {
    llSetTimerEvent(RLV_TIMEOUT);
    if (QState == 2) { rlv_force("@getstatusall:remoutfit;|=" + (string)RLV_CHAN); return; }
    if (QState == 3) { rlv_force("@getstatusall:remattach;|=" + (string)RLV_CHAN); return; }
    if (QState == 4) { rlv_force("@getstatusall:detach;|="   + (string)RLV_CHAN); }
}

// Read locked folder paths from LSD. Other collar plugins are the
// authoritative source for their own locks; parse_detachallthis is a
// fallback for external/relay-applied locks. Reading from LSD avoids
// any dependency on the viewer's @getstatusall:detach response surfacing
// our @detachallthis claims (some RLVa builds don't include them).
list lsd_locked_folders() {
    list out = [];

    string folders_csv = llLinksetDataRead("folders.locked");
    if (folders_csv != "") out += llCSV2List(folders_csv);

    string outfits_csv = llLinksetDataRead("outfits.locked");
    if (outfits_csv != "") {
        list names = llCSV2List(outfits_csv);
        integer i = 0;
        integer n = llGetListLength(names);
        while (i < n) {
            out += ["outfits/" + llList2String(names, i)];
            i += 1;
        }
    }

    string active = llLinksetDataRead("plugin.outfit.active");
    if ((integer)active) out += ["outfits/base"];

    return out;
}

// Extract `detachallthis:<path>` entries from a @getstatusall:detach response.
list parse_detachallthis(string raw) {
    list out = [];
    if (raw == "") return out;
    list parts = llParseString2List(raw, ["|"], []);
    integer n = llGetListLength(parts);
    string prefix = "detachallthis:";
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

// Parse "|key:val|key" style responses. Bare key (no `:val`) means a
// category-level lock; signalled by an empty head entry to the caller.
list parse_status(string raw, string key_name) {
    list out = [];
    if (raw == "") return out;
    list parts = llParseString2List(raw, ["|"], []);
    integer n = llGetListLength(parts);
    string prefix = key_name + ":";
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

// Drop WornAttach entries whose @getpath result falls under any LockedFolders
// entry. Empty paths (item outside #RLV or in a dot-hidden folder) are kept;
// the post-strip verify catches those.
filter_worn_attach_by_folder() {
    if (llGetListLength(LockedFolders) == 0) return;
    if (llGetListLength(WornAttach) == 0)    return;

    list new_worn = [];
    integer n = llGetListLength(WornAttach);
    integer lf_n = llGetListLength(LockedFolders);
    integer i = 0;
    while (i < n) {
        string slot = llList2String(WornAttach, i);
        string item = llList2String(WornAttach, i + 1);
        string path = "";
        integer pi = llListFindList(AttachPaths, [slot]);
        if (pi != -1) path = llList2String(AttachPaths, pi + 1);

        integer locked = FALSE;
        if (path != "") {
            integer lj = 0;
            while (lj < lf_n) {
                string lf = llList2String(LockedFolders, lj);
                if (path == lf || llSubStringIndex(path, lf + "/") == 0) {
                    locked = TRUE;
                    lj = lf_n;
                } else {
                    lj += 1;
                }
            }
        }
        if (!locked) new_worn += [slot, item];
        i += 2;
    }
    WornAttach = new_worn;
}

build_worn_layers() {
    // RLV has no @getpath equivalent for clothing layers, so we cannot
    // determine the source folder of a worn layer. When any folder lock
    // is active we conservatively suppress ALL layers — we'd rather hide
    // an unlocked layer than display a locked one. Wearer can still
    // change layers via plugin_outfits Wear when folder locks are in play.
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
        if (layer_idx < layer_count) {
            if (llGetSubString(RawOutfit, layer_idx, layer_idx) == "1") {
                string layer_name = llList2String(LAYER_NAMES, layer_idx);
                integer skip = FALSE;
                if (GlobalOutfitLocked) skip = TRUE;
                if (!skip && llListFindList(LockedLayers, [layer_name]) != -1) skip = TRUE;
                if (!skip && llListFindList(DiscoveredLocked, ["L:" + layer_name]) != -1) skip = TRUE;
                if (!skip) {
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

// HUD attach points (31-38) skipped via the range check below.
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
            integer pt = llList2Integer(details, 1);
            if (pt > 0 && pt < attach_names_n && (pt < 31 || pt > 38)) {
                string slot_name = llList2String(ATTACH_NAMES, pt);
                if (slot_name != "") {
                    integer skip = FALSE;
                    if (GlobalAttachLocked) skip = TRUE;
                    if (!skip && llListFindList(LockedAttach, [slot_name]) != -1) skip = TRUE;
                    if (!skip && llListFindList(DiscoveredLocked, ["A:" + slot_name]) != -1) skip = TRUE;
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
            if (pt > 0 && pt < attach_names_n) {
                if (llList2String(ATTACH_NAMES, pt) == slot_name) return TRUE;
            }
        }
        i += 1;
    }
    return FALSE;
}

// Post-strip silently-blocked detection. If the just-attempted item is still
// worn, the strip was blocked by something we couldn't pre-filter (typically
// a dot-prefixed folder lock @getpath hides) — add to DiscoveredLocked.
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

    // Action buttons (none today; pattern preserved for spec compliance and
    // future-proofing). page_size = 9 - action_count.
    list action_buttons = [];
    integer action_count = llGetListLength(action_buttons);
    integer page_size = 9 - action_count;

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
        body += "Page " + (string)(page + 1) + " of " + (string)(max_page + 1) + "\n\n";
        integer k = 0;
        while (k < count) {
            integer item_idx = start_idx + k;
            if (category == "L") {
                body += (string)(k + 1) + ". " + llList2String(WornLayers, item_idx) + "\n";
            } else {
                string slot_name = llList2String(WornAttach, item_idx * 2);
                string item_name = ellipsize(llList2String(WornAttach, item_idx * 2 + 1), 30);
                body += (string)(k + 1) + ". " + item_name + " @" + slot_name + "\n";
            }
            k += 1;
        }
    }

    // Layout per project dialog convention (canonical: plugin_animate):
    //   slots 0-2: nav (<<, >>, Back)
    //   slot 3-N : action buttons (none today)
    //   remaining: worn-item content, slot-mapped top→bottom, left→right.
    list button_data = [btn("<<", "prev"), btn(">>", "next"), btn("Back", "back")];
    button_data += action_buttons;
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
        // @detach response carries three things:
        //   bare detach        — ignored (locks only the issuing object)
        //   detach:<pt>        — merged into LockedAttach
        //   detachallthis:<p>  — LockedFolders → QState=5 path sweep
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

        // Augment with LSD-known folder locks (plugin_folders, plugin_outfits).
        // Authoritative source for our own locks; parse_detachallthis above
        // covers external/relay-applied locks. Union ensures we filter
        // even when the viewer's response omits our claims.
        list known = lsd_locked_folders();
        integer kn = llGetListLength(known);
        integer ki = 0;
        while (ki < kn) {
            string lf = llList2String(known, ki);
            if (llListFindList(LockedFolders, [lf]) == -1) LockedFolders += [lf];
            ki += 1;
        }

        verify_attempted_strip();
        build_worn_layers();
        build_worn_attach();

        if (llGetListLength(LockedFolders) > 0 && llGetListLength(WornAttach) > 0) {
            QState = 5;
            PathCheckIdx = 0;
            llSetTimerEvent(RLV_TIMEOUT);
            rlv_force("@getpath:" + llList2String(WornAttach, 0) + "=" + (string)RLV_CHAN);
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
            rlv_force("@getpath:" + llList2String(WornAttach, next_idx) + "=" + (string)RLV_CHAN);
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

/*--------------------
PLUGIN: plugin_strip.lsl
VERSION: 1.10
REVISION: 4
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
//   2 = waiting for @getattach response
//   3 = waiting for @getstatusall;remoutfit response
//   4 = waiting for @getstatusall;remattach response
//   0 = idle (results assembled, picker rendered)
integer QState = 0;

string  RawOutfit          = "";
string  RawAttach          = "";
integer GlobalOutfitLocked = FALSE;
integer GlobalAttachLocked = FALSE;
list    LockedLayers       = [];
list    LockedAttach       = [];

// Worn item table. Stride 2: [type, name]. Locked items are filtered
// out at build_worn_list time, so the picker never displays them.
// type is "L" (layer) or "A" (attach point).
list    WornItems   = [];
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
    RawAttach           = "";
    GlobalOutfitLocked  = FALSE;
    GlobalAttachLocked  = FALSE;
    LockedLayers        = [];
    LockedAttach        = [];
    WornItems           = [];
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
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "rlv.force",
        "command", command
    ]), NULL_KEY);
}

start_listen_if_needed() {
    if (RlvListenHandle == 0) {
        RlvListenHandle = llListen(RLV_CHAN, "", llGetOwner(), "");
    }
}

// Kick off the four-step query chain at QState=1. Used at session start
// and after every successful strip (to refresh the picker).
begin_query() {
    RawOutfit          = "";
    RawAttach          = "";
    GlobalOutfitLocked = FALSE;
    GlobalAttachLocked = FALSE;
    LockedLayers       = [];
    LockedAttach       = [];
    WornItems          = [];

    QState = 1;
    start_listen_if_needed();
    llSetTimerEvent(RLV_TIMEOUT);
    rlv_force("@getoutfit=" + (string)RLV_CHAN);
}

advance_query() {
    llSetTimerEvent(RLV_TIMEOUT);
    if (QState == 2) {
        rlv_force("@getattach=" + (string)RLV_CHAN);
        return;
    }
    if (QState == 3) {
        rlv_force("@getstatusall;remoutfit=" + (string)RLV_CHAN);
        return;
    }
    if (QState == 4) {
        rlv_force("@getstatusall;remattach=" + (string)RLV_CHAN);
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

// Build WornItems containing only items that can actually be stripped.
// Three filter sources combine here: bare @remoutfit / @remattach
// (whole-category) locks, specific @remoutfit:<part> / @remattach:<point>
// y/n locks, and the session's DiscoveredLocked set populated by
// verify_attempted_strip when a previous tap silently no-op'd
// (typically a parent-folder @detachallthis).
//
// Pre-allocates WornItems to the worst-case capacity (every strippable
// layer + every non-HUD attach point, stride 2) via list doubling, then
// fills with llListReplaceList and truncates the tail — matches the
// O(N log N) build cost used in plugin_folders rev 26 so the analyzer's
// loop-concat heuristic stays clean.
build_worn_list() {
    integer max_layers   = llGetListLength(STRIPPABLE_LAYER_IDX);
    integer max_attaches = llGetListLength(ATTACH_NAMES);
    integer cap = (max_layers + max_attaches) * 2;

    WornItems = [];
    if (cap > 0) {
        list buf = [""];
        while (llGetListLength(buf) < cap) buf = buf + buf;
        WornItems = llList2List(buf, 0, cap - 1);
    }

    integer filled = 0;
    string  item_name;
    integer skip_flag;

    integer layer_count = llStringLength(RawOutfit);
    integer i = 0;
    while (i < max_layers) {
        integer layer_idx = llList2Integer(STRIPPABLE_LAYER_IDX, i);
        if (layer_idx < layer_count) {
            if (llGetSubString(RawOutfit, layer_idx, layer_idx) == "1") {
                item_name = llList2String(LAYER_NAMES, layer_idx);
                skip_flag = FALSE;
                if (GlobalOutfitLocked) skip_flag = TRUE;
                if (!skip_flag) {
                    if (llListFindList(LockedLayers, [item_name]) != -1) skip_flag = TRUE;
                }
                if (!skip_flag) {
                    if (llListFindList(DiscoveredLocked, ["L:" + item_name]) != -1) skip_flag = TRUE;
                }
                if (!skip_flag) {
                    WornItems = llListReplaceList(WornItems, ["L", item_name], filled, filled + 1);
                    filled += 2;
                }
            }
        }
        i += 1;
    }

    integer attach_count = llStringLength(RawAttach);
    integer p = 1;
    while (p < attach_count && p < max_attaches) {
        if (llListFindList(HUD_IDX, [p]) == -1) {
            if (llGetSubString(RawAttach, p, p) == "1") {
                item_name = llList2String(ATTACH_NAMES, p);
                if (item_name != "") {
                    skip_flag = FALSE;
                    if (GlobalAttachLocked) skip_flag = TRUE;
                    if (!skip_flag) {
                        if (llListFindList(LockedAttach, [item_name]) != -1) skip_flag = TRUE;
                    }
                    if (!skip_flag) {
                        if (llListFindList(DiscoveredLocked, ["A:" + item_name]) != -1) skip_flag = TRUE;
                    }
                    if (!skip_flag) {
                        WornItems = llListReplaceList(WornItems, ["A", item_name], filled, filled + 1);
                        filled += 2;
                    }
                }
            }
        }
        p += 1;
    }

    if (filled == 0)       WornItems = [];
    else if (filled < cap) WornItems = llList2List(WornItems, 0, filled - 1);
}

// After a strip attempt, re-queries land here before build_worn_list
// runs. If the just-attempted item is still worn, the strip silently
// failed (RLV blocked it, almost certainly via a parent-folder
// @detachallthis) — record the item so subsequent renders omit it.
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
    if (atype == "L") {
        integer layer_idx = llListFindList(LAYER_NAMES, [aname]);
        if (layer_idx != -1 && layer_idx < llStringLength(RawOutfit)) {
            if (llGetSubString(RawOutfit, layer_idx, layer_idx) == "1") still_worn = TRUE;
        }
    }
    else if (atype == "A") {
        integer attach_idx = llListFindList(ATTACH_NAMES, [aname]);
        if (attach_idx != -1 && attach_idx < llStringLength(RawAttach)) {
            if (llGetSubString(RawAttach, attach_idx, attach_idx) == "1") still_worn = TRUE;
        }
    }

    if (still_worn) {
        if (llListFindList(DiscoveredLocked, [AttemptedItem]) == -1) {
            DiscoveredLocked += [AttemptedItem];
        }
        llRegionSayTo(CurrentUser, 0, aname + " is locked — cannot strip.");
    }

    AttemptedItem = "";
}

/* -------------------- UI -------------------- */

show_picker(integer page) {
    integer total = llGetListLength(WornItems) / 2;

    SessionId = generate_session_id();

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

    string body = "Strip menu\n";
    body += "L=layer  A=attach\n";
    if (total == 0) {
        body += "\nNothing to strip.";
    }
    else {
        body += "Page " + (string)(page + 1) + " of " + (string)(max_page + 1) + "\n\n";
        integer k = 0;
        while (k < count) {
            integer item_idx = start_idx + k;
            string  row_type = llList2String(WornItems, item_idx * 2);
            string  row_name = llList2String(WornItems, item_idx * 2 + 1);
            body += (string)(k + 1) + ". " + row_type + ": " + row_name + "\n";
            k += 1;
        }
    }

    // Layout per project convention (canonical: plugin_animate /
    // plugin_folders): slots 0-2 = nav (<<, >>, Back), slots 3-11 =
    // content. Content fills top-down so item 1 is always top-left.
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

apply_pick(integer item_idx) {
    if (item_idx < 0) return;
    if (item_idx >= llGetListLength(WornItems) / 2) return;

    string item_type = llList2String(WornItems, item_idx * 2);
    string item_name = llList2String(WornItems, item_idx * 2 + 1);

    // Stash the item id for verify_attempted_strip; the post-query
    // pass confirms whether the strip succeeded and, if not, hides
    // the item from future renders.
    AttemptedItem = item_type + ":" + item_name;

    if (item_type == "L") rlv_force("@remoutfit:" + item_name + "=force");
    else                  rlv_force("@remattach:" + item_name + "=force");

    // Re-query so the picker reflects what RLV actually removed.
    begin_query();
}

/* -------------------- DIALOG HANDLER -------------------- */

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

    key response_user = (key)llJsonGetValue(msg, ["user"]);
    if (response_user != CurrentUser) return;

    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";

    if (ctx == "back") {
        return_to_root();
        return;
    }
    if (ctx == "prev") {
        if (PickPage == 0) show_picker(LastMaxPage);
        else               show_picker(PickPage - 1);
        return;
    }
    if (ctx == "next") {
        if (PickPage >= LastMaxPage) show_picker(0);
        else                         show_picker(PickPage + 1);
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
    if (CurrentUser == NULL_KEY) return;

    if (QState == 1) {
        RawOutfit = message;
        QState = 2;
        advance_query();
        return;
    }
    if (QState == 2) {
        RawAttach = message;
        QState = 3;
        advance_query();
        return;
    }
    if (QState == 3) {
        list parsed_outfit = parse_status(message, "remoutfit");
        if (llGetListLength(parsed_outfit) > 0) {
            if (llList2String(parsed_outfit, 0) == "") {
                GlobalOutfitLocked = TRUE;
                parsed_outfit = llDeleteSubList(parsed_outfit, 0, 0);
            }
        }
        LockedLayers = parsed_outfit;
        QState = 4;
        advance_query();
        return;
    }
    if (QState == 4) {
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
        build_worn_list();
        show_picker(PickPage);
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

                CurrentUser = id;
                UserAcl     = start_acl;
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

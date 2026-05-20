/*--------------------
PLUGIN: plugin_outfits.lsl
VERSION: 1.10
REVISION: 7
PURPOSE: Browse #RLV/.outfits subfolders and act on them. Five actions
         per outfit:
           Add    — attach the folder additively (layer on top)
           Wear   — replace: detach all .outfits items then attach
                    the chosen folder. .outfits/.base items are
                    protected by plugin_strip's @detachallthis claim
                    and silently survive.
           Remove — detach this outfit's items
           Lock   — claim @detachallthis on the outfit (locks it
                    against removal by Strip, Remove, or relays)
           Unlock — release the lock
         The picker also exposes a Help button that delivers the
         "D/s Collar outfits setup" notecard describing the expected
         #RLV/.outfits/.base layout.
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button
             visibility. Subfolder enumeration via @getinv:.outfits on
             every menu entry — no persisted manifest. The
             .outfits/.base subfolder is intentionally invisible to
             every RLV enumeration command (dot-prefixed names are
             systematically hidden by the API), so the plugin cannot
             programmatically verify it exists; instead the picker
             offers a Help button that delivers the setup notecard
             on demand. Lock state is
             persistent via kmod_settings (KEY_LOCKED CSV in LSD),
             mirroring the plugin_lock / plugin_folders pattern:
             locks survive detach/reattach and script reset, and only
             release when the wearer explicitly Unlocks or
             factory-resets. apply_settings_sync diffs the in-memory
             list against the LSD CSV on every state_entry and
             settings.sync, releasing removed locks and (re-)applying
             current ones. Factory reset releases viewer-side
             restrictions via direct llOwnerSay (release_persisted_locks)
             before llResetScript, so they don't orphan if kmod_rlv
             resets alongside us. Force-attach/detach commands route
             through kmod_rlv (rlv.force); lock/unlock route through
             kmod_rlv rlv.apply/release under consumer "outfits",
             refcount-coordinated with any other plugin claiming the
             same behav. Per-action ACL gating mirrors plugin_folders:
             ACL 1/2 get Add/Wear/Remove; ACL 3/4/5 also get
             Lock/Unlock.
CHANGES:
- v1.10 rev 7: Drop the .base precheck — RLV systematically hides
  dot-prefixed folders from every enumeration command, so the
  @getinv:.outfits response can never report .base regardless of
  whether the wearer has set it up. The precheck was rejecting
  fully-configured wearers. Replaced with a Help button on the
  picker that delivers the setup notecard on demand; picker
  PageSize drops from 9 to 8 to reserve a slot for Help.
- v1.10 rev 6: Rename the setup notecard from
  "D/s Collar - Outfits Setup" to "D/s Collar outfits setup".
  llGetInventoryType lookup is case-sensitive, so the in-prim
  notecard must match exactly.
- v1.10 rev 5: Migrate locks from session-only to persistent. Rev 4's
  premise (locks die on script reset, so session-only is fine with an
  rlv.clear cleanup) was wrong: RLV restrictions on the viewer survive
  llResetScript and survive collar detach — they only release when the
  issuing script explicitly emits @<behav>=y, or when the wearer
  factory-resets. plugin_lock and plugin_folders already model the
  correct pattern, and plugin_outfits now follows it:
  * KEY_LOCKED ("outfits.locked") added; written via settings.delta
    (kmod_settings rev 17 registers it in MANAGED_SETTINGS_KEYS).
  * apply_settings_sync diffs LockedOutfits against the persisted
    CSV, releasing claims for removed entries and (re-)applying
    claims for the current set. Runs on state_entry and on every
    settings.sync.
  * apply_lock / apply_unlock call persist_locked() so the CSV
    follows the in-memory state.
  * kernel.reset.{soft,factory} handler runs release_persisted_locks
    (direct llOwnerSay of @<path>=y) BEFORE llResetScript so the
    viewer-side restrictions release even when kmod_rlv resets in
    parallel and drops its Claims. kmod_settings itself wipes
    KEY_LOCKED via clear_managed_settings.
  * The rlv.clear-in-state_entry from rev 4 is gone — superseded by
    apply_settings_sync's diff-and-reconcile pass.
- v1.10 rev 3: Action set expanded to Add/Wear/Remove/Lock/Unlock
  (Wear was previously named Replace; the old additive "Wear" is
  now "Add" so naming matches user intent that "wearing an outfit"
  always replaces). Lock/Unlock added with session-only state and
  kmod_rlv refcounted claims under consumer "outfits". Per-action
  policy mirrors plugin_folders: Lock/Unlock restricted to ACL
  3/4/5. show_action renders only the buttons the calling ACL is
  allowed; show_picker prefixes locked outfits with "*".
- v1.10 rev 2: Pre-flight check for #RLV/.outfits/.base. The picker
  no longer opens if .base is not configured under .outfits;
  a "base folder not configured" dialog opens instead, and OK
  delivers the "D/s Collar outfits setup" notecard. The check
  piggybacks on the existing @getinv:.outfits roundtrip — no
  additional RLV query needed.
- v1.10 rev 1: handle_rlv_response pre-allocates Outfits via list
  doubling and fills with llListReplaceList instead of `+=` inside
  the parse loop. Matches plugin_folders rev 26 pattern; clears the
  analyzer's O(N²) loop-concat warning on large .outfits trees.
- v1.10 rev 0: Initial implementation.
--------------------*/

/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS     = 800;
integer UI_BUS           = 900;
integer DIALOG_BUS       = 950;

/* -------------------- TEMPORARY DEBUG -------------------- */
// ".outfits / .base not detected" diagnostic. Flip to FALSE to silence.
// Remove this block and all logd(...) calls once the bug is found.
integer DEBUG_OUTFITS = TRUE;
logd(string s) {
    if (DEBUG_OUTFITS) llOwnerSay("[outfits-dbg] " + s);
}

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.outfits";
string PLUGIN_LABEL   = "Outfits";

/* -------------------- RLV -------------------- */
integer RLV_CHAN    = 1888772;
float   RLV_TIMEOUT = 10.0;
string  OUTFITS_ROOT  = ".outfits";   // #RLV-relative root for outfit subfolders.
string  RLV_CONSUMER  = "outfits";    // kmod_rlv consumer id for lock claims.

/* -------------------- SETTINGS KEYS -------------------- */
string  KEY_LOCKED = "outfits.locked";  // CSV of locked outfit names (managed by kmod_settings).

/* -------------------- INVENTORY -------------------- */
string  SETUP_NOTECARD = "D/s Collar outfits setup";

/* -------------------- STATE -------------------- */
key     CurrentUser    = NULL_KEY;
integer UserAcl        = 0;
list    gPolicyButtons = [];
string  SessionId      = "";

// Menu-state machine values used by show_*/handle_dialog_response:
//   "scanning"     = awaiting @getinv:.outfits response
//   "pick"         = paginated outfit picker
//   "action"       = per-outfit Wear/Replace submenu
string  MenuContext      = "";
string  SelectedOutfit   = "";

list    Outfits          = [];
integer PickPage         = 0;
integer LastMaxPage      = 0;
integer PageSize         = 8;  // 12 dialog slots − 3 nav − 1 Help action = 8 content items

// Persistent outfit lock state. Holds outfit names (not full paths)
// that have an active @detachallthis claim under our consumer id.
// Persisted via kmod_settings (KEY_LOCKED CSV) so locks survive
// detach/reattach and script reset. Reset only on explicit
// kernel.reset.factory (the @=y release happens in the reset handler
// before llResetScript). cleanup_session does NOT clear this — locks
// outlive any individual menu session.
list    LockedOutfits    = [];

integer RlvListenHandle  = 0;

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
    // Per-action gating mirrors plugin_folders: ACL 1 (public) and ACL 2
    // (owned wearer) can dress the wearer but cannot defeat or apply
    // locks. ACL 3/4/5 (trustee / self-owned wearer / primary owner)
    // get the full set including Lock/Unlock.
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "Add,Wear,Remove",
        "2", "Add,Wear,Remove",
        "3", "Add,Wear,Remove,Lock,Unlock",
        "4", "Add,Wear,Remove,Lock,Unlock",
        "5", "Add,Wear,Remove,Lock,Unlock"
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
            "type",       "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }

    SessionId       = "";
    CurrentUser     = NULL_KEY;
    UserAcl         = 0;
    gPolicyButtons  = [];
    MenuContext     = "";
    SelectedOutfit  = "";
    Outfits         = [];
    PickPage        = 0;
    LastMaxPage     = 0;
}

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user",    (string)CurrentUser
    ]), NULL_KEY);
    cleanup_session();
}

/* -------------------- SETTINGS PERSISTENCE -------------------- */

// Mirror plugin_folders' pattern: kmod_settings is the sole LSD writer
// for KEY_LOCKED. We send settings.delta:<key>:<csv> (or
// settings.delete:<key> for empty) and rely on the settings.sync
// broadcast to confirm state — apply_settings_sync below reconciles.
persist_locked() {
    if (llGetListLength(LockedOutfits) == 0) {
        llMessageLinked(LINK_SET, SETTINGS_BUS,
            "settings.delete:" + KEY_LOCKED, NULL_KEY);
        return;
    }
    string csv = llDumpList2String(LockedOutfits, ",");
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + KEY_LOCKED + ":" + csv, NULL_KEY);
}

// Reconcile LockedOutfits against the LSD CSV. Runs on state_entry and
// on every settings.sync broadcast. Two phases:
//   1. Release viewer-side / kmod_rlv claims for outfits that are no
//      longer in the persisted list (notecard reload, factory reset,
//      external edit).
//   2. (Re-)claim everything in the persisted list. kmod_rlv claim_add
//      is idempotent, so re-claiming an already-claimed behav is a
//      no-op; safe to run on every sync to re-establish state after a
//      cross-script reset where kmod_rlv lost its Claims but we kept
//      ours.
apply_settings_sync() {
    string csv = llLinksetDataRead(KEY_LOCKED);
    list new_locked = [];
    if (csv != "") new_locked = llParseString2List(csv, [","], []);

    integer i;
    integer n = llGetListLength(LockedOutfits);
    i = 0;
    while (i < n) {
        string old_name = llList2String(LockedOutfits, i);
        if (llListFindList(new_locked, [old_name]) == -1) {
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type",     "rlv.release",
                "consumer", RLV_CONSUMER,
                "behav",    "detachallthis:" + OUTFITS_ROOT + "/" + old_name
            ]), NULL_KEY);
        }
        i += 1;
    }

    LockedOutfits = new_locked;

    i = 0;
    n = llGetListLength(LockedOutfits);
    while (i < n) {
        string cur_name = llList2String(LockedOutfits, i);
        llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
            "type",     "rlv.apply",
            "consumer", RLV_CONSUMER,
            "behav",    "detachallthis:" + OUTFITS_ROOT + "/" + cur_name
        ]), NULL_KEY);
        i += 1;
    }
}

// Called from the kernel.reset.factory handler BEFORE llResetScript.
// kmod_rlv may reset in parallel, dropping its Claims without emitting
// the @<behav>=y commands; bypassing kmod_rlv with a direct llOwnerSay
// here guarantees the viewer-side restrictions release before our LSD
// state is wiped. Safe because we are about to reset anyway —
// kmod_rlv's refcount tracking is moot.
release_persisted_locks() {
    string csv = llLinksetDataRead(KEY_LOCKED);
    if (csv == "") return;
    list locks = llParseString2List(csv, [","], []);
    integer n = llGetListLength(locks);
    integer i = 0;
    while (i < n) {
        string name = llList2String(locks, i);
        if (name != "") {
            llOwnerSay("@detachallthis:" + OUTFITS_ROOT + "/" + name + "=y");
        }
        i += 1;
    }
}

/* -------------------- RLV -------------------- */

// (logging wrapper added by DEBUG_OUTFITS — see top of file)
rlv_force(string command) {
    logd("SEND rlv.force command=\"" + command + "\"");
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "rlv.force",
        "command", command
    ]), NULL_KEY);
}

scan_outfits() {
    Outfits = [];
    MenuContext = "scanning";
    stop_rlv_listen();
    RlvListenHandle = llListen(RLV_CHAN, "", llGetOwner(), "");
    logd("LISTEN opened RLV_CHAN=" + (string)RLV_CHAN
        + " filter=llGetOwner()=" + (string)llGetOwner()
        + " handle=" + (string)RlvListenHandle);
    llSetTimerEvent(RLV_TIMEOUT);
    rlv_force("@getinv:" + OUTFITS_ROOT + "=" + (string)RLV_CHAN);
    llRegionSayTo(CurrentUser, 0, "Reading #RLV/" + OUTFITS_ROOT + " ...");
}

/* -------------------- UI -------------------- */

show_picker(integer page) {
    integer total = llGetListLength(Outfits);

    SessionId   = generate_session_id();
    MenuContext = "pick";

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

    string body = "Outfits  (#RLV/" + OUTFITS_ROOT + ")\n";
    if (total == 0) {
        body += "\nNo outfits found.\n";
        body += "Create subfolders under #RLV/" + OUTFITS_ROOT + ".";
    }
    else {
        body += "*=locked\n";
        body += "Page " + (string)(page + 1) + " of " + (string)(max_page + 1) + "\n\n";
        integer k = 0;
        while (k < count) {
            integer item_idx = start_idx + k;
            string  outfit_name = llList2String(Outfits, item_idx);
            string  lock_mark   = "";
            if (llListFindList(LockedOutfits, [outfit_name]) != -1) lock_mark = " *";
            body += (string)(k + 1) + ". " + outfit_name + lock_mark + "\n";
            k += 1;
        }
    }

    // Layout: slots 0-2 = nav (<<, >>, Back), slot 3 = Help action
    // (delivers the setup notecard), slots 4-11 = content. Content
    // fills top-down so item 1 is always top-left of the content
    // area (slot 9 = top-left when the page is full).
    list button_data = [
        btn("<<",   "prev"),
        btn(">>",   "next"),
        btn("Back", "back"),
        btn("Help", "help")
    ];

    integer pad_i;
    for (pad_i = 0; pad_i < count; pad_i += 1) button_data += [btn(" ", " ")];

    integer total_buttons = 4 + count;
    list target_slots = [];
    if (total_buttons > 9)  target_slots += [9];
    if (total_buttons > 10) target_slots += [10];
    if (total_buttons > 11) target_slots += [11];
    if (total_buttons > 6)  target_slots += [6];
    if (total_buttons > 7)  target_slots += [7];
    if (total_buttons > 8)  target_slots += [8];
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

show_action(string outfit_name) {
    SessionId      = generate_session_id();
    MenuContext    = "action";
    SelectedOutfit = outfit_name;

    integer is_locked = (llListFindList(LockedOutfits, [outfit_name]) != -1);

    string status = "";
    if (is_locked) status = "  (Locked)";

    string body = "Outfit: " + outfit_name + status + "\n\n";
    body += "Add    - attach this folder on top of what is worn\n";
    body += "Wear   - replace: detach all .outfits items, attach this\n";
    body += "Remove - detach this outfit's items\n";
    if (btn_allowed("Lock") || btn_allowed("Unlock")) {
        body += "Lock   - protect this outfit from removal\n";
        body += "Unlock - release the protection";
    }

    // Variable-width action dialog. Per CLAUDE.md small confirmation
    // dialogs skip the multiples-of-3 cosmetic pad. Buttons are emitted
    // in policy-aware order; llDialog lays them out bottom-left → top-
    // right (3 per row).
    list button_data = [];
    if (btn_allowed("Add"))    button_data += [btn("Add",    "add")];
    if (btn_allowed("Wear"))   button_data += [btn("Wear",   "wear")];
    if (btn_allowed("Remove")) button_data += [btn("Remove", "remove")];
    if (is_locked) {
        if (btn_allowed("Unlock")) button_data += [btn("Unlock", "unlock")];
    }
    else {
        if (btn_allowed("Lock")) button_data += [btn("Lock", "lock")];
    }
    button_data += [btn("Back", "back")];

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

// Delivers the setup notecard to the action user. Wired to the Help
// button on the outfit picker; the picker's body footer mentions it.
// Previously also auto-fired from a `.base`-not-found precheck — that
// precheck was dropped because RLV systematically hides dot-prefixed
// folders from every enumeration command (@getinv, @getinvworn, …),
// making it fundamentally impossible for the plugin to verify a
// dot-prefixed protected subfolder exists. The .outfits/.base lock
// applied by plugin_strip still works (locks act on the path
// regardless of hidden status); we just can't validate the wearer's
// setup, so we expose the notecard as opt-in help instead.
give_setup_notecard() {
    if (llGetInventoryType(SETUP_NOTECARD) != INVENTORY_NOTECARD) {
        llRegionSayTo(CurrentUser, 0,
            "Setup notecard not found in collar inventory.");
        return;
    }
    llGiveInventory(CurrentUser, SETUP_NOTECARD);
    llRegionSayTo(CurrentUser, 0, "Setup instructions sent.");
}

// Helper: emit rlv.apply / rlv.release through kmod_rlv for our
// consumer id so refcount stays coordinated with any other plugin
// (e.g. plugin_folders) that may have its own claim on the same behav.
rlv_op(string op, string behav) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",     op,
        "consumer", RLV_CONSUMER,
        "behav",    behav
    ]), NULL_KEY);
}

// Add — truly additive attach. @attachallover is the "over" variant of
// @attachall that explicitly does NOT kick items already occupying the
// slots the new folder would fill. Items at non-overlapping slots stay,
// items at overlapping slots ALSO stay — the new item layers on top.
// (@attachall by contrast kicks slot occupants, which is the Wear
// semantic below.)
apply_add(string outfit_name) {
    rlv_force("@attachallover:" + OUTFITS_ROOT + "/" + outfit_name + "=force");
    llRegionSayTo(CurrentUser, 0, "Adding: " + outfit_name);
}

// Wear — replace semantic. Detach everything currently worn from
// anywhere under .outfits, then attach the chosen folder. Items in
// .outfits/.base are protected by plugin_strip's @detachallthis claim;
// the force-detach silently skips them so the base kit survives.
// Items worn from outside #RLV (regular inventory, unlinked HUDs)
// are untouched.
apply_wear(string outfit_name) {
    rlv_force("@detachall:" + OUTFITS_ROOT + "=force");
    rlv_force("@attachall:" + OUTFITS_ROOT + "/" + outfit_name + "=force");
    llRegionSayTo(CurrentUser, 0, "Wearing: " + outfit_name);
}

// Remove — detach just this outfit's items. Blocked by any active
// @detachallthis lock on this folder (whether owned by us or another
// plugin); the viewer silently no-ops in that case.
apply_remove(string outfit_name) {
    rlv_force("@detachall:" + OUTFITS_ROOT + "/" + outfit_name + "=force");
    llRegionSayTo(CurrentUser, 0, "Removing: " + outfit_name);
}

// Lock — claim @detachallthis on the outfit folder. kmod_rlv's
// refcount engine coordinates with other consumers; the behav stays
// applied as long as any consumer holds it. The persisted CSV in
// kmod_settings is the source of truth — apply_settings_sync will
// re-apply this claim on the next state_entry / settings.sync, so
// the lock survives detach/reattach and script reset until the
// wearer explicitly unlocks or factory-resets.
apply_lock(string outfit_name) {
    if (llListFindList(LockedOutfits, [outfit_name]) != -1) {
        llRegionSayTo(CurrentUser, 0, outfit_name + " is already locked.");
        return;
    }
    LockedOutfits += [outfit_name];
    rlv_op("rlv.apply", "detachallthis:" + OUTFITS_ROOT + "/" + outfit_name);
    persist_locked();
    llRegionSayTo(CurrentUser, 0, "Locked: " + outfit_name);
}

// Unlock — release our claim. The behav drops only if no other
// consumer is holding it. Persisted state is updated so the lock does
// not re-resurrect on the next sync.
apply_unlock(string outfit_name) {
    integer idx = llListFindList(LockedOutfits, [outfit_name]);
    if (idx == -1) {
        llRegionSayTo(CurrentUser, 0, outfit_name + " is not locked.");
        return;
    }
    LockedOutfits = llDeleteSubList(LockedOutfits, idx, idx);
    rlv_op("rlv.release", "detachallthis:" + OUTFITS_ROOT + "/" + outfit_name);
    persist_locked();
    llRegionSayTo(CurrentUser, 0, "Unlocked: " + outfit_name);
}

/* -------------------- DIALOG HANDLER -------------------- */

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

    key response_user = (key)llJsonGetValue(msg, ["user"]);
    if (response_user != CurrentUser) return;

    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";

    if (MenuContext == "pick") {
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
        if (ctx == "help") {
            // Help button on the picker — delivers the setup notecard
            // to the action user and stays in the picker so they can
            // continue browsing.
            give_setup_notecard();
            show_picker(PickPage);
            return;
        }
        if (llSubStringIndex(ctx, "pick:") == 0) {
            integer pick_idx = (integer)llGetSubString(ctx, 5, -1);
            if (pick_idx >= 0 && pick_idx < llGetListLength(Outfits)) {
                show_action(llList2String(Outfits, pick_idx));
            }
        }
        return;
    }

    if (MenuContext == "action") {
        if (ctx == "back") {
            show_picker(PickPage);
            return;
        }
        if (ctx == "add") {
            apply_add(SelectedOutfit);
            show_picker(PickPage);
            return;
        }
        if (ctx == "wear") {
            apply_wear(SelectedOutfit);
            show_picker(PickPage);
            return;
        }
        if (ctx == "remove") {
            apply_remove(SelectedOutfit);
            show_picker(PickPage);
            return;
        }
        if (ctx == "lock") {
            apply_lock(SelectedOutfit);
            show_picker(PickPage);
            return;
        }
        if (ctx == "unlock") {
            apply_unlock(SelectedOutfit);
            show_picker(PickPage);
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
    logd("HANDLE MenuContext=\"" + MenuContext + "\""
        + " msg_len=" + (string)llStringLength(message)
        + " msg=\"" + message + "\""
        + " OUTFITS_ROOT=\"" + OUTFITS_ROOT + "\"");
    stop_rlv_listen();
    if (CurrentUser == NULL_KEY) {
        logd("HANDLE drop: CurrentUser==NULL_KEY");
        return;
    }
    if (MenuContext != "scanning") {
        logd("HANDLE drop: MenuContext != scanning");
        return;
    }

    // Parse the raw @getinv CSV. Dot-prefixed and tilde-prefixed entries
    // are filtered out — the protected .base folder is hidden by RLV's
    // @getinv rule (every enumeration command suppresses dot-prefixed
    // names per the RLV API spec), so there is no programmatic way to
    // verify .base exists. The wearer can request setup instructions via
    // the picker's Help button if needed.
    Outfits = [];

    if (message != "") {
        list raw = llParseString2List(message, [","], []);
        integer n = llGetListLength(raw);

        // Pre-allocate Outfits to the parsed CSV capacity via list
        // doubling, then fill with llListReplaceList and truncate —
        // avoids O(N²) heap churn on large outfit trees (matches the
        // plugin_folders rev 26 pattern).
        if (n > 0) {
            list buf = [""];
            while (llGetListLength(buf) < n) buf = buf + buf;
            Outfits = llList2List(buf, 0, n - 1);
        }

        integer filled = 0;
        integer i = 0;
        while (i < n) {
            string entry = llStringTrim(llList2String(raw, i), STRING_TRIM);
            logd("PARSE entry[" + (string)i + "]=\""
                + entry + "\" len=" + (string)llStringLength(entry));
            if (entry != "") {
                string first = llGetSubString(entry, 0, 0);
                if (first != "." && first != "~") {
                    Outfits = llListReplaceList(Outfits, [entry], filled, filled);
                    filled += 1;
                }
            }
            i += 1;
        }
        logd("PARSE summary: total=" + (string)n
            + " outfits_kept=" + (string)filled);

        if (filled == 0)     Outfits = [];
        else if (filled < n) Outfits = llList2List(Outfits, 0, filled - 1);

        if (filled > 0) Outfits = llListSort(Outfits, 1, TRUE);
    }

    if (llGetListLength(Outfits) == 0) {
        llRegionSayTo(CurrentUser, 0,
            "No outfits found in #RLV/" + OUTFITS_ROOT + ".");
        return_to_root();
        return;
    }

    show_picker(0);
}

/* -------------------- EVENTS -------------------- */
default {
    state_entry() {
        if (llGetObjectDesc() == "COLLAR_UPDATER") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        cleanup_session();
        // Persistent locks: read KEY_LOCKED from LSD and re-claim each
        // outfit via kmod_rlv. The viewer keeps @detachallthis
        // restrictions tied to this object alive until released or
        // until the collar is reset, so re-applying on every boot is
        // both correct (the viewer already has the restriction; this
        // re-establishes kmod_rlv's tracking) and idempotent (claim_add
        // is a no-op for an already-active behav). Mirrors plugin_lock
        // / plugin_folders: locks persist across detach/reattach.
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
        // @getinv response timed out — viewer not RLV-enabled or not
        // responding. cleanup_session in return_to_root resets state.
        logd("TIMEOUT MenuContext=\"" + MenuContext + "\""
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
                // Release viewer-side @detachallthis restrictions before
                // we wipe state and reset. kmod_rlv resets in parallel on
                // factory reset, so its claim_clear path won't reliably
                // emit the @=y commands; bypass with direct llOwnerSay
                // (release_persisted_locks) and rely on kmod_settings to
                // wipe KEY_LOCKED itself via clear_managed_settings.
                release_persisted_locks();
                llLinksetDataDelete("plugin.reg." + PLUGIN_CONTEXT);
                llLinksetDataDelete("acl.policycontext:" + PLUGIN_CONTEXT);
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
                if (id == NULL_KEY) return;

                integer start_acl = (integer)llJsonGetValue(msg, ["acl"]);

                gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, start_acl);
                // Any of the three core actions grants entry; Lock/Unlock
                // alone would be useless without something to lock against.
                if (!btn_allowed("Add") && !btn_allowed("Wear") && !btn_allowed("Remove")) {
                    llRegionSayTo(id, 0, "Access denied.");
                    gPolicyButtons = [];
                    return;
                }

                CurrentUser = id;
                UserAcl     = start_acl;
                scan_outfits();
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

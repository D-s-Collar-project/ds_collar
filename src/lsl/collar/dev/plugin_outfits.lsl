/*--------------------
PLUGIN: plugin_outfits.lsl
VERSION: 1.10
REVISION: 17
PURPOSE: Browse #RLV/~outfits subfolders and act on them. Four actions
         per outfit:
           Add    — attach the folder additively (layer on top)
           Wear   — replace: detach worn unlocked items then attach
                    the chosen folder. ~outfits/~base items are
                    protected by this plugin's @detachallthis claim
                    and silently survive.
           Remove — detach this outfit's items
           Lock   — state-labelled toggle ('Lock: On' / 'Lock: Off');
                    claims @detachallthis on the outfit when off,
                    releases the claim when on. (One button replaces
                    the prior Lock + Unlock pair.)
         The picker also exposes a Help button that delivers the
         "D/s Collar outfits setup" notecard describing the expected
         #RLV/~outfits/~base layout.
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button
             visibility. Subfolder enumeration via @getinv:~outfits on
             every menu entry — no persisted manifest. Folder names
             use a tilde prefix (orthodox-RLV convention, matches OC):
             ~outfits is visible to all RLV enumeration commands, sorts
             to the bottom of the inventory tree alphabetically, and
             — crucially — its paths resolve under @getpath, so
             plugin_strip can pre-filter locked items from its picker.
             The ~base subfolder is hidden from THIS plugin's outfit
             picker by a tilde-prefix skip in show_picker; it remains
             visible to RLV otherwise. Lock state is
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
             Lock/Unlock. plugin_strip detects locked items live via
             @getstatusall:detach + @getpath at picker render time;
             this plugin does NOT maintain a shadow lock vector.
CHANGES:
- v1.10 rev 17: Revert revs 15+16 (worn.registry.locked bit-vector writer
  and @getpath probe sweep). The shadow lock vector caused a Mono stack-heap
  collision and was unnecessary: plugin_strip can ask the viewer directly
  via @getstatusall:detach + @getpath at picker time. Drops
  snapshot_attached / queue_registry_update / apply_registry_update,
  begin_path_sweep / handle_path_response, and the ProbeActive / Registry
  globals. apply_lock / apply_unlock / toggle_active no longer call the
  sweep — the lock state is now read live by plugin_strip.
- v1.10 rev 16: Close the rev 15 gap for Lock/Unlock/Enable/Disable acting on already-worn items. New begin_path_sweep + handle_path_response state machine fires a sequential @getpath:<pt>=<chan> probe over every currently-attached slot at apply_lock / apply_unlock / toggle_active time and updates the worn.registry.locked bit vector accordingly: lock → set bits where the returned path falls under the locked subtree, unlock → clear bits where the returned path was under the unlocked subtree AND no other lock still covers it. Multiplexed timer / listen (ProbeActive flag) routes responses between the probe and the existing @getinv-scan path on the shared RLV_CHAN. is_path_locked refactored to read in-memory LockedOutfits / OutfitsActive instead of LSD so the unlock probe doesn't race against the in-flight settings.delta write that removes the just-unlocked entry. apply_lock + apply_unlock + toggle_active each call begin_path_sweep after their existing state mutation; one settings.delta is emitted per sweep with the accumulated bit changes.
- v1.10 rev 15: Maintain the shared worn.registry.locked bit vector (kmod_settings rev 19) on apply_wear / apply_add / apply_remove. Each fires queue_registry_update + the RLV command; 2s later the timer applies the diff between pre- and post-snapshots of llGetAttachedList. apply_wear uses "replace" semantics (both set newly-attached bits and clear stripped bits); apply_add is "attach"-only (preserves existing bits since @attachallover doesn't kick slot occupants); apply_remove is "detach"-only. Bit position = ATTACH_* integer. Multiplexed timer handles both registry-update deadline and the existing RLV-scan timeout. apply_lock / apply_unlock don't write bits — same limitation as plugin_folders rev 32 (re-Wear via the plugin to update existing items' bits to reflect a new lock state).
- v1.10 rev 14: Collapse Lock + Unlock buttons in the per-outfit action submenu into a single state-labelled toggle ('Lock: On' / 'Lock: Off'), matching the 'Turn: On/Off' / 'Enhanced: On/Off' convention used elsewhere. New `toggle_lock` button context dispatches to apply_lock or apply_unlock based on current LockedOutfits membership. ACL gating still keys off btn_allowed("Lock"); the policy CSV is unchanged (Lock and Unlock are always co-granted in current policy). Body text shortened — the old two-line Lock/Unlock description collapses to one line. Picker `*` prefix on locked outfits is unchanged.
- v1.10 rev 13: Migrate the outfit-system folder names from dot-prefixed (.outfits / .outfits/.base) to tilde-prefixed (~outfits / ~outfits/~base). Tilde-prefixed folders are visible to every RLV enumeration command (@getinv, @getpath, @getinvworn …), which unblocks plugin_strip's path-based pre-filter for picker contents — see plugin_strip rev 15. ~base is kept out of the outfit picker by the existing dot-or-tilde skip in handle_rlv_response. Constants OUTFITS_ROOT / BASE_FOLDER repointed; all live comments and user-facing strings updated. Wearers must rename their inventory folders to match (.outfits → ~outfits, .base → ~base inside it); the setup notecard is rewritten to describe the new layout.
- v1.10 rev 12: Wear's strip is now three-phase and symmetric across attachments and clothing layers: @detachallthis:.outfits=force (subtree-as-unit clear of unlocked .outfits items), then @remattach=force (attachments worn from outside .outfits), then @remoutfit=force (system clothing layers worn from outside .outfits). .base and any locked outfit folder, attachment point, or layer survive via the standard RLV lock-respect path. Attach stays on @attachall:.outfits/<name>=force — the *this family is locks / self-referential detach only, not attaches.
- v1.10 rev 11: Wear now uses @detachallthis / @attachallthis (subtree-as-unit variants) instead of @detachall / @attachall. Lock semantics unchanged — locked subfolders still skipped — but the verbs match the intent (operate on .outfits as one subtree) and stay symmetric on both sides of the replace.
- v1.10 rev 10: Default plugin.outfit.active to OFF when KEY_ACTIVE is
  absent in LSD (fresh installs, pre-rev-9 collars). Booting with .base
  locked before the wearer has set up outfits was a UX trap. Empty
  scan_outfits result now routes to a new no-outfits menu
  (Help/Disable/Back) instead of return_to_root, closing the dead-end
  where post-Enable empty scan locked .base with no path back.
- v1.10 rev 9: Runtime on/off toggle. plugin.outfit.active LSD key
  (managed by kmod_settings rev 18, default ON) controls whether the
  outfit system is active. Disable button on the picker for ACL
  2/3/4/5 (wearer-grade QoL — owned wearers can change appearance
  too); Enable button on the disabled menu. When OFF, the
  .outfits/.base @detachallthis claim is released so the wearer can
  freely change appearance — that lock now belongs to plugin_outfits
  instead of plugin_strip (which dropped its claim in rev 13).
  Per-outfit Lock/Unlock state (KEY_LOCKED) is unaffected by the
  toggle. PageSize drops 8 → 7 to make room for the Disable button
  (cell 4); ACL 1 (public) sees a blank filler in that cell.
- v1.10 rev 8: Strip DEBUG_OUTFITS scaffolding and logd() calls now
  that the dropped .base precheck (rev 7) is confirmed working.
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

integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS     = 800;
integer UI_BUS           = 900;
integer DIALOG_BUS       = 950;

string PLUGIN_CONTEXT = "ui.core.outfits";
string PLUGIN_LABEL   = "Outfits";

integer RLV_CHAN    = 1888772;
float   RLV_TIMEOUT = 10.0;
string  OUTFITS_ROOT = "~outfits";
string  BASE_FOLDER  = "~outfits/~base";
string  RLV_CONSUMER = "outfits";

string  KEY_LOCKED = "outfits.locked";
string  KEY_ACTIVE = "plugin.outfit.active";

string  SETUP_NOTECARD = "D/s Collar outfits setup";

key     CurrentUser    = NULL_KEY;
integer UserAcl        = 0;
list    gPolicyButtons = [];
string  SessionId      = "";

string  MenuContext    = "";   // "scanning" | "pick" | "action" | "disabled" | "empty"
string  SelectedOutfit = "";

list    Outfits     = [];
integer PickPage    = 0;
integer LastMaxPage = 0;
// page_size is derived per-render in show_picker as `9 - action_count`,
// because action_buttons varies with policy: Help is always shown, Disable
// is ACL-gated. ACL 1 (no Disable): action_count=1 → page_size=8. ACL 2+:
// action_count=2 → page_size=7. LastMaxPage stashed for prev/next wrap.

// Default OFF so fresh wearers can build #RLV/~outfits/~base without
// fighting a ~base lock. LastActive = -1 forces first sync to emit.
integer OutfitsActive = 0;
integer LastActive    = -1;

list    LockedOutfits   = [];
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

/* -------------------- LIFECYCLE -------------------- */

write_plugin_reg(string label) {
    string k = "plugin.reg." + PLUGIN_CONTEXT;
    string v = llList2Json(JSON_OBJECT, ["label", label, "script", llGetScriptName()]);
    if (llLinksetDataRead(k) == v) return;
    llLinksetDataWrite(k, v);
}

register_self() {
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "Add,Wear,Remove",
        "2", "Add,Wear,Remove,Disable",
        "3", "Add,Wear,Remove,Lock,Unlock,Disable",
        "4", "Add,Wear,Remove,Lock,Unlock,Disable",
        "5", "Add,Wear,Remove,Lock,Unlock,Disable"
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
    SessionId      = "";
    CurrentUser    = NULL_KEY;
    UserAcl        = 0;
    gPolicyButtons = [];
    MenuContext    = "";
    SelectedOutfit = "";
    Outfits        = [];
    PickPage       = 0;
    LastMaxPage    = 0;
}

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return", "context", PLUGIN_CONTEXT, "user", (string)CurrentUser
    ]), NULL_KEY);
    cleanup_session();
}

/* -------------------- SETTINGS PERSISTENCE -------------------- */

persist_locked() {
    if (llGetListLength(LockedOutfits) == 0) {
        llMessageLinked(LINK_SET, SETTINGS_BUS, "settings.delete:" + KEY_LOCKED, NULL_KEY);
        return;
    }
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + KEY_LOCKED + ":" + llDumpList2String(LockedOutfits, ","), NULL_KEY);
}

rlv_op(string op, string behav) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", op, "consumer", RLV_CONSUMER, "behav", behav
    ]), NULL_KEY);
}

// Diff persisted CSV against LockedOutfits; release dropped, re-apply current.
// kmod_rlv claim_add is idempotent so re-apply is safe; also re-establishes
// tracking after a cross-script reset.
apply_settings_sync() {
    string csv = llLinksetDataRead(KEY_LOCKED);
    list new_locked = [];
    if (csv != "") new_locked = llParseString2List(csv, [","], []);

    integer i = 0;
    integer n = llGetListLength(LockedOutfits);
    while (i < n) {
        string old_name = llList2String(LockedOutfits, i);
        if (llListFindList(new_locked, [old_name]) == -1) {
            rlv_op("rlv.release", "detachallthis:" + OUTFITS_ROOT + "/" + old_name);
        }
        i += 1;
    }

    LockedOutfits = new_locked;

    i = 0;
    n = llGetListLength(LockedOutfits);
    while (i < n) {
        rlv_op("rlv.apply", "detachallthis:" + OUTFITS_ROOT + "/" + llList2String(LockedOutfits, i));
        i += 1;
    }

    string active_str = llLinksetDataRead(KEY_ACTIVE);
    integer new_active = 0;
    if (active_str != "") new_active = (integer)active_str;
    OutfitsActive = new_active;
    if (new_active != LastActive) {
        string op = "rlv.release";
        if (new_active) op = "rlv.apply";
        rlv_op(op, "detachallthis:" + BASE_FOLDER);
        LastActive = new_active;
    }
}

toggle_active(integer new_state) {
    OutfitsActive = new_state;
    LastActive    = new_state;
    string op = "rlv.release";
    if (new_state) op = "rlv.apply";
    rlv_op(op, "detachallthis:" + BASE_FOLDER);
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" + KEY_ACTIVE + ":" + (string)new_state, NULL_KEY);
}

// Direct llOwnerSay before llResetScript — kmod_rlv may reset in parallel
// and drop Claims without emitting @=y, leaving viewer-side restrictions
// orphaned.
release_persisted_locks() {
    string csv = llLinksetDataRead(KEY_LOCKED);
    if (csv != "") {
        list locks = llParseString2List(csv, [","], []);
        integer n = llGetListLength(locks);
        integer i = 0;
        while (i < n) {
            string name = llList2String(locks, i);
            if (name != "") llOwnerSay("@detachallthis:" + OUTFITS_ROOT + "/" + name + "=y");
            i += 1;
        }
    }
    string active_str = llLinksetDataRead(KEY_ACTIVE);
    integer was_active = 1;
    if (active_str != "") was_active = (integer)active_str;
    if (was_active) llOwnerSay("@detachallthis:" + BASE_FOLDER + "=y");
}

/* -------------------- RLV -------------------- */

rlv_force(string command) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "rlv.force", "command", command
    ]), NULL_KEY);
}

scan_outfits() {
    Outfits = [];
    MenuContext = "scanning";
    stop_rlv_listen();
    RlvListenHandle = llListen(RLV_CHAN, "", llGetOwner(), "");
    llSetTimerEvent(RLV_TIMEOUT);
    rlv_force("@getinv:" + OUTFITS_ROOT + "=" + (string)RLV_CHAN);
    llRegionSayTo(CurrentUser, 0, "Reading #RLV/" + OUTFITS_ROOT + " ...");
}

/* -------------------- UI -------------------- */

show_picker(integer page) {
    SessionId   = sid();
    MenuContext = "pick";

    // Action buttons computed up-front because page_size depends on
    // action_count (slot 4 is content for users without Disable policy).
    // Help is always shown (UX, not policy-gated). Disable is ACL-gated.
    list action_buttons = [btn("Help", "help")];
    if (btn_allowed("Disable")) action_buttons += [btn("Disable", "disable")];
    integer action_count = llGetListLength(action_buttons);

    // 12 dialog slots minus 3 nav minus action buttons = content capacity.
    integer page_size = 9 - action_count;
    integer total = llGetListLength(Outfits);

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

    string body = "Outfits  (#RLV/" + OUTFITS_ROOT + ")\n";
    if (total == 0) {
        body += "\nNo outfits found.\nCreate subfolders under #RLV/" + OUTFITS_ROOT + ".";
    } else {
        body += "*=locked\nPage " + (string)(page + 1) + " of " + (string)(max_page + 1) + "\n\n";
        integer k = 0;
        while (k < count) {
            string outfit_name = llList2String(Outfits, start_idx + k);
            string mark = "";
            if (llListFindList(LockedOutfits, [outfit_name]) != -1) mark = " *";
            body += (string)(k + 1) + ". " + outfit_name + mark + "\n";
            k += 1;
        }
    }

    // Layout per project dialog convention (canonical: plugin_animate):
    //   slots 0-2: nav (<<, >>, Back)
    //   slot 3-N : action buttons (Help, optionally Disable)
    //   remaining: outfit content, slot-mapped top→bottom, left→right.
    //              ACL 1 (no Disable): slot 4 becomes content.
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

show_disabled_menu() {
    SessionId   = sid();
    MenuContext = "disabled";

    string body = "Outfits is currently DISABLED.\n";
    body += "~outfits/~base is unlocked — the wearer can change\n";
    body += "appearance freely. Re-enable to restore protection and ";
    body += "resume outfit browsing.";

    list button_data = [];
    if (btn_allowed("Disable")) button_data += [btn("Enable", "enable")];
    button_data += [btn("Help", "help")];
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

show_empty_menu() {
    SessionId   = sid();
    MenuContext = "empty";

    string body = "No outfits found in #RLV/" + OUTFITS_ROOT + ".\n\n";
    body += "Create a subfolder under #RLV/" + OUTFITS_ROOT + " for\n";
    body += "each outfit, then return here. Tap Help for the setup\nnotecard.";

    list button_data = [btn("Help", "help")];
    if (btn_allowed("Disable")) button_data += [btn("Disable", "disable")];
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

show_action(string outfit_name) {
    SessionId      = sid();
    MenuContext    = "action";
    SelectedOutfit = outfit_name;

    integer is_locked = (llListFindList(LockedOutfits, [outfit_name]) != -1);
    string status = "";
    if (is_locked) status = "  (Locked)";

    string body = "Outfit: " + outfit_name + status + "\n\n";
    body += "Add    - attach this folder on top of what is worn\n";
    body += "Wear   - replace: detach worn unlocked items, attach this\n";
    body += "Remove - detach this outfit's items\n";
    if (btn_allowed("Lock") || btn_allowed("Unlock")) {
        body += "Lock   - toggle protection against removal";
    }

    list button_data = [];
    if (btn_allowed("Add"))    button_data += [btn("Add",    "add")];
    if (btn_allowed("Wear"))   button_data += [btn("Wear",   "wear")];
    if (btn_allowed("Remove")) button_data += [btn("Remove", "remove")];
    if (btn_allowed("Lock")) {
        if (is_locked) button_data += [btn("Lock: On",  "toggle_lock")];
        else           button_data += [btn("Lock: Off", "toggle_lock")];
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

give_setup_notecard() {
    if (llGetInventoryType(SETUP_NOTECARD) != INVENTORY_NOTECARD) {
        llRegionSayTo(CurrentUser, 0, "Setup notecard not found in collar inventory.");
        return;
    }
    llGiveInventory(CurrentUser, SETUP_NOTECARD);
    llRegionSayTo(CurrentUser, 0, "Setup instructions sent.");
}

// @attachallover keeps slot occupants — items layer on top.
apply_add(string outfit_name) {
    rlv_force("@attachallover:" + OUTFITS_ROOT + "/" + outfit_name + "=force");
    llRegionSayTo(CurrentUser, 0, "Adding: " + outfit_name);
}

// Three-phase strip (~outfits subtree, then attachments, then layers) then
// attach. All three strip phases respect existing locks (~base survives).
apply_wear(string outfit_name) {
    rlv_force("@detachallthis:" + OUTFITS_ROOT + "=force");
    rlv_force("@remattach=force");
    rlv_force("@remoutfit=force");
    rlv_force("@attachall:" + OUTFITS_ROOT + "/" + outfit_name + "=force");
    llRegionSayTo(CurrentUser, 0, "Wearing: " + outfit_name);
}

apply_remove(string outfit_name) {
    rlv_force("@detachall:" + OUTFITS_ROOT + "/" + outfit_name + "=force");
    llRegionSayTo(CurrentUser, 0, "Removing: " + outfit_name);
}

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
    if ((key)llJsonGetValue(msg, ["user"]) != CurrentUser) return;

    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";

    if (MenuContext == "empty") {
        if (ctx == "help") { give_setup_notecard(); show_empty_menu(); return; }
        if (ctx == "disable") {
            if (!btn_allowed("Disable")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_empty_menu();
                return;
            }
            toggle_active(0);
            show_disabled_menu();
            return;
        }
        if (ctx == "back") return_to_root();
        return;
    }

    if (MenuContext == "disabled") {
        if (ctx == "enable") {
            if (!btn_allowed("Disable")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_disabled_menu();
                return;
            }
            toggle_active(1);
            scan_outfits();
            return;
        }
        if (ctx == "help") { give_setup_notecard(); show_disabled_menu(); return; }
        if (ctx == "back") return_to_root();
        return;
    }

    if (MenuContext == "pick") {
        if (ctx == "back") { return_to_root(); return; }
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
        if (ctx == "help") { give_setup_notecard(); show_picker(PickPage); return; }
        if (ctx == "disable") {
            if (!btn_allowed("Disable")) {
                llRegionSayTo(CurrentUser, 0, "Access denied.");
                show_picker(PickPage);
                return;
            }
            toggle_active(0);
            show_disabled_menu();
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
        if (ctx == "back")   { show_picker(PickPage); return; }
        if (ctx == "add")    { apply_add(SelectedOutfit);    show_picker(PickPage); return; }
        if (ctx == "wear")   { apply_wear(SelectedOutfit);   show_picker(PickPage); return; }
        if (ctx == "remove") { apply_remove(SelectedOutfit); show_picker(PickPage); return; }
        if (ctx == "toggle_lock") {
            if (llListFindList(LockedOutfits, [SelectedOutfit]) != -1) apply_unlock(SelectedOutfit);
            else                                                       apply_lock(SelectedOutfit);
            show_picker(PickPage);
        }
    }
}

handle_dialog_timeout(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
    cleanup_session();
}

/* -------------------- RLV RESPONSE -------------------- */

handle_rlv_response(string message) {
    stop_rlv_listen();
    if (CurrentUser == NULL_KEY) return;
    if (MenuContext != "scanning") return;

    // @getinv only hides dot-prefixed; we skip both dot- and tilde-prefixed
    // so ~base stays out of the picker.
    Outfits = [];
    if (message != "") {
        list raw = llParseString2List(message, [","], []);
        integer n = llGetListLength(raw);
        if (n > 0) {
            list buf = [""];
            while (llGetListLength(buf) < n) buf = buf + buf;
            Outfits = llList2List(buf, 0, n - 1);
        }
        integer filled = 0;
        integer i = 0;
        while (i < n) {
            string entry = llStringTrim(llList2String(raw, i), STRING_TRIM);
            if (entry != "") {
                string first = llGetSubString(entry, 0, 0);
                if (first != "." && first != "~") {
                    Outfits = llListReplaceList(Outfits, [entry], filled, filled);
                    filled += 1;
                }
            }
            i += 1;
        }
        if (filled == 0)     Outfits = [];
        else if (filled < n) Outfits = llList2List(Outfits, 0, filled - 1);
        if (filled > 0) Outfits = llListSort(Outfits, 1, TRUE);
    }

    if (llGetListLength(Outfits) == 0) {
        show_empty_menu();
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
        apply_settings_sync();
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
                // Release viewer-side restrictions BEFORE reset — kmod_rlv may
                // reset in parallel and drop its Claims without emitting @=y.
                release_persisted_locks();
                llLinksetDataDelete("plugin.reg." + PLUGIN_CONTEXT);
                llLinksetDataDelete("acl.policycontext:" + PLUGIN_CONTEXT);
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync") apply_settings_sync();
        }
        else if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                if (id == NULL_KEY) return;

                integer start_acl = (integer)llJsonGetValue(msg, ["acl"]);
                gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, start_acl);
                if (!btn_allowed("Add") && !btn_allowed("Wear") && !btn_allowed("Remove")) {
                    llRegionSayTo(id, 0, "Access denied.");
                    gPolicyButtons = [];
                    return;
                }
                CurrentUser = id;
                UserAcl     = start_acl;
                if (OutfitsActive) scan_outfits();
                else               show_disabled_menu();
            }
        }
        else if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") handle_dialog_response(msg);
            else if (msg_type == "ui.dialog.timeout") handle_dialog_timeout(msg);
        }
    }
}

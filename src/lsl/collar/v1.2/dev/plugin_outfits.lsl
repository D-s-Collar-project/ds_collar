/*--------------------
PLUGIN: plugin_outfits.lsl
VERSION: 1.2
REVISION: 12
PURPOSE: Browse #RLV/outfits subfolders and act on them. Four actions
         per outfit:
           Add    — attach the folder additively (layer on top)
           Wear   — replace: detach worn unlocked items then attach
                    the chosen folder. outfits/.base items are
                    protected by this plugin's @detachallthis claim
                    and silently survive.
           Remove — detach this outfit's items
           Lock   — state-labelled toggle ('Lock: On' / 'Lock: Off');
                    claims @detachallthis on the outfit when off,
                    releases the claim when on. (One button replaces
                    the prior Lock + Unlock pair.)
         The picker also exposes a Help button that delivers the
         "D/s Collar outfits setup" notecard describing the expected
         #RLV/outfits/.base layout.
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button
             visibility. Subfolder enumeration via @getinv:outfits on
             every menu entry — no persisted manifest. The protected
             base subfolder uses a dot prefix (.base), which RLV's
             folder API treats as a "disabled folder" — invisible to
             @getinv, @getpath, and @getinvworn — so it can't be
             enumerated or picker-listed by plugin_strip. Items still
             attach normally from there; the @detachallthis lock blocks
             stripping. Lock state is persistent via kmod_settings
             (KEY_LOCKED CSV in LSD), mirroring the plugin_lock /
             plugin_folders pattern: locks survive detach/reattach and
             script reset, and only release when the wearer explicitly
             Unlocks or factory-resets. apply_settings_sync diffs the
             in-memory list against the LSD CSV on every state_entry
             and settings.sync, releasing removed locks and (re-)applying
             current ones. Factory reset releases viewer-side
             restrictions via direct llOwnerSay (release_persisted_locks)
             before llResetScript, so they don't orphan if kmod_rlv
             resets alongside us. Force-attach/detach commands route
             through kmod_rlv (rlv.force); lock/unlock route through
             kmod_rlv rlv.apply/release under consumer "outfits",
             refcount-coordinated with any other plugin claiming the
             same behav. Per-action ACL gating mirrors plugin_folders:
             ACL 1/2 get Add/Wear/Remove; ACL 3/4/5 also get
             Lock/Unlock. plugin_strip enumerates worn items via
             llGetAttachedList + @getoutfit and filters per-slot locks
             at build time; folder-scoped locks (incl. our
             outfits/.base claim) block @remattach / @remoutfit at
             force time, and plugin_strip's verify_attempted_strip →
             DiscoveredLocked pair catches the silent fail on first
             click and hides those items for the rest of the session.
             No shared shadow lock vector between plugins.
CHANGES:
- v1.2 rev 12: on safeword.fired, clear the persisted per-outfit lock list (LockedOutfits=[] + delete outfits.locked) so the locks don't re-apply on the next sync — kmod_rlv already released the detachallthis claims. A bad-actor-imposed locked outfit can't survive the wearer's safeword (unlock ≠ strip; the wearer just regains the ability to remove it).
- v1.2 rev 11: nav-row consistency — has_nav 0→1 on the empty + action menus so the << >> Back row matches the rest of the UI; catch-all redraws for the inert << >> (the OL outfit picker already pages).
- v1.2 rev 10: replaced the persistent .base lock + the whole Disable/Enable subsystem with a TRANSIENT base lock. apply_wear now locks .base (refcounted via kmod_rlv so a relay's claim isn't clobbered) ONLY across its strip, releasing immediately after — base survives our own re-dress, stays freely editable otherwise, and external strip is the relay's job, not ours. Deleted: toggle_active, OutfitsActive/LastActive, KEY_ACTIVE, show_disabled_menu, the "disabled" context + Disable/Enable buttons + handler branches, the active-gate in ui.menu.start (always scans now). Per-outfit Lock/Unlock unchanged. The scan-time cleanup now also always-releases any standing .base lock left by a pre-transient-lock rev (migration). No persistent base lock means no on/off toggle.
- v1.2 rev 9: renamed the RLV shared folder outfits → .outfits (OUTFITS_ROOT + BASE_FOLDER). Dotting hides it from the #RLV-root @getinvworn listing (so plugin_folders stops showing it) while @getinv:.outfits still enumerates its children directly. The conditional .base release now uses BASE_FOLDER (.outfits/.base) so it stays matched with the apply; the old UNDOTTED outfits/.base was added to the always-release cleanup to migrate existing collars off the undotted root. RLV_CONSUMER + KEY_LOCKED unchanged (IDs, not paths).
- v1.2 rev 8: menu-service migration. show_picker → kmod_menu OL mode + the `fixed` param (Help/Disable action buttons); outfit name+lock-mark ride the item label, page counter moves to title, the hand-rolled target_slots/padding block shed. show_disabled/show_empty/show_action → pager (has_nav=0, service supplies Back). Nav realigned from context (prev/next/back) to button-label (<< >> Back); actions + pick:<idx> still route by context. Browse/action logic unchanged. OUTFITS_ROOT stays "outfits" (the .outfits rename is a separate inventory call — @getinv can't enumerate dot-folders).
- v1.2 rev 7: RLV gating — ORed bit 0x40 into PLUGIN_ACL_MASK (62→126) so kmod_ui drops this RLV-dependent plugin from the menu when rlv.active=0 (published by kmod_bootstrap). No ACL-visibility change — bit 6 sits above the level bits 1-5.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. See collar_kernel rev 6.
--------------------*/

integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS     = 800;
integer UI_BUS           = 900;
integer DIALOG_BUS       = 950;

string PLUGIN_CONTEXT = "ui.core.outfits";
string PLUGIN_LABEL   = "Outfits";

integer RLV_CHAN    = 1888772;
float   RLV_TIMEOUT = 10.0;
string  OUTFITS_ROOT = ".outfits";       // dotted: hidden from the #RLV-root listing (folders browser) yet @getinv:.outfits still enumerates its children
string  BASE_FOLDER  = ".outfits/.base";
string  RLV_CONSUMER = "outfits";

string  KEY_LOCKED = "outfits.locked";

string  SETUP_NOTECARD = "D/s Collar outfits setup";

key     CurrentUser    = NULL_KEY;
integer UserAcl        = 0;
list    gPolicyButtons = [];
string  SessionId      = "";

string  MenuContext    = "";   // "scanning" | "pick" | "action" | "empty"
string  SelectedOutfit = "";

list    Outfits     = [];
integer PickPage    = 0;
integer LastMaxPage = 0;
// page_size is 9 - action_count; the picker's only action button is Help
// (always shown), so action_count=1 → page_size=8. LastMaxPage stashed for
// prev/next wrap.

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

// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "Avatar";
integer PLUGIN_ACL_MASK = 126;  // 62 (ACL 1-5) | 0x40 RLV-required: kmod_ui hides when rlv.active=0

register_self() {
    // Per-button visibility policy. Was written straight to LSD here; now
    // announced to the kernel, which is the SOLE writer of acl.policycontext
    // (and reg.<ctx>) — see collar_kernel rev 6.
    string policy = llList2Json(JSON_OBJECT, [
        "1", "Add,Wear,Remove",
        "2", "Add,Wear,Remove",
        "3", "Add,Wear,Remove,Lock,Unlock",
        "4", "Add,Wear,Remove,Lock,Unlock",
        "5", "Add,Wear,Remove,Lock,Unlock"
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
    // Help is the picker's only action button (always shown, not policy-gated).
    list action_buttons = [btn("Help", "help")];
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

    string body = "Outfits  (#RLV/" + OUTFITS_ROOT + ")";
    if (total == 0) {
        body += "\n\nNo outfits found.\nCreate subfolders under #RLV/" + OUTFITS_ROOT + ".";
    }
    else {
        body += "\n*=locked";
    }

    // Items: outfit name + lock mark; the OL service numbers them and returns
    // pick:<global-index>. The page counter moves into the title.
    list items = [];
    integer i = 0;
    while (i < total) {
        string outfit_name = llList2String(Outfits, i);
        string mark = "";
        if (llListFindList(LockedOutfits, [outfit_name]) != -1) mark = " *";
        items += [outfit_name + mark];
        i += 1;
    }

    // OL via the menu service: nav (<< >> Back) + the fixed Help button reserve
    // the low slots; numbered outfits pack above (no padding).
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

show_empty_menu() {
    SessionId   = sid();
    MenuContext = "empty";

    string body = "No outfits found in #RLV/" + OUTFITS_ROOT + ".\n\n";
    body += "Create a subfolder under #RLV/" + OUTFITS_ROOT + " for\n";
    body += "each outfit, then return here. Tap Help for the setup\nnotecard.";

    // Pager (has_nav=1: full << >> Back nav row; inert << >> redraw). Content = Help.
    list button_data = [btn("Help", "help")];

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

    // Pager (has_nav=1: full << >> Back nav row; inert << >> redraw). Content = the actions.
    list button_data = [];
    if (btn_allowed("Add"))    button_data += [btn("Add",    "add")];
    if (btn_allowed("Wear"))   button_data += [btn("Wear",   "wear")];
    if (btn_allowed("Remove")) button_data += [btn("Remove", "remove")];
    if (btn_allowed("Lock")) {
        if (is_locked) button_data += [btn("Lock: On",  "toggle_lock")];
        else           button_data += [btn("Lock: Off", "toggle_lock")];
    }

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

// Three-phase strip (outfits subtree, then attachments, then layers) then
// attach. All three strip phases respect existing locks (.base survives).
apply_wear(string outfit_name) {
    // Transient base lock: held ONLY across the strip so the foundation
    // survives our own re-dress, released the instant the attach is queued.
    // Refcounted via kmod_rlv (not raw llOwnerSay) so a relay's own .base
    // claim isn't clobbered, and serialized FIFO with the @force strips below
    // so the lock lands before the detach. External strip is the relay's job,
    // not ours — hence no persistent lock.
    rlv_op("rlv.apply", "detachallthis:" + BASE_FOLDER);
    rlv_force("@detachallthis:" + OUTFITS_ROOT + "=force");
    rlv_force("@remattach=force");
    rlv_force("@remoutfit=force");
    rlv_force("@attachall:" + OUTFITS_ROOT + "/" + outfit_name + "=force");
    rlv_op("rlv.release", "detachallthis:" + BASE_FOLDER);
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
    // Nav (<< >> Back) renders as plain buttons → empty context; route nav by
    // the button LABEL. Actions + pick:<idx> carry their own context.
    string button = llJsonGetValue(msg, ["button"]);
    if (button == JSON_INVALID) button = "";

    if (MenuContext == "empty") {
        if (ctx == "help") { give_setup_notecard(); show_empty_menu(); return; }
        if (button == "Back" || ctx == "back") { return_to_root(); return; }
        show_empty_menu();   // inert << >> — redraw
        return;
    }

    if (MenuContext == "pick") {
        if (button == "Back" || ctx == "back") { return_to_root(); return; }
        if (button == "<<") {
            if (PickPage == 0) show_picker(LastMaxPage);
            else               show_picker(PickPage - 1);
            return;
        }
        if (button == ">>") {
            if (PickPage >= LastMaxPage) show_picker(0);
            else                         show_picker(PickPage + 1);
            return;
        }
        if (ctx == "help") { give_setup_notecard(); show_picker(PickPage); return; }
        if (llSubStringIndex(ctx, "pick:") == 0) {
            integer pick_idx = (integer)llGetSubString(ctx, 5, -1);
            if (pick_idx >= 0 && pick_idx < llGetListLength(Outfits)) {
                show_action(llList2String(Outfits, pick_idx));
            }
        }
        return;
    }

    if (MenuContext == "action") {
        if (button == "Back" || ctx == "back") { show_picker(PickPage); return; }
        if (ctx == "add")    { apply_add(SelectedOutfit);    show_picker(PickPage); return; }
        if (ctx == "wear")   { apply_wear(SelectedOutfit);   show_picker(PickPage); return; }
        if (ctx == "remove") { apply_remove(SelectedOutfit); show_picker(PickPage); return; }
        if (ctx == "toggle_lock") {
            if (llListFindList(LockedOutfits, [SelectedOutfit]) != -1) apply_unlock(SelectedOutfit);
            else                                                       apply_lock(SelectedOutfit);
            show_picker(PickPage);
            return;
        }
        show_action(SelectedOutfit);   // inert << >> — redraw
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

    // @getinv hides dot-prefixed entries on its own (so .base never
    // appears here); we additionally skip tilde-prefixed entries to
    // keep legacy ~base layouts off the picker. Also detect "base" /
    // "~base" in the scan — if either is visible, the wearer is on a
    // non-canonical paradigm (current convention is dot-prefixed .base)
    // and our .base lock has nothing to apply to.
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
                // Skip dot/tilde-prefixed entries (RLV system convention).
                // .base is dot-prefixed so it's caught by the dot check.
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

    // Defensive cleanup of stale @detachallthis claims — viewer-side orphans
    // from old paradigms (legacy plain/tilde base, the pre-.outfits undotted
    // root) AND any STANDING .base lock left by a pre-transient-lock rev. All
    // no-ops if no claim is active. Base protection is now the TRANSIENT lock
    // in apply_wear, so nothing here re-applies a persistent lock.
    llOwnerSay("@detachallthis:outfits/base=y");
    llOwnerSay("@detachallthis:outfits/~base=y");
    llOwnerSay("@detachallthis:outfits/.base=y");
    llOwnerSay("@detachallthis:" + BASE_FOLDER + "=y");

    if (llGetListLength(Outfits) == 0) {
        show_empty_menu();
        return;
    }
    show_picker(0);
}

/* -------------------- EVENTS -------------------- */
default {
    state_entry() {
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
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
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
                scan_outfits();
            }
            else if (msg_type == "safeword.fired") {
                // Wearer safeword: kmod_rlv's system-wide clear already released
                // our detachallthis claims; clear the persisted lock list so they
                // don't re-apply on the next sync.
                LockedOutfits = [];
                persist_locked();
            }
        }
        else if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") handle_dialog_response(msg);
            else if (msg_type == "ui.dialog.timeout") handle_dialog_timeout(msg);
        }
    }
}

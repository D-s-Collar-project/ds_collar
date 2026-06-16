/*--------------------
SCRIPT: updater_driver.lsl  (v1.2)
VERSION: 1.2
REVISION: 0
PURPOSE: Installer-side orchestrator. Wearer touches the installer prim;
  top-level menu offers two paths:
    UPDATE COLLAR — scans the region for collars (5s window), shows a
      picker dialog of responders (auto-picks if only one), then deposits
      update_shim into the chosen collar and signals the bundler for an
      intersection refresh pass.
    INSTALL SCRIPTS — sub-menu picks between 'Existing collar' (same scan
      + picker as update, then bundler reports missing features as a
      multi-select dialog, then ships the wearer's selection via
      update_shim) and 'Empty object' (hand over install_shim, wait for
      its ready broadcast from the fresh target, then offer Minimal /
      Full / Bespoke).
ARCHITECTURE: Lives in the installer linkset root. Sibling updater_bundler
  runs in a child prim and holds the staged collar scripts. Chat protocol
  with collar uses kmod_remote's EXTERNAL_ACL_QUERY_CHAN / REPLY_CHAN; chat
  protocol with shim uses a random per-session secure channel passed as
  llRemoteLoadScriptPin's start_param. Dialog channels are per-session
  random negative ints.
--------------------*/


/* -------------------- EXTERNAL PROTOCOL CHANNELS -------------------- */
// Must match kmod_remote's EXTERNAL_ACL_QUERY_CHAN / EXTERNAL_ACL_REPLY_CHAN.
integer EXTERNAL_ACL_QUERY_CHAN = -8675309;
integer EXTERNAL_ACL_REPLY_CHAN = -8675310;


/* -------------------- LINK-MESSAGE NUMBERS -------------------- */
// Must match updater_bundler.
integer LM_BUNDLE_BEGIN        = 91001;
integer LM_BUNDLE_DONE         = 91002;
integer LM_INSTALL_BEGIN       = 91003;
integer LM_INSTALL_FEATURES    = 91004;
integer LM_INSTALL_GO          = 91005;
integer LM_INSTALL_SHIM_BEGIN  = 91006;
integer LM_FEATURES_QUERY      = 91007;  // driver→bundler: enumerate features
integer LM_BUNDLE_RESET        = 91008;  // driver→bundler: hard reset to clean state
integer LM_INSTALL_MISSING     = 91009;  // bundler→driver: flat list of missing scripts (install-existing)
integer LM_BESPOKE_START       = 91010;  // driver→updater_bespoke_ui: begin walk
integer LM_BESPOKE_DONE        = 91011;  // updater_bespoke_ui→driver: walk complete with scripts CSV
integer LM_BESPOKE_CANCEL      = 91012;  // updater_bespoke_ui→driver: wearer cancelled


/* -------------------- CONSTANTS -------------------- */
// Branded description stamped on the installer prim. Doubles as the shims'
// staging self-park signal (they disable themselves when they see it on
// their own prim). v1.2 collar scripts carry no dormancy guard; staged
// collar scripts are disabled directly by updater_bundler.
string UPDATER_MARKER = "D/s Collar Updater -- v1.2";

// Version this installer ships. Shown to the wearer at completion.
string BUILD_VERSION = "1.2";

// Names of payload scripts that get deposited into targets. Must exist
// in THIS prim's inventory for llGiveInventory / llRemoteLoadScriptPin
// to find them.
string SHIM_SCRIPT         = "update_shim";
string INSTALL_SHIM_SCRIPT = "install_shim";

// Timeouts.
float SCAN_WINDOW         = 5.0;     // collect collarready responses for 5s
float SHIM_READY_TIMEOUT  = 15.0;
float BUNDLE_TIMEOUT      = 240.0;
float INVITE_TIMEOUT      = 60.0;
float DIALOG_TIMEOUT      = 120.0;   // wearer has 2 min to answer a dialog
float SHIM_OFFER_TIMEOUT  = 180.0;   // 3 min from give to install.shim.ready

// Pagination. Page size for paginated dialogs is derived from
// `9 - action_count` per the dialog convention; feature picker has 1
// action ("Install") so 8 features per page, scan picker has 0 so 9.
integer COLLARS_PER_PAGE  = 9;


/* -------------------- STATE -------------------- */
// Phase names reflect what we're currently waiting on.
//   idle                       — no session in progress
//   idle_invited               — answered remote.updateravailable
//   scanning                   — collecting collarready responses (5s window)
//   scan_picking               — collar picker dialog open (>1 response)
//   shim_loading               — update shim being deposited (update mode)
//   install_shim_loading       — update shim being deposited (install mode)
//   bundling                   — update bundler running
//   done                       — update applied
//   install_bespoke_running    — updater_bespoke_ui running existing-mode walk
//   install_bundling           — install bundler shipping
//   shim_offer_waiting         — gave install_shim, waiting for ready broadcast
//   shim_features_querying     — bundler enumerating features for shim mode
//   shim_mode_picking          — Minimal/Full/Bespoke dialog open
//   shim_bespoke_running       — updater_bespoke_ui is running its walk
//   shim_bundling              — bundler shipping to install_shim
string Phase = "idle";

key CollarKey = NULL_KEY;
integer CollarPin = 0;
string  Session = "";
integer SecureChannel = 0;

integer ReplyListen = 0;   // permanent listen on EXTERNAL_ACL_REPLY_CHAN
integer SecureListen = 0;  // listen on SecureChannel

key Wearer = NULL_KEY;   // who rezzed / touched / was named in invite

// Cached invitation context.
string  InviteSession = "";
key     InviteCollar = NULL_KEY;

// Install mode: feature list from bundler (stride-2: [label, csv, ...]).
list    Features = [];

// Dialog channel state (used by every dialog the driver opens).
// Selected/PickerPage removed in rev 12 — install_picking is gone.
integer DialogChan = 0;
integer DialogListen = 0;

// install_shim flow state.
key     ShimTarget = NULL_KEY;   // the prim hosting install_shim
integer ShimPin = 0;

// Bespoke walk lives in the sibling updater_bespoke_ui script (split out
// in rev 10 because the inline walk pushed updater_driver past the Mono
// 65 KB compiled ceiling). Driver kicks it off with LM_BESPOKE_START and
// receives LM_BESPOKE_DONE (with the selected script CSV) or
// LM_BESPOKE_CANCEL when the wearer abandons the walk.

// Scan state. ScanResults is a stride-4 list:
//   [collar_key_str, pin_str, wearer_key_str, object_name, ...]
// ScanNextAction encodes the post-pick flow ("update" → load_shim
// "shim_loading"; "install" → load_shim "install_shim_loading").
list    ScanResults = [];
string  ScanNextAction = "";
integer ScanPage = 0;


/* -------------------- HELPERS -------------------- */

string new_session() {
    return "upd_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

integer random_channel() {
    integer n = -((integer)llFrand(2147483600.0) + 1);
    return n;
}

cleanup_listens() {
    if (SecureListen) llListenRemove(SecureListen);
    SecureListen = 0;
    if (DialogListen) llListenRemove(DialogListen);
    DialogListen = 0;
}

cleanup_all() {
    cleanup_listens();
    llSetTimerEvent(0.0);
    Phase = "idle";
    CollarKey = NULL_KEY;
    CollarPin = 0;
    Session = "";
    SecureChannel = 0;
    Wearer = NULL_KEY;
    InviteSession = "";
    InviteCollar = NULL_KEY;
    Features = [];
    DialogChan = 0;
    ShimTarget = NULL_KEY;
    ShimPin = 0;
    ScanResults = [];
    ScanNextAction = "";
    ScanPage = 0;
}

notice(string s) {
    if (Wearer != NULL_KEY) llRegionSayTo(Wearer, 0, s);
    else llOwnerSay(s);
}

// Tear down the current dialog channel and listen. Called whenever a
// dialog answer routes to a path that won't re-open the same dialog —
// keeps slot 0/1/2 from receiving stray responses on the next render.
close_dialog() {
    if (DialogListen) llListenRemove(DialogListen);
    DialogListen = 0;
    DialogChan   = 0;
}

// Open a dialog with a fresh channel and listen. Caller builds the
// buttons list at the exact slot positions per the project's UI
// convention — no automatic padding. See feedback_dialog_layout_convention.
open_dialog(key who, string body, list buttons) {
    if (DialogListen) llListenRemove(DialogListen);
    DialogChan = random_channel();
    DialogListen = llListen(DialogChan, "", who, "");
    llDialog(who, body, buttons, DialogChan);
    llSetTimerEvent(DIALOG_TIMEOUT);
}

// Wrap-around page nav helpers (mandatory per the convention; clamping
// is the wrong UX). `<<` on page 0 → last; `>>` on last → page 0.
integer wrap_prev_page(integer page, integer max_page) {
    page -= 1;
    if (page < 0) page = max_page;
    return page;
}

integer wrap_next_page(integer page, integer max_page) {
    page += 1;
    if (page > max_page) page = 0;
    return page;
}

// Build target_slots for content placement: top-to-bottom, left-to-right
// among the slots reachable given total_buttons length. action_slots is
// the list of action-row slots (3/4/5) claimed by buttons that aren't
// content — skipped here so content doesn't overwrite them. Non-
// contiguous claims are supported (e.g. action at slot 5 only, with
// slots 3 and 4 available as content).
list build_target_slots(integer total_buttons, list action_slots) {
    list slots = [];
    if (total_buttons > 9)  slots += [9];
    if (total_buttons > 10) slots += [10];
    if (total_buttons > 11) slots += [11];
    if (total_buttons > 6)  slots += [6];
    if (total_buttons > 7)  slots += [7];
    if (total_buttons > 8)  slots += [8];
    if (total_buttons > 3 && llListFindList(action_slots, [3]) == -1) slots += [3];
    if (total_buttons > 4 && llListFindList(action_slots, [4]) == -1) slots += [4];
    if (total_buttons > 5 && llListFindList(action_slots, [5]) == -1) slots += [5];
    return slots;
}


/* -------------------- TOP-LEVEL MENU -------------------- */

// Top-level menu. Three buttons in the bottom row (slots 0/1/2). No
// pagination nav since the menu is inherently single-page; Cancel (slot 2)
// rather than Back because there's no parent menu to return to.
show_main_menu(key who) {
    Wearer = who;
    Phase = "main_menu";
    open_dialog(who,
        "D/s Collar installer.\n\n"
      + "Update Collar — refresh an existing collar.\n"
      + "Install Scripts — install missing components, or fresh-install onto a new prim.",
        ["Update Collar", "Install Scripts", "Cancel"]);
}

// Sub-menu shown when wearer picks "Install Scripts" from the main menu.
// Forks explicitly between the two install paths — discovery-based
// branching was ambiguous because a worn collar would always be found
// and pre-empt the install_shim path even when the wearer wanted a
// fresh install onto a new prim. Slot 2 Back cancels the whole flow.
//   Slot 0: Existing, Slot 1: New, Slot 2: Back
show_install_submenu() {
    Phase = "install_submenu";
    open_dialog(Wearer,
        "Is this installation adding features to an existing collar or a new installation?",
        ["Existing", "New", "Back"]);
}


/* -------------------- SCAN + PICKER -------------------- */

// Touch-initiated scan replaces the old first-responder-wins discovery.
// Broadcast on QUERY_CHAN, then collect every remote.collarready for
// SCAN_WINDOW seconds. After the window: 0 responses → notice + cleanup,
// 1 → auto-pick and proceed, >1 → picker dialog. The invite path
// (collar invites updater) is unchanged — that handshake is point-to-point
// and doesn't need scanning.
begin_scan(key toucher, string next_action) {
    Wearer = toucher;
    ScanNextAction = next_action;
    ScanResults = [];
    ScanPage = 0;
    Phase = "scanning";
    Session = new_session();

    string msg = llList2Json(JSON_OBJECT, [
        "type",    "remote.updatediscover",
        "updater", (string)llGetKey(),
        "session", Session
    ]);
    llRegionSay(EXTERNAL_ACL_QUERY_CHAN, msg);

    llSetTimerEvent(SCAN_WINDOW);
    notice("Scanning for collars (" + (string)((integer)SCAN_WINDOW) + "s)...");
}

// Append a collar's response to ScanResults if it's valid and not already
// recorded. Dedupe by collar key. Session match ensures we only collect
// responses to OUR broadcast (not someone else's updater nearby).
record_scan_response(string message) {
    string sess = llJsonGetValue(message, ["session"]);
    if (sess == JSON_INVALID) return;
    if (sess != Session) return;

    string collar_str = llJsonGetValue(message, ["collar"]);
    string pin_str    = llJsonGetValue(message, ["pin"]);
    string wearer_str = llJsonGetValue(message, ["wearer"]);
    if (collar_str == JSON_INVALID) return;
    if (pin_str == JSON_INVALID) return;
    if (wearer_str == JSON_INVALID) wearer_str = collar_str;

    key collar = (key)collar_str;
    if (collar == NULL_KEY) return;
    if (llGetOwnerKey(collar) != llGetOwner()) return;

    // Dedupe — stride-4 means we check positions 0, 4, 8, ... for the key.
    integer n = llGetListLength(ScanResults) / 4;
    integer i = 0;
    while (i < n) {
        if (llList2String(ScanResults, i * 4) == collar_str) return;
        i += 1;
    }

    // Object name (synchronous if collar is in-region, which it must be
    // to have responded). Fallback to "Collar" if unavailable.
    list details = llGetObjectDetails(collar, [OBJECT_NAME]);
    string oname = "Collar";
    if (llGetListLength(details) > 0) {
        string got = llList2String(details, 0);
        if (got != "") oname = got;
    }

    ScanResults += [collar_str, pin_str, wearer_str, oname];
}

// Are there at least two distinct wearer keys in ScanResults? Used to
// decide label format — single-wearer case shows object name only,
// multi-wearer prefixes each with the avatar display name.
integer scan_has_multiple_wearers() {
    integer n = llGetListLength(ScanResults) / 4;
    if (n < 2) return FALSE;
    string first = llList2String(ScanResults, 2);
    integer i = 1;
    while (i < n) {
        if (llList2String(ScanResults, i * 4 + 2) != first) return TRUE;
        i += 1;
    }
    return FALSE;
}

// Truncate to 24 chars (LSL dialog button limit).
string clip24(string s) {
    if (llStringLength(s) <= 24) return s;
    return llGetSubString(s, 0, 23);
}

// Build the button label for one scan result. Multi-wearer mode prefixes
// the wearer's display name; single-wearer mode shows just the object
// name. llGetDisplayName is synchronous and returns the cached name; for
// avatars not in cache it returns "" → fall back to "?".
string scan_label_for(integer idx, integer multi_wearer) {
    string oname = llList2String(ScanResults, idx * 4 + 3);
    if (!multi_wearer) return clip24(oname);

    key wearer = (key)llList2String(ScanResults, idx * 4 + 2);
    string wname = llGetDisplayName(wearer);
    if (wname == "") wname = "?";
    return clip24(wname + ": " + oname);
}

// Render the scan picker as an ordered list per the project pattern:
// body text carries the numbered collar names, buttons are just digits.
// Avoids 24-char button-label clipping on long object names.
//   Slots 0/1/2: <<, >>, Back
//   Slots 3-11: digit buttons ("1", "2", ...), top-to-bottom left-to-right
show_scan_picker() {
    integer n = llGetListLength(ScanResults) / 4;
    integer pages = (n + COLLARS_PER_PAGE - 1) / COLLARS_PER_PAGE;
    if (pages < 1) pages = 1;

    integer multi = scan_has_multiple_wearers();
    integer start = ScanPage * COLLARS_PER_PAGE;
    integer stop = start + COLLARS_PER_PAGE;
    if (stop > n) stop = n;
    integer count = stop - start;

    integer total_buttons = 3 + count;

    list final_buttons = ["<<", ">>", "Back"];
    integer p = 0;
    while (p < count) {
        final_buttons += [" "];
        p += 1;
    }

    list target_slots = build_target_slots(total_buttons, []);
    integer i = 0;
    while (i < count) {
        integer slot = llList2Integer(target_slots, i);
        final_buttons = llListReplaceList(final_buttons, [(string)(i + 1)], slot, slot);
        i += 1;
    }

    string body = "Pick a collar to ";
    if (ScanNextAction == "install") body += "install into";
    else body += "update";
    body += ". Tap a number.\n";
    if (pages > 1) body += "Page " + (string)(ScanPage + 1) + " of " + (string)pages + "\n";
    body += "\n";
    integer k = 0;
    while (k < count) {
        body += (string)(k + 1) + ". " + scan_label_for(start + k, multi) + "\n";
        k += 1;
    }

    open_dialog(Wearer, body, final_buttons);
}

// Parse a digit button back to the absolute scan-results index for the
// current page and proceed with that collar. Returns TRUE on a valid
// numeric pick, FALSE if the label isn't a digit in range (so the nav
// labels and Back fall through to their own dispatchers).
integer try_scan_pick(string label) {
    integer pos = (integer)label;
    if (pos < 1) return FALSE;
    if ((string)pos != label) return FALSE;
    integer abs_idx = (ScanPage * COLLARS_PER_PAGE) + (pos - 1);
    integer n = llGetListLength(ScanResults) / 4;
    if (abs_idx >= n) return FALSE;
    integer page_stop = (ScanPage + 1) * COLLARS_PER_PAGE;
    if (abs_idx >= page_stop) return FALSE;

    CollarKey = (key)llList2String(ScanResults, abs_idx * 4);
    CollarPin = (integer)llList2String(ScanResults, abs_idx * 4 + 1);
    close_dialog();
    string next = "shim_loading";
    if (ScanNextAction == "install") next = "install_shim_loading";
    load_shim(next);
    return TRUE;
}

// Called from timer when the scan window expires. 0 → fail, 1 →
// auto-proceed (no point picker dialog for one option), >1 → picker.
finalize_scan() {
    integer n = llGetListLength(ScanResults) / 4;
    if (n == 0) {
        notice("No collars responded. Make sure your collar is worn and you are within 20 meters.");
        cleanup_all();
        return;
    }
    if (n == 1) {
        CollarKey = (key)llList2String(ScanResults, 0);
        CollarPin = (integer)llList2String(ScanResults, 1);
        string next = "shim_loading";
        if (ScanNextAction == "install") next = "install_shim_loading";
        load_shim(next);
        return;
    }
    Phase = "scan_picking";
    ScanPage = 0;
    show_scan_picker();
}


/* -------------------- UPDATE FLOW (invite path) -------------------- */

respond_to_invite(string message) {
    if (Phase != "idle") return;

    string sess = llJsonGetValue(message, ["session"]);
    if (sess == JSON_INVALID) return;
    string collar_str = llJsonGetValue(message, ["collar"]);
    if (collar_str == JSON_INVALID) return;
    string wearer_str = llJsonGetValue(message, ["wearer"]);
    if (wearer_str == JSON_INVALID) wearer_str = collar_str;

    key collar = (key)collar_str;
    if (collar == NULL_KEY) return;
    if (llGetOwnerKey(collar) != llGetOwner()) return;

    Phase = "idle_invited";
    InviteSession = sess;
    InviteCollar = collar;
    Wearer = (key)wearer_str;

    string reply = llList2Json(JSON_OBJECT, [
        "type",    "remote.updaterhere",
        "updater", (string)llGetKey(),
        "version", BUILD_VERSION,
        "session", sess
    ]);
    llRegionSay(EXTERNAL_ACL_QUERY_CHAN, reply);

    llSetTimerEvent(INVITE_TIMEOUT);
}

accept_invitation(string msg) {
    string sess = llJsonGetValue(msg, ["session"]);
    if (sess == JSON_INVALID) return;
    if (sess != InviteSession) return;

    string collar_str = llJsonGetValue(msg, ["collar"]);
    if (collar_str == JSON_INVALID) return;
    if ((key)collar_str != InviteCollar) return;

    string pin_str = llJsonGetValue(msg, ["pin"]);
    if (pin_str == JSON_INVALID) return;

    CollarKey = InviteCollar;
    CollarPin = (integer)pin_str;
    Session = InviteSession;

    if (llGetOwnerKey(CollarKey) != llGetOwner()) {
        notice("Collar is owned by a different avatar. Aborting.");
        cleanup_all();
        return;
    }

    notice("Collar accepted update; preparing scripts...");
    load_shim("shim_loading");
}

// (handle_collar_ready removed in rev 5 — touch-driven discovery now
// goes through begin_scan → record_scan_response → finalize_scan, which
// either auto-picks the sole responder or shows the picker dialog. The
// invite path uses accept_invitation directly and never needed this
// helper.)

// Deposit update_shim into the collar. next_phase says which post-load
// path to take (update vs install).
load_shim(string next_phase) {
    if (llGetInventoryType(SHIM_SCRIPT) != INVENTORY_SCRIPT) {
        notice("Installer is missing " + SHIM_SCRIPT + "; cannot proceed.");
        cleanup_all();
        return;
    }

    Phase = next_phase;
    SecureChannel = random_channel();
    SecureListen = llListen(SecureChannel, "", CollarKey, "");

    // 3s sleep; shim starts and whispers READY on SecureChannel.
    llRemoteLoadScriptPin(CollarKey, SHIM_SCRIPT, CollarPin, TRUE, SecureChannel);

    llSetTimerEvent(SHIM_READY_TIMEOUT);
    notice("Installing update shim...");
}


/* -------------------- BUNDLE DISPATCH (update) -------------------- */

dispatch_update_bundle() {
    Phase = "bundling";
    llSetTimerEvent(BUNDLE_TIMEOUT);

    string payload = llList2Json(JSON_OBJECT, [
        "collar",  (string)CollarKey,
        "pin",     (string)CollarPin,
        "channel", (string)SecureChannel
    ]);
    llMessageLinked(LINK_SET, LM_BUNDLE_BEGIN, payload, NULL_KEY);
    notice("Applying update...");
}

dispatch_install_bundle() {
    Phase = "install_bundling";
    llSetTimerEvent(BUNDLE_TIMEOUT);

    string payload = llList2Json(JSON_OBJECT, [
        "collar",  (string)CollarKey,
        "pin",     (string)CollarPin,
        "channel", (string)SecureChannel
    ]);
    llMessageLinked(LINK_SET, LM_INSTALL_BEGIN, payload, NULL_KEY);
    notice("Detecting missing components...");
}

// Each finish_* path ends with restart_after_operation rather than
// cleanup_all + return-to-idle. llResetScript wipes every global cleanly,
// avoiding "session already in progress" races caused by leftover Phase /
// listener state on the next touch. 5-second visible delay so the wearer
// reads the completion notice before the prim respawns.
restart_after_operation() {
    Phase = "resetting";
    llSetTimerEvent(0.0);
    notice("Please wait, restarting...");
    llSleep(5.0);
    llResetScript();
}

// User-initiated cancel path. Tells any active install_shim to disarm
// and self-delete (matches the success path's done-broadcast — the shim
// doesn't distinguish, it just removes itself when told), then resets
// the driver immediately rather than waiting for the dialog/bundle
// timer to expire. Shorter delay than restart_after_operation because
// the wearer just pressed Cancel — they want it gone, not a 5s wait.
cancel_and_reset() {
    if (ShimTarget != NULL_KEY) {
        string m = llList2Json(JSON_OBJECT, [
            "type", "install.shim.done",
            "shim", (string)ShimTarget
        ]);
        llRegionSay(EXTERNAL_ACL_QUERY_CHAN, m);
    }
    Phase = "resetting";
    llSetTimerEvent(0.0);
    notice("Installation cancelled. Resetting the updater...");
    llSleep(2.0);
    llResetScript();
}

// Completion notices stay deliberately generic — we ship scripts but
// don't verify they came up at a particular version (no version probe
// from the bundler to the collar). Claiming "Collar is now at version X"
// would be overconfident; "Operation completed" / "Installation of
// requested components completed" describes what we actually did.
finish_update() {
    llWhisper(SecureChannel, "DONE");
    notice("Operation completed.");
    restart_after_operation();
}

finish_install() {
    llWhisper(SecureChannel, "DONE");
    notice("Installation of requested components completed.");
    restart_after_operation();
}

finish_shim_install() {
    // Tell install_shim to disarm PIN, restart its parked collar scripts,
    // and self-delete.
    string msg = llList2Json(JSON_OBJECT, [
        "type", "install.shim.done",
        "shim", (string)ShimTarget
    ]);
    llRegionSay(EXTERNAL_ACL_QUERY_CHAN, msg);
    notice("Installation of requested components completed. Your new collar is ready for use.");
    restart_after_operation();
}


/* -------------------- FEATURE PICKER (multi-select) -------------------- */

integer features_count() {
    return llGetListLength(Features) / 2;
}

string feature_label(integer idx) {
    return llList2String(Features, idx * 2);
}

string feature_scripts(integer idx) {
    return llList2String(Features, idx * 2 + 1);
}

// (show_picker / match_picker_button / handle_picker_button removed in
// rev 12 — the install-against-existing-collar path now dispatches to
// updater_bespoke_ui via start_install_bespoke. The Features list still
// exists for the install_shim Minimal/Full picker path; feature_label /
// feature_scripts helpers above remain for that consumer.)


/* -------------------- INSTALL_SHIM FLOW (empty target) -------------------- */

offer_install_shim() {
    if (llGetInventoryType(INSTALL_SHIM_SCRIPT) != INVENTORY_SCRIPT) {
        notice("Installer is missing " + INSTALL_SHIM_SCRIPT + "; cannot proceed.");
        cleanup_all();
        return;
    }
    llGiveInventory(Wearer, INSTALL_SHIM_SCRIPT);
    Phase = "shim_offer_waiting";
    llSetTimerEvent(SHIM_OFFER_TIMEOUT);
    notice("No collar detected. Drop install_shim into the object you want to install scripts into, then wait — installer will pick it up automatically.");
}

handle_shim_ready(string message) {
    string shim_str = llJsonGetValue(message, ["shim"]);
    string pin_str  = llJsonGetValue(message, ["pin"]);
    if (shim_str == JSON_INVALID) return;
    if (pin_str == JSON_INVALID) return;

    ShimTarget = (key)shim_str;
    ShimPin    = (integer)pin_str;

    // Verify same-owner (llRemoteLoadScriptPin requires it anyway).
    if (llGetOwnerKey(ShimTarget) != llGetOwner()) return;

    // Ack so the shim stops broadcasting.
    string ack = llList2Json(JSON_OBJECT, [
        "type", "install.shim.ack",
        "shim", (string)ShimTarget
    ]);
    llRegionSay(EXTERNAL_ACL_QUERY_CHAN, ack);

    // Ask bundler to enumerate features assuming an empty target.
    Phase = "shim_features_querying";
    llMessageLinked(LINK_SET, LM_FEATURES_QUERY, "", NULL_KEY);
    llSetTimerEvent(BUNDLE_TIMEOUT);
}

/* -------------------- INSTALL-SHIM PAYLOAD BUILDER -------------------- */

// Compose the LM_INSTALL_SHIM_BEGIN payload from a chosen scripts list.
// Asset-gating flags are derived from the scripts themselves so the rule
// is uniform across Minimal / Full / Bespoke: animations ride with
// plugin_animate, and the "D/s Collar outfits setup" notecard rides
// with plugin_outfits. Add new asset/script linkages here as a single
// source of truth.
string build_shim_payload(list scripts) {
    integer skip_anim = (llListFindList(scripts, ["plugin_animate"]) == -1);

    list skip_nc = [];
    if (llListFindList(scripts, ["plugin_outfits"]) == -1) {
        skip_nc += ["D/s Collar outfits setup"];
    }

    return llList2Json(JSON_OBJECT, [
        "shim",            (string)ShimTarget,
        "pin",             (string)ShimPin,
        "scripts",         llDumpList2String(scripts, ","),
        "skip_animations", (string)skip_anim,
        "skip_notecards",  llDumpList2String(skip_nc, ",")
    ]);
}

dispatch_shim_ship(list scripts) {
    Phase = "shim_bundling";
    llSetTimerEvent(BUNDLE_TIMEOUT);
    notice("Installing " + (string)llGetListLength(scripts) + " scripts...");
    llMessageLinked(LINK_SET, LM_INSTALL_SHIM_BEGIN, build_shim_payload(scripts), NULL_KEY);
}

/* -------------------- SHIM MODE PICKER -------------------- */

// Shim mode picker — user-specified layout: Full/Minimal/Back on the
// bottom row, Bespoke alone above. Slots:
//   0: Full, 1: Minimal, 2: Back, 3: Bespoke
show_shim_mode_picker() {
    Phase = "shim_mode_picking";
    open_dialog(Wearer,
        "Fresh install onto new collar prim.\n\n"
      + "Minimal — core + access, blacklist, sos, animate, maint, leash.\n"
      + "Full — every component in the installer.\n"
      + "Bespoke — core + per-subsystem prompt.",
        ["Full", "Minimal", "Back", "Bespoke"]);
}

// Minimal selection — feature labels from the bundler's grouping that
// always ship. Maint is included because plugin_maint owns the updater
// scan/invite flow (remote.updaterscan.start in kmod_remote); without
// it a Minimal collar can never be invited to update again. Status is
// included because plugin_status owns the wearer-facing status UI.
list minimal_feature_labels() {
    return ["Core Components", "Leash Subsystem", "Access", "Blacklist", "Sos", "Animate", "Maint", "Status"];
}

ship_shim_mode(string mode) {
    list scripts = [];
    integer n = features_count();
    integer i = 0;

    if (mode == "full") {
        while (i < n) {
            list parts = llCSV2List(feature_scripts(i));
            scripts += parts;
            i += 1;
        }
    }
    else if (mode == "minimal") {
        list want = minimal_feature_labels();
        while (i < n) {
            if (llListFindList(want, [feature_label(i)]) != -1) {
                list parts = llCSV2List(feature_scripts(i));
                scripts += parts;
            }
            i += 1;
        }
    }

    dispatch_shim_ship(scripts);
}

/* -------------------- BESPOKE WALK (delegated) -------------------- */

// The Bespoke walk lives in the sibling updater_bespoke_ui script. We
// kick it off here with LM_BESPOKE_START and wait for either
// LM_BESPOKE_DONE (with the accumulated script CSV) or LM_BESPOKE_CANCEL.
//
// Split out in rev 10 because keeping the walk inline pushed
// updater_driver past the Mono 65 KB compiled ceiling (104% per
// lslinterpreter). Cross-script LM cost is one round trip per dialog
// answer plus one start/done pair, all within the linkset.
// Fresh-install Bespoke (Empty object path). Hands off to bespoke_ui
// with no existing-mode flag — every subsystem is offered, core ships,
// kmod_rlv ships with any RLV plugin.
start_bespoke() {
    Phase = "shim_bespoke_running";
    string payload = llList2Json(JSON_OBJECT, [
        "wearer", (string)Wearer,
        "shim",   (string)ShimTarget,
        "pin",    (string)ShimPin
    ]);
    llMessageLinked(LINK_SET, LM_BESPOKE_START, payload, NULL_KEY);
    llSetTimerEvent(BUNDLE_TIMEOUT);
}

// Existing-collar Bespoke. Bundler has finished its bundler-MINUS-collar
// diff and handed us the flat missing list — pass it to bespoke_ui with
// existing=1 so the toggle picker filters Displayed* down to subsystems
// where at least one script is actually missing.
start_install_bespoke(string missing_csv) {
    Phase = "install_bespoke_running";
    string payload = llList2Json(JSON_OBJECT, [
        "wearer",   (string)Wearer,
        "existing", "1",
        "missing",  missing_csv
    ]);
    llMessageLinked(LINK_SET, LM_BESPOKE_START, payload, NULL_KEY);
    llSetTimerEvent(BUNDLE_TIMEOUT);
}


/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        llSetObjectDesc(UPDATER_MARKER);
        cleanup_all();

        // Force the sibling bundler to reset alongside us so a stuck
        // Mode != "" from a prior aborted session doesn't silently drop
        // the next LM_*_BEGIN. Without this the driver hangs at
        // "Detecting missing components..." because the bundler's
        // early-return gate eats the request.
        llMessageLinked(LINK_SET, LM_BUNDLE_RESET, "", NULL_KEY);

        // Permanent listener on REPLY_CHAN. In idle, catches
        // remote.updateravailable (update mode invite) and
        // install.shim.ready (fresh-install path).
        ReplyListen = llListen(EXTERNAL_ACL_REPLY_CHAN, "", NULL_KEY, "");
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    touch_start(integer num) {
        key toucher = llDetectedKey(0);
        if (toucher != llGetOwner()) {
            llRegionSayTo(toucher, 0, "Only the owner can run this installer.");
            return;
        }
        if (Phase != "idle") {
            notice("A session is already in progress.");
            return;
        }
        show_main_menu(toucher);
    }

    listen(integer channel, string name, key id, string message) {
        // ---------- DIALOG CHANNEL ----------
        if (DialogChan != 0 && channel == DialogChan) {
            if (id != Wearer) return;

            if (Phase == "main_menu") {
                if (message == "Update Collar") {
                    close_dialog();
                    begin_scan(Wearer, "update");
                    return;
                }
                if (message == "Install Scripts") {
                    show_install_submenu();
                    return;
                }
                if (message == "Cancel") {
                    cancel_and_reset();
                    return;
                }
                return;
            }

            if (Phase == "install_submenu") {
                if (message == "Existing") {
                    close_dialog();
                    begin_scan(Wearer, "install");
                    return;
                }
                if (message == "New") {
                    close_dialog();
                    offer_install_shim();
                    return;
                }
                if (message == "Back") {
                    cancel_and_reset();
                    return;
                }
                return;
            }

            if (Phase == "scan_picking") {
                if (message == "Back") {
                    cancel_and_reset();
                    return;
                }
                integer scan_n = llGetListLength(ScanResults) / 4;
                integer scan_pages = (scan_n + COLLARS_PER_PAGE - 1) / COLLARS_PER_PAGE;
                integer scan_max_page = scan_pages - 1;
                if (scan_max_page < 0) scan_max_page = 0;
                if (message == "<<") {
                    ScanPage = wrap_prev_page(ScanPage, scan_max_page);
                    show_scan_picker();
                    return;
                }
                if (message == ">>") {
                    ScanPage = wrap_next_page(ScanPage, scan_max_page);
                    show_scan_picker();
                    return;
                }
                try_scan_pick(message);
                return;
            }

            // install_picking phase removed in rev 12 — its dialog is
            // now owned by updater_bespoke_ui under the
            // install_bespoke_running phase, dispatched on its own channel.

            if (Phase == "shim_mode_picking") {
                if (message == "Minimal") {
                    close_dialog();
                    ship_shim_mode("minimal");
                    return;
                }
                if (message == "Full") {
                    close_dialog();
                    ship_shim_mode("full");
                    return;
                }
                if (message == "Bespoke") {
                    close_dialog();
                    start_bespoke();
                    return;
                }
                if (message == "Back") {
                    cancel_and_reset();
                    return;
                }
                return;
            }

            // shim_bespoke_iterating dialogs are owned by updater_bespoke_ui;
            // its own listen handles those responses on its own channel.

            return;
        }

        // ---------- EXTERNAL REPLY CHANNEL ----------
        if (channel == EXTERNAL_ACL_REPLY_CHAN) {
            if (llGetOwnerKey(id) != llGetOwner()) return;

            string mtype = llJsonGetValue(message, ["type"]);

            if (mtype == "remote.updateravailable") {
                respond_to_invite(message);
                return;
            }

            if (mtype == "remote.collarready" && Phase == "idle_invited") {
                accept_invitation(message);
                return;
            }

            if (mtype == "remote.collarready" && Phase == "scanning") {
                record_scan_response(message);
                return;
            }

            if (mtype == "install.shim.ready" && Phase == "shim_offer_waiting") {
                handle_shim_ready(message);
                return;
            }

            return;
        }

        // ---------- SECURE CHANNEL (update_shim) ----------
        if (channel == SecureChannel) {
            if (id != CollarKey) return;
            if (message == "READY") {
                if (Phase == "shim_loading") {
                    dispatch_update_bundle();
                    return;
                }
                if (Phase == "install_shim_loading") {
                    dispatch_install_bundle();
                    return;
                }
            }
            return;
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num == LM_BUNDLE_DONE) {
            if (Phase == "bundling") {
                finish_update();
                return;
            }
            if (Phase == "install_bundling") {
                finish_install();
                return;
            }
            if (Phase == "shim_bundling") {
                finish_shim_install();
                return;
            }
            return;
        }

        // updater_bespoke_ui completed its walk. Pull the script CSV out
        // of the payload. Fresh-install path dispatches to bundler via
        // dispatch_shim_ship; existing-collar path forwards as LM_INSTALL_GO
        // to the bundler that's parked in scripts_await.
        if (num == LM_BESPOKE_DONE) {
            string csv = llJsonGetValue(msg, ["scripts"]);
            if (csv == JSON_INVALID) csv = "";
            list scripts = [];
            if (csv != "") scripts = llCSV2List(csv);
            if (Phase == "shim_bespoke_running") {
                dispatch_shim_ship(scripts);
                return;
            }
            if (Phase == "install_bespoke_running") {
                string go_payload = llList2Json(JSON_OBJECT, ["scripts", csv]);
                llMessageLinked(LINK_SET, LM_INSTALL_GO, go_payload, NULL_KEY);
                Phase = "install_bundling";
                llSetTimerEvent(BUNDLE_TIMEOUT);
                if (llGetListLength(scripts) > 0) {
                    notice("Installing selected components...");
                }
                return;
            }
            return;
        }

        // Wearer hit Back during the Bespoke walk (either path). Run the
        // unified cancel path so any active shim is told to disarm and
        // the driver resets cleanly.
        if (num == LM_BESPOKE_CANCEL) {
            if (Phase != "shim_bespoke_running"
             && Phase != "install_bespoke_running") return;
            cancel_and_reset();
            return;
        }

        // Existing-collar install: bundler finished its bundler-MINUS-collar
        // diff. Hand the flat missing list to bespoke_ui as
        // existing-mode input.
        if (num == LM_INSTALL_MISSING) {
            if (Phase != "install_bundling") return;
            string missing_csv = llJsonGetValue(msg, ["missing"]);
            if (missing_csv == JSON_INVALID) missing_csv = "";
            if (missing_csv == "") {
                // Nothing missing on the script side — bundler has
                // already advanced to typed phases for non-scripts.
                // Let the LM_BUNDLE_DONE arrive when those complete.
                notice("Collar already has all available components.");
                return;
            }
            start_install_bespoke(missing_csv);
            return;
        }

        // install_shim Minimal/Full picker path: bundler enumerated all
        // available features so ship_shim_mode can compose Minimal/Full
        // script lists from labels. Bespoke in install_shim mode
        // dispatches via LM_BESPOKE_START directly and never lands here.
        if (num == LM_INSTALL_FEATURES) {
            if (Phase != "shim_features_querying") return;

            string features_json = llJsonGetValue(msg, ["features"]);
            if (features_json == JSON_INVALID) return;
            Features = llJson2List(features_json);

            if (features_count() == 0) {
                notice("Installer has no components to install.");
                finish_shim_install();
                return;
            }
            llSetTimerEvent(DIALOG_TIMEOUT);
            show_shim_mode_picker();
            return;
        }
    }

    timer() {
        llSetTimerEvent(0.0);

        if (Phase == "idle_invited") {
            cleanup_all();
            return;
        }
        if (Phase == "scanning") {
            // Scan window closed. finalize_scan handles 0/1/N cases.
            finalize_scan();
            return;
        }
        if (Phase == "scan_picking") {
            notice("Picker timed out. Cancelling.");
            cleanup_all();
            return;
        }
        if (Phase == "install_submenu") {
            cleanup_all();
            return;
        }
        if (Phase == "shim_loading" || Phase == "install_shim_loading") {
            notice("Shim did not start. The collar may be busy or blocked.");
            cleanup_all();
            return;
        }
        if (Phase == "bundling" || Phase == "install_bundling" || Phase == "shim_bundling") {
            notice("Bundle stalled. Target is in an indeterminate state; reattach the installer to retry.");
            cleanup_all();
            return;
        }
        if (Phase == "shim_mode_picking"
         || Phase == "shim_bespoke_running"
         || Phase == "install_bespoke_running") {
            notice("Dialog timed out. Cancelling.");
            cleanup_all();
            return;
        }
        if (Phase == "shim_offer_waiting") {
            notice("No install_shim detected. Drop install_shim into your target and retry.");
            cleanup_all();
            return;
        }
        if (Phase == "shim_features_querying") {
            notice("Installer enumeration stalled.");
            cleanup_all();
            return;
        }
        if (Phase == "main_menu") {
            cleanup_all();
            return;
        }
    }
}

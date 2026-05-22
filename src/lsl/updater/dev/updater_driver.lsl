/*--------------------
SCRIPT: updater_driver.lsl
VERSION: 1.10
REVISION: 6
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
CHANGES:
- v1.1 rev 6: All three finish_* paths now route through restart_after_operation: 5-second "Please wait, restarting..." notice then llResetScript. Earlier llSleep(2.0) + cleanup_all left stale state visible to queued touch events, producing repeated "session already in progress" errors after completion. Hard reset wipes Phase and listeners cleanly.
- v1.1 rev 5: Replace first-responder-wins discovery with scan-and-pick. Touch-initiated update/install paths now collect every remote.collarready for SCAN_WINDOW (5s), then auto-proceed if exactly one collar responded or show a picker dialog otherwise. Picker label is the collar object name (single-wearer case) or 'Wearer: Object name' (multi-wearer), clipped to the 24-char dialog limit. Invite-path collar handshake is untouched — it's already point-to-point and doesn't need scanning. handle_collar_ready removed; touch flow routes through record_scan_response + finalize_scan.
- v1.1 rev 4: Make the install fork explicit. Picking 'Install Scripts' now opens a sub-menu [Existing collar / Empty object / Cancel] instead of auto-branching on discovery success/failure. Discovery-based branching pre-empted the install_shim path whenever the wearer's collar was in range, so 'Empty object' fresh-installs were silently impossible. Existing-collar timeout no longer falls back to install_shim — the wearer chose that path explicitly, so surface the timeout and let them re-touch.
- v1.1 rev 3: Add Install Scripts path. Top-level touch menu forks update vs install; install discovers, then either runs a multi-select feature picker against a discovered collar or hands the wearer install_shim for fresh-install onto an empty target (Minimal / Full / Bespoke). Bespoke walks features sequentially with Yes/No prompts. Pagination at 9 features per page.
- v1.1 rev 2: Drop multi-bundle iteration.
- v1.1 rev 1: Add collar-driven invitation entry.
- v1.1 rev 0: Initial implementation.
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


/* -------------------- CONSTANTS -------------------- */
// Object description marker; every collar script's dormancy guard parks
// itself if found, so dragged-in scripts stay off in the installer's
// inventory until shipped to the collar.
string UPDATER_MARKER = "COLLAR_UPDATER";

// Version this installer ships. Shown to the wearer at completion.
string BUILD_VERSION = "1.1";

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

// Pagination.
integer FEATURES_PER_PAGE = 9;
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
//   install_picking            — multi-select feature dialog open
//   install_bundling           — install bundler shipping
//   shim_offer_waiting         — gave install_shim, waiting for ready broadcast
//   shim_features_querying     — bundler enumerating features for shim mode
//   shim_mode_picking          — Minimal/Full/Bespoke dialog open
//   shim_bespoke_iterating     — sequential per-feature Yes/No dialog
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

// Multi-select picker state.
integer DialogChan = 0;
integer DialogListen = 0;
list    Selected = [];           // parallel-to-features booleans (integers)
integer PickerPage = 0;

// install_shim flow state.
key     ShimTarget = NULL_KEY;   // the prim hosting install_shim
integer ShimPin = 0;

// Bespoke iteration state.
integer BespokeIdx = 0;
list    BespokeShip = [];        // accumulating script names to ship

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
    Selected = [];
    PickerPage = 0;
    ShimTarget = NULL_KEY;
    ShimPin = 0;
    BespokeIdx = 0;
    BespokeShip = [];
    ScanResults = [];
    ScanNextAction = "";
    ScanPage = 0;
}

notice(string s) {
    if (Wearer != NULL_KEY) llRegionSayTo(Wearer, 0, s);
    else llOwnerSay(s);
}

// Pad a button list to a multiple of 3 with single-space fillers.
list pad_buttons(list buttons) {
    integer n = llGetListLength(buttons);
    while ((n % 3) != 0) {
        buttons += " ";
        n += 1;
    }
    return buttons;
}

// Open a dialog with a fresh channel and listen. Caller sets Phase next.
open_dialog(key who, string body, list buttons) {
    if (DialogListen) llListenRemove(DialogListen);
    DialogChan = random_channel();
    DialogListen = llListen(DialogChan, "", who, "");
    llDialog(who, body, pad_buttons(buttons), DialogChan);
    llSetTimerEvent(DIALOG_TIMEOUT);
}


/* -------------------- TOP-LEVEL MENU -------------------- */

show_main_menu(key who) {
    Wearer = who;
    Phase = "main_menu";
    open_dialog(who,
        "D/s Collar installer.\n\n"
      + "Update Collar — refresh an existing collar.\n"
      + "Install Scripts — install missing components, or fresh-install onto an empty object.",
        ["Update Collar", "Install Scripts", "Cancel"]);
}

// Sub-menu shown when wearer picks "Install Scripts" from the main menu.
// Forks explicitly between the two install paths — discovery-based
// branching was ambiguous because a worn collar would always be found
// and pre-empt the install_shim path even when the wearer wanted a
// fresh install onto a new prim.
show_install_submenu() {
    Phase = "install_submenu";
    open_dialog(Wearer,
        "Install target:\n\n"
      + "Existing collar — discover your worn collar and install missing components.\n"
      + "Empty object — receive install_shim, drop it into a fresh prim, then pick a profile.",
        ["Existing collar", "Empty object", "Cancel"]);
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

// Render the scan picker. Buttons are just (Cancel, [Prev|Next if multi-
// page], collar labels...), padded to a multiple of 3 for layout
// cosmetics — no fixed-width slot reservation, so a 2-collar picker
// shows ~3 buttons total rather than 12 with a wall of " " fillers.
show_scan_picker() {
    integer n = llGetListLength(ScanResults) / 4;
    integer pages = (n + COLLARS_PER_PAGE - 1) / COLLARS_PER_PAGE;
    if (pages < 1) pages = 1;

    integer multi = scan_has_multiple_wearers();
    integer start = ScanPage * COLLARS_PER_PAGE;
    integer stop = start + COLLARS_PER_PAGE;
    if (stop > n) stop = n;

    list buttons = ["Cancel"];
    if (pages > 1) {
        if (ScanPage == 0) buttons += ["Next >"];
        else buttons += ["< Prev"];
    }
    integer i = start;
    while (i < stop) {
        buttons += [scan_label_for(i, multi)];
        i += 1;
    }

    string body = "Pick a collar to ";
    if (ScanNextAction == "install") body += "install into";
    else body += "update";
    body += ":\n\n";
    if (pages > 1) body += "Page " + (string)(ScanPage + 1) + " of " + (string)pages + "\n";

    if (DialogListen) llListenRemove(DialogListen);
    DialogChan = random_channel();
    DialogListen = llListen(DialogChan, "", Wearer, "");
    llDialog(Wearer, body, pad_buttons(buttons), DialogChan);
    llSetTimerEvent(DIALOG_TIMEOUT);
}

// Look up which scan result a label corresponds to and proceed with the
// chosen collar. Returns TRUE on match, FALSE if label didn't match any
// known collar (so the caller can handle nav/cancel buttons).
integer try_scan_pick(string label) {
    integer multi = scan_has_multiple_wearers();
    integer n = llGetListLength(ScanResults) / 4;
    integer i = 0;
    while (i < n) {
        if (scan_label_for(i, multi) == label) {
            CollarKey = (key)llList2String(ScanResults, i * 4);
            CollarPin = (integer)llList2String(ScanResults, i * 4 + 1);
            if (DialogListen) llListenRemove(DialogListen);
            DialogListen = 0;
            DialogChan = 0;
            string next = "shim_loading";
            if (ScanNextAction == "install") next = "install_shim_loading";
            load_shim(next);
            return TRUE;
        }
        i += 1;
    }
    return FALSE;
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

finish_update() {
    llWhisper(SecureChannel, "DONE");
    notice("Update complete. Collar is now at version " + BUILD_VERSION + ".");
    restart_after_operation();
}

finish_install() {
    llWhisper(SecureChannel, "DONE");
    notice("Install complete. Selected components are now in the collar.");
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
    notice("Fresh install complete. Wear or rez the target to bring it online.");
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

// Render the picker for the current page. Each feature button is prefixed
// "[X] " or "[ ] " to show toggle state. Nav row at the bottom.
show_picker() {
    integer n = features_count();
    integer pages = (n + FEATURES_PER_PAGE - 1) / FEATURES_PER_PAGE;
    if (pages < 1) pages = 1;

    integer start = PickerPage * FEATURES_PER_PAGE;
    integer stop = start + FEATURES_PER_PAGE;
    if (stop > n) stop = n;

    list buttons = [];
    integer i = start;
    while (i < stop) {
        string prefix = "[ ] ";
        if (llList2Integer(Selected, i)) prefix = "[X] ";
        buttons += [prefix + feature_label(i)];
        i += 1;
    }
    // Pad page slots to keep nav row stable across pages.
    integer slots_on_page = stop - start;
    while (slots_on_page < FEATURES_PER_PAGE) {
        buttons += [" "];
        slots_on_page += 1;
    }
    // Nav row (cells 0/1/2 by dialog convention: bottom-left → bottom-right).
    string nav3 = " ";
    if (pages > 1) {
        if (PickerPage == 0) nav3 = "Next >";
        else nav3 = "< Prev";
    }
    buttons += ["Cancel", "Confirm", nav3];

    string body = "Select components to install:\n\n";
    if (pages > 1) {
        body += "Page " + (string)(PickerPage + 1) + " of " + (string)pages + "\n\n";
    }
    body += "[X] = will install, [ ] = skip. Tap a feature to toggle.";

    if (DialogListen) llListenRemove(DialogListen);
    DialogChan = random_channel();
    DialogListen = llListen(DialogChan, "", Wearer, "");
    llDialog(Wearer, body, buttons, DialogChan);
    llSetTimerEvent(DIALOG_TIMEOUT);
}

// Match a button press back to a feature index for the current page.
// Returns -1 if no match.
integer match_picker_button(string btn) {
    integer n = features_count();
    integer start = PickerPage * FEATURES_PER_PAGE;
    integer stop = start + FEATURES_PER_PAGE;
    if (stop > n) stop = n;
    integer i = start;
    while (i < stop) {
        if (btn == "[ ] " + feature_label(i)) return i;
        if (btn == "[X] " + feature_label(i)) return i;
        i += 1;
    }
    return -1;
}

handle_picker_button(string btn) {
    if (btn == "Cancel") {
        notice("Install cancelled.");
        // Bundler is parked in scripts_await — abort by sending DONE-ish.
        // Cleanest: send an empty LM_INSTALL_GO so bundler advances past
        // the scripts phase with nothing to ship, then completes non-script
        // phases (which will also be empty if collar already has the
        // non-scripts) and emits LM_BUNDLE_DONE.
        string payload = llList2Json(JSON_OBJECT, ["scripts", ""]);
        llMessageLinked(LINK_SET, LM_INSTALL_GO, payload, NULL_KEY);
        // Bundler will eventually emit LM_BUNDLE_DONE → finish_install.
        return;
    }
    if (btn == "Confirm") {
        // Collect selected scripts across all features.
        list ship = [];
        integer i = 0;
        integer n = features_count();
        while (i < n) {
            if (llList2Integer(Selected, i)) {
                list parts = llCSV2List(feature_scripts(i));
                ship += parts;
            }
            i += 1;
        }
        string csv = llDumpList2String(ship, ",");
        string payload = llList2Json(JSON_OBJECT, ["scripts", csv]);
        llMessageLinked(LINK_SET, LM_INSTALL_GO, payload, NULL_KEY);
        Phase = "install_bundling";
        llSetTimerEvent(BUNDLE_TIMEOUT);
        if (llGetListLength(ship) > 0) notice("Installing selected components...");
        return;
    }
    if (btn == "Next >") {
        PickerPage += 1;
        show_picker();
        return;
    }
    if (btn == "< Prev") {
        PickerPage -= 1;
        if (PickerPage < 0) PickerPage = 0;
        show_picker();
        return;
    }
    integer idx = match_picker_button(btn);
    if (idx >= 0) {
        integer cur = llList2Integer(Selected, idx);
        Selected = llListReplaceList(Selected, [!cur], idx, idx);
        show_picker();
    }
}


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

show_shim_mode_picker() {
    Phase = "shim_mode_picking";
    open_dialog(Wearer,
        "Fresh install onto empty target.\n\n"
      + "Minimal — core + access, blacklist, sos, animate, leash.\n"
      + "Full — every component in the installer.\n"
      + "Bespoke — core + per-component prompt.",
        ["Minimal", "Full", "Bespoke", "Cancel"]);
}

// Minimal selection in install_shim mode. These features are always
// shipped (if the bundler reported them). Anything else is skipped.
// Maint is included because plugin_maint owns the updater scan/invite
// flow (remote.updaterscan.start in kmod_remote); without it a Minimal
// collar can never be invited to update again.
list minimal_feature_labels() {
    return ["Core Components", "Leash Subsystem", "Access", "Blacklist", "Sos", "Animate", "Maint"];
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

    string payload = llList2Json(JSON_OBJECT, [
        "shim",    (string)ShimTarget,
        "pin",     (string)ShimPin,
        "scripts", llDumpList2String(scripts, ",")
    ]);
    Phase = "shim_bundling";
    llSetTimerEvent(BUNDLE_TIMEOUT);
    notice("Installing " + (string)llGetListLength(scripts) + " scripts...");
    llMessageLinked(LINK_SET, LM_INSTALL_SHIM_BEGIN, payload, NULL_KEY);
}

start_bespoke() {
    // Pre-seed with Core Components (always shipped in Bespoke mode).
    BespokeShip = [];
    integer n = features_count();
    integer i = 0;
    while (i < n) {
        if (feature_label(i) == "Core Components") {
            BespokeShip += llCSV2List(feature_scripts(i));
        }
        i += 1;
    }
    BespokeIdx = 0;
    next_bespoke_prompt();
}

next_bespoke_prompt() {
    integer n = features_count();
    // Skip Core Components (already added) and advance to next askable feature.
    while (BespokeIdx < n && feature_label(BespokeIdx) == "Core Components") {
        BespokeIdx += 1;
    }
    if (BespokeIdx >= n) {
        // Done iterating — ship.
        string payload = llList2Json(JSON_OBJECT, [
            "shim",    (string)ShimTarget,
            "pin",     (string)ShimPin,
            "scripts", llDumpList2String(BespokeShip, ",")
        ]);
        Phase = "shim_bundling";
        llSetTimerEvent(BUNDLE_TIMEOUT);
        notice("Installing " + (string)llGetListLength(BespokeShip) + " scripts...");
        llMessageLinked(LINK_SET, LM_INSTALL_SHIM_BEGIN, payload, NULL_KEY);
        return;
    }

    Phase = "shim_bespoke_iterating";
    string label = feature_label(BespokeIdx);
    open_dialog(Wearer,
        "Install component: " + label + "?",
        ["Yes", "No", "Cancel"]);
}

handle_bespoke_answer(string btn) {
    if (btn == "Cancel") {
        notice("Install cancelled.");
        finish_shim_install();
        return;
    }
    if (btn == "Yes") {
        BespokeShip += llCSV2List(feature_scripts(BespokeIdx));
    }
    BespokeIdx += 1;
    next_bespoke_prompt();
}


/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        llSetObjectDesc(UPDATER_MARKER);
        cleanup_all();

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
                    if (DialogListen) llListenRemove(DialogListen);
                    DialogListen = 0;
                    DialogChan = 0;
                    begin_scan(Wearer, "update");
                    return;
                }
                if (message == "Install Scripts") {
                    show_install_submenu();
                    return;
                }
                if (message == "Cancel") {
                    cleanup_all();
                    return;
                }
                return;
            }

            if (Phase == "install_submenu") {
                if (message == "Existing collar") {
                    if (DialogListen) llListenRemove(DialogListen);
                    DialogListen = 0;
                    DialogChan = 0;
                    begin_scan(Wearer, "install");
                    return;
                }
                if (message == "Empty object") {
                    if (DialogListen) llListenRemove(DialogListen);
                    DialogListen = 0;
                    DialogChan = 0;
                    offer_install_shim();
                    return;
                }
                if (message == "Cancel") {
                    cleanup_all();
                    return;
                }
                return;
            }

            if (Phase == "scan_picking") {
                if (message == "Cancel") {
                    notice("Cancelled.");
                    cleanup_all();
                    return;
                }
                if (message == "Next >") {
                    ScanPage += 1;
                    show_scan_picker();
                    return;
                }
                if (message == "< Prev") {
                    ScanPage -= 1;
                    if (ScanPage < 0) ScanPage = 0;
                    show_scan_picker();
                    return;
                }
                try_scan_pick(message);
                return;
            }

            if (Phase == "install_picking") {
                handle_picker_button(message);
                return;
            }

            if (Phase == "shim_mode_picking") {
                if (message == "Minimal") {
                    if (DialogListen) llListenRemove(DialogListen);
                    DialogListen = 0;
                    DialogChan = 0;
                    ship_shim_mode("minimal");
                    return;
                }
                if (message == "Full") {
                    if (DialogListen) llListenRemove(DialogListen);
                    DialogListen = 0;
                    DialogChan = 0;
                    ship_shim_mode("full");
                    return;
                }
                if (message == "Bespoke") {
                    if (DialogListen) llListenRemove(DialogListen);
                    DialogListen = 0;
                    DialogChan = 0;
                    start_bespoke();
                    return;
                }
                if (message == "Cancel") {
                    notice("Install cancelled.");
                    finish_shim_install();
                    return;
                }
                return;
            }

            if (Phase == "shim_bespoke_iterating") {
                handle_bespoke_answer(message);
                return;
            }

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

        if (num == LM_INSTALL_FEATURES) {
            string features_json = llJsonGetValue(msg, ["features"]);
            if (features_json == JSON_INVALID) return;

            // Parse stride-2 JSON array into our flat Features list.
            list parsed = llJson2List(features_json);
            Features = parsed;

            integer n = features_count();
            if (n == 0) {
                if (Phase == "install_bundling" || Phase == "install_picking") {
                    // Already-current — bundler will advance through non-scripts.
                    notice("Collar already has all available components.");
                }
                if (Phase == "shim_features_querying") {
                    notice("Installer has no components to install.");
                    finish_shim_install();
                    return;
                }
                return;
            }

            // Initialize Selected with all on (sensible default; wearer
            // unticks unwanted features).
            Selected = [];
            integer i = 0;
            while (i < n) {
                Selected += [TRUE];
                i += 1;
            }
            PickerPage = 0;

            if (Phase == "shim_features_querying") {
                llSetTimerEvent(DIALOG_TIMEOUT);
                show_shim_mode_picker();
                return;
            }

            // Otherwise we're install_bundling (came from LM_INSTALL_BEGIN).
            Phase = "install_picking";
            llSetTimerEvent(DIALOG_TIMEOUT);
            show_picker();
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
        if (Phase == "install_picking"
         || Phase == "shim_mode_picking"
         || Phase == "shim_bespoke_iterating") {
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

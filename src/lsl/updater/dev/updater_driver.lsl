/*--------------------
SCRIPT: updater_driver.lsl
VERSION: 1.10
REVISION: 3
PURPOSE: Installer-side orchestrator. Wearer touches the installer prim;
  top-level menu offers two paths:
    UPDATE COLLAR — broadcasts remote.updatediscover, deposits update_shim
      via llRemoteLoadScriptPin, signals the bundler for an intersection
      refresh pass (existing flow).
    INSTALL SCRIPTS — discovery as above; on success the bundler reports a
      feature list (bundler-MINUS-collar, grouped), the driver shows a
      multi-select picker, and the bundler ships the wearer's selection.
      On discovery failure, the driver hands the wearer an install_shim,
      waits for its ready broadcast from the empty target, then offers
      Minimal / Full / Bespoke install modes.
ARCHITECTURE: Lives in the installer linkset root. Sibling updater_bundler
  runs in a child prim and holds the staged collar scripts. Chat protocol
  with collar uses kmod_remote's EXTERNAL_ACL_QUERY_CHAN / REPLY_CHAN; chat
  protocol with shim uses a random per-session secure channel passed as
  llRemoteLoadScriptPin's start_param. Dialog channels are per-session
  random negative ints.
CHANGES:
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
float DISCOVERY_TIMEOUT   = 10.0;
float SHIM_READY_TIMEOUT  = 15.0;
float BUNDLE_TIMEOUT      = 240.0;
float INVITE_TIMEOUT      = 60.0;
float DIALOG_TIMEOUT      = 120.0;   // wearer has 2 min to answer a dialog
float SHIM_OFFER_TIMEOUT  = 180.0;   // 3 min from give to install.shim.ready

// Pagination.
integer FEATURES_PER_PAGE = 9;


/* -------------------- STATE -------------------- */
// Phase names reflect what we're currently waiting on.
//   idle                       — no session in progress
//   idle_invited               — answered remote.updateravailable
//   discovering                — update mode discovery
//   shim_loading               — update shim being deposited
//   bundling                   — update bundler running
//   done                       — update applied
//   install_discovering        — install mode discovery (collar present case)
//   install_shim_loading       — install mode, update_shim being loaded
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


/* -------------------- UPDATE FLOW (existing) -------------------- */

begin_discovery(key toucher) {
    Wearer = toucher;
    Phase = "discovering";
    Session = new_session();

    string msg = llList2Json(JSON_OBJECT, [
        "type",    "remote.updatediscover",
        "updater", (string)llGetKey(),
        "session", Session
    ]);
    llRegionSay(EXTERNAL_ACL_QUERY_CHAN, msg);

    llSetTimerEvent(DISCOVERY_TIMEOUT);
    notice("Searching for collar...");
}

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

handle_collar_ready(string msg) {
    string sess = llJsonGetValue(msg, ["session"]);
    if (sess == JSON_INVALID) return;
    if (sess != Session) return;

    if (llJsonGetValue(msg, ["collar"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["pin"]) == JSON_INVALID) return;

    CollarKey = (key)llJsonGetValue(msg, ["collar"]);
    CollarPin = (integer)llJsonGetValue(msg, ["pin"]);

    if (llGetOwnerKey(CollarKey) != llGetOwner()) {
        notice("Collar is owned by a different avatar. Aborting.");
        cleanup_all();
        return;
    }

    // Branch into the correct shim_loading phase based on which discovery
    // initiated this. install_discovering → install_shim_loading; otherwise
    // update mode.
    if (Phase == "install_discovering") load_shim("install_shim_loading");
    else load_shim("shim_loading");
}

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

finish_update() {
    llWhisper(SecureChannel, "DONE");
    Phase = "done";
    llSetTimerEvent(0.0);
    notice("Update complete. Collar is now at version " + BUILD_VERSION + ".");
    llSleep(2.0);
    cleanup_all();
}

finish_install() {
    llWhisper(SecureChannel, "DONE");
    Phase = "done";
    llSetTimerEvent(0.0);
    notice("Install complete. Selected components are now in the collar.");
    llSleep(2.0);
    cleanup_all();
}

finish_shim_install() {
    // Tell install_shim to disarm PIN and self-delete.
    string msg = llList2Json(JSON_OBJECT, [
        "type", "install.shim.done",
        "shim", (string)ShimTarget
    ]);
    llRegionSay(EXTERNAL_ACL_QUERY_CHAN, msg);
    Phase = "done";
    llSetTimerEvent(0.0);
    notice("Fresh install complete. Wear or rez the target to bring it online.");
    llSleep(2.0);
    cleanup_all();
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
list minimal_feature_labels() {
    return ["Core Components", "Leash Subsystem", "Access", "Blacklist", "Sos", "Animate"];
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
                    begin_discovery(Wearer);
                    return;
                }
                if (message == "Install Scripts") {
                    if (DialogListen) llListenRemove(DialogListen);
                    DialogListen = 0;
                    DialogChan = 0;
                    Phase = "install_discovering";
                    Session = new_session();
                    string msg = llList2Json(JSON_OBJECT, [
                        "type",    "remote.updatediscover",
                        "updater", (string)llGetKey(),
                        "session", Session
                    ]);
                    llRegionSay(EXTERNAL_ACL_QUERY_CHAN, msg);
                    llSetTimerEvent(DISCOVERY_TIMEOUT);
                    notice("Searching for collar...");
                    return;
                }
                if (message == "Cancel") {
                    cleanup_all();
                    return;
                }
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

            if (mtype == "remote.collarready"
             && (Phase == "discovering" || Phase == "install_discovering")) {
                handle_collar_ready(message);
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
        if (Phase == "discovering") {
            notice("No collar responded. Make sure your collar is worn and you are within 20 meters.");
            cleanup_all();
            return;
        }
        if (Phase == "install_discovering") {
            // Discovery failed → offer install_shim for fresh-install path.
            offer_install_shim();
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

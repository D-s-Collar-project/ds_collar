/*--------------------
SCRIPT: updater_driver.lsl
VERSION: 1.10
REVISION: 2
PURPOSE: Installer-side orchestrator. Wearer touches the installer prim;
  driver broadcasts remote.updatediscover on kmod_remote's well-known
  external channel, receives the collar's PIN + session via remote.collarready,
  deposits update_shim via llRemoteLoadScriptPin, then signals the bundler
  (child prim) to run a single inventory-driven update pass.
ARCHITECTURE: Lives in the installer linkset root. Sibling updater_bundler
  runs in a child prim and holds the staged collar scripts. Chat protocol
  with collar uses kmod_remote's EXTERNAL_ACL_QUERY_CHAN / REPLY_CHAN; chat
  protocol with shim uses a random per-session secure channel passed as
  llRemoteLoadScriptPin's start_param.
CHANGES:
- v1.1 rev 2: Drop multi-bundle iteration. Bundler is invoked once and
  diffs its inventory against the collar's; no Bundles list, no BundleIdx,
  no per-bundle notice. Bundle payload to bundler no longer carries a
  bundle name. Single LM_BUNDLE_DONE ends the update.
- v1.1 rev 1: Add collar-driven invitation entry. Permanent listener on
  REPLY_CHAN; in Phase=idle, remote.updateravailable triggers a
  remote.updaterhere reply on QUERY_CHAN and we cache session/collar/wearer.
- v1.1 rev 0: Initial implementation.
--------------------*/


/* -------------------- EXTERNAL PROTOCOL CHANNELS -------------------- */
// Must match kmod_remote's EXTERNAL_ACL_QUERY_CHAN / EXTERNAL_ACL_REPLY_CHAN.
integer EXTERNAL_ACL_QUERY_CHAN = -8675309;
integer EXTERNAL_ACL_REPLY_CHAN = -8675310;


/* -------------------- LINK-MESSAGE NUMBERS -------------------- */
// Driver → bundler: begin update pass.
integer LM_BUNDLE_BEGIN = 91001;
// Bundler → driver: pass complete (or empty).
integer LM_BUNDLE_DONE  = 91002;


/* -------------------- CONSTANTS -------------------- */
// Object description marker. Every collar script's dormancy guard checks
// for this and parks itself if found — that's how dragged-in scripts stay
// off in the installer's inventory until they're shipped to the collar.
string UPDATER_MARKER = "COLLAR_UPDATER";

// Version this installer ships. Shown to the wearer at completion.
string BUILD_VERSION = "1.1";

// Name of the payload script to deposit into the collar. Must exist in
// THIS prim's inventory so llRemoteLoadScriptPin can find it.
string SHIM_SCRIPT = "update_shim";

// Timeouts.
float DISCOVERY_TIMEOUT = 10.0;    // wait for remote.collarready
float SHIM_READY_TIMEOUT = 15.0;   // wait for READY from shim after load
float BUNDLE_TIMEOUT = 240.0;      // wait for the bundler pass to finish
float INVITE_TIMEOUT = 60.0;       // wait for collar's confirm after we replied to invite


/* -------------------- STATE -------------------- */
// Phase names reflect what we're currently waiting on.
//   idle           — no update in progress
//   idle_invited   — answered remote.updateravailable, waiting for collar's
//                    confirm (delivered as remote.collarready with PIN)
//   discovering    — we touched and broadcast remote.updatediscover, waiting for reply
//   shim_loading   — shim has been deposited, waiting for READY whisper
//   bundling       — bundler is running its inventory diff
//   done           — update applied
string Phase = "idle";

key CollarKey = NULL_KEY;
integer CollarPin = 0;
string  Session = "";
integer SecureChannel = 0;

integer ReplyListen = 0;   // permanent listen on EXTERNAL_ACL_REPLY_CHAN
integer SecureListen = 0;  // listen on SecureChannel

key Wearer = NULL_KEY;   // who rezzed / touched / was named in invite

// Cached invitation context. Populated when we answer remote.updateravailable;
// validated against the subsequent remote.collarready before we accept.
string  InviteSession = "";
key     InviteCollar = NULL_KEY;


/* -------------------- HELPERS -------------------- */

string new_session() {
    return "upd_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
}

integer random_channel() {
    // Random negative non-zero 31-bit int. Passed to shim via start_param
    // so both ends know where to talk.
    integer n = -((integer)llFrand(2147483600.0) + 1);
    return n;
}

// Closes the per-session secure listen but leaves the permanent REPLY_CHAN
// listen alone — that one is needed even in Phase=idle so we can answer
// future remote.updateravailable invitations.
cleanup_listens() {
    if (SecureListen) llListenRemove(SecureListen);
    SecureListen = 0;
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
}

notice(string s) {
    if (Wearer != NULL_KEY) llRegionSayTo(Wearer, 0, s);
    else llOwnerSay(s);
}


/* -------------------- DISCOVERY -------------------- */

begin_discovery(key toucher) {
    if (Phase != "idle") {
        notice("An update is already in progress.");
        return;
    }

    Wearer = toucher;
    Phase = "discovering";
    Session = new_session();

    // ReplyListen stays open permanently from state_entry; no re-open here.

    string msg = llList2Json(JSON_OBJECT, [
        "type",    "remote.updatediscover",
        "updater", (string)llGetKey(),
        "session", Session
    ]);
    llRegionSay(EXTERNAL_ACL_QUERY_CHAN, msg);

    llSetTimerEvent(DISCOVERY_TIMEOUT);
    notice("Searching for collar...");
}

// Collar broadcast remote.updateravailable. If we're idle and same-owner,
// reply on QUERY_CHAN with our key + version + session, and wait for the
// collar's confirm path to send remote.collarready directly to us.
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

    // Same-owner gate. SL's llRemoteLoadScriptPin requires identical owner
    // anyway; surfacing the rejection here is just cleaner.
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

// Collar's confirm path: remote.collarready sent directly to us with PIN.
// Validate session + collar identity, then jump straight to load_shim.
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
    load_shim();
}

handle_collar_ready(string msg) {
    // Session must match — ignore any stray collarready from another update
    // attempt in the same sim.
    string sess = llJsonGetValue(msg, ["session"]);
    if (sess == JSON_INVALID) return;
    if (sess != Session) return;

    if (llJsonGetValue(msg, ["collar"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["pin"]) == JSON_INVALID) return;

    CollarKey = (key)llJsonGetValue(msg, ["collar"]);
    CollarPin = (integer)llJsonGetValue(msg, ["pin"]);

    // Reject if the collar isn't owned by the same avatar as this installer.
    // llRemoteLoadScriptPin enforces this too, but catching it here gives a
    // cleaner error message than a silent platform-level failure.
    if (llGetOwnerKey(CollarKey) != llGetOwner()) {
        notice("Collar is owned by a different avatar. Aborting.");
        cleanup_all();
        return;
    }

    load_shim();
}

load_shim() {
    if (llGetInventoryType(SHIM_SCRIPT) != INVENTORY_SCRIPT) {
        notice("Installer is missing " + SHIM_SCRIPT + "; cannot proceed.");
        cleanup_all();
        return;
    }

    Phase = "shim_loading";
    SecureChannel = random_channel();

    // Start listening on the secure channel BEFORE we send the shim so we
    // don't miss its READY whisper.
    SecureListen = llListen(SecureChannel, "", CollarKey, "");

    // This call sleeps 3s. The shim arrives in the collar, starts running
    // (running=TRUE), reads start_param, and whispers READY on SecureChannel.
    llRemoteLoadScriptPin(CollarKey, SHIM_SCRIPT, CollarPin, TRUE, SecureChannel);

    llSetTimerEvent(SHIM_READY_TIMEOUT);
    notice("Installing update shim...");
}


/* -------------------- BUNDLE DISPATCH -------------------- */

dispatch_bundle() {
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

finish_update() {
    // Tell the shim we're done. Shim self-deletes and disarms the PIN.
    llWhisper(SecureChannel, "DONE");
    Phase = "done";
    llSetTimerEvent(0.0);
    notice("Update complete. Collar is now at version " + BUILD_VERSION + ".");
    // Give the shim a moment to self-delete and the collar to stabilise.
    llSleep(2.0);
    cleanup_all();
}


/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        // Stamp the prim description so every dragged-in collar script's
        // dormancy guard parks it. Every prim in the installer linkset that
        // holds stagable scripts should carry this marker.
        llSetObjectDesc(UPDATER_MARKER);
        cleanup_all();

        // Permanent listener on REPLY_CHAN: needed in idle to catch
        // remote.updateravailable invitations, and during the touch-driven
        // flow to catch remote.collarready replies to our own discover.
        // NULL_KEY rather than "" so the implicit string→key cast is
        // explicit; the open-filter aspect is intentional (sender unknown).
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
        begin_discovery(toucher);
    }

    listen(integer channel, string name, key id, string message) {
        if (channel == EXTERNAL_ACL_REPLY_CHAN) {
            // Same-owner filter — kmod_remote is the only legitimate sender.
            if (llGetOwnerKey(id) != llGetOwner()) return;

            string mtype = llJsonGetValue(message, ["type"]);

            // Collar broadcasting an open invitation.
            if (mtype == "remote.updateravailable") {
                respond_to_invite(message);
                return;
            }

            // Confirm of an invitation we answered earlier.
            if (mtype == "remote.collarready" && Phase == "idle_invited") {
                accept_invitation(message);
                return;
            }

            // Reply to our own discover broadcast (touch-driven flow).
            if (mtype == "remote.collarready" && Phase == "discovering") {
                handle_collar_ready(message);
                return;
            }

            return;
        }

        if (channel == SecureChannel) {
            if (id != CollarKey) return;
            if (message == "READY") {
                if (Phase != "shim_loading") return;
                // Shim is listening. Hand off to the bundler.
                dispatch_bundle();
            }
            return;
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num != LM_BUNDLE_DONE) return;
        if (Phase != "bundling") return;
        finish_update();
    }

    timer() {
        llSetTimerEvent(0.0);
        if (Phase == "idle_invited") {
            // Collar's wearer probably cancelled at the confirm dialog, or
            // the confirm path stalled. Drop quietly back to idle so we can
            // answer the next invitation.
            cleanup_all();
            return;
        }
        if (Phase == "discovering") {
            notice("No collar responded. Make sure your collar is worn and you are within 20 meters.");
            cleanup_all();
            return;
        }
        if (Phase == "shim_loading") {
            notice("Shim did not start. The collar may be busy or blocked.");
            cleanup_all();
            return;
        }
        if (Phase == "bundling") {
            notice("Update stalled. Collar is in an indeterminate state; reattach the installer to retry.");
            cleanup_all();
            return;
        }
    }
}

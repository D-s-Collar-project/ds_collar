/*--------------------
SCRIPT: updater_bundler.lsl
VERSION: 1.10
REVISION: 1
PURPOSE: Installer child-prim script. Holds the staged collar scripts in
  its own inventory. On LM_BUNDLE_BEGIN from updater_driver, reads the
  named bundle notecard one line at a time, asks update_shim (running in
  the collar) whether each named script is already current, and for each
  GIVE response calls llRemoteLoadScriptPin to deposit the new version.
ARCHITECTURE: Lives in a child prim of the installer linkset. Sibling
  updater_driver runs in the root prim. Chat protocol with the shim uses
  the per-session secure channel passed in LM_BUNDLE_BEGIN. Scripts to be
  transferred must exist in THIS prim's inventory — llRemoteLoadScriptPin
  can only send items from the calling script's own prim.
CHANGES:
- v1.1 rev 1: Add CONDITIONAL bundle mode. Bundle whose name contains
  "CONDITIONAL" ships items only if the collar already has them; lets us
  preserve the wearer's installed-plugin set rather than force-installing
  every plugin in our bundle. Per-line optional 3rd field carries a gate
  script name (for paired kmods like kmod_leash gated on plugin_leash) so
  the kmod ships when the gating plugin is present even if the kmod
  itself was lost. Protocol extended:
    QUERY|SCRIPT|<name>|<uuid>|<mode>[|<gate>]
  Notecard line: SCRIPT|<name>[|<gate>]   (gate only meaningful in CONDITIONAL).
- v1.1 rev 0: Initial implementation. Single-bundle loop with dataserver
  line-reading and per-script shim handshake. Returns LM_BUNDLE_DONE to
  the driver when the notecard is exhausted; driver iterates across
  multiple bundles.
--------------------*/


/* -------------------- LINK-MESSAGE NUMBERS -------------------- */
// Must match updater_driver.
integer LM_BUNDLE_BEGIN = 91001;
integer LM_BUNDLE_DONE  = 91002;


/* -------------------- CONSTANTS -------------------- */
// Object description marker. Dormancy guard in every collar script checks
// for this — any script dragged into this prim's inventory parks itself
// instead of trying to run here.
string UPDATER_MARKER = "COLLAR_UPDATER";


/* -------------------- STATE -------------------- */
// Per-bundle context, populated from LM_BUNDLE_BEGIN and cleared on DONE.
string  BundleName = "";
key     CollarKey = NULL_KEY;
integer CollarPin = 0;
integer SecureChannel = 0;
string  BundleMode = "";   // REQUIRED or DEPRECATED — derived from name

// Notecard reader.
integer LineIdx = 0;
key     LineRequest = NULL_KEY;

// Current query in flight. While this is non-empty we are awaiting a
// REPLY|<name>|<verdict> from the shim before reading the next line.
string  PendingName = "";

// Optional gate parameter for the in-flight CONDITIONAL query. Cached
// alongside PendingName because handle_reply needs to know whether a GIVE
// is even possible (no gate / no local copy ⇒ skip silently).
string  PendingGate = "";

// Listen on SecureChannel for shim REPLYs.
integer SecureListen = 0;


/* -------------------- HELPERS -------------------- */

// Derive mode from bundle name. OpenCollar convention: BUNDLE_##_MODE.
string derive_mode(string bundle_name) {
    if (llSubStringIndex(bundle_name, "DEPRECATED") != -1) return "DEPRECATED";
    if (llSubStringIndex(bundle_name, "CONDITIONAL") != -1) return "CONDITIONAL";
    return "REQUIRED";
}

cleanup_bundle() {
    if (SecureListen) llListenRemove(SecureListen);
    SecureListen = 0;
    BundleName = "";
    CollarKey = NULL_KEY;
    CollarPin = 0;
    SecureChannel = 0;
    BundleMode = "";
    LineIdx = 0;
    LineRequest = NULL_KEY;
    PendingName = "";
    PendingGate = "";
}

notify_driver_done() {
    string payload = llList2Json(JSON_OBJECT, ["bundle", BundleName]);
    llMessageLinked(LINK_SET, LM_BUNDLE_DONE, payload, NULL_KEY);
    cleanup_bundle();
}

// Read the next line. When the dataserver callback returns EOF, the
// bundle is complete.
read_next_line() {
    LineRequest = llGetNotecardLine(BundleName, LineIdx);
}

// Send a QUERY to the shim for the named script. Format mirrors
// update_shim.lsl's protocol:
//   QUERY|SCRIPT|<name>|<uuid>|<mode>[|<gate>]
// gate is only emitted for CONDITIONAL mode entries that supplied one.
send_query(string script_name, string gate) {
    key uuid = llGetInventoryKey(script_name);
    PendingName = script_name;
    PendingGate = gate;
    string q = "QUERY|SCRIPT|" + script_name
        + "|" + (string)uuid
        + "|" + BundleMode;
    if (gate != "") q += "|" + gate;
    llWhisper(SecureChannel, q);
}


/* -------------------- LINE PROCESSING -------------------- */

// A notecard line looks like "SCRIPT|<name>" or is blank / a comment.
// Comments start with '#'. Only SCRIPT type is supported in v1.
process_line(string line) {
    line = llStringTrim(line, STRING_TRIM);
    if (line == "") {
        LineIdx += 1;
        read_next_line();
        return;
    }
    if (llGetSubString(line, 0, 0) == "#") {
        LineIdx += 1;
        read_next_line();
        return;
    }

    list parts = llParseString2List(line, ["|"], []);
    string type = llList2String(parts, 0);
    string name = llList2String(parts, 1);
    if (type != "SCRIPT" || name == "") {
        // Unknown or malformed — skip.
        LineIdx += 1;
        read_next_line();
        return;
    }

    // Optional 3rd field: gate script name. Only meaningful in CONDITIONAL
    // bundles; for paired kmods (e.g. kmod_leash gated on plugin_leash)
    // shim ships the kmod when the gate is in collar inventory.
    string gate = "";
    if (llGetListLength(parts) >= 3) gate = llList2String(parts, 2);

    // For REQUIRED and CONDITIONAL modes the script MUST exist in this prim
    // (shim may answer GIVE in either case). For DEPRECATED the shim does
    // all the work and we don't need a local copy.
    if (BundleMode == "REQUIRED" || BundleMode == "CONDITIONAL") {
        if (llGetInventoryType(name) != INVENTORY_SCRIPT) {
            // Missing script in installer inventory — can't deliver. Skip
            // with a warning on DEBUG_CHANNEL; continue with the next line.
            llShout(DEBUG_CHANNEL,
                "updater_bundler: " + BundleName + " references missing script '"
                + name + "'; skipping.");
            LineIdx += 1;
            read_next_line();
            return;
        }
    }

    send_query(name, gate);
}


/* -------------------- REPLY HANDLING -------------------- */

// Shim REPLY format: REPLY|<name>|<verdict>  where verdict is GIVE|SKIP|OK.
handle_reply(string verdict) {
    if (verdict == "GIVE") {
        // Ship the script. llRemoteLoadScriptPin sleeps 3 s.
        llRemoteLoadScriptPin(CollarKey, PendingName, CollarPin, TRUE, 0);
        PendingName = "";
        PendingGate = "";
        LineIdx += 1;
        read_next_line();
        return;
    }

    // SKIP (already current, or CONDITIONAL with neither name nor gate
    // present in collar) or OK (deprecated item removed or absent).
    PendingName = "";
    PendingGate = "";
    LineIdx += 1;
    read_next_line();
}


/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        // Mark this child prim with the dormancy marker so dragged-in
        // collar scripts park themselves. Safe to set even if the root
        // also carries the marker.
        llSetObjectDesc(UPDATER_MARKER);
        cleanup_bundle();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num != LM_BUNDLE_BEGIN) return;

        // Refuse if a bundle is already in progress; driver should serialise.
        if (BundleName != "") return;

        BundleName    = llJsonGetValue(msg, ["bundle"]);
        CollarKey     = (key)llJsonGetValue(msg, ["collar"]);
        CollarPin     = (integer)llJsonGetValue(msg, ["pin"]);
        SecureChannel = (integer)llJsonGetValue(msg, ["channel"]);
        BundleMode    = derive_mode(BundleName);

        // Sanity — driver shouldn't dispatch a missing notecard, but guard
        // anyway so we don't loop on a bogus llGetNotecardLine forever.
        if (llGetInventoryType(BundleName) != INVENTORY_NOTECARD) {
            notify_driver_done();
            return;
        }

        SecureListen = llListen(SecureChannel, "", CollarKey, "");
        LineIdx = 0;
        read_next_line();
    }

    dataserver(key req, string data) {
        if (req != LineRequest) return;
        if (data == EOF) {
            // Bundle complete.
            notify_driver_done();
            return;
        }
        process_line(data);
    }

    listen(integer channel, string name, key id, string message) {
        if (channel != SecureChannel) return;
        if (id != CollarKey) return;

        list parts = llParseString2List(message, ["|"], []);
        string verb = llList2String(parts, 0);
        if (verb != "REPLY") return;
        // REPLY|<name>|<verdict>
        string replied_name = llList2String(parts, 1);
        string verdict = llList2String(parts, 2);
        if (replied_name != PendingName) return;  // stale or crossed message
        handle_reply(verdict);
    }
}

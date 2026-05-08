/*--------------------
SCRIPT: updater_bundler.lsl
VERSION: 1.10
REVISION: 2
PURPOSE: Installer child-prim script. Holds the staged collar scripts in
  its own inventory. On LM_BUNDLE_BEGIN from updater_driver, asks update_shim
  for the collar's current collar-namespace inventory, iterates THIS prim's
  scripts, asks the shim per-script whether to ship, deposits new/stale
  scripts via llRemoteLoadScriptPin, and finally tells the shim which names
  to keep — anything in collar inventory not in that manifest is swept.
ARCHITECTURE: Lives in a child prim of the installer linkset. Sibling
  updater_driver runs in the root prim. Chat protocol with the shim uses
  the per-session secure channel passed in LM_BUNDLE_BEGIN. Scripts to be
  transferred must exist in THIS prim's inventory — llRemoteLoadScriptPin
  can only send items from the calling script's own prim.
CHANGES:
- v1.1 rev 2: Drop notecard manifest. Replaced by inventory diff: enumerate
  this prim's collar-namespace scripts, ask shim for collar's collar-namespace
  inventory via LIST, ship missing/stale ones, then SWEEP collar of any
  collar-namespace script not in the keep-manifest. Conditional pairs
  (kmod_leash, kmod_particles, leash_holder all gated on plugin_leash) are
  hardcoded here — gated kmods only ship if the gate plugin is present in
  collar OR being shipped this update. Removed dataserver/notecard reader.
- v1.1 rev 1: Add CONDITIONAL bundle mode (superseded by rev 2).
- v1.1 rev 0: Initial implementation.
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

// Conditional pairs: <gated_script>, <gate_plugin>. The gated script ships
// only if the gate plugin is present in collar OR is itself in this prim's
// inventory and about to ship. This preserves the wearer's installed-set
// while still healing paired-kmod gaps when the gating plugin is staged.
list ConditionalPairs = [
    "kmod_leash",      "plugin_leash",
    "kmod_particles",  "plugin_leash",
    "leash_holder",    "plugin_leash"
];
integer PAIR_STRIDE = 2;


/* -------------------- STATE -------------------- */
// Per-bundle context, populated from LM_BUNDLE_BEGIN and cleared on DONE.
key     CollarKey = NULL_KEY;
integer CollarPin = 0;
integer SecureChannel = 0;

// Collar's current collar-namespace inventory, learned via LIST/INV.
list    CollarInv = [];

// Local candidates (this prim's collar-namespace scripts, in iteration order).
list    Candidates = [];
integer CandIdx = 0;

// Names the bundler has decided should remain in collar after the update —
// shipped or acknowledged-current. Sent verbatim to shim as the SWEEP
// keep-list.
list    Manifest = [];

// Name of the script currently awaiting a REPLY from the shim.
string  PendingName = "";

// Listen on SecureChannel for shim INV / REPLY / SWEPT messages.
integer SecureListen = 0;


/* -------------------- HELPERS -------------------- */

// Collar-namespace test. Mirrors update_shim's filter so the two ends
// agree on what "ours to manage" means.
integer is_collar_script(string name) {
    if (name == "leash_holder") return TRUE;
    if (llSubStringIndex(name, "collar_") == 0) return TRUE;
    if (llSubStringIndex(name, "kmod_") == 0) return TRUE;
    if (llSubStringIndex(name, "plugin_") == 0) return TRUE;
    if (llSubStringIndex(name, "control_") == 0) return TRUE;
    return FALSE;
}

// Look up the gate plugin for a given script name. Returns "" if the
// script isn't gated (which is the common case).
string lookup_gate(string name) {
    integer i = 0;
    integer n = llGetListLength(ConditionalPairs);
    while (i < n) {
        if (llList2String(ConditionalPairs, i) == name) {
            return llList2String(ConditionalPairs, i + 1);
        }
        i += PAIR_STRIDE;
    }
    return "";
}

// Build the candidates list: every collar-namespace script in this prim,
// excluding self. update_shim is filtered out by namespace anyway, but
// guard explicitly in case a packager dropped it here by mistake.
build_candidates() {
    Candidates = [];
    string self = llGetScriptName();
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (name != self && name != "update_shim" && is_collar_script(name)) {
            Candidates += [name];
        }
        i += 1;
    }
}

cleanup_bundle() {
    if (SecureListen) llListenRemove(SecureListen);
    SecureListen = 0;
    CollarKey = NULL_KEY;
    CollarPin = 0;
    SecureChannel = 0;
    CollarInv = [];
    Candidates = [];
    CandIdx = 0;
    Manifest = [];
    PendingName = "";
}

notify_driver_done() {
    llMessageLinked(LINK_SET, LM_BUNDLE_DONE, "", NULL_KEY);
    cleanup_bundle();
}

// Advance the candidate cursor, applying gate-checks and sending the next
// QUERY to the shim. When the cursor exhausts, transition to SWEEP.
start_next_query() {
    integer n = llGetListLength(Candidates);
    while (CandIdx < n) {
        string name = llList2String(Candidates, CandIdx);
        string gate = lookup_gate(name);
        integer gated_out = FALSE;
        if (gate != "") {
            integer gate_in_collar = (llListFindList(CollarInv, [gate]) >= 0);
            integer gate_in_bundler = (llGetInventoryType(gate) == INVENTORY_SCRIPT);
            if (!gate_in_collar && !gate_in_bundler) gated_out = TRUE;
        }
        if (!gated_out) {
            PendingName = name;
            key uuid = llGetInventoryKey(name);
            llWhisper(SecureChannel,
                "QUERY|" + name + "|" + (string)uuid);
            return;
        }
        CandIdx += 1;
    }
    // Exhausted. If we have a non-empty manifest, request the sweep;
    // otherwise skip sweep entirely (footgun guard against an empty
    // installer accidentally nuking the collar).
    if (llGetListLength(Manifest) == 0) {
        notify_driver_done();
        return;
    }
    llWhisper(SecureChannel,
        "SWEEP|" + llDumpList2String(Manifest, ","));
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

        // Refuse if a session is already in progress; driver should serialise.
        if (SecureChannel != 0) return;

        CollarKey     = (key)llJsonGetValue(msg, ["collar"]);
        CollarPin     = (integer)llJsonGetValue(msg, ["pin"]);
        SecureChannel = (integer)llJsonGetValue(msg, ["channel"]);

        build_candidates();
        if (llGetListLength(Candidates) == 0) {
            // Empty installer — nothing to ship. Skip the sweep so we
            // don't accidentally wipe the collar from a misconfigured
            // bundler prim, and report done.
            notify_driver_done();
            return;
        }

        SecureListen = llListen(SecureChannel, "", CollarKey, "");
        // Ask the shim what's currently in the collar.
        llWhisper(SecureChannel, "LIST");
    }

    listen(integer channel, string name, key id, string message) {
        if (channel != SecureChannel) return;
        if (id != CollarKey) return;

        list parts = llParseString2List(message, ["|"], []);
        string verb = llList2String(parts, 0);

        if (verb == "INV") {
            string csv = "";
            if (llGetListLength(parts) >= 2) csv = llList2String(parts, 1);
            CollarInv = [];
            if (csv != "") CollarInv = llCSV2List(csv);
            CandIdx = 0;
            start_next_query();
            return;
        }

        if (verb == "REPLY") {
            // REPLY|<name>|<verdict>
            if (llGetListLength(parts) < 3) return;
            string replied_name = llList2String(parts, 1);
            string verdict = llList2String(parts, 2);
            if (replied_name != PendingName) return;
            PendingName = "";
            if (verdict == "GIVE") {
                // Ship. llRemoteLoadScriptPin sleeps 3s.
                llRemoteLoadScriptPin(CollarKey, replied_name, CollarPin, TRUE, 0);
                Manifest += [replied_name];
            } else if (verdict == "SKIP") {
                Manifest += [replied_name];
            }
            // Any other verdict: drop silently, do not add to manifest.
            CandIdx += 1;
            start_next_query();
            return;
        }

        if (verb == "SWEPT") {
            // Sweep complete. Body (CSV of removed names) is informational
            // only — we trust the shim. Tell driver we're done.
            notify_driver_done();
            return;
        }
    }
}

/*--------------------
SCRIPT: updater_bundler.lsl
VERSION: 1.10
REVISION: 4
PURPOSE: Installer child-prim script. Holds the staged collar inventory in
  its own contents. On LM_BUNDLE_BEGIN from updater_driver, asks update_shim
  for the collar's current inventory (scripts, animations, objects,
  notecards), diffs by UUID, deposits scripts via llRemoteLoadScriptPin,
  and ships non-scripts via direct prim-to-prim llGiveInventory(CollarKey,
  item) — same-owner attached transfer is silent at script level and
  bypasses both the accept dialog and RLV's edit-block, no wearer
  interaction required.
ARCHITECTURE: Lives in a child prim of the installer linkset. Sibling
  updater_driver runs in the root prim. Chat protocol with the shim uses
  the per-session secure channel passed in LM_BUNDLE_BEGIN. Items to be
  transferred must exist in THIS prim's inventory — llRemoteLoadScriptPin
  and llGiveInventory both source from the calling script's own prim.
CHANGES:
- v1.1 rev 4: Update-only-installed model. Candidates is now intersected with CollarInv when each LIST/<type>-reply arrives, so the bundler only QUERYs items that are present in BOTH the bundler AND the collar — the rule is "known to the updater AND present in the collar gets refreshed; known but absent gets ignored; present but unknown stays." No SWEEP (would remove wearer customs); no auto-install of bundler-only items (wearer chose not to install them). ConditionalPairs / lookup_gate / Manifest / SWEEP / SWEPT machinery all retired — the general intersection rule subsumes the 3-script paired-kmod gate. Same model for scripts and non-scripts (animations, objects, notecards).
- v1.1 rev 3: Extend the script-only diff to a typed phase machine that also covers animations, objects, and notecards. After SWEPT, walk LIST_ANIM / LIST_OBJ / LIST_NC and per-item QUERY_<type>; the shim wipes stale items synchronously and reports GIVE. Bundler then calls llGiveInventory(CollarKey, item) per GIVE — same-owner attached transfer is silent (the "attached = treated as agent" rule applies to cross-owner cases only) and bypasses RLV's edit-block. No SWEEP for non-scripts; items in collar not in bundler are wearer's customs and stay. Settings notecard ("settings") hard-excluded at both ends. Mirrors OpenCollar's update mechanism.
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

// Wearer-specific config; never managed by the updater. Mirrors the
// shim's exclusion so a stray "settings" notecard in this prim never
// ships and the wearer's existing settings notecard is never wiped.
string SETTINGS_NOTECARD = "settings";

// (ConditionalPairs retired in rev 4 — the general "Candidates =
//  CollarInv ∩ BundlerInv" intersection makes the paired-kmod gate
//  redundant: kmod_leash / kmod_particles / leash_holder are only ever
//  queried if the collar already has them, so a wearer who doesn't have
//  plugin_leash also doesn't have them and they get filtered out
//  automatically. No hand-curated pairs list needed.)


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

// (Manifest list retired in rev 4 — was only used for the SWEEP keep-list,
//  which is gone now that we no longer remove collar items the bundler
//  doesn't carry.)

// Name of the item currently awaiting a REPLY from the shim.
string  PendingName = "";

// Listen on SecureChannel for shim INV / REPLY / typed messages.
integer SecureListen = 0;

// Phase machine. Each phase iterates Candidates (this prim's inventory of
// that type) via QUERY_<verb>; the shim wipes stale and replies with a
// verdict. Order is fixed: scripts → animations → objects → notecards.
// Scripts ship via llRemoteLoadScriptPin (still); non-scripts ship via
// direct llGiveInventory(CollarKey, item) inside the typed REPLY handler.
string  TypePhase = "";


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

// Build the candidates list: every collar-namespace script in this prim,
// excluding self. update_shim is filtered out by namespace anyway, but
// guard explicitly in case a packager dropped it here by mistake.
// Collects into a local list with refcount 1 (O(n) amortized) and
// assigns to the global once at the end; appending directly to the
// global is O(n²) because the global slot holds a second reference.
build_candidates() {
    list buf = [];
    string self = llGetScriptName();
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (name != self && name != "update_shim" && is_collar_script(name)) {
            buf += [name];
        }
        i += 1;
    }
    Candidates = buf;
}

// Build candidates for a non-script type. No namespace filter — the
// bundler's own inventory IS the manifest of what's managed for
// non-script types. Settings notecard is hard-excluded so a stray
// template never ships and the wearer's persisted settings stay intact.
// Same local-buf pattern as build_candidates above.
build_candidates_typed(integer inv_type) {
    list buf = [];
    integer count = llGetInventoryNumber(inv_type);
    integer i = 0;
    while (i < count) {
        string name = llGetInventoryName(inv_type, i);
        if (inv_type != INVENTORY_NOTECARD || name != SETTINGS_NOTECARD) {
            buf += [name];
        }
        i += 1;
    }
    Candidates = buf;
}

// Returns the LIST verb to send to the shim for the current phase.
string list_verb_for_phase() {
    if (TypePhase == "scripts")    return "LIST";
    if (TypePhase == "animations") return "LIST_ANIM";
    if (TypePhase == "objects")    return "LIST_OBJ";
    if (TypePhase == "notecards")  return "LIST_NC";
    return "";
}

// Returns the QUERY verb for per-item lookups in the current phase.
string query_verb_for_phase() {
    if (TypePhase == "scripts")    return "QUERY";
    if (TypePhase == "animations") return "QUERY_ANIM";
    if (TypePhase == "objects")    return "QUERY_OBJ";
    if (TypePhase == "notecards")  return "QUERY_NC";
    return "";
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
    PendingName = "";
    TypePhase = "";
}

notify_driver_done() {
    llMessageLinked(LINK_SET, LM_BUNDLE_DONE, "", NULL_KEY);
    cleanup_bundle();
}

// Begin a new phase. Sets TypePhase, builds the type-specific candidate
// list, and either asks the shim for the collar's current inventory of
// that type (LIST_<verb>) or — if the bundler has nothing of that type —
// skips directly to the next phase without burning a shim round-trip.
begin_phase(string phase) {
    TypePhase = phase;
    CollarInv = [];
    Candidates = [];
    CandIdx = 0;
    PendingName = "";

    if (phase == "animations") {
        build_candidates_typed(INVENTORY_ANIMATION);
    }
    else if (phase == "objects") {
        build_candidates_typed(INVENTORY_OBJECT);
    }
    else if (phase == "notecards") {
        build_candidates_typed(INVENTORY_NOTECARD);
    }
    else if (phase == "done") {
        notify_driver_done();
        return;
    }

    if (llGetListLength(Candidates) == 0) {
        advance_phase();
        return;
    }
    llWhisper(SecureChannel, list_verb_for_phase());
}

// Linear phase progression: scripts → animations → objects → notecards → done.
advance_phase() {
    if (TypePhase == "scripts")         begin_phase("animations");
    else if (TypePhase == "animations") begin_phase("objects");
    else if (TypePhase == "objects")    begin_phase("notecards");
    else if (TypePhase == "notecards")  begin_phase("done");
}

// Send the next typed QUERY. Candidates was pre-intersected with
// CollarInv before this function ran (in the LIST/<type>-reply handler),
// so every entry is guaranteed to be both in this bundler AND in the
// collar — exactly the "known to the updater AND present in the collar"
// scope. No gate checks needed; no SWEEP needed. On exhaustion, advance
// straight to the next phase.
start_next_query() {
    string verb = query_verb_for_phase();
    integer n = llGetListLength(Candidates);
    if (CandIdx < n) {
        string name = llList2String(Candidates, CandIdx);
        PendingName = name;
        key uuid = llGetInventoryKey(name);
        llWhisper(SecureChannel,
            verb + "|" + name + "|" + (string)uuid);
        return;
    }
    advance_phase();
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

        // Validate payload fields up front. Missing keys return
        // JSON_INVALID, which would (key)-cast to NULL_KEY and
        // (integer)-cast to 0 — both are silently broken downstream.
        string collar_str  = llJsonGetValue(msg, ["collar"]);
        string pin_str     = llJsonGetValue(msg, ["pin"]);
        string channel_str = llJsonGetValue(msg, ["channel"]);
        if (collar_str == JSON_INVALID) return;
        if (pin_str == JSON_INVALID) return;
        if (channel_str == JSON_INVALID) return;

        CollarKey     = (key)collar_str;
        CollarPin     = (integer)pin_str;
        SecureChannel = (integer)channel_str;

        TypePhase = "scripts";
        build_candidates();
        SecureListen = llListen(SecureChannel, "", CollarKey, "");

        if (llGetListLength(Candidates) == 0) {
            // No scripts staged in this installer. Don't bail — the
            // packager may have included only non-scripts. Advance to
            // the first non-script phase.
            advance_phase();
            return;
        }
        llWhisper(SecureChannel, "LIST");
    }

    listen(integer channel, string name, key id, string message) {
        if (channel != SecureChannel) return;
        if (id != CollarKey) return;

        list parts = llParseString2List(message, ["|"], []);
        string verb = llList2String(parts, 0);

        // CollarInv-load verbs (one per phase). The shim's CSV of what
        // the collar currently has of the current type — replies to LIST
        // (scripts) / LIST_ANIM / LIST_OBJ / LIST_NC. Intersect the
        // bundler-side Candidates with this CollarInv so we only ever
        // QUERY items that are present in BOTH ends — the "known to the
        // updater AND present in the collar" rule. Items only in the
        // bundler get filtered out here (wearer chose not to install
        // them); items only in the collar are wearer customs that the
        // updater never touches.
        if (verb == "INV" || verb == "ANIM" || verb == "OBJ" || verb == "NC") {
            string csv = "";
            if (llGetListLength(parts) >= 2) csv = llList2String(parts, 1);
            CollarInv = [];
            if (csv != "") CollarInv = llCSV2List(csv);

            list intersected = [];
            integer ci = 0;
            integer cn = llGetListLength(Candidates);
            while (ci < cn) {
                string cand = llList2String(Candidates, ci);
                if (llListFindList(CollarInv, [cand]) != -1) intersected += [cand];
                ci += 1;
            }
            Candidates = intersected;

            CandIdx = 0;
            if (llGetListLength(Candidates) == 0) {
                advance_phase();
                return;
            }
            start_next_query();
            return;
        }

        if (verb == "REPLY") {
            // REPLY|<name>|<verdict> for scripts. Candidates were
            // pre-intersected with CollarInv so we know the collar has
            // this name — GIVE here means "stale UUID, ship the new
            // version via PIN" (3s sleep). SKIP means "matching UUID,
            // nothing to do".
            if (llGetListLength(parts) < 3) return;
            string replied_name = llList2String(parts, 1);
            string verdict = llList2String(parts, 2);
            if (replied_name != PendingName) return;
            PendingName = "";
            if (verdict == "GIVE") {
                llRemoteLoadScriptPin(CollarKey, replied_name, CollarPin, TRUE, 0);
            }
            // SKIP / anything else: do nothing.
            CandIdx += 1;
            start_next_query();
            return;
        }

        // REPLY_ANIM / REPLY_OBJ / REPLY_NC — non-script verdicts.
        // Same pre-intersection guarantee as REPLY: collar has it,
        // GIVE means stale, SKIP means current, EXCLUDE means settings
        // notecard (drop). Same-owner attached prim-to-prim
        // llGiveInventory is silent at script level — no dialog, no
        // wearer interaction, lands in the collar's inventory and
        // bypasses RLV's edit-block.
        if (verb == "REPLY_ANIM" || verb == "REPLY_OBJ" || verb == "REPLY_NC") {
            if (llGetListLength(parts) < 3) return;
            string nspt_name = llList2String(parts, 1);
            string nspt_verdict = llList2String(parts, 2);
            if (nspt_name != PendingName) return;
            PendingName = "";
            if (nspt_verdict == "GIVE") {
                llGiveInventory(CollarKey, nspt_name);
            }
            CandIdx += 1;
            start_next_query();
            return;
        }
    }
}

/*--------------------
SCRIPT: updater_bundler.lsl
VERSION: 1.10
REVISION: 7
PURPOSE: Installer child-prim script. Holds the staged collar inventory in
  its own contents. Three modes:
    UPDATE — on LM_BUNDLE_BEGIN, asks update_shim for the collar's current
      inventory, intersects bundler ∩ collar, ships stale items.
    INSTALL — on LM_INSTALL_BEGIN, same LIST step but inverts the diff to
      bundler-MINUS-collar, groups the missing items into features (Leash
      Subsystem / RLV Subsystem overrides + plugin_<name> anchor heuristic
      + Core Components catchall), and returns the feature list to the
      driver. After LM_INSTALL_GO with the wearer's selection, ships the
      chosen scripts plus every bundler-only non-script.
    INSTALL_SHIM — on LM_INSTALL_SHIM_BEGIN, ships an unconditional script
      set followed by all bundler-side animations / objects / notecards
      to an install_shim sitting in an empty target. No LIST/QUERY
      handshake (target is empty by construction). Same-owner
      llGiveInventory is silent regardless of attached state, so the
      non-script ship is just a flat loop — no shim cooperation needed.
ARCHITECTURE: Lives in a child prim of the installer linkset. Sibling
  updater_driver runs in the root prim. Chat protocol with the shim uses
  the per-session secure channel passed in LM_BUNDLE_BEGIN / LM_INSTALL_BEGIN.
  Items to be transferred must exist in THIS prim's inventory —
  llRemoteLoadScriptPin and llGiveInventory both source from the calling
  script's own prim.
CHANGES:
- v1.1 rev 7: install_shim mode now ships animations / objects / notecards after the script set, including the settings notecard (which is intentionally an example template on fresh install — wearers can customise defaults from it). Update and install-against-existing-collar paths still exclude the settings notecard at all three layers (build_candidates_typed / list_inventory_typed / verdict_for_typed) so wearer customisations are never overwritten. Earlier rev was over-cautious about llGiveInventory dialog floods — same-owner prim-to-prim transfer is silent regardless of attached state.
- v1.1 rev 6: Add missing LM_FEATURES_QUERY handler. Constant was declared and the driver sent the message, but the bundler had no handler — install_shim flow hung at 'shim_features_querying' forever and the wearer's re-touches saw 'session already in progress'.
- v1.1 rev 5: Add INSTALL and INSTALL_SHIM modes. Mode variable gates the diff predicate (intersect vs invert) and the dispatch shape. Feature grouping uses two hand-defined subsystem overrides (Leash, RLV — these don't decompose cleanly under the anchor heuristic) plus plugin_<name> anchor for everything else, with leftover core kmods collapsed into a single "Core Components" feature. Driver picks features via multi-select; bundler then ships the selected script set followed by all bundler-only non-scripts. The install-shim variant skips the shim handshake entirely — install_shim refused to start unless its prim was empty, so the bundler can ship via llRemoteLoadScriptPin without a per-item GIVE/SKIP roundtrip.
- v1.1 rev 4: Update-only-installed model. Candidates is now intersected with CollarInv when each LIST/<type>-reply arrives, so the bundler only QUERYs items that are present in BOTH the bundler AND the collar — the rule is "known to the updater AND present in the collar gets refreshed; known but absent gets ignored; present but unknown stays." No SWEEP (would remove wearer customs); no auto-install of bundler-only items (wearer chose not to install them). ConditionalPairs / lookup_gate / Manifest / SWEEP / SWEPT machinery all retired — the general intersection rule subsumes the 3-script paired-kmod gate. Same model for scripts and non-scripts (animations, objects, notecards).
- v1.1 rev 3: Extend the script-only diff to a typed phase machine that also covers animations, objects, and notecards. After SWEPT, walk LIST_ANIM / LIST_OBJ / LIST_NC and per-item QUERY_<type>; the shim wipes stale items synchronously and reports GIVE. Bundler then calls llGiveInventory(CollarKey, item) per GIVE — same-owner attached transfer is silent (the "attached = treated as agent" rule applies to cross-owner cases only) and bypasses RLV's edit-block. No SWEEP for non-scripts; items in collar not in bundler are wearer's customs and stay. Settings notecard ("settings") hard-excluded at both ends. Mirrors OpenCollar's update mechanism.
- v1.1 rev 2: Drop notecard manifest. Replaced by inventory diff.
- v1.1 rev 1: Add CONDITIONAL bundle mode (superseded by rev 2).
- v1.1 rev 0: Initial implementation.
--------------------*/


/* -------------------- LINK-MESSAGE NUMBERS -------------------- */
// Must match updater_driver.
integer LM_BUNDLE_BEGIN        = 91001;
integer LM_BUNDLE_DONE         = 91002;
integer LM_INSTALL_BEGIN       = 91003;  // driver→bundler: discover & report features
integer LM_INSTALL_FEATURES    = 91004;  // bundler→driver: feature list
integer LM_INSTALL_GO          = 91005;  // driver→bundler: scripts CSV selected
integer LM_INSTALL_SHIM_BEGIN  = 91006;  // driver→bundler: ship blind to install_shim
integer LM_FEATURES_QUERY      = 91007;  // driver→bundler: enumerate features (empty-target case)


/* -------------------- CONSTANTS -------------------- */
// Object description marker. Dormancy guard in every collar script checks
// for this — any script dragged into this prim's inventory parks itself
// instead of trying to run here.
string UPDATER_MARKER = "COLLAR_UPDATER";

// Wearer-specific config; never managed by the updater. Mirrors the
// shim's exclusion so a stray "settings" notecard in this prim never
// ships and the wearer's existing settings notecard is never wiped.
string SETTINGS_NOTECARD = "settings";


/* -------------------- STATE -------------------- */
// "update" | "install" | "install_shim". Set on the LM_*_BEGIN that
// kicked off the current session; gates the diff predicate (intersect vs
// invert) and the post-script behaviour.
string  Mode = "";

// Per-session context.
key     CollarKey = NULL_KEY;
integer CollarPin = 0;
integer SecureChannel = 0;

// Collar's current collar-namespace inventory, learned via LIST/INV.
list    CollarInv = [];

// Local candidates (this prim's collar-namespace scripts for the current phase).
list    Candidates = [];
integer CandIdx = 0;

// Name of the item currently awaiting a REPLY from the shim.
string  PendingName = "";

// Listen on SecureChannel for shim INV / REPLY / typed messages.
integer SecureListen = 0;

// Phase machine. Order is fixed: scripts → animations → objects → notecards.
// In install mode the scripts phase pauses after diff to await the wearer's
// feature selection (LM_INSTALL_GO); typed phases run unconditionally
// against the bundler-only set.
string  TypePhase = "";

// Install-mode only: scripts the wearer picked from the feature menu.
// Set by LM_INSTALL_GO; iterated in install-ship loop.
list    InstallScripts = [];


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
// excluding self and the shim. Local buf with refcount 1 → assigned to
// the global once (avoids O(n²) on the global slot).
build_candidates() {
    list buf = [];
    string self = llGetScriptName();
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (name != self
         && name != "update_shim"
         && name != "install_shim"
         && is_collar_script(name)) {
            buf += [name];
        }
        i += 1;
    }
    Candidates = buf;
}

// Build candidates for a non-script type. No namespace filter — the
// bundler's own inventory IS the manifest of what's managed for
// non-script types. Settings notecard is excluded HERE (update + install-
// against-existing-collar paths) so a customised notecard is never
// overwritten. The install_shim fresh-target path uses
// ship_nonscripts_to_install_shim instead, which intentionally includes
// settings as a starter template.
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
    Mode = "";
    CollarKey = NULL_KEY;
    CollarPin = 0;
    SecureChannel = 0;
    CollarInv = [];
    Candidates = [];
    CandIdx = 0;
    PendingName = "";
    TypePhase = "";
    InstallScripts = [];
}

notify_driver_done() {
    llMessageLinked(LINK_SET, LM_BUNDLE_DONE, "", NULL_KEY);
    cleanup_bundle();
}

// Apply the diff predicate. In update mode, Candidates ∩ CollarInv (we
// only refresh items the collar already has). In install mode, Candidates
// MINUS CollarInv (we only ship items the collar is missing).
list apply_diff_predicate(list cands, list collar_inv) {
    list out = [];
    integer ci = 0;
    integer cn = llGetListLength(cands);
    while (ci < cn) {
        string cand = llList2String(cands, ci);
        integer present = (llListFindList(collar_inv, [cand]) != -1);
        if (Mode == "install") {
            if (!present) out += [cand];
        } else {
            if (present) out += [cand];
        }
        ci += 1;
    }
    return out;
}


/* -------------------- FEATURE GROUPING (install mode) -------------------- */
// Two hand-defined subsystems for items that don't decompose under the
// plugin_<name> anchor heuristic, plus a Core Components catchall for
// kernel-side kmods that have no plugin_<name> peer.
//
// RLV subsystem: kmod_rlv + every plugin that issues rlv.* link-messages
// or @-commands. Anchor heuristic would split these across multiple
// per-plugin features and leave kmod_rlv orphaned in Core; group them.
// Verified set as of v1.1 rev 5: plugin_outfits, plugin_folders,
// plugin_relay, plugin_restrict, plugin_rlvex, plugin_strip.
//
// Leash subsystem: anchor heuristic would group plugin_leash with the
// kmod_leash_* pair correctly, but leash_holder doesn't share the
// "leash" token in the right shape (no plugin_holder), and kmod_particles
// is only used by leash. Group all seven explicitly.

list rlv_members() {
    return [
        "kmod_rlv",
        "plugin_outfits",
        "plugin_folders",
        "plugin_relay",
        "plugin_restrict",
        "plugin_rlvex",
        "plugin_strip"
    ];
}

list leash_members() {
    return [
        "kmod_leash_proto",
        "kmod_leash_engine",
        "kmod_particles",
        "plugin_leash",
        "plugin_leash_avatar",
        "plugin_leash_object",
        "leash_holder"
    ];
}

// Capitalize the first letter of an anchor token for menu display.
// "blacklist" → "Blacklist", "animate" → "Animate".
string capitalize(string s) {
    if (s == "") return s;
    return llToUpper(llGetSubString(s, 0, 0)) + llGetSubString(s, 1, -1);
}

// Extract the anchor token from a plugin_<name>[_<sub>] script name.
// "plugin_blacklist" → "blacklist", "plugin_leash_avatar" → "leash".
// Used by the anchor pass to find related kmod_<anchor>* / plugin_<anchor>*
// scripts in the missing-items set.
string anchor_of(string plugin_name) {
    string tail = llGetSubString(plugin_name, 7, -1);  // strip "plugin_"
    integer us = llSubStringIndex(tail, "_");
    if (us >= 0) tail = llGetSubString(tail, 0, us - 1);
    return tail;
}

// Pull every name in `pool` that matches the anchor's plugin/kmod/control
// pattern. Removes matches from `pool` (caller reassigns).
list pull_anchor_matches(string anchor, list pool) {
    list matches = [];
    string p_exact = "plugin_" + anchor;
    string p_pref  = "plugin_" + anchor + "_";
    string k_exact = "kmod_" + anchor;
    string k_pref  = "kmod_" + anchor + "_";
    string c_exact = "control_" + anchor;
    string c_pref  = "control_" + anchor + "_";

    integer i = 0;
    integer n = llGetListLength(pool);
    while (i < n) {
        string name = llList2String(pool, i);
        integer hit = FALSE;
        if (name == p_exact || name == k_exact || name == c_exact) hit = TRUE;
        else if (llSubStringIndex(name, p_pref) == 0) hit = TRUE;
        else if (llSubStringIndex(name, k_pref) == 0) hit = TRUE;
        else if (llSubStringIndex(name, c_pref) == 0) hit = TRUE;
        if (hit) matches += [name];
        i += 1;
    }
    return matches;
}

// Pull every name in `pool` that's listed in `subset`. Returns the
// intersection; caller subtracts matches from pool afterward.
list pull_subset(list subset, list pool) {
    list out = [];
    integer i = 0;
    integer n = llGetListLength(subset);
    while (i < n) {
        string name = llList2String(subset, i);
        if (llListFindList(pool, [name]) != -1) out += [name];
        i += 1;
    }
    return out;
}

// Return `pool` minus every name in `removed`.
list list_subtract(list pool, list removed) {
    list out = [];
    integer i = 0;
    integer n = llGetListLength(pool);
    while (i < n) {
        string name = llList2String(pool, i);
        if (llListFindList(removed, [name]) == -1) out += [name];
        i += 1;
    }
    return out;
}

// Group the bundler-only script list into features. Result is a flat
// stride-2 list: [label_0, scripts_csv_0, label_1, scripts_csv_1, ...].
// Stride-2 because LSL has no struct type and encoding as JSON would
// double the parse cost on the driver side.
list group_into_features(list missing) {
    list result = [];
    list pool = missing;

    // 1. RLV subsystem override.
    list rlv = pull_subset(rlv_members(), pool);
    if (llGetListLength(rlv) > 0) {
        result += ["RLV Subsystem", llDumpList2String(rlv, ",")];
        pool = list_subtract(pool, rlv);
    }

    // 2. Leash subsystem override.
    list leash = pull_subset(leash_members(), pool);
    if (llGetListLength(leash) > 0) {
        result += ["Leash Subsystem", llDumpList2String(leash, ",")];
        pool = list_subtract(pool, leash);
    }

    // 3. plugin_<name> anchor heuristic. Iterate every remaining
    // plugin_* and group its anchor's related kmod/control/sub-plugin.
    integer i = 0;
    while (i < llGetListLength(pool)) {
        string name = llList2String(pool, i);
        if (llSubStringIndex(name, "plugin_") == 0) {
            string anchor = anchor_of(name);
            list grp = pull_anchor_matches(anchor, pool);
            if (llGetListLength(grp) > 0) {
                result += [capitalize(anchor), llDumpList2String(grp, ",")];
                pool = list_subtract(pool, grp);
                // Don't increment i — pool shrank, and the next item now
                // occupies the current index.
            } else {
                i += 1;
            }
        } else {
            i += 1;
        }
    }

    // 4. Leftovers (collar_kernel, kmod_auth, kmod_bootstrap, etc.) →
    // single "Core Components" feature. These are the kernel-side kmods
    // with no plugin_<name> peer and the kernel itself.
    if (llGetListLength(pool) > 0) {
        result += ["Core Components", llDumpList2String(pool, ",")];
    }

    return result;
}


/* -------------------- PHASE PROGRESSION -------------------- */

// Begin a new phase. In install mode the scripts phase pauses after the
// diff (we send features to the driver and wait for LM_INSTALL_GO); typed
// phases (animations/objects/notecards) ship all bundler-only items
// straight through.
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

// In install mode, "ship" the candidates phase by iterating selected
// scripts (for the scripts phase) or every candidate (for typed phases —
// inverse intersection was already applied).
//
// For UPDATE mode, this is the same loop as before: QUERY each candidate
// to check UUID staleness and ship via PIN if GIVE.
start_next_query() {
    integer n = llGetListLength(Candidates);

    // INSTALL mode, scripts phase: candidates are already the wearer's
    // selected scripts. No QUERY needed (we know they're missing).
    // Ship directly via llRemoteLoadScriptPin (3s sleep per call).
    if (Mode == "install" && TypePhase == "scripts") {
        if (CandIdx < n) {
            string name = llList2String(Candidates, CandIdx);
            llRemoteLoadScriptPin(CollarKey, name, CollarPin, TRUE, 0);
            CandIdx += 1;
            // Tail-call into ourselves for the next ship. The 3s sleep
            // in llRemoteLoadScriptPin keeps the event queue from
            // flooding; no explicit pacing needed.
            start_next_query();
            return;
        }
        advance_phase();
        return;
    }

    // INSTALL mode, typed phases: candidates are the bundler-only set
    // for this type. llGiveInventory unconditionally (target is attached
    // because discovery succeeded → collar is worn).
    if (Mode == "install") {
        if (CandIdx < n) {
            string name = llList2String(Candidates, CandIdx);
            llGiveInventory(CollarKey, name);
            CandIdx += 1;
            start_next_query();
            return;
        }
        advance_phase();
        return;
    }

    // UPDATE mode: per-item QUERY → shim verdict → ship or skip.
    string verb = query_verb_for_phase();
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


/* -------------------- INSTALL-SHIM SHIPPING (fresh target) -------------------- */
// Empty-target ship path. install_shim refused to start unless its prim
// was empty, so we ship the entire selected set unconditionally — no
// LIST/QUERY handshake, no per-item verdict. Same-owner prim-to-prim
// llGiveInventory is silent regardless of attached state, so non-scripts
// (animations, objects, notecards) ship the same way as scripts: just
// loop and call.
ship_to_install_shim(list scripts) {
    integer n = llGetListLength(scripts);
    integer i = 0;
    while (i < n) {
        string name = llList2String(scripts, i);
        // Source must exist in this prim — packager error otherwise.
        if (llGetInventoryType(name) == INVENTORY_SCRIPT) {
            llRemoteLoadScriptPin(CollarKey, name, CollarPin, TRUE, 0);
        }
        i += 1;
    }
    ship_nonscripts_to_install_shim(INVENTORY_ANIMATION);
    ship_nonscripts_to_install_shim(INVENTORY_OBJECT);
    ship_nonscripts_to_install_shim(INVENTORY_NOTECARD);
    notify_driver_done();
}

// Ship every bundler-side item of one non-script type to the install_shim
// target. The settings notecard IS included here — it's an example
// template for wearers who want to customise defaults. On update paths
// it stays excluded (a customised notecard must not be overwritten); the
// install_shim path is the only place we ship it because the target is
// empty by construction and has no notecard to preserve.
ship_nonscripts_to_install_shim(integer inv_type) {
    integer count = llGetInventoryNumber(inv_type);
    integer i = 0;
    while (i < count) {
        string name = llGetInventoryName(inv_type, i);
        llGiveInventory(CollarKey, name);
        i += 1;
    }
}


/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        // Mark this child prim with the dormancy marker so dragged-in
        // collar scripts park themselves.
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
        // ----- FEATURES QUERY (empty-target install_shim path) -----
        // Driver asks "what features would you ship?" without any collar
        // context. Build candidates from our own inventory and group
        // them as if the target were empty (CollarInv = []), so the
        // bundler-MINUS-collar diff returns everything we have.
        if (num == LM_FEATURES_QUERY) {
            if (Mode != "") return;
            build_candidates();
            list features = group_into_features(Candidates);
            string payload = llList2Json(JSON_OBJECT, [
                "features", llList2Json(JSON_ARRAY, features)
            ]);
            llMessageLinked(LINK_SET, LM_INSTALL_FEATURES, payload, NULL_KEY);
            Candidates = [];
            return;
        }

        // ----- UPDATE mode start -----
        if (num == LM_BUNDLE_BEGIN) {
            if (Mode != "") return;  // session already in progress

            string collar_str  = llJsonGetValue(msg, ["collar"]);
            string pin_str     = llJsonGetValue(msg, ["pin"]);
            string channel_str = llJsonGetValue(msg, ["channel"]);
            if (collar_str == JSON_INVALID) return;
            if (pin_str == JSON_INVALID) return;
            if (channel_str == JSON_INVALID) return;

            Mode = "update";
            CollarKey     = (key)collar_str;
            CollarPin     = (integer)pin_str;
            SecureChannel = (integer)channel_str;

            TypePhase = "scripts";
            build_candidates();
            SecureListen = llListen(SecureChannel, "", CollarKey, "");

            if (llGetListLength(Candidates) == 0) {
                advance_phase();
                return;
            }
            llWhisper(SecureChannel, "LIST");
            return;
        }

        // ----- INSTALL mode start (discovered collar) -----
        if (num == LM_INSTALL_BEGIN) {
            if (Mode != "") return;

            string collar_str  = llJsonGetValue(msg, ["collar"]);
            string pin_str     = llJsonGetValue(msg, ["pin"]);
            string channel_str = llJsonGetValue(msg, ["channel"]);
            if (collar_str == JSON_INVALID) return;
            if (pin_str == JSON_INVALID) return;
            if (channel_str == JSON_INVALID) return;

            Mode = "install";
            CollarKey     = (key)collar_str;
            CollarPin     = (integer)pin_str;
            SecureChannel = (integer)channel_str;

            TypePhase = "scripts";
            build_candidates();
            SecureListen = llListen(SecureChannel, "", CollarKey, "");

            if (llGetListLength(Candidates) == 0) {
                // Nothing to install — bundler has no scripts staged.
                // Skip to typed phases anyway in case non-scripts exist.
                advance_phase();
                return;
            }
            llWhisper(SecureChannel, "LIST");
            return;
        }

        // ----- INSTALL mode: wearer's selection from feature picker -----
        if (num == LM_INSTALL_GO) {
            if (Mode != "install") return;
            if (TypePhase != "scripts_await") return;

            string csv = llJsonGetValue(msg, ["scripts"]);
            if (csv == JSON_INVALID) csv = "";
            list selected = [];
            if (csv != "") selected = llCSV2List(csv);

            // Replace Candidates with the wearer's selection. start_next_query
            // in install/scripts mode iterates Candidates without QUERY.
            Candidates = selected;
            CandIdx = 0;
            TypePhase = "scripts";

            if (llGetListLength(Candidates) == 0) {
                advance_phase();
                return;
            }
            start_next_query();
            return;
        }

        // ----- INSTALL_SHIM mode (empty target) -----
        if (num == LM_INSTALL_SHIM_BEGIN) {
            if (Mode != "") return;

            string shim_str = llJsonGetValue(msg, ["shim"]);
            string pin2_str = llJsonGetValue(msg, ["pin"]);
            string csv2     = llJsonGetValue(msg, ["scripts"]);
            if (shim_str == JSON_INVALID) return;
            if (pin2_str == JSON_INVALID) return;
            if (csv2 == JSON_INVALID) csv2 = "";

            Mode = "install_shim";
            CollarKey = (key)shim_str;
            CollarPin = (integer)pin2_str;

            list scripts = [];
            if (csv2 != "") scripts = llCSV2List(csv2);
            ship_to_install_shim(scripts);
            return;
        }
    }

    listen(integer channel, string name, key id, string message) {
        if (channel != SecureChannel) return;
        if (id != CollarKey) return;

        list parts = llParseString2List(message, ["|"], []);
        string verb = llList2String(parts, 0);

        // CollarInv-load verbs. INSTALL mode inverts the diff to
        // bundler-MINUS-collar; UPDATE keeps the existing intersection.
        // For scripts in install mode, after the diff we group into
        // features and pause for the driver's LM_INSTALL_GO instead of
        // shipping straight away.
        if (verb == "INV" || verb == "ANIM" || verb == "OBJ" || verb == "NC") {
            string csv = "";
            if (llGetListLength(parts) >= 2) csv = llList2String(parts, 1);
            CollarInv = [];
            if (csv != "") CollarInv = llCSV2List(csv);

            Candidates = apply_diff_predicate(Candidates, CollarInv);
            CandIdx = 0;

            if (llGetListLength(Candidates) == 0) {
                advance_phase();
                return;
            }

            // Install scripts phase: hand off to driver for wearer's pick.
            if (Mode == "install" && TypePhase == "scripts") {
                list features = group_into_features(Candidates);
                string payload = llList2Json(JSON_OBJECT, [
                    "features", llList2Json(JSON_ARRAY, features)
                ]);
                llMessageLinked(LINK_SET, LM_INSTALL_FEATURES, payload, NULL_KEY);
                TypePhase = "scripts_await";
                return;
            }

            start_next_query();
            return;
        }

        // UPDATE mode: per-script verdict.
        if (verb == "REPLY") {
            if (llGetListLength(parts) < 3) return;
            string replied_name = llList2String(parts, 1);
            string verdict = llList2String(parts, 2);
            if (replied_name != PendingName) return;
            PendingName = "";
            if (verdict == "GIVE") {
                llRemoteLoadScriptPin(CollarKey, replied_name, CollarPin, TRUE, 0);
            }
            CandIdx += 1;
            start_next_query();
            return;
        }

        // UPDATE mode: per-non-script verdict.
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

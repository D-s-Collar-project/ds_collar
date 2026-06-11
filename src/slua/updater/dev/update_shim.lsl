/*--------------------
SCRIPT: update_shim.lsl
VERSION: 1.10
REVISION: 7
PURPOSE: Transient payload deposited into the collar by updater_driver via
  llRemoteLoadScriptPin. Runs inside the collar, answers inventory and
  ship-decision queries from updater_bundler over the start_param channel,
  and sweeps stale collar-namespace scripts on demand. Brackets the
  update with a dormancy-marker stamp on the prim's description so the
  surrounding collar scripts park themselves for the duration. Self-deletes
  on DONE or inactivity timeout.
ARCHITECTURE: Mirrors install_shim's dormancy-marker bracket: state_entry
  saves the collar's prim description to LSD (script-reset-safe) and
  stamps UPDATER_MARKER; every collar script's state_entry checks
  llGetObjectDesc() against the marker and parks via llSetScriptState.
  Replaced scripts hit the guard when their new copy loads; kept scripts
  (same UUID, untouched by the bundle) are caught by park_collar_scripts
  in state_entry. activate_collar_scripts on the DONE / timeout /
  CHANGED_OWNER paths restores the desc from LSD, clears the LSD entry,
  re-enables every collar script, and llResetOtherScript-s each one so
  state_entry runs again with the restored desc — kmod_bootstrap's RLV
  probe / register.refresh / status announcement happen as a natural
  consequence of its own reset, which obsoletes the previous
  remote.update.complete broadcast. Orphaned plugin.reg.<ctx> /
  acl.policycontext:<ctx> entries left by swept scripts are cleaned up
  by collar_kernel's prune_missing_scripts on its next inventory tick —
  the shim does not touch LSD beyond the desc-backup key.
  "Kamikaze" pattern from OpenCollar's oc_update_shim.
CHANGES:
- v1.1 rev 7: Bracket the update with the install_shim dormancy pattern. state_entry now saves the prim description to LSD (key `updater.original_desc`), stamps UPDATER_MARKER, and parks every collar-namespace script via park_collar_scripts. New activate_collar_scripts helper restores the desc from LSD, clears the LSD entry, and re-enables + llResetOtherScript-s each collar script so its state_entry runs again with the new bundle live. Replaces the previous remote.update.complete broadcast (rev 5) — kmod_bootstrap's startup orchestration now fires naturally as part of its own reset. Failure paths (inactivity timeout, CHANGED_OWNER) also activate so the wearer doesn't end up with a silent-locked collar. REMOTE_BUS constant removed.
- v1.1 rev 6: INACTIVITY_TIMEOUT 120s → 600s. The install-against-existing-collar flow parks the bundler in scripts_await while the driver shows the feature picker; if the wearer took longer than 120s reading, the shim disarmed the PIN before they confirmed, then llRemoteLoadScriptPin failed with "trying to illegally load script onto task" on the next dispatch. 600s covers any plausible decision time + BUNDLE_TIMEOUT.
- v1.1 rev 5: Broadcast `remote.update.complete` on REMOTE_BUS in the DONE handler before self-deletion. kmod_bootstrap listens for it and llResetScripts so the startup orchestration (RLV probe, register.refresh, status announcement) re-runs with the new script set live. Only the success path emits — inactivity timeout / CHANGED_OWNER cleanups don't, since those leave the collar half-updated and a "we're done" signal would be misleading.
- v1.1 rev 4: Extend protocol with animations, objects, notecards. LIST_ANIM / LIST_OBJ / LIST_NC + QUERY_ANIM / QUERY_OBJ / QUERY_NC mirror the script flow per-type. Settings notecard ("settings") is hard-excluded — never reported in LIST_NC, never wiped via QUERY_NC (returns EXCLUDE). Non-script types have no SWEEP — items not in bundler are wearer's customs and stay untouched. Shim wipes stale items synchronously inside verdict_for_typed before reporting GIVE; bundler then calls llGiveInventory(collar_uuid, item) per item — same-owner attached prim transfer is silent at script level and bypasses RLV's edit-block, no wearer interaction required (mirrors OpenCollar's mechanism).
- v1.1 rev 3: Drop notecard-mode protocol. Replace with inventory-driven
  flow: LIST → INV|<csv> reports collar's collar-namespace inventory;
  QUERY|<name>|<uuid> → REPLY|<name>|GIVE|SKIP compares UUID; SWEEP|<csv>
  → SWEPT|<csv> removes any collar-namespace script not in the supplied
  manifest. Mode/CONDITIONAL/DEPRECATED branches deleted; ship/skip/keep
  decisions all originate in the bundler now. Collar-namespace prefix
  list: collar_, kmod_, plugin_, control_, plus literal leash_holder.
- v1.1 rev 2: Add CONDITIONAL mode (superseded by rev 3).
- v1.1 rev 1: Hold @detach=n while shim is resident if collar was locked
  at update start; bridges the ~3s window during plugin_lock replacement.
- v1.1 rev 0: Initial implementation.
--------------------*/


/* -------------------- CONSTANTS -------------------- */
// Dormancy marker stamped on the collar's prim description for the
// duration of the update. Every collar script's state_entry compares
// llGetObjectDesc() against this string and parks itself via
// llSetScriptState(self, FALSE) if it matches. Same marker install_shim
// uses on fresh installs — the dormancy guard is a single check across
// the ~33 collar-namespace scripts.
string UPDATER_MARKER = "COLLAR_UPDATER";

// LSD key holding the collar's pre-update prim description. Persisted
// to linkset data (rather than a script global) so an unexpected reset
// of update_shim itself doesn't lose the original — the new copy can
// still find and restore it on the activate path. Cleared explicitly
// in activate_collar_scripts; intentionally not in MANAGED_SETTINGS_KEYS
// since it's a transient marker, not a wearer setting.
string UPDATER_DESC_BACKUP_KEY = "updater.original_desc";

// Inactivity window. If no message arrives from the bundler for this many
// seconds, assume the session died and clean up — which disarms the PIN
// (`llSetRemoteScriptAccessPin(0)`) and removes the shim.
//
// Has to be longer than the longest expected gap between bundler messages:
//   - Update mode: bundler sends QUERY/REPLY continuously; gaps are seconds.
//   - Install-against-existing-collar mode: bundler PARKS in scripts_await
//     while the driver shows the feature picker to the wearer, no
//     traffic for the full picker-decision time + BUNDLE_TIMEOUT.
// Earlier 120s value zeroed the PIN while the wearer was still deciding,
// then llRemoteLoadScriptPin failed with "trying to illegally load
// script" after the wearer confirmed. 600s covers any plausible
// decision time without losing the safety-net behaviour for a truly
// stalled session.
float INACTIVITY_TIMEOUT = 600.0;

// Wearer-specific config; never managed by the updater. Excluded from
// LIST_NC reporting and from QUERY_NC wipe (returns EXCLUDE verdict so
// the bundler also drops it from its give batch).
string SETTINGS_NOTECARD = "settings";


/* -------------------- STATE -------------------- */
integer SecureChannel = 0;
integer ListenHandle = 0;


/* -------------------- PROTOCOL -------------------- */
// Bundler → shim: "LIST"
// Shim → bundler: "INV|<csv of collar-namespace script names>"
// Bundler → shim: "QUERY|<name>|<uuid>"
// Shim → bundler: "REPLY|<name>|GIVE"  (missing or stale)
// Shim → bundler: "REPLY|<name>|SKIP"  (already current)
// Bundler → shim: "SWEEP|<csv of names to keep>"
// Shim → bundler: "SWEPT|<csv of names removed>"
// Driver  → shim: "DONE"


/* -------------------- HELPERS -------------------- */

// Collar-namespace test. Sweep and inventory-report use this filter to
// avoid touching unrelated user scripts that may happen to live in the
// collar inventory.
integer is_collar_script(string name) {
    if (name == "leash_holder") return TRUE;
    if (llSubStringIndex(name, "collar_") == 0) return TRUE;
    if (llSubStringIndex(name, "kmod_") == 0) return TRUE;
    if (llSubStringIndex(name, "plugin_") == 0) return TRUE;
    if (llSubStringIndex(name, "control_") == 0) return TRUE;
    return FALSE;
}

// Build CSV of collar-namespace scripts in our prim, for the bundler to
// diff against its own inventory.
string list_inventory() {
    list names = [];
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (is_collar_script(name)) names += [name];
        i += 1;
    }
    return llDumpList2String(names, ",");
}

// Build CSV of inventory of a given non-script type. The settings notecard
// is hard-excluded from the NC listing — never reported, never managed.
// No namespace filter applies here; the bundler's own inventory IS the
// manifest of what's "ours to manage" for non-script types.
string list_inventory_typed(integer inv_type) {
    list names = [];
    integer count = llGetInventoryNumber(inv_type);
    integer i = 0;
    while (i < count) {
        string name = llGetInventoryName(inv_type, i);
        if (inv_type != INVENTORY_NOTECARD || name != SETTINGS_NOTECARD) {
            names += [name];
        }
        i += 1;
    }
    return llDumpList2String(names, ",");
}

// Compare a single named script: GIVE if missing or UUID-mismatched,
// SKIP if present and matches.
string verdict_for(string target_name, key target_uuid) {
    if (llGetInventoryType(target_name) == INVENTORY_NONE) return "GIVE";
    key local_uuid = llGetInventoryKey(target_name);
    if (local_uuid == target_uuid && target_uuid != NULL_KEY) return "SKIP";
    // Stale version present. Remove first so the bundler's
    // llRemoteLoadScriptPin lands on a clean slot.
    llRemoveInventory(target_name);
    return "GIVE";
}

// Typed verdict for animation / object / notecard. Same GIVE / SKIP
// semantics as scripts, plus EXCLUDE for the settings notecard so the
// bundler skips it even if the packager left one in the installer.
// The wipe of stale local items happens here (synchronous llRemoveInventory)
// before the bundler batches the give — that's the "wipe before, send
// after" sequence the wearer asked for.
string verdict_for_typed(string target_name, key target_uuid, integer inv_type) {
    if (inv_type == INVENTORY_NOTECARD && target_name == SETTINGS_NOTECARD) {
        return "EXCLUDE";
    }
    integer have_type = llGetInventoryType(target_name);
    if (have_type == INVENTORY_NONE) return "GIVE";
    key local_uuid = llGetInventoryKey(target_name);
    if (local_uuid == target_uuid && target_uuid != NULL_KEY) return "SKIP";
    // Stale or wrong-type collision: remove before the bundler ships
    // the replacement. Non-scripts arrive via llGiveInventoryList after
    // wearer accept, so the slot must be clear for the drag to land
    // without an auto-rename collision.
    llRemoveInventory(target_name);
    return "GIVE";
}

// Remove any collar-namespace script not in the supplied keep-list.
// Returns CSV of removed names so the bundler can log/report.
string sweep_inventory(list keep) {
    list removed = [];
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    list current = [];
    // Snapshot first; removing during iteration shifts indices.
    while (i < count) {
        current += [llGetInventoryName(INVENTORY_SCRIPT, i)];
        i += 1;
    }
    integer n = llGetListLength(current);
    i = 0;
    while (i < n) {
        string name = llList2String(current, i);
        if (is_collar_script(name)) {
            if (llListFindList(keep, [name]) < 0) {
                llRemoveInventory(name);
                removed += [name];
            }
        }
        i += 1;
    }
    return llDumpList2String(removed, ",");
}

reply(string verb, string body) {
    if (body == "") llWhisper(SecureChannel, verb);
    else llWhisper(SecureChannel, verb + "|" + body);
}

// Park every collar-namespace script that's already present in the prim.
// Replacements arriving later from the bundler hit the dormancy guard in
// their own state_entry (they read the stamped UPDATER_MARKER and park
// themselves); kept scripts (same UUID, not replaced) would otherwise
// keep running through the update window — this loop is what catches
// them. Skips self so the shim can finish its work.
park_collar_scripts() {
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    string self = llGetScriptName();
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (name != self && is_collar_script(name)) {
            llSetScriptState(name, FALSE);
        }
        i += 1;
    }
}

// Reverse the dormancy bracket: restore the original prim description
// from LSD, drop the LSD entry, then re-enable + reset every collar
// script so each one's state_entry runs again with the new bundle and
// the restored (non-marker) desc. Mirrors install_shim's
// activate_collar_scripts, modulo the LSD-backed desc storage.
//
// llResetOtherScript on a disabled script is a no-op, so the
// llSetScriptState(name, TRUE) MUST come first. With both calls in
// order, each script wakes up, re-enters state_entry on its own
// initiative, and runs its normal init — including kmod_bootstrap,
// which handles RLV probe / register.refresh / status announcement
// from inside its own state_entry. That obsoletes the previous
// remote.update.complete broadcast (rev 5).
activate_collar_scripts() {
    string original = llLinksetDataRead(UPDATER_DESC_BACKUP_KEY);
    llSetObjectDesc(original);
    llLinksetDataDelete(UPDATER_DESC_BACKUP_KEY);

    list names = [];
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    string self = llGetScriptName();
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (name != self && is_collar_script(name)) names += [name];
        i += 1;
    }
    integer n = llGetListLength(names);
    i = 0;
    while (i < n) {
        string name = llList2String(names, i);
        llSetScriptState(name, TRUE);
        llResetOtherScript(name);
        i += 1;
    }
}

cleanup_and_die() {
    if (ListenHandle) llListenRemove(ListenHandle);
    ListenHandle = 0;
    llSetTimerEvent(0.0);
    // Disarm the PIN so the collar stops accepting remote loads once the
    // update session is closed.
    llSetRemoteScriptAccessPin(0);
    llRemoveInventory(llGetScriptName());
}


/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        // Dormancy guard — if this script got dragged into the updater
        // prim's inventory during packaging, state_entry parks it so it
        // doesn't try to run update logic in the wrong context.
        if (llGetObjectDesc() == UPDATER_MARKER) {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        SecureChannel = llGetStartParameter();
        if (SecureChannel == 0) {
            // No session channel passed — this script was placed without
            // going through the proper llRemoteLoadScriptPin path. Remove
            // ourselves to avoid leaving a dormant payload in inventory.
            llRemoveInventory(llGetScriptName());
            return;
        }

        // Inhibit the collar's other scripts for the duration of the
        // update. Save the prim's pre-update description to LSD (survives
        // unexpected resets of the shim itself), stamp UPDATER_MARKER,
        // then park every collar-namespace script. Scripts being REPLACED
        // by the bundler hit the dormancy guard in their new state_entry
        // and self-park; scripts being KEPT (same UUID, untouched by the
        // bundle) are caught by park_collar_scripts so they don't keep
        // running against a half-swapped dependency graph. Unwound by
        // activate_collar_scripts on the success/failure paths.
        //
        // Re-entry guard: only save to LSD if the desc isn't already the
        // marker — without it, a state_entry re-run (sim hiccup, manual
        // reset) would overwrite the LSD backup with "COLLAR_UPDATER"
        // itself, and activate would then restore desc=marker and the
        // re-enabled scripts would immediately re-park.
        if (llGetObjectDesc() != UPDATER_MARKER) {
            llLinksetDataWrite(UPDATER_DESC_BACKUP_KEY, llGetObjectDesc());
            llSetObjectDesc(UPDATER_MARKER);
        }
        park_collar_scripts();

        // If the collar was locked when the update started, hold @detach=n
        // ourselves for the duration. When plugin_lock is replaced later in
        // the bundle, the old script's @detach=n drops the moment it's
        // removed from inventory; the new plugin_lock's @detach=n doesn't
        // land until its state_entry runs. Our independent hold (keyed to
        // the shim's script UUID) keeps the collar worn across that gap.
        // Auto-drops when the shim self-deletes, by which time the new
        // plugin_lock has re-issued its own @detach=n if appropriate.
        if (llLinksetDataRead("lock.locked") == "1") {
            llOwnerSay("@detach=n");
        }

        // Open a listen scoped to the secure channel. Same-owner filtering
        // happens in the listen handler (the bundler's key is not known in
        // advance — we only know it must share the wearer's owner UUID,
        // which is the llRemoteLoadScriptPin precondition anyway).
        // NULL_KEY rather than "" so the implicit string→key cast is
        // explicit; the open-filter aspect is intentional.
        ListenHandle = llListen(SecureChannel, "", NULL_KEY, "");

        // Arm the inactivity watchdog.
        llSetTimerEvent(INACTIVITY_TIMEOUT);

        // Signal to the bundler that we are listening and ready to answer.
        llWhisper(SecureChannel, "READY");
    }

    listen(integer channel, string name, key id, string message) {
        if (channel != SecureChannel) return;
        if (llGetOwnerKey(id) != llGetOwner()) return;

        // Any activity resets the inactivity watchdog.
        llSetTimerEvent(INACTIVITY_TIMEOUT);

        list parts = llParseString2List(message, ["|"], []);
        string verb = llList2String(parts, 0);

        if (verb == "DONE") {
            // Update applied successfully. Restore the original prim
            // description from LSD and re-enable + reset every collar
            // script — each script's state_entry re-runs and runs its
            // own startup logic. kmod_bootstrap's state_entry is where
            // the RLV probe / register.refresh / status announcement
            // live, so resetting it directly obsoletes the previous
            // remote.update.complete broadcast hook.
            activate_collar_scripts();
            cleanup_and_die();
            return;
        }

        if (verb == "LIST") {
            reply("INV", list_inventory());
            return;
        }

        if (verb == "QUERY") {
            // QUERY|<name>|<uuid>
            if (llGetListLength(parts) < 3) return;
            string target_name = llList2String(parts, 1);
            key target_uuid = (key)llList2String(parts, 2);
            string v = verdict_for(target_name, target_uuid);
            reply("REPLY", target_name + "|" + v);
            return;
        }

        if (verb == "SWEEP") {
            // SWEEP|<csv of names to keep>. Empty CSV would mean "remove
            // everything"; refuse that as a footgun guard — the bundler
            // should already skip SWEEP when its own inventory was empty.
            string csv = "";
            if (llGetListLength(parts) >= 2) csv = llList2String(parts, 1);
            list keep = [];
            if (csv != "") keep = llCSV2List(csv);
            if (llGetListLength(keep) == 0) {
                reply("SWEPT", "");
                return;
            }
            reply("SWEPT", sweep_inventory(keep));
            return;
        }

        // -- Non-script types: animations / objects / notecards --
        // Same pattern as LIST + QUERY for scripts, but no SWEEP — items
        // in the collar not in the bundler are wearer's customs and stay
        // untouched. Wipe of stale items happens inside verdict_for_typed;
        // the actual give of new versions is the bundler's batched
        // llGiveInventoryList after all queries complete.

        if (verb == "LIST_ANIM") {
            reply("ANIM", list_inventory_typed(INVENTORY_ANIMATION));
            return;
        }
        if (verb == "QUERY_ANIM") {
            if (llGetListLength(parts) < 3) return;
            string anim_name = llList2String(parts, 1);
            key    anim_uuid = (key)llList2String(parts, 2);
            string v = verdict_for_typed(anim_name, anim_uuid, INVENTORY_ANIMATION);
            reply("REPLY_ANIM", anim_name + "|" + v);
            return;
        }

        if (verb == "LIST_OBJ") {
            reply("OBJ", list_inventory_typed(INVENTORY_OBJECT));
            return;
        }
        if (verb == "QUERY_OBJ") {
            if (llGetListLength(parts) < 3) return;
            string obj_name = llList2String(parts, 1);
            key    obj_uuid = (key)llList2String(parts, 2);
            string v = verdict_for_typed(obj_name, obj_uuid, INVENTORY_OBJECT);
            reply("REPLY_OBJ", obj_name + "|" + v);
            return;
        }

        if (verb == "LIST_NC") {
            reply("NC", list_inventory_typed(INVENTORY_NOTECARD));
            return;
        }
        if (verb == "QUERY_NC") {
            if (llGetListLength(parts) < 3) return;
            string nc_name = llList2String(parts, 1);
            key    nc_uuid = (key)llList2String(parts, 2);
            string v = verdict_for_typed(nc_name, nc_uuid, INVENTORY_NOTECARD);
            reply("REPLY_NC", nc_name + "|" + v);
            return;
        }
    }

    timer() {
        // Inactivity watchdog: bundler has gone silent. Activate the
        // parked scripts so the wearer gets a working collar back (the
        // half-applied bundle may be inconsistent, but a silent-locked
        // collar is worse — they can retry the update or factory-reset
        // from there).
        activate_collar_scripts();
        cleanup_and_die();
    }

    changed(integer change) {
        // If the collar changes ownership or is unlinked mid-update,
        // abort cleanly. Activate even though we're aborting — leaving
        // the collar's scripts parked silently after an owner change
        // would surprise the new wearer.
        if (change & (CHANGED_OWNER | CHANGED_LINK)) {
            activate_collar_scripts();
            cleanup_and_die();
        }
    }
}

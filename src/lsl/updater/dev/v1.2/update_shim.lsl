/*--------------------
SCRIPT: update_shim.lsl  (v1.2)
VERSION: 1.2
REVISION: 0
PURPOSE: Transient payload deposited into the collar by updater_driver via
  llRemoteLoadScriptPin. Runs inside the collar, answers inventory and
  ship-decision queries from updater_bundler over the start_param channel,
  sweeps superseded collar-namespace scripts, and orchestrates run-state
  for the swap. Self-deletes on DONE or inactivity timeout.
ARCHITECTURE (v1.2 — no collar dormancy guard): the shim is the sole
  orchestrator of run-state. On the collar it does NOT stamp any marker on
  the prim description; instead park_collar_scripts disables every existing
  collar-namespace script directly (llSetScriptState FALSE), and the bundler
  ships new/replacement scripts with running=FALSE so they land stopped.
  The whole graph stays quiet until activate_collar_scripts enables +
  llResetOtherScript-s every collar-namespace script at the end — so each
  re-enters state_entry with the full new bundle live (kmod_bootstrap's RLV
  probe / register.refresh / status announcement fire as a consequence).
  The collar's description is never touched by update (install_shim brands
  it). UPDATER_MARKER is used ONLY as this shim's own staging self-park:
  when it's sitting in the updater prim (desc == UPDATER_MARKER) it disables
  itself; loaded into a collar (with a secure channel) it runs. Orphaned plugin.reg.<ctx> / acl.policycontext:<ctx>
  entries from swept scripts are pruned by collar_kernel on its next
  inventory tick. "Kamikaze" pattern from OpenCollar's oc_update_shim.
--------------------*/


/* -------------------- CONSTANTS -------------------- */
// Staging marker — lives ONLY on the updater prim's description. This shim
// self-parks when it sees this on its own prim (it's sitting staged in the
// updater, not loaded into a collar). In v1.2 the shim NEVER stamps a
// marker on a collar: it drives collar run-state directly via
// llSetScriptState and leaves the collar's description untouched (install
// brands it instead). So the marker can't get stuck on a worn collar,
// and the collar scripts carry no dormancy guard.
string UPDATER_MARKER = "D/s Collar Updater -- v1.2";

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

// Grace period between DONE and teardown. llRemoteLoadScriptPin / llGiveInventory
// are asynchronous, so when the driver says DONE the last scripts may still be
// landing. We wait this long before activate_collar_scripts + self-delete so the
// prim is fully populated before we restore the desc, reset the scripts, and go.
float SETTLE_DELAY = 5.0;

// Wearer-specific config; never managed by the updater. Excluded from
// LIST_NC reporting and from QUERY_NC wipe (returns EXCLUDE verdict so
// the bundler also drops it from its give batch).
string SETTINGS_NOTECARD = "settings";


/* -------------------- STATE -------------------- */
integer SecureChannel = 0;
integer ListenHandle = 0;
integer Finishing = FALSE;   // DONE received; settling before teardown (SETTLE_DELAY)


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

// Re-enable + reset every collar script so each one's state_entry runs
// again with the new bundle live. Update mode does NOT touch the collar's
// description (install_shim brands it; an update leaves the wearer's name
// and install-time brand in place).
//
// llResetOtherScript on a disabled script is a no-op, so the
// llSetScriptState(name, TRUE) MUST come first. With both calls in
// order, each script wakes up, re-enters state_entry on its own
// initiative, and runs its normal init — including kmod_bootstrap,
// which handles RLV probe / register.refresh / status announcement
// from inside its own state_entry.
activate_collar_scripts() {
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
        // update by stopping them directly — no desc marker is stamped on
        // the collar in v1.2. park_collar_scripts disables every existing
        // collar-namespace script; scripts the bundler then ships arrive
        // stopped (running=FALSE), so the whole graph stays quiet until
        // activate_collar_scripts enables + resets everything at the end.
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

        // Settling after DONE — ignore any late traffic so it can't reset the
        // settle timer back to the inactivity window.
        if (Finishing) return;

        // Any activity resets the inactivity watchdog.
        llSetTimerEvent(INACTIVITY_TIMEOUT);

        list parts = llParseString2List(message, ["|"], []);
        string verb = llList2String(parts, 0);

        if (verb == "DONE") {
            // Update applied. Don't tear down yet: the bundler's last script
            // give(s) may still be landing (async). Arm the settle delay and
            // let timer() restore the desc, reset the scripts, and self-delete
            // once the prim is fully populated.
            Finishing = TRUE;
            llSetTimerEvent(SETTLE_DELAY);
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
        // Two paths converge here, both ending in restore + teardown:
        //   - SETTLE_DELAY after DONE (Finishing): the bundle is complete and
        //     in-flight scripts have had time to land; finish cleanly.
        //   - INACTIVITY_TIMEOUT of silence: the session died; activate anyway
        //     so the wearer gets a working collar back (a half-applied bundle
        //     beats a silent-locked collar — they can retry or factory-reset).
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

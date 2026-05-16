/*--------------------
SCRIPT: update_shim.lsl
VERSION: 1.10
REVISION: 4
PURPOSE: Transient payload deposited into the collar by updater_driver via
  llRemoteLoadScriptPin. Runs inside the collar, answers inventory and
  ship-decision queries from updater_bundler over the start_param channel,
  and sweeps stale collar-namespace scripts on demand. Self-deletes on
  DONE or inactivity timeout.
ARCHITECTURE: No link_message interaction with the rest of the collar.
  Orphaned plugin.reg.<ctx> / acl.policycontext:<ctx> entries left by
  swept scripts are cleaned up by collar_kernel's prune_missing_scripts on
  its next inventory tick — the shim does not touch LSD itself.
  "Kamikaze" pattern from OpenCollar's oc_update_shim.
CHANGES:
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
// Dormancy marker set on the installer's bundler prim. Any collar script
// that auto-starts there reads the description and parks itself.
string UPDATER_MARKER = "COLLAR_UPDATER";

// Inactivity window. If no message arrives from the bundler for this many
// seconds, assume the update died and clean up. 120s comfortably covers
// the 3s per-script throttle of llRemoteLoadScriptPin across a ~30 script
// package, with slack.
float INACTIVITY_TIMEOUT = 120.0;

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
        // Inactivity watchdog: bundler has gone silent. Disarm, self-delete,
        // leave the collar in whatever half-state the update reached — the
        // wearer can reattach the installer to retry.
        cleanup_and_die();
    }

    changed(integer change) {
        // If the collar changes ownership or is unlinked mid-update, abort
        // cleanly rather than continuing against a shifted target.
        if (change & (CHANGED_OWNER | CHANGED_LINK)) {
            cleanup_and_die();
        }
    }
}

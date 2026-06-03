/*--------------------
MODULE: collar_kernel.lsl
VERSION: 1.10
REVISION: 7
PURPOSE: Plugin registry, lifecycle management, heartbeat monitoring
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- v1.1 rev 7: Heap-pressure fixes for the plugin-count growth path
  (plugin_strip + plugin_outfits pushed the linkset to a stack-heap
  collision at boot). Four hot loops rewritten:
  * prune_dead_plugins and prune_missing_scripts now iterate the
    registry backward and call llDeleteSubList in place. The previous
    pattern rebuilt three parallel new_* lists via `+=` inside the
    scan, allocating O(N²) on every heartbeat / inv-sweep even when
    nothing was pruned. Common-case cost drops to zero allocations.
  * queue_add stops rebuilding RegistrationQueue via `+=` to drop one
    matching context; finds-then-deletes the stride instead.
  * discover_plugins's KnownScriptUUIDs rebuild pre-allocates via
    list doubling and fills with llListReplaceList (analyzer-flagged
    O(N²) at the `+=` site).
  Removed unused REG_CONTEXT stride constant — the refactored prune
  paths no longer reference it.
- v1.1 rev 6: Owner-change LSD wipe safeguard. On any detected owner
  change (runtime CHANGED_OWNER OR cold-start mismatch between the
  persisted safeguard.last_owner key and llGetOwner()), kernel calls
  llLinksetDataReset(), re-writes safeguard.last_owner with the new
  owner, broadcasts kernel.reset.factory so plugins clear their
  in-memory state, then resets itself. Ensures customers get a clean
  slate when the collar is transferred from creator to customer
  through inventory (the path that doesn't fire CHANGED_OWNER on a
  running script).
- v1.1 rev 5: Add dormancy guard in state_entry — script parks itself
  if the prim's object description is "COLLAR_UPDATER" so it stays dormant
  when staged in an updater installer prim.
- v1.1 rev 4: Drop kernel.plugins.list broadcast. Plugins now self-declare
  menu presence via LSD (plugin.reg.<ctx>) and kmod_ui enumerates on the
  linkset_data event. broadcast_plugin_list, handle_plugin_list_request,
  kernel.plugins.request, and PendingPluginListRequest are removed. Also
  drop broadcast_register_now on CHANGED_REGION — the kernel's own registry
  survives the region crossing, and the LastRegionCrossUnix grace window
  already covers dropped pings. prune_missing_scripts now also sweeps
  orphaned plugin.reg.<ctx> and acl.policycontext:<ctx> LSD entries whose
  owning script is no longer in inventory.
- v1.1 rev 3: KERNEL_LIFECYCLE wire-type rename (Phase 1 of bus
  restructuring). kernel.register→kernel.register.declare,
  kernel.registernow→kernel.register.refresh, kernel.pluginlist→
  kernel.plugins.list, kernel.pluginlistrequest→kernel.plugins.request,
  kernel.reset→kernel.reset.soft, kernel.resetall→kernel.reset.factory.
  Plugins still emit old names until Phase 2; this module will not
  register them or respond to their pings until they migrate.
- v1.1 rev 2: Namespaced internal message type strings with "kernel." prefix
  (register_now → kernel.registernow, ping → kernel.ping, etc.).
- v1.1 rev 1: Removed min_acl from registry and registration flow. Plugins no
  longer send min_acl (superseded by LSD policies). Removed route_field to
  AUTH_BUS register_acl and handle_acl_registry_request — auth module no longer
  maintains a plugin ACL registry.
- v1.1 rev 0: Version bump for LSD policy architecture. No functional changes to this module.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;

/* -------------------- CONSTANTS -------------------- */
float   PING_INTERVAL_SEC     = 10.0;
integer PING_TIMEOUT_SEC      = 30;
float   INV_SWEEP_INTERVAL    = 3.0;
float   BATCH_WINDOW_SEC      = 0.1;  // Small batch window during startup burst
float   DISCOVERY_INTERVAL_SEC = 5.0;  // Active plugin discovery interval

/* Registry stride: [context, label, script, script_uuid, last_seen_unix] */
integer REG_STRIDE = 5;
integer REG_LABEL = 1;
integer REG_SCRIPT = 2;
integer REG_SCRIPT_UUID = 3;
integer REG_LAST_SEEN = 4;

/* Plugin operation queue stride: [op_type, context, label, script, timestamp] */
integer QUEUE_STRIDE = 5;
integer QUEUE_OP_TYPE = 0;    // "REG" or "UNREG"
integer QUEUE_CONTEXT = 1;
integer QUEUE_LABEL = 2;
integer QUEUE_SCRIPT = 3;


/* -------------------- STATE -------------------- */
list PluginRegistry = [];           // Active plugin registry
list PluginContexts = [];           // Parallel list for O(1) context lookups
list PluginScripts = [];            // Parallel list for O(1) script lookups
list RegistrationQueue = [];        // Pending operations queue (Unix modprobe style)
integer PendingBatchTimer = FALSE;  // TRUE if batch timer is active
integer LastPingUnix = 0;
integer LastInvSweepUnix = 0;
integer LastDiscoveryUnix = 0;      // Track last active plugin discovery
key LastOwner = NULL_KEY;
integer LastScriptCount = 0;        // Track script count to detect add/remove
integer LastRegionCrossUnix = 0;    // Timestamp of last region crossing

/* -------------------- HELPERS -------------------- */


string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
}

integer now() {
    return llGetUnixTime();
}

integer count_scripts() {
    return llGetInventoryNumber(INVENTORY_SCRIPT);
}


/* -------------------- QUEUE MANAGEMENT (Unix modprobe-style) -------------------- */

// Add operation to queue (deduplicates by context)
// Schedules batch processing if not already scheduled
// Returns: 1 (void function)
//
// PERFORMANCE NOTE: Deduplication is O(n) but intentional:
// - Typical startup has ~15 plugins (n is small)
// - Deduplicating at insertion prevents duplicate operations in batch
// - Guarantees queue contains at most one operation per context
// - Alternative (defer to batch) would process duplicates and cause multiple broadcasts
integer queue_add(string op_type, string context, string label, string script) {
    // Locate any existing queue entry for this context (newest wins) and
    // delete its stride in place, then append. The old implementation
    // rebuilt new_queue via `+=` inside the scan loop — O(N²) heap churn
    // on every registration and a contributor to the kernel's stack-heap
    // pressure under 20+ plugin loads. In-place delete is O(N) read,
    // one allocation when an entry is replaced, zero allocations on the
    // common "new context" path.
    integer found_at = -1;
    integer i = 0;
    integer queue_len = llGetListLength(RegistrationQueue);
    while (i < queue_len) {
        if (llList2String(RegistrationQueue, i + QUEUE_CONTEXT) == context) {
            found_at = i;
            i = queue_len;
        }
        else {
            i += QUEUE_STRIDE;
        }
    }
    if (found_at != -1) {
        RegistrationQueue = llDeleteSubList(RegistrationQueue,
            found_at, found_at + QUEUE_STRIDE - 1);
    }

    RegistrationQueue += [op_type, context, label, script, now()];


    // Schedule batch processing if not already scheduled
    // This creates a small batching window for startup bursts
    if (!PendingBatchTimer) {
        PendingBatchTimer = TRUE;
        llSetTimerEvent(BATCH_WINDOW_SEC);
    }

    return 1;
}

// Process all pending queue operations (atomic batch)
// Returns TRUE if any changes were made to registry
// Resets timer to heartbeat interval after processing
integer process_queue() {
    if (llGetListLength(RegistrationQueue) == 0) {
        // No operations in queue - switch to heartbeat mode
        if (PendingBatchTimer) {
            PendingBatchTimer = FALSE;
            llSetTimerEvent(PING_INTERVAL_SEC);
        }
        return FALSE;
    }

    integer changes_made = FALSE;
    integer i = 0;


    integer reg_queue_len = llGetListLength(RegistrationQueue);
    while (i < reg_queue_len) {
        string op_type = llList2String(RegistrationQueue, i + QUEUE_OP_TYPE);
        string context = llList2String(RegistrationQueue, i + QUEUE_CONTEXT);
        string label = llList2String(RegistrationQueue, i + QUEUE_LABEL);
        string script = llList2String(RegistrationQueue, i + QUEUE_SCRIPT);

        if (op_type == "REG") {
            // Returns TRUE if new plugin OR if existing plugin data changed
            integer reg_delta = registry_upsert(context, label, script);
            if (reg_delta) changes_made = TRUE;
        }
        else if (op_type == "UNREG") {
            integer was_removed = registry_remove(context);
            if (was_removed) changes_made = TRUE;
        }

        i += QUEUE_STRIDE;
    }

    // Clear queue
    RegistrationQueue = [];

    // Reset to heartbeat mode
    PendingBatchTimer = FALSE;
    llSetTimerEvent(PING_INTERVAL_SEC);

    return changes_made;
}

/* -------------------- REGISTRY MANAGEMENT -------------------- */

// Find plugin index in registry by context
integer registry_find(string context) {
    integer idx = llListFindList(PluginContexts, [context]);
    if (idx != -1) {
        return idx * REG_STRIDE;
    }
    return -1;
}

// Add or update plugin in registry
// Returns TRUE if new plugin added OR script UUID changed (recompiled/updated)
// Returns FALSE only if re-registering with identical UUID
integer registry_upsert(string context, string label, string script) {
    integer idx = registry_find(context);

    // Get script UUID - changes when script is recompiled/replaced
    // PERFORMANCE NOTE: llGetInventoryKey() is called on every upsert (intentional):
    // - This is the ONLY way to detect script recompilation
    // - Caching would defeat the purpose (we need to detect UUID changes)
    // - Inventory lookup is O(1) by name, not expensive for single-prim design
    // - Only called during registration bursts, not in steady state
    key script_uuid = llGetInventoryKey(script);

    if (idx == -1) {
        // New plugin - add to registry
        PluginRegistry += [context, label, script, script_uuid, now()];
        PluginContexts += [context];
        PluginScripts += [script];
        return TRUE;
    }
    else {
        // Existing plugin - check if script UUID changed
        key old_uuid = llList2Key(PluginRegistry, idx + REG_SCRIPT_UUID);

        integer uuid_changed = (old_uuid != script_uuid);

        // Update registry (timestamp always updates) - batched for performance
        PluginRegistry = llListReplaceList(PluginRegistry,
            [label, script, script_uuid, now()],
            idx + REG_LABEL,
            idx + REG_LAST_SEEN);

        // Update parallel script list (in case script name changed for same context, though unlikely)
        integer list_idx = idx / REG_STRIDE;
        PluginScripts = llListReplaceList(PluginScripts, [script], list_idx, list_idx);

        // Note: uuid_changed tracked but not logged to reduce spam

        return uuid_changed;
    }
}

// Remove plugin from registry
// Returns TRUE if plugin was removed, FALSE if not found
integer registry_remove(string context) {
    integer idx = registry_find(context);
    if (idx == -1) return FALSE;

    PluginRegistry = llDeleteSubList(PluginRegistry, idx, idx + REG_STRIDE - 1);
    
    integer list_idx = idx / REG_STRIDE;
    PluginContexts = llDeleteSubList(PluginContexts, list_idx, list_idx);
    PluginScripts = llDeleteSubList(PluginScripts, list_idx, list_idx);
    
    return TRUE;
}

// Update last_seen timestamp for plugin
// Returns: 1 (void function)
integer update_last_seen(string context) {
    integer idx = registry_find(context);
    if (idx != -1) {
        PluginRegistry = llListReplaceList(PluginRegistry, [now()], idx + REG_LAST_SEEN, idx + REG_LAST_SEEN);
    }

    return 1;
}

// Remove dead plugins (haven't responded to ping in PING_TIMEOUT_SEC).
//
// Iterates backward and deletes in place. The previous implementation
// built three parallel new_* lists via `+=` inside the scan loop —
// O(N²) heap churn on every heartbeat, even when nothing was pruned.
// Now: zero allocations on the common "no dead plugins" path; only
// the actually-pruned entries cost an llDeleteSubList each.
integer prune_dead_plugins() {
    integer now_unix = llGetUnixTime();

    // Skip pruning during region crossing grace window
    if (LastRegionCrossUnix > 0 &&
        (now_unix - LastRegionCrossUnix) < PING_TIMEOUT_SEC) return 0;
    LastRegionCrossUnix = 0;

    integer cutoff = now_unix - PING_TIMEOUT_SEC;
    integer pruned = 0;

    integer i = llGetListLength(PluginRegistry) - REG_STRIDE;
    while (i >= 0) {
        integer last_seen = llList2Integer(PluginRegistry, i + REG_LAST_SEEN);
        if (last_seen < cutoff) {
            integer list_idx = i / REG_STRIDE;
            PluginRegistry = llDeleteSubList(PluginRegistry, i, i + REG_STRIDE - 1);
            PluginContexts = llDeleteSubList(PluginContexts, list_idx, list_idx);
            PluginScripts  = llDeleteSubList(PluginScripts,  list_idx, list_idx);
            pruned += 1;
        }
        i -= REG_STRIDE;
    }

    return pruned;
}

// Remove plugins whose scripts no longer exist in inventory.
// Also sweeps orphaned plugin.reg.<ctx> and acl.policycontext:<ctx> LSD
// entries whose owning script is gone — the plugin can't run its own
// cleanup in that case, so the kernel prunes on its behalf.
integer prune_missing_scripts() {
    integer pruned = 0;

    // Backward in-place delete (same rationale as prune_dead_plugins):
    // zero allocations when every script is still in inventory, which is
    // the common case in steady-state.
    integer i = llGetListLength(PluginRegistry) - REG_STRIDE;
    while (i >= 0) {
        string script = llList2String(PluginRegistry, i + REG_SCRIPT);
        if (llGetInventoryType(script) != INVENTORY_SCRIPT) {
            integer list_idx = i / REG_STRIDE;
            PluginRegistry = llDeleteSubList(PluginRegistry, i, i + REG_STRIDE - 1);
            PluginContexts = llDeleteSubList(PluginContexts, list_idx, list_idx);
            PluginScripts  = llDeleteSubList(PluginScripts,  list_idx, list_idx);
            pruned += 1;
        }
        i -= REG_STRIDE;
    }

    // LSD sweep: any plugin.reg.<ctx> whose embedded script is no longer in
    // inventory gets deleted, along with its ACL policy sibling. kmod_ui's
    // linkset_data handler picks up the deletions and rebuilds views.
    list reg_keys = llLinksetDataFindKeys("^plugin\\.reg\\.", 0, -1);
    integer rk_len = llGetListLength(reg_keys);
    integer j = 0;
    while (j < rk_len) {
        string k = llList2String(reg_keys, j);
        string entry = llLinksetDataRead(k);
        string scr = llJsonGetValue(entry, ["script"]);
        if (scr != JSON_INVALID && llGetInventoryType(scr) != INVENTORY_SCRIPT) {
            string ctx = llGetSubString(k, 11, -1);  // strip "plugin.reg." prefix
            llLinksetDataDelete(k);
            llLinksetDataDelete("acl.policycontext:" + ctx);
        }
        j++;
    }

    return pruned;
}

/* -------------------- PLUGIN DISCOVERY (Active pull-based detection) -------------------- */

// Track all known script UUIDs to detect new/recompiled scripts.
// Name-agnostic: any unrecognized script triggers register_now,
// letting plugins self-identify via registration protocol.
list KnownScriptUUIDs = [];

integer discover_plugins() {
    integer inv_count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i;
    integer discoveries = 0;

    for (i = 0; i < inv_count; i = i + 1) {
        string script_name = llGetInventoryName(INVENTORY_SCRIPT, i);
        key script_uuid = llGetInventoryKey(script_name);

        // Skip self (kernel)
        if (script_name == llGetScriptName()) jump next_script;

        if (llListFindList(KnownScriptUUIDs, [script_uuid]) == -1) {
            discoveries = discoveries + 1;
        }

        @next_script;
    }

    if (discoveries > 0) {
        // Rebuild known UUIDs from current inventory. Pre-allocate via
        // list doubling and fill with llListReplaceList — the previous
        // `+=` per iteration was O(N²) heap churn (analyzer-flagged) and
        // a contributor to startup memory pressure.
        KnownScriptUUIDs = [];
        if (inv_count > 0) {
            list buf = [""];
            while (llGetListLength(buf) < inv_count) buf = buf + buf;
            KnownScriptUUIDs = llList2List(buf, 0, inv_count - 1);
        }
        integer filled = 0;
        for (i = 0; i < inv_count; i = i + 1) {
            string sn = llGetInventoryName(INVENTORY_SCRIPT, i);
            if (sn != llGetScriptName()) {
                KnownScriptUUIDs = llListReplaceList(KnownScriptUUIDs,
                    [llGetInventoryKey(sn)], filled, filled);
                filled += 1;
            }
        }
        if (filled == 0)             KnownScriptUUIDs = [];
        else if (filled < inv_count) KnownScriptUUIDs = llList2List(KnownScriptUUIDs, 0, filled - 1);
        broadcast_register_now();
    }

    return discoveries;
}

/* -------------------- BROADCASTING -------------------- */

// Request all plugins to register (no time window - event-driven)
broadcast_register_now() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.register.refresh"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);

}

// Heartbeat ping to all plugins
broadcast_ping() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.ping"
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
    // Ping logging disabled - too noisy
}

/* -------------------- OWNER CHANGE DETECTION -------------------- */

// Sentinel LSD key carrying the owner UUID that owned the collar at the
// time of the last successful state_entry. Compared on cold start to
// detect an inventory-transfer ownership change (CHANGED_OWNER does not
// fire when the owner changes while the script is not running). Written
// fresh after every wipe so the next cold start sees a matching value.
string KEY_LAST_OWNER = "safeguard.last_owner";

// Wipe all LSD, broadcast a factory reset so plugins clear in-memory
// state, and reset the kernel itself. Called from CHANGED_OWNER and from
// state_entry's cold-start owner mismatch check. Does not return.
do_owner_change_wipe() {
    llLinksetDataReset();
    llLinksetDataWrite(KEY_LAST_OWNER, (string)llGetOwner());
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.reset.factory"
    ]), NULL_KEY);
    llResetScript();
}

integer check_owner_changed() {
    key current_owner = llGetOwner();
    if (current_owner == NULL_KEY) return FALSE;

    if (LastOwner != NULL_KEY && current_owner != LastOwner) {
        LastOwner = current_owner;
        do_owner_change_wipe();
        return TRUE;  // unreachable; do_owner_change_wipe resets
    }

    LastOwner = current_owner;
    return FALSE;
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_register(string msg) {
    string context = llJsonGetValue(msg, ["context"]);
    if (context == JSON_INVALID) return;
    string label = llJsonGetValue(msg, ["label"]);
    if (label == JSON_INVALID) return;
    string script = llJsonGetValue(msg, ["script"]);
    if (script == JSON_INVALID) return;

    queue_add("REG", context, label, script);
}

handle_pong(string msg) {
    string context = llJsonGetValue(msg, ["context"]);
    if (context == JSON_INVALID) return;
    update_last_seen(context);
    // Pong logging disabled - too noisy
}

handle_soft_reset() {
    PluginRegistry = [];
    PluginContexts = [];
    PluginScripts = [];
    RegistrationQueue = [];
    KnownScriptUUIDs = [];
    PendingBatchTimer = FALSE;
    LastPingUnix = now();
    LastInvSweepUnix = now();
    LastDiscoveryUnix = now();
    llSetTimerEvent(PING_INTERVAL_SEC);
    broadcast_register_now();
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        if (llGetObjectDesc() == "COLLAR_UPDATER") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        // Cold-start owner-change detection. CHANGED_OWNER doesn't fire
        // when ownership transfers while the script isn't running (the
        // typical creator-to-customer inventory transfer path), so we
        // compare against a persistent LSD sentinel. First-ever run on
        // a fresh collar simply records the current owner.
        string saved = llLinksetDataRead(KEY_LAST_OWNER);
        string current = (string)llGetOwner();
        if (saved == "") {
            llLinksetDataWrite(KEY_LAST_OWNER, current);
        } else if (saved != current) {
            do_owner_change_wipe();
            return;  // unreachable; reset above
        }

        LastOwner = llGetOwner();
        PluginRegistry = [];
        PluginContexts = [];
        PluginScripts = [];
        RegistrationQueue = [];
        PendingBatchTimer = FALSE;
        LastPingUnix = now();
        LastInvSweepUnix = now();
        LastDiscoveryUnix = now();
        LastScriptCount = count_scripts();
        KnownScriptUUIDs = [];

        // Immediately broadcast register_now (plugins add to queue)
        broadcast_register_now();

        // Start timer in heartbeat mode (batch timer will override when needed)
        llSetTimerEvent(PING_INTERVAL_SEC);
    }
    
    on_rez(integer start_param) {
        check_owner_changed();
    }
    
    attach(key id) {
        if (id == NULL_KEY) return;
        check_owner_changed();
    }
    
    timer() {
        integer t = llGetUnixTime();
        if (t == 0) return; // Overflow protection

        // DUAL-MODE TIMER: Batch mode (0.1s) or Heartbeat mode (5s)
        if (PendingBatchTimer) {
            // Batch mode: drain the registration queue. Plugins publish their
            // menu presence directly to LSD now, so there is no list broadcast
            // to send after the queue flushes.
            process_queue();
            // process_queue() automatically switches back to heartbeat mode
        }
        else {
            // Heartbeat mode: Periodic maintenance only
            integer ping_elapsed = t - LastPingUnix;
            if (ping_elapsed < 0) ping_elapsed = 0; // Overflow protection

            if (ping_elapsed >= PING_INTERVAL_SEC) {
                broadcast_ping();
                prune_dead_plugins();
                LastPingUnix = t;
            }

            // Periodic inventory sweep: also cleans up orphaned plugin.reg.*
            // and acl.policycontext:* LSD entries (see prune_missing_scripts).
            integer inv_elapsed = t - LastInvSweepUnix;
            if (inv_elapsed < 0) inv_elapsed = 0; // Overflow protection

            if (inv_elapsed >= INV_SWEEP_INTERVAL) {
                prune_missing_scripts();
                LastInvSweepUnix = t;
            }

            // Periodic active plugin discovery
            integer discovery_elapsed = t - LastDiscoveryUnix;
            if (discovery_elapsed < 0) discovery_elapsed = 0; // Overflow protection

            if (discovery_elapsed >= DISCOVERY_INTERVAL_SEC) {
                // Discover new/changed plugins (triggers register_now if found)
                discover_plugins();
                LastDiscoveryUnix = t;
            }
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.register.declare") {
                handle_register(msg);
            }
            else if (msg_type == "kernel.pong") {
                handle_pong(msg);
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                handle_soft_reset();
            }
        }
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            check_owner_changed();
        }

        if (change & CHANGED_REGION) {
            // Region crossing: link messages may be lost, causing stale
            // last_seen timestamps. Record crossing time so prune_dead_plugins()
            // skips culling until one full timeout window has elapsed. The
            // kernel's own registry survives the crossing, and plugin menu
            // presence lives in LSD (also persistent across regions), so no
            // re-registration broadcast is needed.
            LastRegionCrossUnix = llGetUnixTime();
            LastPingUnix = LastRegionCrossUnix;
            LastInvSweepUnix = LastRegionCrossUnix;
            LastDiscoveryUnix = LastRegionCrossUnix;
        }

        if (change & CHANGED_INVENTORY) {
            // Check if SCRIPTS were added/removed (not notecards)
            integer current_script_count = count_scripts();

            if (current_script_count != LastScriptCount) {
                LastScriptCount = current_script_count;

                // Clear registry, known UUIDs, and queue — trigger re-registration
                PluginRegistry = [];
                PluginContexts = [];
                PluginScripts = [];
                RegistrationQueue = [];
                KnownScriptUUIDs = [];
                PendingBatchTimer = FALSE;
                llSetTimerEvent(PING_INTERVAL_SEC);
                broadcast_register_now();
            }
        }
    }
}

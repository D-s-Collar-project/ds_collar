/*--------------------
SCRIPT: install_shim.lsl
VERSION: 1.10
REVISION: 4
PURPOSE: Empty-target receiver for the installer's fresh-install path. Wearer
  drops this single script into an object they want to turn into a collar;
  it sets a remote-load PIN, announces itself on EXTERNAL_ACL_REPLY_CHAN, and
  parks until the installer ships the chosen script set (Minimal / Full /
  Bespoke). Self-destructs on install.shim.done from the installer.
ARCHITECTURE: Lives alone in the fresh target object. Uses kmod_remote's
  well-known external channels so the installer's permanent listener picks
  up the ready broadcast without changes. No coexistence with collar scripts —
  state_entry refuses and self-deletes if any collar-namespace script is
  already present (drop into a non-empty target is a user error, not a
  reinstall path; that's what 'Update Collar' is for).
CHANGES:
- v1.1 rev 4: Stamp prim description with "D/s Collar v1.1" (BRAND_DESC) on the success path instead of restoring the OriginalDesc — a fresh prim's blank desc was a missed branding opportunity. Failure paths still restore OriginalDesc. Tracked via Activated flag so cleanup_and_die doesn't clobber the brand.
- v1.1 rev 3: Inhibit the half-installed collar during the bundle phase. state_entry now stamps the prim with UPDATER_MARKER after the safety checks; every collar script's dormancy guard (universal across 33 scripts) sees the marker in their state_entry and parks via llSetScriptState(self, FALSE). install.shim.done now calls activate_collar_scripts before cleanup_and_die: clear the desc, then llSetScriptState(name, TRUE) + llResetOtherScript(name) per script so they re-enter state_entry and init normally. OriginalDesc preserved across the marker stamp and restored on every cleanup path (success and failure).
- v1.1 rev 2: Fix ready-message instruction — installer's permanent REPLY_CHAN listener picks up the broadcast automatically, so the wearer should NOT touch the installer again (doing so triggered 'session already in progress' because Phase = shim_offer_waiting).
- v1.1 rev 1: Initial implementation. Mirrors update_shim's PIN/secure-channel
  shape but doesn't speak the LIST/QUERY diff protocol — the target is empty
  by construction, so the bundler ships unconditionally.
--------------------*/


/* -------------------- EXTERNAL PROTOCOL CHANNELS -------------------- */
// Must match kmod_remote's EXTERNAL_ACL_QUERY_CHAN / EXTERNAL_ACL_REPLY_CHAN
// so the installer's permanent listener catches the ready broadcast.
integer EXTERNAL_ACL_QUERY_CHAN = -8675309;
integer EXTERNAL_ACL_REPLY_CHAN = -8675310;


/* -------------------- CONSTANTS -------------------- */
// Dormancy marker set on installer prims. If this script was dragged into
// the installer linkset during packaging, state_entry parks it instead of
// trying to announce.
string UPDATER_MARKER = "COLLAR_UPDATER";

// Authoritative prim description stamped on the successfully-installed
// collar. Replaces whatever was there before (typically "" for a fresh
// rezzed prim) so the new collar advertises itself clearly. On failure
// paths the original description is restored instead.
string BRAND_DESC = "D/s Collar v1.1";

// How often we re-broadcast install.shim.ready until the installer acks.
// 5 seconds is a comfortable cadence — fast enough that the wearer's next
// touch on the installer finds us, slow enough not to spam region chat.
float BROADCAST_INTERVAL = 5.0;

// How long we keep broadcasting if no installer acks. Wearer probably gave
// up or the installer is out of range; self-delete rather than sit there
// shouting forever.
float BROADCAST_TIMEOUT = 120.0;

// After ack, how long we wait for the actual install to complete before
// assuming the installer crashed and giving up. Generous because a Full
// install ships ~35 scripts at 3s each = ~105s minimum.
float INSTALL_TIMEOUT = 300.0;


/* -------------------- STATE -------------------- */
integer Pin = 0;
integer ListenHandle = 0;
key     InstallerKey = NULL_KEY;
integer Broadcasting = TRUE;
float   ElapsedBroadcast = 0.0;

// Saved object description from before we stamped UPDATER_MARKER. Restored
// in cleanup_and_die on the failure paths (broadcast/install timeout,
// CHANGED_OWNER) so the prim returns to its pre-install state. Success
// path overwrites with BRAND_DESC instead.
string  OriginalDesc = "";

// Set in activate_collar_scripts on the success path so cleanup_and_die
// knows not to clobber the brand description it just stamped.
integer Activated = FALSE;


/* -------------------- HELPERS -------------------- */

// Collar-namespace test. Mirrors update_shim / updater_bundler so all three
// agree on what counts as "ours" for refuse-on-existing.
integer is_collar_script(string name) {
    if (name == "leash_holder") return TRUE;
    if (llSubStringIndex(name, "collar_") == 0) return TRUE;
    if (llSubStringIndex(name, "kmod_") == 0) return TRUE;
    if (llSubStringIndex(name, "plugin_") == 0) return TRUE;
    if (llSubStringIndex(name, "control_") == 0) return TRUE;
    return FALSE;
}

// Refuse if the target already has collar scripts. The wearer is supposed
// to drop us into an empty object; if there are collar scripts already
// the right tool is 'Update Collar', not a fresh install (which would
// collide with the existing kernel).
integer target_is_empty() {
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    string self = llGetScriptName();
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (name != self && is_collar_script(name)) return FALSE;
        i += 1;
    }
    return TRUE;
}

integer random_pin() {
    // Non-zero positive 31-bit integer; PIN must be != 0 for
    // llRemoteLoadScriptPin to work.
    return (integer)llFrand(2147483600.0) + 1;
}

broadcast_ready() {
    string msg = llList2Json(JSON_OBJECT, [
        "type",   "install.shim.ready",
        "shim",   (string)llGetKey(),
        "pin",    (string)Pin,
        "wearer", (string)llGetOwner()
    ]);
    llRegionSay(EXTERNAL_ACL_REPLY_CHAN, msg);
}

cleanup_and_die() {
    if (ListenHandle) llListenRemove(ListenHandle);
    ListenHandle = 0;
    llSetTimerEvent(0.0);
    // Disarm the PIN so the installer can no longer load scripts into us
    // once the session is closed.
    llSetRemoteScriptAccessPin(0);
    // Restore original desc only on failure paths. Success path already
    // stamped BRAND_DESC in activate_collar_scripts and we mustn't clobber
    // it.
    if (!Activated) {
        llSetObjectDesc(OriginalDesc);
    }
    llRemoveInventory(llGetScriptName());
}

// Unpark every collar script that was loaded into this prim while the
// dormancy marker was set. Stamps BRAND_DESC FIRST so the parked scripts'
// state_entry sees the new clean description (not the marker) and doesn't
// re-park themselves when llResetOtherScript fires. Activated flag tells
// cleanup_and_die to keep the brand intact.
// Sequence per script: enable (parked scripts ignore llResetOtherScript),
// then reset → state_entry runs, sees BRAND_DESC, initializes normally.
activate_collar_scripts() {
    llSetObjectDesc(BRAND_DESC);
    Activated = TRUE;

    list names = [];
    integer count = llGetInventoryNumber(INVENTORY_SCRIPT);
    integer i = 0;
    string self = llGetScriptName();
    while (i < count) {
        string name = llGetInventoryName(INVENTORY_SCRIPT, i);
        if (name != self) names += [name];
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


/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        // Dormancy guard for accidental drag into the installer prim.
        if (llGetObjectDesc() == UPDATER_MARKER) {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        // Refuse if the target already has collar scripts.
        if (!target_is_empty()) {
            llRegionSayTo(llGetOwner(), 0,
                "install_shim: target already has collar scripts. "
              + "Use 'Update Collar' from the installer to update an "
              + "existing collar; this shim is only for empty objects.");
            llRemoveInventory(llGetScriptName());
            return;
        }

        Pin = random_pin();
        llSetRemoteScriptAccessPin(Pin);

        // Inhibit the half-installed collar: stamp the prim with the
        // dormancy marker so every script the bundler loads via
        // llRemoteLoadScriptPin sees it in state_entry and parks itself.
        // The wearer can't accidentally use a partial collar (touches,
        // attachments, timers all stop at the dormancy gate). Cleared
        // and resets fired in activate_collar_scripts when we receive
        // install.shim.done.
        OriginalDesc = llGetObjectDesc();
        llSetObjectDesc(UPDATER_MARKER);

        // Listen for the installer's ack and later for install.shim.done.
        // Open filter on sender; we filter by same-owner in the handler
        // since the installer key isn't known in advance.
        ListenHandle = llListen(EXTERNAL_ACL_QUERY_CHAN, "", NULL_KEY, "");

        Broadcasting = TRUE;
        ElapsedBroadcast = 0.0;
        broadcast_ready();
        llSetTimerEvent(BROADCAST_INTERVAL);

        llRegionSayTo(llGetOwner(), 0,
            "install_shim: ready. Waiting for the installer to detect "
          + "this prim. (No further touch needed.)");
    }

    listen(integer channel, string name, key id, string message) {
        if (channel != EXTERNAL_ACL_QUERY_CHAN) return;
        // Same-owner filter — only our wearer's installer should reach us.
        if (llGetOwnerKey(id) != llGetOwner()) return;

        string mtype = llJsonGetValue(message, ["type"]);

        // Installer is acknowledging our ready broadcast. Lock in the
        // installer key, stop broadcasting, and switch the watchdog to
        // the longer install timeout.
        if (mtype == "install.shim.ack") {
            string shim_str = llJsonGetValue(message, ["shim"]);
            if (shim_str == JSON_INVALID) return;
            if ((key)shim_str != llGetKey()) return;

            InstallerKey = id;
            Broadcasting = FALSE;
            llSetTimerEvent(INSTALL_TIMEOUT);
            return;
        }

        // Installer signalling that the install is complete. Unpark the
        // collar scripts (they were parked by the dormancy marker we set
        // in state_entry), then disarm PIN and self-delete.
        if (mtype == "install.shim.done") {
            string done_shim = llJsonGetValue(message, ["shim"]);
            if (done_shim == JSON_INVALID) return;
            if ((key)done_shim != llGetKey()) return;
            // Only honour DONE from the installer that acked us. Stray
            // DONE from another updater in the sim shouldn't kill us.
            if (InstallerKey != NULL_KEY && id != InstallerKey) return;

            activate_collar_scripts();
            cleanup_and_die();
            return;
        }
    }

    timer() {
        if (Broadcasting) {
            ElapsedBroadcast += BROADCAST_INTERVAL;
            if (ElapsedBroadcast >= BROADCAST_TIMEOUT) {
                // Nobody ever acked. Give up; wearer can drop us again later.
                llRegionSayTo(llGetOwner(), 0,
                    "install_shim: no installer found. Removing self.");
                cleanup_and_die();
                return;
            }
            broadcast_ready();
            return;
        }

        // Acked but install never completed. Bundler probably crashed
        // mid-flight; leave the target in whatever partial state it
        // reached and let the wearer reattempt.
        llRegionSayTo(llGetOwner(), 0,
            "install_shim: install timed out. Removing self.");
        cleanup_and_die();
    }

    changed(integer change) {
        // Owner change or unlink mid-install — abort cleanly rather than
        // continuing against a shifted target.
        if (change & (CHANGED_OWNER | CHANGED_LINK)) {
            cleanup_and_die();
        }
    }

    on_rez(integer start_param) {
        llResetScript();
    }
}

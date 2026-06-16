/*--------------------
SCRIPT: install_shim.lsl  (v1.2)
VERSION: 1.2
REVISION: 0
PURPOSE: Empty-target receiver for the installer's fresh-install path. Wearer
  drops this single script into an object they want to turn into a collar;
  it sets a remote-load PIN, announces itself on EXTERNAL_ACL_REPLY_CHAN, and
  parks until the installer ships the chosen script set (Minimal / Full /
  Bespoke). Self-destructs on install.shim.done from the installer.
ARCHITECTURE (v1.2 — no target dormancy guard): lives alone in the fresh
  target object; refuses + self-deletes if any collar-namespace script is
  already present ('Update Collar' is the path for an existing collar). It
  does NOT stamp a marker on the target — the bundler ships the fresh
  scripts running=FALSE so they land stopped, and activate_collar_scripts
  enables + llResetOtherScript-s them all at the end (each runs state_entry
  with the full bundle live). On success it brands the prim description from
  the wearer's original object name via branded_desc(); failure paths
  restore OriginalDesc untouched. UPDATER_MARKER is used
  ONLY as this shim's own staging self-park in the updater prim. Uses
  kmod_remote's well-known external channels so the installer's permanent
  listener catches the ready broadcast.
--------------------*/


/* -------------------- EXTERNAL PROTOCOL CHANNELS -------------------- */
// Must match kmod_remote's EXTERNAL_ACL_QUERY_CHAN / EXTERNAL_ACL_REPLY_CHAN
// so the installer's permanent listener catches the ready broadcast.
integer EXTERNAL_ACL_QUERY_CHAN = -8675309;
integer EXTERNAL_ACL_REPLY_CHAN = -8675310;


/* -------------------- CONSTANTS -------------------- */
// Staging marker — lives only on the updater/installer prim's description.
// If this script is sitting staged there (desc == UPDATER_MARKER) its
// state_entry parks it instead of announcing. In v1.2 the shim NEVER stamps
// a marker on the target: fresh scripts ship running=FALSE (land stopped),
// and activate_collar_scripts enables + resets them at the end. The target
// desc is only ever set once, on success, to the brand.
string UPDATER_MARKER = "D/s Collar Updater -- v1.2";

// Brand appended to the prim description on a successful install. If the
// prim had no description (typical fresh rezzed prim) the desc becomes just
// this; if the wearer had named the object, we keep their name and append
// the brand after BRAND_SEP — e.g. "Jane Doe's Collar -- D/s Collar v1.2".
// On failure paths the original description is restored instead.
string BRAND_DESC = "D/s Collar v1.2";

// Separator between the wearer's object name and the brand. Spaced so the
// result reads naturally; change to "--" if you want it tight.
string BRAND_SEP = " -- ";

// How often we re-broadcast install.shim.ready until the installer acks.
// 5 seconds is a comfortable cadence — fast enough that the wearer's next
// touch on the installer finds us, slow enough not to spam region chat.
float BROADCAST_INTERVAL = 5.0;

// How long we keep broadcasting if no installer acks. Wearer probably gave
// up or the installer is out of range; self-delete rather than sit there
// shouting forever.
float BROADCAST_TIMEOUT = 120.0;

// After ack, how long we wait for install.shim.done before assuming the
// installer crashed and giving up. Has to span both the wearer's
// decision time (Bespoke toggles, Minimal/Full picker) AND the full
// shipping loop (BUNDLE_TIMEOUT = 240s in the driver). Earlier 300s
// value timed out mid-decision when the wearer took >5min on the
// Bespoke walk, which zeroed the PIN and caused llRemoteLoadScriptPin
// to fail with "trying to illegally load script" on the next dispatch.
// 600s gives ~10 minutes of total margin.
float INSTALL_TIMEOUT = 600.0;

// Grace period between install.shim.done and teardown. The bundler ships scripts
// asynchronously (llRemoteLoadScriptPin / llGiveInventory), so the last items may
// still be landing when DONE arrives. We wait this long before
// activate_collar_scripts + self-delete so the fresh collar is fully populated
// before we brand the desc, reset the scripts, and go.
float SETTLE_DELAY = 5.0;


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

// install.shim.done received; settling before teardown (SETTLE_DELAY).
integer Finishing = FALSE;


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
// Compose the branded description from the wearer's original prim name.
// Blank original → just the brand; otherwise "<original><sep><brand>".
string branded_desc() {
    if (OriginalDesc == "") return BRAND_DESC;
    return OriginalDesc + BRAND_SEP + BRAND_DESC;
}

activate_collar_scripts() {
    llSetObjectDesc(branded_desc());
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

        // Capture the wearer's prim description now (before any branding) so
        // branded_desc() can keep their object name. No marker is stamped on
        // the target in v1.2 — scripts the bundler ships arrive stopped
        // (running=FALSE), so the half-installed collar stays inert until
        // activate_collar_scripts enables + resets everything at the end.
        OriginalDesc = llGetObjectDesc();

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

        // Settling after DONE — ignore late traffic so it can't reset the
        // settle timer back to the install window.
        if (Finishing) return;

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

            // Don't tear down yet: the bundler's last script give(s) may still
            // be landing (async). Arm the settle delay; timer() does the
            // activate + self-delete once the prim is fully populated.
            Finishing = TRUE;
            llSetTimerEvent(SETTLE_DELAY);
            return;
        }
    }

    timer() {
        // Settle delay after install.shim.done elapsed — the prim is fully
        // populated; brand the desc, re-enable + reset the scripts, self-delete.
        if (Finishing) {
            activate_collar_scripts();
            cleanup_and_die();
            return;
        }

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

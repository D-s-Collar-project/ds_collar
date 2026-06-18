/*--------------------
MODULE: kmod_bootstrap.lsl
VERSION: 1.2
REVISION: 7
CHANGES:
- v1.2 rev 7 (sandbox): publish rlv.active to LSD in announce_status ("1"/"0" per RLV detection). CROSS-MODULE: kmod_ui reads it to hide RLV-required plugins (mask bit 0x40) when RLV is off. Written each boot (and re-detected on attach), so it tracks the real state.
- v1.2 rev 6: Touch-guard. Clears boot.ready at boot start and sets it "1" at "Collar startup complete", so kmod_ui ignores touches until startup finishes. Automates the manual "don't touch until startup done" workaround — a touch mid-boot fires kmod_ui's menu render + view rebuild, piling concurrent LSD writes/bus traffic onto the plugin-registration window (which under load drops registrations and strands plugins from the menu). CROSS-MODULE CONTRACT: boot.ready, read by kmod_ui. Also tightened the RLV probe: 3 retries (was 10), first at +2s (was +5s), 30s deadline (was 60s) — caps the no-RLV touch-guard wait at 30s.
- v1.2 rev 4: Card streaming is gated on settings.cardapplied, not the readiness sentinel. The notecard is an OVERRIDE, never a requirement: kmod_settings now stamps readiness (settings.bootstrapped) immediately and independently, so gating the stream on the readiness sentinel was both wrong (a missed handshake left readiness unstamped = no UI) and circular. We stream once per fresh boot (card present + settings.cardapplied unset) and the self-heal retry re-points to the same marker — now non-fatal, since readiness no longer waits on the card. Fixes "new owner / blank-card collar gets no UI".
- v1.2 rev 3: Self-healing card-stream handshake. The 'starting' timer re-streams the card while the sentinel is still unset and a card is present, so a missed first settings.card.streamed (kmod_settings still resetting on a fresh owner-change boot) is recovered until kmod_settings processes one and stamps the sentinel. Fixes "new owner gets no UI" — the owner-change re-bootstrap path never exercised on an already-bootstrapped collar. Bounded by the sentinel check + bootstrap timeout.
- v1.2 rev 2: Owns the settings-notecard I/O now (relocated from kmod_settings, which collided at ~90% of the Mono budget when it parsed). At boot, if the bootstrap sentinel is unset, stream_card() reads the card line-by-line and deposits each as a raw key=value into LSD (dumb deposit: comments/blanks skipped, user.* refused, dotted keys only), then emits settings.card.streamed so kmod_settings converts it. Reload/Reset/card-edit arrive as settings.card.restream (handled in both states). We build no records and hold no parse memory — this module sits at ~46%. CROSS-MODULE CONTRACT: streamed key names + settings.card.streamed / settings.card.restream.
- v1.2 rev 1: Owner announcement + names_ready read the user-record roster (user.<uuid> acl-5 records, rank-ordered) instead of the retired access.owner- keys; multi-owner derives from owner count.
PURPOSE: Startup coordination, RLV detection, status announcement, settings-card streaming
ARCHITECTURE: Consolidated message bus lanes
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer REMOTE_BUS       = 600;
integer SETTINGS_BUS     = 800;

/* -------------------- RLV DETECTION CONFIG -------------------- */
// 3 probes, first at +2s (then +7s, +12s), give up at the 30s deadline. An RLV
// viewer answers the first probe in ~1s; a no-RLV viewer resolves at 30s (which
// is also the worst-case touch-guard wait, since boot.ready lifts at startup
// complete).
integer RLV_PROBE_TIMEOUT_SEC = 30;
integer RLV_RETRY_INTERVAL_SEC = 5;
integer RLV_MAX_RETRIES = 3;
integer RLV_INITIAL_DELAY_SEC = 2;

// Probe multiple channels for better compatibility
integer UseFixed4711;
integer UseRelayChan;
integer RELAY_CHAN = -1812221819;
integer ProbeRelayBothSigns;  // Also try positive relay channel

/* -------------------- SETTINGS KEYS -------------------- */
// Roster reads come from user.<uuid> records (see owner_rows).
string NAME_LOADING = "(loading...)";

// Card-override applied marker (written by kmod_settings once the streamed card
// has been converted/applied). We stream the card only while THIS is unset — NOT
// the readiness sentinel: the notecard is an override, never a requirement, so it
// must not gate (and can't be gated by) collar readiness. CROSS-MODULE CONTRACT.
string KEY_CARD_APPLIED = "settings.cardapplied";

// Touch-guard flag. Cleared at the start of every boot and set "1" once startup
// finishes (announce_status). kmod_ui ignores touches while it is unset, so a
// touch mid-boot can't pile a menu render onto the plugin-registration window.
// CROSS-MODULE CONTRACT with kmod_ui.
string KEY_BOOT_READY = "boot.ready";

/* -------------------- NOTECARD STREAMING --------------------

The settings notecard parse used to live in kmod_settings, which sat at ~90% of
the Mono budget and stack-heap-collided when it ran. We do the I/O here (this
module has ample headroom) and DEPOSIT each card line into LSD verbatim — the
card key names ARE the LSD key names. kmod_settings converts the deposited
roster keys into user.* records on "settings.card.streamed" (it stays the sole
user.* writer). We never build records here — dumb deposit only. CROSS-MODULE
CONTRACT: the streamed key names + the settings.card.streamed / settings.card.restream
signals.

-------------------- */
string NOTECARD_NAME  = "settings";
string COMMENT_PREFIX = "#";
string SEPARATOR      = "=";
string USER_PREFIX    = "user.";

key CardQuery   = NULL_KEY;
integer CardLine = 0;
integer Streaming = FALSE;

/* -------------------- BOOTSTRAP CONFIG -------------------- */
integer BOOTSTRAP_TIMEOUT_SEC = 90;
integer SETTINGS_RETRY_INTERVAL_SEC = 5;
integer SETTINGS_MAX_RETRIES = 3;
integer SETTINGS_INITIAL_DELAY_SEC = 5; // Wait for linkset data + notecard load

/* -------------------- STATE -------------------- */
integer BootstrapComplete = FALSE;
integer BootstrapDeadline = 0;

// Owner tracking
key LastOwner = NULL_KEY;

// RLV detection
list RlvChannels = [];          // List of channels we're listening on
list RlvListenHandles = [];     // Corresponding listen handles
integer RlvProbing = FALSE;
integer RlvActive = FALSE;
string RlvVersion = "";
integer RlvProbeDeadline = 0;
integer RlvNextRetry = 0;
integer RlvRetryCount = 0;
integer RlvReady = FALSE;

// Settings
integer SettingsReceived = FALSE;
integer SettingsRetryCount = 0;
integer SettingsNextRetry = 0;

// Name resolution wait: kmod_settings resolves names async; we wait briefly
// after settings_received before announcing so the owner name is populated.
integer NamesReadyDeadline = 0;
integer NAMES_READY_TIMEOUT_SEC = 10;

/* -------------------- HELPERS -------------------- */


string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
}


integer now() {
    return llGetUnixTime();
}

sendIM(string msg) {
    key wearer = llGetOwner();
    if (wearer != NULL_KEY && msg != "") {
        llInstantMessage(wearer, msg);
    }
}

integer isAttached() {
    return ((integer)llGetAttached() != 0);
}

// Owner change detection (prevents unnecessary resets on teleport)
integer check_owner_changed() {
    key current_owner = llGetOwner();
    if (current_owner == NULL_KEY) return FALSE;

    if (LastOwner != NULL_KEY && current_owner != LastOwner) {
        LastOwner = current_owner;
        llResetScript();
        return TRUE;
    }

    LastOwner = current_owner;
    return FALSE;
}

/* -------------------- RLV DETECTION - Multi-Channel Approach -------------------- */

addProbeChannel(integer ch) {
    if (ch == 0) return;
    if (llListFindList(RlvChannels, [ch]) != -1) return;  // Already added
    
    integer handle = llListen(ch, "", NULL_KEY, "");  // Accept from anyone (NULL_KEY important!)
    RlvChannels += [ch];
    RlvListenHandles += [handle];
}

clearProbeChannels() {
    integer i = 0;
    while (i < llGetListLength(RlvListenHandles)) {
        integer handle = llList2Integer(RlvListenHandles, i);
        if (handle) llListenRemove(handle);
        i += 1;
    }
    RlvChannels = [];
    RlvListenHandles = [];
}

sendRlvQueries() {
    integer i = 0;
    while (i < llGetListLength(RlvChannels)) {
        integer ch = llList2Integer(RlvChannels, i);
        llOwnerSay("@versionnew=" + (string)ch);
        i += 1;
    }
}

start_rlv_probe() {
    if (RlvProbing) {
        return;
    }
    
    if (!isAttached()) {
        // Not attached, can't detect RLV
        RlvReady = TRUE;
        RlvActive = FALSE;
        RlvVersion = "";
        return;
    }
    
    RlvProbing = TRUE;
    RlvActive = FALSE;
    RlvVersion = "";
    RlvRetryCount = 0;
    RlvReady = FALSE;
    
    clearProbeChannels();
    
    // Set up multiple probe channels
    if (UseFixed4711) addProbeChannel(4711);
    if (UseRelayChan) {
        addProbeChannel(RELAY_CHAN);
        if (ProbeRelayBothSigns) {
            addProbeChannel(-RELAY_CHAN);  // Try opposite sign too
        }
    }
    
    RlvProbeDeadline = now() + RLV_PROBE_TIMEOUT_SEC;
    RlvNextRetry = now() + RLV_INITIAL_DELAY_SEC;  // Initial delay before first probe
    
    sendIM("Detecting RLV...");
}

stop_rlv_probe() {
    clearProbeChannels();
    RlvProbing = FALSE;
    RlvReady = TRUE;
}

/* -------------------- SETTINGS LOADING -------------------- */

// Mark settings as received and start the names-ready countdown.
// Actual reading happens at announcement time directly from LSD.
apply_settings_sync() {
    SettingsReceived = TRUE;
    NamesReadyDeadline = now() + NAMES_READY_TIMEOUT_SEC;
}

// Collect owner records (user.<uuid> with acl 5) as a strided
// [rank, name, honorific] list, rank-sorted (rank 0 = primary). The
// record's leading field is the acl; fields 2/3 are name/honorific.
list owner_rows() {
    list rows = [];
    list ks = llLinksetDataFindKeys("^user\\.", 0, -1);
    integer i = 0;
    integer n = llGetListLength(ks);
    while (i < n) {
        string rec = llLinksetDataRead(llList2String(ks, i));
        if ((integer)rec == 5) {
            list f = llCSV2List(rec);
            rows += [(integer)llList2String(f, 1), llList2String(f, 2), llList2String(f, 3)];
        }
        i += 1;
    }
    if (llGetListLength(rows) > 3) rows = llListSortStrided(rows, 3, 0, TRUE);
    return rows;
}

// Returns TRUE if all owner names are resolved (no NAME_LOADING placeholders)
integer names_ready() {
    list rows = owner_rows();
    integer i = 1;
    integer n = llGetListLength(rows);
    while (i < n) {
        if (llList2String(rows, i) == NAME_LOADING) return FALSE;
        i += 3;
    }
    return TRUE;
}

/* -------------------- NOTECARD STREAMING -------------------- */

// Deposit one card line into LSD as a raw key=value. Comments/blanks are
// skipped; user.* is refused (a card may never forge records directly); only
// dotted keys are accepted (roster scratch keys + plugin scalars). No parsing,
// normalization, or record-building happens here — kmod_settings does that on
// settings.card.streamed.
stream_line(string line) {
    line = llStringTrim(line, STRING_TRIM);
    if (line == "") return;
    if (llGetSubString(line, 0, 0) == COMMENT_PREFIX) return;

    integer sep = llSubStringIndex(line, SEPARATOR);
    if (sep == -1) return;

    string k = llStringTrim(llGetSubString(line, 0, sep - 1), STRING_TRIM);
    string v = llStringTrim(llGetSubString(line, sep + 1, -1), STRING_TRIM);
    if (k == "") return;
    if (llSubStringIndex(k, USER_PREFIX) == 0) return;   // never card-write records
    if (llSubStringIndex(k, ".") == -1) return;          // dotted keys only

    llLinksetDataWrite(k, v);
}

// Begin streaming the settings notecard (idempotent while in flight). The
// dataserver chain deposits each line and emits settings.card.streamed at EOF.
stream_card() {
    if (Streaming) return;
    if (llGetInventoryType(NOTECARD_NAME) != INVENTORY_NOTECARD) return;
    Streaming = TRUE;
    CardLine = 0;
    CardQuery = llGetNotecardLine(NOTECARD_NAME, CardLine);
}

// Tell kmod_settings the raw deposit is complete; it converts + stamps the
// sentinel + rebroadcasts settings.sync.
emit_card_streamed() {
    Streaming = FALSE;
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.card.streamed"
    ]), NULL_KEY);
}

/* -------------------- BOOTSTRAP INITIATION -------------------- */

start_bootstrap() {
    BootstrapComplete = FALSE;
    SettingsReceived = FALSE;
    SettingsRetryCount = 0;
    NamesReadyDeadline = 0;

    // Arm the touch-guard: ignore collar touches until startup finishes.
    llLinksetDataDelete(KEY_BOOT_READY);

    BootstrapDeadline = now() + BOOTSTRAP_TIMEOUT_SEC;

    sendIM("D/s Collar starting up. Please wait...");

    start_rlv_probe();

    // Stream the settings card as an OVERRIDE on a fresh boot only: a card is
    // present AND the override hasn't been applied yet (settings.cardapplied
    // unset — cleared by an owner-change wipe / Reload / card-edit). A normal
    // reboot (marker set) keeps the UI/LSD values. This is gated on the card
    // marker, NOT the readiness sentinel — readiness is kmod_settings' job and
    // is stamped immediately, independent of whether a card ever streams.
    if (llGetInventoryType(NOTECARD_NAME) == INVENTORY_NOTECARD
        && llLinksetDataRead(KEY_CARD_APPLIED) == "") {
        stream_card();
    }

    // OPTIMIZATION: Delay initial settings check to allow notecard loading
    SettingsNextRetry = now() + SETTINGS_INITIAL_DELAY_SEC;

    llSetTimerEvent(1.0);
}

/* -------------------- BOOTSTRAP COMPLETION -------------------- */

check_bootstrap_complete() {
    if (BootstrapComplete) return;

    if (RlvReady && SettingsReceived && names_ready()) {
        BootstrapComplete = TRUE;
        announce_status();
    }
}

announce_status() {
    // RLV Status. Publish rlv.active to LSD (CROSS-MODULE: kmod_ui reads it to
    // hide RLV-required plugins — mask bit 0x40 — when RLV is off). Written
    // each boot (and re-detected on attach), so it tracks the real state.
    if (RlvActive) {
        sendIM("RLV: " + RlvVersion);
        llLinksetDataWrite("rlv.active", "1");
    }
    else {
        sendIM("RLV: Not detected");
        llLinksetDataWrite("rlv.active", "0");
    }

    if (!SettingsReceived) {
        sendIM("WARNING: Settings timed out. Using defaults.");
    }

    // Owner announcement from the user-record roster. The mode line shows
    // the access.multiowner POLICY flag (notecard-only), not the count.
    list rows = owner_rows();
    integer owner_count = llGetListLength(rows) / 3;

    if ((integer)llLinksetDataRead("access.multiowner")) {
        sendIM("Mode: Multi-Owner (" + (string)owner_count + ")");
    }
    else {
        sendIM("Mode: Single-Owner");
    }

    if (owner_count > 0) {
        list owner_parts = [];
        integer i = 0;
        while (i < owner_count) {
            string nm = llList2String(rows, i * 3 + 1);
            string hn = llList2String(rows, i * 3 + 2);
            if (hn != "") {
                owner_parts += [hn + " " + nm];
            }
            else {
                owner_parts += [nm];
            }
            i += 1;
        }
        sendIM("Owned by " + llDumpList2String(owner_parts, ", "));
    }
    else {
        sendIM("Uncommitted");
    }

    sendIM("Collar startup complete.");

    // Lift the touch-guard — registrations have long since settled by the time
    // RLV detection + name resolution complete, so the menu is safe to open.
    llLinksetDataWrite(KEY_BOOT_READY, "1");
}

/* -------------------- EVENTS -------------------- */
default
{
    state_entry() {

        UseFixed4711 = TRUE;
        UseRelayChan = TRUE;
        ProbeRelayBothSigns = TRUE;

        LastOwner = llGetOwner();
        
        state starting;
    }
}

state starting
{
    state_entry() {

        start_bootstrap();
    }

    on_rez(integer start_param) {
        // Only reset if owner changed - prevents bootstrap on every teleport
        check_owner_changed();
    }

    attach(key id) {
        if (id == NULL_KEY) return;
        // Bootstrap on attach (covers logon and initial attach)
        llResetScript();
    }
    
    timer() {
        integer current_time = llGetUnixTime();
        if (current_time == 0) return; // Overflow protection

        // GLOBAL TIMEOUT CHECK
        if (!BootstrapComplete && BootstrapDeadline > 0 && current_time >= BootstrapDeadline) {
            sendIM("WARNING: Bootstrap timed out. Forcing completion.");

            if (!RlvReady) stop_rlv_probe();
            if (!SettingsReceived) SettingsReceived = TRUE;

            BootstrapComplete = TRUE;
            announce_status();
            state running;
        }

        // Handle Settings Retries (read directly from LSD)
        if (!SettingsReceived && current_time >= SettingsNextRetry) {
            if (SettingsRetryCount < SETTINGS_MAX_RETRIES) {
                apply_settings_sync();
                SettingsRetryCount++;
                SettingsNextRetry = current_time + SETTINGS_RETRY_INTERVAL_SEC;
            }
        }

        // Self-heal the card-override handshake. settings.card.streamed is a
        // one-shot message: on a fresh boot (e.g. owner-change wipe) kmod_settings
        // can still be resetting when the first one fires and miss it, leaving the
        // override un-applied. Re-stream until kmod_settings processes one and
        // sets settings.cardapplied. This is now NON-FATAL — readiness no longer
        // depends on it, so the worst case is the card override lands a beat late;
        // the marker check stops the loop and the bootstrap timeout bounds it.
        if (!Streaming
            && llLinksetDataRead(KEY_CARD_APPLIED) == ""
            && llGetInventoryType(NOTECARD_NAME) == INVENTORY_NOTECARD) {
            stream_card();
        }

        // Handle RLV probe retries
        if (RlvProbing && !RlvReady) {
            if (RlvNextRetry > 0 && current_time >= RlvNextRetry) {
                if (RlvRetryCount < RLV_MAX_RETRIES) {
                    sendRlvQueries();
                    RlvRetryCount += 1;
                    integer next_retry_time = current_time + RLV_RETRY_INTERVAL_SEC;
                    if (next_retry_time < current_time) next_retry_time = current_time;
                    RlvNextRetry = next_retry_time;
                }
            }

            if (RlvProbeDeadline > 0 && current_time >= RlvProbeDeadline) {
                stop_rlv_probe();
                check_bootstrap_complete();
            }
        }

        // Names ready check (kmod_settings resolves them async)
        if (SettingsReceived && RlvReady && !BootstrapComplete) {
            if (names_ready() ||
                (NamesReadyDeadline > 0 && current_time >= NamesReadyDeadline)) {
                check_bootstrap_complete();
            }
        }

        // Stop timer if bootstrap complete
        if (BootstrapComplete && !RlvProbing) {
            state running;
        }
    }

    listen(integer channel, string name, key id, string message) {
        if (llListFindList(RlvChannels, [channel]) == -1) return;

        key wearer = llGetOwner();
        if (id != wearer && id != NULL_KEY) return;

        RlvActive = TRUE;
        RlvVersion = llStringTrim(message, STRING_TRIM);

        stop_rlv_probe();
        check_bootstrap_complete();
    }

    dataserver(key query_id, string data) {
        if (query_id != CardQuery) return;
        if (data != EOF) {
            stream_line(data);
            CardLine += 1;
            CardQuery = llGetNotecardLine(NOTECARD_NAME, CardLine);
        }
        else {
            emit_card_streamed();
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        /* -------------------- SETTINGS BUS -------------------- */
        if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync") {
                apply_settings_sync();
            }
            else if (msg_type == "settings.card.restream") {
                // kmod_settings (Reload / Reset Config / card edit) cleared the
                // sentinel and wants the card re-deposited.
                stream_card();
            }
        }

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        else if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "settings.notecard.loaded") {
                // Settings notecard was loaded/reloaded - re-run bootstrap
                start_bootstrap();
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
        }

        /* -------------------- REMOTE BUS -------------------- */
        // update_shim broadcasts remote.update.complete just before
        // self-deletion. Restart so the startup orchestration (RLV
        // probe, register.refresh, status announcement) re-runs with
        // the new script set live in the collar.
        else if (num == REMOTE_BUS) {
            if (msg_type == "remote.update.complete") {
                llResetScript();
            }
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            check_owner_changed();
        }
    }
}

state running
{
    state_entry() {

        llSetTimerEvent(0.0);
    }

    on_rez(integer start_param) {
        check_owner_changed();
    }

    attach(key id) {
        if (id == NULL_KEY) return;
        llResetScript();
    }

    dataserver(key query_id, string data) {
        // A post-boot Reload Settings / Reset Config / card edit can request a
        // re-stream while we're running; deposit the lines here too.
        if (query_id != CardQuery) return;
        if (data != EOF) {
            stream_line(data);
            CardLine += 1;
            CardQuery = llGetNotecardLine(NOTECARD_NAME, CardLine);
        }
        else {
            emit_card_streamed();
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        if (num == SETTINGS_BUS) {
            if (msg_type == "settings.card.restream") {
                // Re-deposit the card; the following settings.notecard.loaded
                // (from kmod_settings) then restarts us to re-announce.
                stream_card();
            }
        }
        else if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "settings.notecard.loaded") {
                llResetScript();
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
        }
        // update_shim broadcasts this just before self-deletion. Restart
        // so startup orchestration re-runs with the new script set live.
        else if (num == REMOTE_BUS) {
            if (msg_type == "remote.update.complete") {
                llResetScript();
            }
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            check_owner_changed();
        }
    }
}

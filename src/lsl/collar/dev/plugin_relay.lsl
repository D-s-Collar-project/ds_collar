/*--------------------
PLUGIN: plugin_relay.lsl
VERSION: 1.1
REVISION: 21
PURPOSE: ORG-compliant RLV relay for the D/s Collar plugin system
ARCHITECTURE: Satomi Ahn's multirelay implementation, with D/s Collar patches.
              Single-script consolidation of Satomi's gatekeeper +
              bookkeeper + pigeonkeeper, adapted for the collar's
              plugin model, ACL gates, LSD-backed settings, and SOS
              hooks. Email, HTTP, !x-handover, !x-channel agent listen,
              !x-delay, !x-email, !who user-tier auth, and persistent
              trust lists are intentionally not ported.
CHANGES:
- v1.1 rev 21: Full rewrite as port of Satomi Ahn's multirelay.
  Replaces the prior custom multi-source implementation, which had
  two real bugs:
  (1) Channel commands (@version, @get*, @findfolder) fell through to
      the auth path and triggered a fresh ASK dialog on every
      furniture probe — wearer was prompted continuously even after
      consenting.
  (2) accept_ask added the source to Sources[] only, not to a session
      trust list. The moment a source cleared its restrictions
      (entering and re-entering the relay's view) the wearer was
      re-prompted.
  Rather than patch the prior implementation, this is a port of
  Satomi's multirelay, which solves both correctly:
  - ischannelcommand auto-allows queries that respond on a positive
    chat channel.
  - The 6-button ASK dialog's Yes adds the source to TempObjWhite
    so re-entering after self-clear is silent.
  Other ported MR semantics:
  - Multi-source: Sources / SourceNames / SourceChans /
    SourceRestrictions parallel lists; Baked refcount tracks the set
    of behaviours actually applied to the viewer; per-source @clear
    and !release release that source's contribution only.
  - Distance-based liveness: 10s timer calls llGetObjectDetails on
    each source key and drops anything beyond 100m. No llSensor.
  - Distance-tiered outbound chat: llWhisper/llSay/llShout/
    llRegionSay chosen by measured distance.
  - Multi-command per message: command field can be "|"-separated
    sub-commands; each is processed in order with an END ack.
  - Source ident echoed back in acks (MR-spec; prior code hardcoded "RLV").
  - Queue with re-entrant cleanqueue: when wearer answers the auth
    dialog, the queue is re-walked and any items now passing auth
    are processed without a new prompt; items now failing auth are
    ko'd. Cap at MAX_QUEUE = 8 (MR's MAXLOAD).
  - 6-button auth dialog: Yes / No / Trust Object / Ban Object /
    Trust Owner / Ban Owner. All four trust/ban variants populate
    session-only TempObj{White,Black} / TempAv{White,Black}.
  - 120s auth dialog timeout (MR's value; prior code used 30s).
  D/s Collar patches on top of MR:
  - Single-script consolidation; no inter-script link_message lanes
    for the relay's own state.
  - Hardcore mode (collar concept, not MR's "evil safeword"):
    suppresses the Safeword button on the main menu when active.
    Orthogonal to OFF/ASK/ON.
  - ACL-gated menu visibility via acl.policycontext:<ctx> LSD policy.
  - Plugin registration with the kernel for ping/pong health
    tracking.
  - Chat aliases ("relay [on|off|ask]" and "safeword").
  - SOS hook: sos.relay.clear on UI_BUS triggers a full clear,
    bypassing Hardcore (matches the emergency-exit intent).
  - Dormancy guard: if object description is COLLAR_UPDATER, the
    script parks itself.
  - Ground-rez handler: turns relay OFF and clears state on detach.
  - settings.set is the canonical write path (kmod_settings owns
    the LSD); we never pre-write the keys.
  Intentionally not ported:
  - !who user-tier auth (no compelling case without persistent trust)
  - "Restricted" mode (deny-by-default doesn't fit)
  - Manual lock (plugin_lock owns @detach=n)
  - Playful (one-shot bypass; complexity not justified)
  - Persistent trust lists (drift / silent-grant risk)
  - Sandkeeper (!x-delay scheduled commands)
  - Pigeonkeeper email & HTTP transports
  - Outfitkeeper, 3rdviewkeeper, statuskeeper, versionkeeper
    (collar handles these via dedicated plugins)
- v1.1 rev 20: Correct product name in IMPL_VERSION reply.
- v1.1 rev 19: Add ORG capability-probe handlers (!version,
  !implversion, !x-orgversions).
- v1.1 rev 18: Drop "[RELAY]" source prefix from user-facing notices.
- v1.1 rev 17: ASK early-ack-deferred-apply (later replaced in rev 21).
- v1.1 rev 16: ASK queue + cap (later replaced in rev 21).
- v1.1 rev 15: persist_mode / persist_hardcore stop pre-writing LSD.
- v1.1 rev 14: Strict ORG parser; wildcard reserved for capability probes.
- v1.1 rev 13: write_plugin_reg guards idempotent writes.
- v1.1 rev 12: apply_settings_sync mirrors mode-change side effects.
- v1.1 rev 11: Dormancy guard for COLLAR_UPDATER object description.
- v1.1 rev 10: Self-declare menu presence via plugin.reg.<ctx> LSD key.
- v1.1 rev 9: ASK provisional-accept (superseded by rev 17/21).
- v1.1 rev 8: User notices via llRegionSayTo, drop "[RELAY]" / "[SOS]".
- v1.1 rev 7: Chat command support — "relay [on|off|ask]", "safeword".
- v1.1 rev 6: sos.relay.clear handler on UI_BUS.
- v1.1 rev 5: Wire-type rename (kernel.* / ui.* / settings.* / sos.*).
- v1.1 rev 4: handle_ground_rez takes a reason string.
- v1.1 rev 3: Guard ui.menu.start against raw kmod_chat broadcasts.
- v1.1 rev 2: Namespace internal message type strings.
- v1.1 rev 1: Migrate settings reads from JSON broadcast to direct LSD.
- v1.1 rev 0: Self-declared button visibility policy via LSD.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.relay";
string PLUGIN_LABEL = "RLV Relay";

/* -------------------- ORG CAPABILITY-PROBE REPLIES -------------------- */
string PROTOCOL_VERSION = "1100";
string IMPL_VERSION     = "ORG=0003/D/s Collar Relay v1.1";
string ORG_VERSIONS     = "ORG=0003";

/* ACL levels for reference:
   -1 Blacklisted
    0 No Access
    1 Public
    2 Owned (wearer when owner set)
    3 Trustee
    4 Unowned (wearer when no owner)
    5 Primary Owner
*/

/* -------------------- RELAY CONSTANTS -------------------- */
integer RELAY_CHANNEL = -1812221819;
integer RLV_RESP_CHANNEL = 4711;

integer MAX_SOURCES = 8;
integer MAX_QUEUE = 8;            // anti-flood cap on auth queue (MR's MAXLOAD)

integer MODE_OFF = 0;
integer MODE_ON  = 1;
integer MODE_ASK = 2;

integer ASK_TIMEOUT_SEC = 120;    // MR-faithful auth dialog timeout
float   GC_INTERVAL = 10.0;       // distance-based liveness sweep cadence
float   DISTANCE_MAX = 100.0;     // shout range; sources beyond are released

string  END_MARKER = "$$";        // batch terminator (MR convention)

key WILDCARD_UUID = "ffffffff-ffff-ffff-ffff-ffffffffffff";

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_RELAY_MODE = "relay.mode";
string KEY_RELAY_HARDCORE = "relay.hardcoremode";

/* -------------------- STATE -------------------- */

// Mode + flags
integer Mode = MODE_ASK;
integer Hardcore = FALSE;
integer IsAttached = FALSE;
integer RelayListenHandle = 0;
key WearerKey = NULL_KEY;

// Source tracking — parallel lists indexed by source position.
// Sources[i]            = captor object UUID
// SourceNames[i]        = display name at time of grab
// SourceChans[i]        = session reply channel for that source
// SourceRestrictions[i] = "/"-joined behaviour list for that source
list Sources = [];
list SourceNames = [];
list SourceChans = [];
list SourceRestrictions = [];

// Refcount set: behaviours currently applied to the viewer. A behaviour
// stays in Baked iff at least one source (or LocalRestrictions) wants it.
list Baked = [];

// Relay-internal restrictions — phantom-source slot for relay-owned
// restrictions. Reserved; no producers in this version.
list LocalRestrictions = [];

// Session-only trust lists. Populated by the auth dialog's six buttons;
// cleared on safeword, mode-off, detach, and reset. Not persisted.
list TempObjWhite = [];   // object UUIDs the wearer trusts this session
list TempObjBlack = [];   // object UUIDs the wearer denies this session
list TempAvWhite = [];    // owner UUIDs the wearer trusts this session
list TempAvBlack = [];    // owner UUIDs the wearer denies this session

// Auth queue. Stride 3:
//   Queue[3i]   = ident string from source
//   Queue[3i+1] = object UUID as string
//   Queue[3i+2] = "|"-separated remaining commands (END appended)
list Queue = [];
integer QSTRIDE = 3;

// Auth dialog state
integer AskListenHandle = 0;
integer AskDialogChan = 0;
integer AskExpireAt = 0;          // unix ts; 0 = no pending dialog

// Menu session state
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";
integer ObjectListPage = 0;

/* -------------------- HELPERS -------------------- */

integer lsd_int(string lsd_key, integer fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (integer)v;
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

string truncate_name(string name, integer max_len) {
    if (llStringLength(name) <= max_len) return name;
    return llGetSubString(name, 0, max_len - 4) + "...";
}

list get_policy_buttons(string ctx, integer acl) {
    string policy = llLinksetDataRead("acl.policycontext:" + ctx);
    if (policy == "") return [];
    string csv = llJsonGetValue(policy, [(string)acl]);
    if (csv == JSON_INVALID) return [];
    return llCSV2List(csv);
}

integer btn_allowed(string label) {
    return (llListFindList(gPolicyButtons, [label]) != -1);
}

/* -------------------- LIFECYCLE MANAGEMENT -------------------- */

write_plugin_reg(string label) {
    string k = "plugin.reg." + PLUGIN_CONTEXT;
    string v = llList2Json(JSON_OBJECT, [
        "label",  label,
        "script", llGetScriptName()
    ]);
    if (llLinksetDataRead(k) == v) return;
    llLinksetDataWrite(k, v);
}

register_self() {
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "2", "Mode,Bound by...,Safeword",
        "3", "Mode,Bound by...,Unbind,HC OFF,HC ON",
        "4", "Mode,Bound by...,Safeword",
        "5", "Mode,Bound by...,Unbind,HC OFF,HC ON"
    ]));

    write_plugin_reg(PLUGIN_LABEL);

    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);

    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "relay",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "safeword",
        "context", PLUGIN_CONTEXT + ".safeword"
    ]), NULL_KEY);
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* -------------------- RELAY LISTEN MANAGEMENT -------------------- */

start_relay_listen() {
    if (RelayListenHandle) return;
    RelayListenHandle = llListen(RELAY_CHANNEL, "", NULL_KEY, "");
}

stop_relay_listen() {
    if (RelayListenHandle) {
        llListenRemove(RelayListenHandle);
        RelayListenHandle = 0;
    }
}

update_relay_listen_state() {
    if (Mode != MODE_OFF && IsAttached) start_relay_listen();
    else stop_relay_listen();
}

/* -------------------- TIMER MANAGEMENT -------------------- */

// Single timer multiplexes auth-dialog timeout and source distance GC.
// Runs at GC_INTERVAL whenever sources or a pending auth dialog exist.
rearm_timer() {
    if (llGetListLength(Sources) > 0 || AskExpireAt != 0) {
        llSetTimerEvent(GC_INTERVAL);
    } else {
        llSetTimerEvent(0.0);
    }
}

/* -------------------- OUTBOUND CHAT (DISTANCE-TIERED) -------------------- */

// MR-faithful: pick whisper / say / shout / regionsay by the source's
// actual distance. Conserves region chat budget when sources are close.
say_to_source(key src, integer chan, string text) {
    list det = llGetObjectDetails(src, [OBJECT_POS]);
    vector pos = llList2Vector(det, 0);
    if (pos == ZERO_VECTOR) {
        llRegionSayTo(src, chan, text);
        return;
    }
    float d = llVecDist(pos, llGetRootPosition());
    if (d < 10.0)       llWhisper(chan, text);
    else if (d < 20.0)  llSay(chan, text);
    else if (d < 100.0) llShout(chan, text);
    else                llRegionSay(chan, text);
}

// Wire-format an ack to a source: <ident>,<wearer>,<command>,<ack>
ack_source(string ident, key src, integer chan, string command, string ack) {
    say_to_source(src, chan,
        ident + "," + (string)WearerKey + "," + command + "," + ack);
}

/* -------------------- SOURCE MANAGEMENT -------------------- */

integer source_idx(key obj) {
    return llListFindList(Sources, [obj]);
}

integer add_source(key obj, string obj_name, integer chan) {
    integer idx = source_idx(obj);
    if (idx != -1) {
        SourceNames = llListReplaceList(SourceNames, [obj_name], idx, idx);
        SourceChans = llListReplaceList(SourceChans, [chan], idx, idx);
        return TRUE;
    }
    if (llGetListLength(Sources) >= MAX_SOURCES) return FALSE;
    Sources += [obj];
    SourceNames += [obj_name];
    SourceChans += [chan];
    SourceRestrictions += [""];
    rearm_timer();
    return TRUE;
}

/* -------------------- BAKED REFCOUNT (apply / release) -------------------- */

// Apply a behaviour to the viewer iff it is not already in Baked. Refcount
// discipline: double-add from two sources sends "@behav=n" only once.
apply_add(string behav) {
    if (llListFindList(Baked, [behav]) != -1) return;
    Baked += [behav];
    llOwnerSay("@" + behav + "=n");
}

// Release a behaviour from the viewer iff no source nor LocalRestrictions
// still wants it. Walks all SourceRestrictions to check.
apply_rem(string behav) {
    integer baked_idx = llListFindList(Baked, [behav]);
    if (baked_idx == -1) return;
    if (llListFindList(LocalRestrictions, [behav]) != -1) return;
    integer n = llGetListLength(SourceRestrictions);
    integer i = 0;
    while (i < n) {
        list per_src = llParseString2List(llList2String(SourceRestrictions, i), ["/"], []);
        if (llListFindList(per_src, [behav]) != -1) return;
        i += 1;
    }
    Baked = llDeleteSubList(Baked, baked_idx, baked_idx);
    llOwnerSay("@" + behav + "=y");
}

// Add a per-source restriction. Caller must add_source first if needed.
add_restriction(key src, string behav) {
    integer idx = source_idx(src);
    if (idx == -1) return;
    list per_src = llParseString2List(llList2String(SourceRestrictions, idx), ["/"], []);
    if (llListFindList(per_src, [behav]) == -1) {
        per_src += [behav];
        SourceRestrictions = llListReplaceList(SourceRestrictions,
            [llDumpList2String(per_src, "/")], idx, idx);
    }
    apply_add(behav);
}

// Remove a per-source restriction. apply_rem handles refcount; if any
// other source still wants it, the viewer keeps it.
rem_restriction(key src, string behav) {
    integer idx = source_idx(src);
    if (idx == -1) return;
    list per_src = llParseString2List(llList2String(SourceRestrictions, idx), ["/"], []);
    integer pos = llListFindList(per_src, [behav]);
    if (pos == -1) return;
    per_src = llDeleteSubList(per_src, pos, pos);
    SourceRestrictions = llListReplaceList(SourceRestrictions,
        [llDumpList2String(per_src, "/")], idx, idx);
    apply_rem(behav);
}

// Release ALL restrictions held by one source, then drop the source.
release_source(key src) {
    integer idx = source_idx(src);
    if (idx == -1) return;
    list per_src = llParseString2List(llList2String(SourceRestrictions, idx), ["/"], []);
    // Drop source first so apply_rem's walk sees only the survivors.
    Sources = llDeleteSubList(Sources, idx, idx);
    SourceNames = llDeleteSubList(SourceNames, idx, idx);
    SourceChans = llDeleteSubList(SourceChans, idx, idx);
    SourceRestrictions = llDeleteSubList(SourceRestrictions, idx, idx);
    integer n = llGetListLength(per_src);
    integer i = 0;
    while (i < n) {
        apply_rem(llList2String(per_src, i));
        i += 1;
    }
    rearm_timer();
}

// Total wipe — Safeword and detach use this. Atomic @clear to viewer
// rather than walking Baked (wearer wants instant release).
safeword_clear_all() {
    clear_pending_ask();
    drop_queue();
    llOwnerSay("@clear");
    Sources = [];
    SourceNames = [];
    SourceChans = [];
    SourceRestrictions = [];
    Baked = [];
    LocalRestrictions = [];
    TempObjWhite = [];
    TempObjBlack = [];
    TempAvWhite = [];
    TempAvBlack = [];
    rearm_timer();
}

/* -------------------- AUTH DECISION -------------------- */

// Returns -1 deny, 0 ask, 1 allow. Mode-OFF can't reach here — listener
// is removed in update_relay_listen_state.
integer auth(key obj_key) {
    if (source_idx(obj_key) != -1) return 1;
    key owner = llGetOwnerKey(obj_key);
    if (llListFindList(TempObjBlack, [obj_key]) != -1) return -1;
    if (llListFindList(TempAvBlack, [owner]) != -1) return -1;
    if (llListFindList(TempObjWhite, [obj_key]) != -1) return 1;
    if (llListFindList(TempAvWhite, [owner]) != -1) return 1;
    if (Mode == MODE_ON) return 1;
    return 0;
}

/* -------------------- CHANNEL-COMMAND DETECTOR -------------------- */

// MR's ischannelcommand: queries that respond on a positive chat channel.
// These are inventory/state probes with no restriction effect; auto-allow.
// This is the fix for v1.x bug #1 (re-asking on every furniture probe).
integer is_channel_command(string cmd) {
    if (llSubStringIndex(cmd, "@version") == 0) return TRUE;
    if (llSubStringIndex(cmd, "@get") == 0) return TRUE;
    if (llSubStringIndex(cmd, "@findfolder") == 0) return TRUE;
    return FALSE;
}

/* -------------------- COMMAND HANDLER (MR-style) -------------------- */

// Process a "|"-separated command chain for one source. The auth flag
// is the wearer's-already-said-yes signal: when FALSE, hitting an
// auth-required command returns the unprocessed remainder for the
// dequeue path to re-queue under an auth dialog.
//
// Returns "" when the entire chain was processed; otherwise the
// remaining unprocessed sub-string for re-queueing.
string handle_command(string ident, key src, integer chan, string com, integer auth_ok) {
    list commands = llParseString2List(com, ["|"], []);
    integer n = llGetListLength(commands);
    integer i = 0;
    while (i < n) {
        string command = llList2String(commands, i);

        if (command == END_MARKER) {
            // End of batch — echo END to source (MR convention).
            ack_source(ident, src, chan, END_MARKER, END_MARKER);
            return "";
        }

        // Capability probes — no auth, auto-reply with version data.
        if (command == "!release" || command == "!release_fail") {
            release_source(src);
            ack_source(ident, src, chan, command, "ok");
            i += 1;
            jump after_send;
        }
        if (command == "!version") {
            ack_source(ident, src, chan, command, PROTOCOL_VERSION);
            i += 1;
            jump after_send;
        }
        if (command == "!implversion") {
            ack_source(ident, src, chan, command, IMPL_VERSION);
            i += 1;
            jump after_send;
        }
        if (command == "!x-orgversions") {
            ack_source(ident, src, chan, command, ORG_VERSIONS);
            i += 1;
            jump after_send;
        }
        // Unknown !-meta: ko and continue
        if (llGetSubString(command, 0, 0) == "!") {
            ack_source(ident, src, chan, command, "ko");
            i += 1;
            jump after_send;
        }
        // Anything not @-prefixed at this point is ill-formed; bail.
        if (llGetSubString(command, 0, 0) != "@") {
            // Return remainder; dequeue treats this as "needs decision",
            // but matching MR we just stop processing the chain.
            return llDumpList2String(llList2List(commands, i, -1), "|");
        }

        // Channel commands — auto-allow, fix for v1.x bug #1.
        if (is_channel_command(command)) {
            integer eq = llSubStringIndex(command, "=");
            integer chan_val = 0;
            if (eq != -1) chan_val = (integer)llGetSubString(command, eq + 1, -1);
            if (chan_val > 0) {
                llOwnerSay(command);
                ack_source(ident, src, chan, command, "ok");
            } else {
                ack_source(ident, src, chan, command, "ko");
            }
            i += 1;
            jump after_send;
        }

        // @clear is per-source release; doesn't disturb other sources.
        if (command == "@clear") {
            release_source(src);
            ack_source(ident, src, chan, command, "ok");
            i += 1;
            jump after_send;
        }

        // From here, behav=val parsing required.
        list subargs = llParseString2List(command, ["="], []);
        if (llGetListLength(subargs) != 2) {
            // Ill-formed; return remainder.
            return llDumpList2String(llList2List(commands, i, -1), "|");
        }
        string behav = llGetSubString(llList2String(subargs, 0), 1, -1);
        string val = llList2String(subargs, 1);

        // =y / =rem : removal — auto-allowed (any source can release its own).
        if (val == "y" || val == "rem") {
            rem_restriction(src, behav);
            ack_source(ident, src, chan, command, "ok");
            i += 1;
            jump after_send;
        }

        // From here on the command requires auth.
        if (!auth_ok) {
            return llDumpList2String(llList2List(commands, i, -1), "|");
        }

        // =force : one-shot to viewer; doesn't track as a restriction.
        if (val == "force") {
            llOwnerSay(command);
            ack_source(ident, src, chan, command, "ok");
            i += 1;
            jump after_send;
        }
        // =n / =add : restricting — store + apply via refcount.
        if (val == "n" || val == "add") {
            add_source(src, llKey2Name(src), chan);
            add_restriction(src, behav);
            ack_source(ident, src, chan, command, "ok");
            i += 1;
            jump after_send;
        }
        // behav == "clear" with a value pattern: not supported here.
        // Fall through to ko for unrecognised value forms.
        ack_source(ident, src, chan, command, "ko");
        i += 1;
        @after_send;
    }
    return "";
}

/* -------------------- QUEUE MANAGEMENT -------------------- */

integer queue_length() {
    return llGetListLength(Queue) / QSTRIDE;
}

string q_ident(integer i)   { return llList2String(Queue, QSTRIDE * i); }
key    q_obj(integer i)     { return (key)llList2String(Queue, QSTRIDE * i + 1); }
string q_command(integer i) { return llList2String(Queue, QSTRIDE * i + 2); }

drop_queue_item(integer i) {
    Queue = llDeleteSubList(Queue, QSTRIDE * i, QSTRIDE * i + QSTRIDE - 1);
}

drop_queue() {
    Queue = [];
}

// Entry point from the wire. Decides immediate-handle, queue-and-prompt,
// or reject based on auth.
enqueue(string ident, key src, integer chan, string command_chain) {
    integer decision = auth(src);
    if (decision == 1) {
        handle_command(ident, src, chan, command_chain, TRUE);
        return;
    }
    if (decision == -1 || queue_length() >= MAX_QUEUE) {
        // MR sends ko + END marker when rejecting.
        ack_source(ident, src, chan, command_chain, "ko");
        ack_source(ident, src, chan, END_MARKER, "");
        return;
    }
    // decision == 0 (ASK) and queue has room.
    Queue += [ident, (string)src, command_chain];
    if (AskListenHandle == 0) dequeue();
}

// Pop the next pending item, run handle_command(auth=FALSE), and either
// continue (if entire chain auto-handled — channel commands etc.) or
// open the auth dialog with the remainder re-queued at the front.
dequeue() {
    string remainder = "";
    string cur_ident;
    key cur_src;
    integer cur_chan = RLV_RESP_CHANNEL;
    while (remainder == "") {
        if (queue_length() == 0) return;
        cur_ident = q_ident(0);
        cur_src   = q_obj(0);
        // Look up source's reply channel if known, else default.
        integer sidx = source_idx(cur_src);
        if (sidx != -1) cur_chan = llList2Integer(SourceChans, sidx);
        else cur_chan = RLV_RESP_CHANNEL;
        remainder = handle_command(cur_ident, cur_src, cur_chan, q_command(0), FALSE);
        drop_queue_item(0);
    }
    // Re-queue the remainder at the front and open the dialog.
    Queue = [cur_ident, (string)cur_src, remainder] + Queue;
    show_ask_dialog();
}

// Re-walk queue after wearer answers the auth dialog. Items now
// matching auth=1 are processed; items now auth=-1 are ko'd. Items
// still auth=0 are left in place.
clean_queue() {
    list on_hold = [];
    integer i = 0;
    while (i < queue_length()) {
        string ident   = q_ident(i);
        key    obj     = q_obj(i);
        string command = q_command(i);
        if (llListFindList(on_hold, [obj]) != -1) {
            i += 1;
            jump cq_continue;
        }
        integer decision = auth(obj);
        integer chan = RLV_RESP_CHANNEL;
        integer sidx = source_idx(obj);
        if (sidx != -1) chan = llList2Integer(SourceChans, sidx);
        if (decision == 1) {
            drop_queue_item(i);
            handle_command(ident, obj, chan, command, TRUE);
        } else if (decision == -1) {
            drop_queue_item(i);
            ack_source(ident, obj, chan, command, "ko");
            ack_source(ident, obj, chan, END_MARKER, "");
        } else {
            i += 1;
            on_hold += [obj];
        }
        @cq_continue;
    }
}

/* -------------------- ASK DIALOG -------------------- */

show_ask_dialog() {
    AskDialogChan = -1000000 - (integer)llFrand(1000000000.0);
    if (AskListenHandle) llListenRemove(AskListenHandle);
    AskListenHandle = llListen(AskDialogChan, "", WearerKey, "");

    key src = q_obj(0);
    string obj_name = llKey2Name(src);
    string owner_name = llKey2Name(llGetOwnerKey(src));
    string body = obj_name;
    if (owner_name != "") body += ", owned by " + owner_name + ",";
    body += " wants to apply RLV restrictions.\n\nAllow this?";

    // 6 functional buttons + 3 spacers for grid alignment.
    list buttons = ["No", " ", "Yes",
                    "Ban Object", " ", "Trust Object",
                    "Ban Owner",  " ", "Trust Owner"];

    AskExpireAt = llGetUnixTime() + ASK_TIMEOUT_SEC;
    llDialog(WearerKey, body, buttons, AskDialogChan);
    rearm_timer();
}

// Wearer accepted: trust source for the session (fix for v1.x bug #2),
// then re-walk queue. If a Trust-Object/Trust-Owner button was used,
// the listen handler populates the appropriate temp list before calling
// accept_ask, so cleanqueue's auth() will resolve them too.
accept_ask() {
    key cur_src = q_obj(0);
    // Plain Yes adds source to TempObjWhite — without this, source
    // re-prompts the moment it self-clears and re-enters our view.
    if (llListFindList(TempObjWhite, [cur_src]) == -1) {
        TempObjWhite += [cur_src];
    }
    clean_queue();
    clear_pending_ask();
    if (queue_length() > 0) dequeue();
}

// Wearer declined or dialog timed out: ko the front item's commands and
// re-walk queue (the temp blacklist may now resolve other queued items).
decline_ask() {
    integer chan = RLV_RESP_CHANNEL;
    if (queue_length() > 0) {
        string ident = q_ident(0);
        key obj = q_obj(0);
        string command = q_command(0);
        integer sidx = source_idx(obj);
        if (sidx != -1) chan = llList2Integer(SourceChans, sidx);
        ack_source(ident, obj, chan, command, "ko");
        ack_source(ident, obj, chan, END_MARKER, "");
        drop_queue_item(0);
    }
    clean_queue();
    clear_pending_ask();
    if (queue_length() > 0) dequeue();
}

clear_pending_ask() {
    if (AskListenHandle) {
        llListenRemove(AskListenHandle);
        AskListenHandle = 0;
    }
    AskDialogChan = 0;
    AskExpireAt = 0;
    rearm_timer();
}

/* -------------------- DISTANCE-BASED LIVENESS GC -------------------- */

gc_distant_sources() {
    integer i = llGetListLength(Sources) - 1;
    vector me = llGetRootPosition();
    while (i >= 0) {
        key src = llList2Key(Sources, i);
        list det = llGetObjectDetails(src, [OBJECT_POS]);
        vector pos = llList2Vector(det, 0);
        integer drop = FALSE;
        if (pos == ZERO_VECTOR) drop = TRUE;
        else if (llVecDist(pos, me) > DISTANCE_MAX) drop = TRUE;
        if (drop) release_source(src);
        i -= 1;
    }
}

/* -------------------- SETTINGS -------------------- */

apply_settings_sync() {
    integer prev_mode = Mode;

    Mode = lsd_int(KEY_RELAY_MODE, Mode);
    Hardcore = lsd_int(KEY_RELAY_HARDCORE, Hardcore);

    if (Mode != prev_mode) {
        clear_pending_ask();
        drop_queue();
        if (Mode == MODE_OFF) {
            TempObjWhite = [];
            TempObjBlack = [];
            TempAvWhite = [];
            TempAvBlack = [];
        }
        update_relay_listen_state();
    }
}

persist_mode(integer new_mode) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_RELAY_MODE,
        "value", (string)new_mode
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

persist_hardcore(integer new_hardcore) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_RELAY_HARDCORE,
        "value", (string)new_hardcore
    ]);
    llMessageLinked(LINK_SET, SETTINGS_BUS, msg, NULL_KEY);
}

/* -------------------- UI / MENU SYSTEM -------------------- */

show_main_menu() {
    SessionId = generate_session_id();
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    string mode_str;
    if (!IsAttached)              mode_str = "OFF (not worn)";
    else if (Mode == MODE_OFF)    mode_str = "OFF";
    else if (Mode == MODE_ASK)    mode_str = "ASK";
    else if (Hardcore)            mode_str = "HARDCORE";
    else                          mode_str = "ON";

    integer source_count = llGetListLength(Sources);
    string message = "RLV Relay Menu\nMode: " + mode_str
                   + "\nBound by: " + (string)source_count + " object";
    if (source_count != 1) message += "s";

    list buttons = ["Back"];
    if (btn_allowed("Mode"))                       buttons += ["Mode"];
    if (btn_allowed("Bound by..."))                buttons += ["Bound by..."];
    if (btn_allowed("Safeword") && !Hardcore)      buttons += ["Safeword"];
    if (btn_allowed("Unbind"))                     buttons += ["Unbind"];

    string buttons_json = llList2Json(JSON_ARRAY, buttons);
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL + " Menu",
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]);
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

show_mode_menu() {
    SessionId = generate_session_id();

    string mode_str;
    if (!IsAttached)              mode_str = "OFF (not worn)";
    else if (Mode == MODE_OFF)    mode_str = "OFF";
    else if (Mode == MODE_ASK)    mode_str = "ASK";
    else if (Hardcore)            mode_str = "HARDCORE";
    else                          mode_str = "ON";

    string message = "RLV Relay Mode: " + mode_str;

    list buttons = ["Back", "OFF", "ASK", "ON"];
    if (Mode == MODE_ON) {
        if (Hardcore) {
            if (btn_allowed("HC OFF")) buttons += ["HC OFF"];
        } else {
            if (btn_allowed("HC ON"))  buttons += ["HC ON"];
        }
    }

    string buttons_json = llList2Json(JSON_ARRAY, buttons);
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Relay Mode",
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]);
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

show_object_list() {
    SessionId = generate_session_id();

    integer source_count = llGetListLength(Sources);
    string message;
    if (source_count == 0) {
        message = "No active sources.";
    } else {
        message = "Bound by:\n";
        integer i = 0;
        while (i < source_count) {
            string nm = llList2String(SourceNames, i);
            string restr = llList2String(SourceRestrictions, i);
            message += (string)(i + 1) + ". " + truncate_name(nm, 24);
            if (restr != "") {
                list per_src = llParseString2List(restr, ["/"], []);
                message += " [" + (string)llGetListLength(per_src) + "]";
            }
            message += "\n";
            i += 1;
        }
    }

    list buttons = ["Back"];
    string buttons_json = llList2Json(JSON_ARRAY, buttons);
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Bound by",
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]);
    llMessageLinked(LINK_SET, DIALOG_BUS, msg, NULL_KEY);
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button_click(string button) {
    if (button == "Mode") {
        show_mode_menu();
    }
    else if (button == "Bound by...") {
        show_object_list();
    }
    else if (button == "Safeword") {
        if (btn_allowed("Safeword") && !Hardcore) {
            safeword_clear_all();
            llRegionSayTo(CurrentUser, 0, "Safeword used - all restrictions cleared");
            show_main_menu();
        }
    }
    else if (button == "Unbind") {
        if (btn_allowed("Unbind")) {
            safeword_clear_all();
            llRegionSayTo(CurrentUser, 0, "Unbound - all restrictions cleared");
            show_main_menu();
        }
    }
    else if (button == "OFF") {
        clear_pending_ask();
        drop_queue();
        TempObjWhite = [];
        TempObjBlack = [];
        TempAvWhite = [];
        TempAvBlack = [];
        Mode = MODE_OFF;
        Hardcore = FALSE;
        persist_mode(MODE_OFF);
        persist_hardcore(FALSE);
        update_relay_listen_state();
        llRegionSayTo(CurrentUser, 0, "Mode set to OFF");
        show_mode_menu();
    }
    else if (button == "ASK") {
        clear_pending_ask();
        drop_queue();
        Mode = MODE_ASK;
        Hardcore = FALSE;
        persist_mode(MODE_ASK);
        persist_hardcore(FALSE);
        update_relay_listen_state();
        llRegionSayTo(CurrentUser, 0, "Mode set to ASK");
        show_mode_menu();
    }
    else if (button == "ON") {
        clear_pending_ask();
        Mode = MODE_ON;
        persist_mode(MODE_ON);
        update_relay_listen_state();
        if (!Hardcore) llRegionSayTo(CurrentUser, 0, "Mode set to ON");
        show_mode_menu();
    }
    else if (button == "HC ON") {
        if (btn_allowed("HC ON")) {
            Hardcore = TRUE;
            Mode = MODE_ON;
            persist_hardcore(TRUE);
            persist_mode(MODE_ON);
            llRegionSayTo(CurrentUser, 0, "Hardcore mode ENABLED");
            show_mode_menu();
        }
    }
    else if (button == "HC OFF") {
        if (btn_allowed("HC OFF")) {
            Hardcore = FALSE;
            Mode = MODE_ON;
            persist_hardcore(FALSE);
            persist_mode(MODE_ON);
            llRegionSayTo(CurrentUser, 0, "Hardcore mode DISABLED");
            show_mode_menu();
        }
    }
    else if (button == "Back") {
        return_to_root();
    }
    else {
        show_main_menu();
    }
}

/* -------------------- NAVIGATION -------------------- */

return_to_root() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, CurrentUser);
    cleanup_session();
}

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
    ObjectListPage = 0;
}

/* -------------------- GROUND REZ HANDLER -------------------- */

handle_ground_rez(string reason) {
    clear_pending_ask();
    drop_queue();
    TempObjWhite = [];
    TempObjBlack = [];
    TempAvWhite = [];
    TempAvBlack = [];

    Mode = MODE_OFF;
    Hardcore = FALSE;
    persist_mode(MODE_OFF);
    persist_hardcore(FALSE);

    if (llGetListLength(Sources) > 0) safeword_clear_all();

    update_relay_listen_state();

    if (reason != "") llRegionSayTo(llGetOwner(), 0, reason + " - Relay turned OFF");
}

/* -------------------- MENU MESSAGE HANDLERS -------------------- */

handle_start(string msg) {
    if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["user"]) == JSON_INVALID) return;

    string context = llJsonGetValue(msg, ["context"]);
    if (context != PLUGIN_CONTEXT) return;

    key user = (key)llJsonGetValue(msg, ["user"]);
    integer acl = (integer)llJsonGetValue(msg, ["acl"]);

    string subpath = "";
    string sp = llJsonGetValue(msg, ["subpath"]);
    if (sp != JSON_INVALID) subpath = sp;

    if (subpath != "") {
        handle_subpath(user, acl, subpath);
        return;
    }

    CurrentUser = user;
    UserAcl = acl;
    show_main_menu();
}

handle_subpath(key user, integer acl_level, string subpath) {
    CurrentUser = user;
    UserAcl = acl_level;
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);

    if (subpath == "on" || subpath == "off" || subpath == "ask") {
        if (!btn_allowed("Mode")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        clear_pending_ask();
        drop_queue();
        if (subpath == "off") {
            TempObjWhite = [];
            TempObjBlack = [];
            TempAvWhite = [];
            TempAvBlack = [];
            Mode = MODE_OFF;
            Hardcore = FALSE;
            persist_mode(MODE_OFF);
            persist_hardcore(FALSE);
        }
        else if (subpath == "ask") {
            Mode = MODE_ASK;
            Hardcore = FALSE;
            persist_mode(MODE_ASK);
            persist_hardcore(FALSE);
        }
        else {
            Mode = MODE_ON;
            persist_mode(MODE_ON);
        }
        update_relay_listen_state();
        llRegionSayTo(user, 0, "Mode set to " + llToUpper(subpath) + ".");
        gPolicyButtons = [];
        return;
    }

    if (subpath == "safeword") {
        if (!btn_allowed("Safeword") && !btn_allowed("Unbind")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        safeword_clear_all();
        llRegionSayTo(user, 0, "Safeword used - all restrictions cleared.");
        gPolicyButtons = [];
        return;
    }

    llRegionSayTo(user, 0, "Unknown relay subcommand: " + subpath);
    gPolicyButtons = [];
}

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["button"]) == JSON_INVALID) return;

    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;

    string button = llJsonGetValue(msg, ["button"]);
    handle_button_click(button);
}

handle_dialog_timeout(string msg) {
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session == JSON_INVALID) return;
    if (session != SessionId) return;
    cleanup_session();
}

/* -------------------- RELAY PROTOCOL ENTRY -------------------- */

handle_relay_message(key sender_id, string raw_msg) {
    if (!IsAttached) return;

    // Optional "|<session-channel>" suffix on the chat line itself.
    list parsed = llParseString2List(raw_msg, ["|"], []);
    string raw_cmd = llList2String(parsed, 0);
    integer session_chan = RLV_RESP_CHANNEL;
    if (llGetListLength(parsed) > 1) {
        session_chan = (integer)llList2String(parsed, 1);
    }

    // Strict ORG wire format: ident,target_uuid,command (3 fields).
    list parts = llParseString2List(raw_cmd, [","], []);
    if (llGetListLength(parts) != 3) return;
    string ident = llList2String(parts, 0);
    string potential_uuid = llList2String(parts, 1);
    if (llStringLength(potential_uuid) != 36) return;
    if (llGetSubString(potential_uuid,  8,  8) != "-") return;
    if (llGetSubString(potential_uuid, 13, 13) != "-") return;
    if (llGetSubString(potential_uuid, 18, 18) != "-") return;
    if (llGetSubString(potential_uuid, 23, 23) != "-") return;
    key target_uuid = (key)potential_uuid;
    string command = llList2String(parts, 2);

    // Wildcard target reserved for capability probes (rev 14 hardening
    // preserved). Other commands must match this wearer.
    if (target_uuid == WILDCARD_UUID) {
        if (command != "@version"
            && command != "@versionnew"
            && command != "!version"
            && command != "!implversion"
            && command != "!x-orgversions") return;
    }
    else if (target_uuid != WearerKey) {
        return;
    }

    // Append END marker so handle_command's iteration ends with a $$ ack.
    string command_chain = llToLower(command) + "|" + END_MARKER;
    enqueue(ident, sender_id, session_chan, command_chain);
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        if (llGetObjectDesc() == "COLLAR_UPDATER") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        cleanup_session();
        clear_pending_ask();
        drop_queue();
        Sources = [];
        SourceNames = [];
        SourceChans = [];
        SourceRestrictions = [];
        Baked = [];
        LocalRestrictions = [];
        TempObjWhite = [];
        TempObjBlack = [];
        TempAvWhite = [];
        TempAvBlack = [];

        IsAttached = (llGetAttached() != 0);
        WearerKey = llGetOwner();

        if (!IsAttached) {
            handle_ground_rez("Collar rezzed on ground");
        } else {
            Mode = lsd_int(KEY_RELAY_MODE, MODE_ASK);
            Hardcore = lsd_int(KEY_RELAY_HARDCORE, FALSE);
            update_relay_listen_state();
        }

        register_self();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    timer() {
        // Auth-dialog timeout (deadline-based, granularity = GC_INTERVAL).
        if (AskExpireAt != 0 && llGetUnixTime() >= AskExpireAt) {
            llRegionSayTo(WearerKey, 0, "Auth request timed out");
            decline_ask();
        }
        // Distance-based source GC.
        if (llGetListLength(Sources) > 0) gc_distant_sources();
        rearm_timer();
    }

    attach(key id) {
        if (id == NULL_KEY) {
            clear_pending_ask();
            drop_queue();
            TempObjWhite = [];
            TempObjBlack = [];
            TempAvWhite = [];
            TempAvBlack = [];
            IsAttached = FALSE;
            handle_ground_rez("");
        } else {
            IsAttached = TRUE;
            WearerKey = id;
            update_relay_listen_state();
            llRegionSayTo(llGetOwner(), 0, "Collar attached - Relay state restored");
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.register.refresh") {
                register_self();
            }
            else if (msg_type == "kernel.ping") {
                send_pong();
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llLinksetDataDelete("plugin.reg." + PLUGIN_CONTEXT);
                llLinksetDataDelete("acl.policycontext:" + PLUGIN_CONTEXT);
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync" || msg_type == "settings.delta") {
                apply_settings_sync();
            }
        }
        else if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                handle_start(msg);
            }
            else if (msg_type == "sos.relay.clear") {
                safeword_clear_all();
                llRegionSayTo(llGetOwner(), 0, "All RLV restrictions cleared.");
            }
        }
        else if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                handle_dialog_response(msg);
            }
            else if (msg_type == "ui.dialog.timeout") {
                handle_dialog_timeout(msg);
            }
        }
    }

    listen(integer chan, string name, key id, string msg) {
        if (chan == RELAY_CHANNEL) {
            handle_relay_message(id, msg);
        }
        else if (chan == AskDialogChan && id == WearerKey) {
            // Six-button MR dialog. Trust/Ban variants populate temp
            // lists *before* accept/decline so cleanqueue resolves
            // any other queued items from the same source/owner too.
            key cur_src = q_obj(0);
            key cur_owner = llGetOwnerKey(cur_src);
            if (msg == "Yes") {
                accept_ask();
            }
            else if (msg == "No") {
                decline_ask();
            }
            else if (msg == "Trust Object") {
                if (llListFindList(TempObjWhite, [cur_src]) == -1) {
                    TempObjWhite += [cur_src];
                }
                accept_ask();
            }
            else if (msg == "Ban Object") {
                if (llListFindList(TempObjBlack, [cur_src]) == -1) {
                    TempObjBlack += [cur_src];
                }
                decline_ask();
            }
            else if (msg == "Trust Owner") {
                if (llListFindList(TempAvWhite, [cur_owner]) == -1) {
                    TempAvWhite += [cur_owner];
                }
                accept_ask();
            }
            else if (msg == "Ban Owner") {
                if (llListFindList(TempAvBlack, [cur_owner]) == -1) {
                    TempAvBlack += [cur_owner];
                }
                decline_ask();
            }
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}

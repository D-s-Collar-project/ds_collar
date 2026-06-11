/*--------------------
SCRIPT: kmod_rlv.lsl
VERSION: 1.10
REVISION: 5
PURPOSE: RLV subsystem. Single point of @-command emission for all
  refcount-stateful RLV restrictions in the collar. Owns the third-party
  RLV relay protocol (RELAY_CHANNEL listen, auth queue, ASK dialog,
  per-source bookkeeping) plus a multi-consumer apply/release API for
  other plugins that need coordinated restrictions.
ARCHITECTURE: Spun off from plugin_relay v1.10 rev 21 to keep that
  script under Mono's per-script byte budget. plugin_relay is now a
  thin UI shell that calls into kmod_rlv via UI_BUS messages
  (rlv.apply, rlv.release, rlv.clear, rlv.force, relay.list.request,
  relay.safeword, relay.ground_rez). Mode/Hardcore continue to be
  persisted by kmod_settings; kmod_rlv reads them from LSD on
  settings.delta.
  Plugins exempt from kmod_rlv (use llOwnerSay directly):
    plugin_lock (@detach=n owner), plugin_rlvex (per-user exceptions),
    plugin_sos (@clear emergency), plugin_folders / plugin_restrict
    (one-shot or pre-existing semantics — Phase 2 migration), and
    kmod_leash (=force / =clear only, no refcount overlap).
CHANGES:
- v1.10 rev 5: Dormancy guard widened to the renamed role-split markers ("D/s Collar updater v1.1" / "(updating)" / "(installing)").
- v1.10 rev 4: say_to_source always uses llRegionSayTo instead of the
  distance-based ladder (llWhisper / llSay / llShout / llRegionSay).
  Functional reach is unchanged — the source's listen fires on any
  speech method as long as the channel matches — but llRegionSayTo
  produces no entry in the wearer's local chat history, while the
  other speech methods render as "<collar> whispers: RLV,...,ok" and
  expose the relay protocol traffic to the wearer. Drops the
  MR-faithful distance scaling Satomi MR uses; no relay source cares
  which speech method delivered the ack.
- v1.10 rev 3: Scope safeword to relay-sourced restrictions only. Previous safeword_clear_all emitted llOwnerSay("@clear") which is object-wide — the viewer cleared every restriction tied to the collar's UUID, including plugin_lock's @detach=n, plugin_rlvex's exception entries, and anything else other scripts had issued. Replaced with relay_safeword_clear: walks Sources and calls release_source per-source; claim_clear emits @<behav>=y only when the LAST claim on a behav goes away, so non-relay consumers' claims are preserved. Mirrors Satomi's MR safeword: relay panic cuts the wearer loose from external sources, not from their own collar's lock state. sos.relay.clear notice text updated to reflect the narrowed scope ("Relay restrictions cleared." instead of "All RLV restrictions cleared.").
- v1.10 rev 2: Drop dead `|| msg_type == "settings.delta"` consumer clause — kmod_settings only broadcasts settings.sync; settings.delta is now inbound-CSV-only.
- v1.10 rev 1: Initial implementation. Lift of plugin_relay rev 21's
  refcount engine + relay protocol; adds multi-consumer apply/release
  API on UI_BUS. plugin_relay rewritten to UI shell that consumes this.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;

/* -------------------- KMOD IDENTITY -------------------- */
string KMOD_CONTEXT = "kmod.rlv";

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

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_RELAY_MODE = "relay.mode";
string KEY_RELAY_HARDCORE = "relay.hardcoremode";

/* -------------------- CONSUMER ID FOR RELAY-INTERNAL CLAIMS -------------------- */
// Relay-protocol sources are also Claims consumers; their consumer-id is
// "relay:<source-uuid>" so external rlv.apply requests can never collide.
string RELAY_CONSUMER_PREFIX = "relay:";

/* -------------------- STATE -------------------- */

// Relay mode + flags. Read from LSD on settings.delta.
integer Mode = MODE_ASK;
integer Hardcore = FALSE;
integer IsAttached = FALSE;
integer RelayListenHandle = 0;
key WearerKey = NULL_KEY;

// Relay-protocol source tracking — parallel lists indexed by source position.
list Sources = [];
list SourceNames = [];
list SourceChans = [];
list SourceRestrictions = [];

// Refcount set: behaviours currently applied to the viewer.
list Baked = [];

// Multi-consumer claims. Stride 2: [behav, consumer, behav, consumer, ...].
// A behav stays in Baked iff at least one consumer has a claim on it.
// Relay sources contribute claims under "relay:<uuid>"; external plugins
// supply their own consumer id via rlv.apply.
list Claims = [];
integer CSTRIDE = 2;

// Session-only trust lists. Populated by the auth dialog's six buttons;
// cleared on safeword, mode-off, detach, and reset. Not persisted.
list TempObjWhite = [];
list TempObjBlack = [];
list TempAvWhite = [];
list TempAvBlack = [];

// Auth queue. Stride 3: [ident, obj_uuid_str, command_chain, ...]
list Queue = [];
integer QSTRIDE = 3;

// Auth dialog state
integer AskListenHandle = 0;
integer AskDialogChan = 0;
integer AskExpireAt = 0;          // unix ts; 0 = no pending dialog


/* -------------------- HELPERS -------------------- */

integer lsd_int(string lsd_key, integer fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (integer)v;
}


/* -------------------- LIFECYCLE -------------------- */

register_self() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", KMOD_CONTEXT,
        "label", "RLV Subsystem",
        "script", llGetScriptName()
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", KMOD_CONTEXT
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
rearm_timer() {
    if (llGetListLength(Sources) > 0 || AskExpireAt != 0) {
        llSetTimerEvent(GC_INTERVAL);
    } else {
        llSetTimerEvent(0.0);
    }
}


/* -------------------- OUTBOUND CHAT (DISTANCE-TIERED) -------------------- */

// Region-wide targeted ack, silent in the wearer's local chat history.
//
// The earlier MR-faithful distance ladder (whisper < 10m, say < 20m,
// shout < 100m, region-say otherwise) functioned correctly — the
// source's listen fires regardless of speech method — but llWhisper /
// llSay / llShout / llRegionSay all render the speaker in the wearer's
// local chat as "<collar> whispers/says: RLV,...,ok", exposing the
// relay protocol traffic to the wearer. llRegionSayTo targets the
// source directly and produces no chat-history entry on either side,
// so the wearer no longer sees protocol noise from their own collar.
// Reach is unchanged in practice (sources are nearly always
// in-region; if offsim, none of the speech methods reached them).
say_to_source(key src, integer chan, string text) {
    llRegionSayTo(src, chan, text);
}

// Wire-format an ack to a source: <ident>,<wearer>,<command>,<ack>
ack_source(string ident, key src, integer chan, string command, string ack) {
    say_to_source(src, chan,
        ident + "," + (string)WearerKey + "," + command + "," + ack);
}


/* -------------------- CLAIMS / REFCOUNT -------------------- */

// Returns TRUE if any consumer still has a claim on behav.
integer behav_has_claim(string behav) {
    integer i = 0;
    integer n = llGetListLength(Claims);
    while (i < n) {
        if (llList2String(Claims, i) == behav) return TRUE;
        i += CSTRIDE;
    }
    return FALSE;
}

// Add a claim; emit @behav=n if this is the first claim.
claim_add(string consumer, string behav) {
    integer i = 0;
    integer n = llGetListLength(Claims);
    while (i < n) {
        if (llList2String(Claims, i) == behav
            && llList2String(Claims, i + 1) == consumer) {
            return;  // duplicate; idempotent
        }
        i += CSTRIDE;
    }
    integer first = !behav_has_claim(behav);
    Claims += [behav, consumer];
    if (first) {
        Baked += [behav];
        llOwnerSay("@" + behav + "=n");
    }
}

// Remove one claim; emit @behav=y if no claims remain.
claim_remove(string consumer, string behav) {
    integer i = 0;
    integer n = llGetListLength(Claims);
    while (i < n) {
        if (llList2String(Claims, i) == behav
            && llList2String(Claims, i + 1) == consumer) {
            Claims = llDeleteSubList(Claims, i, i + CSTRIDE - 1);
            if (!behav_has_claim(behav)) {
                integer bi = llListFindList(Baked, [behav]);
                if (bi != -1) Baked = llDeleteSubList(Baked, bi, bi);
                llOwnerSay("@" + behav + "=y");
            }
            return;
        }
        i += CSTRIDE;
    }
}

// Drop every claim from one consumer. Emits =y for any behav that loses
// its last claim.
claim_clear(string consumer) {
    integer i = llGetListLength(Claims) - CSTRIDE;
    list freed = [];
    while (i >= 0) {
        if (llList2String(Claims, i + 1) == consumer) {
            string behav = llList2String(Claims, i);
            Claims = llDeleteSubList(Claims, i, i + CSTRIDE - 1);
            if (llListFindList(freed, [behav]) == -1) freed += [behav];
        }
        i -= CSTRIDE;
    }
    integer fi = 0;
    integer fn = llGetListLength(freed);
    while (fi < fn) {
        string behav = llList2String(freed, fi);
        if (!behav_has_claim(behav)) {
            integer bi = llListFindList(Baked, [behav]);
            if (bi != -1) Baked = llDeleteSubList(Baked, bi, bi);
            llOwnerSay("@" + behav + "=y");
        }
        fi += 1;
    }
}


/* -------------------- RELAY-SIDE RESTRICTION TRACKING -------------------- */

string source_consumer(key obj) {
    return RELAY_CONSUMER_PREFIX + (string)obj;
}

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

// Add a per-source restriction. Maintains the relay-side bookkeeping
// (so per-source @clear knows what to release) and pipes through the
// claims engine.
add_restriction(key src, string behav) {
    integer idx = source_idx(src);
    if (idx == -1) return;
    list per_src = llParseString2List(llList2String(SourceRestrictions, idx), ["/"], []);
    if (llListFindList(per_src, [behav]) == -1) {
        per_src += [behav];
        SourceRestrictions = llListReplaceList(SourceRestrictions,
            [llDumpList2String(per_src, "/")], idx, idx);
    }
    claim_add(source_consumer(src), behav);
}

rem_restriction(key src, string behav) {
    integer idx = source_idx(src);
    if (idx == -1) return;
    list per_src = llParseString2List(llList2String(SourceRestrictions, idx), ["/"], []);
    integer pos = llListFindList(per_src, [behav]);
    if (pos == -1) return;
    per_src = llDeleteSubList(per_src, pos, pos);
    SourceRestrictions = llListReplaceList(SourceRestrictions,
        [llDumpList2String(per_src, "/")], idx, idx);
    claim_remove(source_consumer(src), behav);
}

// Release ALL restrictions held by one source, then drop the source.
release_source(key src) {
    integer idx = source_idx(src);
    if (idx == -1) return;
    Sources = llDeleteSubList(Sources, idx, idx);
    SourceNames = llDeleteSubList(SourceNames, idx, idx);
    SourceChans = llDeleteSubList(SourceChans, idx, idx);
    SourceRestrictions = llDeleteSubList(SourceRestrictions, idx, idx);
    claim_clear(source_consumer(src));
    rearm_timer();
}

// Wearer-initiated safeword: clear ONLY relay-sourced restrictions.
//
// Previously this issued `llOwnerSay("@clear")` which is object-wide —
// the viewer clears every restriction tied to the collar's UUID, which
// means plugin_lock's @detach=n, plugin_rlvex's exceptions, and every
// other script-issued restriction in the collar disappear too. That's
// not what a relay safeword means: a relay safeword cuts the wearer
// loose from EXTERNAL relay sources, not from their own collar's lock
// state. Mirrors Satomi's MR semantics — release-by-source, scoped.
//
// release_source iterates the source's recorded restrictions and calls
// claim_clear, which emits @<behav>=y per behav only when the LAST
// claim on that behav goes away. Behavs co-claimed by another consumer
// (plugin_restrict, plugin_folders, etc.) stay applied; only the relay
// share of each is dropped. Per-relay-session trust (Temp*White/Black)
// is also cleared since the wearer is explicitly resetting trust.
relay_safeword_clear() {
    clear_pending_ask();
    drop_queue();

    // Snapshot Sources because release_source mutates it. Each iteration
    // removes one source and emits the @<behav>=y commands that lose
    // their last claim through that release.
    list snapshot = Sources;
    integer i = 0;
    integer n = llGetListLength(snapshot);
    while (i < n) {
        release_source(llList2Key(snapshot, i));
        i += 1;
    }

    TempObjWhite = [];
    TempObjBlack = [];
    TempAvWhite = [];
    TempAvBlack = [];

    rearm_timer();
}


/* -------------------- AUTH DECISION -------------------- */

// Returns -1 deny, 0 ask, 1 allow.
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


/* -------------------- COMMAND HANDLER (MR-style) -------------------- */

string handle_command(string ident, key src, integer chan, string com, integer auth_ok) {
    list commands = llParseString2List(com, ["|"], []);
    integer n = llGetListLength(commands);
    integer i = 0;
    while (i < n) {
        string command = llList2String(commands, i);

        if (command == END_MARKER) {
            ack_source(ident, src, chan, END_MARKER, END_MARKER);
            return "";
        }

        if (command == "!release" || command == "!release_fail") {
            release_source(src);
            ack_source(ident, src, chan, command, "ok");
            i += 1;
            jump after_send;
        }
        if (command == "!version") {
            ack_source(ident, src, chan, command, "1100");
            i += 1;
            jump after_send;
        }
        if (command == "!implversion") {
            ack_source(ident, src, chan, command, "ORG=0003/D/s Collar Relay v1.1");
            i += 1;
            jump after_send;
        }
        if (command == "!x-orgversions") {
            ack_source(ident, src, chan, command, "ORG=0003");
            i += 1;
            jump after_send;
        }
        if (llGetSubString(command, 0, 0) == "!") {
            ack_source(ident, src, chan, command, "ko");
            i += 1;
            jump after_send;
        }
        if (llGetSubString(command, 0, 0) != "@") {
            return llDumpList2String(llList2List(commands, i, -1), "|");
        }

        // Channel commands — auto-allow (fix for v1.x bug #1).
        integer is_chan_cmd = FALSE;
        if (llSubStringIndex(command, "@version") == 0) is_chan_cmd = TRUE;
        else if (llSubStringIndex(command, "@get") == 0) is_chan_cmd = TRUE;
        else if (llSubStringIndex(command, "@findfolder") == 0) is_chan_cmd = TRUE;
        if (is_chan_cmd) {
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

        if (command == "@clear") {
            release_source(src);
            ack_source(ident, src, chan, command, "ok");
            i += 1;
            jump after_send;
        }

        list subargs = llParseString2List(command, ["="], []);
        if (llGetListLength(subargs) != 2) {
            return llDumpList2String(llList2List(commands, i, -1), "|");
        }
        string behav = llGetSubString(llList2String(subargs, 0), 1, -1);
        string val = llList2String(subargs, 1);

        if (val == "y" || val == "rem") {
            rem_restriction(src, behav);
            ack_source(ident, src, chan, command, "ok");
            i += 1;
            jump after_send;
        }

        if (!auth_ok) {
            return llDumpList2String(llList2List(commands, i, -1), "|");
        }

        if (val == "force") {
            llOwnerSay(command);
            ack_source(ident, src, chan, command, "ok");
            i += 1;
            jump after_send;
        }
        if (val == "n" || val == "add") {
            add_source(src, llKey2Name(src), chan);
            add_restriction(src, behav);
            ack_source(ident, src, chan, command, "ok");
            i += 1;
            jump after_send;
        }
        ack_source(ident, src, chan, command, "ko");
        i += 1;
        @after_send;
    }
    return "";
}


/* -------------------- QUEUE -------------------- */

integer queue_length() { return llGetListLength(Queue) / QSTRIDE; }

drop_queue_item(integer i) {
    Queue = llDeleteSubList(Queue, QSTRIDE * i, QSTRIDE * i + QSTRIDE - 1);
}

drop_queue() { Queue = []; }

enqueue(string ident, key src, integer chan, string command_chain) {
    integer decision = auth(src);
    if (decision == 1) {
        handle_command(ident, src, chan, command_chain, TRUE);
        return;
    }
    if (decision == -1 || queue_length() >= MAX_QUEUE) {
        ack_source(ident, src, chan, command_chain, "ko");
        ack_source(ident, src, chan, END_MARKER, "");
        return;
    }
    Queue += [ident, (string)src, command_chain];
    if (AskListenHandle == 0) dequeue();
}

dequeue() {
    string remainder = "";
    string cur_ident;
    key cur_src;
    integer cur_chan = RLV_RESP_CHANNEL;
    while (remainder == "") {
        if (queue_length() == 0) return;
        cur_ident = llList2String(Queue, 0);
        cur_src   = (key)llList2String(Queue, 1);
        integer sidx = source_idx(cur_src);
        if (sidx != -1) cur_chan = llList2Integer(SourceChans, sidx);
        else cur_chan = RLV_RESP_CHANNEL;
        remainder = handle_command(cur_ident, cur_src, cur_chan,
            llList2String(Queue, 2), FALSE);
        drop_queue_item(0);
    }
    Queue = [cur_ident, (string)cur_src, remainder] + Queue;
    show_ask_dialog();
}

clean_queue() {
    list on_hold = [];
    integer i = 0;
    while (i < queue_length()) {
        string ident   = llList2String(Queue, QSTRIDE * i);
        key    obj     = (key)llList2String(Queue, QSTRIDE * i + 1);
        string command = llList2String(Queue, QSTRIDE * i + 2);
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

    key src = (key)llList2String(Queue, 1);
    string obj_name = llKey2Name(src);
    string owner_name = llKey2Name(llGetOwnerKey(src));
    string body = obj_name;
    if (owner_name != "") body += ", owned by " + owner_name + ",";
    body += " wants to apply RLV restrictions.\n\nAllow this?";

    list buttons = ["No", " ", "Yes",
                    "Ban Object", " ", "Trust Object",
                    "Ban Owner",  " ", "Trust Owner"];

    AskExpireAt = llGetUnixTime() + ASK_TIMEOUT_SEC;
    llDialog(WearerKey, body, buttons, AskDialogChan);
    rearm_timer();
}

accept_ask() {
    key cur_src = (key)llList2String(Queue, 1);
    if (llListFindList(TempObjWhite, [cur_src]) == -1) {
        TempObjWhite += [cur_src];
    }
    clean_queue();
    clear_pending_ask();
    if (queue_length() > 0) dequeue();
}

decline_ask() {
    integer chan = RLV_RESP_CHANNEL;
    if (queue_length() > 0) {
        string ident = llList2String(Queue, 0);
        key obj = (key)llList2String(Queue, 1);
        string command = llList2String(Queue, 2);
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


/* -------------------- SETTINGS SYNC -------------------- */

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


/* -------------------- RELAY PROTOCOL ENTRY -------------------- */

handle_relay_message(key sender_id, string raw_msg) {
    if (!IsAttached) return;

    list parsed = llParseString2List(raw_msg, ["|"], []);
    string raw_cmd = llList2String(parsed, 0);
    integer session_chan = RLV_RESP_CHANNEL;
    if (llGetListLength(parsed) > 1) {
        session_chan = (integer)llList2String(parsed, 1);
    }

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

    // Wildcard target reserved for capability probes.
    if (target_uuid == (key)"ffffffff-ffff-ffff-ffff-ffffffffffff") {
        if (command != "@version"
            && command != "@versionnew"
            && command != "!version"
            && command != "!implversion"
            && command != "!x-orgversions") return;
    }
    else if (target_uuid != WearerKey) {
        return;
    }

    string command_chain = llToLower(command) + "|" + END_MARKER;
    enqueue(ident, sender_id, session_chan, command_chain);
}


/* -------------------- UI_BUS HANDLERS (external API) -------------------- */

// rlv.apply / rlv.release / rlv.clear / rlv.force come from any plugin.
// relay.list.request / relay.safeword / relay.ground_rez come from
// plugin_relay (the UI shell).
respond_list_request() {
    integer n = llGetListLength(Sources);
    list arr = [];
    integer i = 0;
    while (i < n) {
        string nm = llList2String(SourceNames, i);
        string restr = llList2String(SourceRestrictions, i);
        integer rc = 0;
        if (restr != "") rc = llGetListLength(llParseString2List(restr, ["/"], []));
        arr += [llList2Json(JSON_OBJECT, ["name", nm, "restr_count", (string)rc])];
        i += 1;
    }
    string sources_json = llList2Json(JSON_ARRAY, arr);
    string out = llList2Json(JSON_OBJECT, [
        "type", "relay.list.response",
        "sources", sources_json
    ]);
    llMessageLinked(LINK_SET, UI_BUS, out, NULL_KEY);
}

handle_ground_rez(string reason) {
    clear_pending_ask();
    drop_queue();
    TempObjWhite = [];
    TempObjBlack = [];
    TempAvWhite = [];
    TempAvBlack = [];

    Mode = MODE_OFF;
    Hardcore = FALSE;
    // Persist via SETTINGS_BUS so kmod_settings owns the LSD writes.
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_RELAY_MODE,
        "value", (string)MODE_OFF
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_RELAY_HARDCORE,
        "value", "0"
    ]), NULL_KEY);

    if (llGetListLength(Sources) > 0) relay_safeword_clear();

    update_relay_listen_state();

    if (reason != "") llRegionSayTo(llGetOwner(), 0, reason + " - Relay turned OFF");
}


/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        if (llGetObjectDesc() == "D/s Collar updater v1.1" || llGetObjectDesc() == "(updating)" || llGetObjectDesc() == "(installing)") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        clear_pending_ask();
        drop_queue();
        Sources = [];
        SourceNames = [];
        SourceChans = [];
        SourceRestrictions = [];
        Baked = [];
        Claims = [];
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
        if (AskExpireAt != 0 && llGetUnixTime() >= AskExpireAt) {
            llRegionSayTo(WearerKey, 0, "Auth request timed out");
            decline_ask();
        }
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
                string ctx = llJsonGetValue(msg, ["context"]);
                if (ctx != JSON_INVALID && ctx != "" && ctx != KMOD_CONTEXT) return;
                llResetScript();
            }
            return;
        }

        if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync") {
                apply_settings_sync();
            }
            return;
        }

        if (num == UI_BUS) {
            if (msg_type == "rlv.apply") {
                string consumer = llJsonGetValue(msg, ["consumer"]);
                string behav = llJsonGetValue(msg, ["behav"]);
                if (consumer == JSON_INVALID || behav == JSON_INVALID) return;
                claim_add(consumer, behav);
                return;
            }
            if (msg_type == "rlv.release") {
                string consumer = llJsonGetValue(msg, ["consumer"]);
                string behav = llJsonGetValue(msg, ["behav"]);
                if (consumer == JSON_INVALID || behav == JSON_INVALID) return;
                claim_remove(consumer, behav);
                return;
            }
            if (msg_type == "rlv.clear") {
                string consumer = llJsonGetValue(msg, ["consumer"]);
                if (consumer == JSON_INVALID) return;
                claim_clear(consumer);
                return;
            }
            if (msg_type == "rlv.force") {
                string command = llJsonGetValue(msg, ["command"]);
                if (command == JSON_INVALID) return;
                llOwnerSay(command);
                return;
            }
            if (msg_type == "relay.list.request") {
                respond_list_request();
                return;
            }
            if (msg_type == "relay.safeword") {
                relay_safeword_clear();
                return;
            }
            if (msg_type == "relay.ground_rez") {
                string reason = llJsonGetValue(msg, ["reason"]);
                if (reason == JSON_INVALID) reason = "";
                handle_ground_rez(reason);
                return;
            }
            if (msg_type == "sos.relay.clear") {
                relay_safeword_clear();
                // Scoped to relay restrictions — non-relay claims
                // (plugin_lock, plugin_restrict, etc.) are intentionally
                // not affected, mirror Satomi's MR safeword.
                llRegionSayTo(llGetOwner(), 0, "Relay restrictions cleared.");
                return;
            }
            return;
        }
    }

    listen(integer chan, string name, key id, string msg) {
        if (chan == RELAY_CHANNEL) {
            handle_relay_message(id, msg);
            return;
        }
        if (chan == AskDialogChan && id == WearerKey) {
            key cur_src = (key)llList2String(Queue, 1);
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

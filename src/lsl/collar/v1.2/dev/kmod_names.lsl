/*--------------------
MODULE: kmod_names.lsl
VERSION: 1.2
REVISION: 2
PURPOSE: The collar's SINGLE avatar-name resolution authority. Any script sends
         name.resolve {requester, req_id, uuids} on SETTINGS_BUS; this module owns the
         ONE dataserver, resolves each uuid in two phases (display name, then
         username), composes the label — "Display" or "Display (username)" when they
         differ meaningfully — and replies name.resolved {requester, req_id, uuid,
         label} per uuid. Consumers: kmod_menu (pickers) + kmod_settings (roster
         records) delegate here, so neither carries its own dataserver or compose.
         Centralising = one rule + it relieves both those near-ceiling modules.
ARCHITECTURE: Per-uuid reply (LSL has no nested lists, so no multi-batch table).
              Each consumer keeps a light collect-barrier: kmod_menu counts replies
              before rendering; kmod_settings writes each record as its reply lands.
              Resolution order: TTL cache → llGetDisplayName/llGetUsername (same-region,
              synchronous, unthrottled — covers every sensor picker) → paced
              dataserver queue (one llRequest* per tick) for off-region avatars.
              SL throttles llRequestDisplayName/llRequestUsername by average rate
              ("Too many llRequestDisplayName requests. Throttled until average
              falls."), so the dataserver path must never burst.
CHANGES:
- v1.2 rev 2: throttle-proof resolve. Same-region llGet* fast path, TTL cache,
  paced dataserver queue (1 request/0.5s) with 15s timeout fallback — fixes the
  llRequestDisplayName throttle warning from picker bursts (16 avatars = 32
  instant requests in rev 1; now 0 for same-region, paced otherwise).
- v1.2 rev 1: initial. Two-phase resolve + compose; SETTINGS_BUS protocol.
--------------------*/


/* -------------------- ISP CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;   // name.resolve in / name.resolved out (shared roster/settings bus)

/* -------------------- CONFIG -------------------- */
float   QUEUE_TICK_SEC    = 0.5;  // one dataserver request per tick (≤2/s sustained)
integer QUERY_TIMEOUT_SEC = 15;   // in-flight request older than this → fallback reply
integer CACHE_MAX         = 48;   // resolved-label cache cap (oldest dropped)
integer CACHE_TTL_SEC     = 600;  // cache entry lifetime

/* -------------------- STATE -------------------- */
// In-flight dataserver map — parallel lists. Two phases per uuid: phase 0 =
// display name, phase 1 = username (display carried forward). requester/req_id
// echo back so the caller can match the reply. Stamp drives the timeout prune.
list NQid    = [];   // dataserver query ids
list NQUuid  = [];   // parallel: the uuid
list NQPhase = [];   // parallel: 0 = display query, 1 = username query
list NQDisp  = [];   // parallel: display name carried into the username phase
list NQReq   = [];   // parallel: requester tag
list NQReqId = [];   // parallel: requester's request id
list NQStamp = [];   // parallel: llGetUnixTime at dispatch

// Pending queue — resolves waiting for a dispatch slot (paced by the timer).
// Same row shape minus the query id/stamp; phase-1 rows re-enter at the FRONT
// so a uuid finishes both phases before the next uuid starts.
list PQUuid  = [];
list PQPhase = [];
list PQDisp  = [];
list PQReq   = [];
list PQReqId = [];

// Resolved-label cache: uuid → composed label, TTL-bounded, capped.
list CUuid  = [];
list CLabel = [];
list CStamp = [];

integer TimerOn = FALSE;

/* -------------------- HELPERS -------------------- */

string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
}

// Drop one in-flight row.
drop_query(integer idx) {
    NQid    = llDeleteSubList(NQid, idx, idx);
    NQUuid  = llDeleteSubList(NQUuid, idx, idx);
    NQPhase = llDeleteSubList(NQPhase, idx, idx);
    NQDisp  = llDeleteSubList(NQDisp, idx, idx);
    NQReq   = llDeleteSubList(NQReq, idx, idx);
    NQReqId = llDeleteSubList(NQReqId, idx, idx);
    NQStamp = llDeleteSubList(NQStamp, idx, idx);
}

// Drop one pending row.
drop_pending(integer idx) {
    PQUuid  = llDeleteSubList(PQUuid, idx, idx);
    PQPhase = llDeleteSubList(PQPhase, idx, idx);
    PQDisp  = llDeleteSubList(PQDisp, idx, idx);
    PQReq   = llDeleteSubList(PQReq, idx, idx);
    PQReqId = llDeleteSubList(PQReqId, idx, idx);
}

// Normalise a name for the "do they differ" test: lowercase, spaces + dots removed.
// So "John Doe" and "john.doe" collapse (a default display name); a real custom
// display name stays distinct.
string strip_name(string s) {
    return llToLower(llDumpList2String(llParseString2List(s, [" ", "."], []), ""));
}

// The label rule: DISPLAY name, plus " (username)" only when they differ
// meaningfully (a custom display name). Fall back to username, then the uuid.
string compose_name(string disp, string user, string uuid_str) {
    if (disp == "???") disp = "";
    if (user == "???") user = "";
    if (disp == "") {
        if (user != "") return user;
        return uuid_str;
    }
    if (user == "" || strip_name(disp) == strip_name(user)) return disp;
    return disp + " (" + user + ")";
}

reply_one(string req, string req_id, string uuid_str, string label) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type",      "name.resolved",
        "requester", req,
        "req_id",    req_id,
        "uuid",      uuid_str,
        "label",     label
    ]), NULL_KEY);
}

/* -------------------- CACHE -------------------- */

// Cache lookup; expired entries are removed on touch. "" = miss (a real
// composed label is never empty — compose falls back to the uuid).
string cache_get(string uuid_str) {
    integer idx = llListFindList(CUuid, [uuid_str]);
    if (idx == -1) return "";
    if (llGetUnixTime() - llList2Integer(CStamp, idx) > CACHE_TTL_SEC) {
        CUuid  = llDeleteSubList(CUuid, idx, idx);
        CLabel = llDeleteSubList(CLabel, idx, idx);
        CStamp = llDeleteSubList(CStamp, idx, idx);
        return "";
    }
    return llList2String(CLabel, idx);
}

cache_put(string uuid_str, string label) {
    if (label == "") return;
    integer idx = llListFindList(CUuid, [uuid_str]);
    if (idx != -1) {
        CUuid  = llDeleteSubList(CUuid, idx, idx);
        CLabel = llDeleteSubList(CLabel, idx, idx);
        CStamp = llDeleteSubList(CStamp, idx, idx);
    }
    CUuid  += [uuid_str];
    CLabel += [label];
    CStamp += [llGetUnixTime()];
    if (llGetListLength(CUuid) > CACHE_MAX) {
        CUuid  = llDeleteSubList(CUuid, 0, 0);
        CLabel = llDeleteSubList(CLabel, 0, 0);
        CStamp = llDeleteSubList(CStamp, 0, 0);
    }
}

/* -------------------- QUEUE / PACING -------------------- */

update_timer() {
    integer need = FALSE;
    if (llGetListLength(PQUuid) > 0) need = TRUE;
    if (llGetListLength(NQid) > 0) need = TRUE;
    if (need && !TimerOn) {
        llSetTimerEvent(QUEUE_TICK_SEC);
        TimerOn = TRUE;
    }
    else if (!need && TimerOn) {
        llSetTimerEvent(0.0);
        TimerOn = FALSE;
    }
}

// Queue one resolve leg. at_front puts phase-1 (username) legs ahead of
// waiting phase-0 work so each uuid completes promptly.
enqueue(string uuid_str, integer phase, string disp, string req, string req_id, integer at_front) {
    if (at_front) {
        PQUuid  = [uuid_str] + PQUuid;
        PQPhase = [phase] + PQPhase;
        PQDisp  = [disp] + PQDisp;
        PQReq   = [req] + PQReq;
        PQReqId = [req_id] + PQReqId;
    }
    else {
        PQUuid  += [uuid_str];
        PQPhase += [phase];
        PQDisp  += [disp];
        PQReq   += [req];
        PQReqId += [req_id];
    }
    update_timer();
}

// Dispatch the head pending row → one dataserver request, moved to in-flight.
dispatch_one() {
    if (llGetListLength(PQUuid) == 0) return;

    string  uuid_str = llList2String(PQUuid, 0);
    integer phase    = llList2Integer(PQPhase, 0);
    string  disp     = llList2String(PQDisp, 0);
    string  req      = llList2String(PQReq, 0);
    string  req_id   = llList2String(PQReqId, 0);
    drop_pending(0);

    key qid;
    if (phase == 0) qid = llRequestDisplayName((key)uuid_str);
    else            qid = llRequestUsername((key)uuid_str);

    NQid    += [qid];
    NQUuid  += [uuid_str];
    NQPhase += [phase];
    NQDisp  += [disp];
    NQReq   += [req];
    NQReqId += [req_id];
    NQStamp += [llGetUnixTime()];
}

// Reply-and-drop any in-flight request that never came back (bogus uuid,
// dataserver hiccup) so consumers' collect-barriers can't hang.
prune_timeouts() {
    integer now = llGetUnixTime();
    integer i = llGetListLength(NQid) - 1;
    while (i >= 0) {
        if (now - llList2Integer(NQStamp, i) > QUERY_TIMEOUT_SEC) {
            string uuid_str = llList2String(NQUuid, i);
            string disp     = llList2String(NQDisp, i);
            string req      = llList2String(NQReq, i);
            string req_id   = llList2String(NQReqId, i);
            drop_query(i);
            reply_one(req, req_id, uuid_str, compose_name(disp, "", uuid_str));
        }
        i -= 1;
    }
}

/* -------------------- RESOLVE -------------------- */

// Begin resolving one uuid; an invalid uuid replies immediately (empty label).
// Cache → same-region llGet* (no dataserver, no throttle) → paced queue.
resolve_start(string uuid_str, string req, string req_id) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) {
        reply_one(req, req_id, uuid_str, "");
        return;
    }

    string cached = cache_get(uuid_str);
    if (cached != "") {
        reply_one(req, req_id, uuid_str, cached);
        return;
    }

    // Same-region fast path: llGetDisplayName/llGetUsername are synchronous
    // and unthrottled but only answer for avatars in the region — which is
    // every sensor-picker candidate, i.e. the burst case that tripped the
    // llRequestDisplayName throttle.
    string disp = llGetDisplayName((key)uuid_str);
    string user = llGetUsername((key)uuid_str);
    if (disp != "" && disp != "???" && user != "" && user != "???") {
        string label = compose_name(disp, user, uuid_str);
        cache_put(uuid_str, label);
        reply_one(req, req_id, uuid_str, label);
        return;
    }

    enqueue(uuid_str, 0, "", req, req_id, FALSE);
}

// name.resolve {requester, req_id, uuids:"u1\nu2\n..."} — kick off every uuid.
handle_name_resolve(string msg) {
    string req    = llJsonGetValue(msg, ["requester"]);
    string req_id = llJsonGetValue(msg, ["req_id"]);
    if (req == JSON_INVALID) req = "";
    if (req_id == JSON_INVALID) req_id = "";
    string us = llJsonGetValue(msg, ["uuids"]);
    if (us == JSON_INVALID || us == "") return;
    list uuids = llParseStringKeepNulls(us, ["\n"], []);
    integer n = llGetListLength(uuids);
    integer i = 0;
    while (i < n) {
        resolve_start(llList2String(uuids, i), req, req_id);
        i += 1;
    }
}

/* -------------------- EVENTS -------------------- */
default
{
    state_entry() {
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
            return;
        }

        if (num == SETTINGS_BUS) {
            if (msg_type == "name.resolve") handle_name_resolve(msg);
            return;
        }
    }

    // One paced dataserver request per tick; stuck requests fall back after
    // the timeout so collect-barriers never hang.
    timer() {
        prune_timeouts();
        dispatch_one();
        update_timer();
    }

    // The ONE dataserver in the collar for avatar names. Phase 0 (display) →
    // queue the username leg at the FRONT (still paced), carrying the display
    // forward. Phase 1 (username) → compose + cache + reply. A stale/unknown
    // query id is ignored.
    dataserver(key query_id, string data) {
        integer idx = llListFindList(NQid, [query_id]);
        if (idx == -1) return;

        string  uuid_str = llList2String(NQUuid, idx);
        integer phase    = llList2Integer(NQPhase, idx);
        string  disp     = llList2String(NQDisp, idx);
        string  req      = llList2String(NQReq, idx);
        string  req_id   = llList2String(NQReqId, idx);
        drop_query(idx);

        if (phase == 0) {
            enqueue(uuid_str, 1, data, req, req_id, TRUE);
            return;
        }

        string label = compose_name(disp, data, uuid_str);
        cache_put(uuid_str, label);
        reply_one(req, req_id, uuid_str, label);
        update_timer();
    }
}

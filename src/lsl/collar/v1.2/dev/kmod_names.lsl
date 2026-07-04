/*--------------------
MODULE: kmod_names.lsl
VERSION: 1.2
REVISION: 1
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
              No cache in v1 — records persist the composed label (resolve once at
              add), pickers re-resolve per open (same cost as before the module).
CHANGES:
- v1.2 rev 1: initial. Two-phase resolve + compose; SETTINGS_BUS protocol.
--------------------*/


/* -------------------- ISP CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;   // name.resolve in / name.resolved out (shared roster/settings bus)

/* -------------------- STATE -------------------- */
// Pending query map — parallel lists. Two phases per uuid: phase 0 = display name,
// phase 1 = username (with the display carried forward). requester/req_id echo back
// to the caller so it can match the reply to its request.
list NQid    = [];   // dataserver query ids
list NQUuid  = [];   // parallel: the uuid
list NQPhase = [];   // parallel: 0 = display query, 1 = username query
list NQDisp  = [];   // parallel: display name carried into the username phase
list NQReq   = [];   // parallel: requester tag
list NQReqId = [];   // parallel: requester's request id

/* -------------------- HELPERS -------------------- */

string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
}

// Drop one query-map row.
drop_query(integer idx) {
    NQid    = llDeleteSubList(NQid, idx, idx);
    NQUuid  = llDeleteSubList(NQUuid, idx, idx);
    NQPhase = llDeleteSubList(NQPhase, idx, idx);
    NQDisp  = llDeleteSubList(NQDisp, idx, idx);
    NQReq   = llDeleteSubList(NQReq, idx, idx);
    NQReqId = llDeleteSubList(NQReqId, idx, idx);
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

// Begin resolving one uuid; an invalid uuid replies immediately (empty label).
resolve_start(string uuid_str, string req, string req_id) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) {
        reply_one(req, req_id, uuid_str, "");
        return;
    }
    NQid    += [llRequestDisplayName((key)uuid_str)];
    NQUuid  += [uuid_str];
    NQPhase += [0];
    NQDisp  += [""];
    NQReq   += [req];
    NQReqId += [req_id];
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

    // The ONE dataserver in the collar for avatar names. Phase 0 (display) → fire
    // the username query, carrying the display forward. Phase 1 (username) → compose
    // + reply. A stale/unknown query id is ignored.
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
            NQid    += [llRequestUsername((key)uuid_str)];
            NQUuid  += [uuid_str];
            NQPhase += [1];
            NQDisp  += [data];   // the display name
            NQReq   += [req];
            NQReqId += [req_id];
            return;
        }

        reply_one(req, req_id, uuid_str, compose_name(disp, data, uuid_str));
    }
}

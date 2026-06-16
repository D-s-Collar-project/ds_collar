/*--------------------
SCRIPT: leash_holder.lsl
VERSION: 1.2
REVISION: 0
PURPOSE: Minimal leash-holder target responder for external objects
ARCHITECTURE: Direct channel listener with prim discovery fallback. Bilingual on
              the unified leash/Lockmeister channel (-8888): answers DS-native
              JSON plugin.leash.request AND Lockmeister grab pings, so both DS
              and OpenCollar/Lockmeister collars can leash to this holder.
--------------------*/

/* -------------------- CONSTANTS -------------------- */
integer LEASH_HOLDER_CHAN = -8888;

/* -------------------- STATE -------------------- */
integer gListen = 0;

/* -------------------- HELPERS -------------------- */

key primByName(string wantLower) {
    integer n = llGetNumberOfPrims();
    integer i = 2;
    while (i <= n) {
        string nm = llToLower(llGetLinkName(i));
        if (nm == wantLower) return llGetLinkKey(i);
        i = i + 1;
    }
    return NULL_KEY;
}

key primByDesc(string wantLower) {
    integer n = llGetNumberOfPrims();
    integer i = 2;
    while (i <= n) {
        string d = llToLower(llList2String(llGetLinkPrimitiveParams(i, [PRIM_DESC]), 0));
        if (d == wantLower) return llGetLinkKey(i);
        i = i + 1;
    }
    return NULL_KEY;
}

// Choose a leash point prim:
// 1) child named "LeashPoint" (case-insensitive)
// 2) child with description "leash:point" (case-insensitive)
// 3) the prim this script is in (child or root)
key leashPrimKey() {
    key k = primByName("leashpoint");
    if (k != NULL_KEY) return k;

    k = primByDesc("leash:point");
    if (k != NULL_KEY) return k;

    integer ln = llGetLinkNumber();
    if (ln <= 0) ln = 1; // attachments can report 0; root is 1
    return llGetLinkKey(ln);
}

integer openListen() {
    if (gListen) llListenRemove(gListen);
    gListen = llListen(LEASH_HOLDER_CHAN, "", NULL_KEY, "");
    return TRUE;
}

default {
    state_entry() {
        openListen();
    }

    on_rez(integer p) {
        llResetScript();
    }

    changed(integer c) {
        if (c & (CHANGED_OWNER | CHANGED_REGION | CHANGED_REGION_START | CHANGED_TELEPORT)) {
            openListen();
        }
    }

    listen(integer ch, string name, key src, string msg) {
        if (ch != LEASH_HOLDER_CHAN) return;

        // ---------- Native JSON grammar (DS collars) ----------
        // {"type":"plugin.leash.request","wearer":"...","collar":"...","session":"..."}
        if (llGetSubString(msg, 0, 0) == "{") {
            if (llJsonGetValue(msg, ["type"]) != "plugin.leash.request") return;
            // Coffle requests want the peer collar's leashpoint, not a holder.
            if (llJsonGetValue(msg, ["mode"]) == "coffle") return;

            string collarStr = llJsonGetValue(msg, ["collar"]);
            string sessionStr = llJsonGetValue(msg, ["session"]);
            if (collarStr == JSON_INVALID || sessionStr == JSON_INVALID) return;
            key collar = (key)collarStr;
            integer session = (integer)sessionStr;

            key targetPrim = leashPrimKey();
            string reply = llList2Json(JSON_OBJECT, [
                "type", "plugin.leash.target",
                "ok", "1",
                "holder", (string)targetPrim,
                "root", (string)llGetLinkKey(1),
                "name", llGetObjectName(),
                "session", (string)session
            ]);
            llRegionSayTo(collar, LEASH_HOLDER_CHAN, reply);
            return;
        }

        // ---------- Lockmeister grammar (OpenCollar / LM collars) ----------
        // A leashing collar pings the controller (our wearer) with its own
        // wearer UUID:
        //   "<uuid>handle"  /  "<uuid>collar"
        //   "<uuid>|LMV2|RequestPoint|handle"  /  "...|collar"
        // We answer "<ourOwner>handle ok" / "<ourOwner>collar ok" — the
        // requester validates the first 36 chars against our owner and docks to
        // the responding prim. LM can't name a child prim, so the leash docks
        // at THIS script's prim; for a multi-prim holder put this script in the
        // leashpoint prim. " ok" / " free" / other suffixes are replies, not
        // requests — ignored.
        if (llStringLength(msg) < 36) return;
        key req = (key)llGetSubString(msg, 0, 35);
        if (req == NULL_KEY) return;
        string protocol = llGetSubString(msg, 36, -1);

        integer want_handle = (protocol == "handle" || protocol == "|LMV2|RequestPoint|handle");
        integer want_collar = (protocol == "collar" || protocol == "|LMV2|RequestPoint|collar");
        if (!want_handle && !want_collar) return;

        string me = (string)llGetOwner();
        if (want_handle) llRegionSayTo(req, LEASH_HOLDER_CHAN, me + "handle ok");
        if (want_collar) llRegionSayTo(req, LEASH_HOLDER_CHAN, me + "collar ok");
    }
}

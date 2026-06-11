/*--------------------
MODULE: kmod_leash_proto.lsl
VERSION: 1.10
REVISION: 7
PURPOSE: Holder-discovery handshake protocol for the leashing engine
ARCHITECTURE: True LSL state machine.
                default          — idle / coffle responder
                state proto_native — sent plugin.leash.request, awaiting reply
                state proto_oc_lm     — native timed out, sent LM ping, awaiting reply
              Each state's state_entry sets up phase-specific listeners
              and the timeout timer; LSL auto-clears these on transition,
              so no explicit teardown is needed. Engine-agnostic — knows
              nothing about LeashMode beyond what leash.proto.start carries
              (mode_str + validation_target + oc_ping_target). IPC reuses
              SETTINGS_BUS so no new bus number is consumed.
CHANGES:
- v1.1 rev 7: Strip the temporary DEBUG_LEASH scaffolding (constant +
  logd helper + every logd call site) added during the avatar-center
  fallback diagnosis. The two underlying bugs are fixed (rev 4
  validator now uses linkset root, rev 6 + engine rev 32 carry the
  claim-mode tag), so the diagnostic trail is no longer needed.
- v1.1 rev 6: Revert the rev 5 responder widening. The "A coffles B
  to A" path that motivated it is now handled at the source — the
  engine (kmod_leash_engine rev 32+) tags the user's original
  claim mode in persistent state (LeashClaimMode) and sendProtoStart
  emits that tag verbatim instead of deriving from
  Leasher == FollowTarget. So a coffle action stays mode=coffle on
  the wire even when the user picked themselves as the anchor, and
  THIS responder gets to answer (no race against a hand-held
  leash_holder). Strict mode separation restored:
    coffle  → collar LeashPoint (this responder)
    grab    → hand-held leash_holder.lsl
    post    → static-object linkset root
- v1.1 rev 5: Coffle responder now also answers grab requests (still
  skips post). Diagnosed second-order to rev 4 via the same DEBUG_LEASH
  trail: in the "A coffles B to A" RP path (A is ordered to chain B to
  themselves), claimLeash sets Leasher == FollowTarget == A.
  sendProtoStart's state-derived mode classifier sees that equality
  and emits mode=grab on the wire, even though A's collar LeashPoint
  is the appropriate anchor. The earlier coffle-only filter then kept
  A's collar silent; the handshake expired and particles fell back to
  OCPingTarget = A's avatar center. Negative-listing post (which
  resolves to a static linkset root) keeps the responder honest while
  unblocking this case. The other shape that fires mode=grab — A
  grabs B's leash with a hand-held leash_holder worn — still works
  because both responders answer; the validator pins whichever
  arrives first.
  (Superseded by rev 6's engine-side tag.)
- v1.1 rev 4: Fix validateAndExtractHolder rejecting valid avatar/coffle
  replies whose `holder` field is a CHILD prim of the responder's
  attachment. llGetObjectDetails(<child_prim_key>, [OBJECT_ATTACHED_POINT,
  ...]) returns 0 — only the linkset root reports the real attach point.
  Symptom: grabs/coffles where the leasher's LeashPoint lived as a
  child prim (named "leashpoint" or desc "leash:point") timed out the
  4-second handshake and fell back to OCPingTarget = leasher avatar,
  so particles aimed at avatar center instead of the LeashPoint.
  Validation now runs against the `root` field already included in
  every reply (legacy fallback to `candidate` when the field is
  absent). The candidate is still returned to the engine as the
  particle target so the leash docks visually at the LeashPoint prim.
  Diagnosed via in-world DEBUG_LEASH logs: `attach_pt=0 owner=<leasher
  uuid>` on the candidate, confirming the linkset (root) WAS attached
  and owned correctly but the child prim's OBJECT_ATTACHED_POINT was 0.
- v1.1 rev 3: Defensive validProtoStart(msg) gate before captureProtoStart in all three paths that consume leash.proto.start (default's link_message, proto_native's link_message restart, proto_oc_lm's link_message restart). Without it, a malformed leash.proto.start (missing field) would silently corrupt the handshake — llJsonGetValue returns the literal string "JSON_INVALID" for missing fields, (key)"JSON_INVALID" yields garbage, proto_native's request would carry that garbage controller / mode. Engine always sends all fields today, but defends against future protocol drift / typos.
- v1.1 rev 2: Convert HolderState integer-flag dispatch to actual LSL
  states. HOLDER_STATE_* constants and HolderState global gone — the
  current state IS the phase. Phase transitions are now `state X;`
  instead of mutating a flag. completeHandshake / leashProtoListenerTerminate
  / leashProtoHandover / leashingModeQuery / handleProtoStart /
  handleProtoShutdown / leashProtoNativeResponse / leashProtoOCCompat
  collapse into per-state state_entry + listen + timer handlers. Listeners
  are auto-torn-down on transition and re-opened in the next state's
  state_entry — no manual close. New helpers: captureProtoStart() and
  validateAndExtractHolder(). Plenty of headroom in proto for the
  ~2KB scaffolding cost (was 28.7%, becomes ~32-34%).
- v1.1 rev 1: Initial split from kmod_leash.lsl. Handshake state machine
  (then via integer flag), persistent native listener + responder, OC/LM
  fallback, all moved here. Engine-agnostic — receives controller /
  mode_str / validation_target / oc_ping_target via leash.proto.start
  and reports back via leash.proto.holder or leash.proto.fallback.
--------------------*/


/* -------------------- BUS CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS     = 800;

/* -------------------- PROTOCOL CONSTANTS -------------------- */
integer LEASH_CHAN_LM     = -8888;
integer LEASH_CHAN_NATIVE = -192837465;

float NATIVE_PHASE_DURATION = 2.0;
float OC_PHASE_DURATION     = 2.0;

/* -------------------- HANDSHAKE TRANSIENT STATE -------------------- */
// Listener handles. Re-opened in each state's state_entry; LSL clears
// them automatically on state change.
integer HolderListen   = 0;
integer HolderListenOC = 0;

// Per-handshake nonce, generated when proto_native enters.
integer HolderSession = 0;

// Per-handshake parameters captured from leash.proto.start. Survive
// across state transitions; reset when we return to default.
key    Controller       = NULL_KEY;
string ModeStr          = "";
key    ValidationTarget = NULL_KEY;
key    OCPingTarget     = NULL_KEY;

/* -------------------- GENERIC HELPERS -------------------- */
// Find this collar's LeashPoint prim (child named "leashpoint",
// case-insensitive). Falls back to root if no dedicated prim exists.
key findLeashpointPrim() {
    integer n = llGetNumberOfPrims();
    integer i = 2;
    while (i <= n) {
        string nm = llToLower(llStringTrim(llGetLinkName(i), STRING_TRIM));
        if (nm == "leashpoint") return llGetLinkKey(i);
        i = i + 1;
    }
    integer ln = llGetLinkNumber();
    if (ln <= 0) ln = 1;
    return llGetLinkKey(ln);
}

/* -------------------- ENGINE NOTIFICATION -------------------- */
notifyHolder(key holder) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type",   "leash.proto.holder",
        "holder", (string)holder
    ]), NULL_KEY);
}

notifyFallback(key target) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type",   "leash.proto.fallback",
        "target", (string)target
    ]), NULL_KEY);
}

/* -------------------- IPC PARAM CAPTURE -------------------- */
// Defensive guard against malformed leash.proto.start. Engine always
// sends all four fields, but a missing one would have llJsonGetValue
// return the literal string "JSON_INVALID" — silently corrupting the
// handshake (controller / mode field would carry garbage). Callers
// MUST validate before captureProtoStart + state change.
integer validProtoStart(string msg) {
    if (llJsonGetValue(msg, ["controller"])        == JSON_INVALID) return FALSE;
    if (llJsonGetValue(msg, ["mode"])              == JSON_INVALID) return FALSE;
    if (llJsonGetValue(msg, ["validation_target"]) == JSON_INVALID) return FALSE;
    if (llJsonGetValue(msg, ["oc_ping_target"])    == JSON_INVALID) return FALSE;
    return TRUE;
}

captureProtoStart(string msg) {
    Controller       = (key)llJsonGetValue(msg, ["controller"]);
    ModeStr          = llJsonGetValue(msg, ["mode"]);
    ValidationTarget = (key)llJsonGetValue(msg, ["validation_target"]);
    OCPingTarget     = (key)llJsonGetValue(msg, ["oc_ping_target"]);
}

// Per-handshake setup: fresh nonce, send the native request, arm the
// phase timer. Called from proto_native's state_entry AND inline from
// its link_message when leash.proto.start arrives mid-probe (where a
// `state proto_native;` would be a no-op per LSL semantics).
restartNativeProbe() {
    HolderSession = (integer)llFrand(9.0E06);

    string req = llList2Json(JSON_OBJECT, [
        "type",       "plugin.leash.request",
        "wearer",     (string)llGetOwner(),
        "collar",     (string)llGetKey(),
        "controller", (string)Controller,
        "session",    (string)HolderSession,
        "origin",     "leashpoint",
        "mode",       ModeStr
    ]);
    llRegionSay(LEASH_CHAN_NATIVE, req);

    llSetTimerEvent(NATIVE_PHASE_DURATION);
}

/* -------------------- NATIVE RESPONDER -------------------- */
// Replies to plugin.leash.request from OTHER collars (coffle role).
// Independent of our own handshake — we always answer.
leashProtoNativeRequest(string msg) {
    key requesting_collar = (key)llJsonGetValue(msg, ["collar"]);
    if (requesting_collar == NULL_KEY) return;
    if (requesting_collar == llGetKey()) return;       // ignore self-broadcast
    string session_str = llJsonGetValue(msg, ["session"]);
    if (session_str == JSON_INVALID) return;

    // Only answer coffle requests. Grab/post belong to the leasher's
    // hand-held holder; if we replied there we'd race against it.
    //
    // The "A coffles B to A" RP path is supported because the engine
    // tags the original claim mode (kmod_leash_engine rev 32+'s
    // LeashClaimMode) and sendProtoStart emits mode=coffle for that
    // case, so this responder fires correctly even when
    // Leasher == FollowTarget on the engine side.
    string requester_mode = llJsonGetValue(msg, ["mode"]);
    if (requester_mode != JSON_INVALID && requester_mode != "coffle") return;

    key target_prim = findLeashpointPrim();
    string reply = llList2Json(JSON_OBJECT, [
        "type",    "plugin.leash.target",
        "ok",      "1",
        "holder",  (string)target_prim,
        "root",    (string)llGetLinkKey(1),
        "name",    llGetObjectName(),
        "session", session_str
    ]);
    llRegionSayTo(requesting_collar, LEASH_CHAN_NATIVE, reply);
}

/* -------------------- HANDSHAKE-REPLY VALIDATION -------------------- */
// Returns the candidate holder key on a valid plugin.leash.target reply,
// or NULL_KEY if anything fails. Validates session nonce, mode-specific
// post-root or attachment-owner constraint.
key validateAndExtractHolder(string msg) {
    if (llJsonGetValue(msg, ["type"]) != "plugin.leash.target") return NULL_KEY;
    if (llJsonGetValue(msg, ["ok"])   != "1")                   return NULL_KEY;
    integer session = (integer)llJsonGetValue(msg, ["session"]);
    if (session != HolderSession) return NULL_KEY;

    key candidate = (key)llJsonGetValue(msg, ["holder"]);
    if (candidate == NULL_KEY) return NULL_KEY;

    if (ModeStr == "post") {
        // Post mode: responder's linkset root must equal the post UUID
        // the user clicked (ValidationTarget = LeashTarget engine-side).
        string root_str = llJsonGetValue(msg, ["root"]);
        if (root_str == JSON_INVALID) return NULL_KEY;
        if ((key)root_str != ValidationTarget) return NULL_KEY;
    }
    else {
        // Avatar/coffle: responder must be an attachment owned by the
        // expected wearer (ValidationTarget = Leasher in avatar mode,
        // CoffleTargetAvatar in coffle mode — engine-side leashFollowTarget).
        //
        // Validation runs against the responder's LINKSET ROOT, not
        // against the candidate prim. The candidate is whatever
        // findLeashpointPrim/leashPrimKey returned, which is typically
        // a child prim named "leashpoint" — and llGetObjectDetails on a
        // child prim key returns OBJECT_ATTACHED_POINT = 0 (only the
        // linkset root reports a real attach point). The reply always
        // includes a "root" field; we use it here. The candidate is
        // still returned to the engine as the particle target so the
        // leash docks visually at the LeashPoint prim.
        string root_str = llJsonGetValue(msg, ["root"]);
        key validate_key = candidate;
        if (root_str != JSON_INVALID && (key)root_str != NULL_KEY) {
            validate_key = (key)root_str;
        }
        list odetails = llGetObjectDetails(validate_key, [OBJECT_ATTACHED_POINT, OBJECT_OWNER]);
        if (llGetListLength(odetails) < 2) return NULL_KEY;
        if (llList2Integer(odetails, 0) == 0) return NULL_KEY;
        if (llList2Key(odetails, 1) != ValidationTarget) return NULL_KEY;
    }
    return candidate;
}


/* ============================================================
   STATE: default — idle / coffle responder
   ============================================================ */
default
{
    state_entry() {
        if (llGetObjectDesc() == "COLLAR_UPDATER") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        // Reset handshake params.
        Controller       = NULL_KEY;
        ModeStr          = "";
        ValidationTarget = NULL_KEY;
        OCPingTarget     = NULL_KEY;
        HolderSession    = 0;

        // Open the persistent native listener for the responder role —
        // we answer incoming plugin.leash.request from other collars
        // (coffle) regardless of our own handshake state.
        HolderListen = llListen(LEASH_CHAN_NATIVE, "", NULL_KEY, "");

        llSetTimerEvent(0.0);
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
            return;
        }
        if (num == SETTINGS_BUS) {
            if (msg_type == "leash.proto.start") {
                if (!validProtoStart(msg)) return;
                captureProtoStart(msg);
                state proto_native;
            }
            // leash.proto.shutdown is a no-op here — we're already idle.
            return;
        }
    }

    listen(integer channel, string name, key id, string msg) {
        if (channel == LEASH_CHAN_NATIVE) {
            // Only the responder role applies in idle. Late
            // plugin.leash.target replies from a previous handshake (or
            // stray) are ignored — we're not awaiting one.
            string mtype = llJsonGetValue(msg, ["type"]);
            if (mtype == "plugin.leash.request") {
                leashProtoNativeRequest(msg);
            }
        }
    }
}


/* ============================================================
   STATE: proto_native — sent plugin.leash.request, awaiting reply
   ============================================================ */
state proto_native
{
    state_entry() {
        // Re-open native listener (LSL auto-cleared it on transition).
        HolderListen = llListen(LEASH_CHAN_NATIVE, "", NULL_KEY, "");
        restartNativeProbe();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    timer() {
        // Native phase timed out — try OC fallback.
        state proto_oc_lm;
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
            return;
        }
        if (num == SETTINGS_BUS) {
            if (msg_type == "leash.proto.shutdown") {
                state default;
            }
            else if (msg_type == "leash.proto.start") {
                // Engine asked us to restart while we're already in
                // proto_native. `state proto_native;` here would be
                // a no-op (LSL treats same-state changes as return), so
                // do the per-handshake setup inline — the listener stays
                // open across the reset.
                if (!validProtoStart(msg)) return;
                captureProtoStart(msg);
                restartNativeProbe();
            }
            return;
        }
    }

    listen(integer channel, string name, key id, string msg) {
        if (channel == LEASH_CHAN_NATIVE) {
            string mtype = llJsonGetValue(msg, ["type"]);
            if (mtype == "plugin.leash.request") {
                leashProtoNativeRequest(msg);
            }
            else if (mtype == "plugin.leash.target") {
                key holder = validateAndExtractHolder(msg);
                if (holder != NULL_KEY) {
                    notifyHolder(holder);
                    state default;
                }
            }
        }
    }
}


/* ============================================================
   STATE: proto_oc_lm — native timed out, sent LM ping, awaiting reply
   ============================================================ */
state proto_oc_lm
{
    state_entry() {
        // Re-open both listeners (LSL auto-cleared on transition).
        HolderListen   = llListen(LEASH_CHAN_NATIVE, "", NULL_KEY, "");
        HolderListenOC = llListen(LEASH_CHAN_LM,     "", NULL_KEY, "");

        // Send LM ping (`<target>collar` and `<target>handle`) per
        // legacy spec. OCPingTarget is the leasher avatar in grab,
        // the target collar in coffle, the post root in post.
        if (OCPingTarget != NULL_KEY) {
            llRegionSayTo(OCPingTarget, LEASH_CHAN_LM, (string)OCPingTarget + "collar");
            llRegionSayTo(OCPingTarget, LEASH_CHAN_LM, (string)OCPingTarget + "handle");
        }

        llSetTimerEvent(OC_PHASE_DURATION);
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    timer() {
        // Both phases timed out — tell engine to use the raw mode
        // anchor as a particle-aim fallback.
        if (OCPingTarget != NULL_KEY) notifyFallback(OCPingTarget);
        state default;
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
            return;
        }
        if (num == SETTINGS_BUS) {
            if (msg_type == "leash.proto.shutdown") {
                state default;
            }
            else if (msg_type == "leash.proto.start") {
                // Engine restart — go back to native phase fresh.
                if (!validProtoStart(msg)) return;
                captureProtoStart(msg);
                state proto_native;
            }
            return;
        }
    }

    listen(integer channel, string name, key id, string msg) {
        if (channel == LEASH_CHAN_NATIVE) {
            string mtype = llJsonGetValue(msg, ["type"]);
            if (mtype == "plugin.leash.request") {
                leashProtoNativeRequest(msg);
            }
            else if (mtype == "plugin.leash.target") {
                // Late native reply still wins over OC.
                key holder = validateAndExtractHolder(msg);
                if (holder != NULL_KEY) {
                    notifyHolder(holder);
                    state default;
                }
            }
        }
        else if (channel == LEASH_CHAN_LM) {
            // OC/LM legacy reply: `<UUID>handle ok` where UUID is the
            // OCPingTarget we addressed (functions as the nonce —
            // only an addressed responder can know it ahead of time).
            string expected = (string)OCPingTarget + "handle ok";
            if (msg == expected) {
                notifyHolder(id);
                state default;
            }
        }
    }
}

/*--------------------
MODULE: kmod_leash_engine.lsl   (v1.2 redesign)
VERSION: 1.2
REVISION: 2
PURPOSE: Self-contained leashing engine. Absorbs the former
         kmod_leash_proto holder-discovery handshake: there is no proto
         sibling and no engine<->proto IPC.
CHANGES:
- v1.2 rev 2: findLeashpointPrim matches "leashpoint" as a SUBSTRING of the prim description (was exact ==), so an OpenCollar leashpoint (desc has config after the word) is recognized. Mirrors kmod_particles' find_leashpoint_link.
- v1.2 rev 1: Deferred-restraint clip. A fresh gated grab/coffle now enters leashed to reuse its probe/listener/timer but HOLDS @follow + the leashed-broadcast (so plugin_leash's enhanced-TP stays off) + the success notice until a holder confirms (native plugin.leash.target OR Lockmeister particles.lm.grabbed → commitPendingLeash). No holder within PENDING_WINDOW (2s) → denyPendingLeash: "Unable to leash: No holder found to clip leash to." / "...coffle...No collar...", with nothing restrained. Post / reclip / cold-restart / take-over pass gate_on_holder=FALSE (or hit the was_leashed guard) and activate immediately as before. Added: PendingHolder / PendingNotice / PendingDeadline + claimLeash gate_on_holder param. Leashpoint prim matched by DESCRIPTION "leashpoint" (consistent with kmod_particles' find_leashpoint_link).
ARCHITECTURE: Two LSL states.
                default  — unleashed/idle. Coffle responder + LM grab-inflow
                           (via kmod_particles) + claim initiation + auto-reclip.
                leashed  — active (avatar OR object, distinguished by
                           FollowIsAvatar). Follow tick, presence/offsim,
                           native holder discovery, controls, yank.
              ONE listener on LEASH_CHAN (-8888), JSON grammar only — native
              holder discovery + coffle. The Lockmeister grammar on the same
              channel is owned by kmod_particles (grab/release/render); this
              engine ignores non-JSON traffic, so the two coexist. Particles
              stays a separate module.
              Transitions: helpers set the global StateChange flag; each event
              handler performs the actual `state` switch at its end (never from
              inside a deep function). Activation (follow/probe/LM) is
              cause-dependent and routed through activateLeashFromState() via
              the LeashCause discriminator.
--------------------*/


/* ------------------------------------------------------------
   SECTION 1 — SHARED INFRASTRUCTURE
   ------------------------------------------------------------ */

/* -------------------- BUS CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;

/* -------------------- DISCOVERY CHANNEL -------------------- */
// Unified with the Lockmeister channel. We transmit/receive only JSON here;
// kmod_particles owns the plain-string Lockmeister grammar on the same channel.
integer LEASH_CHAN = -8888;
float   PROBE_WINDOW = 3.0;   // seconds to wait for a native holder reply
float   PENDING_WINDOW = 2.0; // seconds a fresh grab/coffle waits for ANY holder
                              // (native OR Lockmeister) before it is denied. A
                              // present holder confirms well under 1s; this only
                              // bounds how long a FAILED clip waits to be denied.

/* -------------------- PROTOCOL CONSTANTS -------------------- */

string PLUGIN_CONTEXT = "ui.core.leash";

// Claim kinds — parameters to claimLeash() only. NOT stored as state.
integer MODE_AVATAR = 0;  // Clip: grab leash, wearer follows the clicker
integer MODE_COFFLE = 1;  // Coffle: wearer follows a different avatar
integer MODE_POST = 2;    // Post: wearer follows a static object

// Settings keys
string KEY_LEASHED = "leash.leashedavatar";
string KEY_LEASHER = "leash.leasherkey";
string KEY_LEASH_LENGTH = "leash.length";
string KEY_LEASH_TURNTO = "leash.turnto";
string KEY_LEASH_TEXTURE = "leash.texture";

// State-transition intent (set by helpers, applied by event handlers).
integer TR_NONE = 0;
integer TR_LEASH = 1;
integer TR_UNLEASH = 2;
integer StateChange = 0;

// Deferred broadcast: helpers deep in a call chain set this instead of calling
// broadcastState() directly; the event handler flushes it at top level so the
// 16-field JSON list allocates with the stack unwound (lower peak — avoids the
// stack-heap collision that building it at depth ~6 in the claim path caused).
integer NeedBroadcast = FALSE;

// Activation cause — selects what activateLeashFromState() does on entry.
integer CAUSE_NATIVE = 0;  // claim/pass/cold-restart: follow + native probe + (LM for grab)
integer CAUSE_LM = 1;      // Lockmeister grab-inflow: follow only (particles already rendering LM)
integer LeashCause = 0;

/* -------------------- STATE -------------------- */

// Leash state
integer Leashed = FALSE;
key Leasher = NULL_KEY;
integer LeashLength = 3;
integer TurnToFace = FALSE;
string LeashTexture = "chain";    // Particle style — "chain" / "silk" / "invisible"
key FollowTarget = NULL_KEY;       // Who/what the wearer follows physically
integer FollowIsAvatar = TRUE;     // TRUE → avatar (RLV @follow + attach validation); FALSE → object (root validation)
integer LeashClaimMode = 0;        // user's original action; drives wire mode_str (0 = MODE_AVATAR)

// Follow mechanics
integer FollowActive = FALSE;
vector LastTargetPos = ZERO_VECTOR;
integer ControlsOk = FALSE;
integer AtLimit = FALSE;          // distance >= LeashLength
integer ControlsExpanded = FALSE; // TRUE when directional keys are in our llTakeControls mask
integer TickCount = 0;

// Turn-to-face throttling
float LastTurnAngle = -999.0;
float TURN_THRESHOLD = 0.1;  // ~5.7 degrees

// Holder discovery (absorbed proto). HolderTarget is the discovered LeashPoint
// prim; the probe is in flight while AwaitingHolder until ProbeDeadline.
key HolderTarget = NULL_KEY;
integer AwaitingHolder = FALSE;
integer HolderSession = 0;
integer ProbeDeadline = 0;

// Offsim detection & auto-reclip
integer OffsimDetected = FALSE;
integer OffsimStartTime = 0;
float OFFSIM_GRACE = 6.0;
integer ReclipScheduled = 0;
key LastLeasher = NULL_KEY;
integer ReclipAttempts = 0;
integer MAX_RECLIP_ATTEMPTS = 3;
integer RECLIP_SAFETY_WINDOW = 120;
integer ReclipDeadline = 0;

// Lockmeister authorization
key AuthorizedLmController = NULL_KEY;

// Deferred-restraint gate for a fresh grab/coffle: the leash enters the leashed
// state to reuse its probe/listener/timer, but @follow + the leashed-broadcast
// (and thus plugin_leash's enhanced-TP) + the success notice are HELD until a
// holder actually answers. No holder by PendingDeadline → deny, nothing to
// unwind. Reclip / post / cold-restart / take-over pass gate_on_holder=FALSE
// and activate immediately as before.
integer PendingHolder   = FALSE;
string  PendingNotice   = "";
integer PendingDeadline = 0;

// Yank rate limiting
integer LastYankTime = 0;
float YANK_COOLDOWN = 5.0;

// Yank arrival detection: llTarget handle so at_target can release the
// physics hold the moment the wearer reaches the leasher.
integer YankTargetHandle = 0;

// Timers
float FOLLOW_TICK = 1.0;

/* -------------------- GENERIC HELPERS -------------------- */

string jsonGet(string j, string k, string default_val) {
    string v = llJsonGetValue(j, [k]);
    if (v == JSON_INVALID) return default_val;
    return v;
}
// Clamp leash length to valid range
integer clampLeashLength(integer len) {
    if (len < 1) return 1;
    if (len > 20) return 20;
    return len;
}

/* -------------------- LOCKMEISTER PROTOCOL -------------------- */
setLockmeisterState(integer enabled, key controller) {
    string msg;
    if (enabled) {
        msg = llList2Json(JSON_OBJECT, [
            "type", "particles.lm.enable",
            "controller", (string)controller
        ]);
    } else {
        msg = llList2Json(JSON_OBJECT, [
            "type", "particles.lm.disable"
        ]);
    }
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- PARTICLES PROTOCOL -------------------- */
setParticlesState(integer active, key target) {
    string msg;
    if (active) {
        msg = llList2Json(JSON_OBJECT, [
            "type", "particles.start",
            "source", PLUGIN_CONTEXT,
            "target", (string)target,
            "style", LeashTexture
        ]);
    } else {
        msg = llList2Json(JSON_OBJECT, [
            "type", "particles.stop",
            "source", PLUGIN_CONTEXT
        ]);
    }
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

updateParticlesTarget(key target) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "particles.update",
        "target", (string)target
    ]), NULL_KEY);
}

/* -------------------- OFFER PROTOCOL -------------------- */
sendOfferPending(key target, key originator) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.offer.pending",
        "target", (string)target,
        "originator", (string)originator
    ]), NULL_KEY);
}

/* -------------------- SETTINGS PERSISTENCE -------------------- */
persistSetting(string setting_key, string value) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", setting_key,
        "value", value
    ]), NULL_KEY);
}

persistLeashState(integer leashed, key leasher) {
    persistSetting(KEY_LEASHED, (string)leashed);
    persistSetting(KEY_LEASHER, (string)leasher);
}

applySettingsSync() {
    string tmp = llLinksetDataRead(KEY_LEASHED);
    if (tmp != "") Leashed = (integer)tmp;
    tmp = llLinksetDataRead(KEY_LEASHER);
    if (tmp != "") Leasher = (key)tmp;
    tmp = llLinksetDataRead(KEY_LEASH_LENGTH);
    if (tmp != "") LeashLength = clampLeashLength((integer)tmp);
    tmp = llLinksetDataRead(KEY_LEASH_TURNTO);
    if (tmp != "") TurnToFace = (integer)tmp;
    tmp = llLinksetDataRead(KEY_LEASH_TEXTURE);
    if (tmp == "chain" || tmp == "silk" || tmp == "invisible") LeashTexture = tmp;

    // Cold-restart fallback only: if we wake Leashed with no in-memory follow
    // target, default to avatar mode with Leasher as the target (the 10s retry
    // re-handshakes for the real leashpoint). FollowTarget != NULL_KEY makes
    // this cold-restart-only so a mid-session settings.sync (our own
    // persistLeashState echo) never clobbers an active post/coffle session.
    if (Leashed && Leasher != NULL_KEY && FollowTarget == NULL_KEY) {
        FollowTarget = Leasher;
        FollowIsAvatar = TRUE;
    }
}

/* -------------------- STATE MANAGEMENT -------------------- */

// Set common leash state and request a transition into the leashed state.
// Activation (follow/probe/LM) is NOT done here — it happens on entry via
// activateLeashFromState(), keyed on LeashCause (set by the caller).
setLeashState(key user, key follow_target, integer follow_is_avatar, integer claim_mode) {
    Leashed = TRUE;
    Leasher = user;
    LastLeasher = user;
    FollowTarget = follow_target;
    FollowIsAvatar = follow_is_avatar;
    LeashClaimMode = claim_mode;
    persistLeashState(TRUE, user);
    NeedBroadcast = TRUE;
    StateChange = TR_LEASH;
}

// Clear leash state and request a transition to unleashed. Physical teardown
// (follow/particles/LM/controls) is done by leashed's state_exit so it runs
// exactly once on the transition.
clearLeashState(integer clear_reclip) {
    Leashed = FALSE;
    Leasher = NULL_KEY;
    FollowTarget = NULL_KEY;
    FollowIsAvatar = TRUE;
    LeashClaimMode = 0;
    HolderTarget = NULL_KEY;
    AwaitingHolder = FALSE;
    AuthorizedLmController = NULL_KEY;
    PendingHolder = FALSE;
    PendingNotice = "";
    persistLeashState(FALSE, NULL_KEY);

    if (clear_reclip) clearReclipState();

    NeedBroadcast = TRUE;
    StateChange = TR_UNLEASH;
}

// Read-and-clear the pending transition. Routing the read through a function
// keeps lslint from constant-folding the global across the routing call (the
// deep helpers set StateChange; the handler can't see that statically).
integer takeStateChange() {
    integer tr = StateChange;
    StateChange = TR_NONE;
    return tr;
}

/* -------------------- NOTIFICATIONS -------------------- */
notifyLeashTransfer(key from_user, key to_user, string action) {
    llRegionSayTo(from_user, 0, "Leash " + action + " to " + llKey2Name(to_user));
    llRegionSayTo(to_user, 0, "Leash received from " + llKey2Name(from_user));
    llRegionSayTo(llGetOwner(), 0, "Leash " + action + " to " + llKey2Name(to_user) + " by " + llKey2Name(from_user));
}

/* -------------------- HOLDER DISCOVERY (absorbed proto) -------------------- */

// Find this collar's LeashPoint prim (child named "leashpoint",
// case-insensitive). Falls back to root if no dedicated prim exists.
key findLeashpointPrim() {
    integer n = llGetNumberOfPrims();
    integer i = 2;
    while (i <= n) {
        // Leashpoint prim = "leashpoint" appearing ANYWHERE in its DESCRIPTION
        // (substring, not exact — OpenCollar's desc has config after the word).
        // Must match kmod_particles' find_leashpoint_link so both pick the same
        // prim (beam emits from / docks at it).
        list p = llGetLinkPrimitiveParams(i, [PRIM_DESC]);
        string desc = llToLower(llList2String(p, 0));
        if (llSubStringIndex(desc, "leashpoint") != -1) return llGetLinkKey(i);
        i = i + 1;
    }
    integer ln = llGetLinkNumber();
    if (ln <= 0) ln = 1;
    return llGetLinkKey(ln);
}

// Coffle responder role: answer plugin.leash.request from OTHER collars when
// the requester is coffling. Independent of our own leash status — we may be a
// coffle anchor whether leashed or not.
coffleResponder(string msg) {
    key requesting_collar = (key)jsonGet(msg, "collar", (string)NULL_KEY);
    if (requesting_collar == NULL_KEY) return;
    if (requesting_collar == llGetKey()) return;        // ignore self
    string session_str = jsonGet(msg, "session", "");
    if (session_str == "") return;
    // Only answer coffle. Grab/post belong to the leasher's hand-held holder;
    // answering there would race against it.
    if (jsonGet(msg, "mode", "") != "coffle") return;

    key target_prim = findLeashpointPrim();
    string reply = llList2Json(JSON_OBJECT, [
        "type",    "plugin.leash.target",
        "ok",      "1",
        "holder",  (string)target_prim,
        "root",    (string)llGetLinkKey(1),
        "name",    llGetObjectName(),
        "session", session_str
    ]);
    llRegionSayTo(requesting_collar, LEASH_CHAN, reply);
}

// Validate a plugin.leash.target reply against our pending probe. Returns the
// candidate holder prim, or NULL_KEY on any failure. Post mode validates the
// responder's linkset root == FollowTarget; avatar/coffle validate that the
// responder is an attachment owned by FollowTarget.
key validateAndExtractHolder(string msg) {
    if (jsonGet(msg, "type", "") != "plugin.leash.target") return NULL_KEY;
    if (jsonGet(msg, "ok", "") != "1") return NULL_KEY;
    integer session = (integer)jsonGet(msg, "session", "0");
    if (session != HolderSession) return NULL_KEY;

    key candidate = (key)jsonGet(msg, "holder", (string)NULL_KEY);
    if (candidate == NULL_KEY) return NULL_KEY;

    if (!FollowIsAvatar) {
        string root_str = jsonGet(msg, "root", "");
        if (root_str == "") return NULL_KEY;
        if ((key)root_str != FollowTarget) return NULL_KEY;
    }
    else {
        // Validate against the responder's linkset root (child prims report
        // OBJECT_ATTACHED_POINT = 0). The candidate prim is still returned so
        // the leash docks visually at the LeashPoint child.
        string root_str = jsonGet(msg, "root", "");
        key validate_key = candidate;
        if (root_str != "" && (key)root_str != NULL_KEY) validate_key = (key)root_str;
        list odetails = llGetObjectDetails(validate_key, [OBJECT_ATTACHED_POINT, OBJECT_OWNER]);
        if (llGetListLength(odetails) < 2) return NULL_KEY;
        if (llList2Integer(odetails, 0) == 0) return NULL_KEY;
        if (llList2Key(odetails, 1) != FollowTarget) return NULL_KEY;
    }
    return candidate;
}

// Fire a fresh native discovery probe at FollowTarget. Targeted (llRegionSayTo)
// so it reaches that avatar's attachments (the hand-held holder for grab, the
// peer collar for coffle) or the post object — no region-wide broadcast.
startProbe() {
    if (FollowTarget == NULL_KEY) return;
    HolderSession = (integer)llFrand(9.0e6);

    string mode_str = "grab";
    if      (LeashClaimMode == MODE_POST)   mode_str = "post";
    else if (LeashClaimMode == MODE_COFFLE) mode_str = "coffle";

    string req = llList2Json(JSON_OBJECT, [
        "type",       "plugin.leash.request",
        "wearer",     (string)llGetOwner(),
        "collar",     (string)llGetKey(),
        "controller", (string)Leasher,
        "session",    (string)HolderSession,
        "origin",     "leashpoint",
        "mode",       mode_str
    ]);
    llRegionSayTo(FollowTarget, LEASH_CHAN, req);
    AwaitingHolder = TRUE;
    ProbeDeadline = llGetUnixTime() + (integer)PROBE_WINDOW;
}

// JSON-only inbound dispatch for LEASH_CHAN. Plain Lockmeister strings on the
// same channel are owned by kmod_particles and ignored here. Identical in both
// states (acceptNativeReply self-gates on AwaitingHolder).
handleLeashListen(string msg) {
    if (llGetSubString(msg, 0, 0) != "{") return;
    string t = jsonGet(msg, "type", "");
    if (t == "plugin.leash.request") {
        coffleResponder(msg);
    }
    else if (t == "plugin.leash.target") {
        if (!AwaitingHolder) return;
        key holder = validateAndExtractHolder(msg);
        if (holder == NULL_KEY) return;
        HolderTarget = holder;
        AwaitingHolder = FALSE;
        setParticlesState(TRUE, HolderTarget);
        if (PendingHolder) commitPendingLeash();   // a pending coffle/grab's collar answered
    }
}

/* -------------------- OFFSIM DETECTION & AUTO-RECLIP -------------------- */
clearReclipState() {
    ReclipScheduled = 0;
    LastLeasher = NULL_KEY;
    ReclipAttempts = 0;
    ReclipDeadline = 0;
}

autoReleaseOffsim() {
    clearLeashState(FALSE);  // FALSE = keep reclip state (we want to try reclipping)
    llRegionSayTo(llGetOwner(), 0, "Auto-released (offsim)");
}

checkLeasherPresence() {
    if (!Leashed || Leasher == NULL_KEY) return;

    integer now_time = llGetUnixTime();

    integer avatar_present = (llGetAgentInfo(Leasher) != 0);
    integer holder_present = FALSE;
    if (HolderTarget != NULL_KEY) {
        holder_present = (llGetListLength(llGetObjectDetails(HolderTarget, [OBJECT_POS])) > 0);
    }
    integer present = avatar_present || holder_present;

    // Holder-only mode notice (avatar offline, holder remains)
    if (!avatar_present && holder_present && !OffsimDetected) {
        llRegionSayTo(llGetOwner(), 0, "Leasher offline, leash held by object");
    }

    if (!present) {
        if (!OffsimDetected) {
            OffsimDetected = TRUE;
            OffsimStartTime = now_time;
        }
        else if ((float)(now_time - OffsimStartTime) >= OFFSIM_GRACE) {
            LastLeasher = Leasher;
            autoReleaseOffsim();
            ReclipScheduled = now_time + 2;
            ReclipAttempts = 0;
            ReclipDeadline = now_time + RECLIP_SAFETY_WINDOW;
        }
    }
    else if (OffsimDetected) {
        OffsimDetected = FALSE;
        OffsimStartTime = 0;
    }
}

checkAutoReclip() {
    if (ReclipScheduled == 0 || llGetUnixTime() < ReclipScheduled) return;

    // Safety window: stop waiting if the leasher hasn't returned in time.
    if (ReclipDeadline != 0 && llGetUnixTime() >= ReclipDeadline) {
        clearReclipState();
        return;
    }
    if (ReclipAttempts >= MAX_RECLIP_ATTEMPTS) {
        clearReclipState();
        return;
    }
    if (LastLeasher != NULL_KEY && llGetAgentInfo(LastLeasher) != 0) {
        // Re-clip the previously-authorized leasher directly — no ACL re-check.
        // They were authorized when first leashed; we're unleashed now, so this
        // is a fresh claim (acl arg unused on the not-leashed path).
        claimLeash(LastLeasher, MODE_AVATAR, NULL_KEY, 1, FALSE);
        ReclipAttempts = ReclipAttempts + 1;
        ReclipScheduled = llGetUnixTime() + 2;
    }
}

/* -------------------- FOLLOW MECHANICS -------------------- */

// Directional keys are added to the mask only when leashed AND (at the leash
// limit OR a yank is in flight). ML_LBUTTON stays for the no-script-parcel
// sticky exemption.
updateControlsMask() {
    if (!ControlsOk) return;
    integer should_expand = Leashed && (AtLimit || YankTargetHandle != 0);
    if (should_expand == ControlsExpanded) return;
    ControlsExpanded = should_expand;
    integer mask = CONTROL_ML_LBUTTON;
    if (should_expand) {
        mask = mask | CONTROL_FWD | CONTROL_BACK
                    | CONTROL_LEFT | CONTROL_RIGHT
                    | CONTROL_ROT_LEFT | CONTROL_ROT_RIGHT;
    }
    llTakeControls(mask, FALSE, TRUE);
}

startFollow() {
    if (!Leashed) return;
    FollowActive = TRUE;
    // RLV @follow target: FollowTarget when avatar; post mode skips (static
    // prims can't be RLV-followed).
    if (FollowIsAvatar && FollowTarget != NULL_KEY) {
        llOwnerSay("@follow:" + (string)FollowTarget + "=force");
    }
    llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);
}

stopFollow() {
    FollowActive = FALSE;
    llOwnerSay("@follow=clear");
    llStopMoveToTarget();
    if (YankTargetHandle != 0) {
        llTargetRemove(YankTargetHandle);
        YankTargetHandle = 0;
    }
    LastTargetPos = ZERO_VECTOR;
    LastTurnAngle = -999.0;
}

turnToTarget(vector target_pos) {
    if (!TurnToFace || !Leashed) return;
    vector wearer_pos = llGetRootPosition();
    vector direction = llVecNorm(target_pos - wearer_pos);
    float angle = llAtan2(direction.y, direction.x);
    if (llFabs(angle - LastTurnAngle) > TURN_THRESHOLD) {
        llOwnerSay("@setrot:" + (string)angle + "=force");
        LastTurnAngle = angle;
    }
}

followTick() {
    if (!FollowActive || !Leashed) return;

    key follow_target = FollowTarget;
    if (follow_target == NULL_KEY) return;

    // Prefer the discovered LeashPoint prim over the raw mode target.
    key target_key = follow_target;
    if (HolderTarget != NULL_KEY) target_key = HolderTarget;

    list details = llGetObjectDetails(target_key, [OBJECT_POS]);

    // HolderTarget vanished (detached/derezzed): drop it and retry with the
    // raw mode anchor.
    if (llGetListLength(details) == 0 && target_key == HolderTarget) {
        HolderTarget = NULL_KEY;
        updateParticlesTarget(follow_target);
        target_key = follow_target;
        details = llGetObjectDetails(target_key, [OBJECT_POS]);
    }

    if (llGetListLength(details) == 0) return;
    vector target_pos = llList2Vector(details, 0);

    vector wearer_pos = llGetRootPosition();
    float distance = llVecDist(wearer_pos, target_pos);

    integer new_at_limit = (distance >= (float)LeashLength);
    if (new_at_limit != AtLimit) {
        AtLimit = new_at_limit;
        updateControlsMask();
    }

    if (ControlsOk && distance > (float)LeashLength) {
        // Pull to 0.85 * length so there is slack on arrival; gentle tau (1.0)
        // keeps walking in the leashed direction feasible.
        vector pull_pos = target_pos + llVecNorm(wearer_pos - target_pos) * (float)LeashLength * 0.85;
        if (llVecMag(pull_pos - LastTargetPos) > 0.2) {
            llMoveToTarget(pull_pos, 1.0);
            LastTargetPos = pull_pos;
        }
        if (TurnToFace && follow_target != NULL_KEY) {
            turnToTarget(target_pos);
        }
    }
    else {
        // In range: release the move target (unless a yank is still in flight).
        if (LastTargetPos != ZERO_VECTOR && YankTargetHandle == 0) {
            llStopMoveToTarget();
            LastTargetPos = ZERO_VECTOR;
        }
    }
}

// Activate a leash session on entry to (or refresh within) the leashed state.
// CAUSE_NATIVE: follow + native holder probe + (LM enable for a regular grab).
// CAUSE_LM:     follow only — particles is already rendering the Lockmeister
//               leash from its own grab detection, so no probe / LM re-enable.
activateLeashFromState() {
    // A pending (deferred) grab/coffle holds the restraint: run the probe/LM
    // handshake to find a holder, but don't start following until one answers.
    if (!PendingHolder) startFollow();
    if (LeashCause == CAUSE_NATIVE) {
        // LM (grab to the leasher's hand-held holder) is avatar-grab only; coffle
        // is DS-to-DS via the native probe, post is an object via native render.
        if (FollowTarget == Leasher && FollowIsAvatar) {
            AuthorizedLmController = Leasher;
            setLockmeisterState(TRUE, Leasher);
        }
        startProbe();
    }
    LeashCause = CAUSE_NATIVE;  // reset to default for next entry
}

// A holder answered a pending grab/coffle (native plugin.leash.target or
// Lockmeister particles.lm.grabbed). Commit the deferred restraint now: start
// following, release the held broadcast (NeedBroadcast was suppressed at claim),
// and show the success notice. Idempotent — a second confirm is a no-op.
commitPendingLeash() {
    if (!PendingHolder) return;
    PendingHolder = FALSE;
    startFollow();
    NeedBroadcast = TRUE;
    if (PendingNotice != "") {
        llRegionSayTo(Leasher, 0, PendingNotice);
        PendingNotice = "";
    }
}

// No holder answered within PENDING_WINDOW. Nothing was restrained, so this is a
// clean drop — the unleash transition tears down the probe/LM and broadcasts the
// (never-shown) unleashed state. Message is parametrized: leash/holder vs
// coffle/collar. Read mode + recipient BEFORE clearLeashState wipes them.
denyPendingLeash() {
    string verb = "leash";
    string anchor = "holder";
    if (LeashClaimMode == MODE_COFFLE) { verb = "coffle"; anchor = "collar"; }
    key who = Leasher;
    clearLeashState(TRUE);
    llRegionSayTo(who, 0, "Unable to " + verb + ": No " + anchor + " found to clip leash to.");
}

/* -------------------- STATE BROADCAST -------------------- */
broadcastState() {
    // Legacy integer "mode" + "target" semantics for plugin_leash's parser.
    integer mode_out = MODE_AVATAR;
    if (!FollowIsAvatar)              mode_out = MODE_POST;
    else if (FollowTarget != Leasher) mode_out = MODE_COFFLE;

    key target_out = NULL_KEY;
    if (FollowTarget != Leasher || !FollowIsAvatar) target_out = FollowTarget;

    string msg = llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.state",
        "leashed", Leashed,
        "leasher", (string)Leasher,
        "length", LeashLength,
        "turnto", TurnToFace,
        "texture", LeashTexture,
        "mode", mode_out,
        "target", (string)target_out
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- SETTINGS ACTIONS (mode-agnostic) -------------------- */
setLengthInternal(integer length) {
    LeashLength = clampLeashLength(length);
    persistSetting(KEY_LEASH_LENGTH, (string)LeashLength);
    NeedBroadcast = TRUE;
}

toggleTurnInternal() {
    TurnToFace = !TurnToFace;
    if (!TurnToFace) {
        llOwnerSay("@setrot=clear");
        LastTurnAngle = -999.0;
    }
    persistSetting(KEY_LEASH_TURNTO, (string)TurnToFace);
    NeedBroadcast = TRUE;
}

setTextureInternal(string texture) {
    if (texture != "chain" && texture != "silk" && texture != "invisible") return;
    if (texture == LeashTexture) {
        NeedBroadcast = TRUE;
        return;
    }
    LeashTexture = texture;
    persistSetting(KEY_LEASH_TEXTURE, texture);
    NeedBroadcast = TRUE;

    if (Leashed) {
        key t = HolderTarget;
        if (t == NULL_KEY) t = FollowTarget;
        if (t != NULL_KEY) setParticlesState(TRUE, t);
    }
}

/* -------------------- UNIFIED LEASH CLAIM -------------------- */

// One entry point for all three claim kinds. Resolves a unified
// (follow_target, follow_is_avatar) pair and calls setLeashState, which marks
// the transition; activateLeashFromState() (on entry) does the activation.
// gate_on_holder: TRUE for a fresh user grab/coffle — defer the restraint until
// a holder answers (deny on timeout). FALSE for post / reclip — activate
// immediately. A take-over (already leashed) never defers regardless.
claimLeash(key user, integer mode, key target_key, integer acl_level, integer gate_on_holder) {
    integer was_leashed = Leashed;
    if (Leashed) {
        if (mode == MODE_AVATAR && acl_level >= 3) {
            llRegionSayTo(Leasher, 0, "Leash taken by " + llKey2Name(user));
            // fall through to overwrite
        }
        else if (mode == MODE_AVATAR) {
            llRegionSayTo(user, 0, "Already leashed to " + llKey2Name(Leasher));
            return;
        }
        else {
            llRegionSayTo(user, 0, "Already leashed. Unclip first.");
            return;
        }
    }

    key follow_target;
    integer follow_is_avatar;
    string notice;

    if (mode == MODE_AVATAR) {
        follow_target = user;
        follow_is_avatar = TRUE;
        notice = "Leash grabbed by " + llKey2Name(user);
    }
    else if (mode == MODE_COFFLE) {
        // OBJECT_OWNER is the avatar wearing the target collar — that's who our
        // wearer physically follows (allows coffling subs with the same Dom).
        list details = llGetObjectDetails(target_key, [OBJECT_POS, OBJECT_NAME, OBJECT_OWNER]);
        if (llGetListLength(details) == 0) {
            llRegionSayTo(user, 0, "Target collar not found or out of range.");
            return;
        }
        follow_target = llList2Key(details, 2);
        if (follow_target == NULL_KEY) {
            llRegionSayTo(user, 0, "Cannot coffle: target collar has no owner.");
            return;
        }
        if (follow_target == llGetOwner()) {
            llRegionSayTo(user, 0, "Cannot coffle to yourself.");
            return;
        }
        follow_is_avatar = TRUE;
        notice = "Coffled to " + llKey2Name(follow_target);
    }
    else if (mode == MODE_POST) {
        list details = llGetObjectDetails(target_key, [OBJECT_POS, OBJECT_NAME]);
        if (llGetListLength(details) == 0) {
            llRegionSayTo(user, 0, "Post object not found or out of range.");
            return;
        }
        follow_target = target_key;
        follow_is_avatar = FALSE;
        notice = "Posted to " + llList2String(details, 1);
    }

    LeashCause = CAUSE_NATIVE;

    // Defer the restraint only for a FRESH gated grab/coffle (not a take-over).
    integer defer = (gate_on_holder && !was_leashed);
    PendingHolder = defer;

    setLeashState(user, follow_target, follow_is_avatar, mode);

    if (defer) {
        // Hold the leashed-broadcast (so plugin_leash's enhanced-TP stays off)
        // and the success notice until a holder confirms; deny on timeout.
        NeedBroadcast = FALSE;
        PendingNotice = notice;
        PendingDeadline = llGetUnixTime() + (integer)PENDING_WINDOW;
    }

    // Fresh claim (was unleashed): leashed/state_entry runs activation on the
    // transition. Take-over (was already leashed): same-state, so state_entry
    // won't re-run — activate the new session directly, like pass.
    if (was_leashed) activateLeashFromState();
    if (!defer) llRegionSayTo(user, 0, notice);
}


/* ------------------------------------------------------------
   SECTION 2 — AVATAR-SPECIFIC FLOWS
   ------------------------------------------------------------ */

releaseLeashInternal(key user) {
    if (!Leashed) {
        llRegionSayTo(user, 0, "Not currently leashed.");
        return;
    }
    clearLeashState(TRUE);  // TRUE = clear reclip attempts
    llRegionSayTo(user, 0, "Leash released");
}

passLeashInternal(key new_leasher) {
    if (!Leashed) return;
    key old_leasher = Leasher;

    // Pass = full transfer; revert to avatar mode.
    LeashCause = CAUSE_NATIVE;
    setLeashState(new_leasher, new_leasher, TRUE, MODE_AVATAR);
    // Same-state (leashed->leashed) so state_entry won't re-run; activate the
    // new session directly (re-follow + re-handshake + LM for the new leasher).
    activateLeashFromState();

    notifyLeashTransfer(old_leasher, new_leasher, "passed");
}

yankToLeasher() {
    if (!Leashed || Leasher == NULL_KEY) return;

    list details = llGetObjectDetails(Leasher, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        llRegionSayTo(llGetOwner(), 0, "Cannot yank: leasher not in range.");
        return;
    }
    vector leasher_pos = llList2Vector(details, 0);

    if (ControlsOk) {
        if (YankTargetHandle != 0) {
            llTargetRemove(YankTargetHandle);
            YankTargetHandle = 0;
        }
        llMoveToTarget(leasher_pos, 0.3);
        YankTargetHandle = llTarget(leasher_pos, 1.5);
        updateControlsMask();
        llRegionSayTo(llGetOwner(), 0, "Yanked to " + llKey2Name(Leasher));
        llRegionSayTo(Leasher, 0, llKey2Name(llGetOwner()) + " yanked to you.");
    } else {
        llRegionSayTo(llGetOwner(), 0, "Cannot yank: controls not active.");
    }
}

// Lockmeister grab-inflow from kmod_particles. LM is avatar-only; accept the
// controller as the new leasher. Authorization is verified by the caller.
handleLmGrabbed(key controller) {
    if (Leashed) return;
    LeashCause = CAUSE_LM;   // particles already rendering LM — no native probe/LM re-enable
    setLeashState(controller, controller, TRUE, MODE_AVATAR);
    llRegionSayTo(llGetOwner(), 0, "Leashed by " + llKey2Name(controller) + " (Lockmeister)");
}

handleLmReleased() {
    if (!Leashed) return;
    key old_leasher = Leasher;
    clearLeashState(TRUE);
    llRegionSayTo(llGetOwner(), 0, "Released by " + llKey2Name(old_leasher) + " (Lockmeister)");
}


/* ------------------------------------------------------------
   SECTION 3 — SHARED EVENT ROUTING
   ------------------------------------------------------------ */

// Permissions can be granted in either state.
onControlsGranted(integer perm) {
    if (perm & PERMISSION_TAKE_CONTROLS) {
        ControlsOk = TRUE;
        llTakeControls(CONTROL_ML_LBUTTON, FALSE, TRUE);
        ControlsExpanded = FALSE;
        updateControlsMask();
    }
}

// Shared link_message routing for both states. Helpers set StateChange; the
// per-state link_message shell applies the transition afterward.
routeLinkMessage(integer num, string msg, key id) {
    string msg_type = llJsonGetValue(msg, ["type"]);
    if (msg_type == JSON_INVALID) return;

    if (num == KERNEL_LIFECYCLE) {
        if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
            llResetScript();
        }
        return;
    }

    if (num == UI_BUS) {
        if (msg_type == "plugin.leash.action") {
            string action = jsonGet(msg, "action", "");
            if (action == "") return;
            key user = id;

            if (action == "query_state") {
                broadcastState();
                return;
            }

            if (action == "yank") {
                if (user == Leasher) {
                    integer now_time = llGetUnixTime();
                    if ((now_time - LastYankTime) < YANK_COOLDOWN) {
                        integer wait_time = (integer)(YANK_COOLDOWN - (now_time - LastYankTime));
                        llRegionSayTo(user, 0, "Yank on cooldown. Wait " + (string)wait_time + "s.");
                        return;
                    }
                    LastYankTime = now_time;
                    yankToLeasher();
                } else {
                    llRegionSayTo(user, 0, "Only the current leasher can yank.");
                }
                return;
            }

            // plugin_leash / plugin_leash_target already gate by policy and
            // pass the user's acl level; the engine trusts the intra-object
            // request and acts synchronously — no AUTH round-trip, no Pending
            // state. (Engines process, plugins decide.)
            integer acl = (integer)jsonGet(msg, "acl", "0");
            key target = (key)jsonGet(msg, "target", (string)NULL_KEY);

            if (action == "grab")             claimLeash(user, MODE_AVATAR, NULL_KEY, acl, TRUE);
            else if (action == "coffle")      claimLeash(user, MODE_COFFLE, target, acl, TRUE);
            else if (action == "post")        claimLeash(user, MODE_POST, target, acl, FALSE);
            else if (action == "release" || action == "force_release") releaseLeashInternal(user);
            else if (action == "pass")        passLeashInternal(target);
            else if (action == "offer") {
                if (Leashed) llRegionSayTo(user, 0, "Cannot offer leash: already leashed.");
                else sendOfferPending(target, user);
            }
            else if (action == "set_length")  setLengthInternal((integer)jsonGet(msg, "length", "0"));
            else if (action == "toggle_turn") toggleTurnInternal();
            else if (action == "set_texture") setTextureInternal(jsonGet(msg, "texture", "chain"));
            return;
        }

        if (msg_type == "sos.leash.release") {
            if (id == llGetOwner()) {
                releaseLeashInternal(id);
            }
            return;
        }

        if (msg_type == "particles.lm.grabbed") {
            key controller = (key)jsonGet(msg, "controller", (string)NULL_KEY);
            if (controller == NULL_KEY) return;
            if (controller != AuthorizedLmController) return;
            if (PendingHolder) commitPendingLeash();   // a pending grab's holder answered
            else handleLmGrabbed(controller);           // Lockmeister grab-inflow
            return;
        }

        if (msg_type == "particles.lm.released") {
            handleLmReleased();
            return;
        }
        return;
    }

    if (num == SETTINGS_BUS) {
        if (msg_type == "settings.sync") {
            applySettingsSync();
        }
        return;
    }
}


/* ------------------------------------------------------------
   SECTION 4 — STATES
   ------------------------------------------------------------ */

default
{
    state_entry() {
        HolderTarget = NULL_KEY;
        AwaitingHolder = FALSE;
        AuthorizedLmController = NULL_KEY;

        applySettingsSync();

        // Cold restart: resume an active leash. leashed/state_entry sets up the
        // listener, timer, controls, and activation.
        if (Leashed && Leasher != NULL_KEY) {
            LeashCause = CAUSE_NATIVE;
            state leashed;
        }

        // Idle setup.
        llListen(LEASH_CHAN, "", NULL_KEY, "");
        llSetTimerEvent(FOLLOW_TICK);
        if (!ControlsOk) llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    run_time_permissions(integer perm) {
        onControlsGranted(perm);
    }

    link_message(integer sender, integer num, string msg, key id) {
        routeLinkMessage(num, msg, id);
        if (NeedBroadcast) { NeedBroadcast = FALSE; broadcastState(); }
        // Only TR_LEASH is reachable here: you can't release when unleashed.
        if (takeStateChange() == TR_LEASH) state leashed;
    }

    listen(integer channel, string name, key id, string msg) {
        if (channel != LEASH_CHAN) return;
        handleLeashListen(msg);
    }

    timer() {
        TickCount++;
        // Auto-reclip polling after an offsim release (~4s cadence). The reclip
        // re-leash is async (ACL query → result in link_message), so no
        // transition originates here.
        if ((TickCount % 4) == 0) {
            if (ReclipScheduled != 0) checkAutoReclip();
        }
    }
}


state leashed
{
    state_entry() {
        llListen(LEASH_CHAN, "", NULL_KEY, "");
        llSetTimerEvent(FOLLOW_TICK);
        if (!ControlsOk) llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);
        else updateControlsMask();
        activateLeashFromState();
    }

    state_exit() {
        // Physical teardown — runs exactly once per leashed→unleashed (or
        // owner-change reset) transition.
        stopFollow();
        setParticlesState(FALSE, NULL_KEY);
        setLockmeisterState(FALSE, NULL_KEY);
        AwaitingHolder = FALSE;
        AtLimit = FALSE;
        updateControlsMask();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    run_time_permissions(integer perm) {
        onControlsGranted(perm);
    }

    link_message(integer sender, integer num, string msg, key id) {
        routeLinkMessage(num, msg, id);
        if (NeedBroadcast) { NeedBroadcast = FALSE; broadcastState(); }
        // Only TR_UNLEASH is reachable here: a re-claim/pass while leashed
        // activates in place (claimLeash/passLeashInternal) without re-entering.
        if (takeStateChange() == TR_UNLEASH) state default;
    }

    listen(integer channel, string name, key id, string msg) {
        if (channel != LEASH_CHAN) return;
        handleLeashListen(msg);
    }

    control(key id, integer level, integer edge) {
        if (!Leashed) return;
        integer pressed = level & edge;
        integer directional = CONTROL_FWD | CONTROL_BACK
                            | CONTROL_LEFT | CONTROL_RIGHT
                            | CONTROL_ROT_LEFT | CONTROL_ROT_RIGHT;
        if ((pressed & directional) == 0) return;

        key follow_target = FollowTarget;
        if (follow_target == NULL_KEY) return;

        key target_key = follow_target;
        if (HolderTarget != NULL_KEY) target_key = HolderTarget;

        list details = llGetObjectDetails(target_key, [OBJECT_POS]);
        if (llGetListLength(details) == 0) return;
        vector target_pos = llList2Vector(details, 0);

        vector wearer_pos = llGetRootPosition();
        float distance = llVecDist(wearer_pos, target_pos);
        if (distance < (float)LeashLength) return;

        // Soft corrective pull — bridges the 1Hz follow tick and is the only
        // correction in post mode (no RLV @follow).
        vector pull_pos = target_pos + llVecNorm(wearer_pos - target_pos) * (float)LeashLength * 0.85;
        llMoveToTarget(pull_pos, 1.0);
        LastTargetPos = pull_pos;
    }

    timer() {
        TickCount++;

        // Offsim / auto-release (~4s cadence). May clearLeashState → TR_UNLEASH.
        if ((TickCount % 4) == 0) {
            checkLeasherPresence();
        }

        // Native discovery timed out — no DS holder answered.
        if (AwaitingHolder && llGetUnixTime() > ProbeDeadline) {
            AwaitingHolder = FALSE;
            // Only aim particles at the raw anchor for coffle/post (no LM). For
            // an avatar grab LM is active and kmod_particles owns the OC-holder
            // render — sending a native fallback here would OVERRIDE it (native
            // outranks Lockmeister in kmod_particles), snapping the leash to the
            // avatar centre instead of the OC leash-point prim. A pending claim
            // applies NO fallback — it either confirms or is denied below.
            if (!PendingHolder && AuthorizedLmController == NULL_KEY && FollowTarget != NULL_KEY) {
                setParticlesState(TRUE, FollowTarget);
            }
        }

        // Deferred grab/coffle that no holder ever confirmed → deny. Nothing was
        // restrained (follow + broadcast were held), so this is a clean drop.
        if (PendingHolder && llGetUnixTime() > PendingDeadline) {
            denyPendingLeash();
        }

        // Re-acquire a leashpoint every ~10s if we've fallen through to the
        // avatar/root (HolderTarget cleared, or never found one).
        if ((TickCount % 10) == 0) {
            if (Leashed && HolderTarget == NULL_KEY && Leasher != NULL_KEY && !AwaitingHolder) {
                startProbe();
            }
        }

        if (FollowActive && Leashed) followTick();

        if (NeedBroadcast) { NeedBroadcast = FALSE; broadcastState(); }
        integer tr = takeStateChange();
        if (tr == TR_UNLEASH) state default;
    }

    at_target(integer tnum, vector target_pos, vector my_pos) {
        // Yank arrival: release the physics hold so the wearer is not anchored
        // to the leasher's exact position after a yank.
        if (tnum == YankTargetHandle) {
            llTargetRemove(YankTargetHandle);
            YankTargetHandle = 0;
            llStopMoveToTarget();
            LastTargetPos = ZERO_VECTOR;
            updateControlsMask();
        }
    }
}

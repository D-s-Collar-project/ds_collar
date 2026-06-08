/*--------------------
MODULE: kmod_leash_engine.lsl
VERSION: 1.2
REVISION: 0
PURPOSE: Leashing engine — state, ACL, claim/release/pass/yank, follow
         mechanics, settings persistence, broadcasts. Holder-discovery
         handshake protocol lives in sibling kmod_leash_proto.lsl.
ARCHITECTURE: Engine + sibling proto. Engine owns leash state and the
              high-level lifecycle. Proto owns the LEASH_CHAN_NATIVE /
              LEASH_CHAN_LM listeners and the two-phase handshake state
              machine. IPC reuses SETTINGS_BUS so no new bus number is
              consumed (proto filters on type prefix "leash.proto.*").
--------------------*/


/* ------------------------------------------------------------
   SECTION 1 — SHARED INFRASTRUCTURE
   State, helpers, ACL gate, holder handshake, follow tick,
   offsim/reclip, settings, broadcast. Mode-agnostic.
   ------------------------------------------------------------ */

/* -------------------- BUS CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;

/* -------------------- PROTOCOL CONSTANTS -------------------- */

string PLUGIN_CONTEXT = "ui.core.leash";

// Policy button labels (must match plugin_leash policy CSV entries)
string POL_CLIP     = "Clip";
string POL_TAKE     = "Take";
string POL_UNCLIP   = "Unclip";
string POL_PASS     = "Pass";
string POL_OFFER    = "Offer";
string POL_COFFLE   = "Coffle";
string POL_POST     = "Post";
string POL_SETTINGS = "Settings";

// Leash session abstraction (state = Leasher + FollowTarget + FollowIsAvatar):
//   Leasher        = controller (has authority: release, yank, pass)
//   FollowTarget   = who/what the wearer physically follows
//   FollowIsAvatar = TRUE → target is an avatar (RLV @follow applies; validation
//                    against responder's attachment-owner)
//                    FALSE → target is a static object (no @follow; validation
//                    against responder's linkset root)
//
// The three legacy "modes" emerge from combinations:
//   Leasher == FollowTarget,  FollowIsAvatar=TRUE  → "grab"   (regular leash)
//   Leasher != FollowTarget,  FollowIsAvatar=TRUE  → "coffle" (chain link)
//                              FollowIsAvatar=FALSE → "post"   (static object)
// mode_str is derived at handshake send-time; not a stored state variable.
//
// Pass swaps Leasher AND FollowTarget to the new user (full transfer).
// Coffle keeps Leasher, changes FollowTarget (redirect follow without transfer).

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

/* -------------------- STATE -------------------- */

// Leash state
integer Leashed = FALSE;
key Leasher = NULL_KEY;
integer LeashLength = 3;
integer TurnToFace = FALSE;
string LeashTexture = "chain";    // Particle style — "chain" / "silk" / "invisible"
key FollowTarget = NULL_KEY;       // Who/what the wearer follows physically
integer FollowIsAvatar = TRUE;     // TRUE → avatar (RLV @follow + attachment validation); FALSE → object (root validation)

// Original claim mode (MODE_AVATAR / MODE_COFFLE / MODE_POST). Set in
// setLeashState from the action the user actually clicked, persisted
// under KEY_CLAIM_MODE, and read by sendProtoStart to derive mode_str
// for the wire. Decouples wire mode from the (Leasher, FollowTarget)
// equality test, so "A coffles B to A" stays mode=coffle even though
// Leasher == FollowTarget.
integer LeashClaimMode = 0;        // 0 = MODE_AVATAR (the default for cold restart)

// Follow mechanics
integer FollowActive = FALSE;
vector LastTargetPos = ZERO_VECTOR;
float LastDistance = -1.0;
integer ControlsOk = FALSE;
integer AtLimit = FALSE;          // distance >= LeashLength
integer ControlsExpanded = FALSE; // TRUE when directional keys are in our llTakeControls mask
integer TickCount = 0;

// Turn-to-face throttling
float LastTurnAngle = -999.0;
float TURN_THRESHOLD = 0.1;  // ~5.7 degrees

// Holder discovery — kmod_leash_proto runs the actual handshake state
// machine and notifies us via leash.proto.holder / leash.proto.fallback.
// HolderTarget is the engine's source-of-truth (proto reports, we pin).
key HolderTarget = NULL_KEY;

// Offsim detection & auto-reclip
integer OffsimDetected = FALSE;
integer OffsimStartTime = 0;
float OFFSIM_GRACE = 6.0;
integer ReclipScheduled = 0;
key LastLeasher = NULL_KEY;
integer ReclipAttempts = 0;
integer MAX_RECLIP_ATTEMPTS = 3;
// Wall-clock cap on how long we keep waiting for LastLeasher to return.
// Prevents a surprise reclip if the leasher crashes at noon and logs back
// in hours later; auto-reclip state clears after RECLIP_SAFETY_WINDOW
// seconds regardless of whether they returned.
integer RECLIP_SAFETY_WINDOW = 120;
integer ReclipDeadline = 0;

// ACL verification system
key PendingActionUser = NULL_KEY;
string PendingAction = "";
key PendingPassTarget = NULL_KEY;
integer AclPending = FALSE;
key PendingPassOriginalUser = NULL_KEY;  // Tracks original passer for error messages
integer PendingIsOffer = FALSE;          // TRUE if this is an offer, not a pass

// Lockmeister authorization
key AuthorizedLmController = NULL_KEY;

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
integer now() {
    return llGetUnixTime();
}
// Check if a button label is allowed at the given ACL level via LSD policy
integer policy_allows(string btn_label, integer acl_level) {
    string policy = llLinksetDataRead("acl.policycontext:" + PLUGIN_CONTEXT);
    if (policy == "") return FALSE;
    string csv = llJsonGetValue(policy, [(string)acl_level]);
    if (csv == JSON_INVALID) return FALSE;
    return (llListFindList(llCSV2List(csv), [btn_label]) != -1);
}
denyAccess(key user, string reason) {
    llRegionSayTo(user, 0, "Access denied: " + reason);
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

    // FollowTarget / FollowIsAvatar / LeashClaimMode aren't persisted
    // — mode survives only in-memory; coffle/post sessions don't
    // restore the original FollowTarget across script reset (matches
    // pre-unification behavior). If we wake up Leashed with no
    // in-memory follow target, default to avatar mode with Leasher as
    // the follow target (LeashClaimMode already defaults to MODE_AVATAR
    // = 0 via its global initialiser, so sendProtoStart consistently
    // emits mode=grab in this cold-restart fallback). The 10s retry
    // timer then re-handshakes to discover the real leashpoint. The
    // FollowTarget == NULL_KEY guard makes this cold-restart-only —
    // mid-session settings.sync (triggered by our own persistLeashState
    // during claimLeash) must NOT clobber an active post/coffle
    // session back into grab mode.
    if (Leashed && Leasher != NULL_KEY && FollowTarget == NULL_KEY) {
        FollowTarget = Leasher;
        FollowIsAvatar = TRUE;
    }
}

/* -------------------- STATE MANAGEMENT -------------------- */

// Clamp leash length to valid range
integer clampLeashLength(integer len) {
    if (len < 1) return 1;
    if (len > 20) return 20;
    return len;
}

// Helper to set common leash state. `follow_target` is who/what the
// wearer will follow physically; `follow_is_avatar` distinguishes
// avatar-mode (RLV @follow + attachment-owner validation) from
// object-mode (no @follow + linkset-root validation). `claim_mode` is
// the user's original action (MODE_AVATAR/MODE_COFFLE/MODE_POST) so
// sendProtoStart can emit the right wire mode even when the
// (Leasher, FollowTarget) state alone is ambiguous (the "A coffles
// B to A" path collapses Leasher == FollowTarget for grab AND
// self-targeted coffle). In-memory only — coffle/post sessions
// already don't restore the original FollowTarget across cold
// restart (per applySettingsSync's documented fallback), so
// persisting the tag would only protect a session that's already
// collapsing into avatar/grab semantics anyway.
setLeashState(key user, key follow_target, integer follow_is_avatar, integer claim_mode) {
    Leashed = TRUE;
    Leasher = user;
    LastLeasher = user;
    FollowTarget = follow_target;
    FollowIsAvatar = follow_is_avatar;
    LeashClaimMode = claim_mode;
    persistLeashState(TRUE, user);
    broadcastState();
}

// Clear all leash state (used by release and auto-release)
clearLeashState(integer clear_reclip) {
    Leashed = FALSE;
    Leasher = NULL_KEY;
    FollowTarget = NULL_KEY;
    FollowIsAvatar = TRUE;
    LeashClaimMode = 0;
    persistLeashState(FALSE, NULL_KEY);
    HolderTarget = NULL_KEY;
    AuthorizedLmController = NULL_KEY;
    sendProtoShutdown();

    if (clear_reclip) clearReclipState();

    setLockmeisterState(FALSE, NULL_KEY);
    setParticlesState(FALSE, NULL_KEY);
    stopFollow();
    AtLimit = FALSE;
    updateControlsMask();
    broadcastState();
}

/* -------------------- NOTIFICATIONS -------------------- */

// For multi-party notifications (like pass)
notifyLeashTransfer(key from_user, key to_user, string action) {
    llRegionSayTo(from_user, 0, "Leash " + action + " to " + llKey2Name(to_user));
    llRegionSayTo(to_user, 0, "Leash received from " + llKey2Name(from_user));
    llRegionSayTo(llGetOwner(), 0, "Leash " + action + " to " + llKey2Name(to_user) + " by " + llKey2Name(from_user));
}

/* -------------------- LEASH PROTO IPC -------------------- */
// Engine ↔ kmod_leash_proto traffic. Reuses SETTINGS_BUS so no new bus
// number is consumed — proto filters on type prefix "leash.proto.*".
//
// engine → proto:
//   leash.proto.start    — kick off handshake (controller, mode_str,
//                          validation_target, oc_ping_target)
//   leash.proto.shutdown — tear down listeners on clear/reset
//
// proto → engine:
//   leash.proto.holder   — handshake found a holder, pin it
//   leash.proto.fallback — handshake timed out, particle-aim target
sendProtoStart(key controller) {
    // mode_str follows the persisted LeashClaimMode tag — the user's
    // original action intent. Deriving from (Leasher, FollowTarget)
    // alone loses information: both regular grab and self-targeted
    // coffle collapse to Leasher == FollowTarget, but they need
    // different responders (hand-held leash_holder for grab; the peer
    // collar's LeashPoint via kmod_leash_proto for coffle). The wire
    // strings stay legacy-compatible ("grab" / "coffle" / "post"), so
    // other DS / OC collars are unaffected.
    string mode_str;
    if      (LeashClaimMode == MODE_POST)   mode_str = "post";
    else if (LeashClaimMode == MODE_COFFLE) mode_str = "coffle";
    else                                    mode_str = "grab";

    // Unified model: both validation_target and oc_ping_target are
    // FollowTarget. For avatar-modes the responder is expected to be an
    // attachment owned by FollowTarget; for post the responder's linkset
    // root must equal FollowTarget. The OC LM ping is addressed to the
    // same UUID and the responder echoes it back as the nonce.
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type",              "leash.proto.start",
        "controller",        (string)controller,
        "mode",              mode_str,
        "validation_target", (string)FollowTarget,
        "oc_ping_target",    (string)FollowTarget
    ]), NULL_KEY);
}

sendProtoShutdown() {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "leash.proto.shutdown"
    ]), NULL_KEY);
}

/* -------------------- ACL VERIFICATION -------------------- */
clearPendingAction() {
    AclPending = FALSE;
    PendingActionUser = NULL_KEY;
    PendingAction = "";
    PendingPassTarget = NULL_KEY;
    PendingPassOriginalUser = NULL_KEY;
    PendingIsOffer = FALSE;
}

requestAclForAction(key user, string action, key pass_target) {
    AclPending = TRUE;
    PendingActionUser = user;
    PendingAction = action;
    PendingPassTarget = pass_target;

    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "auth.acl.query",
        "avatar", (string)user
    ]), user);
}

handleAclResult(string msg) {
    if (!AclPending) return;
    if (llJsonGetValue(msg, ["avatar"]) == JSON_INVALID || llJsonGetValue(msg, ["level"]) == JSON_INVALID) return;

    key avatar = (key)llJsonGetValue(msg, ["avatar"]);
    if (avatar != PendingActionUser) return;

    integer acl_level = (integer)llJsonGetValue(msg, ["level"]);
    AclPending = FALSE;

    // Execute pending action with ACL verification

    // Release: current leasher can always release (safety); otherwise policy-gated
    if (PendingAction == "release") {
        if (PendingActionUser == Leasher || policy_allows(POL_UNCLIP, acl_level)) {
            releaseLeashInternal(PendingActionUser);
        } else {
            denyAccess(PendingActionUser, "only leasher or authorized users can release");
        }
    }
    // Force-release: maintenance emergency clear — wearer always allowed; trustees/owners allowed.
    // Does NOT require the user to be the current leasher, so it clears stray leashes
    // from bad actors (e.g., random public users who clip a public-access collar).
    else if (PendingAction == "force_release") {
        if (PendingActionUser == llGetOwner() || acl_level >= 3) {
            releaseLeashInternal(PendingActionUser);
        } else {
            denyAccess(PendingActionUser, "only wearer or authorized users can force-clear leash");
        }
    }
    // Special case: pass (current leasher OR policy-allowed can pass, then verify target)
    else if (PendingAction == "pass") {
        if (PendingActionUser == Leasher || policy_allows(POL_PASS, acl_level)) {
            requestAclForPassTarget(PendingPassTarget);
            return;  // Don't clear pending state yet
        } else {
            denyAccess(PendingActionUser, "insufficient permissions to pass leash");
        }
    }
    // Special case: offer (policy-allowed, when NOT currently leashed, then verify target)
    else if (PendingAction == "offer") {
        if (policy_allows(POL_OFFER, acl_level) && !Leashed) {
            PendingIsOffer = TRUE;
            requestAclForPassTarget(PendingPassTarget);
            return;  // Don't clear pending state yet
        } else if (Leashed) {
            llRegionSayTo(PendingActionUser, 0, "Cannot offer leash: already leashed.");
        } else {
            denyAccess(PendingActionUser, "insufficient permissions to offer leash");
        }
    }
    // Special case: pass_target_check (verifying the target's ACL for pass/offer)
    // Target must be level 1+ (public or higher) to receive leash.
    else if (PendingAction == "pass_target_check") {
        if (acl_level >= 1) {
            // Offer sends message to plugin for dialog, pass directly transfers.
            if (PendingIsOffer) {
                sendOfferPending(PendingPassTarget, PendingPassOriginalUser);
            }
            else {
                passLeashInternal(PendingPassTarget);
            }
        } else {
            string action_name = "pass";
            if (PendingIsOffer) action_name = "offer";
            llRegionSayTo(PendingPassOriginalUser, 0, "Cannot " + action_name + " leash: target has insufficient permissions.");
        }

        // Clear pass-specific state
        PendingPassOriginalUser = NULL_KEY;
        PendingIsOffer = FALSE;
    }
    // Standard ACL pattern for simple actions — single per-action block
    // checks the LSD policy and dispatches in one ladder.
    else if (PendingAction == "grab") {
        // "grab" is "Take" (take-over) when already leashed, "Clip" otherwise
        string label = POL_CLIP;
        if (Leashed) label = POL_TAKE;
        if (policy_allows(label, acl_level)) claimLeash(PendingActionUser, MODE_AVATAR, NULL_KEY, acl_level);
        else denyAccess(PendingActionUser, "insufficient permissions");
    }
    else if (PendingAction == "coffle") {
        if (policy_allows(POL_COFFLE, acl_level)) claimLeash(PendingActionUser, MODE_COFFLE, PendingPassTarget, acl_level);
        else denyAccess(PendingActionUser, "insufficient permissions");
    }
    else if (PendingAction == "post") {
        if (policy_allows(POL_POST, acl_level)) claimLeash(PendingActionUser, MODE_POST, PendingPassTarget, acl_level);
        else denyAccess(PendingActionUser, "insufficient permissions");
    }
    else if (PendingAction == "set_length") {
        if (policy_allows(POL_SETTINGS, acl_level)) setLengthInternal((integer)((string)PendingPassTarget));
        else denyAccess(PendingActionUser, "insufficient permissions");
    }
    else if (PendingAction == "toggle_turn") {
        if (policy_allows(POL_SETTINGS, acl_level)) toggleTurnInternal();
        else denyAccess(PendingActionUser, "insufficient permissions");
    }
    else if (PendingAction == "set_texture") {
        if (policy_allows(POL_SETTINGS, acl_level)) setTextureInternal((string)PendingPassTarget);
        else denyAccess(PendingActionUser, "insufficient permissions");
    }
    // Enhanced mode is applied locally by plugin_leash now — the engine has
    // no toggle_enhanced handler; an unknown action just falls through here.

    clearPendingAction();
}

requestAclForPassTarget(key target) {
    // Save original passer for error messages
    PendingPassOriginalUser = PendingActionUser;

    // Set PendingActionUser to target so handleAclResult accepts the response
    PendingActionUser = target;

    // Reuse pending state for target check
    PendingAction = "pass_target_check";
    AclPending = TRUE;

    llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
        "type", "auth.acl.query",
        "avatar", (string)target
    ]), target);
}

/* -------------------- OFFSIM DETECTION & AUTO-RECLIP -------------------- */
clearReclipState() {
    ReclipScheduled = 0;
    LastLeasher = NULL_KEY;
    ReclipAttempts = 0;
    ReclipDeadline = 0;
}

checkLeasherPresence() {
    if (!Leashed || Leasher == NULL_KEY) return;

    integer now_time = llGetUnixTime();

    // Check both avatar and holder separately
    integer avatar_present = (llGetAgentInfo(Leasher) != 0);
    integer holder_present = FALSE;

    if (HolderTarget != NULL_KEY) {
        holder_present = (llGetListLength(llGetObjectDetails(HolderTarget, [OBJECT_POS])) > 0);
    }

    integer present = avatar_present || holder_present;

    // Notify if holder-only mode (avatar offline, holder remains)
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

autoReleaseOffsim() {
    clearLeashState(FALSE);  // FALSE = don't clear reclip (we want to try reclipping)
    llRegionSayTo(llGetOwner(), 0, "Auto-released (offsim)");
}

checkAutoReclip() {
    if (ReclipScheduled == 0 || now() < ReclipScheduled) return;

    // Safety window: stop waiting if leasher hasn't returned in time.
    // Checked before MAX_RECLIP_ATTEMPTS so a leasher who reappears after
    // the window is never reclipped even if attempts haven't been exhausted.
    if (ReclipDeadline != 0 && now() >= ReclipDeadline) {
        clearReclipState();
        return;
    }

    if (ReclipAttempts >= MAX_RECLIP_ATTEMPTS) {
        clearReclipState();
        return;
    }

    if (LastLeasher != NULL_KEY && llGetAgentInfo(LastLeasher) != 0) {
        requestAclForAction(LastLeasher, "grab", NULL_KEY);
        ReclipAttempts = ReclipAttempts + 1;
        ReclipScheduled = now() + 2;
    }
}

/* -------------------- FOLLOW MECHANICS -------------------- */

// The leash anchor for the current session. After the Controller/
// FollowTarget unification this is a one-liner; kept as a helper so
// call sites read clearly (and so a future swap to a derived value is
// localised). Callers may layer HolderTarget on top when they want the
// discovered LeashPoint prim instead of the raw anchor.
key leashFollowTarget() {
    return FollowTarget;
}

// accept=FALSE so the wearer's input still drives the avatar normally;
// control() events fire and we layer a corrective llMoveToTarget on top.
// Directional keys are added to the mask only when leashed AND (at the
// leash limit OR a yank is in flight) — otherwise the only registered
// control is ML_LBUTTON for the no-script-parcel sticky exemption.
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

    // RLV @follow target: FollowTarget when avatar; post mode skips
    // because static prims can't be RLV-followed.
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
    LastDistance = -1.0;
    LastTurnAngle = -999.0;
}

turnToTarget(vector target_pos) {
    if (!TurnToFace || !Leashed) return;

    vector wearer_pos = llGetRootPosition();
    vector direction = llVecNorm(target_pos - wearer_pos);
    float angle = llAtan2(direction.y, direction.x);

    // Only send command if angle changed significantly
    if (llFabs(angle - LastTurnAngle) > TURN_THRESHOLD) {
        llOwnerSay("@setrot:" + (string)angle + "=force");
        LastTurnAngle = angle;
    }
}

followTick() {
    if (!FollowActive || !Leashed) return;

    vector target_pos;
    key follow_target = leashFollowTarget();
    if (follow_target == NULL_KEY) return;

    // Prefer the discovered LeashPoint prim over the raw mode target.
    key target_key = follow_target;
    if (HolderTarget != NULL_KEY) target_key = HolderTarget;

    list details = llGetObjectDetails(target_key, [OBJECT_POS]);

    // HolderTarget vanished (detached/derezzed): drop it and retry with
    // the mode's avatar-pelvis/root fallback. Applies in all modes now.
    if (llGetListLength(details) == 0 && target_key == HolderTarget) {
        HolderTarget = NULL_KEY;
        updateParticlesTarget(follow_target);
        target_key = follow_target;
        details = llGetObjectDetails(target_key, [OBJECT_POS]);
    }

    if (llGetListLength(details) == 0) return;
    target_pos = llList2Vector(details, 0);

    vector wearer_pos = llGetRootPosition();
    float distance = llVecDist(wearer_pos, target_pos);

    integer new_at_limit = (distance >= (float)LeashLength);
    if (new_at_limit != AtLimit) {
        AtLimit = new_at_limit;
        updateControlsMask();
    }

    if (ControlsOk && distance > (float)LeashLength) {
        // Pull to 0.85 * length (not 0.98) so there is slack on arrival
        // and the wearer is not pinned at the leash limit. Gentler tau
        // (1.0) keeps walking in the leashed direction feasible.
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
        // In range: always release the move target. The previous
        // implementation only stopped on out-of-range -> in-range
        // transitions, leaving the wearer pinned by leftover physics
        // (and, after a yank, anchored permanently). Skip the call when
        // a yank is still in flight so we do not cancel its arrival pull.
        if (LastTargetPos != ZERO_VECTOR && YankTargetHandle == 0) {
            llStopMoveToTarget();
            LastTargetPos = ZERO_VECTOR;
        }
    }

    LastDistance = distance;
}

/* -------------------- STATE BROADCAST -------------------- */
broadcastState() {
    // Legacy "mode" field stays integer-coded for wire-compat with
    // plugin_leash's existing parsing. Derive from current state.
    integer mode_out = MODE_AVATAR;
    if (!FollowIsAvatar)            mode_out = MODE_POST;
    else if (FollowTarget != Leasher) mode_out = MODE_COFFLE;

    // Legacy "target" semantics: NULL_KEY in avatar mode (suppresses the
    // "Target: ..." line in plugin_leash); FollowTarget for coffle/post.
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
    broadcastState();
}

toggleTurnInternal() {
    TurnToFace = !TurnToFace;
    if (!TurnToFace) {
        llOwnerSay("@setrot=clear");
        LastTurnAngle = -999.0;
    }
    persistSetting(KEY_LEASH_TURNTO, (string)TurnToFace);
    broadcastState();
}

setTextureInternal(string texture) {
    // Whitelist: anything outside chain/silk/invisible is dropped silently
    // so a garbage value can't break particles. kmod_particles also falls
    // back to chain on unknown styles as a second layer of defence.
    if (texture != "chain" && texture != "silk" && texture != "invisible") return;
    if (texture == LeashTexture) {
        broadcastState();
        return;
    }
    LeashTexture = texture;
    persistSetting(KEY_LEASH_TEXTURE, texture);
    broadcastState();

    // Re-render particles immediately if we're currently leashed. The
    // idempotence guard in kmod_particles will detect the style change
    // and re-issue llLinkParticleSystem with the new texture.
    if (Leashed) {
        key t = HolderTarget;
        if (t == NULL_KEY) t = leashFollowTarget();
        if (t != NULL_KEY) setParticlesState(TRUE, t);
    }
}


/* -------------------- UNIFIED LEASH CLAIM -------------------- */

// One entry point for all three leashing modes. Per-mode specifics:
//   AVATAR — target_key ignored (NULL_KEY); leasher's own click identifies
//            them. acl_level >= 3 allows take-over of an existing leash.
//            Enables Lockmeister authorization for the controller.
//   COFFLE — target_key is another collar prim; we resolve its wearer
//            (via OBJECT_OWNER) into CoffleTargetAvatar. Reject self-coffle.
//   POST   — target_key is a static object; just verify it exists in-world.
// Common tail (after mode-specific validation): setLeashState, kick off
// the holder handshake, startFollow, send the user-facing notice.
claimLeash(key user, integer mode, key target_key, integer acl_level) {
    // Already-leashed guard. Avatar allows take-over by trustees (ACL 3+);
    // coffle and post always reject — wearer must unclip first.
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

    // Mode-specific target validation. Resolve to a unified
    // (follow_target, follow_is_avatar) pair for setLeashState.
    key follow_target;
    integer follow_is_avatar;
    string notice;

    if (mode == MODE_AVATAR) {
        follow_target = user;
        follow_is_avatar = TRUE;
        notice = "Leash grabbed by " + llKey2Name(user);
    }
    else if (mode == MODE_COFFLE) {
        // OBJECT_OWNER returns the avatar wearing the collar, not the ACL
        // owner (Dom). This validation allows coffling between different
        // subs with the same Dom. The wearer of the target collar is the
        // FollowTarget — that's who our wearer physically follows.
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

    // Common claim sequence. Tag claim mode so sendProtoStart can emit
    // the right wire mode (the user's action intent is otherwise lost
    // once state collapses to (Leasher, FollowTarget, FollowIsAvatar)).
    setLeashState(user, follow_target, follow_is_avatar, mode);
    sendProtoStart(user);
    // LM authorization only when wearer follows the controller (regular
    // leash). Coffle and post don't enable LM.
    if (follow_target == user && follow_is_avatar) {
        AuthorizedLmController = user;
        setLockmeisterState(TRUE, user);
    }
    startFollow();
    llRegionSayTo(user, 0, notice);
}


/* ------------------------------------------------------------
   SECTION 2 — AVATAR-SPECIFIC FLOWS
   release / pass / yank, plus the Lockmeister grab/release
   entry points (LM is avatar-only). Coffle and post share the
   unified claimLeash above; mode-specific *Internal functions
   no longer exist.
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

    // Reset to avatar mode (if was in coffle/post, revert to standard
    // leashing). Pass = full transfer of both controller and follow target.
    setLeashState(new_leasher, new_leasher, TRUE, MODE_AVATAR);

    // Start holder handshake for new leasher
    sendProtoStart(new_leasher);

    // Update Lockmeister authorization
    AuthorizedLmController = new_leasher;
    setLockmeisterState(TRUE, new_leasher);

    // Re-issue RLV @follow against the new leasher. setLeashState updates
    // Leasher, but the existing follow rule still points at old_leasher
    // until startFollow re-emits @follow:<key>=force.
    startFollow();

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
        // Physics yank: pull hard, but register an llTarget so at_target
        // releases llMoveToTarget the moment the wearer arrives. Without
        // this, the move target persists indefinitely and anchors the
        // wearer to the leasher's exact position.
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

// Lockmeister grab notification from particles module. LM is avatar-only,
// so accepting a controller flips us into MODE_AVATAR with that controller
// as the new leasher. Authorization is verified in the link_message handler
// before this is called.
handleLmGrabbed(key controller) {
    if (Leashed) return;
    setLeashState(controller, controller, TRUE, MODE_AVATAR);
    startFollow();
    llRegionSayTo(llGetOwner(), 0, "Leashed by " + llKey2Name(controller) + " (Lockmeister)");
}

handleLmReleased() {
    if (!Leashed) return;
    key old_leasher = Leasher;
    clearLeashState(TRUE);
    llRegionSayTo(llGetOwner(), 0, "Released by " + llKey2Name(old_leasher) + " (Lockmeister)");
}


/* ------------------------------------------------------------
   SECTION 3 — EVENT HANDLERS
   ------------------------------------------------------------ */

default
{
    state_entry() {
        if (llGetObjectDesc() == "COLLAR_UPDATER") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        HolderTarget = NULL_KEY;
        clearPendingAction();
        AuthorizedLmController = NULL_KEY;

        // Handshake listeners are owned by kmod_leash_proto; engine has
        // no llListen of its own. Tell proto to start clean in case it
        // had stale state from before our reset.
        sendProtoShutdown();

        applySettingsSync();
        llSetTimerEvent(FOLLOW_TICK);
        llRequestPermissions(llGetOwner(), PERMISSION_TAKE_CONTROLS);
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    run_time_permissions(integer perm) {
        if (perm & PERMISSION_TAKE_CONTROLS) {
            ControlsOk = TRUE;
            // Baseline mask: ML_LBUTTON only — keeps the takecontrols-
            // sticky exemption alive so every script in this prim survives
            // on no-script parcels. updateControlsMask() then expands the
            // mask to include directional keys if we should already be in
            // an at-limit/yanking state.
            llTakeControls(CONTROL_ML_LBUTTON, FALSE, TRUE);
            ControlsExpanded = FALSE;
            updateControlsMask();
        }
    }

    control(key id, integer level, integer edge) {
        if (!Leashed) return;
        integer pressed = level & edge;
        integer directional = CONTROL_FWD | CONTROL_BACK
                            | CONTROL_LEFT | CONTROL_RIGHT
                            | CONTROL_ROT_LEFT | CONTROL_ROT_RIGHT;
        if ((pressed & directional) == 0) return;

        key follow_target = leashFollowTarget();
        if (follow_target == NULL_KEY) return;

        key target_key = follow_target;
        if (HolderTarget != NULL_KEY) target_key = HolderTarget;

        list details = llGetObjectDetails(target_key, [OBJECT_POS]);
        if (llGetListLength(details) == 0) return;
        vector target_pos = llList2Vector(details, 0);

        vector wearer_pos = llGetRootPosition();
        float distance = llVecDist(wearer_pos, target_pos);
        if (distance < (float)LeashLength) return;

        // Soft corrective pull — same geometry as followTick (0.85 * length
        // toward the anchor, tau 1.0). Bridges the 1Hz follow tick so the
        // wearer can't sprint past the limit between ticks; also serves as
        // the only correction in post mode (no RLV @follow) and as a
        // non-RLV fallback in avatar/coffle.
        vector pull_pos = target_pos + llVecNorm(wearer_pos - target_pos) * (float)LeashLength * 0.85;
        llMoveToTarget(pull_pos, 1.0);
        LastTargetPos = pull_pos;
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            // Owner-change wipe / external soft reset from collar_kernel.
            // Just llResetScript — clears in-memory leash/coffle state.
            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
            return;
        }

        if (num == UI_BUS) {

            // Commands from config plugin — gated by ACL via requestAclForAction
            if (msg_type == "plugin.leash.action") {
                string action = jsonGet(msg, "action", "");
                if (action == "") return;
                key user = id;

                // Query state doesn't need ACL
                if (action == "query_state") {
                    broadcastState();
                    return;
                }

                // Yank only works for current leasher (with rate limiting)
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

                // All other actions require ACL verification
                key target = (key)jsonGet(msg, "target", (string)NULL_KEY);

                // Special case: set_length repurposes target field for length value
                if (action == "set_length") {
                    target = (key)jsonGet(msg, "length", "0");
                }
                // Special case: set_texture repurposes target field for the
                // texture style string. (string)(key)"chain" round-trips
                // intact because LSL keys are string-backed.
                else if (action == "set_texture") {
                    target = (key)jsonGet(msg, "texture", "chain");
                }

                requestAclForAction(user, action, target);
                return;
            }

            // Emergency release from SOS plugin
            if (msg_type == "sos.leash.release") {
                // Verify sender is owner/wearer to prevent abuse
                if (id == llGetOwner()) {
                    releaseLeashInternal(id);
                }
                return;
            }

            // Lockmeister notifications from particles — verify the controller
            // matches the one we initiated the LM handshake for, then dispatch
            // into the avatar-mode helpers.
            if (msg_type == "particles.lm.grabbed") {
                key controller = (key)jsonGet(msg, "controller", (string)NULL_KEY);
                if (controller == NULL_KEY) return;
                if (controller != AuthorizedLmController) return;
                handleLmGrabbed(controller);
                return;
            }

            if (msg_type == "particles.lm.released") {
                handleLmReleased();
                return;
            }
            return;
        }

        if (num == AUTH_BUS) {
            if (msg_type == "auth.acl.result") {
                handleAclResult(msg);
            }
            return;
        }

        if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync") {
                applySettingsSync();
            }
            else if (msg_type == "leash.proto.holder") {
                // kmod_leash_proto found a leashpoint — pin it.
                // Drop the message if we're no longer leashed: proto can
                // emit a late holder after an Unclip/release because LSL
                // discards pending events when proto state-changes, so a
                // queued proto.shutdown can be lost and the handshake
                // continues in the background until natural timeout.
                if (!Leashed) return;
                HolderTarget = (key)jsonGet(msg, "holder", (string)NULL_KEY);
                if (HolderTarget != NULL_KEY) setParticlesState(TRUE, HolderTarget);
            }
            else if (msg_type == "leash.proto.fallback") {
                // Handshake timed out — particles aim at the raw mode
                // anchor (proto picked it). HolderTarget stays NULL_KEY
                // so followTick falls back to leashFollowTarget too.
                // Same stale-message guard as proto.holder above.
                if (!Leashed) return;
                key fallback = (key)jsonGet(msg, "target", (string)NULL_KEY);
                if (fallback != NULL_KEY) setParticlesState(TRUE, fallback);
            }
            return;
        }
    }

    timer() {
        TickCount++;
        // Check for offsim/auto-release (~4s cadence at 1.0s FOLLOW_TICK)
        if (((integer)TickCount % 4) == 0) {
            if (Leashed) checkLeasherPresence();
            if (!Leashed && ReclipScheduled != 0) checkAutoReclip();
        }

        // Re-acquire a leashpoint every ~10s when we're leashed but have
        // fallen through to the avatar/root (HolderTarget cleared by a
        // detach, or initial handshake never found one). Asks proto to
        // re-run the handshake; proto handles its own state idempotently.
        if (((integer)TickCount % 10) == 0) {
            if (Leashed && HolderTarget == NULL_KEY && Leasher != NULL_KEY) {
                sendProtoStart(Leasher);
            }
        }

        // Follow tick
        if (FollowActive && Leashed) followTick();
    }

    at_target(integer tnum, vector target_pos, vector my_pos) {
        // Yank arrival: release the physics hold so the wearer is not
        // anchored to the leasher's exact position after a yank.
        if (tnum == YankTargetHandle) {
            llTargetRemove(YankTargetHandle);
            YankTargetHandle = 0;
            llStopMoveToTarget();
            LastTargetPos = ZERO_VECTOR;
            updateControlsMask();
        }
    }
}

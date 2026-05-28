/*--------------------
MODULE: kmod_particles.lsl
VERSION: 1.10
REVISION: 18
PURPOSE: Visual connection renderer with Lockmeister compatibility
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- v1.1 rev 18: Add INVISIBLE_TEXTURE (fully-transparent library texture) as a third ParticleStyle. render_leash_particles routes "invisible" to that UUID; particle system still emits (FOLLOW_SRC + TARGET_POS keep tethering math live), just renders nothing. Picked over alpha=0 to avoid any residual ribbon/sprite trail artifacts at very small alpha thresholds.
- v1.1 rev 17: Add SILK_TEXTURE alongside CHAIN_TEXTURE; render_leash_particles (renamed from render_chain_particles) now picks the texture from ParticleStyle ("chain" / "silk", default "chain"). handle_particles_start parses the requested style up-front so the idempotence guard can detect a style change and re-render on chain↔silk swap. All other particle knobs remain shared across styles.
- v1.1 rev 16: Swap CHAIN_*_SCALE X/Y. FOLLOW_VELOCITY aligns the
  particle's Y axis to motion, so link length goes on Y not X.
- v1.1 rev 15: Switch chain from ribbon mode to a regular particle
  stream. Drops PSYS_PART_RIBBON_MASK, adds PSYS_PART_FOLLOW_VELOCITY_MASK
  so each chain-link sprite orients along its motion vector. Eliminates
  the ribbon-specific artifacts that drove revs 9–14: target-movement
  segment-stretching, fresh-ribbon source→target snap, source-velocity
  trail spacing. Each particle now course-corrects independently under
  TARGET_POS instead of as a connected strip. Tradeoff: chain reads as
  a stream of discrete link sprites rather than a continuous textured
  ribbon. Tuning: BURST_RATE 0.0→0.02, MAX_AGE 3.0→2.0, SCALE
  rectangular for FOLLOW_VELOCITY orientation, ACCEL -1.0→-1.5.
- v1.1 rev 14: Restore PSYS_PART_FOLLOW_SRC_MASK — rev 13 removal was
  wrong direction. Without FOLLOW_SRC, alive particles stay in
  worldspace where they were emitted, so a moving wearer produces a
  trail of emission points near the leashpoint that ribbon-stretches
  between them (spacing = wearer-velocity × emission-interval). With
  FOLLOW_SRC restored, alive particles translate with source as it
  moves; chain shape is computed in source's reference frame, no
  trail artifact. Matches the slua reference (no complaints there).
- v1.1 rev 13: Drop PSYS_PART_FOLLOW_SRC_MASK from chain flags. Strays
  correlated with wearer movement: FOLLOW_SRC translates every alive
  particle by source_delta when the source moves, so the oldest
  particles (near target) get yanked with the wearer; TARGET_POS then
  fights to re-acquire the target each frame, manifesting as a
  straight-line snap from leashpoint to holder. Without FOLLOW_SRC,
  alive particles stay in worldspace — the chain lags slightly behind
  a moving wearer but settles smoothly under TARGET_POS alone, no
  conflict.
- v1.1 rev 12: handle_particles_start idempotence guard. Was unconditionally
  re-issuing llLinkParticleSystem on every particles.start, which reset
  the ribbon — for ~tens of ms after each reset only 1-2 particles
  exist, and TARGET_POS pulls them straight at the holder, rendering as
  a stretched straight segment. kmod_leash fires particles.start
  multiple times (native + OC responders, 10s re-handshake), so the
  user saw recurring straight-line strays. Now skips re-render when
  source/target/active state are unchanged. handle_particles_update
  already had this guard.
- v1.1 rev 11: Adopt LSL wiki catenary recipe — BURST_RATE 0.015→0.0
  (max sim emission), MAX_AGE 1.125→3.0 (TARGET_POS uses lifetime as
  travel time, so longer life lets each particle traverse src→target
  fully), ACCEL -2.0→-1.0 (gentle sag without overwhelming TARGET_POS
  correction). Ribbon Z scale 0.05→0.0 per LSL convention.
- v1.1 rev 10: Hoist chain particle knobs into top-level constants
  (CHAIN_BURST_RATE, CHAIN_MAX_AGE, CHAIN_ACCEL, etc.). Soften
  gravity from -3.95→-2.0 to reduce ribbon stretching.
- v1.1 rev 9: Drop PSYS_PART_FOLLOW_VELOCITY_MASK from chain flags. Per
  the LSL wiki it has no effect on ribbon-mode particles, but a particle
  that occasionally escapes ribbon rendering would fall back to
  FOLLOW_VELOCITY orientation — drawn as an elongated streak along its
  velocity. That matches the "stray straight particle" symptom seen
  alongside the ribbon. Removing the flag eliminates the fallback path.
- v1.1 rev 8: Retune chain particles — burst rate 0.05→0.015, scale
  0.06→0.05, max_age 1.5→1.125, accel z -1.75→-3.95 (denser, snappier
  fall with shorter trail).
- v1.1 rev 7: Reviewed burst and scale for particles.
- v1.1 rev 6: Add dormancy guard in state_entry — script parks itself
  if the prim's object description is "COLLAR_UPDATER" so it stays dormant
  when staged in an updater installer prim.
- v1.1 rev 5: Stop orphaning the rendering slot when the target goes
  transiently missing. Periodic validation used to clear SourcePlugin
  alongside TargetKey, which left a subsequent particles.stop with a
  source mismatch — so unclip couldn't clear particles after a holder
  detach/update cycle. Now we stop rendering but keep SourcePlugin so
  the source plugin retains ownership and its stop succeeds. Also
  restart the validation timer in handle_particles_update so a renderer
  that resumes after a target-gone gap still gets periodic checks.
  Drops rev 4 temporary diagnostic (regression was a sim crash).
- v1.1 rev 4: Temporary diagnostic llOwnerSay in handle_particles_start —
  remove once particles regression is resolved.
- v1.1 rev 3: Sub-protocol rename (Phase 1). particles.lmenable→
  particles.lm.enable, particles.lmdisable→particles.lm.disable,
  particles.lmgrabbed→particles.lm.grabbed, particles.lmreleased→
  particles.lm.released.
- v1.1 rev 2: KERNEL_LIFECYCLE rename (Phase 1). kernel.reset→
  kernel.reset.soft, kernel.resetall→kernel.reset.factory.
- v1.1 rev 1: Namespace pass — align message vocabulary with dev peers
  (particles.*, kernel.*) and update the native-priority source match from
  "core_leash" to "ui.core.leash" to track kmod_leash's PLUGIN_CONTEXT.
- v1.1 rev 0: Version bump for LSD policy architecture. No functional changes to this module.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;

/* -------------------- CONSTANTS -------------------- */
float PARTICLE_UPDATE_RATE = 0.25;  // Update every 0.5 seconds

// Lockmeister protocol
integer LEASH_CHAN_LM = -8888;
integer LM_PING_INTERVAL = 8;  // Ping every 8 seconds

/* -------------------- LEASH PARTICLE TUNING -------------------- */
// Visual knobs for the leash particle stream. Edit these without
// touching render_leash_particles. Uses a regular (non-ribbon) particle
// stream: each particle is an independent sprite oriented along its
// motion vector by FOLLOW_VELOCITY. TARGET_POS pulls each particle
// toward the holder over its lifetime; ACCEL adds gravity for catenary
// sag. No ribbon-mode connectivity, so target movement makes each
// particle individually course-correct — no segment-stretch snap.
//
// Texture is style-selected at render time (CHAIN_TEXTURE / SILK_TEXTURE);
// all other knobs are shared. If a future style needs different scale /
// accel / age, fork the relevant constant into a per-style pair and
// branch in render_leash_particles.
string   CHAIN_TEXTURE     = "ebe48305-8955-2b27-7656-3c39cee2cc1b";
string   SILK_TEXTURE      = "78ce70e9-b10d-3650-a54c-aca6bdc9cddb";
string   INVISIBLE_TEXTURE = "8dcd4a48-2d37-4909-9f78-f7a9eb4ef903";
float    CHAIN_BURST_RATE  = 0.02;                  // ~50 sprites/sec
integer  CHAIN_PART_COUNT  = 1;
float    CHAIN_MAX_AGE     = 2.0;                   // travel time src->target
vector   CHAIN_START_SCALE = <0.04, 0.10, 0.0>;     // Y aligns to motion (FOLLOW_VELOCITY)
vector   CHAIN_END_SCALE   = <0.04, 0.10, 0.0>;
vector   CHAIN_START_COLOR = <1.0, 1.0, 1.0>;
vector   CHAIN_END_COLOR   = <1.0, 1.0, 1.0>;
float    CHAIN_START_ALPHA = 1.0;
float    CHAIN_END_ALPHA   = 1.0;
vector   CHAIN_ACCEL       = <0.0, 0.0, -1.5>;      // gentle catenary sag

/* -------------------- STATE -------------------- */
integer ParticlesActive = FALSE;
key TargetKey = NULL_KEY;
string SourcePlugin = "";
string ParticleStyle = "chain";
integer LeashpointLink = 0;

// Lockmeister state
integer LmListen = 0;
integer LmActive = FALSE;
key LmController = NULL_KEY;  // Who is authorized to control the leash
key LmTargetPrim = NULL_KEY;  // Which prim we're leashing to
integer LmLastPing = 0;
integer LmAuthorized = FALSE;  // TRUE when leash module has activated LM mode

/* -------------------- HELPERS -------------------- */



integer now() {
    return llGetUnixTime();
}

// Helper to determine if timer should be running
integer needs_timer() {
    if (LmActive) return TRUE;  // Lockmeister needs pinging
    if (SourcePlugin != "" && ParticlesActive) return TRUE;  // native rendering active
    return FALSE;
}

/* -------------------- LOCKMEISTER PROTOCOL -------------------- */

open_lm_listen() {
    if (LmListen == 0) {
        LmListen = llListen(LEASH_CHAN_LM, "", NULL_KEY, "");
    }
}

close_lm_listen() {
    if (LmListen != 0) {
        llListenRemove(LmListen);
        LmListen = 0;
    }
}

lm_ping() {
    if (!LmActive || LmController == NULL_KEY) return;
    
    integer t = llGetUnixTime();
    if ((t - LmLastPing) < LM_PING_INTERVAL) return;
    LmLastPing = t;
    
    if (llGetAgentSize(LmController) != ZERO_VECTOR) {
        string wearer = (string)llGetOwner();
        llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "collar");
        llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "handle");
        llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "|LMV2|RequestPoint|handle");
        llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "|LMV2|RequestPoint|collar");
    }
}

handle_lm_message(key id, string msg) {
    key owner_key = llGetOwnerKey(id);
    
    // Lockmeister protocol sends: "<holder_uuid>handle ok" or "<holder_uuid>collar ok"
    // Or release: "<holder_uuid>handle free" or "<holder_uuid>collar free"
    // Extract the UUID from the first 36 characters
    string msg_uuid = llGetSubString(msg, 0, 35);
    string protocol = llGetSubString(msg, 36, -1);
    
    // Validate UUID format (basic check)
    if (llStringLength(msg_uuid) != 36) return;
    
    // Verify the UUID in message matches the object owner
    if ((key)msg_uuid != owner_key) {
        return;
    }
    
    // Handle explicit release commands
    if (protocol == "collar free" || protocol == "handle free") {
        if (LmActive && id == LmTargetPrim) {
            
            LmActive = FALSE;
            LmController = NULL_KEY;
            LmTargetPrim = NULL_KEY;
            LmAuthorized = FALSE;
            close_lm_listen();
            
            // Clear particles
            render_leash_particles(NULL_KEY);
            
            // Notify leash plugin
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "particles.lm.released"
            ]), NULL_KEY);
            
            // Stop timer if no other source active
            if (SourcePlugin == "lockmeister" || SourcePlugin == "") {
                SourcePlugin = "";
                TargetKey = NULL_KEY;
            }
            if (!needs_timer()) {
                llSetTimerEvent(0.0);
            }
        }
        return;
    }
    
    // Lockmeister grab response: "collar ok" or "handle ok"
    if (protocol == "collar ok" || protocol == "handle ok") {
        // Only accept if LM mode was activated by the leash module
        if (!LmAuthorized) {
            return;
        }
        
        // Only accept handles belonging to the expected controller
        if (LmController != NULL_KEY && owner_key != LmController) {
            return;
        }
        
        // If we're already locked onto a handle, ONLY accept responses from THAT handle
        if (LmActive && LmTargetPrim != NULL_KEY) {
            if (id != LmTargetPrim) {
                return;
            }
            // Same handle confirming - just update ping time
            LmLastPing = now();
            return;
        }
        
        
        // Priority check: If native is already rendering to a holder prim, don't override
        if (SourcePlugin == "ui.core.leash" && TargetKey != NULL_KEY) {
            // Check if current target is a prim (not avatar)
            if (llGetAgentSize(TargetKey) == ZERO_VECTOR) {
                return;
            }
        }
        
        // Start particles to the responding PRIM (not the owner avatar)
        LmActive = TRUE;
        LmController = owner_key;  // Track who controls it
        LmTargetPrim = id;         // Track the actual prim
        LmLastPing = now();
        
        TargetKey = id;  // Target the responding prim
        ParticlesActive = TRUE;
        SourcePlugin = "lockmeister";
        
        render_leash_particles(id);
        
        // Notify leash plugin
        string notify_msg = llList2Json(JSON_OBJECT, [
            "type", "particles.lm.grabbed",
            "controller", (string)owner_key,
            "prim", (string)id
        ]);
        llMessageLinked(LINK_SET, UI_BUS, notify_msg, NULL_KEY);
    }
}

/* -------------------- LEASHPOINT DETECTION -------------------- */

integer find_leashpoint_link() {
    integer i = 2;
    integer prim_count = llGetNumberOfPrims();
    
    while (i <= prim_count) {
        list params = llGetLinkPrimitiveParams(i, [PRIM_NAME, PRIM_DESC]);
        string name = llToLower(llStringTrim(llList2String(params, 0), STRING_TRIM));
        string desc = llToLower(llStringTrim(llList2String(params, 1), STRING_TRIM));
        
        if (name == "leashpoint" && desc == "leashpoint") {
            return i;
        }
        i = i + 1;
    }
    return LINK_ROOT;
}

/* -------------------- PARTICLE RENDERING -------------------- */

render_leash_particles(key target) {
    if (LeashpointLink == 0) {
        LeashpointLink = find_leashpoint_link();
    }

    if (target == NULL_KEY) {
        // Clear particles
        llLinkParticleSystem(LeashpointLink, []);
        ParticlesActive = FALSE;
        return;
    }

    // Pick the texture for the current style. Unknown styles fall back
    // to chain so a stale settings value doesn't blank the leash visual.
    // "invisible" uses a fully-transparent library texture so the particle
    // system still emits (tethering math stays live) but renders nothing.
    string texture = CHAIN_TEXTURE;
    if (ParticleStyle == "silk")           texture = SILK_TEXTURE;
    else if (ParticleStyle == "invisible") texture = INVISIBLE_TEXTURE;

    llLinkParticleSystem(LeashpointLink, [
        PSYS_SRC_PATTERN, PSYS_SRC_PATTERN_DROP,
        PSYS_SRC_TEXTURE, texture,
        PSYS_SRC_BURST_RATE, CHAIN_BURST_RATE,
        PSYS_SRC_BURST_PART_COUNT, CHAIN_PART_COUNT,
        PSYS_PART_START_ALPHA, CHAIN_START_ALPHA,
        PSYS_PART_END_ALPHA, CHAIN_END_ALPHA,
        PSYS_PART_MAX_AGE, CHAIN_MAX_AGE,
        PSYS_PART_START_SCALE, CHAIN_START_SCALE,
        PSYS_PART_END_SCALE, CHAIN_END_SCALE,
        PSYS_PART_START_COLOR, CHAIN_START_COLOR,
        PSYS_PART_END_COLOR, CHAIN_END_COLOR,
        PSYS_SRC_ACCEL, CHAIN_ACCEL,
        PSYS_PART_FLAGS,
            PSYS_PART_INTERP_COLOR_MASK |
            PSYS_PART_FOLLOW_SRC_MASK |
            PSYS_PART_FOLLOW_VELOCITY_MASK |
            PSYS_PART_TARGET_POS_MASK,
        PSYS_SRC_TARGET_KEY, target
    ]);
    
    ParticlesActive = TRUE;
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_particles_start(string msg) {
    if (llJsonGetValue(msg, ["source"]) == JSON_INVALID || llJsonGetValue(msg, ["target"]) == JSON_INVALID) {
        return;
    }

    string source = llJsonGetValue(msg, ["source"]);
    key target = (key)llJsonGetValue(msg, ["target"]);

    // Resolve the requested style up front so the idempotence guard can
    // include it — a style change (chain↔silk) must trigger re-render
    // even when source and target are unchanged.
    string new_style = "chain";
    string style_field = llJsonGetValue(msg, ["style"]);
    if (style_field != JSON_INVALID) new_style = style_field;

    // Idempotent: same source + target + same style + already rendering
    // → skip the re-issue. Each llLinkParticleSystem call resets the
    // particle system, and for the first few ms after a reset only 1-2
    // particles exist — TARGET_POS pulls them straight at the holder, so
    // the leasher sees a stretched straight segment between source and
    // target. kmod_leash fires particles.start multiple times during
    // handshake (native + OC responders, periodic re-handshake), so this
    // guard is load-bearing.
    if (ParticlesActive && SourcePlugin == source && TargetKey == target && ParticleStyle == new_style) {
        return;
    }

    // Validate target exists in-world
    list details = llGetObjectDetails(target, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        return;
    }

    // Priority: Lockmeister < native leash
    if (SourcePlugin == "lockmeister" && source == "ui.core.leash") {
        if (LmActive) {
            LmActive = FALSE;
            LmController = NULL_KEY;
            LmTargetPrim = NULL_KEY;
            LmAuthorized = FALSE;
            close_lm_listen();
        }
    }
    else if (SourcePlugin != "" && SourcePlugin != source) {
        return;
    }
    
    SourcePlugin = source;
    TargetKey = target;
    ParticleStyle = new_style;

    render_leash_particles(TargetKey);
    llSetTimerEvent(PARTICLE_UPDATE_RATE);
}

handle_particles_stop(string msg) {
    if (llJsonGetValue(msg, ["source"]) == JSON_INVALID) {
        return;
    }
    
    string source = llJsonGetValue(msg, ["source"]);
    
    // Only stop if request is from the same plugin that started it
    if (source != SourcePlugin) {
        return;
    }
    
    render_leash_particles(NULL_KEY);
    
    // Always clear source state when stopping
    SourcePlugin = "";
    TargetKey = NULL_KEY;
    
    // Stop timer if nothing needs it
    if (!needs_timer()) {
        llSetTimerEvent(0.0);
    }
}

handle_particles_update(string msg) {
    if (llJsonGetValue(msg, ["target"]) == JSON_INVALID) {
        return;
    }
    
    key new_target = (key)llJsonGetValue(msg, ["target"]);
    
    // Verify target is present in-world before rendering
    list details = llGetObjectDetails(new_target, [OBJECT_POS]);
    if (llGetListLength(details) == 0) {
        return;
    }
    
    if (new_target != TargetKey) {
        TargetKey = new_target;
        render_leash_particles(TargetKey);
        llSetTimerEvent(PARTICLE_UPDATE_RATE);
    }
}

handle_lm_enable(string msg) {
    // Enable Lockmeister listening
    if (llJsonGetValue(msg, ["controller"]) == JSON_INVALID) {
        return;
    }
    
    LmController = (key)llJsonGetValue(msg, ["controller"]);
    LmAuthorized = TRUE;  // Mark as authorized
    open_lm_listen();
    
    // Start pinging
    LmLastPing = now();
    llSetTimerEvent(PARTICLE_UPDATE_RATE);
    
}

handle_lm_disable() {
    close_lm_listen();
    
    // If Lockmeister was active, clear the particles
    if (LmActive) {
        LmActive = FALSE;
        LmController = NULL_KEY;
        LmTargetPrim = NULL_KEY;
        LmAuthorized = FALSE;
        
        // Clear particles if we were the active source
        if (SourcePlugin == "lockmeister") {
            render_leash_particles(NULL_KEY);
            SourcePlugin = "";
            TargetKey = NULL_KEY;
        }
    }
    
    LmAuthorized = FALSE;  // Clear authorization
    
    // Check if timer should stop
    if (!needs_timer()) {
        llSetTimerEvent(0.0);
    }
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        if (llGetObjectDesc() == "COLLAR_UPDATER") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        ParticlesActive = FALSE;
        TargetKey = NULL_KEY;
        SourcePlugin = "";
        LeashpointLink = 0;

        LmActive = FALSE;
        LmController = NULL_KEY;
        LmTargetPrim = NULL_KEY;
        LmAuthorized = FALSE;
        close_lm_listen();

        // Clear any leftover particles from before the reset
        render_leash_particles(NULL_KEY);
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            // Clear authorization before reset (defensive coding)
            LmAuthorized = FALSE;
            LmController = NULL_KEY;
            close_lm_listen();
            llResetScript();
        }
        
        // If linkset changed, re-detect leashpoint
        if (change & CHANGED_LINK) {
            LeashpointLink = 0;
            if (ParticlesActive) {
                LeashpointLink = find_leashpoint_link();
                render_leash_particles(TargetKey);
            }
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
            return;
        }

        // Only listen on UI_BUS
        if (num != UI_BUS) return;

        if (msg_type == "particles.start") {
            handle_particles_start(msg);
        }
        else if (msg_type == "particles.stop") {
            handle_particles_stop(msg);
        }
        else if (msg_type == "particles.update") {
            handle_particles_update(msg);
        }
        else if (msg_type == "particles.lm.enable") {
            handle_lm_enable(msg);
        }
        else if (msg_type == "particles.lm.disable") {
            handle_lm_disable();
        }
    }
    
    listen(integer channel, string name, key id, string msg) {
        if (channel == LEASH_CHAN_LM) {
            handle_lm_message(id, msg);
        }
    }
    
    timer() {
        // Lockmeister ping
        if (LmActive) {
            lm_ping();
        }
        
        // Periodic validation - verify target still exists
        if (ParticlesActive && TargetKey != NULL_KEY) {
            list details = llGetObjectDetails(TargetKey, [OBJECT_POS]);
            if (llGetListLength(details) == 0) {
                // Target disappeared (offsim, detached, or logged out).
                // Stop rendering, but do not clear SourcePlugin: the source
                // plugin still owns the rendering slot. Clearing it here
                // orphans a later particles.stop (source mismatch) and
                // leaves particles stuck if the source plugin sends a
                // follow-up particles.update with a fresh target.
                render_leash_particles(NULL_KEY);

                // If Lockmeister was active, stop it
                if (LmActive) {
                    LmActive = FALSE;
                    LmController = NULL_KEY;
                    LmTargetPrim = NULL_KEY;
                    LmAuthorized = FALSE;
                    close_lm_listen();

                    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                        "type", "particles.lm.released"
                    ]), NULL_KEY);
                }

                TargetKey = NULL_KEY;

                if (!needs_timer()) {
                    llSetTimerEvent(0.0);
                }
            }
        }
    }
}

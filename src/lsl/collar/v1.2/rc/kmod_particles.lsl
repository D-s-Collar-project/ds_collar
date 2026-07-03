/*--------------------
MODULE: kmod_particles.lsl
VERSION: 1.2
REVISION: 10
PURPOSE: Visual connection renderer with Lockmeister compatibility
CHANGES:
- v1.2 rev 10: tidy — handle_particles_start's style default is now the current ParticleStyle (the LSD-resolved value), not a hardcoded "chain", so a particles.start with no style field keeps the configured style instead of resetting to chain. Behaviour-identical in the normal flow (the engine always sends style).
- v1.2 rev 9: FIX — resetting this script alone (engine still leashed) brought the beam back as "chain", because ParticleStyle resets to its default and the Lockmeister re-render paints from it directly (no style field). state_entry now restores ParticleStyle from the persisted leash.texture, so an independent reset resumes the saved style.
- v1.2 rev 8: narrower leash beam — particle width (CHAIN_*_SCALE X) 0.04 → 0.025; segment length unchanged. Cosmetic.
- v1.2 rev 7: new particles.style message — a style-only update that repaints the CURRENT TargetKey (LM holder or native leashpoint) with a new style, without re-specifying a target. The leash engine sends this on a texture change instead of a full particles.start, which previously forced it to re-guess a target it doesn't own (the LM holder lives here as TargetKey) and snapped the beam to the avatar centre. No-op when nothing is rendering. Pairs with kmod_leash_engine rev 11.
- v1.2 rev 6: OC/LM holder discovery fixed. handle_lm_enable now fires the Lockmeister query IMMEDIATELY (it only opened the listen before — never asked, so a passive/self-keyed OpenCollar holder stayed silent and the engine's 2s deferred-restraint window denied it; the in-world trace showed zero -8888 outbound). New send_lm_query() also queries the HOLDER's key ("<holder>handle"/"collar"), not just the wearer's — an OC leash holder's `handle` listen is an exact match on its OWN owner key, so a wearer-keyed query never reached it. lm_ping routes through the same helper so the keep-alive re-queries the holder (whose own announce timer stops after a couple pulses).
- v1.2 rev 2: find_leashpoint_link matches "leashpoint" as a SUBSTRING of the prim description (was exact ==), so an OpenCollar leashpoint — whose desc carries a slew of config after the word "leashpoint" — is recognized. Engine's findLeashpointPrim updated to match.
- v1.2 rev 1: find_leashpoint_link now identifies the leashpoint prim by its DESCRIPTION == "leashpoint" (was name AND desc, which made a desc-only/name-only leashpoint fall through to LINK_ROOT — the beam emitted from the collar root instead of the ring). Matches the engine's findLeashpointPrim convention so both scripts emit from / dock at the same prim.
ARCHITECTURE: Consolidated message bus lanes
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
// branch in render_leash_particles. The "invisible" style draws no
// particles at all (handled in render_leash_particles), so it has no texture.
string   CHAIN_TEXTURE     = "ebe48305-8955-2b27-7656-3c39cee2cc1b";
string   SILK_TEXTURE      = "78ce70e9-b10d-3650-a54c-aca6bdc9cddb";
float    CHAIN_BURST_RATE  = 0.02;                  // ~50 sprites/sec
integer  CHAIN_PART_COUNT  = 1;
float    CHAIN_MAX_AGE     = 2.0;                   // travel time src->target
vector   CHAIN_START_SCALE = <0.035, 0.10, 0.0>;    // X = beam width, Y = segment length (aligns to motion, FOLLOW_VELOCITY)
vector   CHAIN_END_SCALE   = <0.035, 0.10, 0.0>;
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

// Send the Lockmeister point query to the controller. Two key conventions:
//   • WEARER-keyed (standard Lockmeister: the leashed avatar's own points).
//   • HOLDER-keyed: an OpenCollar leash holder advertises/answers about its OWN
//     owner (its `handle` listen is an exact match on "<holder>handle"), so a
//     query keyed to the wearer never reaches it. Querying the holder's key is
//     what makes a self-keyed OC handle respond "<holder>handle ok".
send_lm_query() {
    if (LmController == NULL_KEY) return;
    if (llGetAgentSize(LmController) == ZERO_VECTOR) return;
    string wearer = (string)llGetOwner();
    string holder = (string)LmController;
    llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "collar");
    llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "handle");
    llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "|LMV2|RequestPoint|handle");
    llRegionSayTo(LmController, LEASH_CHAN_LM, wearer + "|LMV2|RequestPoint|collar");
    llRegionSayTo(LmController, LEASH_CHAN_LM, holder + "collar");
    llRegionSayTo(LmController, LEASH_CHAN_LM, holder + "handle");
}

lm_ping() {
    if (!LmActive || LmController == NULL_KEY) return;

    integer t = llGetUnixTime();
    if ((t - LmLastPing) < LM_PING_INTERVAL) return;
    LmLastPing = t;

    send_lm_query();
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
        // Leashpoint prim = "leashpoint" appearing ANYWHERE in its DESCRIPTION
        // (substring, not an exact match — OpenCollar's leashpoint desc carries
        // a slew of config after the word). Same convention as the engine's
        // findLeashpointPrim so both pick the same prim.
        list params = llGetLinkPrimitiveParams(i, [PRIM_DESC]);
        string desc = llToLower(llList2String(params, 0));
        if (llSubStringIndex(desc, "leashpoint") != -1) {
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

    // No target, OR the "invisible" style: emit nothing. The leash's tether
    // (RLV @follow + llMoveToTarget length enforcement) lives entirely in
    // kmod_leash_engine and is independent of this particle stream, so an
    // invisible leash still follows/yanks/limits exactly like a visible one —
    // it just draws no particles. This is cheaper and more reliable than a
    // transparent-texture particle (no library-asset fetch, no blend-mode
    // edge cases: SL's default particle blend shows a texture's RGB unless it
    // is truly alpha-0 in every viewer).
    if (target == NULL_KEY || ParticleStyle == "invisible") {
        llLinkParticleSystem(LeashpointLink, []);
        ParticlesActive = FALSE;
        return;
    }

    // Pick the texture for the current style. Unknown styles fall back
    // to chain so a stale settings value doesn't blank the leash visual.
    string texture = CHAIN_TEXTURE;
    if (ParticleStyle == "silk") texture = SILK_TEXTURE;

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
    // Default to the current/configured style (LSD-resolved), not a hardcoded
    // "chain": a particles.start with no style field must never reset a
    // configured leash back to chain — it keeps whatever is already set.
    string new_style = ParticleStyle;
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
    // The invisible style renders nothing (ParticlesActive stays FALSE), so
    // there's no stream to validate each tick — only arm the timer when work
    // remains (live particles or a Lockmeister ping). Avoids a 0.25s no-op spin.
    if (needs_timer()) llSetTimerEvent(PARTICLE_UPDATE_RATE);
    else               llSetTimerEvent(0.0);
}

// Style-only update: change the leash texture on the CURRENT beam without
// re-specifying a target. kmod_particles owns the live target (the Lockmeister
// holder or the native leashpoint), so the leash engine must NOT re-guess it on
// a texture change — doing so snapped a Lockmeister beam to the avatar centre.
// Re-renders the existing TargetKey with the new style; no-op if nothing is up.
handle_particles_style(string msg) {
    string style_field = llJsonGetValue(msg, ["style"]);
    if (style_field == JSON_INVALID) return;
    if (style_field == ParticleStyle) return;
    ParticleStyle = style_field;
    if (TargetKey != NULL_KEY) {
        render_leash_particles(TargetKey);
        if (needs_timer()) llSetTimerEvent(PARTICLE_UPDATE_RATE);
        else               llSetTimerEvent(0.0);
    }
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

    // Fire the discovery query NOW (this was missing — the listen opened but we
    // never asked, so a passive/self-keyed OC holder stayed silent and the
    // deferred-restraint window denied it). One region-wide query reaches the
    // holder immediately; a present one answers well inside the deny window.
    send_lm_query();

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

        ParticlesActive = FALSE;
        TargetKey = NULL_KEY;
        SourcePlugin = "";
        LeashpointLink = 0;

        LmActive = FALSE;
        LmController = NULL_KEY;
        LmTargetPrim = NULL_KEY;
        LmAuthorized = FALSE;
        close_lm_listen();

        // Restore the persisted leash style so a re-render after an INDEPENDENT
        // reset of this script (the engine still leashed) uses the saved texture,
        // not the default. Matters for the Lockmeister path, which paints from
        // ParticleStyle directly (no style field) — without this it came back chain.
        string saved_style = llLinksetDataRead("leash.texture");
        if (saved_style == "chain" || saved_style == "silk" || saved_style == "invisible") {
            ParticleStyle = saved_style;
        }

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
        else if (msg_type == "particles.style") {
            handle_particles_style(msg);
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

--[[--------------------
MODULE: kmod_particles.lua  (SLua port)
VERSION: 1.2
REVISION: 6  (SLua port rev 1)
PURPOSE: Visual connection (leash particle) renderer with Lockmeister/OpenCollar
         holder compatibility. Owns the leashpoint particle stream and the -8888
         Lockmeister handshake; the tether physics live in kmod_leash_engine.
ARCHITECTURE: Consolidated message bus lanes.

SLUA PORT NOTES:
- Ported from kmod_particles.lsl v1.2 rev 6. Wire protocol preserved exactly: it
  consumes particles.start / particles.stop / particles.update / particles.lm.enable
  / particles.lm.disable on UI_BUS 900 and the raw Lockmeister chatter on the -8888
  channel, and emits particles.lm.grabbed / particles.lm.released. JSON shapes and
  the LM string protocol ("<uuid>collar/handle ok/free", "<uuid>|LMV2|RequestPoint|..")
  are byte-identical, so OC/LM holders interoperate unchanged.
- GOTCHA: vectors. The particle tuning constants and the ZERO_VECTOR presence
  checks use SLua's native vector type, constructed with vector.create(x, y, z).
  `== ZERO_VECTOR` equality is the not-an-avatar test, unchanged from the LSL.
  (Vector construction is one of the SLua runtime details that only in-world
  testing fully confirms.)
- GOTCHA: single dynamic timer. LSL's llSetTimerEvent(rate) / llSetTimerEvent(0)
  becomes the set_timer shim over LLTimers (start/replace/stop); needs_timer()
  gates it exactly as the LSL, so the 0.25s ping+validate tick only runs while
  there's live work.
- The PSYS_PART_FLAGS bitmask is bit32.bor; the particle rule list is one flat Lua
  table of {key, value, ...} (vectors / keys / floats / ints interleaved) handed to
  ll.LinkParticleSystem, mirroring the LSL rule list.
- ll.Listen on -8888 carries the Lockmeister protocol; uuid() normalizes the JSON
  and protocol UUID strings to keys. ll.GetLinkPrimitiveParams returns a 1-based
  table (params[1] is PRIM_DESC).
- Events are top-level LLEvents.*; state_entry becomes main(), called at the bottom.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local UI_BUS           = 900

--[[ -------------------- CONSTANTS -------------------- ]]
local PARTICLE_UPDATE_RATE = 0.25  -- ping/validate tick

-- Lockmeister protocol
local LEASH_CHAN_LM   = -8888
local LM_PING_INTERVAL = 8         -- ping every 8 seconds

--[[ -------------------- LEASH PARTICLE TUNING -------------------- ]]
-- Regular (non-ribbon) particle stream: each sprite is oriented along its motion
-- (FOLLOW_VELOCITY) and pulled toward the holder over its lifetime (TARGET_POS),
-- with ACCEL adding catenary sag. Texture is style-selected at render time; the
-- "invisible" style draws nothing (the tether still follows/limits via the engine).
local CHAIN_TEXTURE     = "ebe48305-8955-2b27-7656-3c39cee2cc1b"
local SILK_TEXTURE      = "78ce70e9-b10d-3650-a54c-aca6bdc9cddb"
local CHAIN_BURST_RATE  = 0.02                          -- ~50 sprites/sec
local CHAIN_PART_COUNT  = 1
local CHAIN_MAX_AGE     = 2.0                           -- travel time src->target
local CHAIN_START_SCALE = vector.create(0.04, 0.10, 0.0) -- Y aligns to motion
local CHAIN_END_SCALE   = vector.create(0.04, 0.10, 0.0)
local CHAIN_START_COLOR = vector.create(1.0, 1.0, 1.0)
local CHAIN_END_COLOR   = vector.create(1.0, 1.0, 1.0)
local CHAIN_START_ALPHA = 1.0
local CHAIN_END_ALPHA   = 1.0
local CHAIN_ACCEL       = vector.create(0.0, 0.0, -1.5)  -- gentle catenary sag

--[[ -------------------- STATE -------------------- ]]
local ParticlesActive = false
local TargetKey       = NULL_KEY
local SourcePlugin    = ""
local ParticleStyle   = "chain"
local LeashpointLink  = 0

-- Lockmeister state
local LmListen     = 0
local LmActive     = false
local LmController = NULL_KEY  -- who is authorized to control the leash
local LmTargetPrim = NULL_KEY  -- which prim we're leashing to
local LmLastPing   = 0
local LmAuthorized = false     -- TRUE once the leash module activated LM mode

--[[ -------------------- TIMER SHIM (single dynamic timer) -------------------- ]]
-- set_timer(rate>0) starts/replaces the one tick timer; set_timer(0) stops it.
-- _on_timer (the tick body) is forward-declared and assigned far below.
local _timerHandle = nil
local _on_timer
local function set_timer(interval: number)
    if _timerHandle then
        LLTimers:off(_timerHandle)
        _timerHandle = nil
    end
    if interval > 0 then
        _timerHandle = LLTimers:every(interval, _on_timer)
    end
end

--[[ -------------------- HELPERS -------------------- ]]

local function now(): number
    return ll.GetUnixTime()
end

-- Whether the tick timer should be running.
local function needs_timer(): boolean
    if LmActive then return true end                          -- LM needs pinging
    if SourcePlugin ~= "" and ParticlesActive then return true end  -- native render live
    return false
end

--[[ -------------------- LOCKMEISTER PROTOCOL -------------------- ]]

local function open_lm_listen()
    if LmListen == 0 then
        LmListen = ll.Listen(LEASH_CHAN_LM, "", NULL_KEY, "")
    end
end

local function close_lm_listen()
    if LmListen ~= 0 then
        ll.ListenRemove(LmListen)
        LmListen = 0
    end
end

-- Send the Lockmeister point query, keyed BOTH to the wearer (standard LM) and to
-- the holder's own key (an OC leash holder answers about its OWN owner — its
-- `handle` listen is an exact match on "<holder>handle", so a wearer-keyed query
-- never reaches it).
local function send_lm_query()
    if LmController == NULL_KEY then return end
    if ll.GetAgentSize(LmController) == ZERO_VECTOR then return end
    local wearer = tostring(ll.GetOwner())
    local holder = tostring(LmController)
    ll.RegionSayTo(LmController, LEASH_CHAN_LM, wearer .. "collar")
    ll.RegionSayTo(LmController, LEASH_CHAN_LM, wearer .. "handle")
    ll.RegionSayTo(LmController, LEASH_CHAN_LM, wearer .. "|LMV2|RequestPoint|handle")
    ll.RegionSayTo(LmController, LEASH_CHAN_LM, wearer .. "|LMV2|RequestPoint|collar")
    ll.RegionSayTo(LmController, LEASH_CHAN_LM, holder .. "collar")
    ll.RegionSayTo(LmController, LEASH_CHAN_LM, holder .. "handle")
end

local function lm_ping()
    if not LmActive or LmController == NULL_KEY then return end
    local t = ll.GetUnixTime()
    if (t - LmLastPing) < LM_PING_INTERVAL then return end
    LmLastPing = t
    send_lm_query()
end

--[[ -------------------- LEASHPOINT DETECTION -------------------- ]]

-- Leashpoint prim = "leashpoint" appearing ANYWHERE in its description (substring,
-- matching OC's config-laden desc and the engine's findLeashpointPrim). LINK_ROOT
-- if none.
local function find_leashpoint_link(): number
    local prim_count = ll.GetNumberOfPrims()
    local i = 2
    while i <= prim_count do
        local params = ll.GetLinkPrimitiveParams(i, {PRIM_DESC})
        local desc = ll.ToLower(params[1] or "")
        if ll.SubStringIndex(desc, "leashpoint") ~= -1 then
            return i
        end
        i = i + 1
    end
    return LINK_ROOT
end

--[[ -------------------- PARTICLE RENDERING -------------------- ]]

local function render_leash_particles(target)
    if LeashpointLink == 0 then
        LeashpointLink = find_leashpoint_link()
    end

    -- No target, OR the "invisible" style: emit nothing. The tether (RLV @follow +
    -- llMoveToTarget) is independent of this stream, so an invisible leash still
    -- follows/yanks/limits — it just draws no particles.
    if target == NULL_KEY or ParticleStyle == "invisible" then
        ll.LinkParticleSystem(LeashpointLink, {})
        ParticlesActive = false
        return
    end

    -- Texture per style; unknown styles fall back to chain so a stale settings value
    -- doesn't blank the visual.
    local texture = CHAIN_TEXTURE
    if ParticleStyle == "silk" then texture = SILK_TEXTURE end

    ll.LinkParticleSystem(LeashpointLink, {
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
        PSYS_PART_FLAGS, bit32.bor(
            PSYS_PART_INTERP_COLOR_MASK,
            PSYS_PART_FOLLOW_SRC_MASK,
            PSYS_PART_FOLLOW_VELOCITY_MASK,
            PSYS_PART_TARGET_POS_MASK),
        PSYS_SRC_TARGET_KEY, target,
    })

    ParticlesActive = true
end

--[[ -------------------- LOCKMEISTER MESSAGE -------------------- ]]

local function handle_lm_message(id, msg: string)
    local owner_key = ll.GetOwnerKey(id)

    -- "<holder_uuid>handle ok/free" / "<holder_uuid>collar ok/free": UUID is the
    -- first 36 chars, protocol the remainder.
    local msg_uuid = ll.GetSubString(msg, 0, 35)
    local protocol = ll.GetSubString(msg, 36, -1)

    if ll.StringLength(msg_uuid) ~= 36 then return end
    if uuid(msg_uuid) ~= owner_key then return end

    -- Explicit release.
    if protocol == "collar free" or protocol == "handle free" then
        if LmActive and id == LmTargetPrim then
            LmActive = false
            LmController = NULL_KEY
            LmTargetPrim = NULL_KEY
            LmAuthorized = false
            close_lm_listen()
            render_leash_particles(NULL_KEY)
            ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
                "type", "particles.lm.released",
            }), NULL_KEY)
            if SourcePlugin == "lockmeister" or SourcePlugin == "" then
                SourcePlugin = ""
                TargetKey = NULL_KEY
            end
            if not needs_timer() then set_timer(0) end
        end
        return
    end

    -- Grab response.
    if protocol == "collar ok" or protocol == "handle ok" then
        if not LmAuthorized then return end
        -- Only handles belonging to the expected controller.
        if LmController ~= NULL_KEY and owner_key ~= LmController then return end
        -- Already locked onto a handle: only accept from THAT handle (else re-ping).
        if LmActive and LmTargetPrim ~= NULL_KEY then
            if id ~= LmTargetPrim then return end
            LmLastPing = now()
            return
        end
        -- Priority: don't override native rendering to a holder PRIM.
        if SourcePlugin == "ui.core.leash" and TargetKey ~= NULL_KEY then
            if ll.GetAgentSize(TargetKey) == ZERO_VECTOR then return end
        end

        LmActive = true
        LmController = owner_key
        LmTargetPrim = id
        LmLastPing = now()
        TargetKey = id
        ParticlesActive = true
        SourcePlugin = "lockmeister"
        render_leash_particles(id)
        ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "particles.lm.grabbed",
            "controller", tostring(owner_key),
            "prim", tostring(id),
        }), NULL_KEY)
    end
end

--[[ -------------------- MESSAGE HANDLERS -------------------- ]]

local function handle_particles_start(msg: string)
    if ll.JsonGetValue(msg, {"source"}) == JSON_INVALID or ll.JsonGetValue(msg, {"target"}) == JSON_INVALID then
        return
    end

    local source = ll.JsonGetValue(msg, {"source"})
    local target = uuid(ll.JsonGetValue(msg, {"target"}))

    -- Resolve style up front so the idempotence guard includes it (a chain<->silk
    -- change must re-render even at the same source+target).
    local new_style = "chain"
    local style_field = ll.JsonGetValue(msg, {"style"})
    if style_field ~= JSON_INVALID then new_style = style_field end

    -- Idempotent: same source + target + style + already rendering -> skip. Each
    -- ll.LinkParticleSystem resets the stream (briefly a 1-2 sprite straight
    -- segment), and kmod_leash re-fires particles.start during handshakes, so this
    -- guard is load-bearing.
    if ParticlesActive and SourcePlugin == source and TargetKey == target and ParticleStyle == new_style then
        return
    end

    -- Validate target exists in-world.
    if #ll.GetObjectDetails(target, {OBJECT_POS}) == 0 then return end

    -- Priority: Lockmeister < native leash.
    if SourcePlugin == "lockmeister" and source == "ui.core.leash" then
        if LmActive then
            LmActive = false
            LmController = NULL_KEY
            LmTargetPrim = NULL_KEY
            LmAuthorized = false
            close_lm_listen()
        end
    elseif SourcePlugin ~= "" and SourcePlugin ~= source then
        return
    end

    SourcePlugin = source
    TargetKey = target
    ParticleStyle = new_style

    render_leash_particles(TargetKey)
    -- The invisible style renders nothing (ParticlesActive stays false); only arm
    -- the tick when work remains, avoiding a 0.25s no-op spin.
    if needs_timer() then set_timer(PARTICLE_UPDATE_RATE) else set_timer(0) end
end

local function handle_particles_stop(msg: string)
    if ll.JsonGetValue(msg, {"source"}) == JSON_INVALID then return end
    local source = ll.JsonGetValue(msg, {"source"})
    if source ~= SourcePlugin then return end  -- only the owning plugin may stop

    render_leash_particles(NULL_KEY)
    SourcePlugin = ""
    TargetKey = NULL_KEY
    if not needs_timer() then set_timer(0) end
end

local function handle_particles_update(msg: string)
    if ll.JsonGetValue(msg, {"target"}) == JSON_INVALID then return end
    local new_target = uuid(ll.JsonGetValue(msg, {"target"}))

    if #ll.GetObjectDetails(new_target, {OBJECT_POS}) == 0 then return end

    if new_target ~= TargetKey then
        TargetKey = new_target
        render_leash_particles(TargetKey)
        set_timer(PARTICLE_UPDATE_RATE)
    end
end

local function handle_lm_enable(msg: string)
    if ll.JsonGetValue(msg, {"controller"}) == JSON_INVALID then return end

    LmController = uuid(ll.JsonGetValue(msg, {"controller"}))
    LmAuthorized = true
    open_lm_listen()

    -- Fire the discovery query NOW so a passive/self-keyed OC holder answers well
    -- inside the engine's deferred-restraint window.
    send_lm_query()

    LmLastPing = now()
    set_timer(PARTICLE_UPDATE_RATE)
end

local function handle_lm_disable()
    close_lm_listen()

    if LmActive then
        LmActive = false
        LmController = NULL_KEY
        LmTargetPrim = NULL_KEY
        LmAuthorized = false
        if SourcePlugin == "lockmeister" then
            render_leash_particles(NULL_KEY)
            SourcePlugin = ""
            TargetKey = NULL_KEY
        end
    end

    LmAuthorized = false
    if not needs_timer() then set_timer(0) end
end

--[[ -------------------- TICK BODY -------------------- ]]

_on_timer = function()
    -- Lockmeister ping.
    if LmActive then lm_ping() end

    -- Periodic validation: verify the target still exists.
    if ParticlesActive and TargetKey ~= NULL_KEY then
        if #ll.GetObjectDetails(TargetKey, {OBJECT_POS}) == 0 then
            -- Target gone (offsim/detached/logged out). Stop rendering but keep
            -- SourcePlugin so a later particles.stop/update isn't orphaned.
            render_leash_particles(NULL_KEY)

            if LmActive then
                LmActive = false
                LmController = NULL_KEY
                LmTargetPrim = NULL_KEY
                LmAuthorized = false
                close_lm_listen()
                ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
                    "type", "particles.lm.released",
                }), NULL_KEY)
            end

            TargetKey = NULL_KEY
            if not needs_timer() then set_timer(0) end
        end
    end
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    ParticlesActive = false
    TargetKey       = NULL_KEY
    SourcePlugin    = ""
    LeashpointLink  = 0
    LmActive        = false
    LmController    = NULL_KEY
    LmTargetPrim    = NULL_KEY
    LmAuthorized    = false
    close_lm_listen()
    -- Clear any leftover particles from before the reset.
    render_leash_particles(NULL_KEY)
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        LmAuthorized = false
        LmController = NULL_KEY
        close_lm_listen()
        ll.ResetScript()
    end
    -- Linkset changed -> re-detect the leashpoint.
    if bit32.band(change, CHANGED_LINK) ~= 0 then
        LeashpointLink = 0
        if ParticlesActive then
            LeashpointLink = find_leashpoint_link()
            render_leash_particles(TargetKey)
        end
    end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
        return
    end

    if num ~= UI_BUS then return end

    if      msg_type == "particles.start"      then handle_particles_start(msg)
    elseif  msg_type == "particles.stop"       then handle_particles_stop(msg)
    elseif  msg_type == "particles.update"     then handle_particles_update(msg)
    elseif  msg_type == "particles.lm.enable"  then handle_lm_enable(msg)
    elseif  msg_type == "particles.lm.disable" then handle_lm_disable()
    end
end

function LLEvents.listen(channel: number, name: string, id, msg: string)
    if channel == LEASH_CHAN_LM then
        handle_lm_message(id, msg)
    end
end

main()

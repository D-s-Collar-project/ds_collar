--[[--------------------
MODULE: kmod_particles.lua  (SLua port)
VERSION: 1.10
REVISION: 19  (SLua port rev 1)
PURPOSE: Visual connection renderer with Lockmeister compatibility
ARCHITECTURE: Consolidated message bus lanes

SLUA PORT NOTES:
- Ported from kmod_particles.lsl rev 19. The Lockmeister protocol (LEASH_CHAN_LM
  -8888 wire strings) and the particles.* / particles.lm.* UI_BUS messages are
  unchanged for OC/LM interop.
- Idiomatic SLua: particle tuning uses vector() literals; the particle param
  list is a Lua table; PSYS_PART_FLAGS is composed with bit32.bor; booleans
  replace 0/1 flags. No parallel lists in this module.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local UI_BUS = 900

--[[ -------------------- CONSTANTS -------------------- ]]
local PARTICLE_UPDATE_RATE = 0.25

local LEASH_CHAN_LM = -8888
local LM_PING_INTERVAL = 8

--[[ -------------------- LEASH PARTICLE TUNING -------------------- ]]
local CHAIN_TEXTURE     = "ebe48305-8955-2b27-7656-3c39cee2cc1b"
local SILK_TEXTURE      = "78ce70e9-b10d-3650-a54c-aca6bdc9cddb"
local CHAIN_BURST_RATE  = 0.02
local CHAIN_PART_COUNT  = 1
local CHAIN_MAX_AGE     = 2.0
local CHAIN_START_SCALE = vector(0.04, 0.10, 0.0)
local CHAIN_END_SCALE   = vector(0.04, 0.10, 0.0)
local CHAIN_START_COLOR = vector(1.0, 1.0, 1.0)
local CHAIN_END_COLOR   = vector(1.0, 1.0, 1.0)
local CHAIN_START_ALPHA = 1.0
local CHAIN_END_ALPHA   = 1.0
local CHAIN_ACCEL       = vector(0.0, 0.0, -1.5)

--[[ -------------------- STATE -------------------- ]]
local ParticlesActive = false
local TargetKey = NULL_KEY
local SourcePlugin = ""
local ParticleStyle = "chain"
local LeashpointLink = 0

local LmListen = 0
local LmActive = false
local LmController = NULL_KEY
local LmTargetPrim = NULL_KEY
local LmLastPing = 0
local LmAuthorized = false

--[[ -------------------- HELPERS -------------------- ]]

local function now(): number
    return ll.GetUnixTime()
end

local function needs_timer(): boolean
    if LmActive then return true end                              -- Lockmeister pinging
    if SourcePlugin ~= "" and ParticlesActive then return true end -- native rendering
    return false
end

--[[ -------------------- LOCKMEISTER LISTEN -------------------- ]]

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

local function lm_ping()
    if not LmActive or LmController == NULL_KEY then return end

    local t = ll.GetUnixTime()
    if (t - LmLastPing) < LM_PING_INTERVAL then return end
    LmLastPing = t

    if ll.GetAgentSize(LmController) ~= ZERO_VECTOR then
        local wearer = tostring(ll.GetOwner())
        ll.RegionSayTo(LmController, LEASH_CHAN_LM, wearer .. "collar")
        ll.RegionSayTo(LmController, LEASH_CHAN_LM, wearer .. "handle")
        ll.RegionSayTo(LmController, LEASH_CHAN_LM, wearer .. "|LMV2|RequestPoint|handle")
        ll.RegionSayTo(LmController, LEASH_CHAN_LM, wearer .. "|LMV2|RequestPoint|collar")
    end
end

--[[ -------------------- LEASHPOINT DETECTION -------------------- ]]

local function find_leashpoint_link(): number
    local prim_count = ll.GetNumberOfPrims()
    for i = 2, prim_count do
        local params = ll.GetLinkPrimitiveParams(i, {PRIM_NAME, PRIM_DESC})
        local name = string.lower(ll.StringTrim(params[1], STRING_TRIM))
        local desc = string.lower(ll.StringTrim(params[2], STRING_TRIM))
        if name == "leashpoint" and desc == "leashpoint" then return i end
    end
    return LINK_ROOT
end

--[[ -------------------- PARTICLE RENDERING -------------------- ]]

local function render_leash_particles(target)
    if LeashpointLink == 0 then
        LeashpointLink = find_leashpoint_link()
    end

    -- No target, or "invisible" style: emit nothing. The tether (RLV @follow +
    -- llMoveToTarget) lives in kmod_leash_engine, so an invisible leash still
    -- follows/yanks/limits — it just draws nothing.
    if target == NULL_KEY or ParticleStyle == "invisible" then
        ll.LinkParticleSystem(LeashpointLink, {})
        ParticlesActive = false
        return
    end

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

    -- LM sends "<holder_uuid>handle ok" / "<holder_uuid>collar ok" (or "... free").
    local msg_uuid = string.sub(msg, 1, 36)
    local protocol = string.sub(msg, 37)
    if #msg_uuid ~= 36 then return end
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
            ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {"type", "particles.lm.released"}), NULL_KEY)

            if SourcePlugin == "lockmeister" or SourcePlugin == "" then
                SourcePlugin = ""
                TargetKey = NULL_KEY
            end
            if not needs_timer() then ll.SetTimerEvent(0.0) end
        end
        return
    end

    -- Grab response.
    if protocol == "collar ok" or protocol == "handle ok" then
        if not LmAuthorized then return end
        if LmController ~= NULL_KEY and owner_key ~= LmController then return end

        if LmActive and LmTargetPrim ~= NULL_KEY then
            if id ~= LmTargetPrim then return end
            LmLastPing = now()  -- same handle confirming
            return
        end

        -- Priority: don't override native rendering to a holder prim.
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

    local new_style = "chain"
    local style_field = ll.JsonGetValue(msg, {"style"})
    if style_field ~= JSON_INVALID then new_style = style_field end

    -- Idempotent: same source + target + style + already rendering → skip
    -- (each re-issue resets the system and flashes a straight segment).
    if ParticlesActive and SourcePlugin == source and TargetKey == target and ParticleStyle == new_style then
        return
    end

    if #ll.GetObjectDetails(target, {OBJECT_POS}) == 0 then return end  -- target must exist

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
    -- invisible renders nothing (no stream to validate), so only arm the timer
    -- when there's real work (live particles or LM ping).
    if needs_timer() then ll.SetTimerEvent(PARTICLE_UPDATE_RATE) else ll.SetTimerEvent(0.0) end
end

local function handle_particles_stop(msg: string)
    if ll.JsonGetValue(msg, {"source"}) == JSON_INVALID then return end
    local source = ll.JsonGetValue(msg, {"source"})
    if source ~= SourcePlugin then return end  -- only the owner may stop

    render_leash_particles(NULL_KEY)
    SourcePlugin = ""
    TargetKey = NULL_KEY

    if not needs_timer() then ll.SetTimerEvent(0.0) end
end

local function handle_particles_update(msg: string)
    if ll.JsonGetValue(msg, {"target"}) == JSON_INVALID then return end
    local new_target = uuid(ll.JsonGetValue(msg, {"target"}))

    if #ll.GetObjectDetails(new_target, {OBJECT_POS}) == 0 then return end

    if new_target ~= TargetKey then
        TargetKey = new_target
        render_leash_particles(TargetKey)
        ll.SetTimerEvent(PARTICLE_UPDATE_RATE)
    end
end

local function handle_lm_enable(msg: string)
    if ll.JsonGetValue(msg, {"controller"}) == JSON_INVALID then return end
    LmController = uuid(ll.JsonGetValue(msg, {"controller"}))
    LmAuthorized = true
    open_lm_listen()
    LmLastPing = now()
    ll.SetTimerEvent(PARTICLE_UPDATE_RATE)
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
    if not needs_timer() then ll.SetTimerEvent(0.0) end
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end

    ParticlesActive = false
    TargetKey = NULL_KEY
    SourcePlugin = ""
    LeashpointLink = 0

    LmActive = false
    LmController = NULL_KEY
    LmTargetPrim = NULL_KEY
    LmAuthorized = false
    close_lm_listen()

    render_leash_particles(NULL_KEY)  -- clear leftovers
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

    if msg_type == "particles.start" then
        handle_particles_start(msg)
    elseif msg_type == "particles.stop" then
        handle_particles_stop(msg)
    elseif msg_type == "particles.update" then
        handle_particles_update(msg)
    elseif msg_type == "particles.lm.enable" then
        handle_lm_enable(msg)
    elseif msg_type == "particles.lm.disable" then
        handle_lm_disable()
    end
end

function LLEvents.listen(channel: number, name: string, id, msg: string)
    if channel == LEASH_CHAN_LM then
        handle_lm_message(id, msg)
    end
end

function LLEvents.timer()
    if LmActive then lm_ping() end

    -- Periodic validation: verify target still exists.
    if ParticlesActive and TargetKey ~= NULL_KEY then
        if #ll.GetObjectDetails(TargetKey, {OBJECT_POS}) == 0 then
            -- Target gone. Stop rendering but keep SourcePlugin (it still owns
            -- the slot; clearing it would orphan a later particles.stop).
            render_leash_particles(NULL_KEY)

            if LmActive then
                LmActive = false
                LmController = NULL_KEY
                LmTargetPrim = NULL_KEY
                LmAuthorized = false
                close_lm_listen()
                ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {"type", "particles.lm.released"}), NULL_KEY)
            end

            TargetKey = NULL_KEY
            if not needs_timer() then ll.SetTimerEvent(0.0) end
        end
    end
end

-- Top-level init.
main()

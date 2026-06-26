--[[--------------------
MODULE: kmod_leash_engine.lua  (SLua port)
VERSION: 1.2
REVISION: 9  (SLua port rev 1)
PURPOSE: Self-contained leashing engine. Absorbs the holder-discovery handshake;
         no proto sibling. Coffle responder + Lockmeister grab-inflow (via
         kmod_particles) + claim initiation + auto-reclip + follow mechanics.
ARCHITECTURE: a two-mode machine — "default" (unleashed/idle) and "leashed"
  (active). ONE listener on LEASH_CHAN (-8888), JSON grammar only; kmod_particles
  owns the Lockmeister grammar on the same channel.

SLUA PORT NOTES:
- Ported from kmod_leash_engine.lsl v1.2 rev 9. Wire protocol preserved exactly:
  the JSON LEASH_CHAN grammar (plugin.leash.request/target/state), the
  plugin.leash.action API + sos.leash.release/safeword.fired + particles.lm.*
  (UI_BUS 900), settings.set persistence (SETTINGS_BUS 800). @follow/@setrot RLV
  commands via ll.OwnerSay (sanctioned). plugin_leash interoperates unchanged.
- GOTCHA (structural): the LSL's two states (default/leashed) have no SLua
  equivalent. Modeled with a CurrentState string + explicit entry/exit functions
  (leashed_state_entry / leashed_state_exit / default_state_entry). The transition
  machinery is UNCHANGED in spirit: deep helpers set StateChange (TR_LEASH/UNLEASH)
  + NeedBroadcast; the link_message/timer shells flush + apply at top level via
  takeStateChange(). CRITICAL FIDELITY POINTS preserved from the LSL:
    * default.timer does NOT flush/apply a transition (a reclip claim's TR_LEASH is
      applied on the next link_message — the settings.sync echo — exactly as the LSL).
    * default.state_entry re-runs applySettingsSync + the cold-restart check on the
      unleash transition (LSL state-entry behaviour).
  Because SLua lacks the LSL auto-teardown of listens/timer/controls on a state
  change, the LEASH_CHAN listen and the FOLLOW_TICK timer are opened ONCE in main()
  and kept across both modes (both LSL states re-established identical ones);
  controls stay managed by updateControlsMask + the permission grant.
- GOTCHA: 0-is-truthy. Every LSL integer-boolean (Leashed, TurnToFace,
  FollowIsAvatar, FollowActive, ControlsOk, AtLimit, ControlsExpanded,
  AwaitingHolder, OffsimDetected, PendingHolder, NeedBroadcast) is a REAL Lua
  boolean. b2i()/b2s() convert back to 1/0 number/string for the JSON wire +
  settings.set persistence (a bare boolean would serialize "true"/"false").
- vectors are native (component .x/.y, +/-/scalar*); control/perm/change masks use
  bit32.band/bor; csv_lead_int replaces (integer) casts; math.floor(ll.Frand(..))
  for session ids (no integer cast). uuid() normalizes key strings.
----------------------]]

--[[ -------------------- BUS CHANNELS -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS     = 800
local UI_BUS           = 900

--[[ -------------------- DISCOVERY CHANNEL -------------------- ]]
local LEASH_CHAN     = -8888
local PROBE_WINDOW   = 3.0
local PENDING_WINDOW = 2.0

--[[ -------------------- PROTOCOL CONSTANTS -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.leash"

local MODE_AVATAR = 0
local MODE_COFFLE = 1
local MODE_POST   = 2

local KEY_LEASHED        = "leash.leashedavatar"
local KEY_LEASHER        = "leash.leasherkey"
local KEY_LEASH_LENGTH   = "leash.length"
local KEY_LEASH_TURNTO   = "leash.turnto"
local KEY_LEASH_TEXTURE  = "leash.texture"

local TR_NONE    = 0
local TR_LEASH   = 1
local TR_UNLEASH = 2
local StateChange = 0

local NeedBroadcast = false

local CAUSE_NATIVE = 0
local CAUSE_LM     = 1
local LeashCause   = 0

--[[ -------------------- STATE -------------------- ]]
local CurrentState = "default"  -- "default" | "leashed" (replaces LSL states)

-- Leash state
local Leashed        = false
local Leasher        = NULL_KEY
local LeashLength    = 3
local TurnToFace     = false
local LeashTexture   = "chain"
local FollowTarget   = NULL_KEY
local FollowIsAvatar = true
local LeashClaimMode = 0

-- Follow mechanics
local FollowActive     = false
local LastTargetPos    = ZERO_VECTOR
local ControlsOk       = false
local AtLimit          = false
local ControlsExpanded = false
local TickCount        = 0

-- Turn-to-face throttling
local LastTurnAngle = -999.0
local TURN_THRESHOLD = 0.1

-- Holder discovery
local HolderTarget   = NULL_KEY
local AwaitingHolder = false
local HolderSession  = 0
local ProbeDeadline  = 0

-- Offsim detection & auto-reclip
local OffsimDetected      = false
local OffsimStartTime     = 0
local OFFSIM_GRACE        = 6.0
local ReclipScheduled     = 0
local LastLeasher         = NULL_KEY
local ReclipAttempts      = 0
local MAX_RECLIP_ATTEMPTS = 3
local RECLIP_SAFETY_WINDOW = 120
local ReclipDeadline      = 0

-- Lockmeister authorization
local AuthorizedLmController = NULL_KEY

-- Deferred-restraint gate
local PendingHolder   = false
local PendingNotice   = ""
local PendingDeadline = 0

-- Yank rate limiting
local LastYankTime  = 0
local YANK_COOLDOWN = 5.0
local YankTargetHandle = 0

-- Timer
local FOLLOW_TICK = 1.0

--[[ -------------------- FORWARD DECLARATIONS (mutual recursion) -------------------- ]]
local commitPendingLeash
local claimLeash
local go_leashed
local go_default

--[[ -------------------- TIMER SHIM -------------------- ]]
local _timerHandle = nil
local _on_timer  -- forward declaration
local function set_timer(interval: number)
    if _timerHandle then
        LLTimers:off(_timerHandle)
        _timerHandle = nil
    end
    if interval > 0 then
        _timerHandle = LLTimers:every(interval, _on_timer)
    end
end

--[[ -------------------- GENERIC HELPERS -------------------- ]]

local function csv_lead_int(s: string): number
    return tonumber(string.match(s, "^%s*(-?%d+)") or "") or 0
end

-- Boolean -> wire 1/0 (number for JSON, string for settings.set).
local function b2i(b: boolean): number
    if b then return 1 end
    return 0
end
local function b2s(b: boolean): string
    if b then return "1" end
    return "0"
end

local function jsonGet(j: string, k: string, default_val: string): string
    local v = ll.JsonGetValue(j, {k})
    if v == JSON_INVALID then return default_val end
    return v
end

local function clampLeashLength(len: number): number
    if len < 1 then return 1 end
    if len > 20 then return 20 end
    return len
end

--[[ -------------------- LOCKMEISTER / PARTICLES PROTOCOL -------------------- ]]

local function setLockmeisterState(enabled: boolean, controller)
    local msg
    if enabled then
        msg = ll.List2Json(JSON_OBJECT, {
            "type", "particles.lm.enable",
            "controller", tostring(controller),
        })
    else
        msg = ll.List2Json(JSON_OBJECT, {"type", "particles.lm.disable"})
    end
    ll.MessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY)
end

local function setParticlesState(active: boolean, target)
    local msg
    if active then
        msg = ll.List2Json(JSON_OBJECT, {
            "type", "particles.start",
            "source", PLUGIN_CONTEXT,
            "target", tostring(target),
            "style", LeashTexture,
        })
    else
        msg = ll.List2Json(JSON_OBJECT, {"type", "particles.stop", "source", PLUGIN_CONTEXT})
    end
    ll.MessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY)
end

--[[ -------------------- SETTINGS PERSISTENCE -------------------- ]]

local function persistSetting(setting_key: string, value: string)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "settings.set",
        "key", setting_key,
        "value", value,
    }), NULL_KEY)
end

local function persistLeashState(leashed: boolean, leasher)
    persistSetting(KEY_LEASHED, b2s(leashed))
    persistSetting(KEY_LEASHER, tostring(leasher))
end

local function applySettingsSync()
    local tmp = ll.LinksetDataRead(KEY_LEASHED)
    if tmp ~= "" then Leashed = (csv_lead_int(tmp) ~= 0) end
    tmp = ll.LinksetDataRead(KEY_LEASHER)
    if tmp ~= "" then Leasher = uuid(tmp) end
    tmp = ll.LinksetDataRead(KEY_LEASH_LENGTH)
    if tmp ~= "" then LeashLength = clampLeashLength(csv_lead_int(tmp)) end
    tmp = ll.LinksetDataRead(KEY_LEASH_TURNTO)
    if tmp ~= "" then TurnToFace = (csv_lead_int(tmp) ~= 0) end
    tmp = ll.LinksetDataRead(KEY_LEASH_TEXTURE)
    if tmp == "chain" or tmp == "silk" or tmp == "invisible" then LeashTexture = tmp end

    -- Cold-restart fallback only (FollowTarget == NULL gate).
    if Leashed and Leasher ~= NULL_KEY and FollowTarget == NULL_KEY then
        FollowTarget = Leasher
        FollowIsAvatar = true
    end
end

--[[ -------------------- STATE MANAGEMENT -------------------- ]]

local function clearReclipState()
    ReclipScheduled = 0
    LastLeasher = NULL_KEY
    ReclipAttempts = 0
    ReclipDeadline = 0
end

local function setLeashState(user, follow_target, follow_is_avatar: boolean, claim_mode: number)
    Leashed = true
    Leasher = user
    LastLeasher = user
    FollowTarget = follow_target
    FollowIsAvatar = follow_is_avatar
    LeashClaimMode = claim_mode
    persistLeashState(true, user)
    NeedBroadcast = true
    StateChange = TR_LEASH
end

local function clearLeashState(clear_reclip: boolean)
    Leashed = false
    Leasher = NULL_KEY
    FollowTarget = NULL_KEY
    FollowIsAvatar = true
    LeashClaimMode = 0
    HolderTarget = NULL_KEY
    AwaitingHolder = false
    AuthorizedLmController = NULL_KEY
    PendingHolder = false
    PendingNotice = ""
    persistLeashState(false, NULL_KEY)

    if clear_reclip then clearReclipState() end

    NeedBroadcast = true
    StateChange = TR_UNLEASH
end

local function takeStateChange(): number
    local tr = StateChange
    StateChange = TR_NONE
    return tr
end

--[[ -------------------- HOLDER DISCOVERY (absorbed proto) -------------------- ]]

local function findLeashpointPrim()
    local n = ll.GetNumberOfPrims()
    local i = 2
    while i <= n do
        local p = ll.GetLinkPrimitiveParams(i, {PRIM_DESC})
        local desc = ll.ToLower(p[1] or "")
        if ll.SubStringIndex(desc, "leashpoint") ~= -1 then return ll.GetLinkKey(i) end
        i = i + 1
    end
    local ln = ll.GetLinkNumber()
    if ln <= 0 then ln = 1 end
    return ll.GetLinkKey(ln)
end

local function coffleResponder(msg: string)
    local requesting_collar = uuid(jsonGet(msg, "collar", tostring(NULL_KEY)))
    if requesting_collar == NULL_KEY then return end
    if requesting_collar == ll.GetKey() then return end        -- ignore self
    local session_str = jsonGet(msg, "session", "")
    if session_str == "" then return end
    if jsonGet(msg, "mode", "") ~= "coffle" then return end    -- only answer coffle

    local target_prim = findLeashpointPrim()
    ll.RegionSayTo(requesting_collar, LEASH_CHAN, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.target",
        "ok", "1",
        "holder", tostring(target_prim),
        "root", tostring(ll.GetLinkKey(1)),
        "name", ll.GetObjectName(),
        "session", session_str,
    }))
end

local function validateAndExtractHolder(msg: string)
    if jsonGet(msg, "type", "") ~= "plugin.leash.target" then return NULL_KEY end
    if jsonGet(msg, "ok", "") ~= "1" then return NULL_KEY end
    local session = csv_lead_int(jsonGet(msg, "session", "0"))
    if session ~= HolderSession then return NULL_KEY end

    local candidate = uuid(jsonGet(msg, "holder", tostring(NULL_KEY)))
    if candidate == NULL_KEY then return NULL_KEY end

    if not FollowIsAvatar then
        local root_str = jsonGet(msg, "root", "")
        if root_str == "" then return NULL_KEY end
        if uuid(root_str) ~= FollowTarget then return NULL_KEY end
    else
        local root_str = jsonGet(msg, "root", "")
        local validate_key = candidate
        if root_str ~= "" and uuid(root_str) ~= NULL_KEY then validate_key = uuid(root_str) end
        local odetails = ll.GetObjectDetails(validate_key, {OBJECT_ATTACHED_POINT, OBJECT_OWNER})
        if #odetails < 2 then return NULL_KEY end
        if odetails[1] == 0 then return NULL_KEY end
        if odetails[2] ~= FollowTarget then return NULL_KEY end
    end
    return candidate
end

local function startProbe()
    if FollowTarget == NULL_KEY then return end
    HolderSession = math.floor(ll.Frand(9.0e6))

    local mode_str = "grab"
    if LeashClaimMode == MODE_POST then mode_str = "post"
    elseif LeashClaimMode == MODE_COFFLE then mode_str = "coffle" end

    ll.RegionSayTo(FollowTarget, LEASH_CHAN, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.request",
        "wearer", tostring(ll.GetOwner()),
        "collar", tostring(ll.GetKey()),
        "controller", tostring(Leasher),
        "session", tostring(HolderSession),
        "origin", "leashpoint",
        "mode", mode_str,
    }))
    AwaitingHolder = true
    ProbeDeadline = ll.GetUnixTime() + math.floor(PROBE_WINDOW)
end

local function handleLeashListen(msg: string)
    if ll.GetSubString(msg, 0, 0) ~= "{" then return end
    local t = jsonGet(msg, "type", "")
    if t == "plugin.leash.request" then
        coffleResponder(msg)
    elseif t == "plugin.leash.target" then
        if not AwaitingHolder then return end
        local holder = validateAndExtractHolder(msg)
        if holder == NULL_KEY then return end
        HolderTarget = holder
        AwaitingHolder = false
        setParticlesState(true, HolderTarget)
        if PendingHolder then commitPendingLeash() end  -- a pending coffle/grab answered
    end
end

--[[ -------------------- OFFSIM DETECTION & AUTO-RECLIP -------------------- ]]

local function autoReleaseOffsim()
    clearLeashState(false)  -- false = keep reclip state
    ll.RegionSayTo(ll.GetOwner(), 0, "Auto-released (offsim)")
end

local function checkLeasherPresence()
    if not Leashed or Leasher == NULL_KEY then return end

    local now_time = ll.GetUnixTime()

    local avatar_present = (ll.GetAgentInfo(Leasher) ~= 0)
    local holder_present = false
    if HolderTarget ~= NULL_KEY then
        holder_present = (#ll.GetObjectDetails(HolderTarget, {OBJECT_POS}) > 0)
    end
    local present = avatar_present or holder_present

    if not avatar_present and holder_present and not OffsimDetected then
        ll.RegionSayTo(ll.GetOwner(), 0, "Leasher offline, leash held by object")
    end

    if not present then
        if not OffsimDetected then
            OffsimDetected = true
            OffsimStartTime = now_time
        elseif (now_time - OffsimStartTime) >= OFFSIM_GRACE then
            LastLeasher = Leasher
            autoReleaseOffsim()
            ReclipScheduled = now_time + 2
            ReclipAttempts = 0
            ReclipDeadline = now_time + RECLIP_SAFETY_WINDOW
        end
    elseif OffsimDetected then
        OffsimDetected = false
        OffsimStartTime = 0
    end
end

local function checkAutoReclip()
    if ReclipScheduled == 0 or ll.GetUnixTime() < ReclipScheduled then return end

    if ReclipDeadline ~= 0 and ll.GetUnixTime() >= ReclipDeadline then
        clearReclipState()
        return
    end
    if ReclipAttempts >= MAX_RECLIP_ATTEMPTS then
        clearReclipState()
        return
    end
    if LastLeasher ~= NULL_KEY and ll.GetAgentInfo(LastLeasher) ~= 0 then
        -- Re-clip the previously-authorized leasher directly (no ACL re-check).
        claimLeash(LastLeasher, MODE_AVATAR, NULL_KEY, 1, false)
        ReclipAttempts = ReclipAttempts + 1
        ReclipScheduled = ll.GetUnixTime() + 2
    end
end

--[[ -------------------- FOLLOW MECHANICS -------------------- ]]

local function updateControlsMask()
    if not ControlsOk then return end
    local should_expand = Leashed and (AtLimit or YankTargetHandle ~= 0)
    if should_expand == ControlsExpanded then return end
    ControlsExpanded = should_expand
    local mask = CONTROL_ML_LBUTTON
    if should_expand then
        mask = bit32.bor(mask, CONTROL_FWD, CONTROL_BACK,
            CONTROL_LEFT, CONTROL_RIGHT, CONTROL_ROT_LEFT, CONTROL_ROT_RIGHT)
    end
    ll.TakeControls(mask, false, true)
end

local function startFollow()
    if not Leashed then return end
    FollowActive = true
    if FollowIsAvatar and FollowTarget ~= NULL_KEY then
        ll.OwnerSay("@follow:" .. tostring(FollowTarget) .. "=force")
    end
    ll.RequestPermissions(ll.GetOwner(), PERMISSION_TAKE_CONTROLS)
end

local function stopFollow()
    FollowActive = false
    ll.OwnerSay("@follow=clear")
    ll.StopMoveToTarget()
    if YankTargetHandle ~= 0 then
        ll.TargetRemove(YankTargetHandle)
        YankTargetHandle = 0
    end
    LastTargetPos = ZERO_VECTOR
    LastTurnAngle = -999.0
end

local function turnToTarget(target_pos)
    if not TurnToFace or not Leashed then return end
    local wearer_pos = ll.GetRootPosition()
    local direction = ll.VecNorm(target_pos - wearer_pos)
    local angle = ll.Atan2(direction.y, direction.x)
    if math.abs(angle - LastTurnAngle) > TURN_THRESHOLD then
        ll.OwnerSay("@setrot:" .. tostring(angle) .. "=force")
        LastTurnAngle = angle
    end
end

local function followTick()
    if not FollowActive or not Leashed then return end

    local follow_target = FollowTarget
    if follow_target == NULL_KEY then return end

    local target_key = follow_target
    if HolderTarget ~= NULL_KEY then target_key = HolderTarget end

    local details = ll.GetObjectDetails(target_key, {OBJECT_POS})

    -- HolderTarget vanished: drop it and retry with the raw mode anchor.
    if #details == 0 and target_key == HolderTarget then
        HolderTarget = NULL_KEY
        ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "particles.update",
            "target", tostring(follow_target),
        }), NULL_KEY)
        target_key = follow_target
        details = ll.GetObjectDetails(target_key, {OBJECT_POS})
    end

    if #details == 0 then return end
    local target_pos = details[1]

    local wearer_pos = ll.GetRootPosition()
    local distance = ll.VecDist(wearer_pos, target_pos)
    local len = LeashLength  -- numeric (LSL cached (float)LeashLength here)

    local new_at_limit = (distance >= len)
    if new_at_limit ~= AtLimit then
        AtLimit = new_at_limit
        updateControlsMask()
    end

    if ControlsOk and distance > len then
        -- Pull to 0.85 * length so there's slack on arrival.
        local pull_pos = target_pos + ll.VecNorm(wearer_pos - target_pos) * len * 0.85
        if ll.VecMag(pull_pos - LastTargetPos) > 0.2 then
            ll.MoveToTarget(pull_pos, 1.0)
            LastTargetPos = pull_pos
        end
        if TurnToFace and follow_target ~= NULL_KEY then
            turnToTarget(target_pos)
        end
    else
        if LastTargetPos ~= ZERO_VECTOR and YankTargetHandle == 0 then
            ll.StopMoveToTarget()
            LastTargetPos = ZERO_VECTOR
        end
    end
end

--[[ -------------------- ACTIVATION / PENDING -------------------- ]]

local function activateLeashFromState()
    -- A pending grab/coffle holds the restraint: probe/LM but don't follow yet.
    if not PendingHolder then startFollow() end
    if LeashCause == CAUSE_NATIVE then
        if FollowTarget == Leasher and FollowIsAvatar then
            AuthorizedLmController = Leasher
            setLockmeisterState(true, Leasher)
        end
        startProbe()
    end
    LeashCause = CAUSE_NATIVE  -- reset to default for next entry
end

-- Forward-declared above; assigned here.
commitPendingLeash = function()
    if not PendingHolder then return end
    PendingHolder = false
    startFollow()
    NeedBroadcast = true
    if PendingNotice ~= "" then
        ll.RegionSayTo(Leasher, 0, PendingNotice)
        PendingNotice = ""
    end
end

local function denyPendingLeash()
    local verb = "leash"
    local anchor = "holder"
    if LeashClaimMode == MODE_COFFLE then verb = "coffle"; anchor = "collar" end
    local who = Leasher
    clearLeashState(true)
    ll.RegionSayTo(who, 0, "Unable to " .. verb .. ": No " .. anchor .. " found to clip leash to.")
end

--[[ -------------------- STATE BROADCAST -------------------- ]]

local function broadcastState()
    local mode_out = MODE_AVATAR
    if not FollowIsAvatar then mode_out = MODE_POST
    elseif FollowTarget ~= Leasher then mode_out = MODE_COFFLE end

    local target_out = NULL_KEY
    if FollowTarget ~= Leasher or not FollowIsAvatar then target_out = FollowTarget end

    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.state",
        "leashed", b2i(Leashed),
        "leasher", tostring(Leasher),
        "length", LeashLength,
        "turnto", b2i(TurnToFace),
        "texture", LeashTexture,
        "mode", mode_out,
        "target", tostring(target_out),
    }), NULL_KEY)
end

--[[ -------------------- SETTINGS ACTIONS (mode-agnostic) -------------------- ]]

local function setLengthInternal(length: number)
    LeashLength = clampLeashLength(length)
    persistSetting(KEY_LEASH_LENGTH, tostring(LeashLength))
    NeedBroadcast = true
end

local function toggleTurnInternal()
    TurnToFace = not TurnToFace
    if not TurnToFace then
        ll.OwnerSay("@setrot=clear")
        LastTurnAngle = -999.0
    end
    persistSetting(KEY_LEASH_TURNTO, b2s(TurnToFace))
    NeedBroadcast = true
end

local function setTextureInternal(texture: string)
    if texture ~= "chain" and texture ~= "silk" and texture ~= "invisible" then return end
    if texture == LeashTexture then
        NeedBroadcast = true
        return
    end
    LeashTexture = texture
    persistSetting(KEY_LEASH_TEXTURE, texture)
    NeedBroadcast = true

    if Leashed then
        local t = HolderTarget
        if t == NULL_KEY then t = FollowTarget end
        if t ~= NULL_KEY then setParticlesState(true, t) end
    end
end

--[[ -------------------- UNIFIED LEASH CLAIM -------------------- ]]

-- Forward-declared above; assigned here.
claimLeash = function(user, mode: number, target_key, acl_level: number, gate_on_holder: boolean)
    local was_leashed = Leashed
    if Leashed then
        if mode == MODE_AVATAR and acl_level >= 3 then
            ll.RegionSayTo(Leasher, 0, "Leash taken by " .. ll.Key2Name(user))
            -- fall through to overwrite
        elseif mode == MODE_AVATAR then
            ll.RegionSayTo(user, 0, "Already leashed to " .. ll.Key2Name(Leasher))
            return
        else
            ll.RegionSayTo(user, 0, "Already leashed. Unclip first.")
            return
        end
    end

    local follow_target = NULL_KEY
    local follow_is_avatar = true
    local notice = ""

    if mode == MODE_AVATAR then
        follow_target = user
        follow_is_avatar = true
        notice = "Leash grabbed by " .. ll.Key2Name(user)
    elseif mode == MODE_COFFLE then
        local details = ll.GetObjectDetails(target_key, {OBJECT_POS, OBJECT_NAME, OBJECT_OWNER})
        if #details == 0 then
            ll.RegionSayTo(user, 0, "Target collar not found or out of range.")
            return
        end
        follow_target = details[3]  -- OBJECT_OWNER
        if follow_target == NULL_KEY then
            ll.RegionSayTo(user, 0, "Cannot coffle: target collar has no owner.")
            return
        end
        if follow_target == ll.GetOwner() then
            ll.RegionSayTo(user, 0, "Cannot coffle to yourself.")
            return
        end
        follow_is_avatar = true
        notice = "Coffled to " .. ll.Key2Name(follow_target)
    elseif mode == MODE_POST then
        local details = ll.GetObjectDetails(target_key, {OBJECT_POS, OBJECT_NAME})
        if #details == 0 then
            ll.RegionSayTo(user, 0, "Post object not found or out of range.")
            return
        end
        follow_target = target_key
        follow_is_avatar = false
        notice = "Posted to " .. details[2]  -- OBJECT_NAME
    end

    LeashCause = CAUSE_NATIVE

    local defer = (gate_on_holder and not was_leashed)
    PendingHolder = defer

    setLeashState(user, follow_target, follow_is_avatar, mode)

    if defer then
        NeedBroadcast = false  -- hold the leashed-broadcast + notice until a holder confirms
        PendingNotice = notice
        PendingDeadline = ll.GetUnixTime() + math.floor(PENDING_WINDOW)
    end

    -- Take-over (already leashed): same-mode, activate directly. Fresh claim:
    -- the leashed entry runs activation on the transition.
    if was_leashed then activateLeashFromState() end
    if not defer then ll.RegionSayTo(user, 0, notice) end
end

--[[ -------------------- AVATAR-SPECIFIC FLOWS -------------------- ]]

local function releaseLeashInternal(user)
    if not Leashed then
        ll.RegionSayTo(user, 0, "Not currently leashed.")
        return
    end
    clearLeashState(true)
    ll.RegionSayTo(user, 0, "Leash released")
end

local function passLeashInternal(new_leasher)
    if not Leashed then return end
    local old_leasher = Leasher

    LeashCause = CAUSE_NATIVE
    setLeashState(new_leasher, new_leasher, true, MODE_AVATAR)
    activateLeashFromState()  -- same-mode: activate the new session directly

    ll.RegionSayTo(old_leasher, 0, "Leash passed to " .. ll.Key2Name(new_leasher))
    ll.RegionSayTo(new_leasher, 0, "Leash received from " .. ll.Key2Name(old_leasher))
    ll.RegionSayTo(ll.GetOwner(), 0, "Leash passed to " .. ll.Key2Name(new_leasher) .. " by " .. ll.Key2Name(old_leasher))
end

local function yankToLeasher()
    if not Leashed or Leasher == NULL_KEY then return end

    local details = ll.GetObjectDetails(Leasher, {OBJECT_POS})
    if #details == 0 then
        ll.RegionSayTo(ll.GetOwner(), 0, "Cannot yank: leasher not in range.")
        return
    end
    local leasher_pos = details[1]

    if ControlsOk then
        if YankTargetHandle ~= 0 then
            ll.TargetRemove(YankTargetHandle)
            YankTargetHandle = 0
        end
        ll.MoveToTarget(leasher_pos, 0.3)
        YankTargetHandle = ll.Target(leasher_pos, 1.5)
        updateControlsMask()
        ll.RegionSayTo(ll.GetOwner(), 0, "Yanked to " .. ll.Key2Name(Leasher))
        ll.RegionSayTo(Leasher, 0, ll.Key2Name(ll.GetOwner()) .. " yanked to you.")
    else
        ll.RegionSayTo(ll.GetOwner(), 0, "Cannot yank: controls not active.")
    end
end

local function handleLmGrabbed(controller)
    if Leashed then return end
    LeashCause = CAUSE_LM  -- particles already rendering LM — no native probe/LM re-enable
    setLeashState(controller, controller, true, MODE_AVATAR)
    ll.RegionSayTo(ll.GetOwner(), 0, "Leashed by " .. ll.Key2Name(controller) .. " (Lockmeister)")
end

local function handleLmReleased()
    if not Leashed then return end
    local old_leasher = Leasher
    -- An LM drop while the leasher is OFFSIM is a departure, not a deliberate unclip:
    -- route through the offsim/reclip path. A release while present clears as before.
    if ll.GetAgentInfo(old_leasher) == 0 then
        local now_time = ll.GetUnixTime()
        LastLeasher = old_leasher
        autoReleaseOffsim()
        ReclipScheduled = now_time + 2
        ReclipAttempts = 0
        ReclipDeadline = now_time + RECLIP_SAFETY_WINDOW
        return
    end
    clearLeashState(true)
    ll.RegionSayTo(ll.GetOwner(), 0, "Released by " .. ll.Key2Name(old_leasher) .. " (Lockmeister)")
end

--[[ -------------------- SHARED EVENT ROUTING -------------------- ]]

local function onControlsGranted(perm: number)
    if bit32.band(perm, PERMISSION_TAKE_CONTROLS) ~= 0 then
        ControlsOk = true
        ll.TakeControls(CONTROL_ML_LBUTTON, false, true)
        ControlsExpanded = false
        updateControlsMask()
    end
end

local function routeLinkMessage(num: number, msg: string, id)
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
        return
    end

    if num == UI_BUS then
        if msg_type == "plugin.leash.action" then
            local action = jsonGet(msg, "action", "")
            if action == "" then return end
            local user = id

            if action == "query_state" then
                broadcastState()
                return
            end

            if action == "yank" then
                if user == Leasher then
                    local now_time = ll.GetUnixTime()
                    if (now_time - LastYankTime) < YANK_COOLDOWN then
                        local wait_time = math.floor(YANK_COOLDOWN - (now_time - LastYankTime))
                        ll.RegionSayTo(user, 0, "Yank on cooldown. Wait " .. tostring(wait_time) .. "s.")
                        return
                    end
                    LastYankTime = now_time
                    yankToLeasher()
                else
                    ll.RegionSayTo(user, 0, "Only the current leasher can yank.")
                end
                return
            end

            local acl = csv_lead_int(jsonGet(msg, "acl", "0"))
            local target = uuid(jsonGet(msg, "target", tostring(NULL_KEY)))

            if      action == "grab"    then claimLeash(user, MODE_AVATAR, NULL_KEY, acl, true)
            elseif  action == "coffle"  then claimLeash(user, MODE_COFFLE, target, acl, true)
            elseif  action == "post"    then claimLeash(user, MODE_POST, target, acl, false)
            elseif  action == "release" or action == "force_release" then releaseLeashInternal(user)
            elseif  action == "pass"    then passLeashInternal(target)
            elseif  action == "offer" then
                if Leashed then
                    ll.RegionSayTo(user, 0, "Cannot offer leash: already leashed.")
                else
                    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
                        "type", "plugin.leash.offer.pending",
                        "target", tostring(target),
                        "originator", tostring(user),
                    }), NULL_KEY)
                end
            elseif  action == "set_length"  then setLengthInternal(csv_lead_int(jsonGet(msg, "length", "0")))
            elseif  action == "toggle_turn" then toggleTurnInternal()
            elseif  action == "set_texture" then setTextureInternal(jsonGet(msg, "texture", "chain"))
            end
            return
        end

        if msg_type == "sos.leash.release" or msg_type == "safeword.fired" then
            if id == ll.GetOwner() then releaseLeashInternal(id) end
            return
        end

        if msg_type == "particles.lm.grabbed" then
            local controller = uuid(jsonGet(msg, "controller", tostring(NULL_KEY)))
            if controller == NULL_KEY then return end
            if controller ~= AuthorizedLmController then return end
            if PendingHolder then commitPendingLeash()  -- a pending grab's holder answered
            else handleLmGrabbed(controller) end          -- Lockmeister grab-inflow
            return
        end

        if msg_type == "particles.lm.released" then
            handleLmReleased()
            return
        end
        return
    end

    if num == SETTINGS_BUS then
        if msg_type == "settings.sync" then
            applySettingsSync()
        end
        return
    end
end

--[[ -------------------- STATE ENTRY/EXIT -------------------- ]]

local function leashed_state_entry()
    if not ControlsOk then ll.RequestPermissions(ll.GetOwner(), PERMISSION_TAKE_CONTROLS)
    else updateControlsMask() end
    activateLeashFromState()
end

local function leashed_state_exit()
    -- Physical teardown — runs exactly once per leashed -> unleashed transition.
    stopFollow()
    setParticlesState(false, NULL_KEY)
    setLockmeisterState(false, NULL_KEY)
    AwaitingHolder = false
    AtLimit = false
    updateControlsMask()
end

-- Forward-declared above; assigned here.
go_leashed = function()
    CurrentState = "leashed"
    leashed_state_entry()
end

local function default_state_entry()
    HolderTarget = NULL_KEY
    AwaitingHolder = false
    AuthorizedLmController = NULL_KEY

    applySettingsSync()

    -- Cold-restart re-entry (LSL default.state_entry behaviour). On a clean unleash
    -- Leashed is false, so this no-ops.
    if Leashed and Leasher ~= NULL_KEY then
        LeashCause = CAUSE_NATIVE
        go_leashed()
    end
end

go_default = function()
    leashed_state_exit()
    CurrentState = "default"
    default_state_entry()
end

--[[ -------------------- TICK BODY -------------------- ]]

_on_timer = function()
    if CurrentState == "default" then
        TickCount = TickCount + 1
        -- Auto-reclip polling (~4s). The reclip's TR_LEASH is applied on the next
        -- link_message (the settings.sync echo) — default.timer does NOT apply it.
        if (TickCount % 4) == 0 then
            if ReclipScheduled ~= 0 then checkAutoReclip() end
        end
        return
    end

    -- leashed
    TickCount = TickCount + 1

    if (TickCount % 4) == 0 then
        checkLeasherPresence()  -- may clearLeashState -> TR_UNLEASH
    end

    if AwaitingHolder and ll.GetUnixTime() > ProbeDeadline then
        AwaitingHolder = false
        -- Native fallback only for coffle/post (no LM, not pending).
        if not PendingHolder and AuthorizedLmController == NULL_KEY and FollowTarget ~= NULL_KEY then
            setParticlesState(true, FollowTarget)
        end
    end

    if PendingHolder and ll.GetUnixTime() > PendingDeadline then
        denyPendingLeash()
    end

    if (TickCount % 10) == 0 then
        if Leashed and HolderTarget == NULL_KEY and Leasher ~= NULL_KEY and not AwaitingHolder then
            startProbe()
        end
    end

    if FollowActive and Leashed then followTick() end

    if NeedBroadcast then NeedBroadcast = false; broadcastState() end
    if takeStateChange() == TR_UNLEASH then go_default() end
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    HolderTarget = NULL_KEY
    AwaitingHolder = false
    AuthorizedLmController = NULL_KEY

    applySettingsSync()

    -- ONE persistent listen + tick (both modes used identical ones in the LSL).
    ll.Listen(LEASH_CHAN, "", NULL_KEY, "")
    set_timer(FOLLOW_TICK)

    if Leashed and Leasher ~= NULL_KEY then
        LeashCause = CAUSE_NATIVE
        CurrentState = "leashed"
        leashed_state_entry()
    else
        CurrentState = "default"
        if not ControlsOk then ll.RequestPermissions(ll.GetOwner(), PERMISSION_TAKE_CONTROLS) end
    end
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

function LLEvents.run_time_permissions(perm: number)
    onControlsGranted(perm)
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    routeLinkMessage(num, msg, id)
    if NeedBroadcast then NeedBroadcast = false; broadcastState() end
    local tr = takeStateChange()
    if CurrentState == "default" then
        if tr == TR_LEASH then go_leashed() end
    else
        if tr == TR_UNLEASH then go_default() end
    end
end

function LLEvents.listen(channel: number, name: string, id, msg: string)
    if channel ~= LEASH_CHAN then return end
    handleLeashListen(msg)
end

-- control + at_target self-guard (only meaningful while leashed), so a single
-- handler each is safe in both modes.
function LLEvents.control(id, level: number, edge: number)
    if not Leashed then return end
    local pressed = bit32.band(level, edge)
    local directional = bit32.bor(CONTROL_FWD, CONTROL_BACK,
        CONTROL_LEFT, CONTROL_RIGHT, CONTROL_ROT_LEFT, CONTROL_ROT_RIGHT)
    if bit32.band(pressed, directional) == 0 then return end

    local follow_target = FollowTarget
    if follow_target == NULL_KEY then return end

    local target_key = follow_target
    if HolderTarget ~= NULL_KEY then target_key = HolderTarget end

    local details = ll.GetObjectDetails(target_key, {OBJECT_POS})
    if #details == 0 then return end
    local target_pos = details[1]

    local wearer_pos = ll.GetRootPosition()
    local distance = ll.VecDist(wearer_pos, target_pos)
    if distance < LeashLength then return end

    -- Soft corrective pull — bridges the 1Hz tick; the only correction in post mode.
    local pull_pos = target_pos + ll.VecNorm(wearer_pos - target_pos) * LeashLength * 0.85
    ll.MoveToTarget(pull_pos, 1.0)
    LastTargetPos = pull_pos
end

function LLEvents.at_target(tnum: number, target_pos, my_pos)
    -- Yank arrival: release the physics hold.
    if tnum == YankTargetHandle then
        ll.TargetRemove(YankTargetHandle)
        YankTargetHandle = 0
        ll.StopMoveToTarget()
        LastTargetPos = ZERO_VECTOR
        updateControlsMask()
    end
end

main()

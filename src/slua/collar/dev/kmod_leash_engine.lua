--[[--------------------
MODULE: kmod_leash_engine.lua  (SLua port)
VERSION: 1.10
REVISION: 35  (SLua port rev 1)
PURPOSE: Leashing engine — state, ACL, claim/release/pass/yank, follow
         mechanics, settings persistence, broadcasts. The holder-discovery
         handshake lives in sibling kmod_leash_proto.lua.
ARCHITECTURE: Engine + sibling proto over SETTINGS_BUS (proto filters on the
              "leash.proto.*" type prefix).

SLUA PORT NOTES:
- Ported from kmod_leash_engine.lsl rev 35. The Lockmeister grab inflow, the
  native handshake IPC, all RLV @follow/@setrot emission (via ll.OwnerSay), and
  the plugin.leash.* / particles.* / auth.* wire formats are preserved exactly —
  OC/LM interop is a hard requirement.
- Idiomatic SLua: booleans replace 0/1 flags (persisted/broadcast as numbers via
  explicit conversion); bit32.band/bor for control + permission masks;
  forward-declared function block (handleAclResult calls claim/release/pass
  defined later). No parallel lists in this module.
- HAZARD handled: the LSL stores the set_length value and set_texture style in a
  `key`-typed field (LSL keys are arbitrary strings). SLua's uuid() is strict, so
  PendingPassTarget is a STRING here, converted with uuid() only where a real key
  is required (coffle/post/pass targets).
----------------------]]

--[[ -------------------- BUS CHANNELS -------------------- ]]
local KERNEL_LIFECYCLE = 500
local AUTH_BUS = 700
local SETTINGS_BUS = 800
local UI_BUS = 900

--[[ -------------------- PROTOCOL CONSTANTS -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.leash"

local POL_CLIP     = "Clip"
local POL_TAKE     = "Take"
local POL_UNCLIP   = "Unclip"
local POL_PASS     = "Pass"
local POL_OFFER    = "Offer"
local POL_COFFLE   = "Coffle"
local POL_POST     = "Post"
local POL_SETTINGS = "Settings"

-- Claim kinds — parameters to claimLeash() only (not stored as state).
local MODE_AVATAR = 0
local MODE_COFFLE = 1
local MODE_POST = 2

-- Settings keys.
local KEY_LEASHED = "leash.leashedavatar"
local KEY_LEASHER = "leash.leasherkey"
local KEY_LEASH_LENGTH = "leash.length"
local KEY_LEASH_TURNTO = "leash.turnto"
local KEY_LEASH_TEXTURE = "leash.texture"

--[[ -------------------- STATE -------------------- ]]
local Leashed = false
local Leasher = NULL_KEY
local LeashLength = 3
local TurnToFace = false
local LeashTexture = "chain"
local FollowTarget = NULL_KEY
local FollowIsAvatar = true
local LeashClaimMode = 0  -- MODE_AVATAR default (cold-restart fallback)

local FollowActive = false
local LastTargetPos = ZERO_VECTOR
local ControlsOk = false
local AtLimit = false
local ControlsExpanded = false
local TickCount = 0

local LastTurnAngle = -999.0
local TURN_THRESHOLD = 0.1

local HolderTarget = NULL_KEY

local OffsimDetected = false
local OffsimStartTime = 0
local OFFSIM_GRACE = 6.0
local ReclipScheduled = 0
local LastLeasher = NULL_KEY
local ReclipAttempts = 0
local MAX_RECLIP_ATTEMPTS = 3
local RECLIP_SAFETY_WINDOW = 120
local ReclipDeadline = 0

local PendingActionUser = NULL_KEY
local PendingAction = ""
local PendingPassTarget = ""           -- STRING (may hold a UUID, a length, or a style)
local AclPending = false
local PendingPassOriginalUser = NULL_KEY
local PendingIsOffer = false

local AuthorizedLmController = NULL_KEY

local LastYankTime = 0
local YANK_COOLDOWN = 5.0
local YankTargetHandle = 0

local FOLLOW_TICK = 1.0

--[[ -------------------- FORWARD DECLARATIONS -------------------- ]]
local jsonGet, now, policy_allows, denyAccess
local setLockmeisterState, setParticlesState, updateParticlesTarget, sendOfferPending
local persistSetting, persistLeashState, clampLeashLength, applySettingsSync
local setLeashState, clearLeashState, notifyLeashTransfer
local sendProtoStart, sendProtoShutdown
local clearPendingAction, requestAclForAction, handleAclResult, requestAclForPassTarget
local clearReclipState, checkLeasherPresence, autoReleaseOffsim, checkAutoReclip
local leashFollowTarget, updateControlsMask, startFollow, stopFollow, turnToTarget, followTick
local broadcastState, setLengthInternal, toggleTurnInternal, setTextureInternal
local claimLeash, releaseLeashInternal, passLeashInternal, yankToLeasher
local handleLmGrabbed, handleLmReleased

local function list_find(t, v)
    for i, x in ipairs(t) do
        if x == v then return i end
    end
    return nil
end

local function b2i(b: boolean): number
    if b then return 1 end
    return 0
end

--[[ -------------------- GENERIC HELPERS -------------------- ]]

function jsonGet(j: string, k: string, default_val: string): string
    local v = ll.JsonGetValue(j, {k})
    if v == JSON_INVALID then return default_val end
    return v
end

function now(): number
    return ll.GetUnixTime()
end

function policy_allows(btn_label: string, acl_level: number): boolean
    local policy = ll.LinksetDataRead("acl.policycontext:" .. PLUGIN_CONTEXT)
    if policy == "" then return false end
    local csv = ll.JsonGetValue(policy, {tostring(acl_level)})
    if csv == JSON_INVALID then return false end
    return list_find(ll.CSV2List(csv), btn_label) ~= nil
end

function denyAccess(user, reason: string)
    ll.RegionSayTo(user, 0, "Access denied: " .. reason)
end

--[[ -------------------- LOCKMEISTER / PARTICLES / OFFER PROTOCOL -------------------- ]]

function setLockmeisterState(enabled: boolean, controller)
    if enabled then
        ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "particles.lm.enable",
            "controller", tostring(controller),
        }), NULL_KEY)
    else
        ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {"type", "particles.lm.disable"}), NULL_KEY)
    end
end

function setParticlesState(active: boolean, target)
    if active then
        ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "particles.start",
            "source", PLUGIN_CONTEXT,
            "target", tostring(target),
            "style", LeashTexture,
        }), NULL_KEY)
    else
        ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "particles.stop",
            "source", PLUGIN_CONTEXT,
        }), NULL_KEY)
    end
end

function updateParticlesTarget(target)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "particles.update",
        "target", tostring(target),
    }), NULL_KEY)
end

function sendOfferPending(target, originator)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.offer.pending",
        "target", tostring(target),
        "originator", tostring(originator),
    }), NULL_KEY)
end

--[[ -------------------- SETTINGS PERSISTENCE -------------------- ]]

function persistSetting(setting_key: string, value: string)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "settings.set",
        "key", setting_key,
        "value", value,
    }), NULL_KEY)
end

function persistLeashState(leashed: boolean, leasher)
    persistSetting(KEY_LEASHED, tostring(b2i(leashed)))
    persistSetting(KEY_LEASHER, tostring(leasher))
end

function clampLeashLength(len: number): number
    if len < 1 then return 1 end
    if len > 20 then return 20 end
    return len
end

function applySettingsSync()
    local tmp = ll.LinksetDataRead(KEY_LEASHED)
    if tmp ~= "" then Leashed = integer(tmp) ~= 0 end
    tmp = ll.LinksetDataRead(KEY_LEASHER)
    if tmp ~= "" then Leasher = uuid(tmp) end
    tmp = ll.LinksetDataRead(KEY_LEASH_LENGTH)
    if tmp ~= "" then LeashLength = clampLeashLength(integer(tmp)) end
    tmp = ll.LinksetDataRead(KEY_LEASH_TURNTO)
    if tmp ~= "" then TurnToFace = integer(tmp) ~= 0 end
    tmp = ll.LinksetDataRead(KEY_LEASH_TEXTURE)
    if tmp == "chain" or tmp == "silk" or tmp == "invisible" then LeashTexture = tmp end

    -- Cold-restart-only fallback (guarded by FollowTarget == NULL_KEY so a
    -- mid-session settings.sync can't clobber an active post/coffle session).
    if Leashed and Leasher ~= NULL_KEY and FollowTarget == NULL_KEY then
        FollowTarget = Leasher
        FollowIsAvatar = true
    end
end

--[[ -------------------- LEASH PROTO IPC -------------------- ]]

function sendProtoStart(controller)
    local mode_str = "grab"
    if LeashClaimMode == MODE_POST then mode_str = "post"
    elseif LeashClaimMode == MODE_COFFLE then mode_str = "coffle" end

    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "leash.proto.start",
        "controller", tostring(controller),
        "mode", mode_str,
        "validation_target", tostring(FollowTarget),
        "oc_ping_target", tostring(FollowTarget),
    }), NULL_KEY)
end

function sendProtoShutdown()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {"type", "leash.proto.shutdown"}), NULL_KEY)
end

--[[ -------------------- STATE MANAGEMENT -------------------- ]]

function setLeashState(user, follow_target, follow_is_avatar: boolean, claim_mode: number)
    Leashed = true
    Leasher = user
    LastLeasher = user
    FollowTarget = follow_target
    FollowIsAvatar = follow_is_avatar
    LeashClaimMode = claim_mode
    persistLeashState(true, user)
    broadcastState()
end

function clearLeashState(clear_reclip: boolean)
    Leashed = false
    Leasher = NULL_KEY
    FollowTarget = NULL_KEY
    FollowIsAvatar = true
    LeashClaimMode = 0
    persistLeashState(false, NULL_KEY)
    HolderTarget = NULL_KEY
    AuthorizedLmController = NULL_KEY
    sendProtoShutdown()

    if clear_reclip then clearReclipState() end

    setLockmeisterState(false, NULL_KEY)
    setParticlesState(false, NULL_KEY)
    stopFollow()
    AtLimit = false
    updateControlsMask()
    broadcastState()
end

--[[ -------------------- NOTIFICATIONS -------------------- ]]

function notifyLeashTransfer(from_user, to_user, action: string)
    ll.RegionSayTo(from_user, 0, "Leash " .. action .. " to " .. ll.Key2Name(to_user))
    ll.RegionSayTo(to_user, 0, "Leash received from " .. ll.Key2Name(from_user))
    ll.RegionSayTo(ll.GetOwner(), 0, "Leash " .. action .. " to " .. ll.Key2Name(to_user) .. " by " .. ll.Key2Name(from_user))
end

--[[ -------------------- ACL VERIFICATION -------------------- ]]

function clearPendingAction()
    AclPending = false
    PendingActionUser = NULL_KEY
    PendingAction = ""
    PendingPassTarget = ""
    PendingPassOriginalUser = NULL_KEY
    PendingIsOffer = false
end

function requestAclForAction(user, action: string, pass_target: string)
    AclPending = true
    PendingActionUser = user
    PendingAction = action
    PendingPassTarget = pass_target

    ll.MessageLinked(LINK_SET, AUTH_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "auth.acl.query",
        "avatar", tostring(user),
    }), user)
end

function requestAclForPassTarget(target: string)
    PendingPassOriginalUser = PendingActionUser
    PendingActionUser = uuid(target)  -- so handleAclResult matches the response
    PendingAction = "pass_target_check"
    AclPending = true

    ll.MessageLinked(LINK_SET, AUTH_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "auth.acl.query",
        "avatar", target,
    }), uuid(target))
end

function handleAclResult(msg: string)
    if not AclPending then return end
    if ll.JsonGetValue(msg, {"avatar"}) == JSON_INVALID or ll.JsonGetValue(msg, {"level"}) == JSON_INVALID then return end

    local avatar = uuid(ll.JsonGetValue(msg, {"avatar"}))
    if avatar ~= PendingActionUser then return end

    local acl_level = integer(ll.JsonGetValue(msg, {"level"}))
    AclPending = false

    if PendingAction == "release" then
        if PendingActionUser == Leasher or policy_allows(POL_UNCLIP, acl_level) then
            releaseLeashInternal(PendingActionUser)
        else
            denyAccess(PendingActionUser, "only leasher or authorized users can release")
        end
    elseif PendingAction == "force_release" then
        if PendingActionUser == ll.GetOwner() or acl_level >= 3 then
            releaseLeashInternal(PendingActionUser)
        else
            denyAccess(PendingActionUser, "only wearer or authorized users can force-clear leash")
        end
    elseif PendingAction == "pass" then
        if PendingActionUser == Leasher or policy_allows(POL_PASS, acl_level) then
            requestAclForPassTarget(PendingPassTarget)
            return  -- keep pending state
        else
            denyAccess(PendingActionUser, "insufficient permissions to pass leash")
        end
    elseif PendingAction == "offer" then
        if policy_allows(POL_OFFER, acl_level) and not Leashed then
            PendingIsOffer = true
            requestAclForPassTarget(PendingPassTarget)
            return  -- keep pending state
        elseif Leashed then
            ll.RegionSayTo(PendingActionUser, 0, "Cannot offer leash: already leashed.")
        else
            denyAccess(PendingActionUser, "insufficient permissions to offer leash")
        end
    elseif PendingAction == "pass_target_check" then
        if acl_level >= 1 then
            if PendingIsOffer then
                sendOfferPending(uuid(PendingPassTarget), PendingPassOriginalUser)
            else
                passLeashInternal(uuid(PendingPassTarget))
            end
        else
            local action_name = "pass"
            if PendingIsOffer then action_name = "offer" end
            ll.RegionSayTo(PendingPassOriginalUser, 0, "Cannot " .. action_name .. " leash: target has insufficient permissions.")
        end
        PendingPassOriginalUser = NULL_KEY
        PendingIsOffer = false
    elseif PendingAction == "grab" then
        local label = POL_CLIP
        if Leashed then label = POL_TAKE end
        if policy_allows(label, acl_level) then claimLeash(PendingActionUser, MODE_AVATAR, NULL_KEY, acl_level)
        else denyAccess(PendingActionUser, "insufficient permissions") end
    elseif PendingAction == "coffle" then
        if policy_allows(POL_COFFLE, acl_level) then claimLeash(PendingActionUser, MODE_COFFLE, uuid(PendingPassTarget), acl_level)
        else denyAccess(PendingActionUser, "insufficient permissions") end
    elseif PendingAction == "post" then
        if policy_allows(POL_POST, acl_level) then claimLeash(PendingActionUser, MODE_POST, uuid(PendingPassTarget), acl_level)
        else denyAccess(PendingActionUser, "insufficient permissions") end
    elseif PendingAction == "set_length" then
        if policy_allows(POL_SETTINGS, acl_level) then setLengthInternal(integer(PendingPassTarget))
        else denyAccess(PendingActionUser, "insufficient permissions") end
    elseif PendingAction == "toggle_turn" then
        if policy_allows(POL_SETTINGS, acl_level) then toggleTurnInternal()
        else denyAccess(PendingActionUser, "insufficient permissions") end
    elseif PendingAction == "set_texture" then
        if policy_allows(POL_SETTINGS, acl_level) then setTextureInternal(PendingPassTarget)
        else denyAccess(PendingActionUser, "insufficient permissions") end
    end

    clearPendingAction()
end

--[[ -------------------- OFFSIM DETECTION & AUTO-RECLIP -------------------- ]]

function clearReclipState()
    ReclipScheduled = 0
    LastLeasher = NULL_KEY
    ReclipAttempts = 0
    ReclipDeadline = 0
end

function checkLeasherPresence()
    if not Leashed or Leasher == NULL_KEY then return end

    local now_time = ll.GetUnixTime()
    local avatar_present = ll.GetAgentInfo(Leasher) ~= 0
    local holder_present = false
    if HolderTarget ~= NULL_KEY then
        holder_present = #ll.GetObjectDetails(HolderTarget, {OBJECT_POS}) > 0
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

function autoReleaseOffsim()
    clearLeashState(false)  -- keep reclip state so we can re-clip
    ll.RegionSayTo(ll.GetOwner(), 0, "Auto-released (offsim)")
end

function checkAutoReclip()
    if ReclipScheduled == 0 or now() < ReclipScheduled then return end

    if ReclipDeadline ~= 0 and now() >= ReclipDeadline then
        clearReclipState()
        return
    end
    if ReclipAttempts >= MAX_RECLIP_ATTEMPTS then
        clearReclipState()
        return
    end

    if LastLeasher ~= NULL_KEY and ll.GetAgentInfo(LastLeasher) ~= 0 then
        requestAclForAction(LastLeasher, "grab", tostring(NULL_KEY))
        ReclipAttempts += 1
        ReclipScheduled = now() + 2
    end
end

--[[ -------------------- FOLLOW MECHANICS -------------------- ]]

function leashFollowTarget()
    return FollowTarget
end

function updateControlsMask()
    if not ControlsOk then return end
    local should_expand = Leashed and (AtLimit or YankTargetHandle ~= 0)
    if should_expand == ControlsExpanded then return end
    ControlsExpanded = should_expand
    local mask = CONTROL_ML_LBUTTON
    if should_expand then
        mask = bit32.bor(mask, CONTROL_FWD, CONTROL_BACK, CONTROL_LEFT, CONTROL_RIGHT, CONTROL_ROT_LEFT, CONTROL_ROT_RIGHT)
    end
    ll.TakeControls(mask, false, true)
end

function startFollow()
    if not Leashed then return end
    FollowActive = true
    -- RLV @follow only for avatar targets (static prims can't be followed).
    if FollowIsAvatar and FollowTarget ~= NULL_KEY then
        ll.OwnerSay("@follow:" .. tostring(FollowTarget) .. "=force")
    end
    ll.RequestPermissions(ll.GetOwner(), PERMISSION_TAKE_CONTROLS)
end

function stopFollow()
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

function turnToTarget(target_pos)
    if not TurnToFace or not Leashed then return end
    local wearer_pos = ll.GetRootPosition()
    local direction = ll.VecNorm(target_pos - wearer_pos)
    local angle = ll.Atan2(direction.y, direction.x)
    if ll.Fabs(angle - LastTurnAngle) > TURN_THRESHOLD then
        ll.OwnerSay("@setrot:" .. tostring(angle) .. "=force")
        LastTurnAngle = angle
    end
end

function followTick()
    if not FollowActive or not Leashed then return end

    local follow_target = leashFollowTarget()
    if follow_target == NULL_KEY then return end

    -- Prefer the discovered LeashPoint prim over the raw anchor.
    local target_key = follow_target
    if HolderTarget ~= NULL_KEY then target_key = HolderTarget end

    local details = ll.GetObjectDetails(target_key, {OBJECT_POS})

    -- HolderTarget vanished: drop it, retry with the raw fallback.
    if #details == 0 and target_key == HolderTarget then
        HolderTarget = NULL_KEY
        updateParticlesTarget(follow_target)
        target_key = follow_target
        details = ll.GetObjectDetails(target_key, {OBJECT_POS})
    end

    if #details == 0 then return end
    local target_pos = details[1]

    local wearer_pos = ll.GetRootPosition()
    local distance = ll.VecDist(wearer_pos, target_pos)

    local new_at_limit = distance >= LeashLength
    if new_at_limit ~= AtLimit then
        AtLimit = new_at_limit
        updateControlsMask()
    end

    if ControlsOk and distance > LeashLength then
        -- Pull to 0.85 * length so there is slack on arrival.
        local pull_pos = target_pos + ll.VecNorm(wearer_pos - target_pos) * LeashLength * 0.85
        if ll.VecMag(pull_pos - LastTargetPos) > 0.2 then
            ll.MoveToTarget(pull_pos, 1.0)
            LastTargetPos = pull_pos
        end
        if TurnToFace and follow_target ~= NULL_KEY then
            turnToTarget(target_pos)
        end
    else
        -- In range: release the move target (unless a yank is in flight).
        if LastTargetPos ~= ZERO_VECTOR and YankTargetHandle == 0 then
            ll.StopMoveToTarget()
            LastTargetPos = ZERO_VECTOR
        end
    end
end

--[[ -------------------- STATE BROADCAST -------------------- ]]

function broadcastState()
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

function setLengthInternal(length: number)
    LeashLength = clampLeashLength(length)
    persistSetting(KEY_LEASH_LENGTH, tostring(LeashLength))
    broadcastState()
end

function toggleTurnInternal()
    TurnToFace = not TurnToFace
    if not TurnToFace then
        ll.OwnerSay("@setrot=clear")
        LastTurnAngle = -999.0
    end
    persistSetting(KEY_LEASH_TURNTO, tostring(b2i(TurnToFace)))
    broadcastState()
end

function setTextureInternal(texture: string)
    if texture ~= "chain" and texture ~= "silk" and texture ~= "invisible" then return end
    if texture == LeashTexture then
        broadcastState()
        return
    end
    LeashTexture = texture
    persistSetting(KEY_LEASH_TEXTURE, texture)
    broadcastState()

    if Leashed then
        local t = HolderTarget
        if t == NULL_KEY then t = leashFollowTarget() end
        if t ~= NULL_KEY then setParticlesState(true, t) end
    end
end

--[[ -------------------- UNIFIED LEASH CLAIM -------------------- ]]

function claimLeash(user, mode: number, target_key, acl_level: number)
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

    local follow_target, follow_is_avatar, notice

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
        follow_target = details[3]  -- OBJECT_OWNER = wearer of the target collar
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
        notice = "Posted to " .. details[2]
    end

    setLeashState(user, follow_target, follow_is_avatar, mode)
    sendProtoStart(user)
    -- LM authorization only when the wearer follows the controller (grab).
    if follow_target == user and follow_is_avatar then
        AuthorizedLmController = user
        setLockmeisterState(true, user)
    end
    startFollow()
    ll.RegionSayTo(user, 0, notice)
end

--[[ -------------------- AVATAR-SPECIFIC FLOWS -------------------- ]]

function releaseLeashInternal(user)
    if not Leashed then
        ll.RegionSayTo(user, 0, "Not currently leashed.")
        return
    end
    clearLeashState(true)
    ll.RegionSayTo(user, 0, "Leash released")
end

function passLeashInternal(new_leasher)
    if not Leashed then return end
    local old_leasher = Leasher

    -- Pass = full transfer; revert to avatar mode.
    setLeashState(new_leasher, new_leasher, true, MODE_AVATAR)
    sendProtoStart(new_leasher)

    AuthorizedLmController = new_leasher
    setLockmeisterState(true, new_leasher)

    startFollow()  -- re-issue @follow against the new leasher
    notifyLeashTransfer(old_leasher, new_leasher, "passed")
end

function yankToLeasher()
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

-- LM grab is avatar-only: flip into MODE_AVATAR with the controller as leasher.
function handleLmGrabbed(controller)
    if Leashed then return end
    setLeashState(controller, controller, true, MODE_AVATAR)
    startFollow()
    ll.RegionSayTo(ll.GetOwner(), 0, "Leashed by " .. ll.Key2Name(controller) .. " (Lockmeister)")
end

function handleLmReleased()
    if not Leashed then return end
    local old_leasher = Leasher
    clearLeashState(true)
    ll.RegionSayTo(ll.GetOwner(), 0, "Released by " .. ll.Key2Name(old_leasher) .. " (Lockmeister)")
end

--[[ -------------------- EVENT HANDLERS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end

    HolderTarget = NULL_KEY
    clearPendingAction()
    AuthorizedLmController = NULL_KEY

    sendProtoShutdown()  -- proto owns the handshake listeners; start it clean

    applySettingsSync()
    ll.SetTimerEvent(FOLLOW_TICK)
    ll.RequestPermissions(ll.GetOwner(), PERMISSION_TAKE_CONTROLS)
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

function LLEvents.run_time_permissions(perm: number)
    if bit32.band(perm, PERMISSION_TAKE_CONTROLS) ~= 0 then
        ControlsOk = true
        -- Baseline ML_LBUTTON keeps the takecontrols-sticky exemption alive.
        ll.TakeControls(CONTROL_ML_LBUTTON, false, true)
        ControlsExpanded = false
        updateControlsMask()
    end
end

function LLEvents.control(id, level: number, edge: number)
    if not Leashed then return end
    local pressed = bit32.band(level, edge)
    local directional = bit32.bor(CONTROL_FWD, CONTROL_BACK, CONTROL_LEFT, CONTROL_RIGHT, CONTROL_ROT_LEFT, CONTROL_ROT_RIGHT)
    if bit32.band(pressed, directional) == 0 then return end

    local follow_target = leashFollowTarget()
    if follow_target == NULL_KEY then return end

    local target_key = follow_target
    if HolderTarget ~= NULL_KEY then target_key = HolderTarget end

    local details = ll.GetObjectDetails(target_key, {OBJECT_POS})
    if #details == 0 then return end
    local target_pos = details[1]

    local wearer_pos = ll.GetRootPosition()
    if ll.VecDist(wearer_pos, target_pos) < LeashLength then return end

    -- Soft corrective pull (bridges the 1Hz tick; only correction in post mode).
    local pull_pos = target_pos + ll.VecNorm(wearer_pos - target_pos) * LeashLength * 0.85
    ll.MoveToTarget(pull_pos, 1.0)
    LastTargetPos = pull_pos
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
                        local wait_time = integer(YANK_COOLDOWN - (now_time - LastYankTime))
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

            -- All other actions require ACL verification.
            local target = jsonGet(msg, "target", tostring(NULL_KEY))
            if action == "set_length" then
                target = jsonGet(msg, "length", "0")
            elseif action == "set_texture" then
                target = jsonGet(msg, "texture", "chain")
            end

            requestAclForAction(user, action, target)
            return
        end

        if msg_type == "sos.leash.release" then
            if id == ll.GetOwner() then releaseLeashInternal(id) end
            return
        end

        if msg_type == "particles.lm.grabbed" then
            local controller = uuid(jsonGet(msg, "controller", tostring(NULL_KEY)))
            if controller == NULL_KEY then return end
            if controller ~= AuthorizedLmController then return end
            handleLmGrabbed(controller)
            return
        end

        if msg_type == "particles.lm.released" then
            handleLmReleased()
            return
        end
        return
    end

    if num == AUTH_BUS then
        if msg_type == "auth.acl.result" then handleAclResult(msg) end
        return
    end

    if num == SETTINGS_BUS then
        if msg_type == "settings.sync" then
            applySettingsSync()
        elseif msg_type == "leash.proto.holder" then
            if not Leashed then return end  -- drop late holder after unclip
            HolderTarget = uuid(jsonGet(msg, "holder", tostring(NULL_KEY)))
            if HolderTarget ~= NULL_KEY then setParticlesState(true, HolderTarget) end
        elseif msg_type == "leash.proto.fallback" then
            if not Leashed then return end
            local fallback = uuid(jsonGet(msg, "target", tostring(NULL_KEY)))
            if fallback ~= NULL_KEY then setParticlesState(true, fallback) end
        end
        return
    end
end

function LLEvents.timer()
    TickCount += 1

    -- Offsim/auto-release (~4s cadence at 1.0s FOLLOW_TICK).
    if (TickCount % 4) == 0 then
        if Leashed then checkLeasherPresence() end
        if not Leashed and ReclipScheduled ~= 0 then checkAutoReclip() end
    end

    -- Re-acquire a leashpoint every ~10s while leashed but anchorless.
    if (TickCount % 10) == 0 then
        if Leashed and HolderTarget == NULL_KEY and Leasher ~= NULL_KEY then
            sendProtoStart(Leasher)
        end
    end

    if FollowActive and Leashed then followTick() end
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

-- Top-level init.
main()

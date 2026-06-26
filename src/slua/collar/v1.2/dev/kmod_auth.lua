--[[--------------------
MODULE: kmod_auth.lua  (SLua port)
VERSION: 1.2
REVISION: 6  (SLua port rev 1)
PURPOSE: Authoritative ACL engine over the user-record roster
ARCHITECTURE: JSON response builder. The roster lives in LSD as
  user.<uuid> = "<acl>,<rank>,<name>,<honorific>" records (written solely by
  kmod_settings); this module only reads them. Consumers with a hot path
  (kmod_ui, kmod_chat) compute ACL from the same records directly — kmod_auth
  remains the authoritative responder for async auth.acl.query traffic and the
  sole broadcaster of auth.acl.update on roster/flag changes. Readiness is gated
  on the settings.bootstrapped sentinel (an LSD fact), not on any settings.sync.

SLUA PORT NOTES:
- Ported from kmod_auth.lsl v1.2 rev 6. The AUTH_BUS (700) wire protocol is
  preserved exactly: auth.acl.query / auth.acl.result / auth.acl.update keep
  their JSON shapes (type/avatar/level/is_wearer/is_blacklisted/owner_set/id),
  so LSL plugins and external HUD queries interoperate unchanged during the
  incremental port.
- IDIOMATIC: the LSL kept eight pre-built JSON template strings plus an
  OWNER_SET_PLACEHOLDER substring-substitution hack (an LSL micro-optimization
  to avoid rebuilding JSON). That collapses into one send_acl() builder that
  takes the result fields directly — route_acl_query already knew the right
  owner_set per branch, so the placeholder dance was pure ceremony. No wire
  change.
- IDIOMATIC: the stride-2 PendingQueries list ([avatar, id, ...]) becomes an
  array of { av, cid } records; FIFO-capped at MAX_PENDING_QUERIES.
- GOTCHA: LSL's (integer) cast is lenient — (integer)"3,5,Nia,Miss" == 3 and
  (integer)"" == 0. Lua tonumber() is strict (returns nil on both), so the
  leading-int parse of a CSV record / flag goes through csv_lead_int() with a
  string.match anchor. This is the single most error-prone LSL->Lua difference
  in this module.
- Events are top-level LLEvents.* functions (no states); state_entry becomes
  main(), called once at the bottom. The single-timer debounce rides the same
  LLTimers set_timer shim the kernel uses.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
-- SETTINGS_BUS (800) is intentionally absent: readiness is sentinel-driven off
-- LSD (main + linkset_data), so kmod_auth never listens for settings.sync.
local KERNEL_LIFECYCLE = 500
local AUTH_BUS         = 700

--[[ -------------------- ACL CONSTANTS -------------------- ]]
local ACL_BLACKLIST     = -1
local ACL_NOACCESS      = 0
local ACL_PUBLIC        = 1
local ACL_OWNED         = 2
local ACL_TRUSTEE       = 3
local ACL_UNOWNED       = 4
local ACL_PRIMARY_OWNER = 5

--[[ -------------------- SETTINGS KEYS (CROSS-MODULE CONTRACT) -------------------- ]]
-- User records (written by kmod_settings): user.<uuid> =
-- "<acl>,<rank>,<name>,<honorific>". The leading field is the ACL.
local USER_PREFIX       = "user."

local KEY_ISOWNED       = "access.isowned"
local KEY_PUBLIC_ACCESS = "public.mode"
local KEY_TPE_MODE      = "tpe.mode"

-- Readiness gate: kmod_settings stamps KEY_SENTINEL once the roster is
-- bootstrapped. We serve as soon as it is NON-EMPTY (a durable fact any restart
-- re-reads) and flip ready the instant the stamp lands via linkset_data — no
-- settings.sync round-trip, no boot-order window to miss. Gating on presence
-- (not a specific value) decouples auth from the roster-format version.
local KEY_SENTINEL      = "settings.bootstrapped"

-- Debounce for the linkset_data-driven auth.acl.update: a card parse writes many
-- records back-to-back; one broadcast covers the burst.
local ACL_UPDATE_DEBOUNCE = 0.2

--[[ -------------------- STATE -------------------- ]]
-- Queries arriving before the roster is final (cold boot, card still parsing)
-- are queued so early touches can't read a half-built roster.
local SettingsReady      = false
local PendingQueries: {{ av: any, cid: string }} = {}  -- FIFO of parked queries
local MAX_PENDING_QUERIES = 50

-- Debounce flag for the auth.acl.update broadcast.
local AclUpdatePending   = false

--[[ -------------------- HELPERS -------------------- ]]

-- LSL (integer) cast equivalent for a leading signed integer. Returns 0 when the
-- string has no leading int (absent record, blank flag) — matching (integer)"".
local function csv_lead_int(s: string): number
    return tonumber(string.match(s, "^%s*(-?%d+)") or "") or 0
end

local function lsd_int(key: string): number
    return csv_lead_int(ll.LinksetDataRead(key))
end

-- ACL role for a uuid: 5/3/-1, or 0 when no record (the leading field of the
-- user.<uuid> record; absent record reads 0, same as the LSL).
local function user_role(avatar): number
    return csv_lead_int(ll.LinksetDataRead(USER_PREFIX .. tostring(avatar)))
end

local function has_owner(): number
    return lsd_int(KEY_ISOWNED)
end

--[[ -------------------- TIMER SHIM (single-timer over LLTimers) -------------------- ]]
-- Reproduces the LSL single-timer contract: set_timer(t>0) starts/replaces the
-- one timer; set_timer(0) stops it. Here it serves the one-shot acl.update
-- debounce — the callback fires once, broadcasts, then stops itself.
local _timerHandle = nil
local _on_timer  -- forward declaration; assigned below
local function set_timer(interval: number)
    if _timerHandle then
        LLTimers:off(_timerHandle)
        _timerHandle = nil
    end
    if interval > 0 then
        _timerHandle = LLTimers:every(interval, _on_timer)
    end
end

--[[ -------------------- RESPONSE BUILDER -------------------- ]]

-- Build + send one auth.acl.result. Replaces the eight LSL template globals and
-- the OWNER_SET_PLACEHOLDER substitution: every field is passed directly.
local function send_acl(avatar, level: number, is_wearer: number,
                        is_blacklisted: number, owner_set: number, cid: string)
    local fields = {
        "type", "auth.acl.result",
        "avatar", tostring(avatar),
        "level", level,
        "is_wearer", is_wearer,
        "is_blacklisted", is_blacklisted,
        "owner_set", owner_set,
    }
    if cid ~= "" then
        fields[#fields + 1] = "id"
        fields[#fields + 1] = cid
    end
    ll.MessageLinked(LINK_SET, AUTH_BUS, ll.List2Json(JSON_OBJECT, fields), NULL_KEY)
end

--[[ -------------------- ACL LEVEL COMPUTATION (DISPATCH ROUTER) -------------------- ]]

-- Determine ACL level from the user record + flags and answer. One LSD read for
-- named actors; wearer/stranger paths read the scalars.
local function route_acl_query(avatar, cid: string)
    local role = user_role(avatar)

    -- Blacklist first (most restrictive).
    if role == ACL_BLACKLIST then
        send_acl(avatar, ACL_BLACKLIST, 0, 1, 0, cid)
        return
    end

    -- Owner (highest privilege).
    if role == ACL_PRIMARY_OWNER then
        send_acl(avatar, ACL_PRIMARY_OWNER, 0, 0, 1, cid)
        return
    end

    local owner_set = has_owner()

    -- Wearer paths (the wearer never has a record).
    if avatar == ll.GetOwner() then
        if lsd_int(KEY_TPE_MODE) ~= 0 then
            send_acl(avatar, ACL_NOACCESS, 1, 0, owner_set, cid)
            return
        end
        if owner_set ~= 0 then
            send_acl(avatar, ACL_OWNED, 1, 0, 1, cid)
            return
        end
        send_acl(avatar, ACL_UNOWNED, 1, 0, 0, cid)
        return
    end

    -- Trustee.
    if role == ACL_TRUSTEE then
        send_acl(avatar, ACL_TRUSTEE, 0, 0, owner_set, cid)
        return
    end

    -- Public mode.
    if lsd_int(KEY_PUBLIC_ACCESS) ~= 0 then
        send_acl(avatar, ACL_PUBLIC, 0, 0, owner_set, cid)
        return
    end

    -- Unauthorized stranger: level -1 but NOT blacklisted, just no access.
    send_acl(avatar, ACL_BLACKLIST, 0, 0, owner_set, cid)
end

--[[ -------------------- ACL CHANGE BROADCAST -------------------- ]]

local function broadcast_acl_change(scope: string, avatar)
    ll.MessageLinked(LINK_SET, AUTH_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "auth.acl.update",
        "scope", scope,
        "avatar", tostring(avatar),
    }), NULL_KEY)
end

--[[ -------------------- MESSAGE HANDLERS -------------------- ]]

-- Answer every query parked while the roster was still being built, then clear
-- the queue. Called the instant the sentinel lands.
local function drain_pending_queries()
    for _, q in ipairs(PendingQueries) do
        route_acl_query(q.av, q.cid)
    end
    PendingQueries = {}
end

local function handle_acl_query(msg: string)
    local av_str = ll.JsonGetValue(msg, {"avatar"})
    if av_str == JSON_INVALID then return end
    local av = uuid(av_str)
    if av == NULL_KEY then return end

    local cid = ll.JsonGetValue(msg, {"id"})
    if cid == JSON_INVALID then cid = "" end

    if not SettingsReady then
        if #PendingQueries >= MAX_PENDING_QUERIES then
            table.remove(PendingQueries, 1)  -- drop oldest (FIFO)
        end
        PendingQueries[#PendingQueries + 1] = { av = av, cid = cid }
        return
    end

    route_acl_query(av, cid)
end

--[[ -------------------- EVENTS -------------------- ]]
-- In SLua these top-level functions are the event handlers (no states).

local function main()
    -- Ready iff the roster is already final (sentinel present). A lone restart
    -- of this module re-reads the durable sentinel and serves immediately; a
    -- cold boot reads not-ready and queues until the stamp lands (linkset_data).
    SettingsReady    = (ll.LinksetDataRead(KEY_SENTINEL) ~= "")
    PendingQueries   = {}
    AclUpdatePending = false
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
    elseif num == AUTH_BUS then
        if msg_type == "auth.acl.query" then
            handle_acl_query(msg)
        end
    end
    -- Readiness no longer rides SETTINGS_BUS — it is sentinel-driven (see main +
    -- linkset_data). The roster is read from LSD live; nothing to do on a sync.
end

-- Readiness + roster/flag changes, both driven straight off LSD:
--  * the sentinel landing is our readiness signal — flip ready and drain any
--    queued boot-time touches against the final roster.
--  * any user.* write/delete (or a flip of the isowned/tpe/public scalars) arms
--    a debounced auth.acl.update so session-holding consumers invalidate.
function LLEvents.linkset_data(action: number, name: string, value: string)
    if action == LINKSETDATA_RESET then return end

    if name == KEY_SENTINEL then
        if value ~= "" and not SettingsReady then
            SettingsReady = true
            drain_pending_queries()
            broadcast_acl_change("global", NULL_KEY)
        end
        return
    end

    local relevant = (string.sub(name, 1, #USER_PREFIX) == USER_PREFIX)
        or (name == KEY_ISOWNED)
        or (name == KEY_TPE_MODE)
        or (name == KEY_PUBLIC_ACCESS)
    if not relevant then return end

    if not AclUpdatePending then
        AclUpdatePending = true
        set_timer(ACL_UPDATE_DEBOUNCE)
    end
end

_on_timer = function()
    if AclUpdatePending then
        AclUpdatePending = false
        set_timer(0)  -- one-shot: stop the debounce timer
        broadcast_acl_change("global", NULL_KEY)
    end
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        ll.ResetScript()
    end
end

-- Top-level init: SLua runs this once at script start in place of state_entry.
main()

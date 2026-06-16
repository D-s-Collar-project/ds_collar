--[[--------------------
MODULE: kmod_auth.lua  (SLua port)
VERSION: 1.10
REVISION: 9  (SLua port rev 1)
PURPOSE: Authoritative ACL engine
ARCHITECTURE: ACL dispatch + linkset-data result cache

SLUA PORT NOTES:
- Ported from kmod_auth.lsl rev 9. AUTH_BUS (700) / SETTINGS_BUS (800) /
  KERNEL_LIFECYCLE (500) wire formats and the acl.* LSD contract (including the
  "<level>|<unix>" cache value read by kmod_ui) are byte-compatible with LSL.
- Idiomatic SLua:
  * the 8 pre-built JSON template strings + llJsonSetValue placeholder patching
    (a Mono speed hack) collapse into one send_acl() builder plus an ACL_META
    table for cache reconstruction;
  * the LSL "compare lists by serializing to JSON" content-equality workaround
    becomes a plain lists_equal() helper;
  * the stride-2 PendingQueries list becomes an array of {av, corr} records;
  * integer-predicates return real booleans.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local AUTH_BUS = 700
local SETTINGS_BUS = 800

--[[ -------------------- ACL CONSTANTS -------------------- ]]
local ACL_BLACKLIST     = -1
local ACL_NOACCESS      = 0
local ACL_PUBLIC        = 1
local ACL_OWNED         = 2
local ACL_TRUSTEE       = 3
local ACL_UNOWNED       = 4
local ACL_PRIMARY_OWNER = 5

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_MULTI_OWNER_MODE = "access.multiowner"
local KEY_OWNER            = "access.owner"
local KEY_OWNER_UUIDS      = "access.owneruuids"
local KEY_TRUSTEE_UUIDS    = "access.trusteeuuids"
local KEY_BLACKLIST        = "blacklist.blklistuuid"
local KEY_PUBLIC_ACCESS    = "public.mode"
local KEY_TPE_MODE         = "tpe.mode"

--[[ -------------------- LINKSET DATA KEYS -------------------- ]]
local LSD_KEY_ACL_OWNERS    = "acl.owners"
local LSD_KEY_ACL_TRUSTEES  = "acl.trustees"
local LSD_KEY_ACL_BLACKLIST = "acl.blacklist"
local LSD_KEY_ACL_PUBLIC    = "acl.public"
local LSD_KEY_ACL_TPE       = "acl.wearertpe"
local LSD_KEY_ACL_TIMESTAMP = "acl.timestamp"

-- CROSS-MODULE CONTRACT: format must match kmod_ui's cache reader.
local LSD_ACL_CACHE_PREFIX = "acl."
local LSD_ACL_CACHE_SUFFIX = ".cache"

local CACHE_TTL = 60
local CACHE_MAX_USERS = 800

local MAX_PENDING_QUERIES = 50

--[[ -------------------- STATE (CACHED SETTINGS) -------------------- ]]
local MultiOwnerMode = false
local OwnerKey = NULL_KEY
local OwnerKeys = {}      -- array of uuid strings
local TrusteeList = {}    -- array of uuid strings
local Blacklist = {}      -- array of uuid strings
local PublicMode = false
local TpeMode = false

local SettingsReady = false
local PendingQueries = {}  -- array of { av = uuid, corr = string }

-- Per-ACL-level response metadata used to reconstruct a result from a cached
-- level. owner_set is fixed unless dyn=true (then it follows has_owner()).
-- Note: cache only ever stores these levels; the "unauthorized stranger" -1
-- variant is never cached, so [-1] unambiguously means blacklisted here.
local ACL_META = {
    [ACL_BLACKLIST]     = { is_wearer = 0, is_blacklisted = 1, owner_set = 0 },
    [ACL_NOACCESS]      = { is_wearer = 1, is_blacklisted = 0, dyn = true },
    [ACL_PUBLIC]        = { is_wearer = 0, is_blacklisted = 0, dyn = true },
    [ACL_OWNED]         = { is_wearer = 1, is_blacklisted = 0, owner_set = 1 },
    [ACL_TRUSTEE]       = { is_wearer = 0, is_blacklisted = 0, dyn = true },
    [ACL_UNOWNED]       = { is_wearer = 1, is_blacklisted = 0, owner_set = 0 },
    [ACL_PRIMARY_OWNER] = { is_wearer = 0, is_blacklisted = 0, owner_set = 1 },
}

--[[ -------------------- HELPERS -------------------- ]]

--[[ integer(): SLua has no LSL-style (integer) cast; emulate it (truncate toward zero; non-numeric -> 0). ]]
local function integer(v): number
    local n = tonumber(v)
    if n == nil then return 0 end
    if n < 0 then return math.ceil(n) end
    return math.floor(n)
end

local function list_find(t, v)
    for i, x in ipairs(t) do
        if x == v then return i end
    end
    return nil
end

local function list_has_key(search_list, k): boolean
    return list_find(search_list, tostring(k)) ~= nil
end

local function remove_value(t, v)
    local idx = list_find(t, v)
    if idx ~= nil then table.remove(t, idx) end
end

local function lists_equal(a, b): boolean
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

--[[ -------------------- OWNER CHECKING -------------------- ]]

local function has_owner(): boolean
    if MultiOwnerMode then return #OwnerKeys > 0 end
    return OwnerKey ~= NULL_KEY
end

local function is_owner(av): boolean
    if MultiOwnerMode then return list_has_key(OwnerKeys, av) end
    return av == OwnerKey
end

--[[ -------------------- RESULT BUILDER -------------------- ]]

local function send_acl(avatar, level: number, is_wearer: number, is_blacklisted: number,
                        owner_set: number, correlation_id: string)
    local fields = {
        "type", "auth.acl.result",
        "avatar", tostring(avatar),
        "level", level,
        "is_wearer", is_wearer,
        "is_blacklisted", is_blacklisted,
        "owner_set", owner_set,
    }
    if correlation_id ~= "" then
        fields[#fields + 1] = "id"
        fields[#fields + 1] = correlation_id
    end
    ll.MessageLinked(LINK_SET, AUTH_BUS, ll.List2Json(JSON_OBJECT, fields), NULL_KEY)
end

-- Reconstruct a response from a cached level (sliding-window cache-hit path).
local function send_acl_from_level(avatar, level: number, correlation_id: string)
    local m = ACL_META[level]
    if m == nil then return end
    local owner_set = m.owner_set or 0
    if m.dyn then owner_set = (has_owner() and 1) or 0 end
    send_acl(avatar, level, m.is_wearer, m.is_blacklisted, owner_set, correlation_id)
end

--[[ -------------------- LINKSET DATA CACHE -------------------- ]]

local function get_cache_key(avatar): string
    return LSD_ACL_CACHE_PREFIX .. tostring(avatar) .. LSD_ACL_CACHE_SUFFIX
end

-- Clear all cached ACL query results (regex search runs in the simulator).
local function clear_acl_query_cache()
    for _, k in ipairs(ll.LinksetDataFindKeys("^acl\\.[0-9a-f-]+\\.cache$", 1, -1)) do  -- SLua: start 1-based, count -1 = all
        ll.LinksetDataDelete(k)
    end
end

local function store_cached_acl(avatar, level: number)
    if ll.LinksetDataCountKeys() > CACHE_MAX_USERS then return end  -- full; let TTL prune
    ll.LinksetDataWrite(get_cache_key(avatar), tostring(level) .. "|" .. tostring(ll.GetUnixTime()))
end

-- Try cached result. Returns true (and sends the response) on a fresh hit.
-- Sliding window: TTL resets on access so active sessions stay cached.
local function get_cached_acl(avatar, correlation_id: string): boolean
    local cache_key = get_cache_key(avatar)
    local cached = ll.LinksetDataRead(cache_key)
    if cached == "" then return false end

    local sep = string.find(cached, "|", 1, true)
    if sep == nil then
        ll.LinksetDataDelete(cache_key)  -- corrupted
        return false
    end

    local cached_time = integer(string.sub(cached, sep + 1))
    local current = ll.GetUnixTime()
    if (current - cached_time) > CACHE_TTL then
        ll.LinksetDataDelete(cache_key)
        return false
    end

    local level = integer(string.sub(cached, 1, sep - 1))
    ll.LinksetDataWrite(cache_key, tostring(level) .. "|" .. tostring(current))  -- reset TTL
    send_acl_from_level(avatar, level, correlation_id)
    return true
end

-- Persist ACL role lists to LSD and bump the timestamp; then clear the query
-- cache (precompute_known_acl re-populates known actors immediately after).
local function persist_acl_cache()
    local owners_payload = {}
    if MultiOwnerMode then
        owners_payload = OwnerKeys
    elseif OwnerKey ~= NULL_KEY then
        owners_payload = { tostring(OwnerKey) }
    end

    ll.LinksetDataWrite(LSD_KEY_ACL_OWNERS,    ll.List2Json(JSON_ARRAY, owners_payload))
    ll.LinksetDataWrite(LSD_KEY_ACL_TRUSTEES,  ll.List2Json(JSON_ARRAY, TrusteeList))
    ll.LinksetDataWrite(LSD_KEY_ACL_BLACKLIST, ll.List2Json(JSON_ARRAY, Blacklist))
    ll.LinksetDataWrite(LSD_KEY_ACL_PUBLIC,    tostring((PublicMode and 1) or 0))
    ll.LinksetDataWrite(LSD_KEY_ACL_TPE,       tostring((TpeMode and 1) or 0))
    ll.LinksetDataWrite(LSD_KEY_ACL_TIMESTAMP, tostring(ll.GetUnixTime()))

    clear_acl_query_cache()
end

--[[ -------------------- PER-ACL HANDLERS -------------------- ]]

local function process_blacklist_query(avatar, corr: string)
    send_acl(avatar, ACL_BLACKLIST, 0, 1, 0, corr)
    store_cached_acl(avatar, ACL_BLACKLIST)
end

-- Unauthorized stranger: not blacklisted, just no access. Never cached (their
-- ACL can change at any time via owner/trustee add or public toggle).
local function process_unauthorized_query(avatar, corr: string)
    send_acl(avatar, ACL_BLACKLIST, 0, 0, (has_owner() and 1) or 0, corr)
end

local function process_noaccess_query(avatar, corr: string)
    send_acl(avatar, ACL_NOACCESS, 1, 0, (has_owner() and 1) or 0, corr)
    store_cached_acl(avatar, ACL_NOACCESS)
end

local function process_public_query(avatar, corr: string)
    send_acl(avatar, ACL_PUBLIC, 0, 0, (has_owner() and 1) or 0, corr)
    store_cached_acl(avatar, ACL_PUBLIC)
end

local function process_owned_query(avatar, corr: string)
    send_acl(avatar, ACL_OWNED, 1, 0, 1, corr)
    store_cached_acl(avatar, ACL_OWNED)
end

local function process_trustee_query(avatar, corr: string)
    send_acl(avatar, ACL_TRUSTEE, 0, 0, (has_owner() and 1) or 0, corr)
    store_cached_acl(avatar, ACL_TRUSTEE)
end

local function process_unowned_query(avatar, corr: string)
    send_acl(avatar, ACL_UNOWNED, 1, 0, 0, corr)
    store_cached_acl(avatar, ACL_UNOWNED)
end

local function process_primary_owner_query(avatar, corr: string)
    send_acl(avatar, ACL_PRIMARY_OWNER, 0, 0, 1, corr)
    store_cached_acl(avatar, ACL_PRIMARY_OWNER)
end

--[[ -------------------- ACL LEVEL COMPUTATION (DISPATCH ROUTER) -------------------- ]]

local function route_acl_query(avatar, correlation_id: string)
    local wearer = ll.GetOwner()
    local owner_set = has_owner()
    local is_wearer = (avatar == wearer)

    if list_has_key(Blacklist, avatar) then
        process_blacklist_query(avatar, correlation_id)
        return
    end
    if is_owner(avatar) then
        process_primary_owner_query(avatar, correlation_id)
        return
    end
    if is_wearer then
        if TpeMode then
            process_noaccess_query(avatar, correlation_id)
            return
        end
        if owner_set then
            process_owned_query(avatar, correlation_id)
            return
        end
        process_unowned_query(avatar, correlation_id)
        return
    end
    if list_has_key(TrusteeList, avatar) then
        process_trustee_query(avatar, correlation_id)
        return
    end
    if PublicMode then
        process_public_query(avatar, correlation_id)
        return
    end
    process_unauthorized_query(avatar, correlation_id)
end

-- Pre-populate the cache for all known actors after a settings load/change so
-- their touches skip the AUTH_BUS round-trip. Strangers still cold-miss.
local function precompute_known_acl()
    route_acl_query(ll.GetOwner(), "")
    if MultiOwnerMode then
        for _, s in ipairs(OwnerKeys) do route_acl_query(uuid(s), "") end
    elseif OwnerKey ~= NULL_KEY then
        route_acl_query(OwnerKey, "")
    end
    for _, s in ipairs(TrusteeList) do route_acl_query(uuid(s), "") end
end

--[[ -------------------- ACL CHANGE BROADCAST -------------------- ]]

local function broadcast_acl_change(scope: string, avatar)
    ll.MessageLinked(LINK_SET, AUTH_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "auth.acl.update",
        "scope", scope,
        "avatar", tostring(avatar),
    }), NULL_KEY)
end

--[[ -------------------- ROLE EXCLUSIVITY -------------------- ]]

local function enforce_role_exclusivity()
    local owners = {}
    if MultiOwnerMode then
        owners = OwnerKeys
    elseif OwnerKey ~= NULL_KEY then
        owners = { tostring(OwnerKey) }
    end
    for _, owner in ipairs(owners) do
        remove_value(TrusteeList, owner)
        remove_value(Blacklist, owner)
    end
    for _, trustee in ipairs(TrusteeList) do
        remove_value(Blacklist, trustee)
    end
end

--[[ -------------------- SETTINGS CONSUMPTION -------------------- ]]

local function apply_settings_sync()
    local prev_multi = MultiOwnerMode
    local prev_owner = OwnerKey
    local prev_owners = OwnerKeys
    local prev_trustees = TrusteeList
    local prev_blacklist = Blacklist
    local prev_public = PublicMode
    local prev_tpe = TpeMode

    MultiOwnerMode = false
    OwnerKey = NULL_KEY
    OwnerKeys = {}
    TrusteeList = {}
    Blacklist = {}
    PublicMode = false
    TpeMode = false

    local tmp = ll.LinksetDataRead(KEY_MULTI_OWNER_MODE)
    if tmp ~= "" then MultiOwnerMode = integer(tmp) ~= 0 end

    if MultiOwnerMode then
        local raw = ll.LinksetDataRead(KEY_OWNER_UUIDS)
        if raw ~= "" then
            OwnerKeys = ll.CSV2List(raw)
            if #OwnerKeys > 0 then OwnerKey = uuid(OwnerKeys[1]) end
        end
    else
        local raw = ll.LinksetDataRead(KEY_OWNER)
        if raw ~= "" then OwnerKey = uuid(raw) end
    end

    local trustees_raw = ll.LinksetDataRead(KEY_TRUSTEE_UUIDS)
    if trustees_raw ~= "" then TrusteeList = ll.CSV2List(trustees_raw) end

    local bl_raw = ll.LinksetDataRead(KEY_BLACKLIST)
    if bl_raw ~= "" then Blacklist = ll.CSV2List(bl_raw) end

    tmp = ll.LinksetDataRead(KEY_PUBLIC_ACCESS)
    if tmp ~= "" then PublicMode = integer(tmp) ~= 0 end

    tmp = ll.LinksetDataRead(KEY_TPE_MODE)
    if tmp ~= "" then TpeMode = integer(tmp) ~= 0 end

    enforce_role_exclusivity()

    -- Detect any ACL-relevant change (content equality via lists_equal).
    local acl_changed = false
    if MultiOwnerMode ~= prev_multi then acl_changed = true end
    if OwnerKey ~= prev_owner then acl_changed = true end
    if PublicMode ~= prev_public then acl_changed = true end
    if TpeMode ~= prev_tpe then acl_changed = true end
    if not lists_equal(OwnerKeys, prev_owners) then acl_changed = true end
    if not lists_equal(TrusteeList, prev_trustees) then acl_changed = true end
    if not lists_equal(Blacklist, prev_blacklist) then acl_changed = true end

    if acl_changed then
        persist_acl_cache()
        broadcast_acl_change("global", NULL_KEY)
        precompute_known_acl()
    end

    -- First load: always persist + broadcast even if "unchanged" (defaults).
    if not SettingsReady then
        if not acl_changed then
            persist_acl_cache()
            broadcast_acl_change("global", NULL_KEY)
            precompute_known_acl()
        end
        SettingsReady = true
    end

    -- Drain pending queries.
    for _, q in ipairs(PendingQueries) do
        route_acl_query(q.av, q.corr)
    end
    PendingQueries = {}
end

--[[ -------------------- MESSAGE HANDLERS -------------------- ]]

local function handle_acl_query(msg: string)
    local av_str = ll.JsonGetValue(msg, {"avatar"})
    if av_str == JSON_INVALID then return end
    local av = uuid(av_str)
    if av == NULL_KEY then return end

    local correlation_id = ll.JsonGetValue(msg, {"id"})
    if correlation_id == JSON_INVALID then correlation_id = "" end

    if not SettingsReady then
        if #PendingQueries >= MAX_PENDING_QUERIES then table.remove(PendingQueries, 1) end
        PendingQueries[#PendingQueries + 1] = { av = av, corr = correlation_id }
        return
    end

    if get_cached_acl(av, correlation_id) then return end
    route_acl_query(av, correlation_id)
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end

    SettingsReady = false
    PendingQueries = {}
    apply_settings_sync()  -- read settings directly from LSD
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
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
    elseif num == SETTINGS_BUS then
        if msg_type == "settings.sync" then
            apply_settings_sync()
        end
    end
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        ll.ResetScript()
    end
end

-- Top-level init.
main()

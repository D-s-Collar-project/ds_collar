--[[--------------------
MODULE: kmod_settings.lua  (SLua port)
VERSION: 1.2
REVISION: 9  (SLua port rev 1)
PURPOSE: Validation guards, roster conversion, and the LSD settings store.
ARCHITECTURE: People live in user.<uuid> = "<acl>,<rank>,<name>,<honorific>" records
  (acl 5 owner / 3 trustee / -1 blacklist). kmod_settings is the SOLE writer of
  user.* and of the MANAGED_SETTINGS_KEYS, mutated via the CSV-envelope
  settings.delta/delete/seed protocol (no JSON parse on that path) + the dedicated
  owner/trustee/blacklist messages. The notecard is an OVERRIDE, streamed by
  kmod_bootstrap and converted here on settings.card.streamed.

SLUA PORT NOTES:
- Ported from kmod_settings.lsl v1.2 rev 9. Wire/CROSS-MODULE contracts preserved
  exactly: the settings.delta/delete/seed CSV envelope, the dedicated roster
  messages, settings.card.streamed conversion, settings.sync broadcast, the
  user.<uuid> record format, and the rlv/auth flag keys. Stays the sole user.* writer.
- IDIOMATIC: the parallel NameQueryIds/Uuids lists become an array of {qid, uuid}
  records; role_uuids' strided [rank,uuid] list becomes an array of records,
  rank-sorted via table.sort; MANAGED_SETTINGS_KEYS is a plain string array. The
  card honorific buffers stay arrays.
- GOTCHA: CSV-field index base. ll.CSV2List returns a 1-based table, but the record
  field convention (2=name, 3=honorific) is the LSL 0-based CSV index — user_set_field
  converts with field_idx + 1 at the single write site. role/rank parse off field [2].
- GOTCHA: 0-is-truthy. is_multi_owner_mode / has_external_owner return real Lua
  booleans (not the LSL 0/1 int), since both are used in `if` / `not`. csv_lead_int
  replaces the lenient (integer) casts on records/flags; normalize_bool returns "1"/"0".
- JSON-free delta path retained: the link_message CSV-prefix check runs BEFORE any
  ll.JsonGetValue, exactly as the LSL. san_field strips commas via
  ParseString2List + table.concat. uuid() normalizes key strings; names resolve async
  via ll.RequestDisplayName / ll.RequestUsername -> the dataserver -> handle_name_response.
- Single LSL state -> top-level LLEvents.*; state_entry becomes main().
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS     = 800

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_ISOWNED = "access.isowned"

local USER_PREFIX = "user."
local KEY_MULTI_OWNER_MODE = "access.multiowner"

-- Card-syntax tokens (deposited verbatim by kmod_bootstrap; built into records here).
local CARD_OWNER         = "access.owner"
local CARD_OWNER_NAME    = "access.ownername"
local CARD_OWNER_HON     = "access.ownerhonorific"
local CARD_OWNER_UUIDS   = "access.owneruuids"
local CARD_OWNER_NAMES   = "access.ownernames"
local CARD_OWNER_HONS    = "access.ownerhonorifics"
local CARD_TRUSTEE_UUIDS = "access.trusteeuuids"
local CARD_TRUSTEE_NAMES = "access.trusteenames"
local CARD_TRUSTEE_HONS  = "access.trusteehonorifics"
local CARD_BLACKLIST     = "blacklist.blklistuuid"

local KEY_RUNAWAY_ENABLED = "access.enablerunaway"

local KEY_PUBLIC_ACCESS = "public.mode"
local KEY_TPE_MODE      = "tpe.mode"
local KEY_LOCKED        = "lock.locked"

local KEY_SENTINEL      = "settings.bootstrapped"
local KEY_CARD_APPLIED  = "settings.cardapplied"

local NAME_LOADING = "(loading...)"

local NOTECARD_NAME = "settings"

--[[ -------------------- STATE -------------------- ]]
local LastOwner = NULL_KEY
local NotecardKey = NULL_KEY
local MaxListLen = 64

-- Pending name queries: {qid, uuid} records.
local NameQueries: {{ qid: any, uuid: string }} = {}

-- Card honorifics buffered during a parse (applied by rank at EOF).
local CardOwnerHons: {string} = {}
local CardTrusteeHons: {string} = {}

--[[ -------------------- HELPERS -------------------- ]]

local function get_msg_type(msg: string): string
    local t = ll.JsonGetValue(msg, {"type"})
    if t == JSON_INVALID then return "" end
    return t
end

local function csv_lead_int(s: string): number
    return tonumber(string.match(s, "^%s*(-?%d+)") or "") or 0
end

local function normalize_bool(s: string): string
    local v = csv_lead_int(s)
    if v ~= 0 then v = 1 end
    return tostring(v)
end

local function list_has(t: {string}, v: string): boolean
    for _, x in ipairs(t) do
        if x == v then return true end
    end
    return false
end

-- CSV field sanitizer — record fields may not contain commas.
local function san_field(s: string): string
    return table.concat(ll.ParseString2List(s, {","}, {}), " ")
end

--[[ -------------------- USER RECORD PRIMITIVES -------------------- ]]

local function user_read(uuid_str: string): string
    return ll.LinksetDataRead(USER_PREFIX .. uuid_str)
end

local function user_write(uuid_str: string, acl: number, rank: number, name_str: string, hon: string)
    ll.LinksetDataWrite(USER_PREFIX .. uuid_str,
        table.concat({tostring(acl), tostring(rank), san_field(name_str), san_field(hon)}, ","))
end

local function user_delete(uuid_str: string)
    ll.LinksetDataDelete(USER_PREFIX .. uuid_str)
end

-- Role of a uuid: 5/3/-1, or 0 when no record (the leading CSV field).
local function user_role(uuid_str: string): number
    local rec = user_read(uuid_str)
    if rec == "" then return 0 end
    return csv_lead_int(rec)
end

-- Update one field (field_idx is the 0-based CSV index: 2=name, 3=honorific).
local function user_set_field(uuid_str: string, field_idx: number, value: string)
    local rec = user_read(uuid_str)
    if rec == "" then return end
    local f = ll.CSV2List(rec)
    f[field_idx + 1] = san_field(value)  -- +1: 0-based CSV index -> 1-based table
    ll.LinksetDataWrite(USER_PREFIX .. uuid_str, table.concat(f, ","))
end

local function user_keys()
    return ll.LinksetDataFindKeys("^user\\.", 0, -1)
end

-- All uuids holding a role, rank-ordered (rank 0 first).
local function role_uuids(acl: number): {string}
    local ranked = {}  -- {rank, uuid} records
    for _, k in ipairs(user_keys()) do
        local rec = ll.LinksetDataRead(k)
        if csv_lead_int(rec) == acl then
            local f = ll.CSV2List(rec)
            ranked[#ranked + 1] = { rank = csv_lead_int(f[2] or "0"), uuid = ll.GetSubString(k, 5, -1) }
        end
    end
    table.sort(ranked, function(a, b) return a.rank < b.rank end)
    local uuids = {}
    for _, r in ipairs(ranked) do uuids[#uuids + 1] = r.uuid end
    return uuids
end

local function role_count(acl: number): number
    return #role_uuids(acl)
end

local function delete_role(acl: number)
    for _, k in ipairs(user_keys()) do
        if csv_lead_int(ll.LinksetDataRead(k)) == acl then
            ll.LinksetDataDelete(k)
        end
    end
end

-- Multi-owner POLICY flag (notecard-only). Real boolean (0-is-truthy guard).
local function is_multi_owner_mode(): boolean
    return csv_lead_int(ll.LinksetDataRead(KEY_MULTI_OWNER_MODE)) ~= 0
end

--[[ -------------------- BROADCASTING -------------------- ]]

local function broadcast_settings_changed()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "settings.sync",
    }), NULL_KEY)
end

-- Owner ADD/TRANSFER soft-reboots (roster + notecard KEPT).
local function request_owner_reboot()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.reset.soft",
        "from", "owner_change",
    }), NULL_KEY)
end

-- Ask kmod_bootstrap to (re-)stream the notecard into LSD.
local function request_card_restream()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "settings.card.restream",
    }), NULL_KEY)
end

--[[ -------------------- CSV WRITE PROTOCOL (settings.delta / delete / seed) -------------------- ]]

-- Keys kmod_settings manages on behalf of consumer plugins (the is_writable_key gate).
local MANAGED_SETTINGS_KEYS: {string} = {
    "lock.locked", "public.mode", "tpe.mode",
    "folders.locked", "outfits.locked", "plugin.outfit.active",
    "relay.mode", "relay.hardcoremode",
    "chat.prefix", "chat.channel", "chat.public",
    "safeword.word",
    "bell.visible", "bell.enablesound", "bell.volume", "bell.sound",
    "rlvex.ownertp", "rlvex.ownerim", "rlvex.trusteetp", "rlvex.trusteeim",
    "restrict.list", "access.enablerunaway", "leash.enhanced",
    "leash.leashedavatar", "leash.leasherkey", "leash.length",
    "leash.turnto", "leash.texture",
}

local function is_writable_key(lsd_key: string): boolean
    return list_has(MANAGED_SETTINGS_KEYS, lsd_key)
end

local function handle_settings_delta_csv(msg: string)
    -- KeepNulls preserves a trailing empty token (set foo="" must write, not drop).
    local parts = ll.ParseStringKeepNulls(msg, {":"}, {})
    if #parts ~= 3 then return end
    local lsd_key = parts[2]
    local value = parts[3]
    if lsd_key == "" or not is_writable_key(lsd_key) then return end
    ll.LinksetDataWrite(lsd_key, value)
    broadcast_settings_changed()
end

local function handle_settings_delete_csv(msg: string)
    local parts = ll.ParseString2List(msg, {":"}, {})
    if #parts ~= 2 then return end
    local lsd_key = parts[2]
    if lsd_key == "" or not is_writable_key(lsd_key) then return end
    ll.LinksetDataDelete(lsd_key)
    broadcast_settings_changed()
end

local function handle_settings_seed_csv(msg: string)
    -- Write a plugin's default ONLY IF ABSENT, and do NOT broadcast.
    local parts = ll.ParseStringKeepNulls(msg, {":"}, {})
    if #parts ~= 3 then return end
    local lsd_key = parts[2]
    local value = parts[3]
    if lsd_key == "" or not is_writable_key(lsd_key) then return end
    if ll.LinksetDataRead(lsd_key) ~= "" then return end  -- already set — never clobber
    ll.LinksetDataWrite(lsd_key, value)
end

--[[ -------------------- LSD CLEAR & FACTORY RESET -------------------- ]]

local function factory_reset()
    ll.RegionSayTo(ll.GetOwner(), 0, "Collar factory reset triggered.")

    -- Zero-trust: remove a possibly-poisoned notecard before wiping.
    if ll.GetInventoryType(NOTECARD_NAME) == INVENTORY_NOTECARD then
        ll.RemoveInventory(NOTECARD_NAME)
    end

    ll.LinksetDataReset()

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.reset.factory",
        "from", "factory_reset",
    }), NULL_KEY)

    ll.ResetScript()
end

--[[ -------------------- VALIDATION HELPERS -------------------- ]]

-- TRUE if any external owner exists.
local function has_external_owner(): boolean
    return role_count(5) > 0
end

--[[ -------------------- ASYNC NAME RESOLUTION -------------------- ]]

local function request_name(uuid_str: string)
    if uuid_str == "" or uuid(uuid_str) == NULL_KEY then return end
    NameQueries[#NameQueries + 1] = { qid = ll.RequestDisplayName(uuid(uuid_str)), uuid = uuid_str }
end

local function request_username(uuid_str: string)
    if uuid_str == "" or uuid(uuid_str) == NULL_KEY then return end
    NameQueries[#NameQueries + 1] = { qid = ll.RequestUsername(uuid(uuid_str)), uuid = uuid_str }
end

-- One response path for every role: a resolved name updates the record's name field.
local function handle_name_response(query_id, name: string)
    local idx = nil
    for i, q in ipairs(NameQueries) do
        if q.qid == query_id then
            idx = i
            break
        end
    end
    if idx == nil then return end

    local uuid_str = NameQueries[idx].uuid
    table.remove(NameQueries, idx)

    if name == "" then return end
    if user_read(uuid_str) == "" then return end

    user_set_field(uuid_str, 2, name)
    broadcast_settings_changed()
end

--[[ -------------------- INTERNAL MUTATORS -------------------- ]]

local function set_owner_record(uuid_str: string, honorific: string): boolean
    if uuid_str == "" or uuid(uuid_str) == NULL_KEY then return false end
    if uuid(uuid_str) == ll.GetOwner() then
        ll.RegionSayTo(ll.GetOwner(), 0, "ERROR: Cannot add wearer as owner (role separation required)")
        return false
    end

    delete_role(5)

    local nm = ll.GetUsername(uuid(uuid_str))
    if nm == "" then nm = NAME_LOADING end
    user_write(uuid_str, 5, 0, nm, honorific)
    ll.LinksetDataWrite(KEY_ISOWNED, "1")

    request_name(uuid_str)
    return true
end

local function add_trustee_internal(uuid_str: string, honorific: string): boolean
    if uuid_str == "" or uuid(uuid_str) == NULL_KEY then return false end
    if uuid(uuid_str) == ll.GetOwner() then return false end
    if user_role(uuid_str) == 5 then return false end
    if user_role(uuid_str) == 3 then return false end
    if role_count(3) >= MaxListLen then return false end

    local nm = ll.GetUsername(uuid(uuid_str))
    if nm == "" then nm = NAME_LOADING end
    user_write(uuid_str, 3, role_count(3), nm, honorific)

    request_name(uuid_str)
    return true
end

local function remove_trustee_internal(uuid_str: string): boolean
    if user_role(uuid_str) ~= 3 then return false end
    user_delete(uuid_str)
    return true
end

local function add_blacklist_internal(uuid_str: string, name_str: string): boolean
    if uuid_str == "" or uuid(uuid_str) == NULL_KEY then return false end
    if uuid(uuid_str) == ll.GetOwner() then return false end
    if user_role(uuid_str) == 5 then return false end
    if user_role(uuid_str) == 3 then return false end
    if user_role(uuid_str) == -1 then return false end
    if role_count(-1) >= MaxListLen then return false end

    -- Name chain: provided -> username -> UUID placeholder + async username upgrade.
    local nm = san_field(name_str)
    if nm == "" then nm = ll.GetUsername(uuid(uuid_str)) end
    if nm == "" then
        nm = uuid_str
        request_username(uuid_str)
    end

    user_write(uuid_str, -1, 0, nm, "")
    return true
end

local function remove_blacklist_internal(uuid_str: string): boolean
    if user_role(uuid_str) ~= -1 then return false end
    user_delete(uuid_str)
    return true
end

--[[ -------------------- CARD ROSTER BUILDERS -------------------- ]]

local function card_add_owner(uuid_str: string)
    local u = uuid(uuid_str)
    if u == NULL_KEY or u == ll.GetOwner() then return end
    if user_role(uuid_str) == 5 then return end

    if not is_multi_owner_mode() and role_count(5) >= 1 then
        ll.RegionSayTo(ll.GetOwner(), 0,
            "WARNING: Multi-owner mode is off — additional card owner ignored. Set access.multiowner = 1 in the notecard to allow several owners.")
        return
    end

    local nm = ll.GetUsername(u)
    if nm == "" then nm = NAME_LOADING end
    user_write(uuid_str, 5, role_count(5), nm, "")
    ll.LinksetDataWrite(KEY_ISOWNED, "1")
    request_name(uuid_str)
end

local function card_add_trustee(uuid_str: string)
    local u = uuid(uuid_str)
    if u == NULL_KEY or u == ll.GetOwner() then return end
    if user_role(uuid_str) == 5 then return end
    if user_role(uuid_str) == 3 then return end
    if role_count(3) >= MaxListLen then return end

    local nm = ll.GetUsername(u)
    if nm == "" then nm = NAME_LOADING end
    user_write(uuid_str, 3, role_count(3), nm, "")
    request_name(uuid_str)
end

-- Apply card honorific lines at EOF, by rank.
local function apply_card_honorifics()
    local owners = role_uuids(5)
    local n = #CardOwnerHons
    if n > #owners then n = #owners end
    for i = 1, n do
        user_set_field(owners[i], 3, CardOwnerHons[i])
    end

    local trustees = role_uuids(3)
    n = #CardTrusteeHons
    if n > #trustees then n = #trustees end
    for i = 1, n do
        user_set_field(trustees[i], 3, CardTrusteeHons[i])
    end

    CardOwnerHons = {}
    CardTrusteeHons = {}
end

--[[ -------------------- STREAMED-CARD CONVERSION -------------------- ]]

-- Normalize a boolean flag the card deposited raw.
local function normalize_flag(k: string)
    local v = ll.LinksetDataRead(k)
    if v ~= "" then ll.LinksetDataWrite(k, normalize_bool(v)) end
end

-- Convert the streamed legacy roster keys into user.<uuid> records.
local function migrate_legacy_roster()
    delete_role(5)
    delete_role(3)
    delete_role(-1)

    -- Owners: multi-owner list preferred, else the single-owner scalar.
    local owners_csv = ll.LinksetDataRead(CARD_OWNER_UUIDS)
    if owners_csv ~= "" then
        local items = ll.CSV2List(owners_csv)
        local n = #items
        if n > MaxListLen then n = MaxListLen end
        for i = 1, n do card_add_owner(items[i]) end
        local ohons = ll.LinksetDataRead(CARD_OWNER_HONS)
        if ohons ~= "" then CardOwnerHons = ll.CSV2List(ohons) end
    else
        local owner1 = ll.LinksetDataRead(CARD_OWNER)
        if owner1 ~= "" then
            card_add_owner(owner1)
            local ohon1 = ll.LinksetDataRead(CARD_OWNER_HON)
            if ohon1 ~= "" then CardOwnerHons = {ohon1} end
        end
    end

    -- Trustees.
    local tru_csv = ll.LinksetDataRead(CARD_TRUSTEE_UUIDS)
    if tru_csv ~= "" then
        local items = ll.CSV2List(tru_csv)
        local n = #items
        if n > MaxListLen then n = MaxListLen end
        for i = 1, n do card_add_trustee(items[i]) end
        local thons = ll.LinksetDataRead(CARD_TRUSTEE_HONS)
        if thons ~= "" then CardTrusteeHons = ll.CSV2List(thons) end
    end

    -- Blacklist.
    local bl_csv = ll.LinksetDataRead(CARD_BLACKLIST)
    if bl_csv ~= "" then
        local items = ll.CSV2List(bl_csv)
        local n = #items
        if n > MaxListLen then n = MaxListLen end
        for i = 1, n do add_blacklist_internal(items[i], "") end
    end

    apply_card_honorifics()

    -- Deferred TPE guard: requires an external owner.
    if csv_lead_int(ll.LinksetDataRead(KEY_TPE_MODE)) ~= 0 and not has_external_owner() then
        ll.LinksetDataWrite(KEY_TPE_MODE, "0")
        ll.RegionSayTo(ll.GetOwner(), 0, "ERROR: TPE disabled - it requires an external owner.")
    end

    -- Drop the converted scratch keys; flag scalars stay.
    ll.LinksetDataDelete(CARD_OWNER)
    ll.LinksetDataDelete(CARD_OWNER_NAME)
    ll.LinksetDataDelete(CARD_OWNER_HON)
    ll.LinksetDataDelete(CARD_OWNER_UUIDS)
    ll.LinksetDataDelete(CARD_OWNER_NAMES)
    ll.LinksetDataDelete(CARD_OWNER_HONS)
    ll.LinksetDataDelete(CARD_TRUSTEE_UUIDS)
    ll.LinksetDataDelete(CARD_TRUSTEE_NAMES)
    ll.LinksetDataDelete(CARD_TRUSTEE_HONS)
    ll.LinksetDataDelete(CARD_BLACKLIST)
end

-- Entry point when kmod_bootstrap signals the card has been streamed into LSD.
local function process_streamed_card()
    normalize_flag(KEY_PUBLIC_ACCESS)
    normalize_flag(KEY_LOCKED)
    normalize_flag(KEY_RUNAWAY_ENABLED)
    normalize_flag(KEY_ISOWNED)
    normalize_flag(KEY_MULTI_OWNER_MODE)
    normalize_flag(KEY_TPE_MODE)

    migrate_legacy_roster()

    -- Idempotent readiness stamp + mark the card override applied.
    ll.LinksetDataWrite(KEY_SENTINEL, "1")
    ll.LinksetDataWrite(KEY_CARD_APPLIED, "1")
    broadcast_settings_changed()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "settings.notecard.loaded",
    }), NULL_KEY)
end

--[[ -------------------- MESSAGE HANDLERS -------------------- ]]

local function handle_settings_get()
    -- "Reload Settings": with a card, re-arm the override; without, just rebroadcast.
    if ll.GetInventoryType(NOTECARD_NAME) ~= INVENTORY_NOTECARD then
        broadcast_settings_changed()
        return
    end
    ll.LinksetDataDelete(KEY_CARD_APPLIED)
    request_card_restream()
end

local function handle_set(msg: string)
    local key_name = ll.JsonGetValue(msg, {"key"})
    if key_name == JSON_INVALID then return end
    local value = ll.JsonGetValue(msg, {"value"})
    if value == JSON_INVALID then return end

    -- Refuse direct roster writes + the notecard-only multi-owner flag.
    if ll.SubStringIndex(key_name, USER_PREFIX) == 0 then return end
    if key_name == KEY_MULTI_OWNER_MODE then return end

    if key_name == KEY_PUBLIC_ACCESS or key_name == KEY_LOCKED
        or key_name == KEY_RUNAWAY_ENABLED or key_name == KEY_ISOWNED then
        value = normalize_bool(value)
    end

    if key_name == KEY_TPE_MODE then
        value = normalize_bool(value)
        if value == "1" and not has_external_owner() then
            ll.RegionSayTo(ll.GetOwner(), 0, "ERROR: Cannot enable TPE - requires external owner")
            return
        end
    end

    -- isowned = 0 -> factory reset trigger.
    if key_name == KEY_ISOWNED and value == "0" then
        factory_reset()
        return
    end

    if ll.LinksetDataRead(key_name) == value then return end
    ll.LinksetDataWrite(key_name, value)
    broadcast_settings_changed()
end

local function handle_set_owner(msg: string)
    if is_multi_owner_mode() then
        ll.RegionSayTo(ll.GetOwner(), 0, "ERROR: Cannot set owner via menu in multi-owner mode (notecard managed)")
        return
    end

    local uuid_str = ll.JsonGetValue(msg, {"uuid"})
    local honorific = ll.JsonGetValue(msg, {"honorific"})
    if uuid_str == JSON_INVALID or honorific == JSON_INVALID then return end

    if set_owner_record(uuid_str, honorific) then
        request_owner_reboot()  -- owned-state change -> reboot, not just sync
    end
end

local function handle_clear_owner()
    if is_multi_owner_mode() then
        ll.RegionSayTo(ll.GetOwner(), 0, "ERROR: Cannot clear owner via menu in multi-owner mode (notecard managed)")
        return
    end
    -- Release ends authority -> full wipe (card + roster + settings), same as runaway.
    factory_reset()
end

local function handle_add_trustee(msg: string)
    local uuid_str = ll.JsonGetValue(msg, {"uuid"})
    local honorific = ll.JsonGetValue(msg, {"honorific"})
    if uuid_str == JSON_INVALID or honorific == JSON_INVALID then return end
    if add_trustee_internal(uuid_str, honorific) then
        broadcast_settings_changed()
    end
end

local function handle_remove_trustee(msg: string)
    local uuid_str = ll.JsonGetValue(msg, {"uuid"})
    if uuid_str == JSON_INVALID then return end
    if remove_trustee_internal(uuid_str) then
        broadcast_settings_changed()
    end
end

local function handle_blacklist_add(msg: string)
    local uuid_str = ll.JsonGetValue(msg, {"uuid"})
    if uuid_str == JSON_INVALID then return end

    local name_str = ll.JsonGetValue(msg, {"name"})
    if name_str == JSON_INVALID then name_str = "" end

    if add_blacklist_internal(uuid_str, name_str) then
        broadcast_settings_changed()
    end
end

local function handle_blacklist_remove(msg: string)
    local uuid_str = ll.JsonGetValue(msg, {"uuid"})
    if uuid_str == JSON_INVALID then return end
    if remove_blacklist_internal(uuid_str) then
        broadcast_settings_changed()
    end
end

local function handle_runaway()
    factory_reset()
end

-- Reset Config: wipe config, keep roster + ownership flags + lock + owner marker,
-- then let the standard boot rebuild.
local function handle_reset_config()
    ll.RegionSayTo(ll.GetOwner(), 0, "Resetting configuration...")

    for _, k in ipairs(ll.LinksetDataFindKeys("", 0, -1)) do
        if ll.SubStringIndex(k, "user.") ~= 0
            and k ~= KEY_ISOWNED
            and k ~= KEY_MULTI_OWNER_MODE
            and k ~= KEY_LOCKED
            and k ~= "safeguard.last_owner" then
            ll.LinksetDataDelete(k)
        end
    end

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.reset.factory",
        "from", "reset_config",
    }), NULL_KEY)
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    LastOwner = ll.GetOwner()
    NotecardKey = ll.GetInventoryKey(NOTECARD_NAME)

    -- Readiness from LSD alone — NEVER waits on the card.
    if ll.LinksetDataRead(KEY_SENTINEL) ~= "" then
        broadcast_settings_changed()
    else
        ll.LinksetDataWrite(KEY_SENTINEL, "1")
        broadcast_settings_changed()
    end
end

function LLEvents.on_rez(start_param: number)
    local current_owner = ll.GetOwner()
    if current_owner ~= LastOwner then
        LastOwner = current_owner
        ll.ResetScript()
    end
end

function LLEvents.attach(id)
    if id == NULL_KEY then return end
    local current_owner = ll.GetOwner()
    if current_owner ~= LastOwner then
        LastOwner = current_owner
        ll.ResetScript()
    end
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        local current_owner = ll.GetOwner()
        if current_owner ~= LastOwner then
            LastOwner = current_owner
            ll.ResetScript()
        end
    end

    if bit32.band(change, CHANGED_INVENTORY) ~= 0 then
        local current_notecard_key = ll.GetInventoryKey(NOTECARD_NAME)
        if current_notecard_key ~= NotecardKey then
            if current_notecard_key == NULL_KEY then
                factory_reset()  -- notecard removed
            else
                -- Notecard swapped/edited — re-arm the override.
                NotecardKey = current_notecard_key
                ll.LinksetDataDelete(KEY_CARD_APPLIED)
                request_card_restream()
            end
        end
    end
end

function LLEvents.dataserver(query_id, data: string)
    -- Only async display-name resolution for roster records reaches here.
    handle_name_response(query_id, data)
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    -- CSV envelope (single-writer) — detect BEFORE any JSON parse.
    if num == SETTINGS_BUS then
        if ll.SubStringIndex(msg, "settings.delta:") == 0 then
            handle_settings_delta_csv(msg)
            return
        end
        if ll.SubStringIndex(msg, "settings.delete:") == 0 then
            handle_settings_delete_csv(msg)
            return
        end
        if ll.SubStringIndex(msg, "settings.seed:") == 0 then
            handle_settings_seed_csv(msg)
            return
        end
    end

    local msg_type = get_msg_type(msg)
    if msg_type == "" then return end

    if num == KERNEL_LIFECYCLE then
        -- External kernel-driven reset — just reset; do NOT remove the notecard.
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
        return
    end

    if num ~= SETTINGS_BUS then return end

    if      msg_type == "settings.card.streamed"   then process_streamed_card()
    elseif  msg_type == "settings.get"             then handle_settings_get()
    elseif  msg_type == "settings.set"             then handle_set(msg)
    elseif  msg_type == "settings.owner.set"       then handle_set_owner(msg)
    elseif  msg_type == "settings.owner.clear"     then handle_clear_owner()
    elseif  msg_type == "settings.trustee.add"     then handle_add_trustee(msg)
    elseif  msg_type == "settings.trustee.remove"  then handle_remove_trustee(msg)
    elseif  msg_type == "settings.blacklist.add"   then handle_blacklist_add(msg)
    elseif  msg_type == "settings.blacklist.remove" then handle_blacklist_remove(msg)
    elseif  msg_type == "settings.runaway"         then handle_runaway()
    elseif  msg_type == "settings.reset.config"    then handle_reset_config()
    end
end

main()

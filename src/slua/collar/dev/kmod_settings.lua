--[[--------------------
MODULE: kmod_settings.lua  (SLua port)
VERSION: 1.10
REVISION: 21  (SLua port rev 1)
PURPOSE: Notecard parser, validation guards, and LSD settings store
ARCHITECTURE: Two-mode access model. Single-owner mode uses scalar keys and is
              set via the menu UI. Multi-owner mode uses parallel CSVs and is
              set ONLY via the settings notecard. Mode is selected by
              access.multiowner. Trustees and blacklist always use CSVs. Names
              are resolved asynchronously via ll.RequestDisplayName. This module
              is the SOLE LSD WRITER for MANAGED_SETTINGS_KEYS — plugins request
              writes via the CSV-envelope settings.delta / settings.delete
              protocol on SETTINGS_BUS.

SLUA PORT NOTES:
- Ported from kmod_settings.lsl rev 21. Wire protocol (SETTINGS_BUS 800 +
  KERNEL_LIFECYCLE 500), LSD key names, and storage formats (flat scalars /
  CSVs, never JSON) are unchanged so it interoperates with LSL plugins.
- LSD remains JSON-free: the settings.delta / settings.delete write path stays
  CSV-parsed (ll.ParseStringKeepNulls preserves the rev-16 empty-value fix).
  JSON is parsed only for the menu-driven settings.* messages that already used
  it in LSL.
- Idiomatic SLua: the three parallel name-query lists collapse to one map keyed
  by query id; Reset-Config's parallel key/value lists become a saved-values
  map; CSVs are 1-based Lua arrays. Every LSL integer-predicate now returns a
  real boolean (0 is truthy in Lua, so this matters).
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_ISOWNED          = "access.isowned"
local KEY_MULTI_OWNER_MODE = "access.multiowner"

local KEY_OWNER            = "access.owner"
local KEY_OWNER_NAME       = "access.ownername"
local KEY_OWNER_HONORIFIC  = "access.ownerhonorific"

local KEY_OWNER_UUIDS      = "access.owneruuids"
local KEY_OWNER_NAMES      = "access.ownernames"
local KEY_OWNER_HONORIFICS = "access.ownerhonorifics"

local KEY_TRUSTEE_UUIDS      = "access.trusteeuuids"
local KEY_TRUSTEE_NAMES      = "access.trusteenames"
local KEY_TRUSTEE_HONORIFICS = "access.trusteehonorifics"

local KEY_BLACKLIST = "blacklist.blklistuuid"

local KEY_RUNAWAY_ENABLED = "access.enablerunaway"

local KEY_PUBLIC_ACCESS = "public.mode"
local KEY_TPE_MODE      = "tpe.mode"
local KEY_LOCKED        = "lock.locked"

-- Bootstrap sentinel — set after first notecard parse completes; gates
-- start_notecard_reading so script restarts don't re-arm a hostile notecard.
local KEY_SENTINEL = "settings.bootstrapped"

local NAME_LOADING = "(loading...)"

--[[ -------------------- NOTECARD CONFIG -------------------- ]]
local NOTECARD_NAME = "settings"
local COMMENT_PREFIX = "#"
local SEPARATOR = "="

--[[ -------------------- STATE -------------------- ]]
local LastOwner = NULL_KEY

local NotecardQuery = NULL_KEY
local NotecardLine = 0
local IsLoadingNotecard = false
local NotecardKey = NULL_KEY

-- Reset Config in-flight state.
local InResetConfig = false
local ResetConfigSaved = {}  -- lsd_key -> saved value

local MaxListLen = 64

-- Pending display-name queries: query-id (string) -> { uuid, role }.
-- Role values: "owner_scalar", "owner_csv", "trustee_csv".
local NameQueries = {}

-- Keys whose pre-wipe values Reset Config preserves (card writes win; these
-- fill the slots the card is silent on). Order is not significant.
local RESET_CONFIG_KEYS = {
    KEY_OWNER, KEY_OWNER_NAME, KEY_OWNER_HONORIFIC,
    KEY_OWNER_UUIDS, KEY_OWNER_NAMES, KEY_OWNER_HONORIFICS,
    KEY_MULTI_OWNER_MODE, KEY_ISOWNED, KEY_LOCKED,
}

--[[ -------------------- HELPERS -------------------- ]]

local function get_msg_type(msg: string): string
    local t = ll.JsonGetValue(msg, {"type"})
    if t == JSON_INVALID then return "" end
    return t
end

local function starts_with(s: string, prefix: string): boolean
    return string.sub(s, 1, #prefix) == prefix
end

-- 1-based index of v in array t, or nil.
local function list_find(t, v)
    for i, x in ipairs(t) do
        if x == v then return i end
    end
    return nil
end

local function normalize_bool(s: string): string
    local v = integer(s)
    if v ~= 0 then v = 1 end
    return tostring(v)
end

local function csv_read(key_name: string)
    local raw = ll.LinksetDataRead(key_name)
    if raw == "" then return {} end
    return ll.CSV2List(raw)
end

local function csv_write(key_name: string, values)
    if #values == 0 then
        ll.LinksetDataDelete(key_name)
    else
        ll.LinksetDataWrite(key_name, ll.List2CSV(values))
    end
end

local function is_multi_owner_mode(): boolean
    return integer(ll.LinksetDataRead(KEY_MULTI_OWNER_MODE)) ~= 0
end

--[[ -------------------- BROADCASTING -------------------- ]]

local function broadcast_settings_changed()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS,
        ll.List2Json(JSON_OBJECT, {"type", "settings.sync"}), NULL_KEY)
end

--[[ -------------------- MANAGED-KEY WRITE PROTOCOL --------------------

Single-writer protocol. Plugins send CSV write requests (no JSON parsing here,
preserving the JSON-free LSD invariant):

    settings.delta:<key>:<value>     write/update LSD key
    settings.delete:<key>            delete LSD key (exactly 2 fields)

is_writable_key gates which keys this protocol may mutate. Every successful
write/delete broadcasts settings.sync so consumers re-read.
----------------------------------------------------------------------------]]

local MANAGED_SETTINGS_KEYS = {
    "lock.locked", "public.mode", "tpe.mode",
    "folders.locked", "outfits.locked", "plugin.outfit.active",
    "relay.mode", "relay.hardcoremode",
    "chat.prefix", "chat.channel", "chat.public",
    "bell.visible", "bell.enablesound", "bell.volume", "bell.sound",
    "rlvex.ownertp", "rlvex.ownerim", "rlvex.trusteetp", "rlvex.trusteeim",
    "restrict.list", "access.enablerunaway", "leash.enhanced",
    -- still on the settings.set JSON path but conceptually owned here:
    "leash.leashedavatar", "leash.leasherkey", "leash.length",
    "leash.turnto", "leash.texture",
}

local function is_writable_key(lsd_key: string): boolean
    return list_find(MANAGED_SETTINGS_KEYS, lsd_key) ~= nil
end

local function clear_managed_settings()
    for _, k in ipairs(MANAGED_SETTINGS_KEYS) do
        ll.LinksetDataDelete(k)
    end
end

local function handle_settings_delta_csv(msg: string)
    -- KeepNulls preserves a trailing empty token so `settings.delta:foo:`
    -- correctly writes foo="" (rev-16 fix).
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

--[[ -------------------- LSD CLEAR & FACTORY RESET -------------------- ]]

local function clear_owner_keys()
    ll.LinksetDataDelete(KEY_ISOWNED)
    ll.LinksetDataDelete(KEY_OWNER)
    ll.LinksetDataDelete(KEY_OWNER_NAME)
    ll.LinksetDataDelete(KEY_OWNER_HONORIFIC)
    ll.LinksetDataDelete(KEY_OWNER_UUIDS)
    ll.LinksetDataDelete(KEY_OWNER_NAMES)
    ll.LinksetDataDelete(KEY_OWNER_HONORIFICS)
end

local function clear_trustee_keys()
    ll.LinksetDataDelete(KEY_TRUSTEE_UUIDS)
    ll.LinksetDataDelete(KEY_TRUSTEE_NAMES)
    ll.LinksetDataDelete(KEY_TRUSTEE_HONORIFICS)
end

-- Full wipe + notecard removal (zero-trust: an abusive owner could have baked
-- hostile values into the card). Does not return.
local function factory_reset()
    ll.RegionSayTo(ll.GetOwner(), 0, "Collar factory reset triggered.")

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

-- True if any external owner exists (not the wearer, not NULL_KEY).
local function has_external_owner(): boolean
    local wearer = ll.GetOwner()
    if is_multi_owner_mode() then
        for _, s in ipairs(csv_read(KEY_OWNER_UUIDS)) do
            local owner = uuid(s)
            if owner ~= wearer and owner ~= NULL_KEY then return true end
        end
        return false
    end
    local primary = uuid(ll.LinksetDataRead(KEY_OWNER))
    return primary ~= NULL_KEY and primary ~= wearer
end

local function is_owner(who: string): boolean
    if is_multi_owner_mode() then
        return list_find(csv_read(KEY_OWNER_UUIDS), who) ~= nil
    end
    return ll.LinksetDataRead(KEY_OWNER) == who
end

local function is_trustee(who: string): boolean
    return list_find(csv_read(KEY_TRUSTEE_UUIDS), who) ~= nil
end

--[[ -------------------- ASYNC NAME RESOLUTION -------------------- ]]

local function request_name(uuid_str: string, role: string)
    if uuid_str == "" or uuid(uuid_str) == NULL_KEY then return end
    local qid = ll.RequestDisplayName(uuid(uuid_str))
    NameQueries[tostring(qid)] = { uuid = uuid_str, role = role }
end

local function handle_name_response(query_id, name: string)
    local qkey = tostring(query_id)
    local q = NameQueries[qkey]
    if q == nil then return end
    NameQueries[qkey] = nil

    if name == "" then return end
    local uuid_str = q.uuid

    if q.role == "owner_scalar" then
        if ll.LinksetDataRead(KEY_OWNER) == uuid_str then
            ll.LinksetDataWrite(KEY_OWNER_NAME, name)
            broadcast_settings_changed()
        end
        return
    end

    if q.role == "owner_csv" then
        local slot = list_find(csv_read(KEY_OWNER_UUIDS), uuid_str)
        if slot == nil then return end
        local names = csv_read(KEY_OWNER_NAMES)
        while #names < slot do names[#names + 1] = NAME_LOADING end
        names[slot] = name
        csv_write(KEY_OWNER_NAMES, names)
        broadcast_settings_changed()
        return
    end

    if q.role == "trustee_csv" then
        local slot = list_find(csv_read(KEY_TRUSTEE_UUIDS), uuid_str)
        if slot == nil then return end
        local names = csv_read(KEY_TRUSTEE_NAMES)
        while #names < slot do names[#names + 1] = NAME_LOADING end
        names[slot] = name
        csv_write(KEY_TRUSTEE_NAMES, names)
        broadcast_settings_changed()
    end
end

--[[ -------------------- INTERNAL MUTATORS -------------------- ]]
-- Defined callee-before-caller (Lua resolves locals lexically).

local function remove_trustee_internal(uuid_str: string): boolean
    local uuids = csv_read(KEY_TRUSTEE_UUIDS)
    local idx = list_find(uuids, uuid_str)
    if idx == nil then return false end

    local names = csv_read(KEY_TRUSTEE_NAMES)
    local hons  = csv_read(KEY_TRUSTEE_HONORIFICS)

    table.remove(uuids, idx)
    if idx <= #names then table.remove(names, idx) end
    if idx <= #hons  then table.remove(hons,  idx) end

    csv_write(KEY_TRUSTEE_UUIDS,      uuids)
    csv_write(KEY_TRUSTEE_NAMES,      names)
    csv_write(KEY_TRUSTEE_HONORIFICS, hons)
    return true
end

local function remove_blacklist_internal(uuid_str: string): boolean
    local bl = csv_read(KEY_BLACKLIST)
    local idx = list_find(bl, uuid_str)
    if idx == nil then return false end
    table.remove(bl, idx)
    csv_write(KEY_BLACKLIST, bl)
    return true
end

-- Single-owner: write the scalar trio, set isowned, clear stale multi-owner CSVs.
local function set_single_owner(uuid_str: string, honorific: string): boolean
    if uuid_str == "" or uuid(uuid_str) == NULL_KEY then return false end
    if uuid(uuid_str) == ll.GetOwner() then
        ll.RegionSayTo(ll.GetOwner(), 0, "ERROR: Cannot add wearer as owner (role separation required)")
        return false
    end

    -- Role exclusivity.
    remove_trustee_internal(uuid_str)
    remove_blacklist_internal(uuid_str)

    ll.LinksetDataDelete(KEY_OWNER_UUIDS)
    ll.LinksetDataDelete(KEY_OWNER_NAMES)
    ll.LinksetDataDelete(KEY_OWNER_HONORIFICS)
    ll.LinksetDataDelete(KEY_MULTI_OWNER_MODE)

    ll.LinksetDataWrite(KEY_OWNER, uuid_str)
    ll.LinksetDataWrite(KEY_OWNER_NAME, NAME_LOADING)
    ll.LinksetDataWrite(KEY_OWNER_HONORIFIC, honorific)
    ll.LinksetDataWrite(KEY_ISOWNED, "1")

    request_name(uuid_str, "owner_scalar")
    return true
end

local function clear_single_owner()
    ll.LinksetDataDelete(KEY_OWNER)
    ll.LinksetDataDelete(KEY_OWNER_NAME)
    ll.LinksetDataDelete(KEY_OWNER_HONORIFIC)
    ll.LinksetDataDelete(KEY_ISOWNED)
end

local function add_trustee_internal(uuid_str: string, honorific: string): boolean
    if uuid_str == "" or uuid(uuid_str) == NULL_KEY then return false end
    if uuid(uuid_str) == ll.GetOwner() then return false end
    if is_owner(uuid_str) then return false end

    local uuids = csv_read(KEY_TRUSTEE_UUIDS)
    if list_find(uuids, uuid_str) ~= nil then return false end
    if #uuids >= MaxListLen then return false end

    remove_blacklist_internal(uuid_str)

    local names = csv_read(KEY_TRUSTEE_NAMES)
    local hons  = csv_read(KEY_TRUSTEE_HONORIFICS)

    uuids[#uuids + 1] = uuid_str
    names[#names + 1] = NAME_LOADING
    hons[#hons + 1]   = honorific

    csv_write(KEY_TRUSTEE_UUIDS,      uuids)
    csv_write(KEY_TRUSTEE_NAMES,      names)
    csv_write(KEY_TRUSTEE_HONORIFICS, hons)

    request_name(uuid_str, "trustee_csv")
    return true
end

local function add_blacklist_internal(uuid_str: string): boolean
    if uuid_str == "" or uuid(uuid_str) == NULL_KEY then return false end
    if uuid(uuid_str) == ll.GetOwner() then return false end
    if is_owner(uuid_str) then return false end
    if is_trustee(uuid_str) then return false end

    local bl = csv_read(KEY_BLACKLIST)
    if list_find(bl, uuid_str) ~= nil then return false end
    if #bl >= MaxListLen then return false end

    bl[#bl + 1] = uuid_str
    csv_write(KEY_BLACKLIST, bl)
    return true
end

--[[ -------------------- NOTECARD-ONLY KEYS -------------------- ]]

local function is_notecard_only_key(k: string): boolean
    return k == KEY_MULTI_OWNER_MODE
        or k == KEY_OWNER_UUIDS
        or k == KEY_OWNER_NAMES
        or k == KEY_OWNER_HONORIFICS
end

--[[ -------------------- NOTECARD PARSING -------------------- ]]

-- Parse + validate a CSV of UUIDs (owner/trustee/blacklist). Truncates to
-- MaxListLen, drops the wearer / NULL_KEY, and applies the extra reject_fn
-- guard (e.g. "already an owner"). Returns the validated string array.
local function parse_uuid_csv(value: string, reject_fn): {string}
    local valid = {}
    for i, s in ipairs(ll.CSV2List(value)) do
        if i > MaxListLen then break end
        local u = uuid(s)
        if u ~= NULL_KEY and u ~= ll.GetOwner() and not reject_fn(tostring(u)) then
            valid[#valid + 1] = tostring(u)
        end
    end
    return valid
end

local function parse_notecard_line(line: string)
    line = ll.StringTrim(line, STRING_TRIM)
    if line == "" then return end
    if string.sub(line, 1, 1) == COMMENT_PREFIX then return end

    local sep = string.find(line, SEPARATOR, 1, true)
    if sep == nil then return end

    local key_name = ll.StringTrim(string.sub(line, 1, sep - 1), STRING_TRIM)
    local value    = ll.StringTrim(string.sub(line, sep + 1), STRING_TRIM)

    if key_name == KEY_MULTI_OWNER_MODE then
        ll.LinksetDataWrite(KEY_MULTI_OWNER_MODE, normalize_bool(value))
        return
    end

    if key_name == KEY_OWNER then
        local u = uuid(value)
        if u == NULL_KEY or u == ll.GetOwner() then return end
        ll.LinksetDataWrite(KEY_OWNER, value)
        if ll.LinksetDataRead(KEY_OWNER_NAME) == "" then
            ll.LinksetDataWrite(KEY_OWNER_NAME, NAME_LOADING)
        end
        ll.LinksetDataWrite(KEY_ISOWNED, "1")
        request_name(value, "owner_scalar")
        return
    end

    if key_name == KEY_OWNER_HONORIFIC then
        ll.LinksetDataWrite(KEY_OWNER_HONORIFIC, value)
        return
    end

    if key_name == KEY_OWNER_UUIDS then
        local valid = parse_uuid_csv(value, function(_) return false end)
        for _, s in ipairs(valid) do request_name(s, "owner_csv") end
        csv_write(KEY_OWNER_UUIDS, valid)
        local placeholders = {}
        for i = 1, #valid do placeholders[i] = NAME_LOADING end
        csv_write(KEY_OWNER_NAMES, placeholders)
        if #valid > 0 then ll.LinksetDataWrite(KEY_ISOWNED, "1") end
        return
    end

    if key_name == KEY_OWNER_HONORIFICS then
        csv_write(KEY_OWNER_HONORIFICS, ll.CSV2List(value))
        return
    end

    if key_name == KEY_TRUSTEE_UUIDS then
        local valid = parse_uuid_csv(value, is_owner)
        for _, s in ipairs(valid) do request_name(s, "trustee_csv") end
        csv_write(KEY_TRUSTEE_UUIDS, valid)
        local placeholders = {}
        for i = 1, #valid do placeholders[i] = NAME_LOADING end
        csv_write(KEY_TRUSTEE_NAMES, placeholders)
        return
    end

    if key_name == KEY_TRUSTEE_HONORIFICS then
        csv_write(KEY_TRUSTEE_HONORIFICS, ll.CSV2List(value))
        return
    end

    if key_name == KEY_BLACKLIST then
        local valid = parse_uuid_csv(value, function(s) return is_owner(s) or is_trustee(s) end)
        csv_write(KEY_BLACKLIST, valid)
        return
    end

    if key_name == KEY_PUBLIC_ACCESS
        or key_name == KEY_LOCKED
        or key_name == KEY_RUNAWAY_ENABLED
        or key_name == KEY_ISOWNED then
        ll.LinksetDataWrite(key_name, normalize_bool(value))
        return
    end

    if key_name == KEY_TPE_MODE then
        value = normalize_bool(value)
        if integer(value) == 1 and not has_external_owner() then
            ll.RegionSayTo(ll.GetOwner(), 0, "ERROR: Cannot enable TPE via notecard - requires external owner")
            ll.RegionSayTo(ll.GetOwner(), 0, "HINT: Set owner BEFORE tpe.mode in notecard")
            return
        end
        ll.LinksetDataWrite(KEY_TPE_MODE, value)
        return
    end

    -- Generic plugin scalars (any other dotted key) — write through.
    if string.find(key_name, ".", 1, true) ~= nil then
        ll.LinksetDataWrite(key_name, value)
    end
end

local function start_notecard_reading(): boolean
    -- Sentinel-gated: explicit re-parse paths must clear the sentinel first so
    -- a hostile notecard cannot self-arm a wiped collar on restart.
    if ll.LinksetDataRead(KEY_SENTINEL) ~= "" then return false end
    if ll.GetInventoryType(NOTECARD_NAME) ~= INVENTORY_NOTECARD then return false end

    -- Notecard is canonical: clear managed data first so removed entries don't
    -- linger, then let consumers fall back to defaults for card-silent keys.
    clear_owner_keys()
    clear_trustee_keys()
    ll.LinksetDataDelete(KEY_BLACKLIST)
    clear_managed_settings()

    IsLoadingNotecard = true
    NotecardLine = 0
    NotecardQuery = ll.GetNotecardLine(NOTECARD_NAME, NotecardLine)
    return true
end

--[[ -------------------- RESET CONFIG (preserve owner+lock) -------------------- ]]

local function finalize_reset_config()
    for _, k in ipairs(RESET_CONFIG_KEYS) do
        if ll.LinksetDataRead(k) == "" then
            local v = ResetConfigSaved[k]
            if v ~= nil and v ~= "" then ll.LinksetDataWrite(k, v) end
        end
    end

    ll.LinksetDataWrite(KEY_SENTINEL, "1")
    InResetConfig = false
    ResetConfigSaved = {}

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.reset.factory",
        "from", "reset_config",
    }), NULL_KEY)

    broadcast_settings_changed()
end

local function handle_reset_config()
    ResetConfigSaved = {}
    for _, k in ipairs(RESET_CONFIG_KEYS) do
        ResetConfigSaved[k] = ll.LinksetDataRead(k)
    end

    ll.RegionSayTo(ll.GetOwner(), 0, "Resetting configuration...")

    ll.LinksetDataReset()
    InResetConfig = true

    if not start_notecard_reading() then
        finalize_reset_config()  -- no notecard: restore + finalize now
    end
    -- else dataserver chain runs; EOF routes to finalize_reset_config.
end

--[[ -------------------- MESSAGE HANDLERS -------------------- ]]

local function handle_settings_get()
    if IsLoadingNotecard then return end
    -- Explicit re-arm: clear sentinel so start_notecard_reading proceeds.
    ll.LinksetDataDelete(KEY_SENTINEL)
    if not start_notecard_reading() then
        broadcast_settings_changed()
    end
end

-- Generic scalar set for non-access keys. Owner/trustee/blacklist must use the
-- dedicated handlers below.
local function handle_set(msg: string)
    local key_name = ll.JsonGetValue(msg, {"key"})
    if key_name == JSON_INVALID then return end
    if is_notecard_only_key(key_name) then return end

    local value = ll.JsonGetValue(msg, {"value"})
    if value == JSON_INVALID then return end

    -- Refuse direct writes to managed access lists.
    if key_name == KEY_OWNER
        or key_name == KEY_OWNER_NAME
        or key_name == KEY_OWNER_HONORIFIC
        or key_name == KEY_TRUSTEE_UUIDS
        or key_name == KEY_TRUSTEE_NAMES
        or key_name == KEY_TRUSTEE_HONORIFICS
        or key_name == KEY_BLACKLIST then
        return
    end

    if key_name == KEY_PUBLIC_ACCESS
        or key_name == KEY_LOCKED
        or key_name == KEY_RUNAWAY_ENABLED
        or key_name == KEY_ISOWNED then
        value = normalize_bool(value)
    end

    if key_name == KEY_TPE_MODE then
        value = normalize_bool(value)
        if integer(value) == 1 and not has_external_owner() then
            ll.RegionSayTo(ll.GetOwner(), 0, "ERROR: Cannot enable TPE - requires external owner")
            return
        end
    end

    if key_name == KEY_ISOWNED and value == "0" then
        factory_reset()  -- does not return
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
    local uuid_str  = ll.JsonGetValue(msg, {"uuid"})
    local honorific = ll.JsonGetValue(msg, {"honorific"})
    if uuid_str == JSON_INVALID or honorific == JSON_INVALID then return end
    if set_single_owner(uuid_str, honorific) then
        broadcast_settings_changed()
    end
end

local function handle_clear_owner()
    if is_multi_owner_mode() then
        ll.RegionSayTo(ll.GetOwner(), 0, "ERROR: Cannot clear owner via menu in multi-owner mode (notecard managed)")
        return
    end
    clear_single_owner()
    broadcast_settings_changed()
end

local function handle_add_trustee(msg: string)
    local uuid_str  = ll.JsonGetValue(msg, {"uuid"})
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
    if add_blacklist_internal(uuid_str) then
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

--[[ -------------------- EVENTS -------------------- ]]

local function maybe_reset_on_owner_change()
    local current_owner = ll.GetOwner()
    if current_owner ~= LastOwner then
        LastOwner = current_owner
        ll.ResetScript()
    end
end

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end

    LastOwner = ll.GetOwner()
    NotecardKey = ll.GetInventoryKey(NOTECARD_NAME)

    if not start_notecard_reading() then
        -- No notecard (or already bootstrapped): LSD already holds settings.
        broadcast_settings_changed()
    end
end

function LLEvents.on_rez(start_param: number)
    maybe_reset_on_owner_change()
end

function LLEvents.attach(id)
    if id == NULL_KEY then return end
    maybe_reset_on_owner_change()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        maybe_reset_on_owner_change()
    end

    if bit32.band(change, CHANGED_INVENTORY) ~= 0 then
        local current_notecard_key = ll.GetInventoryKey(NOTECARD_NAME)
        if current_notecard_key ~= NotecardKey then
            if current_notecard_key == NULL_KEY then
                factory_reset()  -- notecard removed
            else
                -- New/edited card is an explicit re-arm signal.
                NotecardKey = current_notecard_key
                ll.LinksetDataDelete(KEY_SENTINEL)
                start_notecard_reading()
            end
        end
    end
end

function LLEvents.dataserver(query_id, data: string)
    if query_id == NotecardQuery then
        if data ~= EOF then
            parse_notecard_line(data)
            NotecardLine += 1
            NotecardQuery = ll.GetNotecardLine(NOTECARD_NAME, NotecardLine)
        else
            IsLoadingNotecard = false
            if InResetConfig then
                finalize_reset_config()
            else
                -- Normal bootstrap completion.
                ll.LinksetDataWrite(KEY_SENTINEL, "1")
                broadcast_settings_changed()
                ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE,
                    ll.List2Json(JSON_OBJECT, {"type", "settings.notecard.loaded"}), NULL_KEY)
            end
        end
        return
    end

    -- Display-name response.
    handle_name_response(query_id, data)
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    -- CSV envelope (single-writer protocol) — detect before JSON parsing so
    -- the write path stays JSON-free.
    if num == SETTINGS_BUS then
        if starts_with(msg, "settings.delta:") then
            handle_settings_delta_csv(msg)
            return
        end
        if starts_with(msg, "settings.delete:") then
            handle_settings_delete_csv(msg)
            return
        end
    end

    local msg_type = get_msg_type(msg)
    if msg_type == "" then return end

    if num == KERNEL_LIFECYCLE then
        -- Kernel-driven reset: just reset, never touch the notecard (removal is
        -- exclusive to the wearer Runaway path).
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
        return
    end

    if num ~= SETTINGS_BUS then return end

    if msg_type == "settings.get" then handle_settings_get()
    elseif msg_type == "settings.set" then handle_set(msg)
    elseif msg_type == "settings.owner.set" then handle_set_owner(msg)
    elseif msg_type == "settings.owner.clear" then handle_clear_owner()
    elseif msg_type == "settings.trustee.add" then handle_add_trustee(msg)
    elseif msg_type == "settings.trustee.remove" then handle_remove_trustee(msg)
    elseif msg_type == "settings.blacklist.add" then handle_blacklist_add(msg)
    elseif msg_type == "settings.blacklist.remove" then handle_blacklist_remove(msg)
    elseif msg_type == "settings.runaway" then handle_runaway()
    elseif msg_type == "settings.reset.config" then handle_reset_config()
    end
end

-- Top-level init (SLua runs this in place of state_entry).
main()

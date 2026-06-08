--[[--------------------
PLUGIN: plugin_access.lua  (SLua port)
VERSION: 1.10
PURPOSE: Owner/trustee management — set/transfer/release owner, add/remove
         trustees (with consent dialogs), runaway, runaway-enable toggle.
ARCHITECTURE: Consolidated message bus lanes; mutations routed through
              kmod_settings (settings.owner.* / trustee.* / runaway / delta).

SLUA PORT NOTES:
- Ported from plugin_access.lsl. The settings.* mutation wire, multi-stage
  consent dialogs, numbered-list pickers, and runaway semantics are unchanged.
  (Runaway = consensual self-eject; see project notes.)
- SLua conventions: LLEvents.* handlers, local main(); NameCache is a map with
  FIFO eviction; owner/trustee parallel CSVs are arrays; sensor uses
  detected:getKey(); MultiOwnerMode/RunawayEnabled are booleans.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.owner"
local PLUGIN_LABEL = "Access"

local MAX_NUMBERED_LIST_ITEMS = 11

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_MULTI_OWNER_MODE   = "access.multiowner"
local KEY_OWNER              = "access.owner"
local KEY_OWNER_NAME         = "access.ownername"
local KEY_OWNER_HONORIFIC    = "access.ownerhonorific"
local KEY_OWNER_UUIDS        = "access.owneruuids"
local KEY_OWNER_NAMES        = "access.ownernames"
local KEY_OWNER_HONORIFICS   = "access.ownerhonorifics"
local KEY_TRUSTEE_UUIDS      = "access.trusteeuuids"
local KEY_TRUSTEE_NAMES      = "access.trusteenames"
local KEY_TRUSTEE_HONORIFICS = "access.trusteehonorifics"
local KEY_RUNAWAY_ENABLED    = "access.enablerunaway"

--[[ -------------------- STATE -------------------- ]]
local MultiOwnerMode = false
local OwnerKey = NULL_KEY
local OwnerKeys = {}
local OwnerHonorific = ""
local OwnerHonorifics = {}
-- Display-name half of the multi-owner uuids/names/honorifics trio. Read from
-- LSD for parity with the trustee block; not currently rendered (underscore
-- silences the unused-local lint without dropping the data-model symmetry).
local _OwnerNames = {}
local TrusteeKeys = {}
local TrusteeHonorifics = {}
local TrusteeNames = {}
local RunawayEnabled = true

local CurrentUser = NULL_KEY
local UserAcl = -999
local gPolicyButtons = {}
local SessionId = ""
local MenuContext = ""

local PendingCandidate = NULL_KEY
local PendingHonorific = ""
local CandidateKeys = {}

local NameCache = {}      -- tostring(key) -> name
local NameCacheKeys = {}  -- insertion order for FIFO cap
local ActiveNameQuery = NULL_KEY
local ActiveQueryTarget = NULL_KEY

local OWNER_HONORIFICS = {"Master", "Mistress", "Daddy", "Mommy", "King", "Queen"}
local TRUSTEE_HONORIFICS = {"Sir", "Madame", "Milord", "Milady"}

--[[ -------------------- HELPERS -------------------- ]]

local function list_find(t, v)
    for i, x in ipairs(t) do
        if x == v then return i end
    end
    return nil
end

local function btn(label: string, cmd: string): string
    return ll.List2Json(JSON_OBJECT, {"label", label, "context", cmd})
end

local function csv_read(lsd_key: string)
    local raw = ll.LinksetDataRead(lsd_key)
    if raw == "" then return {} end
    return ll.CSV2List(raw)
end

local function gen_session(): string
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
end

local function get_policy_buttons(ctx: string, acl: number)
    local policy = ll.LinksetDataRead("acl.policycontext:" .. ctx)
    if policy == "" then return {} end
    local csv = ll.JsonGetValue(policy, {tostring(acl)})
    if csv == JSON_INVALID then return {} end
    return ll.CSV2List(csv)
end

local function btn_allowed(label: string): boolean
    return list_find(gPolicyButtons, label) ~= nil
end

local function has_owner(): boolean
    if MultiOwnerMode then return #OwnerKeys > 0 end
    return OwnerKey ~= NULL_KEY
end

local function get_primary_owner()
    if MultiOwnerMode and #OwnerKeys > 0 then return uuid(OwnerKeys[1]) end
    return OwnerKey
end

local function is_owner(k): boolean
    if MultiOwnerMode then return list_find(OwnerKeys, tostring(k)) ~= nil end
    return k == OwnerKey
end

--[[ -------------------- NAMES -------------------- ]]

local function cache_name(k, n: string)
    if k == NULL_KEY or n == "" or n == "???" then return end
    local kk = tostring(k)
    if NameCache[kk] ~= nil then NameCache[kk] = n; return end
    NameCache[kk] = n
    NameCacheKeys[#NameCacheKeys + 1] = kk
    if #NameCacheKeys > 20 then
        local old = table.remove(NameCacheKeys, 1)
        NameCache[old] = nil
    end
end

local function get_name(k): string
    if k == NULL_KEY then return "" end
    local kk = tostring(k)
    if NameCache[kk] ~= nil then return NameCache[kk] end

    local n = ll.GetDisplayName(k)
    if n ~= "" and n ~= "???" then cache_name(k, n); return n end

    if ActiveNameQuery == NULL_KEY then
        ActiveNameQuery = ll.RequestDisplayName(k)
        ActiveQueryTarget = k
    end
    return ll.Key2Name(k)
end

--[[ -------------------- LIFECYCLE -------------------- ]]

local function write_plugin_reg(label: string)
    local k = "plugin.reg." .. PLUGIN_CONTEXT
    local v = ll.List2Json(JSON_OBJECT, {"label", label, "script", ll.GetScriptName()})
    if ll.LinksetDataRead(k) == v then return end
    ll.LinksetDataWrite(k, v)
end

local function register_self()
    ll.LinksetDataWrite("acl.policycontext:" .. PLUGIN_CONTEXT, ll.List2Json(JSON_OBJECT, {
        "2", "Add Owner,Runaway",
        "3", "Add Trustee,Rem Trustee,Release,Runaway: On,Runaway: Off",
        "4", "Add Owner,Runaway,Add Trustee,Rem Trustee",
        "5", "Transfer,Release,Runaway: On,Runaway: Off,Add Trustee,Rem Trustee",
    }))
    write_plugin_reg(PLUGIN_LABEL)
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", ll.GetScriptName(),
    }), NULL_KEY)
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "chat.alias.declare", "alias", "access", "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

local function send_pong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

--[[ -------------------- SETTINGS -------------------- ]]

local function apply_settings_sync()
    MultiOwnerMode = false
    OwnerKey = NULL_KEY
    OwnerKeys = {}
    OwnerHonorific = ""
    OwnerHonorifics = {}
    _OwnerNames = {}
    TrusteeKeys = {}
    TrusteeHonorifics = {}
    TrusteeNames = {}

    local tmp = ll.LinksetDataRead(KEY_MULTI_OWNER_MODE)
    if tmp ~= "" then MultiOwnerMode = integer(tmp) ~= 0 end

    if MultiOwnerMode then
        OwnerKeys = csv_read(KEY_OWNER_UUIDS)
        _OwnerNames = csv_read(KEY_OWNER_NAMES)
        OwnerHonorifics = csv_read(KEY_OWNER_HONORIFICS)
        if #OwnerKeys > 0 then
            OwnerKey = uuid(OwnerKeys[1])
            if #OwnerHonorifics > 0 then OwnerHonorific = OwnerHonorifics[1] end
        end
    else
        local raw = ll.LinksetDataRead(KEY_OWNER)
        if raw ~= "" then
            OwnerKey = uuid(raw)
            OwnerHonorific = ll.LinksetDataRead(KEY_OWNER_HONORIFIC)
        end
    end

    TrusteeKeys = csv_read(KEY_TRUSTEE_UUIDS)
    TrusteeNames = csv_read(KEY_TRUSTEE_NAMES)
    TrusteeHonorifics = csv_read(KEY_TRUSTEE_HONORIFICS)

    local rv = ll.LinksetDataRead(KEY_RUNAWAY_ENABLED)
    if rv == "" then RunawayEnabled = true else RunawayEnabled = integer(rv) ~= 0 end
end

local function persist_owner(owner, hon: string)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "settings.owner.set", "uuid", tostring(owner), "honorific", hon,
    }), NULL_KEY)
end

local function add_trustee(trustee, hon: string)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "settings.trustee.add", "uuid", tostring(trustee), "honorific", hon,
    }), NULL_KEY)
end

local function remove_trustee(trustee)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "settings.trustee.remove", "uuid", tostring(trustee),
    }), NULL_KEY)
end

local function clear_owner()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {"type", "settings.owner.clear"}), NULL_KEY)
end

local function trigger_runaway()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {"type", "settings.runaway"}), NULL_KEY)
end

--[[ -------------------- MENUS -------------------- ]]

local function show_main()
    SessionId = gen_session()
    MenuContext = "main"
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl)

    local body = "Owner Management\n\n"
    if has_owner() then
        if MultiOwnerMode then
            body = body .. "Multi-owner mode (notecard managed)\nOwners: " .. tostring(#OwnerKeys) .. "\n"
        else
            local display_name = ll.LinksetDataRead(KEY_OWNER_NAME)
            if display_name == "" then display_name = get_name(OwnerKey) end
            body = body .. "Owner: " .. display_name
            if OwnerHonorific ~= "" then body = body .. " (" .. OwnerHonorific .. ")" end
        end
    else
        body = body .. "Unowned"
    end
    body = body .. "\nTrustees: " .. tostring(#TrusteeKeys)

    local button_data = {btn("Back", "back")}

    if not MultiOwnerMode then
        if btn_allowed("Add Owner") and CurrentUser == ll.GetOwner() and not has_owner() then
            button_data[#button_data + 1] = btn("Add Owner", "add_owner")
        end
        if btn_allowed("Runaway") and CurrentUser == ll.GetOwner() and has_owner() and RunawayEnabled then
            button_data[#button_data + 1] = btn("Runaway", "runaway")
        end
        if btn_allowed("Transfer") and is_owner(CurrentUser) then
            button_data[#button_data + 1] = btn("Transfer", "transfer")
        end
        if btn_allowed("Release") and is_owner(CurrentUser) then
            button_data[#button_data + 1] = btn("Release", "release")
        end
        if is_owner(CurrentUser) then
            if RunawayEnabled and btn_allowed("Runaway: On") then
                button_data[#button_data + 1] = btn("Runaway: On", "runaway_toggle")
            elseif not RunawayEnabled and btn_allowed("Runaway: Off") then
                button_data[#button_data + 1] = btn("Runaway: Off", "runaway_toggle")
            end
        end
    end

    if btn_allowed("Add Trustee") then button_data[#button_data + 1] = btn("Add Trustee", "add_trustee") end
    if btn_allowed("Rem Trustee") then button_data[#button_data + 1] = btn("Rem Trustee", "rem_trustee") end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", PLUGIN_LABEL,
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, button_data),
        "timeout", 60,
    }), NULL_KEY)
end

local function open_numbered_dialog(target, ctx: string, title: string, prompt: string, items)
    SessionId = gen_session()
    MenuContext = ctx
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", tostring(target),
        "title", title,
        "prompt", prompt,
        "items", ll.List2Json(JSON_ARRAY, items),
        "timeout", 60,
    }), NULL_KEY)
end

local function show_confirm(target, ctx: string, title: string, body: string)
    SessionId = gen_session()
    MenuContext = ctx
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(target),
        "title", title,
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, {btn("Yes", "confirm"), btn("No", "cancel")}),
        "timeout", 60,
    }), NULL_KEY)
end

local function show_candidates(context: string, title: string, prompt: string)
    if #CandidateKeys == 0 then
        ll.RegionSayTo(CurrentUser, 0, "No nearby avatars found.")
        show_main()
        return
    end
    local names = {}
    local limit = #CandidateKeys
    if limit > MAX_NUMBERED_LIST_ITEMS then limit = MAX_NUMBERED_LIST_ITEMS end
    for i = 1, limit do
        names[#names + 1] = get_name(uuid(CandidateKeys[i]))
    end
    open_numbered_dialog(CurrentUser, context, title, prompt, names)
end

local function show_honorific(target, context: string)
    PendingCandidate = target
    local choices = OWNER_HONORIFICS
    if context == "trustee_hon" then choices = TRUSTEE_HONORIFICS end
    open_numbered_dialog(target, context, "Honorific", "What would you like to be called?", choices)
end

local function show_remove_trustee()
    if #TrusteeKeys == 0 then
        ll.RegionSayTo(CurrentUser, 0, "No trustees.")
        show_main()
        return
    end
    local names = {}
    local limit = #TrusteeKeys
    if limit > MAX_NUMBERED_LIST_ITEMS then limit = MAX_NUMBERED_LIST_ITEMS end
    for i = 1, limit do
        local display_name = TrusteeNames[i] or ""
        if display_name == "" then display_name = get_name(uuid(TrusteeKeys[i])) end
        local hon = TrusteeHonorifics[i] or ""
        if hon ~= "" then display_name = display_name .. " (" .. hon .. ")" end
        names[#names + 1] = display_name
    end
    open_numbered_dialog(CurrentUser, "remove_trustee", "Remove Trustee", "Select to remove:", names)
end

local function handle_subpath(user, acl_level: number, subpath: string)
    local tokens = ll.ParseString2List(subpath, {"."}, {})
    if #tokens < 2 then
        ll.RegionSayTo(user, 0, "Usage: access <add|rem> <owner|trustee>")
        return
    end
    local verb = tokens[1]
    local role = tokens[2]

    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level)
    CurrentUser = user
    UserAcl = acl_level
    MenuContext = "main"

    if verb == "add" and role == "owner" then
        if not btn_allowed("Add Owner") then ll.RegionSayTo(user, 0, "Access denied."); gPolicyButtons = {}; return end
        gPolicyButtons = {}
        MenuContext = "set_scan"
        CandidateKeys = {}
        ll.Sensor("", NULL_KEY, AGENT, 10.0, PI)
    elseif verb == "rem" and role == "owner" then
        if not btn_allowed("Release") then ll.RegionSayTo(user, 0, "Access denied."); gPolicyButtons = {}; return end
        gPolicyButtons = {}
        show_confirm(CurrentUser, "release_owner", "Confirm Release", "Release " .. get_name(ll.GetOwner()) .. "?")
    elseif verb == "add" and role == "trustee" then
        if not btn_allowed("Add Trustee") then ll.RegionSayTo(user, 0, "Access denied."); gPolicyButtons = {}; return end
        gPolicyButtons = {}
        MenuContext = "trustee_scan"
        CandidateKeys = {}
        ll.Sensor("", NULL_KEY, AGENT, 10.0, PI)
    elseif verb == "rem" and role == "trustee" then
        if not btn_allowed("Rem Trustee") then ll.RegionSayTo(user, 0, "Access denied."); gPolicyButtons = {}; return end
        gPolicyButtons = {}
        show_remove_trustee()
    else
        gPolicyButtons = {}
        ll.RegionSayTo(user, 0, "Unknown access subcommand: " .. verb .. " " .. role)
    end
end

--[[ -------------------- CLEANUP -------------------- ]]

local function cleanup()
    if SessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.close", "session_id", SessionId,
        }), NULL_KEY)
    end
    CurrentUser = NULL_KEY
    UserAcl = -999
    gPolicyButtons = {}
    SessionId = ""
    MenuContext = ""
    PendingCandidate = NULL_KEY
    PendingHonorific = ""
    CandidateKeys = {}
end

local function menu_return()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return", "user", tostring(CurrentUser),
    }), NULL_KEY)
end

--[[ -------------------- BUTTON HANDLING -------------------- ]]

local function handle_button(cmd: string, label: string)
    if cmd == "back" or (cmd == "" and label == "Back") then
        if MenuContext == "main" then menu_return(); cleanup()
        else show_main() end
        return
    end

    if MenuContext == "main" then
        if cmd == "add_owner" then
            MenuContext = "set_scan"; CandidateKeys = {}
            ll.Sensor("", NULL_KEY, AGENT, 10.0, PI)
        elseif cmd == "transfer" then
            MenuContext = "transfer_scan"; CandidateKeys = {}
            ll.Sensor("", NULL_KEY, AGENT, 10.0, PI)
        elseif cmd == "release" then
            show_confirm(CurrentUser, "release_owner", "Confirm Release", "Release " .. get_name(ll.GetOwner()) .. "?")
        elseif cmd == "runaway" then
            show_confirm(CurrentUser, "runaway", "Confirm Runaway",
                "Run away from " .. get_name(get_primary_owner()) .. "?\n\nThis removes ownership without consent.")
        elseif cmd == "runaway_toggle" then
            if RunawayEnabled then
                local hon = OwnerHonorific
                if hon == "" then hon = "Owner" end
                show_confirm(ll.GetOwner(), "runaway_disable_confirm", "Disable Runaway",
                    "Your " .. hon .. " wants to disable runaway for you.\n\nPlease confirm.")
            else
                RunawayEnabled = true
                ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delta:" .. KEY_RUNAWAY_ENABLED .. ":1", NULL_KEY)
                ll.RegionSayTo(CurrentUser, 0, "Runaway enabled.")
                show_main()
            end
        elseif cmd == "add_trustee" then
            MenuContext = "trustee_scan"; CandidateKeys = {}
            ll.Sensor("", NULL_KEY, AGENT, 10.0, PI)
        elseif cmd == "rem_trustee" then
            show_remove_trustee()
        end
        return
    end

    local idx = integer(label) - 1  -- numbered-list 0-based index

    if MenuContext == "set_select" then
        if idx >= 0 and idx < #CandidateKeys then
            PendingCandidate = uuid(CandidateKeys[idx + 1])
            show_confirm(PendingCandidate, "set_accept", "Accept Ownership",
                get_name(ll.GetOwner()) .. " wishes to submit to you.\n\nAccept?")
        end
    elseif MenuContext == "set_accept" then
        if cmd == "confirm" then show_honorific(PendingCandidate, "set_hon")
        else ll.RegionSayTo(CurrentUser, 0, "Declined."); show_main() end
    elseif MenuContext == "set_hon" then
        if idx >= 0 and idx < #OWNER_HONORIFICS then
            PendingHonorific = OWNER_HONORIFICS[idx + 1]
            show_confirm(ll.GetOwner(), "set_confirm", "Confirm",
                "Submit to " .. get_name(PendingCandidate) .. " as your " .. PendingHonorific .. "?")
        end
    elseif MenuContext == "set_confirm" then
        if cmd == "confirm" then
            persist_owner(PendingCandidate, PendingHonorific)
            ll.RegionSayTo(PendingCandidate, 0, get_name(ll.GetOwner()) .. " has submitted to you as their " .. PendingHonorific .. ".")
            ll.RegionSayTo(ll.GetOwner(), 0, "You are now property of " .. PendingHonorific .. " " .. get_name(PendingCandidate) .. ".")
            cleanup()
            menu_return()
        else show_main() end
    elseif MenuContext == "transfer_select" then
        if idx >= 0 and idx < #CandidateKeys then
            PendingCandidate = uuid(CandidateKeys[idx + 1])
            show_confirm(PendingCandidate, "transfer_accept", "Accept Transfer",
                "Accept ownership of " .. get_name(ll.GetOwner()) .. "?")
        end
    elseif MenuContext == "transfer_accept" then
        if cmd == "confirm" then show_honorific(PendingCandidate, "transfer_hon")
        else ll.RegionSayTo(CurrentUser, 0, "Declined."); show_main() end
    elseif MenuContext == "transfer_hon" then
        if idx >= 0 and idx < #OWNER_HONORIFICS then
            PendingHonorific = OWNER_HONORIFICS[idx + 1]
            local old = OwnerKey
            persist_owner(PendingCandidate, PendingHonorific)
            ll.RegionSayTo(old, 0, "You have transferred " .. get_name(ll.GetOwner()) .. " to " .. get_name(PendingCandidate) .. ".")
            ll.RegionSayTo(PendingCandidate, 0, get_name(ll.GetOwner()) .. " is now your property as " .. PendingHonorific .. ".")
            ll.RegionSayTo(ll.GetOwner(), 0, "You are now property of " .. PendingHonorific .. " " .. get_name(PendingCandidate) .. ".")
            cleanup()
        end
    elseif MenuContext == "release_owner" then
        if cmd == "confirm" then
            show_confirm(ll.GetOwner(), "release_wearer", "Confirm Release",
                "Released by " .. get_name(CurrentUser) .. ".\n\nConfirm freedom?")
        else show_main() end
    elseif MenuContext == "release_wearer" then
        if cmd == "confirm" then
            clear_owner()
            ll.RegionSayTo(ll.GetOwner(), 0, "Released. You are free.")
            cleanup()
        else
            ll.RegionSayTo(CurrentUser, 0, "Release cancelled.")
            cleanup()
        end
    elseif MenuContext == "runaway" then
        if cmd == "confirm" then
            local old = get_primary_owner()
            local old_hon = OwnerHonorific
            if old ~= NULL_KEY then
                local notify_msg = "You have run away from "
                if old_hon ~= "" then notify_msg = notify_msg .. old_hon .. " " end
                notify_msg = notify_msg .. get_name(old) .. "."
                ll.RegionSayTo(ll.GetOwner(), 0, notify_msg)
                ll.RegionSayTo(old, 0, get_name(ll.GetOwner()) .. " ran away.")
            else
                ll.RegionSayTo(ll.GetOwner(), 0, "You have run away.")
            end
            trigger_runaway()
            cleanup()
        else show_main() end
    elseif MenuContext == "runaway_disable_confirm" then
        if cmd == "confirm" then
            RunawayEnabled = false
            ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delta:" .. KEY_RUNAWAY_ENABLED .. ":0", NULL_KEY)
            ll.RegionSayTo(ll.GetOwner(), 0, "Runaway disabled.")
            ll.RegionSayTo(CurrentUser, 0, "Runaway disabled.")
            show_main()
        else
            ll.RegionSayTo(ll.GetOwner(), 0, "You declined to disable runaway.")
            ll.RegionSayTo(CurrentUser, 0, get_name(ll.GetOwner()) .. " declined to disable runaway.")
            show_main()
        end
    elseif MenuContext == "trustee_select" then
        if idx >= 0 and idx < #CandidateKeys then
            PendingCandidate = uuid(CandidateKeys[idx + 1])
            if list_find(TrusteeKeys, tostring(PendingCandidate)) ~= nil then
                ll.RegionSayTo(CurrentUser, 0, "Already trustee.")
                show_main()
                return
            end
            show_confirm(PendingCandidate, "trustee_accept", "Accept Trustee",
                get_name(ll.GetOwner()) .. " wants you as trustee.\n\nAccept?")
        end
    elseif MenuContext == "trustee_accept" then
        if cmd == "confirm" then show_honorific(PendingCandidate, "trustee_hon")
        else ll.RegionSayTo(CurrentUser, 0, "Declined."); show_main() end
    elseif MenuContext == "trustee_hon" then
        if idx >= 0 and idx < #TRUSTEE_HONORIFICS then
            PendingHonorific = TRUSTEE_HONORIFICS[idx + 1]
            add_trustee(PendingCandidate, PendingHonorific)
            ll.RegionSayTo(PendingCandidate, 0, "You are trustee of " .. get_name(ll.GetOwner()) .. " as " .. PendingHonorific .. ".")
            ll.RegionSayTo(CurrentUser, 0, get_name(PendingCandidate) .. " is trustee.")
            show_main()
        end
    elseif MenuContext == "remove_trustee" then
        if idx >= 0 and idx < #TrusteeKeys then
            local trustee_key = uuid(TrusteeKeys[idx + 1])
            remove_trustee(trustee_key)
            ll.RegionSayTo(CurrentUser, 0, "Removed.")
            ll.RegionSayTo(trustee_key, 0, "Removed as trustee.")
            show_main()
        end
    else
        show_main()
    end
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
    cleanup()
    register_self()
    apply_settings_sync()
end

function LLEvents.on_rez(p: number)
    ll.ResetScript()
end

function LLEvents.changed(c: number)
    if bit32.band(c, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local mtype = ll.JsonGetValue(msg, {"type"})
    if mtype == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if mtype == "kernel.register.refresh" then register_self()
        elseif mtype == "kernel.ping" then send_pong()
        elseif mtype == "kernel.reset.soft" or mtype == "kernel.reset.factory" then
            local target_context = ll.JsonGetValue(msg, {"context"})
            if target_context ~= JSON_INVALID then
                if target_context ~= "" and target_context ~= PLUGIN_CONTEXT then return end
            end
            ll.LinksetDataDelete("plugin.reg." .. PLUGIN_CONTEXT)
            ll.LinksetDataDelete("acl.policycontext:" .. PLUGIN_CONTEXT)
            ll.ResetScript()
        end
    elseif num == SETTINGS_BUS then
        if mtype == "settings.sync" then apply_settings_sync() end
    elseif num == UI_BUS then
        if mtype == "ui.menu.start" and ll.JsonGetValue(msg, {"context"}) ~= JSON_INVALID then
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) == PLUGIN_CONTEXT then
                local acl = integer(ll.JsonGetValue(msg, {"acl"}))
                local subpath = ""
                local sp = ll.JsonGetValue(msg, {"subpath"})
                if sp ~= JSON_INVALID then subpath = sp end
                if subpath ~= "" then
                    handle_subpath(id, acl, subpath)
                    return
                end
                CurrentUser = id
                UserAcl = acl
                show_main()
            end
        end
    elseif num == DIALOG_BUS then
        if mtype == "ui.dialog.response" then
            if ll.JsonGetValue(msg, {"session_id"}) ~= JSON_INVALID then
                if ll.JsonGetValue(msg, {"session_id"}) == SessionId then
                    local resp_ctx = ll.JsonGetValue(msg, {"context"})
                    if resp_ctx == JSON_INVALID then resp_ctx = "" end
                    local resp_btn = ll.JsonGetValue(msg, {"button"})
                    if resp_btn == JSON_INVALID then resp_btn = "" end
                    handle_button(resp_ctx, resp_btn)
                end
            end
        elseif mtype == "ui.dialog.timeout" then
            if ll.JsonGetValue(msg, {"session_id"}) ~= JSON_INVALID then
                if ll.JsonGetValue(msg, {"session_id"}) == SessionId then cleanup() end
            end
        end
    end
end

function LLEvents.sensor(detected)
    if CurrentUser == NULL_KEY then return end
    local wearer = ll.GetOwner()
    local candidates = {}
    for _, d in ipairs(detected) do
        local k = d:getKey()
        if k ~= wearer then candidates[#candidates + 1] = tostring(k) end
    end
    CandidateKeys = candidates

    if MenuContext == "set_scan" then show_candidates("set_select", "Set Owner", "Choose owner:")
    elseif MenuContext == "transfer_scan" then show_candidates("transfer_select", "Transfer", "Choose new owner:")
    elseif MenuContext == "trustee_scan" then show_candidates("trustee_select", "Add Trustee", "Choose trustee:") end
end

function LLEvents.no_sensor()
    if CurrentUser == NULL_KEY then return end
    CandidateKeys = {}
    if MenuContext == "set_scan" then show_candidates("set_select", "Set Owner", "Choose owner:")
    elseif MenuContext == "transfer_scan" then show_candidates("transfer_select", "Transfer", "Choose new owner:")
    elseif MenuContext == "trustee_scan" then show_candidates("trustee_select", "Add Trustee", "Choose trustee:") end
end

function LLEvents.dataserver(qid, data: string)
    if qid ~= ActiveNameQuery then return end
    if data ~= "" and data ~= "???" then cache_name(ActiveQueryTarget, data) end
    ActiveNameQuery = NULL_KEY
    ActiveQueryTarget = NULL_KEY
end

-- Top-level init.
main()

--[[--------------------
PLUGIN: plugin_blacklist.lua  (SLua port)
VERSION: 1.10
REVISION: 13  (SLua port rev 1)
PURPOSE: Blacklist management with sensor-based avatar selection
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility

SLUA PORT NOTES:
- Ported from plugin_blacklist.lsl rev 13 (includes the numbered-list context
  fallback fix: fall back to the button number when context is "" as well as
  invalid). Wire formats and the settings.blacklist.add/remove JSON unchanged.
- Idiomatic SLua: Blacklist / CandidateKeys are arrays of UUID strings.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.blacklist"
local PLUGIN_LABEL = "Blacklist"

--[[ -------------------- CONSTANTS -------------------- ]]
local MAX_NUMBERED_LIST_ITEMS = 11

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_BLACKLIST = "blacklist.blklistuuid"

--[[ -------------------- UI CONSTANTS -------------------- ]]
local BTN_BACK = "Back"
local BTN_ADD = "+Blacklist"
local BTN_REMOVE = "-Blacklist"
local BLACKLIST_RADIUS = 5.0

--[[ -------------------- STATE -------------------- ]]
local Blacklist = {}        -- array of UUID strings
local CurrentUser = NULL_KEY
local CurrentUserAcl = -999
local gPolicyButtons = {}
local SessionId = ""
local MenuContext = ""      -- "main" | "add_scan" | "add_pick" | "remove"
local CandidateKeys = {}    -- array of UUID strings

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

local function generate_session_id(): string
    return "blacklist_" .. tostring(ll.GetKey()) .. "_" .. tostring(ll.GetUnixTime())
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

local function blacklist_names()
    local out = {}
    for _, k in ipairs(Blacklist) do
        local nm = ll.GetDisplayName(uuid(k))
        if nm == "" then nm = k end
        out[#out + 1] = nm
    end
    return out
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
        "2", "+Blacklist,-Blacklist",
        "3", "+Blacklist,-Blacklist",
        "4", "+Blacklist,-Blacklist",
        "5", "+Blacklist,-Blacklist",
    }))
    write_plugin_reg(PLUGIN_LABEL)

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", ll.GetScriptName(),
    }), NULL_KEY)

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "chat.alias.declare",
        "alias", "blacklist",
        "context", PLUGIN_CONTEXT,
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
    local raw = ll.LinksetDataRead(KEY_BLACKLIST)
    if raw == "" then Blacklist = {} else Blacklist = ll.CSV2List(raw) end
end

local function send_blacklist_add(uuid_str: string)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "settings.blacklist.add",
        "uuid", uuid_str,
    }), NULL_KEY)
end

local function send_blacklist_remove(uuid_str: string)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "settings.blacklist.remove",
        "uuid", uuid_str,
    }), NULL_KEY)
end

--[[ -------------------- MENU DISPLAY -------------------- ]]

local function show_main_menu()
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, CurrentUserAcl)

    local body = "Blacklist Management\n\nCurrently blacklisted: " .. tostring(#Blacklist)

    local button_data = {btn(BTN_BACK, "back")}
    if btn_allowed("+Blacklist") then button_data[#button_data + 1] = btn(BTN_ADD, "add") end
    if btn_allowed("-Blacklist") then button_data[#button_data + 1] = btn(BTN_REMOVE, "remove") end

    SessionId = generate_session_id()
    MenuContext = "main"

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", "Blacklist",
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, button_data),
        "timeout", 60,
    }), NULL_KEY)
end

local function show_remove_menu()
    if #Blacklist == 0 then
        ll.RegionSayTo(CurrentUser, 0, "Blacklist is empty.")
        show_main_menu()
        return
    end

    SessionId = generate_session_id()
    MenuContext = "remove"

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", "Remove from Blacklist",
        "prompt", "Select avatar to remove:",
        "items", ll.List2Json(JSON_ARRAY, blacklist_names()),
        "timeout", 60,
    }), NULL_KEY)
end

local function show_add_candidates()
    if #CandidateKeys == 0 then
        ll.RegionSayTo(CurrentUser, 0, "No nearby avatars found.")
        show_main_menu()
        return
    end

    local names = {}
    local limit = #CandidateKeys
    if limit > MAX_NUMBERED_LIST_ITEMS then limit = MAX_NUMBERED_LIST_ITEMS end
    for i = 1, limit do
        local nm = ll.GetDisplayName(uuid(CandidateKeys[i]))
        if nm == "" then nm = CandidateKeys[i] end
        names[#names + 1] = nm
    end

    SessionId = generate_session_id()
    MenuContext = "add_pick"

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "dialog_type", "numbered_list",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", "Add to Blacklist",
        "prompt", "Select avatar to blacklist:",
        "items", ll.List2Json(JSON_ARRAY, names),
        "timeout", 60,
    }), NULL_KEY)
end

local function handle_subpath(user, acl_level: number, subpath: string)
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level)
    CurrentUser = user
    CurrentUserAcl = acl_level
    MenuContext = "main"

    if subpath == "add" then
        if not btn_allowed("+Blacklist") then
            ll.RegionSayTo(user, 0, "Access denied.")
            gPolicyButtons = {}
            return
        end
        gPolicyButtons = {}
        MenuContext = "add_scan"
        CandidateKeys = {}
        ll.Sensor("", NULL_KEY, AGENT, BLACKLIST_RADIUS, PI)
        return
    end
    if subpath == "rem" then
        if not btn_allowed("-Blacklist") then
            ll.RegionSayTo(user, 0, "Access denied.")
            gPolicyButtons = {}
            return
        end
        gPolicyButtons = {}
        show_remove_menu()
        return
    end

    gPolicyButtons = {}
    ll.RegionSayTo(user, 0, "Unknown blacklist subcommand: " .. subpath)
end

--[[ -------------------- NAVIGATION / SESSION -------------------- ]]

local function cleanup_session()
    if SessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.close",
            "session_id", SessionId,
        }), NULL_KEY)
    end
    CurrentUser = NULL_KEY
    CurrentUserAcl = -999
    gPolicyButtons = {}
    SessionId = ""
    MenuContext = ""
    CandidateKeys = {}
end

local function return_to_root()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return",
        "user", tostring(CurrentUser),
    }), NULL_KEY)
    cleanup_session()
end

--[[ -------------------- DIALOG HANDLERS -------------------- ]]

local function handle_dialog_response(msg: string)
    if ll.JsonGetValue(msg, {"session_id"}) == JSON_INVALID then return end
    if ll.JsonGetValue(msg, {"button"}) == JSON_INVALID then return end
    if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end

    local cmd = ll.JsonGetValue(msg, {"context"})
    -- numbered_list responses carry an empty (not invalid) context — fall back
    -- to the button number for "" as well as JSON_INVALID (rev-13 fix).
    if cmd == JSON_INVALID or cmd == "" then cmd = ll.JsonGetValue(msg, {"button"}) end

    if cmd == "back" or cmd == BTN_BACK then
        if MenuContext == "main" then return_to_root() else show_main_menu() end
        return
    end

    if MenuContext == "main" then
        if cmd == "add" then
            MenuContext = "add_scan"
            CandidateKeys = {}
            ll.Sensor("", NULL_KEY, AGENT, BLACKLIST_RADIUS, PI)
            return
        end
        if cmd == "remove" then
            show_remove_menu()
            return
        end
    end

    if MenuContext == "remove" then
        local idx = integer(cmd) - 1  -- 0-based
        if idx >= 0 and idx < #Blacklist then
            send_blacklist_remove(Blacklist[idx + 1])
            ll.RegionSayTo(CurrentUser, 0, "Removed from blacklist.")
        end
        show_main_menu()
        return
    end

    if MenuContext == "add_pick" then
        local idx = integer(cmd) - 1
        if idx >= 0 and idx < #CandidateKeys then
            local entry = CandidateKeys[idx + 1]
            if entry ~= "" then
                send_blacklist_add(entry)
                ll.RegionSayTo(CurrentUser, 0, "Added to blacklist.")
            end
        end
        show_main_menu()
        return
    end

    show_main_menu()
end

local function handle_dialog_timeout(msg: string)
    local session = ll.JsonGetValue(msg, {"session_id"})
    if session == JSON_INVALID then return end
    if session ~= SessionId then return end
    cleanup_session()
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
    cleanup_session()
    register_self()
    apply_settings_sync()
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.register.refresh" then
            register_self()
        elseif msg_type == "kernel.ping" then
            send_pong()
        elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            local target_context = ll.JsonGetValue(msg, {"context"})
            if target_context ~= JSON_INVALID then
                if target_context ~= "" and target_context ~= PLUGIN_CONTEXT then return end
            end
            ll.LinksetDataDelete("plugin.reg." .. PLUGIN_CONTEXT)
            ll.LinksetDataDelete("acl.policycontext:" .. PLUGIN_CONTEXT)
            ll.ResetScript()
        end
        return
    end

    if num == SETTINGS_BUS then
        if msg_type == "settings.sync" then apply_settings_sync() end
        return
    end

    if num == UI_BUS then
        if msg_type == "ui.menu.start" then
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) ~= PLUGIN_CONTEXT then return end

            local acl = integer(ll.JsonGetValue(msg, {"acl"}))
            local subpath = ""
            local sp = ll.JsonGetValue(msg, {"subpath"})
            if sp ~= JSON_INVALID then subpath = sp end

            if subpath ~= "" then
                handle_subpath(id, acl, subpath)
                return
            end

            CurrentUser = id
            CurrentUserAcl = acl
            show_main_menu()
        end
        return
    end

    if num == DIALOG_BUS then
        if msg_type == "ui.dialog.response" then
            handle_dialog_response(msg)
        elseif msg_type == "ui.dialog.timeout" then
            handle_dialog_timeout(msg)
        end
        return
    end
end

function LLEvents.sensor(detected)
    if CurrentUser == NULL_KEY then return end
    if MenuContext ~= "add_scan" then return end

    local candidates = {}
    local owner = ll.GetOwner()
    for _, d in ipairs(detected) do
        local k = d:getKey()
        local entry = tostring(k)
        if k ~= owner and list_find(Blacklist, entry) == nil then
            candidates[#candidates + 1] = entry
        end
    end
    CandidateKeys = candidates
    show_add_candidates()
end

function LLEvents.no_sensor()
    if CurrentUser == NULL_KEY then return end
    if MenuContext ~= "add_scan" then return end
    CandidateKeys = {}
    show_add_candidates()
end

-- Top-level init.
main()

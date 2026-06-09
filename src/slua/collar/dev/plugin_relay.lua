--[[--------------------
PLUGIN: plugin_relay.lua  (SLua port)
VERSION: 1.10
PURPOSE: RLV relay UI shell (mode / hardcore / bound-by / safeword). The engine
         is kmod_rlv; this script only drives the menu and persists mode.
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility

SLUA PORT NOTES:
- Ported from plugin_relay.lsl. settings.delta CSV writes, relay.* UI_BUS
  messages, and LSD contracts unchanged. (Relay persists mode, not restrictions.)
- Idiomatic SLua: Mode is a number; Hardcore/IsAttached/AwaitingList booleans.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.relay"
local PLUGIN_LABEL = "RLV Relay"

--[[ -------------------- RELAY MODE CONSTANTS -------------------- ]]
local MODE_OFF = 0
local MODE_ON  = 1
local MODE_ASK = 2

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_RELAY_MODE = "relay.mode"
local KEY_RELAY_HARDCORE = "relay.hardcoremode"

--[[ -------------------- STATE -------------------- ]]
local Mode = MODE_ASK
local Hardcore = false
local IsAttached = false

local CurrentUser = NULL_KEY
local UserAcl = -999
local gPolicyButtons = {}
local SessionId = ""
local AwaitingList = false

--[[ -------------------- HELPERS -------------------- ]]

--[[ integer(): SLua has no LSL-style (integer) cast; emulate it (truncate toward zero; non-numeric -> 0). ]]
local function integer(v): number
    local n = tonumber(v)
    if n == nil then return 0 end
    if n < 0 then return math.ceil(n) end
    return math.floor(n)
end

local function b2i(b: boolean): number
    if b then return 1 end
    return 0
end

local function list_find(t, v)
    for i, x in ipairs(t) do
        if x == v then return i end
    end
    return nil
end

local function lsd_int(lsd_key: string, fallback: number): number
    local v = ll.LinksetDataRead(lsd_key)
    if v == "" then return fallback end
    return integer(v)
end

local function generate_session_id(): string
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
end

local function truncate_name(name: string, max_len: number): string
    if #name <= max_len then return name end
    return string.sub(name, 1, max_len - 3) .. "..."
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

local function mode_str(): string
    if not IsAttached then return "OFF (not worn)" end
    if Mode == MODE_OFF then return "OFF" end
    if Mode == MODE_ASK then return "ASK" end
    if Hardcore then return "HARDCORE" end
    return "ON"
end

local function refresh_mode()
    Mode = lsd_int(KEY_RELAY_MODE, MODE_ASK)
    Hardcore = lsd_int(KEY_RELAY_HARDCORE, 0) ~= 0
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
        "2", "Mode,Bound by...,Safeword",
        "3", "Mode,Bound by...,Unbind,HC OFF,HC ON",
        "4", "Mode,Bound by...,Safeword",
        "5", "Mode,Bound by...,Unbind,HC OFF,HC ON",
    }))
    write_plugin_reg(PLUGIN_LABEL)

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", ll.GetScriptName(),
    }), NULL_KEY)

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "chat.alias.declare", "alias", "relay", "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "chat.alias.declare", "alias", "safeword", "context", PLUGIN_CONTEXT .. ".safeword",
    }), NULL_KEY)
end

local function send_pong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

--[[ -------------------- SETTINGS -------------------- ]]

local function persist_mode(new_mode: number)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delta:" .. KEY_RELAY_MODE .. ":" .. tostring(new_mode), NULL_KEY)
end

local function persist_hardcore(new_hardcore: boolean)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delta:" .. KEY_RELAY_HARDCORE .. ":" .. tostring(b2i(new_hardcore)), NULL_KEY)
end

--[[ -------------------- MENU SYSTEM -------------------- ]]

local function show_main_menu()
    SessionId = generate_session_id()
    refresh_mode()
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl)

    local buttons = {"Back"}
    if btn_allowed("Mode") then buttons[#buttons + 1] = "Mode" end
    if btn_allowed("Bound by...") then buttons[#buttons + 1] = "Bound by..." end
    if btn_allowed("Safeword") and not Hardcore then buttons[#buttons + 1] = "Safeword" end
    if btn_allowed("Unbind") then buttons[#buttons + 1] = "Unbind" end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", PLUGIN_LABEL .. " Menu",
        "message", "RLV Relay Menu\nMode: " .. mode_str(),
        "buttons", ll.List2Json(JSON_ARRAY, buttons),
        "timeout", 60,
    }), NULL_KEY)
end

local function show_mode_menu()
    SessionId = generate_session_id()
    refresh_mode()

    local buttons = {"Back", "OFF", "ASK", "ON"}
    if Mode == MODE_ON then
        if Hardcore then
            if btn_allowed("HC OFF") then buttons[#buttons + 1] = "HC OFF" end
        else
            if btn_allowed("HC ON") then buttons[#buttons + 1] = "HC ON" end
        end
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", "Relay Mode",
        "message", "RLV Relay Mode: " .. mode_str(),
        "buttons", ll.List2Json(JSON_ARRAY, buttons),
        "timeout", 60,
    }), NULL_KEY)
end

local function render_object_list(sources_json: string)
    SessionId = generate_session_id()

    local arr = {}
    if sources_json ~= "" and sources_json ~= JSON_INVALID then
        local i = 0
        local entry = ll.JsonGetValue(sources_json, {tostring(i)})
        while entry ~= JSON_INVALID do
            arr[#arr + 1] = entry
            i += 1
            entry = ll.JsonGetValue(sources_json, {tostring(i)})
        end
    end

    local message
    if #arr == 0 then
        message = "No active sources."
    else
        message = "Bound by:\n"
        for i, entry in ipairs(arr) do
            local nm = ll.JsonGetValue(entry, {"name"})
            local rcs = ll.JsonGetValue(entry, {"restr_count"})
            message = message .. tostring(i) .. ". " .. truncate_name(nm, 24)
            if rcs ~= JSON_INVALID and rcs ~= "0" then message = message .. " [" .. rcs .. "]" end
            message = message .. "\n"
        end
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", "Bound by",
        "message", message,
        "buttons", ll.List2Json(JSON_ARRAY, {"Back"}),
        "timeout", 60,
    }), NULL_KEY)
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
    UserAcl = -999
    gPolicyButtons = {}
    SessionId = ""
    AwaitingList = false
end

local function return_to_root()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user", tostring(CurrentUser),
    }), CurrentUser)
    cleanup_session()
end

--[[ -------------------- BUTTON HANDLING -------------------- ]]

local function set_mode(new_mode: number, clear_hardcore: boolean)
    Mode = new_mode
    if clear_hardcore then Hardcore = false end
    persist_mode(new_mode)
    if clear_hardcore then persist_hardcore(false) end
end

local function handle_button_click(button: string)
    if button == "Mode" then
        show_mode_menu()
    elseif button == "Bound by..." then
        AwaitingList = true
        ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {"type", "relay.list.request"}), NULL_KEY)
    elseif button == "Safeword" then
        if btn_allowed("Safeword") and not Hardcore then
            ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {"type", "relay.safeword"}), NULL_KEY)
            ll.RegionSayTo(CurrentUser, 0, "Safeword used - all restrictions cleared")
            show_main_menu()
        end
    elseif button == "Unbind" then
        if btn_allowed("Unbind") then
            ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {"type", "relay.safeword"}), NULL_KEY)
            ll.RegionSayTo(CurrentUser, 0, "Unbound - all restrictions cleared")
            show_main_menu()
        end
    elseif button == "OFF" then
        set_mode(MODE_OFF, true)
        ll.RegionSayTo(CurrentUser, 0, "Mode set to OFF")
        show_mode_menu()
    elseif button == "ASK" then
        set_mode(MODE_ASK, true)
        ll.RegionSayTo(CurrentUser, 0, "Mode set to ASK")
        show_mode_menu()
    elseif button == "ON" then
        Mode = MODE_ON
        persist_mode(MODE_ON)
        if not Hardcore then ll.RegionSayTo(CurrentUser, 0, "Mode set to ON") end
        show_mode_menu()
    elseif button == "HC ON" then
        if btn_allowed("HC ON") then
            Hardcore = true
            Mode = MODE_ON
            persist_hardcore(true)
            persist_mode(MODE_ON)
            ll.RegionSayTo(CurrentUser, 0, "Hardcore mode ENABLED")
            show_mode_menu()
        end
    elseif button == "HC OFF" then
        if btn_allowed("HC OFF") then
            Hardcore = false
            Mode = MODE_ON
            persist_hardcore(false)
            persist_mode(MODE_ON)
            ll.RegionSayTo(CurrentUser, 0, "Hardcore mode DISABLED")
            show_mode_menu()
        end
    elseif button == "Back" then
        return_to_root()
    else
        show_main_menu()
    end
end

--[[ -------------------- MENU MESSAGE HANDLERS -------------------- ]]

local function handle_subpath(user, acl_level: number, subpath: string)
    CurrentUser = user
    UserAcl = acl_level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level)

    if subpath == "on" or subpath == "off" or subpath == "ask" then
        if not btn_allowed("Mode") then
            ll.RegionSayTo(user, 0, "Access denied."); gPolicyButtons = {}; return
        end
        if subpath == "off" then set_mode(MODE_OFF, true)
        elseif subpath == "ask" then set_mode(MODE_ASK, true)
        else set_mode(MODE_ON, false) end
        ll.RegionSayTo(user, 0, "Mode set to " .. string.upper(subpath) .. ".")
        gPolicyButtons = {}
        return
    end

    if subpath == "safeword" then
        if not btn_allowed("Safeword") and not btn_allowed("Unbind") then
            ll.RegionSayTo(user, 0, "Access denied."); gPolicyButtons = {}; return
        end
        ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {"type", "relay.safeword"}), NULL_KEY)
        ll.RegionSayTo(user, 0, "Safeword used - all restrictions cleared.")
        gPolicyButtons = {}
        return
    end

    ll.RegionSayTo(user, 0, "Unknown relay subcommand: " .. subpath)
    gPolicyButtons = {}
end

local function handle_start(msg: string)
    if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
    if ll.JsonGetValue(msg, {"context"}) == JSON_INVALID then return end
    if ll.JsonGetValue(msg, {"user"}) == JSON_INVALID then return end
    if ll.JsonGetValue(msg, {"context"}) ~= PLUGIN_CONTEXT then return end

    local user = uuid(ll.JsonGetValue(msg, {"user"}))
    local acl = integer(ll.JsonGetValue(msg, {"acl"}))

    local subpath = ""
    local sp = ll.JsonGetValue(msg, {"subpath"})
    if sp ~= JSON_INVALID then subpath = sp end

    if subpath ~= "" then
        handle_subpath(user, acl, subpath)
        return
    end

    CurrentUser = user
    UserAcl = acl
    show_main_menu()
end

local function handle_dialog_response(msg: string)
    if ll.JsonGetValue(msg, {"session_id"}) == JSON_INVALID then return end
    if ll.JsonGetValue(msg, {"button"}) == JSON_INVALID then return end
    if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
    handle_button_click(ll.JsonGetValue(msg, {"button"}))
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
    cleanup_session()
    IsAttached = ll.GetAttached() ~= 0
    refresh_mode()
    register_self()
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.attach(id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    IsAttached = id ~= NULL_KEY
    if IsAttached then refresh_mode() end
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.register.refresh" then
            register_self()
        elseif msg_type == "kernel.ping" then
            send_pong()
        elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            local ctx = ll.JsonGetValue(msg, {"context"})
            if ctx ~= JSON_INVALID and ctx ~= "" and ctx ~= PLUGIN_CONTEXT then return end
            ll.LinksetDataDelete("plugin.reg." .. PLUGIN_CONTEXT)
            ll.LinksetDataDelete("acl.policycontext:" .. PLUGIN_CONTEXT)
            ll.ResetScript()
        end
    elseif num == SETTINGS_BUS then
        if msg_type == "settings.sync" then refresh_mode() end
    elseif num == UI_BUS then
        if msg_type == "ui.menu.start" then
            handle_start(msg)
        elseif msg_type == "relay.list.response" then
            if not AwaitingList then return end
            AwaitingList = false
            local sources = ll.JsonGetValue(msg, {"sources"})
            if sources == JSON_INVALID then sources = "" end
            render_object_list(sources)
        end
    elseif num == DIALOG_BUS then
        if msg_type == "ui.dialog.response" then
            handle_dialog_response(msg)
        elseif msg_type == "ui.dialog.timeout" then
            local session = ll.JsonGetValue(msg, {"session_id"})
            if session == JSON_INVALID then return end
            if session ~= SessionId then return end
            cleanup_session()
        end
    end
end

-- Top-level init.
main()

--[[--------------------
PLUGIN: plugin_public.lua  (SLua port)
VERSION: 1.10
REVISION: 15  (SLua port rev 1)
PURPOSE: Toggle public access mode directly from the main menu
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility

SLUA PORT NOTES:
- Ported from plugin_public.lsl rev 15. Wire formats unchanged: the settings.delta
  CSV write, the plugin.reg.* / plugin.public.state / acl.policycontext:* LSD
  contracts, and the kmod_dialogs buttonconfig.
- Idiomatic SLua: PublicModeEnabled is a boolean (persisted/state-written as a
  number); policy buttons are an array; predicates return booleans.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.public"
local PLUGIN_LABEL_ON = "Public: Y"
local PLUGIN_LABEL_OFF = "Public: N"

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_PUBLIC_MODE = "public.mode"

--[[ -------------------- STATE -------------------- ]]
local PublicModeEnabled = false
local gPolicyButtons = {}

--[[ -------------------- HELPERS -------------------- ]]

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

--[[ -------------------- LIFECYCLE -------------------- ]]

local function write_plugin_reg(label: string)
    local k = "plugin.reg." .. PLUGIN_CONTEXT
    local v = ll.List2Json(JSON_OBJECT, {"label", label, "script", ll.GetScriptName()})
    if ll.LinksetDataRead(k) == v then return end  -- idempotent
    ll.LinksetDataWrite(k, v)
end

local function register_button_config()
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.buttonconfig.register",
        "context", PLUGIN_CONTEXT,
        "button_a", PLUGIN_LABEL_OFF,
        "button_b", PLUGIN_LABEL_ON,
    }), NULL_KEY)
end

-- Write toggle state to plugin.public.state (kmod_ui reads it at render time).
local function send_state_update()
    local k = "plugin.public.state"
    local v = tostring(b2i(PublicModeEnabled))
    if ll.LinksetDataRead(k) == v then return end  -- idempotent
    ll.LinksetDataWrite(k, v)
end

local function register_self()
    ll.LinksetDataWrite("acl.policycontext:" .. PLUGIN_CONTEXT, ll.List2Json(JSON_OBJECT, {
        "3", "toggle",
        "4", "toggle",
        "5", "toggle",
    }))

    write_plugin_reg(PLUGIN_LABEL_OFF)
    register_button_config()
    send_state_update()

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL_OFF,
        "script", ll.GetScriptName(),
    }), NULL_KEY)

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "chat.alias.declare",
        "alias", "public",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

local function send_pong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

--[[ -------------------- SETTINGS CONSUMPTION -------------------- ]]

local function apply_settings_sync()
    local old_state = PublicModeEnabled
    local lsd_val = ll.LinksetDataRead(KEY_PUBLIC_MODE)
    if lsd_val ~= "" then PublicModeEnabled = integer(lsd_val) ~= 0 end
    if old_state ~= PublicModeEnabled then send_state_update() end
end

--[[ -------------------- SETTINGS MODIFICATION -------------------- ]]

local function persist_public_mode(new_value: boolean)
    -- kmod_settings is the canonical writer (settings.delta CSV protocol).
    ll.MessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" .. KEY_PUBLIC_MODE .. ":" .. tostring(b2i(new_value)), NULL_KEY)
end

local function update_ui_label_and_return(user)
    send_state_update()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return",
        "user", tostring(user),
    }), NULL_KEY)
end

--[[ -------------------- ACTIONS -------------------- ]]

local function set_public_mode(user, acl_level: number, target_enabled: boolean)
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level)
    if not btn_allowed("toggle") then
        ll.RegionSayTo(user, 0, "Access denied.")
        gPolicyButtons = {}
        return
    end
    gPolicyButtons = {}

    if PublicModeEnabled == target_enabled then
        if target_enabled then ll.RegionSayTo(user, 0, "Public access already enabled.")
        else ll.RegionSayTo(user, 0, "Public access already disabled.") end
        return
    end

    PublicModeEnabled = target_enabled
    persist_public_mode(PublicModeEnabled)
    if PublicModeEnabled then ll.RegionSayTo(user, 0, "Public access enabled.")
    else ll.RegionSayTo(user, 0, "Public access disabled.") end
    send_state_update()
end

local function handle_subpath(user, acl_level: number, subpath: string)
    if subpath == "on" then
        set_public_mode(user, acl_level, true)
    elseif subpath == "off" then
        set_public_mode(user, acl_level, false)
    else
        ll.RegionSayTo(user, 0, "Unknown public subcommand: " .. subpath)
    end
end

local function toggle_public_access(user, acl_level: number)
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level)
    if not btn_allowed("toggle") then
        ll.RegionSayTo(user, 0, "Access denied.")
        gPolicyButtons = {}
        return
    end
    gPolicyButtons = {}

    PublicModeEnabled = not PublicModeEnabled
    persist_public_mode(PublicModeEnabled)
    if PublicModeEnabled then ll.RegionSayTo(user, 0, "Public access enabled.")
    else ll.RegionSayTo(user, 0, "Public access disabled.") end
    update_ui_label_and_return(user)
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
    gPolicyButtons = {}
    apply_settings_sync()
    register_self()
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    if num == KERNEL_LIFECYCLE then
        local msg_type = ll.JsonGetValue(msg, {"type"})
        if msg_type == JSON_INVALID then return end

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
            ll.LinksetDataDelete("plugin.public.state")
            ll.LinksetDataDelete("acl.policycontext:" .. PLUGIN_CONTEXT)
            ll.ResetScript()
        end
        return
    end

    if num == SETTINGS_BUS then
        if ll.JsonGetValue(msg, {"type"}) == "settings.sync" then
            apply_settings_sync()
        end
        return
    end

    if num == UI_BUS then
        if ll.JsonGetValue(msg, {"type"}) == "ui.menu.start" then
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) ~= PLUGIN_CONTEXT then return end
            if id == NULL_KEY then return end

            local acl = integer(ll.JsonGetValue(msg, {"acl"}))
            local subpath = ""
            local sp = ll.JsonGetValue(msg, {"subpath"})
            if sp ~= JSON_INVALID then subpath = sp end

            if subpath ~= "" then
                handle_subpath(id, acl, subpath)
            else
                toggle_public_access(id, acl)
            end
        end
        return
    end
end

-- Top-level init.
main()

--[[--------------------
PLUGIN: plugin_tpe.lua  (SLua port)
VERSION: 1.10
REVISION: 14  (SLua port rev 1)
PURPOSE: Manage TPE mode with wearer confirmation and owner oversight
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility

SLUA PORT NOTES:
- Ported from plugin_tpe.lsl rev 14. settings.delta CSV write, plugin.reg.* /
  plugin.tpe.state / buttonconfig contracts, ui.menu.close to kmod_ui unchanged.
- Idiomatic SLua: TpeModeEnabled is a boolean.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.tpe"
local PLUGIN_LABEL_ON = "TPE: Y"
local PLUGIN_LABEL_OFF = "TPE: N"

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_TPE_MODE = "tpe.mode"

--[[ -------------------- STATE -------------------- ]]
local TpeModeEnabled = false
local CurrentUser = NULL_KEY
local UserAcl = -999
local gPolicyButtons = {}
local SessionId = ""
local WearerKey = NULL_KEY

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

local function btn(label: string, cmd: string): string
    return ll.List2Json(JSON_OBJECT, {"label", label, "context", cmd})
end

local function gen_session(): string
    return tostring(ll.GetKey()) .. "_" .. tostring(ll.GetUnixTime())
end

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
end

local function close_ui_for_user(user)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.close",
        "context", PLUGIN_CONTEXT,
        "user", tostring(user),
    }), user)
end

local function menu_return(user)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return",
        "user", tostring(user),
    }), NULL_KEY)
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
    if ll.LinksetDataRead(k) == v then return end
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

local function send_state_update()
    local k = "plugin.tpe.state"
    local v = tostring(b2i(TpeModeEnabled))
    if ll.LinksetDataRead(k) == v then return end
    ll.LinksetDataWrite(k, v)
end

local function register_with_kernel()
    ll.LinksetDataWrite("acl.policycontext:" .. PLUGIN_CONTEXT, ll.List2Json(JSON_OBJECT, {
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
end

local function send_pong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

--[[ -------------------- SETTINGS -------------------- ]]

local function persist_tpe_mode(new_value: boolean)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" .. KEY_TPE_MODE .. ":" .. tostring(b2i(new_value)), NULL_KEY)
end

local function apply_settings_sync()
    local prev = TpeModeEnabled
    local lsd_val = ll.LinksetDataRead(KEY_TPE_MODE)
    if lsd_val ~= "" then TpeModeEnabled = integer(lsd_val) ~= 0 end
    if TpeModeEnabled ~= prev then send_state_update() end
end

--[[ -------------------- BUTTON HANDLING -------------------- ]]

local function handle_button_click(cmd: string)
    if cmd == "confirm" then
        TpeModeEnabled = true
        persist_tpe_mode(true)

        ll.RegionSayTo(WearerKey, 0, "TPE mode enabled. You have relinquished collar control.")
        if CurrentUser ~= WearerKey then
            ll.RegionSayTo(CurrentUser, 0, "TPE mode enabled with wearer consent.")
        end

        send_state_update()
        close_ui_for_user(WearerKey)
        if CurrentUser ~= WearerKey then menu_return(CurrentUser) end
        cleanup_session()
    elseif cmd == "cancel" then
        ll.RegionSayTo(WearerKey, 0, "TPE activation cancelled.")
        if CurrentUser ~= WearerKey then
            ll.RegionSayTo(CurrentUser, 0, "Wearer declined TPE activation.")
        end
        close_ui_for_user(WearerKey)
        if CurrentUser ~= WearerKey then menu_return(CurrentUser) end
        cleanup_session()
    end
end

--[[ -------------------- TPE TOGGLE LOGIC -------------------- ]]

local function handle_tpe_click(user, acl_level: number)
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level)
    if not btn_allowed("toggle") then
        ll.RegionSayTo(user, 0, "Access denied. Only primary owner can manage TPE mode.")
        cleanup_session()
        return
    end

    CurrentUser = user
    UserAcl = acl_level
    WearerKey = ll.GetOwner()

    if TpeModeEnabled then
        -- TPE on → disable directly (owner can release without wearer consent).
        TpeModeEnabled = false
        persist_tpe_mode(false)
        ll.RegionSayTo(user, 0, "TPE mode disabled. Wearer regains collar access.")
        if user ~= WearerKey then
            ll.RegionSayTo(WearerKey, 0, "Your collar access has been restored.")
        end
        send_state_update()
        menu_return(user)
        cleanup_session()
    else
        -- TPE off → requires wearer consent (dialog to the WEARER).
        local msg_body = "Your owner wants to enable TPE mode.\n\n"
            .. "By clicking Yes, you relinquish control of this collar. "
            .. "The normal collar menu will be locked out.\n\n"
            .. "A SOS menu remains available through long touch as a safety hatch.\n\n"
            .. "Do you consent?"

        SessionId = gen_session()
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.open",
            "session_id", SessionId,
            "user", tostring(ll.GetOwner()),
            "title", "TPE Confirmation",
            "body", msg_body,
            "button_data", ll.List2Json(JSON_ARRAY, {btn("Yes", "confirm"), btn("No", "cancel")}),
            "timeout", 60,
        }), NULL_KEY)
    end
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
    WearerKey = ll.GetOwner()
    cleanup_session()
    apply_settings_sync()
    register_with_kernel()
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

function LLEvents.link_message(sender_num: number, num: number, str: string, id)
    if num == KERNEL_LIFECYCLE then
        local msg_type = ll.JsonGetValue(str, {"type"})
        if msg_type == "kernel.register.refresh" then
            register_with_kernel()
        elseif msg_type == "kernel.ping" then
            send_pong()
        elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            local target_context = ll.JsonGetValue(str, {"context"})
            if target_context ~= JSON_INVALID then
                if target_context ~= "" and target_context ~= PLUGIN_CONTEXT then return end
            end
            ll.LinksetDataDelete("plugin.reg." .. PLUGIN_CONTEXT)
            ll.LinksetDataDelete("plugin.tpe.state")
            ll.LinksetDataDelete("acl.policycontext:" .. PLUGIN_CONTEXT)
            ll.ResetScript()
        end
    elseif num == SETTINGS_BUS then
        if ll.JsonGetValue(str, {"type"}) == "settings.sync" then
            apply_settings_sync()
        end
    elseif num == UI_BUS then
        if ll.JsonGetValue(str, {"type"}) == "ui.menu.start" then
            if ll.JsonGetValue(str, {"acl"}) == JSON_INVALID then return end
            if ll.JsonGetValue(str, {"context"}) ~= PLUGIN_CONTEXT then return end
            CurrentUser = id
            UserAcl = integer(ll.JsonGetValue(str, {"acl"}))
            handle_tpe_click(CurrentUser, UserAcl)
        end
    elseif num == DIALOG_BUS then
        local msg_type = ll.JsonGetValue(str, {"type"})
        if msg_type == "ui.dialog.response" then
            if ll.JsonGetValue(str, {"session_id"}) ~= SessionId then return end
            local cmd = ll.JsonGetValue(str, {"context"})
            if cmd == JSON_INVALID then cmd = "" end
            handle_button_click(cmd)
        elseif msg_type == "ui.dialog.timeout" then
            if ll.JsonGetValue(str, {"session_id"}) ~= SessionId then return end
            ll.RegionSayTo(WearerKey, 0, "TPE confirmation timed out.")
            if CurrentUser ~= WearerKey then
                ll.RegionSayTo(CurrentUser, 0, "TPE confirmation timed out.")
            end
            close_ui_for_user(WearerKey)
            if CurrentUser ~= WearerKey then menu_return(CurrentUser) end
            cleanup_session()
        end
    end
end

-- Top-level init.
main()

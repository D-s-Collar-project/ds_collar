--[[--------------------
PLUGIN: plugin_bell.lua  (SLua port)
VERSION: 1.10
PURPOSE: Bell visibility / sound / volume settings + jingle while moving
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility

SLUA PORT NOTES:
- Ported from plugin_bell.lsl. settings.delta CSV writes and LSD contracts
  unchanged. moving_start/moving_end drive the jingle timer.
- Idiomatic SLua: BellVisible / BellSoundEnabled / IsMoving are booleans;
  BellVolume a number. The find-bell-link `jump` becomes a `break`.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.bell"
local PLUGIN_LABEL = "Bell"

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_BELL_VISIBLE = "bell.visible"
local KEY_BELL_SOUND_ENABLED = "bell.enablesound"
local KEY_BELL_VOLUME = "bell.volume"
local KEY_BELL_SOUND = "bell.sound"

--[[ -------------------- STATE -------------------- ]]
local BellVisible = false
local BellSoundEnabled = false
local BellVolume = 0.3
local BellSound = "16fcf579-82cb-b110-c1a4-5fa5e1385406"
local IsMoving = false
local BellLink = 0

local JINGLE_INTERVAL = 1.75

local CurrentUser = NULL_KEY
local UserAcl = -999
local gPolicyButtons = {}
local SessionId = ""
local MenuContext = ""

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

local function generate_session_id(): string
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
end

local function lsd_bool(lsd_key: string, fallback: boolean): boolean
    local v = ll.LinksetDataRead(lsd_key)
    if v == "" then return fallback end
    return integer(v) ~= 0
end

local function lsd_float(lsd_key: string, fallback: number): number
    local v = ll.LinksetDataRead(lsd_key)
    if v == "" then return fallback end
    return tonumber(v) or fallback
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

local function set_bell_visibility(visible: boolean)
    if BellLink == 0 then
        local link_count = ll.GetNumberOfPrims()
        for i = 1, link_count do
            if string.lower(ll.GetLinkName(i)) == "bell" then BellLink = i; break end
        end
    end
    if BellLink ~= 0 then
        ll.SetLinkAlpha(BellLink, (visible and 1.0) or 0.0, ALL_SIDES)
    end
    BellVisible = visible
end

local function play_jingle()
    if BellSound == "" or BellSound == "00000000-0000-0000-0000-000000000000" then return end
    if not BellSoundEnabled then return end
    ll.TriggerSound(BellSound, BellVolume)
end

--[[ -------------------- MENU DISPLAY -------------------- ]]

local function show_menu(context: string, title: string, body: string, button_data)
    SessionId = generate_session_id()
    MenuContext = context
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", title,
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, button_data),
        "timeout", 60,
    }), NULL_KEY)
end

--[[ -------------------- REGISTRATION -------------------- ]]

local function write_plugin_reg(label: string)
    local k = "plugin.reg." .. PLUGIN_CONTEXT
    local v = ll.List2Json(JSON_OBJECT, {"label", label, "script", ll.GetScriptName()})
    if ll.LinksetDataRead(k) == v then return end
    ll.LinksetDataWrite(k, v)
end

local function register_self()
    ll.LinksetDataWrite("acl.policycontext:" .. PLUGIN_CONTEXT, ll.List2Json(JSON_OBJECT, {
        "3", "Show,Sound,Volume +,Volume -",
        "4", "Show,Sound,Volume +,Volume -",
        "5", "Show,Sound,Volume +,Volume -",
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
        "alias", "bell",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

local function send_pong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

local function persist_bell_setting(setting_key: string, value: string)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delta:" .. setting_key .. ":" .. value, NULL_KEY)
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
    MenuContext = ""
end

local function return_to_root()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return",
        "user", tostring(CurrentUser),
    }), NULL_KEY)
    cleanup_session()
end

--[[ -------------------- MENU SYSTEM -------------------- ]]

local function show_main_menu()
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl)

    local visible_label = "Show: N"
    if BellVisible then visible_label = "Show: Y" end
    local sound_label = "Sound: Off"
    if BellSoundEnabled then sound_label = "Sound: On" end

    local button_data = {btn("Back", "back")}
    if btn_allowed("Show") then button_data[#button_data + 1] = btn(visible_label, "toggle_visible") end
    if btn_allowed("Sound") then button_data[#button_data + 1] = btn(sound_label, "toggle_sound") end
    if btn_allowed("Volume +") then button_data[#button_data + 1] = btn("Volume +", "vol_up") end
    if btn_allowed("Volume -") then button_data[#button_data + 1] = btn("Volume -", "vol_down") end

    local body = "Bell Control\n\n"
        .. "Visibility: " .. tostring(b2i(BellVisible)) .. "\n"
        .. "Sound: " .. tostring(b2i(BellSoundEnabled)) .. "\n"
        .. "Volume: " .. tostring(integer(BellVolume * 100)) .. "%"

    show_menu("main", "Bell", body, button_data)
end

--[[ -------------------- CHAT SUBCOMMANDS -------------------- ]]

local function set_bell_visible_state(user, acl_level: number, target_visible: boolean)
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level)
    if not btn_allowed("Show") then
        ll.RegionSayTo(user, 0, "Access denied."); gPolicyButtons = {}; return
    end
    gPolicyButtons = {}
    if BellVisible == target_visible then
        if target_visible then ll.RegionSayTo(user, 0, "Bell already shown.")
        else ll.RegionSayTo(user, 0, "Bell already hidden.") end
        return
    end
    BellVisible = target_visible
    set_bell_visibility(BellVisible)
    persist_bell_setting(KEY_BELL_VISIBLE, tostring(b2i(BellVisible)))
    if BellVisible then ll.RegionSayTo(user, 0, "Bell shown.") else ll.RegionSayTo(user, 0, "Bell hidden.") end
end

local function set_bell_sound_state(user, acl_level: number, target_enabled: boolean)
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level)
    if not btn_allowed("Sound") then
        ll.RegionSayTo(user, 0, "Access denied."); gPolicyButtons = {}; return
    end
    gPolicyButtons = {}
    if BellSoundEnabled == target_enabled then
        if target_enabled then ll.RegionSayTo(user, 0, "Bell sound already enabled.")
        else ll.RegionSayTo(user, 0, "Bell sound already disabled.") end
        return
    end
    BellSoundEnabled = target_enabled
    persist_bell_setting(KEY_BELL_SOUND_ENABLED, tostring(b2i(BellSoundEnabled)))
    if BellSoundEnabled then ll.RegionSayTo(user, 0, "Bell sound enabled.") else ll.RegionSayTo(user, 0, "Bell sound disabled.") end
end

local function adjust_bell_volume(user, acl_level: number, delta: number, policy_label: string)
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level)
    if not btn_allowed(policy_label) then
        ll.RegionSayTo(user, 0, "Access denied."); gPolicyButtons = {}; return
    end
    gPolicyButtons = {}
    BellVolume = BellVolume + delta
    if BellVolume > 1.0 then BellVolume = 1.0 end
    if BellVolume < 0.0 then BellVolume = 0.0 end
    persist_bell_setting(KEY_BELL_VOLUME, tostring(BellVolume))
    ll.RegionSayTo(user, 0, "Volume: " .. tostring(integer(BellVolume * 100)) .. "%")
end

local function handle_subpath(user, acl_level: number, subpath: string)
    if subpath == "show" then set_bell_visible_state(user, acl_level, true)
    elseif subpath == "hide" then set_bell_visible_state(user, acl_level, false)
    elseif subpath == "sound" then set_bell_sound_state(user, acl_level, true)
    elseif subpath == "silent" then set_bell_sound_state(user, acl_level, false)
    elseif subpath == "vol.up" then adjust_bell_volume(user, acl_level, 0.1, "Volume +")
    elseif subpath == "vol.dn" then adjust_bell_volume(user, acl_level, -0.1, "Volume -")
    elseif subpath == "jingle" then
        if not BellSoundEnabled then ll.RegionSayTo(user, 0, "Bell sound is disabled."); return end
        play_jingle()
    else
        ll.RegionSayTo(user, 0, "Unknown bell subcommand: " .. subpath)
    end
end

--[[ -------------------- BUTTON HANDLER -------------------- ]]

local function handle_button_click(msg: string)
    local cmd = ll.JsonGetValue(msg, {"context"})
    if cmd == JSON_INVALID then cmd = ll.JsonGetValue(msg, {"button"}) end

    if MenuContext ~= "main" then return end

    if cmd == "back" then
        return_to_root()
    elseif cmd == "vol_up" then
        BellVolume = BellVolume + 0.1
        if BellVolume > 1.0 then BellVolume = 1.0 end
        persist_bell_setting(KEY_BELL_VOLUME, tostring(BellVolume))
        ll.RegionSayTo(CurrentUser, 0, "Volume: " .. tostring(integer(BellVolume * 100)) .. "%")
        show_main_menu()
    elseif cmd == "vol_down" then
        BellVolume = BellVolume - 0.1
        if BellVolume < 0.0 then BellVolume = 0.0 end
        persist_bell_setting(KEY_BELL_VOLUME, tostring(BellVolume))
        ll.RegionSayTo(CurrentUser, 0, "Volume: " .. tostring(integer(BellVolume * 100)) .. "%")
        show_main_menu()
    elseif cmd == "toggle_visible" then
        BellVisible = not BellVisible
        set_bell_visibility(BellVisible)
        persist_bell_setting(KEY_BELL_VISIBLE, tostring(b2i(BellVisible)))
        if BellVisible then ll.RegionSayTo(CurrentUser, 0, "Bell shown.") else ll.RegionSayTo(CurrentUser, 0, "Bell hidden.") end
        show_main_menu()
    elseif cmd == "toggle_sound" then
        BellSoundEnabled = not BellSoundEnabled
        persist_bell_setting(KEY_BELL_SOUND_ENABLED, tostring(b2i(BellSoundEnabled)))
        if BellSoundEnabled then ll.RegionSayTo(CurrentUser, 0, "Bell sound enabled.") else ll.RegionSayTo(CurrentUser, 0, "Bell sound disabled.") end
        show_main_menu()
    end
end

--[[ -------------------- SETTINGS -------------------- ]]

local function apply_settings_sync()
    local prev_visible = BellVisible
    BellVisible = lsd_bool(KEY_BELL_VISIBLE, BellVisible)
    BellSoundEnabled = lsd_bool(KEY_BELL_SOUND_ENABLED, BellSoundEnabled)
    BellVolume = lsd_float(KEY_BELL_VOLUME, BellVolume)
    local tmp = ll.LinksetDataRead(KEY_BELL_SOUND)
    if tmp ~= "" then BellSound = tmp end
    if BellVisible ~= prev_visible then set_bell_visibility(BellVisible) end
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
    cleanup_session()
    BellVisible = lsd_bool(KEY_BELL_VISIBLE, false)
    BellSoundEnabled = lsd_bool(KEY_BELL_SOUND_ENABLED, false)
    BellVolume = lsd_float(KEY_BELL_VOLUME, 0.3)
    set_bell_visibility(BellVisible)
    apply_settings_sync()
    register_self()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
    if bit32.band(change, CHANGED_LINK) ~= 0 then BellLink = 0 end
end

function LLEvents.timer()
    if IsMoving and BellVisible and BellSoundEnabled then play_jingle() end
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
            ll.LinksetDataDelete("acl.policycontext:" .. PLUGIN_CONTEXT)
            ll.ResetScript()
        end
        return
    end

    if num == SETTINGS_BUS then
        if ll.JsonGetValue(msg, {"type"}) == "settings.sync" then apply_settings_sync() end
        return
    end

    if num == UI_BUS then
        if ll.JsonGetValue(msg, {"type"}) == "ui.menu.start" then
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) ~= PLUGIN_CONTEXT then return end

            CurrentUser = id
            UserAcl = integer(ll.JsonGetValue(msg, {"acl"}))
            local subpath = ""
            local sp = ll.JsonGetValue(msg, {"subpath"})
            if sp ~= JSON_INVALID then subpath = sp end

            if subpath ~= "" then
                handle_subpath(id, UserAcl, subpath)
            else
                show_main_menu()
            end
        end
        return
    end

    if num == DIALOG_BUS then
        local msg_type = ll.JsonGetValue(msg, {"type"})
        if msg_type == "ui.dialog.response" then
            if ll.JsonGetValue(msg, {"session_id"}) == JSON_INVALID or ll.JsonGetValue(msg, {"button"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
            handle_button_click(msg)
        elseif msg_type == "ui.dialog.timeout" then
            if ll.JsonGetValue(msg, {"session_id"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
            cleanup_session()
        end
        return
    end
end

function LLEvents.moving_start()
    if not IsMoving then
        IsMoving = true
        if BellVisible and BellSoundEnabled then play_jingle() end
        ll.SetTimerEvent(JINGLE_INTERVAL)
    end
end

function LLEvents.moving_end()
    if IsMoving then
        IsMoving = false
        ll.SetTimerEvent(0.0)
    end
end

-- Top-level init.
main()

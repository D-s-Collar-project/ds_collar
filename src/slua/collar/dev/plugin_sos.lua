--[[--------------------
PLUGIN: plugin_sos.lua  (SLua port)
VERSION: 1.10
PURPOSE: SOS emergency menu — Unleash / Clear RLV / Clear Relay / Escape (Runaway)
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility

SLUA PORT NOTES:
- Ported from plugin_sos.lsl. The graduated emergency actions are preserved
  exactly (per project convention — never collapse to one nuclear action).
  sos.* / settings.runaway wire messages unchanged.
- Idiomatic SLua: policy buttons are an array; the ACL-2 Runaway runtime strip
  uses table.remove.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.sos.911"
local PLUGIN_LABEL = "SOS"

--[[ -------------------- STATE -------------------- ]]
local CurrentUser = NULL_KEY
local UserAcl = -999
local gPolicyButtons = {}
local SessionId = ""
local MenuContext = "main"

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

--[[ -------------------- REGISTRATION -------------------- ]]

local function write_plugin_reg(label: string)
    local k = "plugin.reg." .. PLUGIN_CONTEXT
    local v = ll.List2Json(JSON_OBJECT, {"label", label, "script", ll.GetScriptName()})
    if ll.LinksetDataRead(k) == v then return end
    ll.LinksetDataWrite(k, v)
end

local function declare_alias(alias: string, context: string)
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "chat.alias.declare",
        "alias", alias,
        "context", context,
    }), NULL_KEY)
end

local function register_self()
    ll.LinksetDataWrite("acl.policycontext:" .. PLUGIN_CONTEXT, ll.List2Json(JSON_OBJECT, {
        "0", "Unleash,Clear RLV,Clear Relay,Runaway",
        "2", "Runaway",
    }))
    write_plugin_reg(PLUGIN_LABEL)

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", ll.GetScriptName(),
    }), NULL_KEY)

    declare_alias("sos", PLUGIN_CONTEXT)
    declare_alias("sosunleash", PLUGIN_CONTEXT .. ".unleash")
    declare_alias("sosrestrict", PLUGIN_CONTEXT .. ".restrict")
    declare_alias("sosrelay", PLUGIN_CONTEXT .. ".relay")
    declare_alias("sosrunaway", PLUGIN_CONTEXT .. ".runaway")
end

local function send_pong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

--[[ -------------------- MENU DISPLAY -------------------- ]]

local function show_sos_menu()
    MenuContext = "main"
    SessionId = generate_session_id()
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl)

    -- At ACL 2, strip the SOS Runaway duplicate when in-scene Runaway is on.
    if UserAcl == 2 then
        if integer(ll.LinksetDataRead("access.enablerunaway")) ~= 0 then
            local idx = list_find(gPolicyButtons, "Runaway")
            if idx ~= nil then table.remove(gPolicyButtons, idx) end
        end
    end

    local button_data = {btn("Back", "back")}
    local body = "EMERGENCY ACCESS\n\nChoose an action:\n"

    if btn_allowed("Unleash") then
        button_data[#button_data + 1] = btn("Unleash", "unleash")
        body = body .. "• Unleash - Release leash\n"
    end
    if btn_allowed("Clear RLV") then
        button_data[#button_data + 1] = btn("Clear RLV", "clear_rlv")
        body = body .. "• Clear RLV - Clear RLV restrictions\n"
    end
    if btn_allowed("Clear Relay") then
        button_data[#button_data + 1] = btn("Clear Relay", "clear_relay")
        body = body .. "• Clear Relay - Clear relay restrictions\n"
    end
    if btn_allowed("Runaway") then
        -- UI label "Escape"; routing/policy stay "runaway"/"Runaway".
        button_data[#button_data + 1] = btn("Escape", "runaway")
        body = body .. "• Escape - Escape an abusive setting. Resets the collar to factory settings."
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", "SOS Emergency",
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, button_data),
        "timeout", 60,
    }), NULL_KEY)
end

local function show_runaway_confirm()
    MenuContext = "runaway_confirm"
    SessionId = generate_session_id()

    local body = "EMERGENCY ESCAPE\n\n"
        .. "This will remove ownership entirely and erase ALL collar settings. "
        .. "The collar will return to an unowned, unlocked state.\n\n"
        .. "This cannot be undone.\n\nProceed?"

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", "Escape",
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, {btn("No", "cancel"), btn("Yes", "confirm")}),
        "timeout", 30,
    }), NULL_KEY)
end

--[[ -------------------- EMERGENCY ACTIONS -------------------- ]]

local function action_unleash()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {"type", "sos.leash.release"}), CurrentUser)
    ll.RegionSayTo(CurrentUser, 0, "Leash released.")
end

local function action_clear_rlv()
    -- Structured clear (consumer-scoped); the consented collar lock stands.
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {"type", "sos.restrict.clear"}), CurrentUser)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {"type", "sos.relay.clear"}), CurrentUser)
    ll.RegionSayTo(CurrentUser, 0, "Imposed restrictions cleared -- the collar lock stands.")
end

local function action_clear_relay()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {"type", "sos.relay.clear"}), CurrentUser)
    ll.RegionSayTo(CurrentUser, 0, "All relay restrictions cleared.")
end

-- Nuclear, irreversible, unconditional (bypasses the in-scene runaway gate).
local function action_runaway()
    ll.RegionSayTo(CurrentUser, 0, "Escape initiated. Wiping collar...")
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {"type", "settings.runaway"}), NULL_KEY)
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
    MenuContext = "main"
end

local function return_to_root()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return",
        "user", tostring(CurrentUser),
    }), NULL_KEY)
    cleanup_session()
end

--[[ -------------------- CHAT SUBCOMMANDS -------------------- ]]

local function handle_subpath(user, acl_level: number, subpath: string)
    CurrentUser = user
    UserAcl = acl_level

    if subpath == "unleash" then
        action_unleash()
    elseif subpath == "restrict" then
        action_clear_rlv()
    elseif subpath == "relay" then
        action_clear_relay()
    elseif subpath == "runaway" then
        if acl_level == 2 and integer(ll.LinksetDataRead("access.enablerunaway")) ~= 0 then
            ll.RegionSayTo(user, 0, "Use Access → Runaway from the collar menu instead.")
            return
        end
        show_runaway_confirm()
    else
        ll.RegionSayTo(user, 0, "Unknown SOS subcommand: " .. subpath)
    end
end

--[[ -------------------- BUTTON HANDLER -------------------- ]]

local function handle_button_click(cmd: string)
    if MenuContext == "runaway_confirm" then
        if cmd == "confirm" then
            action_runaway()
            cleanup_session()  -- kmod_settings is about to wipe + reset us
            return
        end
        show_sos_menu()  -- cancel
        return
    end

    if cmd == "back" then
        return_to_root()
    elseif cmd == "unleash" then
        action_unleash()
        show_sos_menu()
    elseif cmd == "clear_rlv" then
        action_clear_rlv()
        show_sos_menu()
    elseif cmd == "clear_relay" then
        action_clear_relay()
        show_sos_menu()
    elseif cmd == "runaway" then
        show_runaway_confirm()
    end
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
    cleanup_session()
    register_self()
end

function LLEvents.changed(change_mask: number)
    if bit32.band(change_mask, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
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
            UserAcl = acl
            show_sos_menu()
        end
        return
    end

    if num == DIALOG_BUS then
        if msg_type == "ui.dialog.response" then
            if ll.JsonGetValue(msg, {"session_id"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
            local cmd = ll.JsonGetValue(msg, {"context"})
            if cmd == JSON_INVALID then cmd = "" end
            handle_button_click(cmd)
        elseif msg_type == "ui.dialog.timeout" then
            if ll.JsonGetValue(msg, {"session_id"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
            cleanup_session()
        end
        return
    end
end

-- Top-level init.
main()

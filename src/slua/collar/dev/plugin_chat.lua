--[[--------------------
PLUGIN: plugin_chat.lua  (SLua port)
VERSION: 1.10
PURPOSE: Chat command settings UI (prefix / channel / public toggle)
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility

SLUA PORT NOTES:
- Ported from plugin_chat.lsl. settings.delta CSV writes, plugin.reg.* /
  acl.policycontext:* contracts unchanged. llTextBox input via a random negative
  channel + timeout preserved.
- Idiomatic SLua: PublicChat is a boolean; ChatChan a number.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.chat"
local PLUGIN_LABEL = "Chat"

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_PREFIX      = "chat.prefix"
local KEY_PUBLIC_CHAT = "chat.public"
local KEY_CHAT_CHAN   = "chat.channel"

--[[ -------------------- CONSTANTS -------------------- ]]
local INPUT_TIMEOUT = 30.0

--[[ -------------------- STATE -------------------- ]]
local ChatPrefix = ""
local PublicChat = false
local ChatChan = 1

local CurrentUser = NULL_KEY
local UserAcl = 0
local gPolicyButtons = {}
local SessionId = ""
local MenuContext = ""
local InputListen = 0

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
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetKey()) .. "_" .. tostring(ll.GetUnixTime())
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

local function register_self()
    ll.LinksetDataWrite("acl.policycontext:" .. PLUGIN_CONTEXT, ll.List2Json(JSON_OBJECT, {
        "4", "Set Prefix,Set Channel,Toggle Public",
        "5", "Set Prefix,Set Channel,Toggle Public",
    }))
    write_plugin_reg(PLUGIN_LABEL)

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", ll.GetScriptName(),
    }), NULL_KEY)
end

local function send_pong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

local function cleanup_session()
    if InputListen ~= 0 then ll.ListenRemove(InputListen); InputListen = 0 end
    ll.SetTimerEvent(0.0)
    if SessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.close",
            "session_id", SessionId,
        }), NULL_KEY)
    end
    SessionId = ""
    CurrentUser = NULL_KEY
    UserAcl = 0
    gPolicyButtons = {}
    MenuContext = ""
end

--[[ -------------------- SETTINGS -------------------- ]]

local function apply_settings_sync()
    local stored_prefix = ll.LinksetDataRead(KEY_PREFIX)
    local stored_public = ll.LinksetDataRead(KEY_PUBLIC_CHAT)
    if stored_prefix ~= "" then ChatPrefix = stored_prefix end
    if stored_public ~= "" then PublicChat = integer(stored_public) ~= 0 end
    local stored_chan = ll.LinksetDataRead(KEY_CHAT_CHAN)
    if stored_chan ~= "" then ChatChan = integer(stored_chan) end
end

local function persist_prefix(new_prefix: string)
    ChatPrefix = new_prefix
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delta:" .. KEY_PREFIX .. ":" .. new_prefix, NULL_KEY)
end

local function persist_chat_chan(new_chan: number)
    ChatChan = new_chan
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delta:" .. KEY_CHAT_CHAN .. ":" .. tostring(new_chan), NULL_KEY)
end

local function persist_public_chat(enabled: boolean)
    PublicChat = enabled
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delta:" .. KEY_PUBLIC_CHAT .. ":" .. tostring(b2i(enabled)), NULL_KEY)
end

--[[ -------------------- UI -------------------- ]]

local function return_to_root()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user", tostring(CurrentUser),
    }), NULL_KEY)
    cleanup_session()
end

local function show_main()
    SessionId = generate_session_id()
    MenuContext = "main"
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl)

    local public_label = "Public: OFF"
    if PublicChat then public_label = "Public: ON" end

    local prefix_display = ChatPrefix
    if prefix_display == "" then prefix_display = "(none)" end

    local body = "Chat Commands\n\nPrefix: " .. prefix_display
        .. "\nChannel: " .. tostring(ChatChan)
        .. "\nPublic chat: " .. public_label
        .. "\n\nChannel " .. tostring(ChatChan) .. " is the private channel."
        .. "\nChannel 0 allows public commands."

    local button_data = {btn("Back", "back")}
    if btn_allowed("Set Prefix")    then button_data[#button_data + 1] = btn("Set Prefix", "set_prefix") end
    if btn_allowed("Set Channel")   then button_data[#button_data + 1] = btn("Set Channel", "set_channel") end
    if btn_allowed("Toggle Public") then button_data[#button_data + 1] = btn(public_label, "toggle_public") end

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

local function open_input(context: string, prompt: string)
    MenuContext = context
    if InputListen ~= 0 then ll.ListenRemove(InputListen) end
    local input_chan = -1 - integer(ll.Frand(2000000))
    InputListen = ll.Listen(input_chan, "", CurrentUser, "")
    ll.SetTimerEvent(INPUT_TIMEOUT)
    ll.TextBox(CurrentUser, prompt, input_chan)
end

local function prompt_for_channel()
    open_input("input_channel", "Enter secondary channel number (1-9, not 0).\nLeave blank or type 'cancel' to abort.")
end

local function prompt_for_prefix()
    open_input("input_prefix", "Enter new prefix (1-8 characters).\nLeave blank or type 'cancel' to abort.")
end

--[[ -------------------- DIALOG HANDLER -------------------- ]]

local function handle_dialog_response(msg: string)
    if ll.JsonGetValue(msg, {"session_id"}) == JSON_INVALID then return end
    if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
    if uuid(ll.JsonGetValue(msg, {"user"})) ~= CurrentUser then return end

    local ctx = ll.JsonGetValue(msg, {"context"})
    if ctx == JSON_INVALID then ctx = "" end

    if MenuContext ~= "main" then return end

    if ctx == "back" then
        return_to_root()
    elseif ctx == "set_channel" then
        if not btn_allowed("Set Channel") then ll.RegionSayTo(CurrentUser, 0, "Access denied."); show_main(); return end
        prompt_for_channel()
    elseif ctx == "set_prefix" then
        if not btn_allowed("Set Prefix") then ll.RegionSayTo(CurrentUser, 0, "Access denied."); show_main(); return end
        prompt_for_prefix()
    elseif ctx == "toggle_public" then
        if not btn_allowed("Toggle Public") then ll.RegionSayTo(CurrentUser, 0, "Access denied."); show_main(); return end
        if PublicChat then
            persist_public_chat(false)
            ll.RegionSayTo(CurrentUser, 0, "Public chat commands disabled.")
        else
            persist_public_chat(true)
            ll.RegionSayTo(CurrentUser, 0, "Public chat commands enabled.")
        end
        show_main()
    end
end

--[[ -------------------- CHAT INPUT HANDLER -------------------- ]]

local function handle_channel_input(raw: string)
    if InputListen ~= 0 then ll.ListenRemove(InputListen); InputListen = 0 end
    ll.SetTimerEvent(0.0)

    raw = ll.StringTrim(raw, STRING_TRIM)
    if raw == "cancel" or raw == "" then
        ll.RegionSayTo(CurrentUser, 0, "Cancelled.")
        show_main()
        return
    end

    local new_chan = integer(raw)
    if new_chan < 1 or new_chan > 9 then
        ll.RegionSayTo(CurrentUser, 0, "Invalid channel. Must be 1-9.")
        show_main()
        return
    end

    persist_chat_chan(new_chan)
    ll.RegionSayTo(CurrentUser, 0, "Channel set to: " .. tostring(new_chan))
    show_main()
end

local function handle_prefix_input(new_prefix: string)
    if InputListen ~= 0 then ll.ListenRemove(InputListen); InputListen = 0 end
    ll.SetTimerEvent(0.0)

    new_prefix = ll.StringTrim(new_prefix, STRING_TRIM)
    if new_prefix == "cancel" or new_prefix == "" then
        ll.RegionSayTo(CurrentUser, 0, "Cancelled.")
        show_main()
        return
    end
    if #new_prefix > 8 then
        ll.RegionSayTo(CurrentUser, 0, "Prefix too long (max 8 characters). Try again.")
        show_main()
        return
    end

    persist_prefix(new_prefix)
    ll.RegionSayTo(CurrentUser, 0, "Prefix set to: " .. new_prefix)
    show_main()
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
    cleanup_session()
    apply_settings_sync()
    register_self()
end

function LLEvents.on_rez(param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

function LLEvents.timer()
    if InputListen ~= 0 then ll.ListenRemove(InputListen); InputListen = 0 end
    ll.SetTimerEvent(0.0)
    if CurrentUser ~= NULL_KEY then ll.RegionSayTo(CurrentUser, 0, "Input timed out.") end
    show_main()
end

function LLEvents.listen(channel: number, name: string, id, message: string)
    if id ~= CurrentUser then return end
    if MenuContext == "input_prefix" then handle_prefix_input(message)
    elseif MenuContext == "input_channel" then handle_channel_input(message) end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.register.refresh" then
            register_self()
            apply_settings_sync()
        elseif msg_type == "kernel.ping" then
            send_pong()
        elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.LinksetDataDelete("plugin.reg." .. PLUGIN_CONTEXT)
            ll.LinksetDataDelete("acl.policycontext:" .. PLUGIN_CONTEXT)
            ll.ResetScript()
        end
    elseif num == SETTINGS_BUS then
        if msg_type == "settings.sync" then apply_settings_sync() end
    elseif num == UI_BUS then
        if msg_type == "ui.menu.start" then
            if ll.JsonGetValue(msg, {"context"}) ~= PLUGIN_CONTEXT then return end
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            local req_acl = integer(ll.JsonGetValue(msg, {"acl"}))
            if req_acl < 4 then
                ll.RegionSayTo(id, 0, "Access denied.")
                return
            end
            CurrentUser = id
            UserAcl = req_acl
            show_main()
        end
    elseif num == DIALOG_BUS then
        if msg_type == "ui.dialog.response" then
            handle_dialog_response(msg)
        elseif msg_type == "ui.dialog.timeout" then
            if ll.JsonGetValue(msg, {"session_id"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
            cleanup_session()
        end
    end
end

-- Top-level init.
main()

--[[--------------------
PLUGIN: plugin_status.lua  (SLua port)
VERSION: 1.10
REVISION: 12  (SLua port rev 1)
PURPOSE: Read-only collar status display
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility

SLUA PORT NOTES:
- Ported from plugin_status.lsl rev 12. Wire formats and LSD contracts unchanged.
- Idiomatic SLua: CSV reads return arrays; csv_read still guards the
  ll.CSV2List("") == {""} empty-string case.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.status"
local PLUGIN_LABEL = "Status"

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_MULTI_OWNER_MODE  = "access.multiowner"
local KEY_OWNER             = "access.owner"
local KEY_OWNER_NAME        = "access.ownername"
local KEY_OWNER_HONORIFIC   = "access.ownerhonorific"
local KEY_OWNER_UUIDS       = "access.owneruuids"
local KEY_OWNER_NAMES       = "access.ownernames"
local KEY_OWNER_HONORIFICS  = "access.ownerhonorifics"
local KEY_TRUSTEE_UUIDS     = "access.trusteeuuids"
local KEY_TRUSTEE_NAMES     = "access.trusteenames"
local KEY_TRUSTEE_HONORIFICS = "access.trusteehonorifics"
local KEY_PUBLIC_ACCESS     = "public.mode"
local KEY_LOCKED            = "lock.locked"
local KEY_TPE_MODE          = "tpe.mode"
local KEY_CHAT_PREFIX       = "chat.prefix"
local KEY_CHAT_PUBLIC       = "chat.public"
local KEY_CHAT_CHAN         = "chat.channel"

--[[ -------------------- STATE -------------------- ]]
local CurrentUser = NULL_KEY
local SessionId = ""
-- Policy-button cache, loaded on menu entry. Status registers an empty policy
-- for all ACLs (presence marker only) so nothing is gated today; this scaffold
-- mirrors the other plugins and stages per-button filtering if the registered
-- policy ever differs by ACL. Consumed by btn_allowed.
local gPolicyButtons = {}

--[[ -------------------- HELPERS -------------------- ]]

local function generate_session_id(): string
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
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

local function csv_read(lsd_key: string)
    local raw = ll.LinksetDataRead(lsd_key)
    if raw == "" then return {} end
    return ll.CSV2List(raw)
end

local function lsd_truthy(lsd_key: string): boolean
    return integer(ll.LinksetDataRead(lsd_key)) ~= 0
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
        "1", "", "2", "", "3", "", "4", "", "5", "",
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
        "alias", "status",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

local function send_pong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

--[[ -------------------- STATUS REPORT -------------------- ]]

local function build_status_report(): string
    local status_text = "Collar Status:\n\n"

    local multi_mode = integer(ll.LinksetDataRead(KEY_MULTI_OWNER_MODE)) ~= 0

    if multi_mode then
        local uuids = csv_read(KEY_OWNER_UUIDS)
        local names = csv_read(KEY_OWNER_NAMES)
        local hons  = csv_read(KEY_OWNER_HONORIFICS)
        if #uuids > 0 then
            status_text = status_text .. "Owners:\n"
            for i = 1, #uuids do
                local nm = names[i] or ""
                local hn = hons[i] or ""
                if hn ~= "" then status_text = status_text .. "  " .. hn .. " " .. nm .. "\n"
                else status_text = status_text .. "  " .. nm .. "\n" end
            end
        else
            status_text = status_text .. "Owners: Uncommitted\n"
        end
    else
        local owner_uuid = ll.LinksetDataRead(KEY_OWNER)
        if owner_uuid ~= "" then
            local nm = ll.LinksetDataRead(KEY_OWNER_NAME)
            local hn = ll.LinksetDataRead(KEY_OWNER_HONORIFIC)
            if hn ~= "" then status_text = status_text .. "Owner: " .. hn .. " " .. nm .. "\n"
            else status_text = status_text .. "Owner: " .. nm .. "\n" end
        else
            status_text = status_text .. "Owner: Uncommitted\n"
        end
    end

    local trustee_uuids = csv_read(KEY_TRUSTEE_UUIDS)
    local trustee_names = csv_read(KEY_TRUSTEE_NAMES)
    local trustee_hons  = csv_read(KEY_TRUSTEE_HONORIFICS)
    if #trustee_uuids > 0 then
        status_text = status_text .. "Trustees:\n"
        for i = 1, #trustee_uuids do
            local nm = trustee_names[i] or ""
            local hn = trustee_hons[i] or ""
            if hn ~= "" then status_text = status_text .. "  " .. hn .. " " .. nm .. "\n"
            else status_text = status_text .. "  " .. nm .. "\n" end
        end
    else
        status_text = status_text .. "Trustees: none\n"
    end

    if lsd_truthy(KEY_PUBLIC_ACCESS) then status_text = status_text .. "Public Access: On\n"
    else status_text = status_text .. "Public Access: Off\n" end

    if lsd_truthy(KEY_LOCKED) then status_text = status_text .. "Collar locked: Yes\n"
    else status_text = status_text .. "Collar locked: No\n" end

    if lsd_truthy(KEY_TPE_MODE) then status_text = status_text .. "TPE Mode: On\n"
    else status_text = status_text .. "TPE Mode: Off\n" end

    local chat_prefix = ll.LinksetDataRead(KEY_CHAT_PREFIX)
    if chat_prefix == "" then chat_prefix = "(auto)" end
    local chat_chan = ll.LinksetDataRead(KEY_CHAT_CHAN)
    if chat_chan == "" then chat_chan = "1" end
    local chat_public_label = "off"
    if lsd_truthy(KEY_CHAT_PUBLIC) then chat_public_label = "on" end
    status_text = status_text .. "Chat prefix: " .. chat_prefix .. "  channel: " .. chat_chan
        .. "  public: " .. chat_public_label .. "\n"

    return status_text
end

--[[ -------------------- UI / SESSION -------------------- ]]

local function show_status_menu()
    SessionId = generate_session_id()
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", PLUGIN_LABEL,
        "message", build_status_report(),
        "buttons", ll.List2Json(JSON_ARRAY, {"Back"}),
        "timeout", 60,
    }), NULL_KEY)
end

local function cleanup_session()
    if SessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.close",
            "session_id", SessionId,
        }), NULL_KEY)
    end
    CurrentUser = NULL_KEY
    SessionId = ""
    gPolicyButtons = {}
end

local function ui_return_root()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return",
        "user", tostring(CurrentUser),
    }), NULL_KEY)
end

local function handle_button_click(button: string)
    if button == "Back" then
        ui_return_root()
        cleanup_session()
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
            ll.LinksetDataDelete("acl.policycontext:" .. PLUGIN_CONTEXT)
            ll.ResetScript()
        end
        return
    end

    if num == UI_BUS then
        if ll.JsonGetValue(msg, {"type"}) == "ui.menu.start" then
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) ~= PLUGIN_CONTEXT then return end
            if id == NULL_KEY then return end

            local sp = ll.JsonGetValue(msg, {"subpath"})
            if sp ~= JSON_INVALID and sp ~= "" then
                ll.RegionSayTo(id, 0, "Unknown status subcommand: " .. sp)
                return
            end

            CurrentUser = id
            gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, integer(ll.JsonGetValue(msg, {"acl"})))
            show_status_menu()
        end
        return
    end

    if num == DIALOG_BUS then
        local msg_type = ll.JsonGetValue(msg, {"type"})
        if msg_type == JSON_INVALID then return end

        if msg_type == "ui.dialog.response" then
            if ll.JsonGetValue(msg, {"session_id"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
            local button = ll.JsonGetValue(msg, {"button"})
            if button == JSON_INVALID then return end
            local user_str = ll.JsonGetValue(msg, {"user"})
            if user_str == JSON_INVALID then return end
            if uuid(user_str) ~= CurrentUser then return end
            handle_button_click(button)
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

--[[--------------------
MODULE: kmod_dialogs.lua  (SLua port)
VERSION: 1.10
REVISION: 8  (SLua port rev 1)
PURPOSE: Centralized dialog management for shared listener handling
ARCHITECTURE: Consolidated message bus lanes

SLUA PORT NOTES:
- Ported from kmod_dialogs.lsl rev 8. DIALOG_BUS (950) wire messages
  (ui.dialog.open / .close / .response / .timeout / .buttonconfig.register)
  keep their JSON shape so LSL plugins drive this dialog manager unchanged.
- Idiomatic SLua: the six parallel session lists become an array of session
  records, and each session's button map is now a real nested Lua table
  ({b=,c=}) instead of a serialized JSON string (it never leaves this script).
  The three button-config lists become a context-keyed map. The listen-loop's
  `jump found_context` becomes a `break`.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local DIALOG_BUS = 950

--[[ -------------------- CONSTANTS -------------------- ]]
local CHANNEL_BASE = -80000000   -- (integer) -8E07
local SESSION_MAX = 10           -- maximum concurrent sessions

--[[ -------------------- STATE -------------------- ]]
-- Sessions: array of { id, user, channel, listen, timeout, map }
-- where map is an array of { b = button_label, c = context }.
local Sessions = {}
local NextChannelOffset = 1

-- Button configs: context -> { a = label_off, b = label_on }
local ButtonConfigs = {}

--[[ -------------------- HELPERS -------------------- ]]

--[[ -------------------- TIMER SHIM (LSL single-timer over SLua LLTimers) -------------------- ]]
local _timerHandle = nil
local _on_timer  -- forward declaration; assigned where the timer body lives
--[[ integer(): SLua has no LSL-style (integer) cast; emulate it (truncate toward zero; non-numeric -> 0). ]]
local function integer(v): number
    local n = tonumber(v)
    if n == nil then return 0 end
    if n < 0 then return math.ceil(n) end
    return math.floor(n)
end

local function set_timer(interval: number)
    if _timerHandle then
        LLTimers:off(_timerHandle)
        _timerHandle = nil
    end
    if interval > 0 then
        _timerHandle = LLTimers:every(interval, _on_timer)
    end
end

local function get_msg_type(msg: string): string
    local t = ll.JsonGetValue(msg, {"type"})
    if t == JSON_INVALID then return "" end
    return t
end

local function validate_required_fields(json_str: string, field_names): boolean
    for _, field in ipairs(field_names) do
        if ll.JsonGetValue(json_str, {field}) == JSON_INVALID then
            return false
        end
    end
    return true
end

local function now(): number
    return ll.GetUnixTime()
end

--[[ -------------------- SESSION MANAGEMENT -------------------- ]]

local function find_session_idx(session_id: string)
    for i, s in ipairs(Sessions) do
        if s.id == session_id then return i end
    end
    return nil
end

local function close_session_at_idx(idx)
    if idx == nil then return end
    local s = Sessions[idx]
    if s == nil then return end
    if s.listen ~= 0 then ll.ListenRemove(s.listen) end
    table.remove(Sessions, idx)
end

local function close_session(session_id: string)
    close_session_at_idx(find_session_idx(session_id))
end

local function prune_expired_sessions()
    local now_time = now()
    for i = #Sessions, 1, -1 do
        local s = Sessions[i]
        if s.timeout > 0 and now_time >= s.timeout then
            ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
                "type", "ui.dialog.timeout",
                "session_id", s.id,
                "user", tostring(s.user),
            }), NULL_KEY)
            close_session_at_idx(i)
        end
    end
end

local function get_next_channel(): number
    local channel = CHANNEL_BASE - NextChannelOffset
    NextChannelOffset += 1
    if NextChannelOffset > 1000000 then NextChannelOffset = 1 end
    return channel
end

-- Register a new session and open the dialog. Shared tail of both dialog types.
local function open_session(session_id: string, user, title: string, body: string,
                           buttons, storage_map, timeout: number)
    local existing = find_session_idx(session_id)
    if existing ~= nil then close_session_at_idx(existing) end
    if #Sessions >= SESSION_MAX then close_session_at_idx(1) end  -- drop oldest

    local channel = get_next_channel()
    local listen_handle = ll.Listen(channel, "", user, "")

    local timeout_unix = 0
    if timeout > 0 then timeout_unix = now() + timeout end

    Sessions[#Sessions + 1] = {
        id = session_id, user = user, channel = channel,
        listen = listen_handle, timeout = timeout_unix, map = storage_map,
    }

    ll.Dialog(user, title .. "\n\n" .. body, buttons, channel)
end

--[[ -------------------- BUTTON CONFIG MANAGEMENT -------------------- ]]

local function register_button_config(context: string, button_a: string, button_b: string)
    ButtonConfigs[context] = { a = button_a, b = button_b }
end

local function get_button_label(context: string, button_state: number): string
    local cfg = ButtonConfigs[context]
    if cfg == nil then return context end
    if button_state == 0 then return cfg.a end
    return cfg.b
end

-- Read a context's toggle state from LSD: "plugin.<short>.state", where <short>
-- is the trailing dotted segment of the context. Missing → 0 (off).
local function read_toggle_state(context: string): number
    local parts = ll.ParseString2List(context, {"."}, {})
    local short_name = parts[#parts]
    if short_name == nil or short_name == "" then return 0 end
    return integer(ll.LinksetDataRead("plugin." .. short_name .. ".state"))
end

--[[ -------------------- DIALOG DISPLAY -------------------- ]]

local function handle_numbered_list_dialog(msg: string, session_id: string, user)
    if not validate_required_fields(msg, {"items"}) then return end

    local title, prompt, timeout = "Select Item", "Choose:", 60
    local tmp = ll.JsonGetValue(msg, {"title"});   if tmp ~= JSON_INVALID then title = tmp end
    tmp = ll.JsonGetValue(msg, {"prompt"});        if tmp ~= JSON_INVALID then prompt = tmp end
    tmp = ll.JsonGetValue(msg, {"timeout"});       if tmp ~= JSON_INVALID then timeout = integer(tmp) end

    local items = ll.Json2List(ll.JsonGetValue(msg, {"items"}))
    local item_count = #items
    local original_count = item_count
    if item_count == 0 then return end

    -- Max 11 items leaves room for the Back button.
    local max_items = 11
    if item_count > max_items then
        ll.RegionSayTo(ll.GetOwner(), 0, "WARNING: Item list truncated to " .. tostring(max_items)
            .. " items (had " .. tostring(original_count) .. ")")
        item_count = max_items
    end

    local body = prompt .. "\n\n"
    local buttons = {"Back"}
    for i = 1, item_count do
        body = body .. tostring(i) .. ". " .. items[i] .. "\n"
        buttons[#buttons + 1] = tostring(i)
    end

    -- Numbered buttons carry no context.
    local storage_map = {}
    for _, btn in ipairs(buttons) do
        storage_map[#storage_map + 1] = { b = btn, c = "" }
    end

    open_session(session_id, user, title, body, buttons, storage_map, timeout)
end

local function handle_dialog_open(msg: string)
    if not validate_required_fields(msg, {"session_id", "user"}) then return end

    local session_id = ll.JsonGetValue(msg, {"session_id"})
    local user = uuid(ll.JsonGetValue(msg, {"user"}))

    if ll.JsonGetValue(msg, {"dialog_type"}) ~= JSON_INVALID
        and ll.JsonGetValue(msg, {"dialog_type"}) == "numbered_list" then
        handle_numbered_list_dialog(msg, session_id, user)
        return
    end

    local buttons = {}
    local storage_map = {}  -- array of { b = label, c = context }

    if ll.JsonGetValue(msg, {"button_data"}) ~= JSON_INVALID then
        -- New format: mixed array of plain-label strings and {label,context[,state]} objects.
        for _, item in ipairs(ll.Json2List(ll.JsonGetValue(msg, {"button_data"}))) do
            local button_text = ""
            local button_context = ""

            local is_obj = ll.JsonValueType(item, {}) == JSON_OBJECT
            if is_obj
                and ll.JsonGetValue(item, {"context"}) ~= JSON_INVALID
                and ll.JsonGetValue(item, {"label"}) ~= JSON_INVALID then
                -- Routable button (state optional, used for toggle resolution).
                local context = ll.JsonGetValue(item, {"context"})
                local label = ll.JsonGetValue(item, {"label"})
                if ButtonConfigs[context] ~= nil then
                    -- Toggle button: resolve label via config + live LSD state.
                    button_text = get_button_label(context, read_toggle_state(context))
                else
                    button_text = label
                end
                button_context = context
            else
                -- Navigation / non-routable button.
                if is_obj and ll.JsonGetValue(item, {"label"}) ~= JSON_INVALID then
                    button_text = ll.JsonGetValue(item, {"label"})
                else
                    button_text = item
                end
            end

            buttons[#buttons + 1] = button_text
            storage_map[#storage_map + 1] = { b = button_text, c = button_context }
        end
    elseif ll.JsonGetValue(msg, {"buttons"}) ~= JSON_INVALID then
        -- Old format: array of label strings.
        buttons = ll.Json2List(ll.JsonGetValue(msg, {"buttons"}))
        for _, btn in ipairs(buttons) do
            storage_map[#storage_map + 1] = { b = btn, c = "" }
        end
    else
        return
    end

    local title, message, timeout = "Menu", "Select an option:", 60
    local tmp = ll.JsonGetValue(msg, {"title"})
    if tmp ~= JSON_INVALID then title = tmp end
    tmp = ll.JsonGetValue(msg, {"body"})
    if tmp ~= JSON_INVALID then
        message = tmp
    else
        tmp = ll.JsonGetValue(msg, {"message"})
        if tmp ~= JSON_INVALID then message = tmp end
    end
    tmp = ll.JsonGetValue(msg, {"timeout"})
    if tmp ~= JSON_INVALID then timeout = integer(tmp) end

    open_session(session_id, user, title, message, buttons, storage_map, timeout)
end

local function handle_dialog_close(msg: string)
    local session_id = ll.JsonGetValue(msg, {"session_id"})
    if session_id == JSON_INVALID then return end
    close_session(session_id)
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end

    Sessions = {}
    NextChannelOffset = 1
    ButtonConfigs = {}

    set_timer(5.0)  -- session cleanup
end

_on_timer = function()
    prune_expired_sessions()
end

function LLEvents.listen(channel: number, name: string, id, message: string)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    local idx = nil
    for i, s in ipairs(Sessions) do
        if s.channel == channel then idx = i; break end
    end
    if idx == nil then return end

    local s = Sessions[idx]
    if id ~= s.user then return end  -- speaker must match session user

    local clicked_context = ""
    for _, entry in ipairs(s.map) do
        if entry.b == message then clicked_context = entry.c; break end
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.response",
        "session_id", s.id,
        "user", tostring(id),
        "button", message,
        "context", clicked_context,
    }), NULL_KEY)

    close_session_at_idx(idx)
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    local msg_type = get_msg_type(msg)
    if msg_type == "" then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
        return
    end

    if num ~= DIALOG_BUS then return end

    if msg_type == "ui.dialog.open" then
        handle_dialog_open(msg)
    elseif msg_type == "ui.dialog.close" then
        handle_dialog_close(msg)
    elseif msg_type == "ui.dialog.buttonconfig.register" then
        if ll.JsonGetValue(msg, {"context"})  == JSON_INVALID then return end
        if ll.JsonGetValue(msg, {"button_a"}) == JSON_INVALID then return end
        if ll.JsonGetValue(msg, {"button_b"}) == JSON_INVALID then return end
        register_button_config(
            ll.JsonGetValue(msg, {"context"}),
            ll.JsonGetValue(msg, {"button_a"}),
            ll.JsonGetValue(msg, {"button_b"}))
    end
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        ll.ResetScript()
    end
end

-- Top-level init.
main()

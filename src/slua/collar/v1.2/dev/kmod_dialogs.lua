--[[--------------------
MODULE: kmod_dialogs.lua  (SLua port)
VERSION: 1.2
REVISION: 7  (SLua port rev 1)
PURPOSE: Centralized dialog management — owns every llDialog + its per-session
         listener, resolves the click back to a routable context, and broadcasts
         ui.dialog.response / timeout / close. Plugins never open their own dialog.
ARCHITECTURE: Consolidated message bus lanes.

SLUA PORT NOTES:
- Ported from kmod_dialogs.lsl v1.2 rev 7. Wire protocol preserved exactly: it
  consumes ui.dialog.open / ui.dialog.close / ui.dialog.buttonconfig.register on
  DIALOG_BUS 950 and emits ui.dialog.response / ui.dialog.timeout / ui.dialog.close
  with the same JSON shapes. nav:close is still handled centrally (tear down +
  broadcast ui.dialog.close, NOT a button response).
- IDIOMATIC: the six parallel Session* lists collapse into one array of Session
  records. The per-session click map — stored in the LSL as a {"b":[..],"c":[..]}
  JSON string purely to avoid per-entry object parsing on the hot listen path —
  becomes two native arrays (labels / ctxs) on the record, so resolving a click is
  one Lua loop with no JSON round-trip.
- IDIOMATIC: the three parallel ButtonConfig* lists become a dict keyed by context,
  { [context] = { a = labelA, b = labelB } }.
- GOTCHA: single-timer. LSL's recurring llSetTimerEvent(5.0) becomes
  LLTimers:every(5.0, prune) — SLua has no ll.SetTimerEvent. Only this one prune
  timer exists, so the single-timer contract is trivially honoured.
- ll.Listen / ll.ListenRemove drive the per-session listener; channel allocation
  (CHANNEL_BASE - offset) is unchanged. uuid() normalizes the JSON `user` string to
  a key for ll.Listen / ll.Dialog and for the session-owner compare in listen().
- csv_lead_int stands in for LSL's (integer) cast on the timeout field.
- Events are top-level LLEvents.*; state_entry becomes main() (also starts the
  prune timer), called once at the bottom.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local DIALOG_BUS       = 950

--[[ -------------------- CONSTANTS -------------------- ]]
local CHANNEL_BASE = -80000000  -- LSL had float -8E07 then (integer)-cast it
local SESSION_MAX  = 10         -- maximum concurrent sessions

--[[ -------------------- STATE -------------------- ]]
type Session = {
    id: string,
    user: any,        -- session owner (key)
    channel: number,
    listen: number,   -- listen handle (0 = none)
    timeout: number,  -- unix expiry (0 = never)
    labels: {string}, -- button labels (the llDialog button list)
    ctxs: {string},   -- parallel routing contexts ("" = non-routable)
}

local Sessions: {Session} = {}
local NextChannelOffset = 1

-- context -> { a = labelA, b = labelB } toggle button label configs.
local ButtonConfigs: { [string]: { a: string, b: string } } = {}

--[[ -------------------- HELPERS -------------------- ]]

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

-- LSL (integer) cast equivalent for a leading signed integer; 0 when absent.
local function csv_lead_int(s: string): number
    return tonumber(string.match(s, "^%s*(-?%d+)") or "") or 0
end

local function now(): number
    return ll.GetUnixTime()
end

--[[ -------------------- SESSION MANAGEMENT -------------------- ]]

local function find_session_idx_by_id(session_id: string): number?
    for i, s in ipairs(Sessions) do
        if s.id == session_id then return i end
    end
    return nil
end

local function find_session_idx_by_channel(channel: number): number?
    for i, s in ipairs(Sessions) do
        if s.channel == channel then return i end
    end
    return nil
end

local function close_session_at_idx(idx: number?)
    if idx == nil then return end
    local s = Sessions[idx]
    if s.listen ~= 0 then ll.ListenRemove(s.listen) end
    table.remove(Sessions, idx)
end

local function close_session(session_id: string)
    close_session_at_idx(find_session_idx_by_id(session_id))
end

local function prune_expired_sessions()
    local now_time = now()
    -- Iterate backwards to delete safely.
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
    NextChannelOffset = NextChannelOffset + 1
    if NextChannelOffset > 1000000 then NextChannelOffset = 1 end
    return channel
end

--[[ -------------------- BUTTON CONFIG MANAGEMENT -------------------- ]]

local function register_button_config(context: string, button_a: string, button_b: string)
    ButtonConfigs[context] = { a = button_a, b = button_b }
end

local function get_button_label(context: string, button_state: number): string
    local cfg = ButtonConfigs[context]
    if cfg == nil then return context end  -- no config: return context as-is
    if button_state == 0 then return cfg.a end
    return cfg.b
end

-- Read the toggle state for a context from LSD. Convention: the state lives at
-- "plugin.<short>.state" where <short> is the trailing dotted segment of the
-- context. Missing key -> 0 (default off).
local function read_toggle_state(context: string): number
    local parts = ll.ParseString2List(context, {"."}, {})
    local short_name = parts[#parts] or ""
    if short_name == "" then return 0 end
    return csv_lead_int(ll.LinksetDataRead("plugin." .. short_name .. ".state"))
end

--[[ -------------------- DIALOG DISPLAY -------------------- ]]

-- Numbered-list dialog: a body-numbered chooser (Back + 1..N index buttons), no
-- routing contexts. Defined before handle_dialog_open, which dispatches to it.
local function handle_numbered_list_dialog(msg: string, session_id: string, user)
    if not validate_required_fields(msg, {"items"}) then return end

    local title = "Select Item"
    local prompt = "Choose:"
    local timeout = 60

    local tmp = ll.JsonGetValue(msg, {"title"})
    if tmp ~= JSON_INVALID then title = tmp end
    tmp = ll.JsonGetValue(msg, {"prompt"})
    if tmp ~= JSON_INVALID then prompt = tmp end
    tmp = ll.JsonGetValue(msg, {"timeout"})
    if tmp ~= JSON_INVALID then timeout = csv_lead_int(tmp) end

    local items = ll.Json2List(ll.JsonGetValue(msg, {"items"}))
    local item_count = #items
    local original_count = item_count
    if item_count == 0 then return end

    -- Body numbered list (max 11 items, leaving room for Back).
    local body = prompt .. "\n\n"
    local buttons = {"Back"}

    local max_items = 11
    if item_count > max_items then
        ll.RegionSayTo(ll.GetOwner(), 0, "WARNING: Item list truncated to " ..
            tostring(max_items) .. " items (had " .. tostring(original_count) .. ")")
        item_count = max_items
    end

    for i = 1, item_count do
        body = body .. tostring(i) .. ". " .. items[i] .. "\n"
        buttons[#buttons + 1] = tostring(i)
    end

    local existing_idx = find_session_idx_by_id(session_id)
    if existing_idx ~= nil then close_session_at_idx(existing_idx) end
    if #Sessions >= SESSION_MAX then close_session_at_idx(1) end  -- evict oldest

    local channel = get_next_channel()
    local listen_handle = ll.Listen(channel, "", user, "")

    local timeout_unix = 0
    if timeout > 0 then timeout_unix = now() + timeout end

    local map_ctxs = {}
    for _ = 1, #buttons do map_ctxs[#map_ctxs + 1] = "" end

    Sessions[#Sessions + 1] = {
        id = session_id, user = user, channel = channel,
        listen = listen_handle, timeout = timeout_unix,
        labels = buttons, ctxs = map_ctxs,
    }

    ll.Dialog(user, title .. "\n\n" .. body, buttons, channel)
end

local function handle_dialog_open(msg: string)
    if not validate_required_fields(msg, {"session_id", "user"}) then return end

    local session_id = ll.JsonGetValue(msg, {"session_id"})
    local user = uuid(ll.JsonGetValue(msg, {"user"}))

    -- Numbered-list variant.
    local dialog_type = ll.JsonGetValue(msg, {"dialog_type"})
    if dialog_type ~= JSON_INVALID and dialog_type == "numbered_list" then
        handle_numbered_list_dialog(msg, session_id, user)
        return
    end

    -- Standard dialog: button_data (new, routable) or buttons (old, plain strings).
    local buttons = {}
    local map_ctxs = {}

    if ll.JsonGetValue(msg, {"button_data"}) ~= JSON_INVALID then
        -- New format: mixed array of plain strings and {label,context[,state]} objects.
        local button_data_list = ll.Json2List(ll.JsonGetValue(msg, {"button_data"}))
        for _, item in ipairs(button_data_list) do
            local button_text = ""
            local button_context = ""

            if ll.JsonValueType(item, {}) == JSON_OBJECT
                and ll.JsonGetValue(item, {"context"}) ~= JSON_INVALID
                and ll.JsonGetValue(item, {"label"}) ~= JSON_INVALID then
                -- Routable button.
                local context = ll.JsonGetValue(item, {"context"})
                local label = ll.JsonGetValue(item, {"label"})
                if ButtonConfigs[context] ~= nil then
                    -- Toggle button: resolve label from config + the live LSD state,
                    -- so a flip that landed mid-dialog is reflected on redraw.
                    button_text = get_button_label(context, read_toggle_state(context))
                else
                    button_text = label  -- action/plugin button: label verbatim
                end
                button_context = context
            else
                -- Nav or other non-routable button: label field if present, else the
                -- raw string; context stays empty.
                if ll.JsonValueType(item, {}) == JSON_OBJECT and ll.JsonGetValue(item, {"label"}) ~= JSON_INVALID then
                    button_text = ll.JsonGetValue(item, {"label"})
                else
                    button_text = item
                end
            end

            buttons[#buttons + 1] = button_text
            map_ctxs[#map_ctxs + 1] = button_context
        end
    elseif ll.JsonGetValue(msg, {"buttons"}) ~= JSON_INVALID then
        -- Old format: plain string array, no routing contexts.
        buttons = ll.Json2List(ll.JsonGetValue(msg, {"buttons"}))
        for _ = 1, #buttons do map_ctxs[#map_ctxs + 1] = "" end
    else
        return
    end

    local title = "Menu"
    local message = "Select an option:"
    local timeout = 60

    local tmp = ll.JsonGetValue(msg, {"title"})
    if tmp ~= JSON_INVALID then title = tmp end
    tmp = ll.JsonGetValue(msg, {"body"})
    if tmp ~= JSON_INVALID then
        message = tmp
    elseif ll.JsonGetValue(msg, {"message"}) ~= JSON_INVALID then
        message = ll.JsonGetValue(msg, {"message"})
    end
    tmp = ll.JsonGetValue(msg, {"timeout"})
    if tmp ~= JSON_INVALID then timeout = csv_lead_int(tmp) end

    local existing_idx = find_session_idx_by_id(session_id)
    if existing_idx ~= nil then close_session_at_idx(existing_idx) end
    if #Sessions >= SESSION_MAX then close_session_at_idx(1) end  -- evict oldest

    local channel = get_next_channel()
    local listen_handle = ll.Listen(channel, "", user, "")

    local timeout_unix = 0
    if timeout > 0 then timeout_unix = now() + timeout end

    Sessions[#Sessions + 1] = {
        id = session_id, user = user, channel = channel,
        listen = listen_handle, timeout = timeout_unix,
        labels = buttons, ctxs = map_ctxs,
    }

    ll.Dialog(user, title .. "\n\n" .. message, buttons, channel)
end

local function handle_dialog_close(msg: string)
    local session_id = ll.JsonGetValue(msg, {"session_id"})
    if session_id == JSON_INVALID then return end
    close_session(session_id)
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    Sessions          = {}
    NextChannelOffset = 1
    ButtonConfigs     = {}
    -- Single recurring timer for session cleanup (LSL llSetTimerEvent(5.0)).
    LLTimers:every(5.0, prune_expired_sessions)
end

function LLEvents.listen(channel: number, name: string, id, message: string)
    local i = find_session_idx_by_channel(channel)
    if i == nil then return end
    local s = Sessions[i]

    -- Verify speaker matches the session owner.
    if id ~= s.user then return end

    local session_id = s.id

    -- Resolve the click: find the clicked label, take the parallel context.
    local clicked_context = ""
    for k, lbl in ipairs(s.labels) do
        if lbl == message then
            clicked_context = s.ctxs[k] or ""
            break
        end
    end

    -- Close (nav:close) handled centrally: tear down + broadcast ui.dialog.close so
    -- the owning consumer clears its session state (NOT a response — no redraw).
    if clicked_context == "nav:close" then
        close_session_at_idx(i)
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.close",
            "session_id", session_id,
            "user", tostring(id),
        }), NULL_KEY)
        return
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.response",
        "session_id", session_id,
        "user", tostring(id),
        "button", message,
        "context", clicked_context,
    }), NULL_KEY)

    -- Close session after response.
    close_session_at_idx(i)
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
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

main()

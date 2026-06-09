--[[--------------------
MODULE: kmod_menu.lua  (SLua port)
VERSION: 1.10
REVISION: 4  (SLua port rev 1)
PURPOSE: Menu rendering and visual presentation service
ARCHITECTURE: Consolidated message bus lanes

SLUA PORT NOTES:
- Ported from kmod_menu.lsl rev 4. Consumes ui.menu.render / ui.message.show on
  UI_BUS and emits ui.dialog.open on DIALOG_BUS — all JSON, unchanged.
- Idiomatic SLua: button reordering uses array slices/concat helpers; the
  button_data array still serializes through ll.List2Json (nested-JSON preserved)
  so kmod_dialogs parses it identically.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- CONTEXT CONSTANTS -------------------- ]]
local ROOT_CONTEXT = "ui.core.root"
local SOS_CONTEXT  = "ui.sos.root"

--[[ -------------------- HELPERS -------------------- ]]

--[[ integer(): SLua has no LSL-style (integer) cast; emulate it (truncate toward zero; non-numeric -> 0). ]]
local function integer(v): number
    local n = tonumber(v)
    if n == nil then return 0 end
    if n < 0 then return math.ceil(n) end
    return math.floor(n)
end

local function get_msg_type(msg: string): string
    local t = ll.JsonGetValue(msg, {"type"})
    if t == JSON_INVALID then return "" end
    return t
end

local function validate_required_fields(json_str: string, field_names): boolean
    for _, field in ipairs(field_names) do
        if ll.JsonGetValue(json_str, {field}) == JSON_INVALID then return false end
    end
    return true
end

local function slice(t, a: number, b: number)  -- 1-based inclusive
    local out = {}
    for i = a, b do out[#out + 1] = t[i] end
    return out
end

local function concat_arrays(a, b)
    local out = {}
    for _, x in ipairs(a) do out[#out + 1] = x end
    for _, x in ipairs(b) do out[#out + 1] = x end
    return out
end

--[[ -------------------- BUTTON LAYOUT -------------------- ]]

-- Re-emit complete rows bottom-to-top (llDialog lays out bottom-left first).
local function reverse_complete_rows(button_list, row_size: number)
    local count = #button_list
    if count == 0 then return {} end
    local num_rows = count // row_size
    local reordered = {}
    for row = num_rows - 1, 0, -1 do
        local start1 = row * row_size + 1
        for j = start1, start1 + row_size - 1 do
            reordered[#reordered + 1] = button_list[j]
        end
    end
    return reordered
end

local function reorder_buttons_for_display(buttons)
    local count = #buttons
    if count == 0 then return {} end

    local row_size = 3
    local partial_count = count % row_size
    if partial_count == 0 then
        return reverse_complete_rows(buttons, row_size)
    end

    local partial_row = slice(buttons, 1, partial_count)
    local complete_buttons = slice(buttons, partial_count + 1, count)
    return concat_arrays(reverse_complete_rows(complete_buttons, row_size), partial_row)
end

--[[ -------------------- RENDERING -------------------- ]]

local function render_menu(msg: string)
    if not validate_required_fields(msg, {"user", "session_id", "menu_type", "buttons"}) then return end

    local user = uuid(ll.JsonGetValue(msg, {"user"}))
    local session_id = ll.JsonGetValue(msg, {"session_id"})
    local menu_type = ll.JsonGetValue(msg, {"menu_type"})
    local current_page = integer(ll.JsonGetValue(msg, {"page"}))
    local total_pages = integer(ll.JsonGetValue(msg, {"total_pages"}))
    local has_nav = integer(ll.JsonGetValue(msg, {"has_nav"})) ~= 0

    local reordered = reorder_buttons_for_display(ll.Json2List(ll.JsonGetValue(msg, {"buttons"})))

    local nav
    if has_nav then nav = {"<<", ">>", "Close"} else nav = {"Close"} end
    local final_button_data = concat_arrays(nav, reordered)

    local title = "Menu"
    local body_text = "Choose:"
    if menu_type == ROOT_CONTEXT then
        title = "Main Menu"
        body_text = "Select an option:"
    elseif menu_type == SOS_CONTEXT then
        title = "Emergency Menu"
        body_text = "Emergency options:"
    end

    if total_pages > 1 then
        title = title .. " (" .. tostring(current_page + 1) .. "/" .. tostring(total_pages) .. ")"
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", session_id,
        "user", tostring(user),
        "title", title,
        "body", body_text,
        "button_data", ll.List2Json(JSON_ARRAY, final_button_data),
        "timeout", 60,
    }), NULL_KEY)
end

local function show_message(msg: string)
    if not validate_required_fields(msg, {"user", "message"}) then return end
    local user = uuid(ll.JsonGetValue(msg, {"user"}))
    ll.RegionSayTo(user, 0, ll.JsonGetValue(msg, {"message"}))
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
end

function LLEvents.link_message(sender_num: number, num: number, msg: string, id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    local msg_type = get_msg_type(msg)
    if msg_type == "" then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
        return
    end

    if num == UI_BUS then
        if msg_type == "ui.menu.render" then
            render_menu(msg)
        elseif msg_type == "ui.message.show" then
            show_message(msg)
        end
    end
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        ll.ResetScript()
    end
end

-- Top-level init.
main()

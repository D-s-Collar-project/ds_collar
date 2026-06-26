--[[--------------------
MODULE: kmod_menu.lua  (SLua port)
VERSION: 1.2
REVISION: 16  (SLua port rev 1)
PURPOSE: Menu rendering and visual presentation service. Consumes ui.menu.render
         (six modes) on UI_BUS and forwards a built button_data payload to the
         dialog layer on DIALOG_BUS; also relays ui.message.show as owner chat.
ARCHITECTURE: Consolidated message bus lanes.

SLUA PORT NOTES:
- Ported from kmod_menu.lsl v1.2 rev 16. Wire protocol preserved exactly: it
  consumes ui.menu.render (UI_BUS 900) in the six explicit modes
  (menu.fixed / menu.pager / menu.unordered / menu.ordered, dialog.modal,
  dialog.info) plus ui.message.show, and emits ui.dialog.open (DIALOG_BUS 950)
  with the same JSON shape. Plugins and kmod_dialogs interoperate unchanged.
- IDIOMATIC: the stride-2 `pairs` list built during UL/OL item parsing becomes an
  array of { label, context } records; the UL alphabetical sort is table.sort by
  label rather than llListSortStrided.
- GOTCHA: layout_buttons' reading_order holds 0-based llDialog SLOT positions
  (3x4 grid semantics), NOT Lua table indices. They stay 0-based; the single
  placement site converts to the 1-based table index with `slot + 1`. The
  canonical reverse-map law is otherwise byte-for-byte the LSL.
- GOTCHA: page math is integer — floor division (//) for total_pages, and
  csv_lead_int (the shared leading-int parse) stands in for LSL's lenient
  (integer) cast on `page` / `has_nav` (Lua tonumber is strict; an absent field
  parses to 0, matching (integer)"").
- ll.Json2List returns nested objects as JSON strings (LSL-compatible), so each
  item/button element is re-queried with ll.JsonGetValue exactly as the LSL did.
- uuid() normalizes the JSON `user` string back to a key for ll.RegionSayTo
  (show_message); the render forwards keep `user` as a string inside the JSON.
- STATELESS: the LSL had no state_entry (nothing to initialise); this port
  likewise defines NO main() — only the LLEvents handlers.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local UI_BUS           = 900
local DIALOG_BUS       = 950

--[[ -------------------- CONTEXT CONSTANTS -------------------- ]]
-- Must match ROOT_CONTEXT / SOS_CONTEXT in kmod_ui, control_hud, kmod_remote.
local ROOT_CONTEXT = "ui.core.root"
local SOS_CONTEXT  = "ui.sos.root"

-- llDialog is a 3x4 grid — MENU_SLOTS button slots total. Content capacity is
-- MENU_SLOTS minus the reserved low slots (nav + any fixed action buttons), so a
-- standard 3-nav menu holds 9 content buttons — which kmod_ui's MAX_FUNC_BTNS
-- must match (cross-module contract).
local MENU_SLOTS = 12

-- menu.* render shapes — all flow through the one render_paged():
local SHAPE_FIXED = 0  -- [Close . - . Back], single page (never paginates)
local SHAPE_PAGER = 1  -- [<< . >> . exit], paginates
local SHAPE_UL    = 2  -- unordered picker: A-Z sort, name on the button
local SHAPE_OL    = 3  -- ordered picker: number on the button + numbered body

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

--[[ -------------------- BUTTON LAYOUT (canonical reverse-map) -------------------- ]]

-- llDialog fills its 3-wide grid bottom-left -> top-right, so a naive button list
-- reads UPWARD and backwards to a human. This is the project's canonical
-- reverse-layout, shared byte-identically by every menu mode. nav/fixed buttons
-- take the low slots 0..nav_count-1 (physical bottom row, left); content fills the
-- remaining slots walked in VISUAL reading order (top row first, L->R) so the list
-- reads top-to-bottom, L->R. Requires nav_count in 1..3 and nav_count + content
-- <= 12. Every placeholder is replaced — no filler survives in the output.
local function layout_buttons(nav_buttons, content_buttons)
    local nav_count     = #nav_buttons
    local content_count = #content_buttons
    local total         = nav_count + content_count

    -- Slot indices in visual top-to-bottom, L->R reading order. These are 0-based
    -- llDialog SLOT numbers (grid semantics), not Lua indices. Keep only the slots
    -- that fit within `total` and aren't reserved for nav — exactly [nav_count, total).
    local reading_order = {9, 10, 11, 6, 7, 8, 3, 4, 5, 0, 1, 2}
    local slots = {}
    for _, rs in ipairs(reading_order) do
        if rs < total and rs >= nav_count then
            slots[#slots + 1] = rs
        end
    end

    -- nav into the low slots, placeholders for the rest.
    local final_buttons = {}
    for i = 1, nav_count do
        final_buttons[i] = nav_buttons[i]
    end
    for i = nav_count + 1, total do
        final_buttons[i] = " "
    end

    -- Place each content button at its reading-order slot. slot is a 0-based
    -- dialog position, so the 1-based Lua table index is slot + 1.
    for i = 1, content_count do
        final_buttons[slots[i] + 1] = content_buttons[i]
    end
    return final_buttons
end

-- Build a routable nav button. Nav buttons carry a context (nav:prev / nav:next /
-- nav:back / nav:close) exactly like content buttons, so the dialog layer maps the
-- click to a context and consumers route by context, never by the visible label.
local function nav_obj(label: string, ctx: string): string
    return ll.List2Json(JSON_OBJECT, {"label", label, "context", ctx})
end

--[[ -------------------- UNIFIED NAVIGABLE RENDERER (menu.*) -------------------- ]]
-- The four menu.* shapes share ONE process: reserve the bottom slots (nav +
-- optional fixed action buttons), lay content above them via layout_buttons, page
-- if the shape paginates, forward to DIALOG_BUS. Only two things vary by shape: the
-- NAV ROW and how the CONTENT BUTTONS are produced from the input.
local function render_paged(msg: string, shape: number)
    if not validate_required_fields(msg, {"user", "session_id"}) then return end

    local user = ll.JsonGetValue(msg, {"user"})
    local session_id = ll.JsonGetValue(msg, {"session_id"})
    local current_page = csv_lead_int(ll.JsonGetValue(msg, {"page"}))

    local category = ""
    local cat_tmp = ll.JsonGetValue(msg, {"category"})
    if cat_tmp ~= JSON_INVALID then category = cat_tmp end

    -- nav row (per-shape difference #1)
    local nav
    if shape == SHAPE_FIXED then
        -- Two-sided: Close (leave the menu system) + inert spacer + Back (up one
        -- level). A fixed menu frees the << >> slots, which pays for showing both.
        nav = {nav_obj("Close", "nav:close"), nav_obj("-", ""), nav_obj("Back", "nav:back")}
    elseif shape == SHAPE_PAGER then
        -- Exit is Close at the root tier (ends the session) and Back inside a
        -- category (pops to root). has_nav=0 -> a lone exit (no << >>).
        local exit_obj = nav_obj("Close", "nav:close")
        if category ~= "" then exit_obj = nav_obj("Back", "nav:back") end
        nav = {exit_obj}
        if csv_lead_int(ll.JsonGetValue(msg, {"has_nav"})) ~= 0 then
            nav = {nav_obj("<<", "nav:prev"), nav_obj(">>", "nav:next"), exit_obj}
        end
    else
        nav = {nav_obj("<<", "nav:prev"), nav_obj(">>", "nav:next"), nav_obj("Back", "nav:back")}
    end

    -- optional fixed action buttons (any shape; e.g. leash length's +/-1m)
    local fixed = {}
    local fixed_json = ll.JsonGetValue(msg, {"fixed"})
    if fixed_json ~= JSON_INVALID then fixed = ll.Json2List(fixed_json) end

    -- reserved = nav ++ fixed
    local reserved = {}
    for _, b in ipairs(nav) do reserved[#reserved + 1] = b end
    for _, b in ipairs(fixed) do reserved[#reserved + 1] = b end

    local page_size = MENU_SLOTS - #reserved
    if page_size < 1 then page_size = 1 end

    -- content source + count. Button shapes (fixed/pager) take a pre-built
    -- `buttons` array; list shapes (UL/OL) take raw `items` -> {label,context} recs.
    local is_list = (shape == SHAPE_UL or shape == SHAPE_OL)
    local full_buttons = {}
    local pairs_list: {{ label: string, context: string }} = {}
    local item_count = 0
    if is_list then
        local raw = ll.Json2List(ll.JsonGetValue(msg, {"items"}))
        for _, it in ipairs(raw) do
            local lbl = ll.JsonGetValue(it, {"label"})
            local ctx
            if lbl == JSON_INVALID then
                lbl = it            -- flat string: label IS the value
                ctx = it
            else
                ctx = ll.JsonGetValue(it, {"context"})
                if ctx == JSON_INVALID then ctx = lbl end
            end
            pairs_list[#pairs_list + 1] = { label = lbl, context = ctx }
        end
        -- UL sorts A-Z by label; OL preserves the caller's order.
        if shape == SHAPE_UL and #pairs_list > 1 then
            table.sort(pairs_list, function(a, b) return a.label < b.label end)
        end
        item_count = #pairs_list
    else
        local buttons_json = ll.JsonGetValue(msg, {"buttons"})
        if buttons_json ~= JSON_INVALID then full_buttons = ll.Json2List(buttons_json) end
        item_count = #full_buttons
    end

    -- page math (fixed never paginates: one page, no slice, no counter)
    local total_pages = 1
    local pstart = 0
    local pend = item_count
    if shape ~= SHAPE_FIXED then
        total_pages = (item_count + page_size - 1) // page_size
        if total_pages < 1 then total_pages = 1 end
        if current_page >= total_pages then current_page = 0 end
        if current_page < 0 then current_page = total_pages - 1 end
        pstart = current_page * page_size
        pend = pstart + page_size
        if pend > item_count then pend = item_count end
    end

    -- body (default up front; OL appends numbered lines below)
    local body_text = ll.JsonGetValue(msg, {"body"})
    if body_text == JSON_INVALID then
        if shape == SHAPE_PAGER and ll.JsonGetValue(msg, {"menu_type"}) == SOS_CONTEXT then
            body_text = "Emergency options:"
        else
            body_text = "Select an option:"
        end
    end

    -- build the page's content buttons (pstart/pend are 0-based; +1 for Lua)
    local content = {}
    if is_list then
        for i = pstart, pend - 1 do
            local rec = pairs_list[i + 1]
            if shape == SHAPE_OL then
                local num = tostring(i - pstart + 1)
                content[#content + 1] = ll.List2Json(JSON_OBJECT, {"label", num, "context", "pick:" .. tostring(i)})
                body_text = body_text .. "\n" .. num .. ". " .. rec.label
            else
                content[#content + 1] = ll.List2Json(JSON_OBJECT, {"label", rec.label, "context", rec.context})
            end
        end
    elseif item_count > 0 then
        for i = pstart, pend - 1 do
            content[#content + 1] = full_buttons[i + 1]
        end
    end

    local final_button_data = layout_buttons(reserved, content)

    -- title (pager derives from category/menu_type; + page counter)
    local title = ll.JsonGetValue(msg, {"title"})
    if title == JSON_INVALID then
        if shape == SHAPE_PAGER and category ~= "" then
            title = category
        elseif shape == SHAPE_PAGER then
            local menu_type = ll.JsonGetValue(msg, {"menu_type"})
            if menu_type == ROOT_CONTEXT then title = "Main Menu"
            elseif menu_type == SOS_CONTEXT then title = "Emergency Menu"
            else title = "Menu" end
        else
            title = "Menu"
        end
    end
    if total_pages > 1 then
        title = title .. " (" .. tostring(current_page + 1) .. "/" .. tostring(total_pages) .. ")"
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", session_id,
        "user", user,
        "title", title,
        "body", body_text,
        "button_data", ll.List2Json(JSON_ARRAY, final_button_data),
        "timeout", 60,
    }), NULL_KEY)
end

--[[ -------------------- TERMINAL DIALOGS (dialog.*) -------------------- ]]

-- dialog.modal: a forced Yes/No confirmation (terminal — NOT a navigable menu).
-- Bottom row [No . - . Yes]: No/cancel first (reflexive-safe) + an inert spacer so
-- No and Yes are never adjacent (fat-finger guard). Labels default to Yes/No; the
-- click always returns context "confirm" (Yes) or "cancel" (No).
local function render_modal(msg: string)
    if not validate_required_fields(msg, {"user", "session_id"}) then return end

    local user = ll.JsonGetValue(msg, {"user"})
    local session_id = ll.JsonGetValue(msg, {"session_id"})

    local confirm_label = ll.JsonGetValue(msg, {"confirm_label"})
    if confirm_label == JSON_INVALID then confirm_label = "Yes" end
    local cancel_label = ll.JsonGetValue(msg, {"cancel_label"})
    if cancel_label == JSON_INVALID then cancel_label = "No" end

    local button_data = {
        ll.List2Json(JSON_OBJECT, {"label", cancel_label,  "context", "cancel"}),
        ll.List2Json(JSON_OBJECT, {"label", "-",           "context", ""}),
        ll.List2Json(JSON_OBJECT, {"label", confirm_label, "context", "confirm"}),
    }

    local title = ll.JsonGetValue(msg, {"title"})
    if title == JSON_INVALID then title = "Confirm" end
    local body_text = ll.JsonGetValue(msg, {"body"})
    if body_text == JSON_INVALID then body_text = "Are you sure?" end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", session_id,
        "user", user,
        "title", title,
        "body", body_text,
        "button_data", ll.List2Json(JSON_ARRAY, button_data),
        "timeout", 60,
    }), NULL_KEY)
end

-- dialog.info: a terminal informational dialog — title + body + a single OK that
-- dismisses. NO nav row (it isn't a navigable menu). The click returns context "ok".
local function render_info(msg: string)
    if not validate_required_fields(msg, {"user", "session_id"}) then return end

    local user = ll.JsonGetValue(msg, {"user"})
    local session_id = ll.JsonGetValue(msg, {"session_id"})

    local ok_label = ll.JsonGetValue(msg, {"ok_label"})
    if ok_label == JSON_INVALID then ok_label = "OK" end
    local title = ll.JsonGetValue(msg, {"title"})
    if title == JSON_INVALID then title = "Info" end
    local body_text = ll.JsonGetValue(msg, {"body"})
    if body_text == JSON_INVALID then body_text = "" end

    local button_data = {ll.List2Json(JSON_OBJECT, {"label", ok_label, "context", "ok"})}

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", session_id,
        "user", user,
        "title", title,
        "body", body_text,
        "button_data", ll.List2Json(JSON_ARRAY, button_data),
        "timeout", 60,
    }), NULL_KEY)
end

local function show_message(msg: string)
    if not validate_required_fields(msg, {"user", "message"}) then return end

    local user = ll.JsonGetValue(msg, {"user"})
    local message_text = ll.JsonGetValue(msg, {"message"})

    ll.RegionSayTo(uuid(user), 0, message_text)
end

--[[ -------------------- EVENTS -------------------- ]]
-- Stateless renderer — no init, so NO main(); these handlers are the whole script.

function LLEvents.link_message(sender_num: number, num: number, msg: string, id)
    local msg_type = get_msg_type(msg)
    if msg_type == "" then return end

    if num == KERNEL_LIFECYCLE then
        -- Owner-change wipe / external soft reset from collar_kernel.
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
        return
    end

    if num == UI_BUS then
        if msg_type == "ui.menu.render" then
            -- Two families: navigable menus (menu.*) all flow through render_paged;
            -- terminal dialogs (dialog.*) are their own small renderers. A missing or
            -- unknown mode defaults to the safe paginating pager.
            local mode = ll.JsonGetValue(msg, {"mode"})
            if      mode == "menu.fixed"     then render_paged(msg, SHAPE_FIXED)
            elseif  mode == "menu.unordered" then render_paged(msg, SHAPE_UL)
            elseif  mode == "menu.ordered"   then render_paged(msg, SHAPE_OL)
            elseif  mode == "dialog.modal"   then render_modal(msg)
            elseif  mode == "dialog.info"    then render_info(msg)
            else                                  render_paged(msg, SHAPE_PAGER)
            end
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

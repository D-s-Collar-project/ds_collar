--[[--------------------
PLUGIN: plugin_leash_object.lua  (SLua port)
VERSION: 1.10
REVISION: 3  (SLua port rev 1)
PURPOSE: Sub-plugin for object-target leash flows (Post mode). Sensor scan for
         in-world objects, paginated picker, dispatches the post action.
ARCHITECTURE: Hidden helper of plugin_leash (no plugin.reg.*). Receives
              ui.menu.start (context "ui.core.leash.object" + subpath "post").

SLUA PORT NOTES:
- Ported from plugin_leash_object.lsl rev 3. UI_BUS / DIALOG_BUS JSON wire and
  the button_data layout are unchanged.
- Idiomatic SLua: sensor candidates are {name,key} records (sorted with
  table.sort); btn() still emits JSON for the wire; the slot-mapping layout
  helper is preserved.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT        = "ui.core.leash.object"
local PARENT_PLUGIN_CONTEXT = "ui.core.leash"

--[[ -------------------- STATE -------------------- ]]
local CurrentUser = NULL_KEY
local UserAcl = -999
local SessionId = ""
local MenuContext = ""
local SensorCandidates = {}  -- array of { name, key }
local SensorPage = 0

--[[ -------------------- HELPERS -------------------- ]]

--[[ integer(): SLua has no LSL-style (integer) cast; emulate it (truncate toward zero; non-numeric -> 0). ]]
local function integer(v): number
    local n = tonumber(v)
    if n == nil then return 0 end
    if n < 0 then return math.ceil(n) end
    return math.floor(n)
end

local function generate_session_id(): string
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
end

local function starts_with(s: string, prefix: string): boolean
    return string.sub(s, 1, #prefix) == prefix
end

local function btn(label: string, cmd: string): string
    return ll.List2Json(JSON_OBJECT, {"label", label, "context", cmd})
end

-- Canonical dialog button layout: nav in cells 0-2, items slot-mapped
-- alphabetical top-to-bottom (see plugin_animate convention).
local function reorder_item_buttons(nav_buttons, item_buttons)
    local item_count = #item_buttons
    local total = 3 + item_count

    local slots = {}
    local function add(s) slots[#slots + 1] = s end
    if total > 9  then add(9)  end
    if total > 10 then add(10) end
    if total > 11 then add(11) end
    if total > 6  then add(6)  end
    if total > 7  then add(7)  end
    if total > 8  then add(8)  end
    if total > 3  then add(3)  end
    if total > 4  then add(4)  end
    if total > 5  then add(5)  end

    local final = {}
    for _, b in ipairs(nav_buttons) do final[#final + 1] = b end
    for _ = 1, item_count do final[#final + 1] = " " end
    for i = 1, item_count do
        final[slots[i] + 1] = item_buttons[i]  -- slot values are 0-based
    end
    return final
end

--[[ -------------------- OBJECT PICKER -------------------- ]]

local function displayObjectMenu()
    if #SensorCandidates == 0 then return end

    local total_items = #SensorCandidates
    local total_pages = (total_items + 8) // 9
    local start_index = SensorPage * 9       -- 0-based
    local end_index = start_index + 9
    if end_index > total_items then end_index = total_items end

    local body = ""
    local display_num = 1
    for i = start_index, end_index - 1 do
        body = body .. tostring(display_num) .. ". " .. SensorCandidates[i + 1].name .. "\n"
        display_num += 1
    end

    local nav_buttons = {btn("<<", "prev"), btn(">>", "next"), btn("Back", "back")}
    local item_buttons = {}
    for i = 1, (end_index - start_index) do
        item_buttons[#item_buttons + 1] = btn(tostring(i), "sel:" .. tostring(i))
    end
    local button_data = reorder_item_buttons(nav_buttons, item_buttons)

    if total_pages > 1 then
        body = body .. "\nPage " .. tostring(SensorPage + 1) .. "/" .. tostring(total_pages)
    end

    SessionId = generate_session_id()
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", "Post",
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, button_data),
        "timeout", 60,
    }), NULL_KEY)
end

local function startSensorScan()
    SensorPage = 0
    SensorCandidates = {}
    -- Stationary objects only (ACTIVE omitted — that returns avatars).
    ll.Sensor("", NULL_KEY, bit32.bor(PASSIVE, SCRIPTED), 96.0, PI)
end

--[[ -------------------- ACTION DISPATCH -------------------- ]]

local function sendActionWithTarget(action: string, target)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.action",
        "action", action,
        "target", tostring(target),
    }), CurrentUser)
end

--[[ -------------------- NAVIGATION -------------------- ]]

local function cleanupSession()
    if SessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.close",
            "session_id", SessionId,
        }), NULL_KEY)
    end
    CurrentUser = NULL_KEY
    UserAcl = -999
    SessionId = ""
    MenuContext = ""
    SensorCandidates = {}
    SensorPage = 0
end

-- Back button only — explicit back-navigation to plugin_leash's main menu.
local function returnToParent()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.start",
        "context", PARENT_PLUGIN_CONTEXT,
        "acl", UserAcl,
    }), CurrentUser)
    cleanupSession()
end

--[[ -------------------- DISPATCH -------------------- ]]

local function handleSubpath(subpath: string)
    if subpath == "post" then
        MenuContext = "post"
        startSensorScan()
    else
        cleanupSession()
    end
end

local function handlePickerClick(ctx: string)
    if ctx == "back" then
        returnToParent()
        return
    end

    local total_items = #SensorCandidates
    local total_pages = (total_items + 8) // 9
    if total_pages < 1 then total_pages = 1 end

    if ctx == "prev" then
        if SensorPage == 0 then SensorPage = total_pages - 1 else SensorPage -= 1 end
        displayObjectMenu()
        return
    end
    if ctx == "next" then
        if SensorPage >= total_pages - 1 then SensorPage = 0 else SensorPage += 1 end
        displayObjectMenu()
        return
    end
    if starts_with(ctx, "sel:") then
        local button_num = integer(string.sub(ctx, 5))
        if button_num >= 1 and button_num <= 9 then
            local actual_index = (SensorPage * 9) + (button_num - 1)  -- 0-based
            local record = SensorCandidates[actual_index + 1]
            if record ~= nil then
                sendActionWithTarget(MenuContext, record.key)
                cleanupSession()
                return
            end
        end
        ll.RegionSayTo(CurrentUser, 0, "Invalid selection.")
        cleanupSession()
    end
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
    cleanupSession()
    -- No plugin.reg.* — hidden from kmod_ui's top menu.
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
        return
    end

    if num == UI_BUS then
        if msg_type == "ui.menu.start" then
            if ll.JsonGetValue(msg, {"context"}) ~= PLUGIN_CONTEXT then return end
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end

            CurrentUser = id
            UserAcl = integer(ll.JsonGetValue(msg, {"acl"}))
            local sp = ll.JsonGetValue(msg, {"subpath"})
            if sp == JSON_INVALID then sp = "" end
            handleSubpath(sp)
        end
        return
    end

    if num == DIALOG_BUS then
        if msg_type == "ui.dialog.response" then
            local resp_session = ll.JsonGetValue(msg, {"session_id"})
            if resp_session == JSON_INVALID or resp_session ~= SessionId then return end
            local ctx = ll.JsonGetValue(msg, {"context"})
            if ctx == JSON_INVALID then ctx = "" end
            handlePickerClick(ctx)
        elseif msg_type == "ui.dialog.timeout" then
            local to_session = ll.JsonGetValue(msg, {"session_id"})
            if to_session ~= JSON_INVALID and to_session == SessionId then cleanupSession() end
        end
    end
end

function LLEvents.sensor(detected)
    if MenuContext ~= "post" then return end
    if CurrentUser == NULL_KEY then return end

    local wearer = ll.GetOwner()
    local my_key = ll.GetKey()
    local buf = {}
    for _, d in ipairs(detected) do
        local det = d:getKey()
        if det ~= my_key and det ~= wearer then
            buf[#buf + 1] = { name = d:getName(), key = det }
        end
    end
    SensorCandidates = buf

    table.sort(SensorCandidates, function(a, b) return a.name < b.name end)

    if #SensorCandidates == 0 then
        ll.RegionSayTo(CurrentUser, 0, "No nearby objects found to post to.")
        cleanupSession()
        return
    end
    displayObjectMenu()
end

function LLEvents.no_sensor()
    if MenuContext ~= "post" then return end
    if CurrentUser == NULL_KEY then return end
    ll.RegionSayTo(CurrentUser, 0, "No nearby objects found to post to.")
    cleanupSession()
end

-- Top-level init.
main()

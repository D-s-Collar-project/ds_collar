--[[--------------------
PLUGIN: plugin_animate.lua  (SLua port)
VERSION: 1.10
PURPOSE: Play/stop avatar animations from inventory, paginated menu
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility

SLUA PORT NOTES:
- Ported from plugin_animate.lsl. UI_BUS/DIALOG_BUS JSON wire and the slot-mapped
  button layout unchanged. Animations read live from inventory.
- SLua conventions: event handlers are LLEvents.* fields; init is local main();
  HasPermission is a boolean; bit32.band for permission masks.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.animate"
local PLUGIN_LABEL = "Animate"

--[[ -------------------- CONSTANTS -------------------- ]]
local MAX_ANIMATIONS = 128
local PAGE_SIZE = 8

--[[ -------------------- STATE -------------------- ]]
local CurrentUser = NULL_KEY
local SessionId = ""
local CurrentPage = 0
local LastAnimCount = -1
local LastPlayedAnim = ""
local HasPermission = false
-- Policy-button cache, loaded on menu entry. Animate registers an identical
-- "<<,>>,Stop" policy for every ACL, so filtering is a no-op by construction
-- today; this scaffold mirrors the other plugins and stages per-button
-- filtering should the registered policy ever diverge by ACL. Read by btn_allowed.
local gPolicyButtons = {}

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

-- Number of animations the plugin exposes (capped).
local function get_animation_count(): number
    local count = ll.GetInventoryNumber(INVENTORY_ANIMATION)
    if count > MAX_ANIMATIONS then return MAX_ANIMATIONS end
    return count
end

--[[ -------------------- ANIMATION CONTROL -------------------- ]]

local function ensure_permissions()
    if bit32.band(ll.GetPermissions(), PERMISSION_TRIGGER_ANIMATION) ~= 0 then
        HasPermission = true
    else
        ll.RequestPermissions(ll.GetOwner(), PERMISSION_TRIGGER_ANIMATION)
    end
end

local function start_animation(anim_name: string)
    if not HasPermission then
        ll.RegionSayTo(CurrentUser, 0, "No animation permission granted.")
        return
    end
    if LastPlayedAnim ~= "" then ll.StopAnimation(LastPlayedAnim) end
    if ll.GetInventoryType(anim_name) == INVENTORY_ANIMATION then
        ll.StartAnimation(anim_name)
        LastPlayedAnim = anim_name
        ll.RegionSayTo(CurrentUser, 0, "Playing: " .. anim_name)
    else
        ll.RegionSayTo(CurrentUser, 0, "Animation not found: " .. anim_name)
    end
end

local function stop_all_animations()
    if LastPlayedAnim ~= "" then
        ll.StopAnimation(LastPlayedAnim)
        LastPlayedAnim = ""
        ll.RegionSayTo(CurrentUser, 0, "Animation stopped.")
    else
        ll.RegionSayTo(CurrentUser, 0, "No animation playing.")
    end
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
        "1", "<<,>>,Stop",
        "2", "<<,>>,Stop",
        "3", "<<,>>,Stop",
        "4", "<<,>>,Stop",
        "5", "<<,>>,Stop",
    }))
    write_plugin_reg(PLUGIN_LABEL)

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", ll.GetScriptName(),
    }), NULL_KEY)

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "chat.alias.declare", "alias", "pose", "context", PLUGIN_CONTEXT .. ".pose",
    }), NULL_KEY)
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "chat.alias.declare", "alias", "stand", "context", PLUGIN_CONTEXT .. ".stand",
    }), NULL_KEY)
end

local function send_pong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

--[[ -------------------- UI / MENU -------------------- ]]

local function show_animation_menu(page: number)
    SessionId = generate_session_id()
    CurrentPage = page

    local total_anims = get_animation_count()

    if total_anims == 0 then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.open",
            "session_id", SessionId,
            "user", tostring(CurrentUser),
            "title", PLUGIN_LABEL,
            "message", "No animations found in inventory.",
            "buttons", ll.List2Json(JSON_ARRAY, {"Back"}),
            "timeout", 60,
        }), NULL_KEY)
        return
    end

    local max_page = (total_anims - 1) // PAGE_SIZE
    if page < 0 then page = 0 end
    if page > max_page then page = max_page end
    CurrentPage = page

    local start_idx = page * PAGE_SIZE  -- 0-based
    local end_idx = start_idx + PAGE_SIZE - 1
    if end_idx >= total_anims then end_idx = total_anims - 1 end

    -- Page animations (0-based inventory indices).
    local page_anims = {}
    for i = start_idx, end_idx do
        page_anims[#page_anims + 1] = ll.GetInventoryName(INVENTORY_ANIMATION, i + 1)  -- SLua inventory is 1-based; i stays 0-based for paging math
    end

    local count = #page_anims
    local total_buttons = 4 + count

    -- Fixed layout: 0-2 nav (<<,>>,Back), 3 [Stop], 4+ animations top-to-bottom.
    local final_buttons = {"<<", ">>", "Back", "[Stop]"}
    for _ = 1, count do final_buttons[#final_buttons + 1] = "" end

    local target_slots = {}
    local function add(s) target_slots[#target_slots + 1] = s end
    if total_buttons > 9 then add(9) end
    if total_buttons > 10 then add(10) end
    if total_buttons > 11 then add(11) end
    if total_buttons > 6 then add(6) end
    if total_buttons > 7 then add(7) end
    if total_buttons > 8 then add(8) end
    if total_buttons > 4 then add(4) end
    if total_buttons > 5 then add(5) end

    for i = 1, count do
        final_buttons[target_slots[i] + 1] = page_anims[i]  -- slot is 0-based
    end

    local message = "Select an animation to play.\nPage " .. tostring(page + 1) .. " of " .. tostring(max_page + 1)
    if LastPlayedAnim ~= "" then message = message .. "\nPlaying: " .. LastPlayedAnim end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", PLUGIN_LABEL,
        "message", message,
        "buttons", ll.List2Json(JSON_ARRAY, final_buttons),
        "timeout", 60,
    }), NULL_KEY)
end

--[[ -------------------- CHAT SUBCOMMANDS -------------------- ]]

local function handle_subpath(subpath: string)
    local tokens = ll.ParseString2List(subpath, {"."}, {})
    if #tokens == 0 then return end
    local action = tokens[1]

    if action == "stand" then
        stop_all_animations()
        return
    end
    if action == "pose" then
        if #tokens < 2 then
            ll.RegionSayTo(CurrentUser, 0, "Usage: pose <animation name>")
            return
        end
        local tail = {}
        for i = 2, #tokens do tail[#tail + 1] = tokens[i] end
        local anim = ll.DumpList2String(tail, ".")
        if anim == "stop" then stop_all_animations() else start_animation(anim) end
        return
    end
    ll.RegionSayTo(CurrentUser, 0, "Unknown animate subcommand: " .. action)
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
    SessionId = ""
    CurrentPage = 0
    gPolicyButtons = {}
end

local function ui_return_root()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return",
        "user", tostring(CurrentUser),
    }), NULL_KEY)
end

--[[ -------------------- BUTTON HANDLING -------------------- ]]

local function handle_button_click(button: string)
    if button == "Back" then
        ui_return_root()
        cleanup_session()
        return
    end
    if button == "[Stop]" then
        stop_all_animations()
        show_animation_menu(CurrentPage)
        return
    end
    if button == "<<" then
        local max_page = (get_animation_count() - 1) // PAGE_SIZE
        if CurrentPage == 0 then show_animation_menu(max_page)
        else show_animation_menu(CurrentPage - 1) end
        return
    end
    if button == ">>" then
        local max_page = (get_animation_count() - 1) // PAGE_SIZE
        if CurrentPage >= max_page then show_animation_menu(0)
        else show_animation_menu(CurrentPage + 1) end
        return
    end
    if ll.GetInventoryType(button) == INVENTORY_ANIMATION then
        start_animation(button)
        show_animation_menu(CurrentPage)
        return
    end
    show_animation_menu(CurrentPage)
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end

    local raw_count = ll.GetInventoryNumber(INVENTORY_ANIMATION)
    if raw_count > MAX_ANIMATIONS then
        ll.RegionSayTo(ll.GetOwner(), 0, "WARNING: Too many animations (" .. tostring(raw_count)
            .. "). Only the first " .. tostring(MAX_ANIMATIONS) .. " are reachable.")
    end
    LastAnimCount = raw_count

    cleanup_session()
    ensure_permissions()
    register_self()
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
    if bit32.band(change, CHANGED_INVENTORY) ~= 0 then
        if ll.GetInventoryNumber(INVENTORY_ANIMATION) ~= LastAnimCount then ll.ResetScript() end
    end
end

function LLEvents.run_time_permissions(perm: number)
    if bit32.band(perm, PERMISSION_TRIGGER_ANIMATION) ~= 0 then HasPermission = true end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
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

            CurrentUser = id
            local subpath = ""
            local sp = ll.JsonGetValue(msg, {"subpath"})
            if sp ~= JSON_INVALID then subpath = sp end

            if subpath ~= "" then
                handle_subpath(subpath)
            else
                gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, integer(ll.JsonGetValue(msg, {"acl"})))
                CurrentPage = 0
                show_animation_menu(0)
            end
        end
        return
    end

    if num == DIALOG_BUS then
        local msg_type = ll.JsonGetValue(msg, {"type"})
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

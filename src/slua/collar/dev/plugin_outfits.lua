--[[--------------------
PLUGIN: plugin_outfits.lua  (SLua port)
VERSION: 1.10
PURPOSE: Outfit manager — Add/Wear/Remove/Lock/Unlock folders under #RLV/outfits,
         with persistent per-outfit locks and an active on/off toggle.
ARCHITECTURE: Consolidated message bus lanes; RLV via kmod_rlv (rlv.force +
              rlv.apply/release claims under consumer "outfits"); replies on RLV_CHAN.

SLUA PORT NOTES:
- Ported from plugin_outfits.lsl. RLV @getinv scan, the detachallthis lock
  claims, settings.delta CSV writes, and the .base/.outfits convention unchanged.
- SLua conventions: LLEvents.* handlers, local main(); Outfits / LockedOutfits
  are string arrays; OutfitsActive / LastActive stay numeric (0/1/-1 sentinel).
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS     = 800
local UI_BUS           = 900
local DIALOG_BUS       = 950

--[[ -------------------- IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.outfits"
local PLUGIN_LABEL   = "Outfits"

local RLV_CHAN     = 1888772
local RLV_TIMEOUT  = 10.0
local OUTFITS_ROOT = "outfits"
local BASE_FOLDER  = "outfits/.base"
local RLV_CONSUMER = "outfits"

local KEY_LOCKED = "outfits.locked"
local KEY_ACTIVE = "plugin.outfit.active"

local SETUP_NOTECARD = "D/s Collar outfits setup"

--[[ -------------------- STATE -------------------- ]]
local CurrentUser    = NULL_KEY
local gPolicyButtons = {}
local SessionId      = ""

local MenuContext    = ""   -- "scanning" | "pick" | "action" | "disabled" | "empty"
local SelectedOutfit = ""

local Outfits     = {}      -- array of outfit names
local PickPage    = 0
local LastMaxPage = 0

local OutfitsActive = 0     -- default OFF
local LastActive    = -1    -- forces first sync to emit

local LockedOutfits   = {}  -- array of outfit names
local RlvListenHandle = 0

--[[ -------------------- HELPERS -------------------- ]]

local function list_find(t, v)
    for i, x in ipairs(t) do
        if x == v then return i end
    end
    return nil
end

local function starts_with(s: string, prefix: string): boolean
    return string.sub(s, 1, #prefix) == prefix
end

local function json_has(j: string, path): boolean
    return ll.JsonGetValue(j, path) ~= JSON_INVALID
end

local function sid(): string
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
end

local function btn(label: string, ctx: string): string
    return ll.List2Json(JSON_OBJECT, {"label", label, "context", ctx})
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
        "1", "Add,Wear,Remove",
        "2", "Add,Wear,Remove,Disable",
        "3", "Add,Wear,Remove,Lock,Unlock,Disable",
        "4", "Add,Wear,Remove,Lock,Unlock,Disable",
        "5", "Add,Wear,Remove,Lock,Unlock,Disable",
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

local function stop_rlv_listen()
    if RlvListenHandle ~= 0 then
        ll.ListenRemove(RlvListenHandle)
        RlvListenHandle = 0
    end
    ll.SetTimerEvent(0.0)
end

local function cleanup_session()
    stop_rlv_listen()
    if SessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.close", "session_id", SessionId,
        }), NULL_KEY)
    end
    SessionId = ""
    CurrentUser = NULL_KEY
    gPolicyButtons = {}
    MenuContext = ""
    SelectedOutfit = ""
    Outfits = {}
    PickPage = 0
    LastMaxPage = 0
end

local function return_to_root()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return", "context", PLUGIN_CONTEXT, "user", tostring(CurrentUser),
    }), NULL_KEY)
    cleanup_session()
end

--[[ -------------------- SETTINGS / RLV CLAIMS -------------------- ]]

local function persist_locked()
    if #LockedOutfits == 0 then
        ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delete:" .. KEY_LOCKED, NULL_KEY)
        return
    end
    ll.MessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" .. KEY_LOCKED .. ":" .. ll.DumpList2String(LockedOutfits, ","), NULL_KEY)
end

local function rlv_op(op: string, behav: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", op, "consumer", RLV_CONSUMER, "behav", behav,
    }), NULL_KEY)
end

-- Diff persisted CSV against LockedOutfits; release dropped, re-apply current.
local function apply_settings_sync()
    local csv = ll.LinksetDataRead(KEY_LOCKED)
    local new_locked = {}
    if csv ~= "" then new_locked = ll.ParseString2List(csv, {","}, {}) end

    for _, old_name in ipairs(LockedOutfits) do
        if list_find(new_locked, old_name) == nil then
            rlv_op("rlv.release", "detachallthis:" .. OUTFITS_ROOT .. "/" .. old_name)
        end
    end

    LockedOutfits = new_locked

    for _, name in ipairs(LockedOutfits) do
        rlv_op("rlv.apply", "detachallthis:" .. OUTFITS_ROOT .. "/" .. name)
    end

    local active_str = ll.LinksetDataRead(KEY_ACTIVE)
    local new_active = 0
    if active_str ~= "" then new_active = integer(active_str) end
    OutfitsActive = new_active
    if new_active ~= LastActive then
        local op = "rlv.release"
        if new_active ~= 0 then op = "rlv.apply" end
        rlv_op(op, "detachallthis:" .. BASE_FOLDER)
        LastActive = new_active
    end
end

local function toggle_active(new_state: number)
    OutfitsActive = new_state
    LastActive = new_state
    local op = "rlv.release"
    if new_state ~= 0 then op = "rlv.apply" end
    rlv_op(op, "detachallthis:" .. BASE_FOLDER)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" .. KEY_ACTIVE .. ":" .. tostring(new_state), NULL_KEY)
end

-- Direct @=y before reset — kmod_rlv may reset in parallel and drop Claims.
local function release_persisted_locks()
    local csv = ll.LinksetDataRead(KEY_LOCKED)
    if csv ~= "" then
        for _, name in ipairs(ll.ParseString2List(csv, {","}, {})) do
            if name ~= "" then ll.OwnerSay("@detachallthis:" .. OUTFITS_ROOT .. "/" .. name .. "=y") end
        end
    end
    local active_str = ll.LinksetDataRead(KEY_ACTIVE)
    local was_active = 1
    if active_str ~= "" then was_active = integer(active_str) end
    if was_active ~= 0 then ll.OwnerSay("@detachallthis:" .. BASE_FOLDER .. "=y") end
end

--[[ -------------------- RLV / SCAN -------------------- ]]

local function rlv_force(command: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "rlv.force", "command", command,
    }), NULL_KEY)
end

local function scan_outfits()
    Outfits = {}
    MenuContext = "scanning"
    stop_rlv_listen()
    RlvListenHandle = ll.Listen(RLV_CHAN, "", ll.GetOwner(), "")
    ll.SetTimerEvent(RLV_TIMEOUT)
    rlv_force("@getinv:" .. OUTFITS_ROOT .. "=" .. tostring(RLV_CHAN))
    ll.RegionSayTo(CurrentUser, 0, "Reading #RLV/" .. OUTFITS_ROOT .. " ...")
end

--[[ -------------------- UI -------------------- ]]

local function show_picker(page: number)
    SessionId = sid()
    MenuContext = "pick"

    local action_buttons = {btn("Help", "help")}
    if btn_allowed("Disable") then action_buttons[#action_buttons + 1] = btn("Disable", "disable") end
    local action_count = #action_buttons

    local page_size = 9 - action_count
    local total = #Outfits

    local max_page = 0
    if total > 0 then max_page = (total - 1) // page_size end
    if page < 0 then page = 0 end
    if page > max_page then page = max_page end
    PickPage = page
    LastMaxPage = max_page

    local start_idx = page * page_size  -- 0-based
    local end_idx = start_idx + page_size
    if end_idx > total then end_idx = total end
    local count = end_idx - start_idx

    local body = "Outfits  (#RLV/" .. OUTFITS_ROOT .. ")\n"
    if total == 0 then
        body = body .. "\nNo outfits found.\nCreate subfolders under #RLV/" .. OUTFITS_ROOT .. "."
    else
        body = body .. "*=locked\nPage " .. tostring(page + 1) .. " of " .. tostring(max_page + 1) .. "\n\n"
        for k = 0, count - 1 do
            local outfit_name = Outfits[start_idx + k + 1]
            local mark = ""
            if list_find(LockedOutfits, outfit_name) ~= nil then mark = " *" end
            body = body .. tostring(k + 1) .. ". " .. outfit_name .. mark .. "\n"
        end
    end

    -- Layout: 0-2 nav, 3..(2+action_count) actions, remaining content.
    local button_data = {btn("<<", "prev"), btn(">>", "next"), btn("Back", "back")}
    for _, b in ipairs(action_buttons) do button_data[#button_data + 1] = b end
    for _ = 1, count do button_data[#button_data + 1] = btn(" ", " ") end

    local first_content_slot = 3 + action_count
    local total_buttons = first_content_slot + count

    local target_slots = {}
    local function add(s) target_slots[#target_slots + 1] = s end
    if total_buttons > 9 then add(9) end
    if total_buttons > 10 then add(10) end
    if total_buttons > 11 then add(11) end
    if total_buttons > 6 then add(6) end
    if total_buttons > 7 then add(7) end
    if total_buttons > 8 then add(8) end
    if first_content_slot <= 3 and total_buttons > 3 then add(3) end
    if first_content_slot <= 4 and total_buttons > 4 then add(4) end
    if first_content_slot <= 5 and total_buttons > 5 then add(5) end

    for ci = 0, count - 1 do
        button_data[target_slots[ci + 1] + 1] = btn(tostring(ci + 1), "pick:" .. tostring(start_idx + ci))
    end

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

local function show_disabled_menu()
    SessionId = sid()
    MenuContext = "disabled"

    local body = "Outfits is currently DISABLED.\n"
        .. "outfits/.base is unlocked — the wearer can change\n"
        .. "appearance freely. Re-enable to restore protection and resume outfit browsing."

    local button_data = {}
    if btn_allowed("Disable") then button_data[#button_data + 1] = btn("Enable", "enable") end
    button_data[#button_data + 1] = btn("Help", "help")
    button_data[#button_data + 1] = btn("Back", "back")

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

local function show_empty_menu()
    SessionId = sid()
    MenuContext = "empty"

    local body = "No outfits found in #RLV/" .. OUTFITS_ROOT .. ".\n\n"
        .. "Create a subfolder under #RLV/" .. OUTFITS_ROOT .. " for\n"
        .. "each outfit, then return here. Tap Help for the setup\nnotecard."

    local button_data = {btn("Help", "help")}
    if btn_allowed("Disable") then button_data[#button_data + 1] = btn("Disable", "disable") end
    button_data[#button_data + 1] = btn("Back", "back")

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

local function show_action(outfit_name: string)
    SessionId = sid()
    MenuContext = "action"
    SelectedOutfit = outfit_name

    local is_locked = list_find(LockedOutfits, outfit_name) ~= nil
    local status = ""
    if is_locked then status = "  (Locked)" end

    local body = "Outfit: " .. outfit_name .. status .. "\n\n"
        .. "Add    - attach this folder on top of what is worn\n"
        .. "Wear   - replace: detach worn unlocked items, attach this\n"
        .. "Remove - detach this outfit's items\n"
    if btn_allowed("Lock") or btn_allowed("Unlock") then
        body = body .. "Lock   - toggle protection against removal"
    end

    local button_data = {}
    if btn_allowed("Add") then button_data[#button_data + 1] = btn("Add", "add") end
    if btn_allowed("Wear") then button_data[#button_data + 1] = btn("Wear", "wear") end
    if btn_allowed("Remove") then button_data[#button_data + 1] = btn("Remove", "remove") end
    if btn_allowed("Lock") then
        if is_locked then button_data[#button_data + 1] = btn("Lock: On", "toggle_lock")
        else button_data[#button_data + 1] = btn("Lock: Off", "toggle_lock") end
    end
    button_data[#button_data + 1] = btn("Back", "back")

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

local function give_setup_notecard()
    if ll.GetInventoryType(SETUP_NOTECARD) ~= INVENTORY_NOTECARD then
        ll.RegionSayTo(CurrentUser, 0, "Setup notecard not found in collar inventory.")
        return
    end
    ll.GiveInventory(CurrentUser, SETUP_NOTECARD)
    ll.RegionSayTo(CurrentUser, 0, "Setup instructions sent.")
end

--[[ -------------------- ACTIONS -------------------- ]]

local function apply_add(outfit_name: string)
    rlv_force("@attachallover:" .. OUTFITS_ROOT .. "/" .. outfit_name .. "=force")
    ll.RegionSayTo(CurrentUser, 0, "Adding: " .. outfit_name)
end

local function apply_wear(outfit_name: string)
    rlv_force("@detachallthis:" .. OUTFITS_ROOT .. "=force")
    rlv_force("@remattach=force")
    rlv_force("@remoutfit=force")
    rlv_force("@attachall:" .. OUTFITS_ROOT .. "/" .. outfit_name .. "=force")
    ll.RegionSayTo(CurrentUser, 0, "Wearing: " .. outfit_name)
end

local function apply_remove(outfit_name: string)
    rlv_force("@detachall:" .. OUTFITS_ROOT .. "/" .. outfit_name .. "=force")
    ll.RegionSayTo(CurrentUser, 0, "Removing: " .. outfit_name)
end

local function apply_lock(outfit_name: string)
    if list_find(LockedOutfits, outfit_name) ~= nil then
        ll.RegionSayTo(CurrentUser, 0, outfit_name .. " is already locked.")
        return
    end
    LockedOutfits[#LockedOutfits + 1] = outfit_name
    rlv_op("rlv.apply", "detachallthis:" .. OUTFITS_ROOT .. "/" .. outfit_name)
    persist_locked()
    ll.RegionSayTo(CurrentUser, 0, "Locked: " .. outfit_name)
end

local function apply_unlock(outfit_name: string)
    local idx = list_find(LockedOutfits, outfit_name)
    if idx == nil then
        ll.RegionSayTo(CurrentUser, 0, outfit_name .. " is not locked.")
        return
    end
    table.remove(LockedOutfits, idx)
    rlv_op("rlv.release", "detachallthis:" .. OUTFITS_ROOT .. "/" .. outfit_name)
    persist_locked()
    ll.RegionSayTo(CurrentUser, 0, "Unlocked: " .. outfit_name)
end

--[[ -------------------- DIALOG HANDLER -------------------- ]]

local function handle_dialog_response(msg: string)
    if not json_has(msg, {"session_id"}) then return end
    if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
    if uuid(ll.JsonGetValue(msg, {"user"})) ~= CurrentUser then return end

    local ctx = ll.JsonGetValue(msg, {"context"})
    if ctx == JSON_INVALID then ctx = "" end

    if MenuContext == "empty" then
        if ctx == "help" then give_setup_notecard(); show_empty_menu()
        elseif ctx == "disable" then
            if not btn_allowed("Disable") then ll.RegionSayTo(CurrentUser, 0, "Access denied."); show_empty_menu(); return end
            toggle_active(0)
            show_disabled_menu()
        elseif ctx == "back" then return_to_root() end
        return
    end

    if MenuContext == "disabled" then
        if ctx == "enable" then
            if not btn_allowed("Disable") then ll.RegionSayTo(CurrentUser, 0, "Access denied."); show_disabled_menu(); return end
            toggle_active(1)
            scan_outfits()
        elseif ctx == "help" then give_setup_notecard(); show_disabled_menu()
        elseif ctx == "back" then return_to_root() end
        return
    end

    if MenuContext == "pick" then
        if ctx == "back" then return_to_root(); return end
        if ctx == "prev" then
            if PickPage == 0 then show_picker(LastMaxPage) else show_picker(PickPage - 1) end
            return
        end
        if ctx == "next" then
            if PickPage >= LastMaxPage then show_picker(0) else show_picker(PickPage + 1) end
            return
        end
        if ctx == "help" then give_setup_notecard(); show_picker(PickPage); return end
        if ctx == "disable" then
            if not btn_allowed("Disable") then ll.RegionSayTo(CurrentUser, 0, "Access denied."); show_picker(PickPage); return end
            toggle_active(0)
            show_disabled_menu()
            return
        end
        if starts_with(ctx, "pick:") then
            local pick_idx = integer(string.sub(ctx, 6))  -- 0-based
            if pick_idx >= 0 and pick_idx < #Outfits then
                show_action(Outfits[pick_idx + 1])
            end
        end
        return
    end

    if MenuContext == "action" then
        if ctx == "back" then show_picker(PickPage)
        elseif ctx == "add" then apply_add(SelectedOutfit); show_picker(PickPage)
        elseif ctx == "wear" then apply_wear(SelectedOutfit); show_picker(PickPage)
        elseif ctx == "remove" then apply_remove(SelectedOutfit); show_picker(PickPage)
        elseif ctx == "toggle_lock" then
            if list_find(LockedOutfits, SelectedOutfit) ~= nil then apply_unlock(SelectedOutfit)
            else apply_lock(SelectedOutfit) end
            show_picker(PickPage)
        end
    end
end

local function handle_dialog_timeout(msg: string)
    if not json_has(msg, {"session_id"}) then return end
    if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
    cleanup_session()
end

--[[ -------------------- RLV RESPONSE -------------------- ]]

local function handle_rlv_response(message: string)
    stop_rlv_listen()
    if CurrentUser == NULL_KEY then return end
    if MenuContext ~= "scanning" then return end

    Outfits = {}
    local has_alt_base = false
    if message ~= "" then
        for _, raw_e in ipairs(ll.ParseString2List(message, {","}, {})) do
            local entry = ll.StringTrim(raw_e, STRING_TRIM)
            if entry ~= "" then
                if entry == "base" or entry == "~base" then has_alt_base = true end
                local first = string.sub(entry, 1, 1)
                if first ~= "." and first ~= "~" then
                    Outfits[#Outfits + 1] = entry
                end
            end
        end
        table.sort(Outfits)
    end

    -- Defensive cleanup of stale @detachallthis claims (legacy paradigms).
    ll.OwnerSay("@detachallthis:outfits/base=y")
    ll.OwnerSay("@detachallthis:outfits/~base=y")
    if has_alt_base or #Outfits == 0 then
        ll.OwnerSay("@detachallthis:outfits/.base=y")
        LastActive = 0
        OutfitsActive = 0
    end

    if #Outfits == 0 then
        show_empty_menu()
        return
    end
    show_picker(0)
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
    stop_rlv_listen()
    if CurrentUser ~= NULL_KEY then
        ll.RegionSayTo(CurrentUser, 0, "RLV not responding. Is RLV mode enabled?")
        return_to_root()
    end
end

function LLEvents.listen(channel: number, name: string, id, message: string)
    if channel == RLV_CHAN and id == ll.GetOwner() then handle_rlv_response(message) end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.register.refresh" then register_self()
        elseif msg_type == "kernel.ping" then send_pong()
        elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            release_persisted_locks()  -- before reset; kmod_rlv may drop Claims
            ll.LinksetDataDelete("plugin.reg." .. PLUGIN_CONTEXT)
            ll.LinksetDataDelete("acl.policycontext:" .. PLUGIN_CONTEXT)
            ll.ResetScript()
        end
    elseif num == SETTINGS_BUS then
        if msg_type == "settings.sync" then apply_settings_sync() end
    elseif num == UI_BUS then
        if msg_type == "ui.menu.start" then
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) ~= PLUGIN_CONTEXT then return end
            if id == NULL_KEY then return end

            local start_acl = integer(ll.JsonGetValue(msg, {"acl"}))
            gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, start_acl)
            if not btn_allowed("Add") and not btn_allowed("Wear") and not btn_allowed("Remove") then
                ll.RegionSayTo(id, 0, "Access denied.")
                gPolicyButtons = {}
                return
            end
            CurrentUser = id
            if OutfitsActive ~= 0 then scan_outfits() else show_disabled_menu() end
        end
    elseif num == DIALOG_BUS then
        if msg_type == "ui.dialog.response" then handle_dialog_response(msg)
        elseif msg_type == "ui.dialog.timeout" then handle_dialog_timeout(msg) end
    end
end

-- Top-level init.
main()

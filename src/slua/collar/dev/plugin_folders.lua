--[[--------------------
PLUGIN: plugin_folders.lua  (SLua port)
VERSION: 1.10
PURPOSE: Browse #RLV shared folders; Attach/Detach/Lock/Unlock with persistent
         @detachallthis locks. Paginated, breadcrumb-navigable picker.
ARCHITECTURE: Consolidated message bus lanes; RLV via kmod_rlv (rlv.force +
              rlv.apply/release under consumer "folders"); replies on RLV_CHAN.

SLUA PORT NOTES:
- Ported from plugin_folders.lsl. @getinvworn scan, lock claims, settings.delta
  CSV writes, and the dot/tilde-folder skip are unchanged.
- SLua conventions: LLEvents.* handlers, local main(); the stride-2 Folders list
  becomes an array of {name,worn} records; LockedNames is a string array.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS     = 800
local UI_BUS           = 900
local DIALOG_BUS       = 950

--[[ -------------------- IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.folders"
local PLUGIN_LABEL   = "Folders"

--[[ -------------------- SETTINGS / CONSTANTS -------------------- ]]
local KEY_LOCKED   = "folders.locked"
local RLV_CHAN     = 1888753
local RLV_TIMEOUT  = 10.0
local RLV_CONSUMER = "folders"

--[[ -------------------- STATE -------------------- ]]
local LockedNames = {}   -- folder paths locked via @detachallthis

local CurrentUser    = NULL_KEY
local UserAcl        = 0
local gPolicyButtons = {}
local SessionId      = ""
local MenuContext    = ""   -- "scanning" | "pick"
local CurrentPath    = ""   -- #RLV-relative; "" = root
local Folders        = {}   -- array of { name, worn }
local PickPage       = 0
local LastMaxPage    = 0
local RlvListenHandle = 0

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

local function generate_session_id(): string
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
end

local function btn(label: string, cmd: string): string
    return ll.List2Json(JSON_OBJECT, {"label", label, "context", cmd})
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
        "2", "Attach,Detach",
        "3", "Attach,Detach,Lock,Unlock",
        "4", "Attach,Detach,Lock,Unlock",
        "5", "Attach,Detach,Lock,Unlock",
    }))
    write_plugin_reg(PLUGIN_LABEL)
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", ll.GetScriptName(),
    }), NULL_KEY)
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "chat.alias.declare", "alias", "folders", "context", PLUGIN_CONTEXT,
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
    set_timer(0.0)
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
    UserAcl = 0
    gPolicyButtons = {}
    MenuContext = ""
    CurrentPath = ""
    Folders = {}
    PickPage = 0
    LastMaxPage = 0
end

--[[ -------------------- RLV FOLDER COMMANDS -------------------- ]]

local function rlv_op(op: string, behav: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", op, "consumer", RLV_CONSUMER, "behav", behav,
    }), NULL_KEY)
end

local function rlv_force(command: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "rlv.force", "command", command,
    }), NULL_KEY)
end

local function attach_folder(folder_name: string) rlv_force("@attachall:" .. folder_name .. "=force") end
local function detach_folder(folder_name: string) rlv_force("@detachall:" .. folder_name .. "=force") end
local function lock_folder(folder_name: string) rlv_op("rlv.apply", "detachallthis:" .. folder_name) end
local function unlock_folder(folder_name: string) rlv_op("rlv.release", "detachallthis:" .. folder_name) end

--[[ -------------------- SETTINGS -------------------- ]]

local function apply_settings_sync()
    local csv = ll.LinksetDataRead(KEY_LOCKED)
    local new_locked = {}
    if csv ~= "" then new_locked = ll.ParseString2List(csv, {","}, {}) end

    for _, folder_name in ipairs(LockedNames) do
        if list_find(new_locked, folder_name) == nil then unlock_folder(folder_name) end
    end

    LockedNames = new_locked

    for _, folder_name in ipairs(LockedNames) do lock_folder(folder_name) end
end

local function persist_locked()
    if #LockedNames == 0 then
        ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delete:" .. KEY_LOCKED, NULL_KEY)
        return
    end
    ll.MessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" .. KEY_LOCKED .. ":" .. ll.DumpList2String(LockedNames, ","), NULL_KEY)
end

--[[ -------------------- UI / NAV -------------------- ]]

local function return_to_root()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return", "context", PLUGIN_CONTEXT, "user", tostring(CurrentUser),
    }), NULL_KEY)
    cleanup_session()
end

local function full_path(folder_name: string): string
    if CurrentPath == "" then return folder_name end
    return CurrentPath .. "/" .. folder_name
end

local function pop_current_path()
    if CurrentPath == "" then return end
    local parts = ll.ParseString2List(CurrentPath, {"/"}, {})
    if #parts <= 1 then CurrentPath = ""; return end
    local kept = {}
    for i = 1, #parts - 1 do kept[i] = parts[i] end
    CurrentPath = ll.DumpList2String(kept, "/")
end

local function scan_current_path()
    Folders = {}
    PickPage = 0
    MenuContext = "scanning"
    stop_rlv_listen()
    RlvListenHandle = ll.Listen(RLV_CHAN, "", ll.GetOwner(), "")
    rlv_force("@getinvworn:" .. CurrentPath .. "=" .. tostring(RLV_CHAN))
    set_timer(RLV_TIMEOUT)
    local where = "#RLV"
    if CurrentPath ~= "" then where = "#RLV/" .. CurrentPath end
    ll.RegionSayTo(CurrentUser, 0, "Reading " .. where .. " ...")
end

local function show_main()
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl)
    CurrentPath = ""
    scan_current_path()
end

-- Decode @getinvworn "<self><descendants>" → indicator.
local function worn_indicator(raw: string): string
    local self_state = "0"
    local desc_state = "0"
    if #raw >= 1 then self_state = string.sub(raw, 1, 1) end
    if #raw >= 2 then desc_state = string.sub(raw, 2, 2) end
    if self_state == "3" or desc_state == "3" then return "[+]" end
    if self_state == "2" or desc_state == "2" then return "[-]" end
    return "[ ]"
end

local function show_folder_pick(page: number)
    local at_subfolder = CurrentPath ~= ""

    local current_locked = false
    if at_subfolder and list_find(LockedNames, CurrentPath) ~= nil then current_locked = true end

    local action_buttons = {}
    if at_subfolder then
        if btn_allowed("Attach") then action_buttons[#action_buttons + 1] = btn("Attach", "attach") end
        if btn_allowed("Detach") then action_buttons[#action_buttons + 1] = btn("Detach", "detach") end
        if current_locked then
            if btn_allowed("Unlock") then action_buttons[#action_buttons + 1] = btn("Unlock", "unlock") end
        else
            if btn_allowed("Lock") then action_buttons[#action_buttons + 1] = btn("Lock", "lock") end
        end
    end
    local action_count = #action_buttons

    local page_size = 9 - action_count
    local total = #Folders

    SessionId = generate_session_id()
    MenuContext = "pick"

    local crumb = "#RLV"
    if at_subfolder then crumb = "#RLV/" .. CurrentPath end

    local max_page = 0
    if total > 0 then max_page = (total - 1) // page_size end
    if page < 0 then page = 0 end
    if page > max_page then page = max_page end
    PickPage = page
    LastMaxPage = max_page

    local start = page * page_size  -- 0-based
    local end_idx = start + page_size
    if end_idx > total then end_idx = total end
    local count = end_idx - start

    local body = crumb
    if at_subfolder then
        if current_locked then body = body .. "  (Locked)" else body = body .. "  (Unlocked)" end
    end
    body = body .. "\n\n"
    if total == 0 then
        body = body .. "(no subfolders here)"
    else
        body = body .. "Tap a number to open a subfolder.\n[+]=worn  [-]=partial  *=locked\n"
            .. "Page " .. tostring(page + 1) .. " of " .. tostring(max_page + 1) .. "\n\n"
        for k = 0, count - 1 do
            local rec = Folders[start + k + 1]
            local lock_mark = ""
            if list_find(LockedNames, full_path(rec.name)) ~= nil then lock_mark = "*" end
            body = body .. tostring(k + 1) .. ". " .. worn_indicator(rec.worn) .. " " .. rec.name .. lock_mark .. "\n"
        end
    end

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
        button_data[target_slots[ci + 1] + 1] = btn(tostring(ci + 1), "pick:" .. tostring(start + ci))
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

--[[ -------------------- ACTIONS -------------------- ]]

local function apply_folder_action(folder_path: string, app_action: string)
    if folder_path == "" then
        ll.RegionSayTo(CurrentUser, 0, "Cannot perform that on the #RLV root.")
        return
    end

    if app_action == "attach" then
        attach_folder(folder_path)
        ll.RegionSayTo(CurrentUser, 0, "Attaching: " .. folder_path)
    elseif app_action == "detach" then
        if list_find(LockedNames, folder_path) ~= nil then
            ll.RegionSayTo(CurrentUser, 0, folder_path .. " is locked. Unlock it first.")
        else
            detach_folder(folder_path)
            ll.RegionSayTo(CurrentUser, 0, "Detaching: " .. folder_path)
        end
    elseif app_action == "lock" then
        if list_find(LockedNames, folder_path) ~= nil then
            ll.RegionSayTo(CurrentUser, 0, folder_path .. " is already locked.")
        else
            LockedNames[#LockedNames + 1] = folder_path
            lock_folder(folder_path)
            persist_locked()
            ll.RegionSayTo(CurrentUser, 0, "Locked: " .. folder_path)
        end
    elseif app_action == "unlock" then
        local idx = list_find(LockedNames, folder_path)
        if idx == nil then
            ll.RegionSayTo(CurrentUser, 0, folder_path .. " is not locked.")
        else
            table.remove(LockedNames, idx)
            unlock_folder(folder_path)
            persist_locked()
            ll.RegionSayTo(CurrentUser, 0, "Unlocked: " .. folder_path)
        end
    end
end

local function handle_subpath(user, acl_level: number, subpath: string)
    local tokens = ll.ParseString2List(subpath, {"."}, {})
    if #tokens == 0 then return end
    local action = tokens[1]

    if action ~= "attach" and action ~= "detach" and action ~= "lock" and action ~= "unlock" then
        ll.RegionSayTo(user, 0, "Unknown folders subcommand: " .. action)
        return
    end
    if #tokens < 2 then
        ll.RegionSayTo(user, 0, "Usage: folders " .. action .. " <foldername>")
        return
    end
    if #tokens > 2 then
        ll.RegionSayTo(user, 0, "Folder names containing dots are not accessible via chat — use the menu.")
        return
    end

    local folder_name = tokens[2]

    local btn_label = "Attach"
    if action == "detach" then btn_label = "Detach"
    elseif action == "lock" then btn_label = "Lock"
    elseif action == "unlock" then btn_label = "Unlock" end

    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level)
    if not btn_allowed(btn_label) then
        ll.RegionSayTo(user, 0, "Access denied.")
        gPolicyButtons = {}
        return
    end
    gPolicyButtons = {}

    CurrentUser = user
    UserAcl = acl_level
    apply_folder_action(folder_name, action)
end

--[[ -------------------- DIALOG HANDLER -------------------- ]]

local function handle_dialog_response(msg: string)
    if not json_has(msg, {"session_id"}) then return end
    if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
    if uuid(ll.JsonGetValue(msg, {"user"})) ~= CurrentUser then return end

    local ctx = ll.JsonGetValue(msg, {"context"})
    if ctx == JSON_INVALID then ctx = "" end

    if MenuContext ~= "pick" then return end

    if ctx == "back" then
        if CurrentPath == "" then return_to_root()
        else pop_current_path(); scan_current_path() end
        return
    end

    if ctx == "prev" then
        if PickPage == 0 then show_folder_pick(LastMaxPage) else show_folder_pick(PickPage - 1) end
        return
    end
    if ctx == "next" then
        if PickPage >= LastMaxPage then show_folder_pick(0) else show_folder_pick(PickPage + 1) end
        return
    end

    if ctx == "attach" or ctx == "detach" then
        apply_folder_action(CurrentPath, ctx)
        scan_current_path()
        return
    end
    if ctx == "lock" or ctx == "unlock" then
        apply_folder_action(CurrentPath, ctx)
        show_folder_pick(PickPage)
        return
    end

    if starts_with(ctx, "pick:") then
        local idx = integer(string.sub(ctx, 6))  -- 0-based
        if idx >= 0 and idx < #Folders then
            CurrentPath = full_path(Folders[idx + 1].name)
            scan_current_path()
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

    Folders = {}
    if message ~= "" then
        for _, raw_e in ipairs(ll.ParseString2List(message, {","}, {})) do
            local entry = ll.StringTrim(raw_e, STRING_TRIM)
            if entry ~= "" then
                local pipe_pos = string.find(entry, "|", 1, true)
                local folder_name, worn_state
                if pipe_pos == nil then
                    folder_name = entry
                    worn_state = "0"
                elseif pipe_pos > 1 then
                    folder_name = string.sub(entry, 1, pipe_pos - 1)
                    worn_state = string.sub(entry, pipe_pos + 1)
                else
                    folder_name = ""  -- empty name before pipe — skip
                end
                if folder_name ~= "" then
                    local first = string.sub(folder_name, 1, 1)
                    if first ~= "." and first ~= "~" then
                        Folders[#Folders + 1] = { name = folder_name, worn = worn_state }
                    end
                end
            end
        end
        table.sort(Folders, function(a, b) return a.name < b.name end)
    end

    if #Folders == 0 and CurrentPath == "" then
        ll.RegionSayTo(CurrentUser, 0, "No shared folders found in #RLV.")
        return_to_root()
        return
    end

    show_folder_pick(0)
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

_on_timer = function()
    stop_rlv_listen()
    if CurrentUser ~= NULL_KEY then
        ll.RegionSayTo(CurrentUser, 0, "RLV not responding. Is RLV mode enabled?")
        return_to_root()
    end
end

function LLEvents.listen(channel: number, name: string, id, message: string)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    if channel == RLV_CHAN and id == ll.GetOwner() then handle_rlv_response(message) end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
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
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) ~= PLUGIN_CONTEXT then return end

            local start_acl = integer(ll.JsonGetValue(msg, {"acl"}))
            local subpath = ""
            local sp = ll.JsonGetValue(msg, {"subpath"})
            if sp ~= JSON_INVALID then subpath = sp end

            if subpath ~= "" then
                handle_subpath(id, start_acl, subpath)
                return
            end

            CurrentUser = id
            UserAcl = start_acl
            show_main()
        end
    elseif num == DIALOG_BUS then
        if msg_type == "ui.dialog.response" then handle_dialog_response(msg)
        elseif msg_type == "ui.dialog.timeout" then handle_dialog_timeout(msg) end
    end
end

-- Top-level init.
main()

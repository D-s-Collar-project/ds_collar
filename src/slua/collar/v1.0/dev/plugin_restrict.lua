--[[--------------------
PLUGIN: plugin_restrict.lua  (SLua port)
VERSION: 1.10
PURPOSE: Toggle RLV restrictions by category, plus Force Sit/Unsit.
ARCHITECTURE: Consolidated message bus lanes; RLV via kmod_rlv (rlv.apply/release
              under consumer "restrict", rlv.force for sit/unsit).

SLUA PORT NOTES:
- Ported from plugin_restrict.lsl. The CAT_*/LABEL_* tables, settings.delta CSV
  writes, the @sittp reconcile, and sos.restrict.clear are unchanged.
- SLua conventions: LLEvents.* handlers, local main(); Restrictions is a string
  array; SitCandidates is an array of {name,key}; sensor uses detected:getKey().
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS     = 800
local UI_BUS           = 900
local DIALOG_BUS       = 950

--[[ -------------------- IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.rlvrestrict"
local PLUGIN_LABEL   = "Restrict"

local KEY_RESTRICTIONS = "restrict.list"

local MAX_RESTRICTIONS = 32
local Restrictions = {}  -- active RLV commands, e.g. "@shownames"

--[[ -------------------- CATEGORIES -------------------- ]]
local CAT_NAME_INVENTORY = "Inventory"
local CAT_NAME_SPEECH    = "Speech"
local CAT_NAME_TRAVEL    = "Travel"
local CAT_NAME_OTHER     = "Other"

local CAT_INV    = {"@addattach", "@addoutfit", "@remattach", "@remoutfit", "@showinv", "@viewnote", "@viewscript"}
local CAT_SPEECH = {"@sendchat", "@recvim", "@sendim", "@chatshout", "@startim", "@chatwhisper"}
local CAT_TRAVEL = {"@tploc", "@tplm", "@sittp", "@tplure"}
local CAT_OTHER  = {"@edit", "@interact", "@shownames", "@rez", "@sit", "@touchattach", "@fartouch", "@touchhud", "@touchall", "@touchworld", "@unsit"}

local LABEL_INV    = {"+ Attach", "+ Outfit", "- Attach", "- Outfit", "Inv", "Notes", "Scripts"}
local LABEL_SPEECH = {"Chat", "Recv IM", "Send IM", "Shout", "Start IM", "Whisper"}
local LABEL_TRAVEL = {"Loc. TP", "Map TP", "Sit TP", "TP"}
local LABEL_OTHER  = {"Edit", "Isolate", "Names", "Rez", "Sit", "Touch Att", "Touch Far", "Touch HUD", "Touch Own", "Touch Wld", "Unsit"}

--[[ -------------------- UI SESSION STATE -------------------- ]]
local SessionId = ""
local CurrentUser = NULL_KEY
local UserAcl = 0
local gPolicyButtons = {}
local MenuContext = ""
local CurrentCategory = ""
local CurrentPage = 0

local DIALOG_PAGE_SIZE = 9

--[[ -------------------- FORCE SIT STATE -------------------- ]]
local SitCandidates = {}  -- array of { name, key }
local SitPage = 0
local SIT_SCAN_RANGE = 10.0
local ScanInitiator = NULL_KEY

--[[ -------------------- HELPERS -------------------- ]]

--[[ integer(): SLua has no LSL-style (integer) cast; emulate it (truncate toward zero; non-numeric -> 0). ]]
local function integer(v): number
    local n = tonumber(v)
    if n == nil then return 0 end
    if n < 0 then return math.ceil(n) end
    return math.floor(n)
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

local function btn(label: string, cmd: string): string
    return ll.List2Json(JSON_OBJECT, {"label", label, "context", cmd})
end

local function generate_session_id(): string
    return ll.GetScriptName() .. "_" .. tostring(ll.GetKey()) .. "_" .. tostring(ll.GetUnixTime())
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

-- Lay out 1-3 nav buttons (slots 0..nav_count-1) + content top-to-bottom, L-R.
local function reorder_item_buttons(nav_buttons, item_buttons)
    local nav_count = #nav_buttons
    local item_count = #item_buttons
    local total = nav_count + item_count

    local reading_order = {9, 10, 11, 6, 7, 8, 3, 4, 5, 0, 1, 2}
    local slots = {}
    for _, rs in ipairs(reading_order) do
        if rs < total and rs >= nav_count then slots[#slots + 1] = rs end
    end

    local final_buttons = {}
    for _, b in ipairs(nav_buttons) do final_buttons[#final_buttons + 1] = b end
    for _ = 1, item_count do final_buttons[#final_buttons + 1] = btn(" ", " ") end

    for i = 1, item_count do
        final_buttons[slots[i] + 1] = item_buttons[i]  -- slot is 0-based
    end
    return final_buttons
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
        "1", "Force Sit,Force Unsit",
        "2", "Force Sit,Force Unsit",
        "3", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        "4", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        "5", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
    }))
    write_plugin_reg(PLUGIN_LABEL)
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", ll.GetScriptName(),
    }), NULL_KEY)
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "chat.alias.declare", "alias", "restrict", "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

local function send_pong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

local function cleanup_session()
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
    CurrentCategory = ""
    CurrentPage = 0
end

--[[ -------------------- SETTINGS / RLV -------------------- ]]

local RLV_CONSUMER = "restrict"

local function persist_restrictions()
    if #Restrictions == 0 then
        ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delete:" .. KEY_RESTRICTIONS, NULL_KEY)
        return
    end
    ll.MessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" .. KEY_RESTRICTIONS .. ":" .. ll.DumpList2String(Restrictions, ","), NULL_KEY)
end

-- Restrictions store "@behav"; kmod_rlv wants the bare behav.
local function rlv_op(op: string, restr_cmd: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", op, "consumer", RLV_CONSUMER, "behav", string.sub(restr_cmd, 2),
    }), NULL_KEY)
end

local function rlv_clear_all()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "rlv.clear", "consumer", RLV_CONSUMER,
    }), NULL_KEY)
end

local function rlv_force(command: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "rlv.force", "command", command,
    }), NULL_KEY)
end

local function restriction_idx(restr_cmd: string)
    return list_find(Restrictions, restr_cmd)
end

-- @sittp = OR of explicit toggle + implicit @tplm/@tploc holds.
local function reconcile_sittp()
    local explicit = list_find(Restrictions, "@sittp") ~= nil
    local implied = list_find(Restrictions, "@tplm") ~= nil or list_find(Restrictions, "@tploc") ~= nil
    if explicit or implied then rlv_op("rlv.apply", "@sittp") else rlv_op("rlv.release", "@sittp") end
end

local function apply_settings_sync()
    local csv = ll.LinksetDataRead(KEY_RESTRICTIONS)
    local new_list = {}
    if csv ~= "" then new_list = ll.ParseString2List(csv, {","}, {}) end

    if ll.DumpList2String(new_list, ",") == ll.DumpList2String(Restrictions, ",") then return end

    for _, restr_cmd in ipairs(Restrictions) do
        if list_find(new_list, restr_cmd) == nil then rlv_op("rlv.release", restr_cmd) end
    end

    Restrictions = new_list
    for _, restr_cmd in ipairs(Restrictions) do rlv_op("rlv.apply", restr_cmd) end

    reconcile_sittp()
end

local function toggle_restriction(restr_cmd: string)
    local idx = restriction_idx(restr_cmd)
    local is_sittp = restr_cmd == "@sittp"
    local affects_sittp = is_sittp or restr_cmd == "@tplm" or restr_cmd == "@tploc"

    if idx ~= nil then
        table.remove(Restrictions, idx)
        if not is_sittp then rlv_op("rlv.release", restr_cmd) end
    else
        if #Restrictions >= MAX_RESTRICTIONS then
            ll.RegionSayTo(CurrentUser, 0, "Cannot add restriction: limit reached.")
            return
        end
        Restrictions[#Restrictions + 1] = restr_cmd
        if not is_sittp then rlv_op("rlv.apply", restr_cmd) end
    end

    if affects_sittp then reconcile_sittp() end
    persist_restrictions()
end

local function remove_all_restrictions()
    rlv_clear_all()
    Restrictions = {}
    persist_restrictions()
end

--[[ -------------------- CATEGORY HELPERS -------------------- ]]

local function get_category_list(cat_name: string)
    if cat_name == CAT_NAME_INVENTORY then return CAT_INV end
    if cat_name == CAT_NAME_SPEECH then return CAT_SPEECH end
    if cat_name == CAT_NAME_TRAVEL then return CAT_TRAVEL end
    if cat_name == CAT_NAME_OTHER then return CAT_OTHER end
    return {}
end

local function get_category_labels(cat_name: string)
    if cat_name == CAT_NAME_INVENTORY then return LABEL_INV end
    if cat_name == CAT_NAME_SPEECH then return LABEL_SPEECH end
    if cat_name == CAT_NAME_TRAVEL then return LABEL_TRAVEL end
    if cat_name == CAT_NAME_OTHER then return LABEL_OTHER end
    return {}
end

--[[ -------------------- NAV / MENUS -------------------- ]]

local function return_to_root()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return", "context", PLUGIN_CONTEXT, "user", tostring(CurrentUser),
    }), NULL_KEY)
    cleanup_session()
end

local function show_main()
    SessionId = generate_session_id()
    MenuContext = "main"
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl)

    local nav_buttons = {btn("Back", "back")}
    local item_buttons = {}
    if btn_allowed("Clear all") then item_buttons[#item_buttons + 1] = btn("Clear all", "clear_all") end
    if btn_allowed("Force Sit") then item_buttons[#item_buttons + 1] = btn("Force Sit", "force_sit") end
    if btn_allowed("Force Unsit") then item_buttons[#item_buttons + 1] = btn("Force Unsit", "force_unsit") end
    if btn_allowed("Inventory") then item_buttons[#item_buttons + 1] = btn(CAT_NAME_INVENTORY, "cat_inventory") end
    if btn_allowed("Other") then item_buttons[#item_buttons + 1] = btn(CAT_NAME_OTHER, "cat_other") end
    if btn_allowed("Speech") then item_buttons[#item_buttons + 1] = btn(CAT_NAME_SPEECH, "cat_speech") end
    if btn_allowed("Travel") then item_buttons[#item_buttons + 1] = btn(CAT_NAME_TRAVEL, "cat_travel") end

    local body
    if btn_allowed("Inventory") then
        body = "RLV Restrictions\n\nActive: " .. tostring(#Restrictions) .. "/" .. tostring(MAX_RESTRICTIONS)
    else
        body = "RLV Actions\n\nForce sit or unsit the wearer."
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", PLUGIN_LABEL,
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, reorder_item_buttons(nav_buttons, item_buttons)),
        "timeout", 60,
    }), NULL_KEY)
end

local function show_category_menu(cat_name: string, page_num: number)
    SessionId = generate_session_id()
    MenuContext = "category"
    CurrentCategory = cat_name
    CurrentPage = page_num

    local cat_cmds = get_category_list(cat_name)
    local cat_labels = get_category_labels(cat_name)
    local total_items = #cat_cmds

    if total_items == 0 then
        ll.RegionSayTo(CurrentUser, 0, "Empty category.")
        show_main()
        return
    end

    local start_idx = page_num * DIALOG_PAGE_SIZE  -- 0-based
    local end_idx = start_idx + DIALOG_PAGE_SIZE - 1
    if end_idx >= total_items then end_idx = total_items - 1 end

    local item_buttons = {}
    for i = start_idx, end_idx do
        local cmd = cat_cmds[i + 1]
        local label = cat_labels[i + 1]
        if restriction_idx(cmd) ~= nil then label = "[X] " .. label else label = "[ ] " .. label end
        item_buttons[#item_buttons + 1] = btn(label, cmd)
    end

    local max_page = (total_items - 1) // DIALOG_PAGE_SIZE
    local nav_buttons = {btn("<<", "prev_page"), btn(">>", "next_page"), btn("Back", "back")}

    local body = cat_name .. " (" .. tostring(page_num + 1) .. "/" .. tostring(max_page + 1)
        .. ")\n\nActive: " .. tostring(#Restrictions)

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", cat_name,
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, reorder_item_buttons(nav_buttons, item_buttons)),
        "timeout", 60,
    }), NULL_KEY)
end

--[[ -------------------- FORCE SIT / UNSIT -------------------- ]]

local function start_sit_scan()
    SitCandidates = {}
    SitPage = 0
    MenuContext = "sit_scan"
    ScanInitiator = CurrentUser
    ll.RegionSayTo(CurrentUser, 0, "Scanning for nearby objects...")
    ll.Sensor("", NULL_KEY, bit32.bor(PASSIVE, ACTIVE, SCRIPTED), SIT_SCAN_RANGE, PI)
end

local function display_sit_targets()
    local total_items = #SitCandidates
    if total_items == 0 then
        ll.RegionSayTo(CurrentUser, 0, "No objects found nearby.")
        show_main()
        return
    end

    SessionId = generate_session_id()
    MenuContext = "sit_select"

    local items_per_page = 9
    local total_pages = (total_items + items_per_page - 1) // items_per_page
    local start_idx = SitPage * items_per_page  -- 0-based
    local end_idx = start_idx + items_per_page
    if end_idx > total_items then end_idx = total_items end

    local body = "Select object to sit on:\n\n"
    local display_num = 1
    for i = start_idx, end_idx - 1 do
        local obj_name = SitCandidates[i + 1].name
        if #obj_name > 20 then obj_name = string.sub(obj_name, 1, 17) .. "..." end
        body = body .. tostring(display_num) .. ". " .. obj_name .. "\n"
        display_num += 1
    end
    if total_pages > 1 then body = body .. "\nPage " .. tostring(SitPage + 1) .. "/" .. tostring(total_pages) end

    local nav_buttons = {btn("<<", "prev_page"), btn(">>", "next_page"), btn("Back", "back")}
    local item_buttons = {}
    for i = 1, (end_idx - start_idx) do
        item_buttons[#item_buttons + 1] = btn(tostring(i), "sit_" .. tostring(i))
    end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", "Force Sit",
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, reorder_item_buttons(nav_buttons, item_buttons)),
        "timeout", 60,
    }), NULL_KEY)
end

local function force_sit_on(target)
    if target == NULL_KEY then return end
    rlv_force("@sit:" .. tostring(target) .. "=force")
    ll.RegionSayTo(CurrentUser, 0, "Forcing sit...")
end

local function force_unsit()
    rlv_force("@unsit=force")
    ll.RegionSayTo(CurrentUser, 0, "Forcing unsit...")
end

--[[ -------------------- DIALOG HANDLER -------------------- ]]

local function deny_or(label: string): boolean
    if not btn_allowed(label) then
        ll.RegionSayTo(CurrentUser, 0, "Access denied.")
        show_main()
        return true
    end
    return false
end

local function handle_dialog_response(msg: string)
    if ll.JsonGetValue(msg, {"session_id"}) == JSON_INVALID
        or ll.JsonGetValue(msg, {"context"}) == JSON_INVALID
        or ll.JsonGetValue(msg, {"user"}) == JSON_INVALID then return end

    if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
    if uuid(ll.JsonGetValue(msg, {"user"})) ~= CurrentUser then return end

    local ctx = ll.JsonGetValue(msg, {"context"})

    if MenuContext == "main" then
        if ctx == "back" then return_to_root()
        elseif ctx == "cat_inventory" then if not deny_or("Inventory") then show_category_menu(CAT_NAME_INVENTORY, 0) end
        elseif ctx == "cat_speech" then if not deny_or("Speech") then show_category_menu(CAT_NAME_SPEECH, 0) end
        elseif ctx == "cat_travel" then if not deny_or("Travel") then show_category_menu(CAT_NAME_TRAVEL, 0) end
        elseif ctx == "cat_other" then if not deny_or("Other") then show_category_menu(CAT_NAME_OTHER, 0) end
        elseif ctx == "clear_all" then
            if not deny_or("Clear all") then
                remove_all_restrictions()
                ll.RegionSayTo(CurrentUser, 0, "All restrictions removed.")
                show_main()
            end
        elseif ctx == "force_sit" then start_sit_scan()
        elseif ctx == "force_unsit" then force_unsit(); show_main()
        end
    elseif MenuContext == "sit_select" then
        if ctx == "back" then
            show_main()
        elseif ctx == "prev_page" then
            local max_page = (#SitCandidates - 1) // 9
            if SitPage == 0 then SitPage = max_page else SitPage -= 1 end
            display_sit_targets()
        elseif ctx == "next_page" then
            local max_page = (#SitCandidates - 1) // 9
            if SitPage >= max_page then SitPage = 0 else SitPage += 1 end
            display_sit_targets()
        elseif starts_with(ctx, "sit_") then
            local button_num = integer(string.sub(ctx, 5))
            if button_num >= 1 and button_num <= 9 then
                local actual_idx = (SitPage * 9) + (button_num - 1)  -- 0-based
                local record = SitCandidates[actual_idx + 1]
                if record ~= nil then
                    force_sit_on(record.key)
                    show_main()
                end
            end
        end
    elseif MenuContext == "category" then
        if ctx == "back" then
            show_main()
        elseif ctx == "prev_page" then
            local max_page = (#get_category_list(CurrentCategory) - 1) // DIALOG_PAGE_SIZE
            if CurrentPage == 0 then show_category_menu(CurrentCategory, max_page)
            else show_category_menu(CurrentCategory, CurrentPage - 1) end
        elseif ctx == "next_page" then
            local max_page = (#get_category_list(CurrentCategory) - 1) // DIALOG_PAGE_SIZE
            if CurrentPage >= max_page then show_category_menu(CurrentCategory, 0)
            else show_category_menu(CurrentCategory, CurrentPage + 1) end
        else
            local restr_cmd = ctx
            if restriction_idx(restr_cmd) ~= nil or starts_with(restr_cmd, "@") then
                toggle_restriction(restr_cmd)
                show_category_menu(CurrentCategory, CurrentPage)
            end
        end
    end
end

local function handle_dialog_timeout(msg: string)
    local recv_session = ll.JsonGetValue(msg, {"session_id"})
    if recv_session == JSON_INVALID then return end
    if recv_session ~= SessionId then return end
    cleanup_session()
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

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    local mtype = ll.JsonGetValue(msg, {"type"})
    if mtype == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if mtype == "kernel.register.refresh" then
            register_self()
            apply_settings_sync()
        elseif mtype == "kernel.ping" then
            send_pong()
        elseif mtype == "kernel.reset.soft" or mtype == "kernel.reset.factory" then
            ll.LinksetDataDelete("plugin.reg." .. PLUGIN_CONTEXT)
            ll.LinksetDataDelete("acl.policycontext:" .. PLUGIN_CONTEXT)
            ll.ResetScript()
        end
    elseif num == SETTINGS_BUS then
        if mtype == "settings.sync" then apply_settings_sync() end
    elseif num == UI_BUS then
        if mtype == "ui.menu.start" then
            local context = ll.JsonGetValue(msg, {"context"})
            if context == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            if context ~= PLUGIN_CONTEXT then return end

            local acl = integer(ll.JsonGetValue(msg, {"acl"}))
            local subpath = ""
            local sp = ll.JsonGetValue(msg, {"subpath"})
            if sp ~= JSON_INVALID then subpath = sp end

            if subpath == "clear" then
                gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl)
                if not btn_allowed("Clear all") then
                    ll.RegionSayTo(id, 0, "Access denied.")
                    gPolicyButtons = {}
                    return
                end
                gPolicyButtons = {}
                remove_all_restrictions()
                ll.RegionSayTo(id, 0, "All restrictions removed.")
                return
            end
            if subpath ~= "" then
                ll.RegionSayTo(id, 0, "Unknown restrict subcommand: " .. subpath)
                return
            end

            CurrentUser = id
            UserAcl = acl
            show_main()
        elseif mtype == "sos.restrict.clear" then
            remove_all_restrictions()
        end
    elseif num == DIALOG_BUS then
        if mtype == "ui.dialog.response" then handle_dialog_response(msg)
        elseif mtype == "ui.dialog.timeout" then handle_dialog_timeout(msg) end
    end
end

function LLEvents.sensor(detected)
    if MenuContext ~= "sit_scan" then return end
    if CurrentUser == NULL_KEY then return end
    if CurrentUser ~= ScanInitiator then return end

    local wearer = ll.GetOwner()
    local my_key = ll.GetKey()
    SitCandidates = {}
    for _, d in ipairs(detected) do
        local detected_key = d:getKey()
        if detected_key ~= my_key and detected_key ~= wearer then
            SitCandidates[#SitCandidates + 1] = { name = d:getName(), key = detected_key }
        end
    end
    display_sit_targets()
end

function LLEvents.no_sensor()
    if MenuContext ~= "sit_scan" then return end
    if CurrentUser == NULL_KEY then return end
    if CurrentUser ~= ScanInitiator then return end
    ll.RegionSayTo(CurrentUser, 0, "No objects found within " .. tostring(integer(SIT_SCAN_RANGE)) .. "m.")
    show_main()
end

-- Top-level init.
main()

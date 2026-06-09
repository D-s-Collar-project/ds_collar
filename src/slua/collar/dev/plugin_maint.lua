--[[--------------------
PLUGIN: plugin_maint.lua  (SLua port)
VERSION: 1.10
PURPOSE: Maintenance menu — view/reload settings, access list, reload collar,
         clear leash, give HUD/manual, reset config, and the updater-scan flow.
ARCHITECTURE: Consolidated message bus lanes; updater scan via kmod_remote (REMOTE_BUS).

SLUA PORT NOTES:
- Ported from plugin_maint.lsl. settings.* / remote.updaterscan.* / plugin.leash
  wire messages and LSD reads unchanged. plugin_maint owns the updater invite flow.
- SLua conventions: LLEvents.* handlers, local main(); CSV reads are arrays.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local REMOTE_BUS = 600
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.maintenance"
local PLUGIN_LABEL = "Maintenance"

--[[ -------------------- INVENTORY ITEMS -------------------- ]]
local HUD_ITEM = "Control HUD"
local MANUAL_NOTECARD = "D/s Collar User Manual"

--[[ -------------------- STATE -------------------- ]]
local CurrentUser = NULL_KEY
local CurrentUserAcl = -999
local gPolicyButtons = {}
local SessionId = ""
local MenuContext = "main"
local UpdateScanUpdater = NULL_KEY
local UpdateScanVersion = ""

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

local function generate_session_id(): string
    return "maint_" .. tostring(ll.GetKey()) .. "_" .. tostring(ll.GetUnixTime())
end

local function csv_read(lsd_key: string)
    local raw = ll.LinksetDataRead(lsd_key)
    if raw == "" then return {} end
    return ll.CSV2List(raw)
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

local function btn(label: string, cmd: string): string
    return ll.List2Json(JSON_OBJECT, {"label", label, "context", cmd})
end

local function fmt_bool(raw: string): string
    if integer(raw) ~= 0 then return "ON" end
    return "OFF"
end

local function fmt_relay_mode(raw: string): string
    local m = integer(raw)
    if m == 1 then return "ON" end
    if m == 2 then return "ASK" end
    return "OFF"
end

-- Format parallel uuid/name/honorific CSVs into one block, or fallback if empty.
local function fmt_csv_person_lines(uuids_csv: string, names_csv: string, hons_csv: string, fallback_str: string): string
    if uuids_csv == "" then return fallback_str end
    local uuids = ll.CSV2List(uuids_csv)
    local names = ll.CSV2List(names_csv)
    local hons  = ll.CSV2List(hons_csv)
    if #uuids == 0 then return fallback_str end

    local block = ""
    for i = 1, #uuids do
        local p_uuid = uuids[i]
        local p_name = names[i] or ""
        local p_hon = hons[i] or ""
        if p_hon ~= "" then block = block .. "  " .. p_hon .. " " .. p_name .. " (" .. p_uuid .. ")\n"
        else block = block .. "  " .. p_name .. " (" .. p_uuid .. ")\n" end
    end
    return block
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
        "1", "Get HUD,User Manual",
        "2", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual,Reset Config,Update Collar",
        "3", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual",
        "4", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual,Reset Config,Update Collar",
        "5", "View Settings,Reload Settings,Access List,Reload Collar,Clear Leash,Get HUD,User Manual,Update Collar",
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

local function cleanup_session()
    if SessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.close", "session_id", SessionId,
        }), NULL_KEY)
    end
    CurrentUser = NULL_KEY
    CurrentUserAcl = -999
    gPolicyButtons = {}
    SessionId = ""
    MenuContext = "main"
    UpdateScanUpdater = NULL_KEY
    UpdateScanVersion = ""
end

local function return_to_root()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return", "user", tostring(CurrentUser),
    }), NULL_KEY)
    cleanup_session()
end

--[[ -------------------- MENU DISPLAY -------------------- ]]

local function show_main_menu()
    MenuContext = "main"
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, CurrentUserAcl)

    local button_data = {btn("Back", "back")}
    if btn_allowed("View Settings") then button_data[#button_data + 1] = btn("View Settings", "view_settings") end
    if btn_allowed("Reload Settings") then button_data[#button_data + 1] = btn("Reload Settings", "reload_settings") end
    if btn_allowed("Access List") then button_data[#button_data + 1] = btn("Access List", "access_list") end
    if btn_allowed("Reload Collar") then button_data[#button_data + 1] = btn("Reload Collar", "reload_collar") end
    if btn_allowed("Clear Leash") then button_data[#button_data + 1] = btn("Clear Leash", "clear_leash") end
    if btn_allowed("Get HUD") then button_data[#button_data + 1] = btn("Get HUD", "get_hud") end
    if btn_allowed("User Manual") then button_data[#button_data + 1] = btn("User Manual", "user_manual") end
    if btn_allowed("Reset Config") then button_data[#button_data + 1] = btn("Reset Config", "reset_config") end
    if btn_allowed("Update Collar") then button_data[#button_data + 1] = btn("Update Collar", "update_collar") end

    local body = "Maintenance:\n\n"
    if btn_allowed("View Settings") then body = body .. "System utilities and documentation."
    else body = body .. "Get HUD or user manual." end

    SessionId = generate_session_id()
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", "Maintenance",
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, button_data),
        "timeout", 60,
    }), NULL_KEY)
end

--[[ -------------------- ACTIONS -------------------- ]]

local function do_view_settings()
    local multi = integer(ll.LinksetDataRead("access.multiowner")) ~= 0

    local lock_str = "UNLOCKED"
    if integer(ll.LinksetDataRead("lock.locked")) ~= 0 then lock_str = "LOCKED" end

    local restr_csv = ll.LinksetDataRead("restrict.list")
    local restr_str = "none"
    if restr_csv ~= "" then restr_str = tostring(#ll.ParseString2List(restr_csv, {","}, {})) .. " active" end

    local output = "\n=== Collar Settings ===\n"

    if multi then
        local owner_block = fmt_csv_person_lines(
            ll.LinksetDataRead("access.owneruuids"),
            ll.LinksetDataRead("access.ownernames"),
            ll.LinksetDataRead("access.ownerhonorifics"), "")
        if owner_block == "" then output = output .. "Owners: Uncommitted\n"
        else output = output .. "Owners:\n" .. owner_block end
    else
        local owner_uuid = ll.LinksetDataRead("access.owner")
        if owner_uuid ~= "" then
            local p_name = ll.LinksetDataRead("access.ownername")
            local p_hon = ll.LinksetDataRead("access.ownerhonorific")
            if p_hon ~= "" then output = output .. "Owner: " .. p_hon .. " " .. p_name .. " (" .. owner_uuid .. ")\n"
            else output = output .. "Owner: " .. p_name .. " (" .. owner_uuid .. ")\n" end
        else
            output = output .. "Owner: Uncommitted\n"
        end
    end

    local trustee_block = fmt_csv_person_lines(
        ll.LinksetDataRead("access.trusteeuuids"),
        ll.LinksetDataRead("access.trusteenames"),
        ll.LinksetDataRead("access.trusteehonorifics"), "")
    if trustee_block == "" then output = output .. "Trustees: none\n"
    else output = output .. "Trustees:\n" .. trustee_block end

    output = output .. "Access: multi-owner " .. fmt_bool(ll.LinksetDataRead("access.multiowner"))
        .. " | runaway " .. fmt_bool(ll.LinksetDataRead("access.enablerunaway")) .. "\n"
    output = output .. "Lock: " .. lock_str
        .. " | public " .. fmt_bool(ll.LinksetDataRead("public.mode"))
        .. " | TPE " .. fmt_bool(ll.LinksetDataRead("tpe.mode")) .. "\n"
    output = output .. "Relay: " .. fmt_relay_mode(ll.LinksetDataRead("relay.mode"))
        .. " | hardcore " .. fmt_bool(ll.LinksetDataRead("relay.hardcoremode")) .. "\n"
    output = output .. "Owner TP/IM: " .. fmt_bool(ll.LinksetDataRead("rlvex.ownertp"))
        .. "/" .. fmt_bool(ll.LinksetDataRead("rlvex.ownerim")) .. "\n"
    output = output .. "Trustee TP/IM: " .. fmt_bool(ll.LinksetDataRead("rlvex.trusteetp"))
        .. "/" .. fmt_bool(ll.LinksetDataRead("rlvex.trusteeim")) .. "\n"
    output = output .. "Restrictions: " .. restr_str

    ll.RegionSayTo(CurrentUser, 0, output)
end

local function person_block(uuids_key: string, names_key: string, hons_key: string, default_hon: string): string
    local uuids = csv_read(uuids_key)
    local names = csv_read(names_key)
    local hons  = csv_read(hons_key)
    if #uuids == 0 then return "  (none)\n" end
    local out = ""
    for i = 1, #uuids do
        local nm = names[i] or ""
        local hn = default_hon
        if hons[i] ~= nil and hons[i] ~= "" then hn = hons[i] end
        out = out .. "  " .. hn .. " " .. nm .. " - " .. uuids[i] .. "\n"
    end
    return out
end

local function do_display_access_list()
    local output = "=== Access Control List ===\n\n"
    local multi_mode = integer(ll.LinksetDataRead("access.multiowner")) ~= 0

    if multi_mode then
        output = output .. "OWNERS:\n" .. person_block(
            "access.owneruuids", "access.ownernames", "access.ownerhonorifics", "Owner")
    else
        output = output .. "OWNER:\n"
        local owner_uuid = ll.LinksetDataRead("access.owner")
        if owner_uuid ~= "" then
            local nm = ll.LinksetDataRead("access.ownername")
            local hn = ll.LinksetDataRead("access.ownerhonorific")
            if hn == "" then hn = "Owner" end
            output = output .. "  " .. hn .. " " .. nm .. " - " .. owner_uuid .. "\n"
        else
            output = output .. "  (none)\n"
        end
    end

    output = output .. "\nTRUSTEES:\n" .. person_block(
        "access.trusteeuuids", "access.trusteenames", "access.trusteehonorifics", "Trustee")

    output = output .. "\nBLACKLISTED:\n"
    local blacklist = csv_read("blacklist.blklistuuid")
    if #blacklist > 0 then
        for _, b in ipairs(blacklist) do output = output .. "  " .. b .. "\n" end
    else
        output = output .. "  (none)\n"
    end

    ll.RegionSayTo(CurrentUser, 0, output)
end

local function show_confirm(context: string, title: string, body: string, timeout: number)
    MenuContext = context
    SessionId = generate_session_id()
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", title,
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, {btn("No", "cancel"), btn("Yes", "confirm")}),
        "timeout", timeout,
    }), NULL_KEY)
end

local function do_reset_config()
    ll.RegionSayTo(CurrentUser, 0, "Resetting configuration...")
    cleanup_session()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {"type", "settings.reset.config"}), NULL_KEY)
end

local function do_reload_settings()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, ll.List2Json(JSON_OBJECT, {"type", "settings.get"}), NULL_KEY)
    ll.RegionSayTo(CurrentUser, 0, "Settings reload requested.")
end

local function do_clear_leash()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.action", "action", "force_release",
    }), CurrentUser)
    ll.RegionSayTo(CurrentUser, 0, "Leash cleared.")
end

local function do_reload_collar()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.reset.soft", "from", "maintenance",
    }), NULL_KEY)
    ll.RegionSayTo(CurrentUser, 0, "Collar reload initiated.")
end

--[[ -------------------- UPDATE FLOW -------------------- ]]

local function do_start_update_scan()
    MenuContext = "update_scan_waiting"
    UpdateScanUpdater = NULL_KEY
    UpdateScanVersion = ""
    ll.MessageLinked(LINK_SET, REMOTE_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "remote.updaterscan.start", "user", tostring(CurrentUser),
    }), NULL_KEY)
    ll.RegionSayTo(CurrentUser, 0, "Scanning for an updater in range...")
end

local function show_update_confirm()
    MenuContext = "update_confirm"
    SessionId = generate_session_id()
    local body = "Updater found.\n\nUpdater: " .. tostring(UpdateScanUpdater) .. "\n"
        .. "Version: " .. UpdateScanVersion .. "\n\n"
        .. "Begin update? Your collar will receive new scripts."
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", "Update Collar",
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, {btn("No", "cancel"), btn("Yes", "confirm")}),
        "timeout", 60,
    }), NULL_KEY)
end

local function do_confirm_update()
    ll.MessageLinked(LINK_SET, REMOTE_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "remote.updaterscan.confirm", "updater", tostring(UpdateScanUpdater),
    }), NULL_KEY)
    ll.RegionSayTo(CurrentUser, 0, "Update started. Please leave your collar attached.")
    cleanup_session()
end

local function do_cancel_update()
    ll.MessageLinked(LINK_SET, REMOTE_BUS, ll.List2Json(JSON_OBJECT, {"type", "remote.updaterscan.cancel"}), NULL_KEY)
end

local function handle_scan_result(msg: string)
    if MenuContext ~= "update_scan_waiting" then return end

    if integer(ll.JsonGetValue(msg, {"found"})) == 0 then
        ll.RegionSayTo(CurrentUser, 0, "No updater responded. Make sure your updater object is rezzed and within 20m.")
        cleanup_session()
        return
    end

    local updater_str = ll.JsonGetValue(msg, {"updater"})
    if updater_str == JSON_INVALID then cleanup_session(); return end
    UpdateScanUpdater = uuid(updater_str)

    local ver = ll.JsonGetValue(msg, {"version"})
    if ver == JSON_INVALID then ver = "?" end
    UpdateScanVersion = ver

    show_update_confirm()
end

local function do_give_hud()
    if ll.GetInventoryType(HUD_ITEM) ~= INVENTORY_OBJECT then
        ll.RegionSayTo(CurrentUser, 0, "HUD not found in inventory.")
    else
        ll.GiveInventory(CurrentUser, HUD_ITEM)
        ll.RegionSayTo(CurrentUser, 0, "HUD sent.")
    end
end

local function do_give_manual()
    if ll.GetInventoryType(MANUAL_NOTECARD) ~= INVENTORY_NOTECARD then
        ll.RegionSayTo(CurrentUser, 0, "Manual not found in inventory.")
    else
        ll.GiveInventory(CurrentUser, MANUAL_NOTECARD)
        ll.RegionSayTo(CurrentUser, 0, "Manual sent.")
    end
end

--[[ -------------------- DIALOG HANDLER -------------------- ]]

local function handle_dialog_response(msg: string)
    if ll.JsonGetValue(msg, {"session_id"}) == JSON_INVALID then return end
    if ll.JsonGetValue(msg, {"button"}) == JSON_INVALID then return end
    if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end

    local cmd = ll.JsonGetValue(msg, {"context"})
    if cmd == JSON_INVALID then cmd = "" end

    if cmd == "back" then
        if MenuContext ~= "main" then show_main_menu() else return_to_root() end
        return
    end

    if MenuContext == "reset_config" then
        if cmd == "confirm" then do_reset_config() else show_main_menu() end
        return
    end
    if MenuContext == "clear_leash" then
        if cmd == "confirm" then do_clear_leash() else show_main_menu() end
        return
    end
    if MenuContext == "update_confirm" then
        if cmd == "confirm" then do_confirm_update()
        else do_cancel_update(); show_main_menu() end
        return
    end

    if cmd == "view_settings" then do_view_settings(); show_main_menu()
    elseif cmd == "access_list" then do_display_access_list(); show_main_menu()
    elseif cmd == "reload_settings" then do_reload_settings(); show_main_menu()
    elseif cmd == "clear_leash" then show_confirm("clear_leash", "Clear Leash",
        "Force-release the current leash?\n\nThis bypasses normal permission checks and clears any leash, including one held by a bad actor.\n\nAre you sure?", 30)
    elseif cmd == "reload_collar" then do_reload_collar(); show_main_menu()
    elseif cmd == "get_hud" then do_give_hud(); show_main_menu()
    elseif cmd == "user_manual" then do_give_manual(); show_main_menu()
    elseif cmd == "reset_config" then show_confirm("reset_config", "Reset Config",
        "This will reset all settings except for ownership and lock state.\n\nIf you need out of an abusive collar, please use Runaway.", 30)
    elseif cmd == "update_collar" then do_start_update_scan()
    end
end

local function handle_dialog_timeout(msg: string)
    local session = ll.JsonGetValue(msg, {"session_id"})
    if session == JSON_INVALID then return end
    if session ~= SessionId then return end
    cleanup_session()
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
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    if num == KERNEL_LIFECYCLE then
        local msg_type = ll.JsonGetValue(msg, {"type"})
        if msg_type == JSON_INVALID then return end
        if msg_type == "kernel.register.refresh" then register_self()
        elseif msg_type == "kernel.ping" then send_pong()
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

    if num == REMOTE_BUS then
        if ll.JsonGetValue(msg, {"type"}) == "remote.updaterscan.result" then
            handle_scan_result(msg)
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
            CurrentUserAcl = integer(ll.JsonGetValue(msg, {"acl"}))
            show_main_menu()
        end
        return
    end

    if num == DIALOG_BUS then
        local msg_type = ll.JsonGetValue(msg, {"type"})
        if msg_type == JSON_INVALID then return end
        if msg_type == "ui.dialog.response" then
            handle_dialog_response(msg)
        elseif msg_type == "ui.dialog.timeout" then
            handle_dialog_timeout(msg)
        elseif msg_type == "ui.dialog.close" then
            local session = ll.JsonGetValue(msg, {"session_id"})
            if session ~= JSON_INVALID and session == SessionId then
                -- Externally closed; drop session without re-closing.
                CurrentUser = NULL_KEY
                CurrentUserAcl = -999
                gPolicyButtons = {}
                SessionId = ""
            end
        end
        return
    end
end

-- Top-level init.
main()

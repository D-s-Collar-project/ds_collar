--[[--------------------
PLUGIN: plugin_leash.lua  (SLua port)
VERSION: 1.10
PURPOSE: Leash UI shell — main menu, settings (length/turn/texture/enhanced),
         Get Holder, and delegation to the avatar/object sub-plugins. The leash
         engine is kmod_leash_engine; this drives the menu + local enhanced mode.
ARCHITECTURE: Consolidated message bus lanes.

SLUA PORT NOTES:
- Ported from plugin_leash.lsl. plugin.leash.action/.state wire, the sub-plugin
  delegation (ui.menu.start + subpath), settings.delta CSV for leash.enhanced,
  and the local enhanced RLV (@sittp,... via ll.OwnerSay) are unchanged.
- SLua conventions: LLEvents.* handlers, local main(); booleans for the flags.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.leash"
local PLUGIN_LABEL = "Leash"

local STATE_QUERY_DELAY = 0.5

--[[ -------------------- STATE -------------------- ]]
local Leashed = false
local Leasher = NULL_KEY
local LeashLength = 3
local TurnToFace = false
local LeashTexture = "chain"
local EnhancedMode = true     -- ON by default — a leash should restrain
local EnhancedApplied = true  -- idempotence guard; TRUE so first sync clears stale
local LeashMode = 0           -- 0 avatar, 1 coffle, 2 post
local LeashTarget = NULL_KEY

local CurrentUser = NULL_KEY
local UserAcl = -999
local gPolicyButtons = {}
local SessionId = ""
local MenuContext = ""

local PendingStateQuery = false
local PendingQueryContext = ""

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

local function b2i(b: boolean): number
    if b then return 1 end
    return 0
end

local function list_find(t, v)
    for i, x in ipairs(t) do
        if x == v then return i end
    end
    return nil
end

local function generate_session_id(): string
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
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
        final_buttons[slots[i] + 1] = item_buttons[i]
    end
    return final_buttons
end

local function showMenu(context: string, title: string, body: string, button_data)
    SessionId = generate_session_id()
    MenuContext = context
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", title,
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, button_data),
        "timeout", 60,
    }), NULL_KEY)
end

--[[ -------------------- REGISTRATION -------------------- ]]

local function write_plugin_reg(label: string)
    local k = "plugin.reg." .. PLUGIN_CONTEXT
    local v = ll.List2Json(JSON_OBJECT, {"label", label, "script", ll.GetScriptName()})
    if ll.LinksetDataRead(k) == v then return end
    ll.LinksetDataWrite(k, v)
end

local function register_self()
    ll.LinksetDataWrite("acl.policycontext:" .. PLUGIN_CONTEXT, ll.List2Json(JSON_OBJECT, {
        "1", "Clip,Unclip,Coffle,Post,Get Holder,Settings",
        "2", "Offer",
        "3", "Clip,Unclip,Pass,Yank,Take,Coffle,Post,Get Holder,Settings",
        "4", "Clip,Unclip,Pass,Yank,Coffle,Post,Get Holder,Settings",
        "5", "Clip,Unclip,Pass,Yank,Take,Coffle,Post,Get Holder,Settings",
    }))
    write_plugin_reg(PLUGIN_LABEL)
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", ll.GetScriptName(),
    }), NULL_KEY)
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "chat.alias.declare", "alias", "leash", "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

local function send_pong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

--[[ -------------------- MENUS -------------------- ]]

local function showMainMenu()
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl)

    local nav_buttons = {btn("Back", "back")}
    local item_buttons = {}

    if not Leashed then
        if btn_allowed("Clip") then item_buttons[#item_buttons + 1] = btn("Clip", "clip") end
        if btn_allowed("Offer") then item_buttons[#item_buttons + 1] = btn("Offer", "offer") end
        if btn_allowed("Coffle") then item_buttons[#item_buttons + 1] = btn("Coffle", "coffle") end
        if btn_allowed("Post") then item_buttons[#item_buttons + 1] = btn("Post", "post") end
    else
        if btn_allowed("Unclip") and (CurrentUser == Leasher or UserAcl >= 3) then
            item_buttons[#item_buttons + 1] = btn("Unclip", "unclip")
        end
        if CurrentUser == Leasher then
            if btn_allowed("Pass") then item_buttons[#item_buttons + 1] = btn("Pass", "pass") end
            if btn_allowed("Yank") then item_buttons[#item_buttons + 1] = btn("Yank", "yank") end
        end
        if btn_allowed("Take") and CurrentUser ~= Leasher and UserAcl >= 3 then
            item_buttons[#item_buttons + 1] = btn("Take", "clip")
        end
    end

    if btn_allowed("Get Holder") then item_buttons[#item_buttons + 1] = btn("Get Holder", "get_holder") end
    if btn_allowed("Settings") then item_buttons[#item_buttons + 1] = btn("Settings", "settings") end

    local body
    if Leashed then
        local mode_text = "Avatar"
        if LeashMode == 1 then mode_text = "Coffle"
        elseif LeashMode == 2 then mode_text = "Post" end
        body = "Mode: " .. mode_text .. "\nLeashed to: " .. ll.Key2Name(Leasher) .. "\nLength: " .. tostring(LeashLength) .. "m"
        if LeashTarget ~= NULL_KEY then
            local details = ll.GetObjectDetails(LeashTarget, {OBJECT_NAME})
            if #details > 0 then body = body .. "\nTarget: " .. details[1] end
        end
    else
        body = "Not leashed"
    end

    showMenu("main", "Leash", body, reorder_item_buttons(nav_buttons, item_buttons))
end

local function showSettingsMenu()
    local nav_buttons = {btn("Back", "back")}
    local item_buttons = {btn("Length", "length")}
    if TurnToFace then item_buttons[#item_buttons + 1] = btn("Turn: On", "toggle_turn")
    else item_buttons[#item_buttons + 1] = btn("Turn: Off", "toggle_turn") end
    item_buttons[#item_buttons + 1] = btn("Texture", "texture")

    if UserAcl >= 3 then
        if EnhancedMode then item_buttons[#item_buttons + 1] = btn("Enhance: Y", "toggle_enhanced")
        else item_buttons[#item_buttons + 1] = btn("Enhance: N", "toggle_enhanced") end
    end

    local texture_label = "Chain"
    if LeashTexture == "silk" then texture_label = "Silk"
    elseif LeashTexture == "invisible" then texture_label = "Invisible" end

    local turn_state = "Disabled"
    if TurnToFace then turn_state = "Enabled" end

    local body = "Leash Settings\nLength: " .. tostring(LeashLength)
        .. "m\nTurn to leasher: " .. turn_state .. "\nTexture: " .. texture_label
    if UserAcl >= 3 then
        local enh_state = "Disabled"
        if EnhancedMode then enh_state = "Enabled" end
        body = body .. "\nEnhanced mode: " .. enh_state
    end

    showMenu("settings", "Settings", body, reorder_item_buttons(nav_buttons, item_buttons))
end

local function showTextureMenu()
    local current = "Chain"
    if LeashTexture == "silk" then current = "Silk"
    elseif LeashTexture == "invisible" then current = "Invisible" end

    local nav_buttons = {btn("Back", "back")}
    local item_buttons = {btn("Chain", "chain"), btn("Silk", "silk"), btn("Invisible", "invisible")}
    showMenu("texture", "Texture", "Select leash texture\nCurrent: " .. current,
        reorder_item_buttons(nav_buttons, item_buttons))
end

local function showLengthMenu()
    local nav_buttons = {btn("<<", "prev"), btn(">>", "next"), btn("Back", "back")}
    local item_buttons = {
        btn("1m", "1"), btn("3m", "3"), btn("5m", "5"),
        btn("10m", "10"), btn("15m", "15"), btn("20m", "20"),
    }
    showMenu("length", "Length", "Select leash length\nCurrent: " .. tostring(LeashLength) .. "m",
        reorder_item_buttons(nav_buttons, item_buttons))
end

--[[ -------------------- DELEGATION / ACTIONS -------------------- ]]

local function delegateTo(sub_context: string, subpath: string)
    if SessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.close", "session_id", SessionId,
        }), NULL_KEY)
        SessionId = ""
    end
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.start",
        "context", sub_context,
        "acl", UserAcl,
        "subpath", subpath,
    }), CurrentUser)
    MenuContext = ""
end

local function giveHolderObject()
    if not btn_allowed("Get Holder") then
        ll.RegionSayTo(CurrentUser, 0, "Access denied: Insufficient permissions to receive leash holder.")
        return
    end
    local wanted = "leash holder"
    local holder_name = ""
    local count = ll.GetInventoryNumber(INVENTORY_OBJECT)
    for i = 1, count do  -- SLua inventory is 1-based
        local nm = ll.GetInventoryName(INVENTORY_OBJECT, i)
        if string.lower(ll.StringTrim(nm, STRING_TRIM)) == wanted then holder_name = nm; break end
    end
    if holder_name == "" then
        ll.RegionSayTo(CurrentUser, 0, "Error: Leash holder object not found in collar inventory.")
        return
    end
    ll.GiveInventory(CurrentUser, holder_name)
    ll.RegionSayTo(CurrentUser, 0, "Leash holder given.")
end

local function sendLeashAction(action: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.action", "action", action,
    }), CurrentUser)
end

local function sendLeashActionWithTarget(action: string, target)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.action", "action", action, "target", tostring(target),
    }), CurrentUser)
end

local function sendSetLength(length: number)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.action", "action", "set_length", "length", tostring(length),
    }), CurrentUser)
end

-- Enhanced TP/sit restrictions applied locally, following the leash
-- (active only while EnhancedMode AND Leashed). Idempotent via EnhancedApplied.
local function sync_enhanced()
    local want = EnhancedMode and Leashed
    if want and not EnhancedApplied then
        ll.OwnerSay("@sittp=n,tploc=n,tplm=n,tplure=n")
        EnhancedApplied = true
    elseif not want and EnhancedApplied then
        ll.OwnerSay("@sittp=y,tploc=y,tplm=y,tplure=y")
        EnhancedApplied = false
    end
end

local function persist_enhanced()
    ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delta:leash.enhanced:" .. tostring(b2i(EnhancedMode)), NULL_KEY)
end

local function load_enhanced()
    local v = ll.LinksetDataRead("leash.enhanced")
    EnhancedMode = true  -- default ON
    if v ~= "" then EnhancedMode = integer(v) ~= 0 end
    sync_enhanced()
end

--[[ -------------------- SESSION / STATE QUERY -------------------- ]]

local function cleanupSession()
    if SessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.close", "session_id", SessionId,
        }), NULL_KEY)
    end
    CurrentUser = NULL_KEY
    UserAcl = -999
    gPolicyButtons = {}
    SessionId = ""
    MenuContext = ""
end

local function queryState()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.action", "action", "query_state",
    }), NULL_KEY)
end

local function scheduleStateQuery(next_menu_context: string)
    PendingStateQuery = true
    PendingQueryContext = next_menu_context
    set_timer(STATE_QUERY_DELAY)
end

--[[ -------------------- CHAT SUBCOMMANDS -------------------- ]]

local function handle_subpath(user, acl_level: number, subpath: string)
    CurrentUser = user
    UserAcl = acl_level

    local tokens = ll.ParseString2List(subpath, {"."}, {})
    if #tokens == 0 then return end
    local action = tokens[1]

    if action == "clip" then sendLeashAction("grab")
    elseif action == "unclip" then sendLeashAction("release")
    elseif action == "turn" then sendLeashAction("toggle_turn")
    elseif action == "yank" then sendLeashAction("yank")
    elseif action == "length" then
        if #tokens < 2 then ll.RegionSayTo(user, 0, "Usage: leash length <meters>"); return end
        local len = integer(tokens[2])
        if len < 1 then ll.RegionSayTo(user, 0, "Length must be at least 1 meter."); return end
        sendSetLength(len)
    elseif action == "pass" then
        if #tokens < 2 then ll.RegionSayTo(user, 0, "Usage: leash pass <username>"); return end
        local tail = {}
        for i = 2, #tokens do tail[#tail + 1] = tokens[i] end
        local username = ll.DumpList2String(tail, ".")
        local target = ll.Name2Key(username)
        if target == NULL_KEY then ll.RegionSayTo(user, 0, "User not found in sim: " .. username); return end
        sendLeashActionWithTarget("pass", target)
    elseif action == "coffle" then delegateTo("ui.core.leash.avatar", "coffle")
    elseif action == "post" then delegateTo("ui.core.leash.object", "post")
    else ll.RegionSayTo(user, 0, "Unknown leash subcommand: " .. action) end
end

--[[ -------------------- BUTTON HANDLER -------------------- ]]

local function handleButtonClick(ctx: string)
    if MenuContext == "main" then
        if ctx == "clip" then sendLeashAction("grab"); cleanupSession()
        elseif ctx == "unclip" then sendLeashAction("release"); cleanupSession()
        elseif ctx == "pass" then delegateTo("ui.core.leash.avatar", "pass")
        elseif ctx == "offer" then delegateTo("ui.core.leash.avatar", "offer")
        elseif ctx == "coffle" then delegateTo("ui.core.leash.avatar", "coffle")
        elseif ctx == "post" then delegateTo("ui.core.leash.object", "post")
        elseif ctx == "yank" then sendLeashAction("yank"); cleanupSession()
        elseif ctx == "get_holder" then giveHolderObject(); cleanupSession()
        elseif ctx == "settings" then showSettingsMenu()
        elseif ctx == "back" then
            ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
                "type", "ui.menu.return", "user", tostring(CurrentUser),
            }), NULL_KEY)
            cleanupSession()
        end
    elseif MenuContext == "settings" then
        if ctx == "length" then showLengthMenu()
        elseif ctx == "toggle_turn" then sendLeashAction("toggle_turn"); scheduleStateQuery("settings")
        elseif ctx == "toggle_enhanced" then
            if UserAcl >= 3 then
                EnhancedMode = not EnhancedMode
                sync_enhanced()
                persist_enhanced()
            end
            showSettingsMenu()
        elseif ctx == "texture" then showTextureMenu()
        elseif ctx == "back" then showMainMenu() end
    elseif MenuContext == "texture" then
        if ctx == "back" then showSettingsMenu()
        elseif ctx == "chain" or ctx == "silk" or ctx == "invisible" then
            ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
                "type", "plugin.leash.action", "action", "set_texture", "texture", ctx,
            }), CurrentUser)
            scheduleStateQuery("settings")
        end
    elseif MenuContext == "length" then
        if ctx == "back" then showSettingsMenu()
        elseif ctx == "prev" then sendSetLength(LeashLength - 1); scheduleStateQuery("length")
        elseif ctx == "next" then sendSetLength(LeashLength + 1); scheduleStateQuery("length")
        else
            local sel_length = integer(ctx)
            if sel_length >= 1 and sel_length <= 20 then
                sendSetLength(sel_length)
                scheduleStateQuery("settings")
            end
        end
    end
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
    cleanupSession()
    register_self()
    load_enhanced()
    queryState()
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

_on_timer = function()
    if PendingStateQuery then
        PendingStateQuery = false
        set_timer(0.0)
        queryState()
    end
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

    if num == SETTINGS_BUS then
        if ll.JsonGetValue(msg, {"type"}) == "settings.sync" then load_enhanced() end
        return
    end

    if num == UI_BUS then
        local msg_type = ll.JsonGetValue(msg, {"type"})
        if msg_type == JSON_INVALID then return end

        if msg_type == "sos.leash.release" then
            if id == ll.GetOwner() then
                Leashed = false
                sync_enhanced()
            end
            return
        end

        if msg_type == "ui.menu.start" then
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) == JSON_INVALID then return end
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
            scheduleStateQuery("main")
            return
        end

        if msg_type == "plugin.leash.state" then
            local tmp = ll.JsonGetValue(msg, {"leashed"})
            if tmp ~= JSON_INVALID then Leashed = integer(tmp) ~= 0 end
            tmp = ll.JsonGetValue(msg, {"leasher"})
            if tmp ~= JSON_INVALID then Leasher = uuid(tmp) end
            tmp = ll.JsonGetValue(msg, {"length"})
            if tmp ~= JSON_INVALID then LeashLength = integer(tmp) end
            tmp = ll.JsonGetValue(msg, {"turnto"})
            if tmp ~= JSON_INVALID then TurnToFace = integer(tmp) ~= 0 end
            tmp = ll.JsonGetValue(msg, {"texture"})
            if tmp ~= JSON_INVALID then LeashTexture = tmp end
            sync_enhanced()
            tmp = ll.JsonGetValue(msg, {"mode"})
            if tmp ~= JSON_INVALID then LeashMode = integer(tmp) end
            tmp = ll.JsonGetValue(msg, {"target"})
            if tmp ~= JSON_INVALID then LeashTarget = uuid(tmp) end

            if PendingQueryContext ~= "" then
                local menu_to_show = PendingQueryContext
                PendingQueryContext = ""
                if menu_to_show == "settings" then showSettingsMenu()
                elseif menu_to_show == "length" then showLengthMenu()
                elseif menu_to_show == "main" then showMainMenu() end
            end
            return
        end
        return
    end

    if num == DIALOG_BUS then
        local msg_type = ll.JsonGetValue(msg, {"type"})
        if msg_type == JSON_INVALID then return end
        if msg_type == "ui.dialog.response" then
            if ll.JsonGetValue(msg, {"session_id"}) == JSON_INVALID or ll.JsonGetValue(msg, {"context"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
            handleButtonClick(ll.JsonGetValue(msg, {"context"}))
        elseif msg_type == "ui.dialog.timeout" then
            if ll.JsonGetValue(msg, {"session_id"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
            cleanupSession()
        end
        return
    end
end

-- Top-level init.
main()

--[[--------------------
PLUGIN: plugin_leash_avatar.lua  (SLua port)
VERSION: 1.10
REVISION: 3  (SLua port rev 1)
PURPOSE: Sub-plugin for avatar-target leash flows — Clip / Pass / Offer / Coffle,
         plus the offer-reception accept/decline dialog.
ARCHITECTURE: Hidden helper of plugin_leash (no plugin.reg.*). Receives
              ui.menu.start (context "ui.core.leash.avatar" + subpath).

SLUA PORT NOTES:
- Ported from plugin_leash_avatar.lsl rev 3. UI_BUS / DIALOG_BUS JSON wire and
  plugin.leash.action / .offer.pending are unchanged.
- Idiomatic SLua: avatar candidates are {name,key} records (sorted with
  table.sort); the slot-mapping layout helper is preserved.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT        = "ui.core.leash.avatar"
local PARENT_PLUGIN_CONTEXT = "ui.core.leash"

--[[ -------------------- STATE -------------------- ]]
local CurrentUser = NULL_KEY
local UserAcl = -999
local SessionId = ""
local MenuContext = ""
local SensorCandidates = {}  -- array of { name, key }
local SensorPage = 0

local OfferDialogSession = ""
local OfferTarget = NULL_KEY
local OfferOriginator = NULL_KEY

--[[ -------------------- HELPERS -------------------- ]]

local function generate_session_id(): string
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
end

local function btn(label: string, cmd: string): string
    return ll.List2Json(JSON_OBJECT, {"label", label, "context", cmd})
end

local function dialogTitleForContext(ctx: string): string
    if ctx == "pass" then return "Pass Leash" end
    if ctx == "offer" then return "Offer Leash" end
    if ctx == "coffle" then return "Coffle" end
    return ""
end

-- Canonical layout: 3 nav in cells 0-2, items slot-mapped top-to-bottom.
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
        final[slots[i] + 1] = item_buttons[i]
    end
    return final
end

--[[ -------------------- AVATAR PICKER -------------------- ]]

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

local function renderAvatarPickerPage(page: number)
    local total = #SensorCandidates
    local total_pages = (total + 8) // 9
    if total_pages < 1 then total_pages = 1 end
    if page < 0 then page = 0 end
    if page >= total_pages then page = total_pages - 1 end
    SensorPage = page

    local start = page * 9  -- 0-based
    local end_idx = start + 9
    if end_idx > total then end_idx = total end

    local nav_buttons = {btn("<<", "prev"), btn(">>", "next"), btn("Back", "back")}
    local item_buttons = {}
    for i = start, end_idx - 1 do
        local avatar_name = SensorCandidates[i + 1].name
        item_buttons[#item_buttons + 1] = btn(avatar_name, "sel:" .. avatar_name)
    end
    local button_data = reorder_item_buttons(nav_buttons, item_buttons)

    local body = "Select avatar:"
    if total_pages > 1 then
        body = body .. "\n\nPage " .. tostring(page + 1) .. "/" .. tostring(total_pages)
    end

    SessionId = generate_session_id()
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", dialogTitleForContext(MenuContext),
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, button_data),
        "timeout", 60,
    }), NULL_KEY)
end

local function showAvatarPicker(action_name: string)
    MenuContext = action_name

    local nearby = ll.GetAgentList(AGENT_LIST_PARCEL, {})
    local wearer = ll.GetOwner()

    local buf = {}
    for _, detected in ipairs(nearby) do
        if detected ~= wearer then
            buf[#buf + 1] = { name = ll.Key2Name(detected), key = detected }
        end
    end
    SensorCandidates = buf

    table.sort(SensorCandidates, function(a, b) return a.name < b.name end)

    if #SensorCandidates == 0 then
        ll.RegionSayTo(CurrentUser, 0, "No nearby avatars found.")
        cleanupSession()
        return
    end
    renderAvatarPickerPage(0)
end

--[[ -------------------- ACTIONS -------------------- ]]

local function sendAction(action: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.action",
        "action", action,
    }), CurrentUser)
end

local function sendActionWithTarget(action: string, target)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "plugin.leash.action",
        "action", action,
        "target", tostring(target),
    }), CurrentUser)
end

--[[ -------------------- OFFER RECEPTION DIALOG -------------------- ]]

local function showOfferDialog(target, originator)
    OfferDialogSession = generate_session_id()
    OfferTarget = target
    OfferOriginator = originator

    local offerer_name = ll.Key2Name(originator)
    local wearer_name = ll.Key2Name(ll.GetOwner())

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", OfferDialogSession,
        "user", tostring(target),
        "title", "Leash Offer",
        "body", offerer_name .. " (" .. wearer_name .. ") is offering you their leash.",
        "button_data", ll.List2Json(JSON_ARRAY, {btn("Accept", "accept"), btn("Decline", "decline")}),
        "timeout", 60,
    }), NULL_KEY)
end

local function handleOfferResponse(ctx: string)
    if ctx == "accept" then
        ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "plugin.leash.action",
            "action", "grab",
        }), OfferTarget)
        ll.RegionSayTo(OfferOriginator, 0, ll.Key2Name(OfferTarget) .. " accepted your leash offer.")
    else
        ll.RegionSayTo(OfferOriginator, 0, ll.Key2Name(OfferTarget) .. " declined your leash offer.")
        ll.RegionSayTo(OfferTarget, 0, "You declined the leash offer.")
    end
    OfferDialogSession = ""
    OfferTarget = NULL_KEY
    OfferOriginator = NULL_KEY
end

--[[ -------------------- NAVIGATION -------------------- ]]

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
    if subpath == "clip" then
        sendAction("grab")
        cleanupSession()
    elseif subpath == "pass" then
        showAvatarPicker("pass")
    elseif subpath == "offer" then
        showAvatarPicker("offer")
    elseif subpath == "coffle" then
        showAvatarPicker("coffle")
    else
        cleanupSession()
    end
end

local function handlePickerClick(ctx: string, clicked_btn: string)
    if ctx == "back" then
        returnToParent()
        return
    end

    local total_pages = (#SensorCandidates + 8) // 9
    if total_pages < 1 then total_pages = 1 end

    if ctx == "prev" then
        if SensorPage == 0 then renderAvatarPickerPage(total_pages - 1)
        else renderAvatarPickerPage(SensorPage - 1) end
        return
    end
    if ctx == "next" then
        if SensorPage >= total_pages - 1 then renderAvatarPickerPage(0)
        else renderAvatarPickerPage(SensorPage + 1) end
        return
    end

    -- Avatar selection: the clicked label is the avatar name.
    local selected = NULL_KEY
    for _, c in ipairs(SensorCandidates) do
        if c.name == clicked_btn then selected = c.key; break end
    end

    if selected ~= NULL_KEY then
        sendActionWithTarget(MenuContext, selected)  -- MenuContext = action verb
        cleanupSession()
    else
        ll.RegionSayTo(CurrentUser, 0, "Avatar not found.")
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
    OfferDialogSession = ""
    OfferTarget = NULL_KEY
    OfferOriginator = NULL_KEY
    -- No plugin.reg.* — hidden from kmod_ui's top menu.
end

function LLEvents.on_rez(start_param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
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
            return
        end

        if msg_type == "plugin.leash.offer.pending" then
            if ll.JsonGetValue(msg, {"target"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"originator"}) == JSON_INVALID then return end
            showOfferDialog(uuid(ll.JsonGetValue(msg, {"target"})), uuid(ll.JsonGetValue(msg, {"originator"})))
            return
        end
        return
    end

    if num == DIALOG_BUS then
        if msg_type == "ui.dialog.response" then
            local resp_session = ll.JsonGetValue(msg, {"session_id"})
            if resp_session == JSON_INVALID then return end
            local ctx = ll.JsonGetValue(msg, {"context"})
            if ctx == JSON_INVALID then ctx = "" end
            local clicked_btn = ll.JsonGetValue(msg, {"button"})
            if clicked_btn == JSON_INVALID then clicked_btn = "" end

            if resp_session == OfferDialogSession then
                handleOfferResponse(ctx)
            elseif resp_session == SessionId then
                handlePickerClick(ctx, clicked_btn)
            end
            return
        end
        if msg_type == "ui.dialog.timeout" then
            local to_session = ll.JsonGetValue(msg, {"session_id"})
            if to_session == JSON_INVALID then return end
            if to_session == OfferDialogSession then
                if OfferOriginator ~= NULL_KEY then
                    ll.RegionSayTo(OfferOriginator, 0, "Leash offer to " .. ll.Key2Name(OfferTarget) .. " timed out.")
                end
                OfferDialogSession = ""
                OfferTarget = NULL_KEY
                OfferOriginator = NULL_KEY
            elseif to_session == SessionId then
                cleanupSession()
            end
        end
    end
end

-- Top-level init.
main()

--[[--------------------
PLUGIN: plugin_rlvex.lua  (SLua port)
VERSION: 1.10
PURPOSE: Manage RLV exceptions (TP/IM) for owners and trustees
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility

SLUA PORT NOTES:
- Ported from plugin_rlvex.lsl. RLV @accepttp/@tplure/@sendim/@recvim emission
  (via ll.OwnerSay), settings.delta CSV writes, and LSD contracts unchanged.
- Idiomatic SLua: exception flags + owner/trustee lists are booleans/arrays;
  the list-changed checks use a lists_equal helper.
----------------------]]

--[[ -------------------- ISP CHANNELS -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.rlv_exceptions"
local PLUGIN_LABEL = "Exceptions"

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_EX_OWNER_TP    = "rlvex.ownertp"
local KEY_EX_OWNER_IM    = "rlvex.ownerim"
local KEY_EX_TRUSTEE_TP  = "rlvex.trusteetp"
local KEY_EX_TRUSTEE_IM  = "rlvex.trusteeim"
local KEY_OWNER          = "access.owner"
local KEY_OWNER_UUIDS    = "access.owneruuids"
local KEY_TRUSTEE_UUIDS  = "access.trusteeuuids"
local KEY_MULTI_OWNER_MODE = "access.multiowner"

--[[ -------------------- STATE -------------------- ]]
local ExOwnerTp = true
local ExOwnerIm = true
local ExTrusteeTp = false
local ExTrusteeIm = false

local OwnerKey = NULL_KEY
local OwnerKeys = {}
local TrusteeKeys = {}
local MultiOwnerMode = false

local CurrentUser = NULL_KEY
local UserAcl = -999
local gPolicyButtons = {}
local SessionId = ""
local MenuContext = ""

local PendingReconcile = false

--[[ -------------------- HELPERS -------------------- ]]

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

local function lists_equal(a, b): boolean
    if #a ~= #b then return false end
    for i = 1, #a do
        if a[i] ~= b[i] then return false end
    end
    return true
end

local function starts_with(s: string, prefix: string): boolean
    return string.sub(s, 1, #prefix) == prefix
end

local function btn(label: string, cmd: string): string
    return ll.List2Json(JSON_OBJECT, {"label", label, "context", cmd})
end

local function lsd_bool(lsd_key: string, fallback: boolean): boolean
    local v = ll.LinksetDataRead(lsd_key)
    if v == "" then return fallback end
    return integer(v) ~= 0
end

local function gen_session(): string
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

--[[ -------------------- RLV COMMANDS -------------------- ]]

local function apply_tp_exception(k, allow: boolean)
    if k == NULL_KEY then return end
    local op = "=rem"
    if allow then op = "=add" end
    ll.OwnerSay("@accepttp:" .. tostring(k) .. op .. ",tplure:" .. tostring(k) .. op)
end

local function apply_im_exception(k, allow: boolean)
    if k == NULL_KEY then return end
    local op = "=rem"
    if allow then op = "=add" end
    ll.OwnerSay("@sendim:" .. tostring(k) .. op .. ",recvim:" .. tostring(k) .. op)
end

local function reconcile_all()
    local has_owners = (MultiOwnerMode and #OwnerKeys > 0) or (not MultiOwnerMode and OwnerKey ~= NULL_KEY)
    local has_trustees = #TrusteeKeys > 0
    if not has_owners and not has_trustees then return end

    if MultiOwnerMode then
        for _, s in ipairs(OwnerKeys) do
            apply_tp_exception(uuid(s), ExOwnerTp)
            apply_im_exception(uuid(s), ExOwnerIm)
        end
    else
        apply_tp_exception(OwnerKey, ExOwnerTp)
        apply_im_exception(OwnerKey, ExOwnerIm)
    end

    for _, s in ipairs(TrusteeKeys) do
        apply_tp_exception(uuid(s), ExTrusteeTp)
        apply_im_exception(uuid(s), ExTrusteeIm)
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
        "3", "Owner,Trustee,TP,IM",
        "4", "Owner,Trustee,TP,IM",
        "5", "Owner,Trustee,TP,IM",
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

local function persist_setting(setting_key: string, value: boolean)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" .. setting_key .. ":" .. tostring(b2i(value)), NULL_KEY)
end

--[[ -------------------- SETTINGS -------------------- ]]

local function apply_settings_sync()
    local prev_owner = OwnerKey
    local prev_owners = OwnerKeys
    local prev_trustees = TrusteeKeys
    local prev_ex_otp = ExOwnerTp
    local prev_ex_oim = ExOwnerIm
    local prev_ex_ttp = ExTrusteeTp
    local prev_ex_tim = ExTrusteeIm
    local prev_multi = MultiOwnerMode

    OwnerKey = NULL_KEY
    OwnerKeys = {}
    TrusteeKeys = {}
    MultiOwnerMode = false

    ExOwnerTp = lsd_bool(KEY_EX_OWNER_TP, true)
    ExOwnerIm = lsd_bool(KEY_EX_OWNER_IM, true)
    ExTrusteeTp = lsd_bool(KEY_EX_TRUSTEE_TP, false)
    ExTrusteeIm = lsd_bool(KEY_EX_TRUSTEE_IM, false)

    local tmp = ll.LinksetDataRead(KEY_MULTI_OWNER_MODE)
    if tmp ~= "" then MultiOwnerMode = integer(tmp) ~= 0 end

    if MultiOwnerMode then
        local raw = ll.LinksetDataRead(KEY_OWNER_UUIDS)
        if raw ~= "" then OwnerKeys = ll.CSV2List(raw) end
    else
        local raw = ll.LinksetDataRead(KEY_OWNER)
        if raw ~= "" then OwnerKey = uuid(raw) end
    end

    local trustees_raw = ll.LinksetDataRead(KEY_TRUSTEE_UUIDS)
    if trustees_raw ~= "" then TrusteeKeys = ll.CSV2List(trustees_raw) end

    -- Auto-initialize owner exceptions if owners exist but keys are absent.
    local owners_exist = (MultiOwnerMode and #OwnerKeys > 0) or (not MultiOwnerMode and OwnerKey ~= NULL_KEY)
    if owners_exist then
        if ll.LinksetDataRead(KEY_EX_OWNER_TP) == "" then persist_setting(KEY_EX_OWNER_TP, true) end
        if ll.LinksetDataRead(KEY_EX_OWNER_IM) == "" then persist_setting(KEY_EX_OWNER_IM, true) end
    end

    local need_reconcile = false
    if ExOwnerTp ~= prev_ex_otp or ExOwnerIm ~= prev_ex_oim
        or ExTrusteeTp ~= prev_ex_ttp or ExTrusteeIm ~= prev_ex_tim
        or MultiOwnerMode ~= prev_multi then
        need_reconcile = true
    end

    if OwnerKey ~= prev_owner then
        if prev_owner ~= NULL_KEY then
            apply_tp_exception(prev_owner, false)
            apply_im_exception(prev_owner, false)
        end
        need_reconcile = true
    end

    if not lists_equal(OwnerKeys, prev_owners) then
        for _, s in ipairs(prev_owners) do
            apply_tp_exception(uuid(s), false)
            apply_im_exception(uuid(s), false)
        end
        need_reconcile = true
    end

    if not lists_equal(TrusteeKeys, prev_trustees) then
        for _, s in ipairs(prev_trustees) do
            apply_tp_exception(uuid(s), false)
            apply_im_exception(uuid(s), false)
        end
        need_reconcile = true
    end

    if need_reconcile then
        PendingReconcile = true
        ll.SetTimerEvent(1.0)
    end
end

--[[ -------------------- MENUS -------------------- ]]

local function show_main()
    SessionId = gen_session()
    MenuContext = "main"
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl)

    local body = "RLV Exceptions\n\nManage which restrictions can be bypassed by owners and trustees."
    local button_data = {btn("Back", "back")}
    if btn_allowed("Owner") then button_data[#button_data + 1] = btn("Owner", "owner") end
    if btn_allowed("Trustee") then button_data[#button_data + 1] = btn("Trustee", "trustee") end

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

local function show_role_menu(role: string, ex_tp: boolean, ex_im: boolean, ctx: string)
    SessionId = gen_session()
    MenuContext = ctx

    local body = role .. " Exceptions\n\nCurrent settings:\n"
    if ex_tp then body = body .. "TP: Allowed\n" else body = body .. "TP: Denied\n" end
    if ex_im then body = body .. "IM: Allowed" else body = body .. "IM: Denied" end

    local button_data = {btn("Back", "back")}
    if btn_allowed("TP") then button_data[#button_data + 1] = btn("TP", "tp") end
    if btn_allowed("IM") then button_data[#button_data + 1] = btn("IM", "im") end

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", role .. " Exceptions",
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, button_data),
        "timeout", 60,
    }), NULL_KEY)
end

local function show_owner_menu() show_role_menu("Owner", ExOwnerTp, ExOwnerIm, "owner") end
local function show_trustee_menu() show_role_menu("Trustee", ExTrusteeTp, ExTrusteeIm, "trustee") end

local function show_toggle(role: string, exception_type: string, current: boolean)
    SessionId = gen_session()
    MenuContext = role .. "_" .. exception_type

    local body = role .. " " .. exception_type .. " Exception\n\n"
    if current then body = body .. "Current: Allowed\n\n" else body = body .. "Current: Denied\n\n" end
    body = body .. "Allow = Owner/trustee can bypass restrictions\nDeny = Normal restrictions apply"

    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", tostring(CurrentUser),
        "title", role .. " " .. exception_type,
        "body", body,
        "button_data", ll.List2Json(JSON_ARRAY, {btn("Back", "back"), btn("Allow", "allow"), btn("Deny", "deny")}),
        "timeout", 60,
    }), NULL_KEY)
end

--[[ -------------------- CLEANUP -------------------- ]]

local function cleanup()
    if SessionId ~= "" then
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.close",
            "session_id", SessionId,
        }), NULL_KEY)
    end
    ll.SetTimerEvent(0.0)
    PendingReconcile = false
    CurrentUser = NULL_KEY
    UserAcl = -999
    gPolicyButtons = {}
    SessionId = ""
    MenuContext = ""
end

--[[ -------------------- BUTTON HANDLING -------------------- ]]

local function set_exception(role: string, etype: string, allow: boolean)
    if role == "Owner" and etype == "TP" then
        ExOwnerTp = allow; persist_setting(KEY_EX_OWNER_TP, allow)
    elseif role == "Owner" and etype == "IM" then
        ExOwnerIm = allow; persist_setting(KEY_EX_OWNER_IM, allow)
    elseif role == "Trustee" and etype == "TP" then
        ExTrusteeTp = allow; persist_setting(KEY_EX_TRUSTEE_TP, allow)
    elseif role == "Trustee" and etype == "IM" then
        ExTrusteeIm = allow; persist_setting(KEY_EX_TRUSTEE_IM, allow)
    end
    reconcile_all()
    local verb = "denied"
    if allow then verb = "allowed" end
    ll.RegionSayTo(CurrentUser, 0, role .. " " .. etype .. " exception " .. verb .. ".")
end

-- Apply allow/deny in a toggle context like "Owner_TP", then redisplay parent.
local function handle_toggle_ctx(role: string, etype: string, ctx: string)
    if ctx == "allow" then set_exception(role, etype, true)
    elseif ctx == "deny" then set_exception(role, etype, false) end
    if role == "Owner" then show_owner_menu() else show_trustee_menu() end
end

local function handle_button(ctx: string)
    if ctx == "back" then
        if MenuContext == "main" then
            ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
                "type", "ui.menu.return", "user", tostring(CurrentUser),
            }), NULL_KEY)
            cleanup()
        elseif MenuContext == "owner" or MenuContext == "trustee" then
            show_main()
        else
            if starts_with(MenuContext, "Owner") then show_owner_menu()
            elseif starts_with(MenuContext, "Trustee") then show_trustee_menu()
            else show_main() end
        end
        return
    end

    if MenuContext == "main" then
        if ctx == "owner" then show_owner_menu()
        elseif ctx == "trustee" then show_trustee_menu() end
    elseif MenuContext == "owner" then
        if ctx == "tp" then show_toggle("Owner", "TP", ExOwnerTp)
        elseif ctx == "im" then show_toggle("Owner", "IM", ExOwnerIm) end
    elseif MenuContext == "trustee" then
        if ctx == "tp" then show_toggle("Trustee", "TP", ExTrusteeTp)
        elseif ctx == "im" then show_toggle("Trustee", "IM", ExTrusteeIm) end
    elseif MenuContext == "Owner_TP" then
        handle_toggle_ctx("Owner", "TP", ctx)
    elseif MenuContext == "Owner_IM" then
        handle_toggle_ctx("Owner", "IM", ctx)
    elseif MenuContext == "Trustee_TP" then
        handle_toggle_ctx("Trustee", "TP", ctx)
    elseif MenuContext == "Trustee_IM" then
        handle_toggle_ctx("Trustee", "IM", ctx)
    end
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
    cleanup()
    register_self()
    apply_settings_sync()

    -- On cold start, reconcile immediately (don't wait on the debounce timer).
    if PendingReconcile then
        PendingReconcile = false
        ll.SetTimerEvent(0.0)
        reconcile_all()
    end
end

function LLEvents.on_rez(p: number)
    ll.ResetScript()
end

function LLEvents.changed(c: number)
    if bit32.band(c, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

function LLEvents.timer()
    ll.SetTimerEvent(0.0)
    if PendingReconcile then
        PendingReconcile = false
        reconcile_all()
    end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local mtype = ll.JsonGetValue(msg, {"type"})
    if mtype == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if mtype == "kernel.register.refresh" then
            register_self()
            apply_settings_sync()
        elseif mtype == "kernel.ping" then
            send_pong()
        elseif mtype == "kernel.reset.soft" or mtype == "kernel.reset.factory" then
            local target_context = ll.JsonGetValue(msg, {"context"})
            if target_context ~= JSON_INVALID then
                if target_context ~= "" and target_context ~= PLUGIN_CONTEXT then return end
            end
            ll.LinksetDataDelete("plugin.reg." .. PLUGIN_CONTEXT)
            ll.LinksetDataDelete("acl.policycontext:" .. PLUGIN_CONTEXT)
            ll.ResetScript()
        end
    elseif num == SETTINGS_BUS then
        if mtype == "settings.sync" then apply_settings_sync() end
    elseif num == UI_BUS then
        if mtype == "ui.menu.start" and ll.JsonGetValue(msg, {"context"}) ~= JSON_INVALID then
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) == PLUGIN_CONTEXT then
                CurrentUser = id
                UserAcl = integer(ll.JsonGetValue(msg, {"acl"}))
                show_main()
            end
        end
    elseif num == DIALOG_BUS then
        if mtype == "ui.dialog.response" then
            if ll.JsonGetValue(msg, {"session_id"}) ~= JSON_INVALID and ll.JsonGetValue(msg, {"context"}) ~= JSON_INVALID then
                if ll.JsonGetValue(msg, {"session_id"}) == SessionId then
                    handle_button(ll.JsonGetValue(msg, {"context"}))
                end
            end
        elseif mtype == "ui.dialog.timeout" then
            if ll.JsonGetValue(msg, {"session_id"}) ~= JSON_INVALID then
                if ll.JsonGetValue(msg, {"session_id"}) == SessionId then cleanup() end
            end
        end
    end
end

-- Top-level init.
main()

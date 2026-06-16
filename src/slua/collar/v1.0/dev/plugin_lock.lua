--[[--------------------
PLUGIN: plugin_lock.lua  (SLua port)
VERSION: 1.10
REVISION: 15  (SLua port rev 1)
PURPOSE: Toggle collar lock (RLV @detach) and lock/unlock prim visuals
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility

SLUA PORT NOTES:
- Ported from plugin_lock.lsl rev 15. settings.delta CSV write, plugin.reg.* /
  plugin.lock.state / buttonconfig contracts, and @detach RLV (via ll.OwnerSay)
  unchanged.
- Idiomatic SLua: Locked is a boolean (persisted/state as a number).
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS = 800
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.lock"
local PLUGIN_LABEL_LOCKED = "Locked: Y"
local PLUGIN_LABEL_UNLOCKED = "Locked: N"

--[[ -------------------- SETTINGS KEYS -------------------- ]]
local KEY_LOCKED = "lock.locked"

--[[ -------------------- SOUND / VISUAL -------------------- ]]
local SOUND_TOGGLE = "3aacf116-f060-b4c8-bb58-07aefc0af33a"
local SOUND_VOLUME = 1.0
local PRIM_LOCKED = "locked"
local PRIM_UNLOCKED = "unlocked"

--[[ -------------------- STATE -------------------- ]]
local Locked = false
local gPolicyButtons = {}

--[[ -------------------- HELPERS -------------------- ]]

--[[ integer(): SLua has no LSL-style (integer) cast; emulate it (truncate toward zero; non-numeric -> 0). ]]
local function integer(v): number
    local n = tonumber(v)
    if n == nil then return 0 end
    if n < 0 then return math.ceil(n) end
    return math.floor(n)
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

local function lsd_bool(lsd_key: string, fallback: boolean): boolean
    local v = ll.LinksetDataRead(lsd_key)
    if v == "" then return fallback end
    return integer(v) ~= 0
end

local function play_toggle_sound()
    ll.TriggerSound(SOUND_TOGGLE, SOUND_VOLUME)
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

--[[ -------------------- VISUAL FEEDBACK -------------------- ]]

local function set_lock_prims(locked: boolean)
    local link_count = ll.GetNumberOfPrims()
    for i = 1, link_count do
        local name = ll.GetLinkName(i)
        if name == PRIM_LOCKED then
            ll.SetLinkAlpha(i, (locked and 1.0) or 0.0, ALL_SIDES)
        elseif name == PRIM_UNLOCKED then
            ll.SetLinkAlpha(i, (locked and 0.0) or 1.0, ALL_SIDES)
        end
    end
end

local function apply_lock_state()
    if Locked then
        ll.OwnerSay("@detach=n")
        set_lock_prims(true)
    else
        ll.OwnerSay("@detach=y")
        set_lock_prims(false)
    end
end

--[[ -------------------- LIFECYCLE -------------------- ]]

local function write_plugin_reg(label: string)
    local k = "plugin.reg." .. PLUGIN_CONTEXT
    local v = ll.List2Json(JSON_OBJECT, {"label", label, "script", ll.GetScriptName()})
    if ll.LinksetDataRead(k) == v then return end
    ll.LinksetDataWrite(k, v)
end

local function register_button_config()
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.buttonconfig.register",
        "context", PLUGIN_CONTEXT,
        "button_a", PLUGIN_LABEL_UNLOCKED,
        "button_b", PLUGIN_LABEL_LOCKED,
    }), NULL_KEY)
end

local function send_state_update()
    local k = "plugin.lock.state"
    local v = tostring(b2i(Locked))
    if ll.LinksetDataRead(k) == v then return end
    ll.LinksetDataWrite(k, v)
end

local function register_self()
    ll.LinksetDataWrite("acl.policycontext:" .. PLUGIN_CONTEXT, ll.List2Json(JSON_OBJECT, {
        "4", "toggle",
        "5", "toggle",
    }))
    write_plugin_reg(PLUGIN_LABEL_UNLOCKED)
    register_button_config()
    send_state_update()

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL_UNLOCKED,
        "script", ll.GetScriptName(),
    }), NULL_KEY)

    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "chat.alias.declare",
        "alias", "lock",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

local function send_pong()
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

--[[ -------------------- SETTINGS -------------------- ]]

local function apply_settings_sync()
    local prev_locked = Locked
    Locked = lsd_bool(KEY_LOCKED, false)
    if Locked ~= prev_locked then
        apply_lock_state()
        play_toggle_sound()
        send_state_update()
    end
end

local function persist_locked(new_value: boolean)
    ll.MessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" .. KEY_LOCKED .. ":" .. tostring(b2i(new_value)), NULL_KEY)
end

local function update_ui_label_and_return(user)
    send_state_update()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return",
        "user", tostring(user),
    }), NULL_KEY)
end

--[[ -------------------- ACTIONS -------------------- ]]

local function set_lock_state(user, acl_level: number, target_locked: boolean)
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level)
    if not btn_allowed("toggle") then
        ll.RegionSayTo(user, 0, "Access denied.")
        gPolicyButtons = {}
        return
    end
    gPolicyButtons = {}

    if Locked == target_locked then
        if target_locked then ll.RegionSayTo(user, 0, "Collar already locked.")
        else ll.RegionSayTo(user, 0, "Collar already unlocked.") end
        return
    end

    Locked = target_locked
    play_toggle_sound()
    apply_lock_state()
    persist_locked(Locked)
    if Locked then ll.RegionSayTo(user, 0, "Collar locked.")
    else ll.RegionSayTo(user, 0, "Collar unlocked.") end
    send_state_update()
end

local function handle_subpath(user, acl_level: number, subpath: string)
    if subpath == "locked" then
        set_lock_state(user, acl_level, true)
    elseif subpath == "unlocked" then
        set_lock_state(user, acl_level, false)
    else
        ll.RegionSayTo(user, 0, "Unknown lock subcommand: " .. subpath)
    end
end

local function toggle_lock(user, acl_level: number)
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level)
    if not btn_allowed("toggle") then
        ll.RegionSayTo(user, 0, "Access denied.")
        gPolicyButtons = {}
        return
    end
    gPolicyButtons = {}

    Locked = not Locked
    play_toggle_sound()
    apply_lock_state()
    persist_locked(Locked)
    if Locked then ll.RegionSayTo(user, 0, "Collar locked.")
    else ll.RegionSayTo(user, 0, "Collar unlocked.") end
    update_ui_label_and_return(user)
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end
    gPolicyButtons = {}
    Locked = lsd_bool(KEY_LOCKED, false)  -- restore (survives relog)
    apply_lock_state()
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

        if msg_type == "kernel.register.refresh" then
            apply_settings_sync()
            register_self()
        elseif msg_type == "kernel.ping" then
            send_pong()
        elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            local target_context = ll.JsonGetValue(msg, {"context"})
            if target_context ~= JSON_INVALID then
                if target_context ~= "" and target_context ~= PLUGIN_CONTEXT then return end
            end
            ll.LinksetDataDelete("plugin.reg." .. PLUGIN_CONTEXT)
            ll.LinksetDataDelete("plugin.lock.state")
            ll.LinksetDataDelete("acl.policycontext:" .. PLUGIN_CONTEXT)
            ll.ResetScript()
        end
        return
    end

    if num == SETTINGS_BUS then
        if ll.JsonGetValue(msg, {"type"}) == "settings.sync" then
            apply_settings_sync()
        end
        return
    end

    if num == UI_BUS then
        if ll.JsonGetValue(msg, {"type"}) == "ui.menu.start" then
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) ~= PLUGIN_CONTEXT then return end
            if id == NULL_KEY then return end

            local acl = integer(ll.JsonGetValue(msg, {"acl"}))
            local subpath = ""
            local sp = ll.JsonGetValue(msg, {"subpath"})
            if sp ~= JSON_INVALID then subpath = sp end

            if subpath ~= "" then
                handle_subpath(id, acl, subpath)
            else
                toggle_lock(id, acl)
            end
        end
        return
    end
end

-- Top-level init.
main()

--[[--------------------
PLUGIN: plugin_restrict.lua  (SLua IDIOMATIC port — Batch 2 anchor)
VERSION: 1.2
REVISION: 13  (SLua port rev 1)
PURPOSE: RLV restriction toggles grouped by category, force-sit/unsit.
ARCHITECTURE: RLV emission routed through kmod_rlv (refcount-coordinated). Menu
  visibility is LSD policy-driven (acl.policycontext, seeded via the kernel declare).

SLUA PORT NOTES — this is the Batch-2 idiom anchor. Unlike Batch 1 (faithful
structural port of infrastructure), the PLUGINS are reimagined to use SLua:
- COROUTINE MENU SESSIONS (the headline). A user's whole interaction is one
  coroutine that runs straight-line and AWAITS input, instead of rendering +
  stashing session state in globals + re-entering a handle_dialog_response ladder.
  menu_await() renders a menu and yields; the link_message handler resumes the
  parked coroutine with the clicked context. sensor_await() does the same for the
  force-sit scan — so scan -> pick is LINEAR (the LSL needed a sensor() callback +
  a display function + a separate response branch). Timeout/close resume with nil,
  so a flow just `return`s. One active flow at a time (mirrors the LSL's single
  CurrentUser/SessionId); a new ui.menu.start abandons the old coroutine.
- DISPATCH stays as readable if/else on the returned context (small, local).
- The wire to kmod_menu/kmod_dialogs is UNCHANGED (same ui.menu.render shapes), and
  the kmod_rlv / settings.delta / kernel-declare contracts are byte-identical to the
  LSL — only this plugin's INTERNAL structure is idiomatic.
- The MENU HARNESS block below (new_session + menu_await + sensor_await + the
  deliver()/start_flow() resume plumbing) is plugin-agnostic. It is a candidate for
  the build-time bundle once proven (SLua has no runtime require()).
- 0-is-truthy booleans, csv_lead_int for casts, uuid() for keys, ll.* string ops —
  same rules as Batch 1.
- IN-WORLD VALIDATION NEEDED: (1) the coroutine yield/resume mechanic itself;
  (2) sensor detection via d:getKey()/d:getName() (the SLua detected-event idiom,
  same caveat as touch in kmod_ui).
----------------------]]

--[[ -------------------- CHANNELS -------------------- ]]
local KERNEL_LIFECYCLE = 500
local SETTINGS_BUS     = 800
local UI_BUS           = 900
local DIALOG_BUS       = 950

--[[ -------------------- IDENTITY -------------------- ]]
local PLUGIN_CONTEXT  = "ui.core.rlvrestrict"
local PLUGIN_LABEL    = "Restrict"
local PLUGIN_CATEGORY = "RLV"
local PLUGIN_ACL_MASK = 126  -- 62 (ACL 1-5) | 0x40 RLV-required
local RLV_CONSUMER    = "restrict"

local KEY_RESTRICTIONS = "restrict.list"
local MAX_RESTRICTIONS = 32
local SIT_SCAN_RANGE   = 10.0

--[[ -------------------- CATEGORIES -------------------- ]]
local CAT_NAME_INVENTORY = "Inventory"
local CAT_NAME_SPEECH    = "Speech"
local CAT_NAME_TRAVEL    = "Travel"
local CAT_NAME_OTHER     = "Other"

-- Per category: parallel command/label arrays (pre-sorted by label).
local CATEGORIES: { [string]: { cmds: {string}, labels: {string} } } = {
    [CAT_NAME_INVENTORY] = {
        cmds   = {"@addattach", "@addoutfit", "@remattach", "@remoutfit", "@showinv", "@viewnote", "@viewscript"},
        labels = {"+ Attach", "+ Outfit", "- Attach", "- Outfit", "Inv", "Notes", "Scripts"},
    },
    [CAT_NAME_SPEECH] = {
        cmds   = {"@sendchat", "@recvim", "@sendim", "@chatshout", "@startim", "@chatwhisper"},
        labels = {"Chat", "Recv IM", "Send IM", "Shout", "Start IM", "Whisper"},
    },
    [CAT_NAME_TRAVEL] = {
        cmds   = {"@tploc", "@tplm", "@sittp", "@tplure"},
        labels = {"Loc. TP", "Map TP", "Sit TP", "TP"},
    },
    [CAT_NAME_OTHER] = {
        cmds   = {"@edit", "@interact", "@shownames", "@rez", "@sit", "@touchattach", "@fartouch", "@touchhud", "@touchall", "@touchworld", "@unsit"},
        labels = {"Edit", "Isolate", "Names", "Rez", "Sit", "Touch Att", "Touch Far", "Touch HUD", "Touch Own", "Touch Wld", "Unsit"},
    },
}

local DIALOG_PAGE_SIZE = 9

--[[ -------------------- STATE -------------------- ]]
local Restrictions: {string} = {}
local CurrentUser = NULL_KEY
local UserAcl = 0
local gPolicyButtons: {string} = {}

--[[ -------------------- HELPERS -------------------- ]]

local function csv_lead_int(s: string): number
    return tonumber(string.match(s, "^%s*(-?%d+)") or "") or 0
end

local function starts_with(s: string, prefix: string): boolean
    return ll.SubStringIndex(s, prefix) == 0
end

local function list_find(t: {string}, v: string): number?
    for i, x in ipairs(t) do
        if x == v then return i end
    end
    return nil
end

local function notify(text: string)
    ll.RegionSayTo(CurrentUser, 0, text)
end

-- {label,context} button object for a fixed/pager buttons array.
local function btn(label: string, cmd: string): string
    return ll.List2Json(JSON_OBJECT, {"label", label, "context", cmd})
end

--[[ ====================================================================
     COROUTINE MENU HARNESS  (plugin-agnostic; bundle candidate)
     -------------------------------------------------------------------
     One active flow coroutine at a time. A flow calls menu_await/sensor_await,
     which set what signal we're parked on and yield; the matching event delivers
     the value back. A new flow abandons any prior one (single-session model).
     ==================================================================== ]]

local _flow_co: thread? = nil   -- the running flow coroutine, or nil
local _flow_sess = ""           -- session id a dialog-await is parked on
local _flow_signal = ""         -- "dialog" | "sensor" | "" (not parked)
local _sess_ctr = 0

local function new_session(): string
    _sess_ctr = _sess_ctr + 1
    return "r_" .. tostring(ll.GetKey()) .. "_" .. tostring(ll.GetUnixTime()) .. "_" .. tostring(_sess_ctr)
end

-- Resume the parked flow with a value, iff it is waiting on this signal kind.
local function deliver(signal_kind: string, value: any)
    if _flow_co == nil or _flow_signal ~= signal_kind then return end
    _flow_signal = ""  -- consumed; the flow sets a new await on its next call
    local co = _flow_co
    local ok = coroutine.resume(co, value)
    if not ok or coroutine.status(co) == "dead" then
        if _flow_co == co then _flow_co = nil end
    end
end

-- Start a fresh flow, abandoning any prior one.
local function start_flow(fn: () -> ())
    _flow_co = coroutine.create(fn)
    _flow_signal = ""
    local co = _flow_co
    local ok = coroutine.resume(co)  -- run to the first await
    if not ok or coroutine.status(co) == "dead" then
        if _flow_co == co then _flow_co = nil end
    end
end

-- Render a menu and park until the user clicks. Returns the clicked context, or
-- nil on timeout/close. opts: {mode, title?, body?, buttons?, items?, fixed?,
-- has_nav?, page?, category?}.
local function menu_await(opts): string?
    local sess = new_session()
    _flow_sess = sess
    _flow_signal = "dialog"

    local f = {
        "type", "ui.menu.render",
        "mode", opts.mode,
        "session_id", sess,
        "user", tostring(CurrentUser),
        "menu_type", PLUGIN_CONTEXT,
    }
    local function add(k, v) f[#f + 1] = k; f[#f + 1] = v end
    if opts.title    ~= nil then add("title", opts.title) end
    if opts.body     ~= nil then add("body", opts.body) end
    if opts.category ~= nil then add("category", opts.category) end
    if opts.has_nav  ~= nil then add("has_nav", opts.has_nav) end
    if opts.page     ~= nil then add("page", opts.page) end
    if opts.buttons  ~= nil then add("buttons", ll.List2Json(JSON_ARRAY, opts.buttons)) end
    if opts.items    ~= nil then add("items", ll.List2Json(JSON_ARRAY, opts.items)) end
    if opts.fixed    ~= nil then add("fixed", ll.List2Json(JSON_ARRAY, opts.fixed)) end

    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, f), NULL_KEY)
    return coroutine.yield()
end

-- Fire a sensor and park until results. Returns an array of {name, key} records
-- (empty on no_sensor).
local function sensor_await(range: number)
    _flow_signal = "sensor"
    ll.Sensor("", NULL_KEY, bit32.bor(PASSIVE, ACTIVE, SCRIPTED), range, PI)
    return coroutine.yield()
end

--[[ -------------------- LSD POLICY -------------------- ]]

local function get_policy_buttons(ctx: string, acl: number): {string}
    local policy = ll.LinksetDataRead("acl.policycontext:" .. ctx)
    if policy == "" then return {} end
    local csv = ll.JsonGetValue(policy, {tostring(acl)})
    if csv == JSON_INVALID then return {} end
    if csv == "" then return {} end  -- guard llCSV2List("") -> [""]
    return ll.CSV2List(csv)
end

local function btn_allowed(label: string): boolean
    return list_find(gPolicyButtons, label) ~= nil
end

--[[ -------------------- REGISTRATION -------------------- ]]

local function register_self()
    local policy = ll.List2Json(JSON_OBJECT, {
        "1", "Force Sit,Force Unsit",
        "2", "Force Sit,Force Unsit",
        "3", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        "4", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
        "5", "Inventory,Speech,Travel,Other,Clear all,Force Sit,Force Unsit",
    })
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", ll.GetScriptName(),
        "cat", PLUGIN_CATEGORY,
        "mask", tostring(PLUGIN_ACL_MASK),
        "policy", policy,
    }), NULL_KEY)
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "chat.alias.declare",
        "alias", "restrict",
        "context", PLUGIN_CONTEXT,
    }), NULL_KEY)
end

--[[ -------------------- PERSISTENCE -------------------- ]]

local function persist_restrictions()
    if #Restrictions == 0 then
        ll.MessageLinked(LINK_SET, SETTINGS_BUS, "settings.delete:" .. KEY_RESTRICTIONS, NULL_KEY)
        return
    end
    ll.MessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:" .. KEY_RESTRICTIONS .. ":" .. table.concat(Restrictions, ","), NULL_KEY)
end

--[[ -------------------- KMOD_RLV PROXY -------------------- ]]

local function rlv_op(op: string, restr_cmd: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", op,
        "consumer", RLV_CONSUMER,
        "behav", ll.GetSubString(restr_cmd, 1, -1),  -- strip leading "@"
    }), NULL_KEY)
end

local function rlv_clear_all()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "rlv.clear",
        "consumer", RLV_CONSUMER,
    }), NULL_KEY)
end

local function rlv_force(command: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "rlv.force",
        "command", command,
    }), NULL_KEY)
end

--[[ -------------------- RESTRICTION LOGIC -------------------- ]]

local function restriction_idx(restr_cmd: string): number?
    return list_find(Restrictions, restr_cmd)
end

-- @sittp viewer state = OR of the explicit toggle + implicit @tplm/@tploc holds.
local function reconcile_sittp()
    local explicit = (list_find(Restrictions, "@sittp") ~= nil)
    local implied  = (list_find(Restrictions, "@tplm") ~= nil) or (list_find(Restrictions, "@tploc") ~= nil)
    if explicit or implied then rlv_op("rlv.apply", "@sittp")
    else rlv_op("rlv.release", "@sittp") end
end

local function toggle_restriction(restr_cmd: string)
    local idx = restriction_idx(restr_cmd)
    local is_sittp = (restr_cmd == "@sittp")
    local affects_sittp = is_sittp or (restr_cmd == "@tplm") or (restr_cmd == "@tploc")

    if idx ~= nil then
        table.remove(Restrictions, idx)
        if not is_sittp then rlv_op("rlv.release", restr_cmd) end
    else
        if #Restrictions >= MAX_RESTRICTIONS then
            notify("Cannot add restriction: limit reached.")
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

local function apply_settings_sync()
    local csv = ll.LinksetDataRead(KEY_RESTRICTIONS)
    local new_list = {}
    if csv ~= "" then new_list = ll.ParseString2List(csv, {","}, {}) end

    if table.concat(new_list, ",") == table.concat(Restrictions, ",") then return end

    -- Release any current restriction not in the new list.
    for _, restr_cmd in ipairs(Restrictions) do
        if list_find(new_list, restr_cmd) == nil then
            rlv_op("rlv.release", restr_cmd)
        end
    end

    -- Apply the new list (kmod_rlv claim_add is idempotent).
    Restrictions = new_list
    for _, restr_cmd in ipairs(Restrictions) do
        rlv_op("rlv.apply", restr_cmd)
    end

    reconcile_sittp()
end

--[[ -------------------- FORCE SIT/UNSIT -------------------- ]]

local function force_sit_on(target)
    if target == NULL_KEY then return end
    rlv_force("@sit:" .. tostring(target) .. "=force")
    notify("Forcing sit...")
end

local function force_unsit()
    rlv_force("@unsit=force")
    notify("Forcing unsit...")
end

--[[ -------------------- MENU BUILDERS -------------------- ]]

local function build_main_buttons(): {string}
    local b = {}
    -- Alphabetical by displayed label.
    if btn_allowed("Clear all")   then b[#b + 1] = btn("Clear all", "clear_all") end
    if btn_allowed("Force Sit")   then b[#b + 1] = btn("Force Sit", "force_sit") end
    if btn_allowed("Force Unsit") then b[#b + 1] = btn("Force Unsit", "force_unsit") end
    if btn_allowed("Inventory")   then b[#b + 1] = btn(CAT_NAME_INVENTORY, "cat_inventory") end
    if btn_allowed("Other")       then b[#b + 1] = btn(CAT_NAME_OTHER, "cat_other") end
    if btn_allowed("Speech")      then b[#b + 1] = btn(CAT_NAME_SPEECH, "cat_speech") end
    if btn_allowed("Travel")      then b[#b + 1] = btn(CAT_NAME_TRAVEL, "cat_travel") end
    return b
end

local function main_body(): string
    if btn_allowed("Inventory") then
        return "RLV Restrictions\n\nActive: " .. tostring(#Restrictions) .. "/" .. tostring(MAX_RESTRICTIONS)
    end
    return "RLV Actions\n\nForce sit or unsit the wearer."
end

local CAT_CTX = {
    cat_inventory = CAT_NAME_INVENTORY,
    cat_speech    = CAT_NAME_SPEECH,
    cat_travel    = CAT_NAME_TRAVEL,
    cat_other     = CAT_NAME_OTHER,
}

local CAT_LABEL_FOR_POLICY = {
    [CAT_NAME_INVENTORY] = "Inventory",
    [CAT_NAME_SPEECH]    = "Speech",
    [CAT_NAME_TRAVEL]    = "Travel",
    [CAT_NAME_OTHER]     = "Other",
}

local function build_category_buttons(cat_name: string): {string}
    local cat = CATEGORIES[cat_name]
    local b = {}
    for i, cmd in ipairs(cat.cmds) do
        local label = cat.labels[i]
        if restriction_idx(cmd) ~= nil then label = "[X] " .. label
        else label = "[ ] " .. label end
        b[#b + 1] = btn(label, cmd)
    end
    return b
end

--[[ -------------------- FLOWS (coroutine menu sessions) -------------------- ]]

local function return_to_root()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user", tostring(CurrentUser),
    }), NULL_KEY)
end

-- Force-sit: scan -> OL picker -> @sit. Linear, thanks to sensor_await/menu_await.
local function force_sit_flow()
    notify("Scanning for nearby objects...")
    local candidates = sensor_await(SIT_SCAN_RANGE)
    if #candidates == 0 then
        notify("No objects found nearby.")
        return
    end

    local page = 0
    local max_page = (#candidates - 1) // DIALOG_PAGE_SIZE
    while true do
        local items = {}
        for _, c in ipairs(candidates) do
            local nm = c.name
            if ll.StringLength(nm) > 28 then nm = ll.GetSubString(nm, 0, 25) .. "..." end
            items[#items + 1] = nm
        end

        local ctx = menu_await{
            mode = "menu.ordered",
            title = "Force Sit",
            body = "Select an object to sit on:",
            items = items,
            page = page,
        }
        if ctx == nil or ctx == "nav:back" then return end
        if ctx == "nav:prev" then
            if page == 0 then page = max_page else page = page - 1 end
        elseif ctx == "nav:next" then
            if page >= max_page then page = 0 else page = page + 1 end
        elseif starts_with(ctx, "pick:") then
            local idx = csv_lead_int(ll.GetSubString(ctx, 5, -1)) + 1  -- 1-based
            local target = candidates[idx]
            if target ~= nil then force_sit_on(target.key) end
            return
        end
    end
end

-- A category's toggle list: redraw-on-toggle is just the loop iterating.
local function category_flow(cat_name: string)
    local page = 0
    local max_page = (#CATEGORIES[cat_name].cmds - 1) // DIALOG_PAGE_SIZE
    while true do
        local ctx = menu_await{
            mode = "menu.pager",
            title = cat_name,
            body = "Active: " .. tostring(#Restrictions),
            category = PLUGIN_CATEGORY,
            has_nav = 1,
            buttons = build_category_buttons(cat_name),
            page = page,
        }
        if ctx == nil or ctx == "nav:back" then return end
        if ctx == "nav:prev" then
            if page == 0 then page = max_page else page = page - 1 end
        elseif ctx == "nav:next" then
            if page >= max_page then page = 0 else page = page + 1 end
        else
            -- ctx is the @cmd directly.
            if restriction_idx(ctx) ~= nil or starts_with(ctx, "@") then
                toggle_restriction(ctx)
            end
        end
    end
end

-- The whole Restrict interaction: one coroutine looping on the main menu.
local function restrict_session()
    while true do
        gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl)

        local ctx = menu_await{
            mode = "menu.fixed",
            title = PLUGIN_LABEL,
            body = main_body(),
            buttons = build_main_buttons(),
        }
        if ctx == nil then return end
        if ctx == "nav:back" then
            return_to_root()
            return
        elseif ctx == "clear_all" then
            if btn_allowed("Clear all") then
                remove_all_restrictions()
                notify("All restrictions removed.")
            else
                notify("Access denied.")
            end
        elseif ctx == "force_sit" then
            force_sit_flow()
        elseif ctx == "force_unsit" then
            force_unsit()
        elseif CAT_CTX[ctx] ~= nil then
            local cat_name = CAT_CTX[ctx]
            if btn_allowed(CAT_LABEL_FOR_POLICY[cat_name]) then
                category_flow(cat_name)
            else
                notify("Access denied.")
            end
        end
        -- loop redraws the main menu
    end
end

--[[ -------------------- CHAT SUBPATH (non-menu) -------------------- ]]

-- "<prefix> restrict clear" — gated, no menu session.
local function handle_chat_clear(acl: number, sender)
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl)
    if not btn_allowed("Clear all") then
        ll.RegionSayTo(sender, 0, "Access denied.")
        gPolicyButtons = {}
        return
    end
    gPolicyButtons = {}
    remove_all_restrictions()
    ll.RegionSayTo(sender, 0, "All restrictions removed.")
end

--[[ -------------------- EVENTS -------------------- ]]

local function main()
    CurrentUser = NULL_KEY
    apply_settings_sync()
    register_self()
end

function LLEvents.on_rez(param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        ll.ResetScript()
    end
end

-- Sensor results feed the parked force-sit flow. SLua delivers detections as
-- objects with :getKey()/:getName() (NOT llDetectedKey) — IN-WORLD VALIDATE.
function LLEvents.sensor(detected)
    local wearer = ll.GetOwner()
    local my_key = ll.GetKey()
    local arr = {}
    for _, d in ipairs(detected) do
        local k = d:getKey()
        if k ~= my_key and k ~= wearer then
            arr[#arr + 1] = { name = d:getName(), key = k }
        end
    end
    deliver("sensor", arr)
end

function LLEvents.no_sensor()
    deliver("sensor", {})
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.register.refresh" then
            register_self()
            apply_settings_sync()
        elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
        return
    end

    if num == SETTINGS_BUS then
        if msg_type == "settings.sync" then apply_settings_sync() end
        return
    end

    if num == UI_BUS then
        if msg_type == "ui.menu.start" then
            local context = ll.JsonGetValue(msg, {"context"})
            if context ~= PLUGIN_CONTEXT then return end
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            local acl = csv_lead_int(ll.JsonGetValue(msg, {"acl"}))

            local subpath = ""
            local sp = ll.JsonGetValue(msg, {"subpath"})
            if sp ~= JSON_INVALID then subpath = sp end

            if subpath == "clear" then
                handle_chat_clear(acl, id)
                return
            end
            if subpath ~= "" then
                ll.RegionSayTo(id, 0, "Unknown restrict subcommand: " .. subpath)
                return
            end

            -- Open the menu session: one coroutine drives the whole interaction.
            CurrentUser = id
            UserAcl = acl
            start_flow(restrict_session)
        elseif msg_type == "sos.restrict.clear" then
            remove_all_restrictions()
        elseif msg_type == "safeword.fired" then
            Restrictions = {}
            persist_restrictions()
        end
        return
    end

    -- Dialog responses/timeout/close resume the parked flow.
    if num == DIALOG_BUS then
        if msg_type == "ui.dialog.response" then
            if ll.JsonGetValue(msg, {"session_id"}) ~= _flow_sess then return end
            local ctx = ll.JsonGetValue(msg, {"context"})
            if ctx == JSON_INVALID then ctx = "" end
            deliver("dialog", ctx)
        elseif msg_type == "ui.dialog.timeout" or msg_type == "ui.dialog.close" then
            if ll.JsonGetValue(msg, {"session_id"}) ~= _flow_sess then return end
            deliver("dialog", nil)  -- flow returns
        end
        return
    end
end

main()

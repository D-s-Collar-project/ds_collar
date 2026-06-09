--[[--------------------
MODULE: kmod_ui.lua  (SLua port)
VERSION: 1.10
REVISION: 19  (SLua port rev 1)
PURPOSE: Session management, LSD policy filtering, and plugin list orchestration
ARCHITECTURE: Consolidated message bus lanes

SLUA PORT NOTES:
- Ported from kmod_ui.lsl rev 19. All bus wire formats (KERNEL_LIFECYCLE 500,
  AUTH_BUS 700, UI_BUS 900, DIALOG_BUS 950) and LSD contracts (acl.<uuid>.cache,
  plugin.reg.*, acl.policycontext:*) are preserved for LSL interop.
- Idiomatic SLua:
  * plugin list is an array of {context,label} records (1-based index is the
    plugin id referenced by the view tables);
  * view tables are acl -> {plugin indices} maps — the rev-12/16 CSV-accumulator
    heap optimizations are gone (they fought Mono, not SLua);
  * sessions are an array of records, pending-ACL and touch state are maps;
  * mutually-recursive functions are forward-declared in one block.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local AUTH_BUS = 700
local UI_BUS = 900
local DIALOG_BUS = 950

--[[ -------------------- CONSTANTS -------------------- ]]
local ROOT_CONTEXT = "ui.core.root"
local SOS_CONTEXT = "ui.sos.root"
local SOS_PREFIX = "ui.sos."
local MAX_FUNC_BTNS = 9
local TOUCH_RANGE_M = 5.0
local LONG_TOUCH_THRESHOLD = 1.5

local MAX_SESSIONS = 5
local SESSION_MAX_AGE = 60  -- seconds before ACL refresh required

-- CROSS-MODULE CONTRACT: must match kmod_auth's cache key/value format.
local LSD_ACL_CACHE_PREFIX = "acl."
local LSD_ACL_CACHE_SUFFIX = ".cache"
local LSD_PLUGIN_REG_PREFIX = "plugin.reg."

local REBUILD_DEBOUNCE = 0.1

local ACL_BLACKLIST = -1
local VIEW_ACL_LEVELS = {-1, 0, 1, 2, 3, 4, 5}  -- constant

--[[ -------------------- STATE -------------------- ]]
local Plugins = {}    -- array of { context, label }; index = plugin id
local ViewRoot = {}   -- acl -> { plugin index, ... } for root menu
local ViewSos = {}    -- acl -> { plugin index, ... } for SOS menu

-- Sessions: array of { user, acl, blacklisted, page, total_pages, id, created, context }
local Sessions = {}
-- Pending ACL queries: tostring(avatar) -> requested context
local PendingAcl = {}
-- Touch tracking: tostring(toucher) -> ll.GetTime() at touch_start
local TouchTimes = {}

local ViewsStale = false

--[[ -------------------- FORWARD DECLARATIONS (mutual recursion) -------------------- ]]
local try_cached_session, find_session_idx, get_session_filtered_indices
local cleanup_session, create_session, rebuild_plugin_list_from_lsd
local schedule_rebuild, build_views, get_primary_owner_display, send_message
local send_render_menu, resolve_plugin_context, extract_subpath, dispatch_to_plugin
local handle_button_click, invalidate_all_sessions, handle_acl_result, handle_start
local start_root_session, start_sos_session, handle_return, handle_close
local handle_dialog_response, handle_dialog_timeout

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

local function get_msg_type(msg: string): string
    local t = ll.JsonGetValue(msg, {"type"})
    if t == JSON_INVALID then return "" end
    return t
end

local function starts_with(s: string, prefix: string): boolean
    return string.sub(s, 1, #prefix) == prefix
end

local function validate_required_fields(json_str: string, field_names): boolean
    for _, field in ipairs(field_names) do
        if ll.JsonGetValue(json_str, {field}) == JSON_INVALID then return false end
    end
    return true
end

local function generate_session_id(user): string
    return "ui_" .. tostring(user) .. "_" .. tostring(ll.GetUnixTime())
end

--[[ -------------------- ACL CACHE -------------------- ]]

function try_cached_session(user_key, context_filter: string): boolean
    local raw = ll.LinksetDataRead(LSD_ACL_CACHE_PREFIX .. tostring(user_key) .. LSD_ACL_CACHE_SUFFIX)
    if raw == "" then return false end
    local sep = string.find(raw, "|", 1, true)
    if sep == nil then return false end
    -- Reject entries older than the last settings change.
    local cache_ts = integer(string.sub(raw, sep + 1))
    local global_ts = integer(ll.LinksetDataRead("acl.timestamp"))
    if cache_ts < global_ts then return false end
    local level = integer(string.sub(raw, 1, sep - 1))
    create_session(user_key, level, level == ACL_BLACKLIST, context_filter)
    send_render_menu(user_key, context_filter)
    return true
end

--[[ -------------------- SESSION MANAGEMENT -------------------- ]]

function find_session_idx(user)
    for i, s in ipairs(Sessions) do
        if s.user == user then return i end
    end
    return nil
end

function get_session_filtered_indices(session)
    local map = ViewRoot
    if session.context == SOS_CONTEXT then map = ViewSos end
    return map[session.acl] or {}
end

function cleanup_session(user)
    local idx = find_session_idx(user)
    if idx == nil then return end
    -- Close the dialog before dropping the session.
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.close",
        "session_id", Sessions[idx].id,
    }), NULL_KEY)
    table.remove(Sessions, idx)
end

function create_session(user, acl: number, is_blacklisted: boolean, context_filter: string)
    if find_session_idx(user) ~= nil then
        cleanup_session(user)
    end
    if #Sessions >= MAX_SESSIONS then
        cleanup_session(Sessions[1].user)  -- evict oldest
    end
    Sessions[#Sessions + 1] = {
        user = user, acl = acl, blacklisted = is_blacklisted,
        page = 0, total_pages = 0,
        id = generate_session_id(user), created = ll.GetUnixTime(),
        context = context_filter,
    }
end

--[[ -------------------- PLUGIN LIST MANAGEMENT -------------------- ]]

-- Build the per-(acl, menu) view tables. One LSD policy read per plugin; fan
-- out across ACL levels from the cached policy string.
function build_views()
    ViewRoot = {}
    ViewSos = {}
    for _, acl in ipairs(VIEW_ACL_LEVELS) do
        ViewRoot[acl] = {}
        ViewSos[acl] = {}
    end

    for i, p in ipairs(Plugins) do
        local policy = ll.LinksetDataRead("acl.policycontext:" .. p.context)
        if policy ~= "" then
            local is_sos = starts_with(p.context, SOS_PREFIX)
            for _, acl in ipairs(VIEW_ACL_LEVELS) do
                if ll.JsonGetValue(policy, {tostring(acl)}) ~= JSON_INVALID then
                    local target = ViewRoot[acl]
                    if is_sos then target = ViewSos[acl] end
                    target[#target + 1] = i
                end
            end
        end
    end
end

-- Enumerate plugin.reg.* from LSD and rebuild the plugin list + views. Sort by
-- label (what the wearer reads), not by context key.
function rebuild_plugin_list_from_lsd()
    Plugins = {}
    local keys = ll.LinksetDataFindKeys("^plugin\\.reg\\.", 1, -1)  -- SLua: start is 1-based
    local prefix_len = #LSD_PLUGIN_REG_PREFIX

    local temp = {}
    for _, k in ipairs(keys) do
        local entry = ll.LinksetDataRead(k)
        local label = ll.JsonGetValue(entry, {"label"})
        if label ~= JSON_INVALID then
            temp[#temp + 1] = { context = string.sub(k, prefix_len + 1), label = label }
        end
    end

    table.sort(temp, function(a, b) return a.label < b.label end)
    Plugins = temp

    build_views()
end

-- Arm the debounce timer; multiple plugin.reg.* writes collapse to one rebuild.
function schedule_rebuild()
    if not ViewsStale then
        ViewsStale = true
        set_timer(REBUILD_DEBOUNCE)
    end
end

--[[ -------------------- MENU RENDERING -------------------- ]]

-- "[Honorific] Name" for the primary owner, or "" when none.
function get_primary_owner_display(): string
    local owner_uuid = ll.LinksetDataRead("access.owner")
    if owner_uuid ~= "" and uuid(owner_uuid) ~= NULL_KEY then
        local owner_name = ll.LinksetDataRead("access.ownername")
        local honorific  = ll.LinksetDataRead("access.ownerhonorific")
        if honorific ~= "" then return honorific .. " " .. owner_name end
        return owner_name
    end
    -- Multi-owner mode — use first owner.
    local names_csv = ll.LinksetDataRead("access.ownernames")
    if names_csv ~= "" then
        local names_list = ll.CSV2List(names_csv)
        local first_name = names_list[1]
        if first_name ~= nil and first_name ~= "" then
            local hons_csv = ll.LinksetDataRead("access.ownerhonorifics")
            if hons_csv ~= "" then
                local first_hon = ll.CSV2List(hons_csv)[1]
                if first_hon ~= nil and first_hon ~= "" then return first_hon .. " " .. first_name end
            end
            return first_name
        end
    end
    return ""
end

function send_message(user, message_text: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.message.show",
        "user", tostring(user),
        "message", message_text,
    }), NULL_KEY)
end

function send_render_menu(user, menu_type: string)
    local idx = find_session_idx(user)
    if idx == nil then return end
    local session = Sessions[idx]

    local filtered = get_session_filtered_indices(session)
    local plugin_count = #filtered

    if plugin_count == 0 then
        if menu_type == SOS_CONTEXT then
            send_message(user, "No emergency options are currently available.")
        elseif session.acl == -1 then
            if session.blacklisted then
                send_message(user, "You have been barred from using this collar.")
            else
                local primary_owner = get_primary_owner_display()
                if primary_owner ~= "" then
                    send_message(user, "This collar is owned by " .. primary_owner .. " and is exclusive to them.")
                else
                    send_message(user, "This collar is not available for public use.")
                end
            end
        elseif session.acl == 0 then
            send_message(user, "You have relinquished control of the collar.")
        else
            send_message(user, "No plugins are currently installed.")
        end
        cleanup_session(user)
        return
    end

    local total_pages = (plugin_count + MAX_FUNC_BTNS - 1) // MAX_FUNC_BTNS
    local current_page = session.page
    if current_page >= total_pages then current_page = 0 end
    if current_page < 0 then current_page = total_pages - 1 end
    session.page = current_page
    session.total_pages = total_pages

    local button_data = {}
    local start_idx = current_page * MAX_FUNC_BTNS  -- 0-based offset
    local end_idx = start_idx + MAX_FUNC_BTNS
    if end_idx > plugin_count then end_idx = plugin_count end

    for i = start_idx + 1, end_idx do   -- filtered is 1-based
        local p = Plugins[filtered[i]]
        button_data[#button_data + 1] = ll.List2Json(JSON_OBJECT, {
            "context", p.context,
            "label", p.label,
        })
    end

    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.render",
        "user", tostring(user),
        "session_id", session.id,
        "menu_type", menu_type,
        "page", current_page,
        "total_pages", total_pages,
        "buttons", ll.List2Json(JSON_ARRAY, button_data),
        "has_nav", 1,  -- navigation row is ALWAYS present (do not change)
    }), NULL_KEY)
end

--[[ -------------------- BUTTON HANDLING -------------------- ]]

-- Longest dot-boundary-prefix match of `requested` against a registered plugin
-- context. Returns the matched context, or "".
function resolve_plugin_context(requested: string): string
    for _, p in ipairs(Plugins) do
        if p.context == requested then return requested end
    end
    local best, best_len = "", 0
    local rlen = #requested
    for _, p in ipairs(Plugins) do
        local pc = p.context
        local plen = #pc
        if plen > best_len and rlen > plen then
            if string.sub(requested, 1, plen) == pc and string.sub(requested, plen + 1, plen + 1) == "." then
                best = pc
                best_len = plen
            end
        end
    end
    return best
end

-- Remainder after stripping a matched plugin context ("pose.nadu"); "" for exact.
function extract_subpath(requested: string, plugin_context: string): string
    local plen = #plugin_context
    if #requested <= plen + 1 then return "" end
    return string.sub(requested, plen + 2)
end

-- Dispatch ui.menu.start to a plugin, re-checking policy against the session ACL.
function dispatch_to_plugin(user, context: string, subpath: string, session)
    local user_acl = session.acl
    local policy = ll.LinksetDataRead("acl.policycontext:" .. context)
    if policy == "" then send_message(user, "Access denied."); return end
    if ll.JsonGetValue(policy, {tostring(user_acl)}) == JSON_INVALID then
        send_message(user, "Access denied.")
        return
    end
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.start",
        "context", context,
        "subpath", subpath,
        "user", tostring(user),
        "acl", user_acl,
    }), user)
end

function handle_button_click(user, button: string, context: string)
    local idx = find_session_idx(user)
    if idx == nil then return end
    local session = Sessions[idx]

    if session.blacklisted then
        send_message(user, "You have been barred from using this collar.")
        cleanup_session(user)
        return
    end

    if button == "<<" then
        local page = session.page - 1
        if page < 0 then page = session.total_pages - 1 end
        session.page = page
        send_render_menu(user, session.context)
        return
    end
    if button == "Close" then
        cleanup_session(user)
        return
    end
    if button == ">>" then
        local page = session.page + 1
        if page >= session.total_pages then page = 0 end
        session.page = page
        send_render_menu(user, session.context)
        return
    end

    -- Plugin button: menu buttons always carry an exact context, no subpath.
    if context ~= "" then
        if resolve_plugin_context(context) == context then
            dispatch_to_plugin(user, context, "", session)
        end
    end
end

--[[ -------------------- MESSAGE HANDLERS -------------------- ]]

-- Close all dialogs and drop all sessions after a rebuild applies.
function invalidate_all_sessions()
    if #Sessions == 0 then return end
    for _, s in ipairs(Sessions) do
        ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
            "type", "ui.dialog.close",
            "session_id", s.id,
        }), NULL_KEY)
    end
    Sessions = {}
    PendingAcl = {}
end

function handle_acl_result(msg: string)
    if not validate_required_fields(msg, {"avatar", "level", "is_blacklisted"}) then return end

    local avatar = uuid(ll.JsonGetValue(msg, {"avatar"}))
    local level = integer(ll.JsonGetValue(msg, {"level"}))
    local is_blacklisted = integer(ll.JsonGetValue(msg, {"is_blacklisted"})) ~= 0

    local akey = tostring(avatar)
    local requested_context = PendingAcl[akey]
    if requested_context == nil then return end
    PendingAcl[akey] = nil

    if requested_context == ROOT_CONTEXT or requested_context == SOS_CONTEXT then
        create_session(avatar, level, is_blacklisted, requested_context)
        send_render_menu(avatar, requested_context)
    else
        -- Plugin context from chat dispatch: root session for nav, then dispatch.
        create_session(avatar, level, is_blacklisted, ROOT_CONTEXT)
        local idx = find_session_idx(avatar)
        if idx ~= nil then
            local matched = resolve_plugin_context(requested_context)
            if matched ~= "" then
                dispatch_to_plugin(avatar, matched, extract_subpath(requested_context, matched), Sessions[idx])
            end
        end
    end
end

function start_root_session(user_key)
    if PendingAcl[tostring(user_key)] ~= nil then return end
    if try_cached_session(user_key, ROOT_CONTEXT) then return end
    PendingAcl[tostring(user_key)] = ROOT_CONTEXT
    ll.MessageLinked(LINK_SET, AUTH_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "auth.acl.query",
        "avatar", tostring(user_key),
    }), NULL_KEY)
end

function start_sos_session(user_key)
    if PendingAcl[tostring(user_key)] ~= nil then return end
    if try_cached_session(user_key, SOS_CONTEXT) then return end
    PendingAcl[tostring(user_key)] = SOS_CONTEXT
    ll.MessageLinked(LINK_SET, AUTH_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "auth.acl.query",
        "avatar", tostring(user_key),
    }), NULL_KEY)
end

function handle_start(msg: string, user_key)
    -- Already-routed messages (carry an acl field) are for a plugin, not us.
    if ll.JsonGetValue(msg, {"acl"}) ~= JSON_INVALID then return end

    local context = ll.JsonGetValue(msg, {"context"})
    if context == JSON_INVALID then start_root_session(user_key); return end
    if context == ROOT_CONTEXT then start_root_session(user_key); return end
    if context == SOS_CONTEXT then start_sos_session(user_key); return end

    -- Plugin-specific context from kmod_chat (longest-prefix + subpath).
    local matched = resolve_plugin_context(context)
    if matched == "" then start_root_session(user_key); return end
    local subpath = extract_subpath(context, matched)

    local idx = find_session_idx(user_key)
    if idx ~= nil then
        dispatch_to_plugin(user_key, matched, subpath, Sessions[idx])
        return
    end

    -- LSD cache hit — create root session then dispatch.
    local raw = ll.LinksetDataRead(LSD_ACL_CACHE_PREFIX .. tostring(user_key) .. LSD_ACL_CACHE_SUFFIX)
    if raw ~= "" then
        local sep = string.find(raw, "|", 1, true)
        if sep ~= nil then
            local cache_ts = integer(string.sub(raw, sep + 1))
            local global_ts = integer(ll.LinksetDataRead("acl.timestamp"))
            if cache_ts >= global_ts then
                local level = integer(string.sub(raw, 1, sep - 1))
                create_session(user_key, level, level == ACL_BLACKLIST, ROOT_CONTEXT)
                idx = find_session_idx(user_key)
                if idx ~= nil then dispatch_to_plugin(user_key, matched, subpath, Sessions[idx]) end
                return
            end
        end
    end

    -- Cold miss — queue ACL query, preserving the original requested context.
    if PendingAcl[tostring(user_key)] ~= nil then return end
    PendingAcl[tostring(user_key)] = context
    ll.MessageLinked(LINK_SET, AUTH_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "auth.acl.query",
        "avatar", tostring(user_key),
    }), NULL_KEY)
end

function handle_return(msg: string)
    local user_key_str = ll.JsonGetValue(msg, {"user"})
    if user_key_str == JSON_INVALID then return end
    local user_key = uuid(user_key_str)

    local idx = find_session_idx(user_key)
    if idx == nil then
        start_root_session(user_key)
        return
    end

    local session = Sessions[idx]
    local age = ll.GetUnixTime() - session.created
    if age > SESSION_MAX_AGE then
        local sctx = session.context
        cleanup_session(user_key)
        if sctx == SOS_CONTEXT then start_sos_session(user_key) else start_root_session(user_key) end
    else
        send_render_menu(user_key, session.context)
    end
end

-- Force-close a user's dialog and drop their session (also drops cached ACL via
-- re-auth on next touch). Used by plugin_tpe on TPE acceptance.
function handle_close(msg: string)
    local user_key_str = ll.JsonGetValue(msg, {"user"})
    if user_key_str == JSON_INVALID then return end
    cleanup_session(uuid(user_key_str))
end

function handle_dialog_response(msg: string)
    if not validate_required_fields(msg, {"session_id", "button", "user"}) then return end

    local session_id = ll.JsonGetValue(msg, {"session_id"})
    local button = ll.JsonGetValue(msg, {"button"})
    local user = uuid(ll.JsonGetValue(msg, {"user"}))

    local context = ""
    local tmp = ll.JsonGetValue(msg, {"context"})
    if tmp ~= JSON_INVALID then context = tmp end

    for _, s in ipairs(Sessions) do
        if s.id == session_id then
            handle_button_click(user, button, context)
            return
        end
    end
end

function handle_dialog_timeout(msg: string)
    if not validate_required_fields(msg, {"session_id", "user"}) then return end
    local session_id = ll.JsonGetValue(msg, {"session_id"})
    local user = uuid(ll.JsonGetValue(msg, {"user"}))
    for _, s in ipairs(Sessions) do
        if s.id == session_id then
            cleanup_session(user)
            return
        end
    end
end

--[[ -------------------- EVENTS -------------------- ]]

local function declare_root_menu()
    -- ROOT_CONTEXT is not a plugin (no plugin.reg.* entry); this synthetic
    -- registration only feeds kmod_chat's 'menu' alias table.
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", ROOT_CONTEXT,
        "label", "Menu",
        "script", ll.GetScriptName(),
    }), NULL_KEY)
end

local function main()
    if ll.GetObjectDesc() == "COLLAR_UPDATER" then
        ll.SetScriptState(ll.GetScriptName(), false)
        return
    end

    Plugins = {}
    Sessions = {}
    ViewRoot = {}
    ViewSos = {}
    PendingAcl = {}
    TouchTimes = {}

    declare_root_menu()
    schedule_rebuild()
end

function LLEvents.touch_start(detected)
    for _, d in ipairs(detected) do
        local toucher = d:getKey()
        local touch_pos = d:getTouchPos()
        if touch_pos ~= ZERO_VECTOR then
            if ll.VecDist(touch_pos, ll.GetPos()) <= TOUCH_RANGE_M then
                TouchTimes[tostring(toucher)] = ll.GetTime()
            end
        end
    end
end

function LLEvents.touch_end(detected)
    local wearer = ll.GetOwner()
    for _, d in ipairs(detected) do
        local toucher = d:getKey()
        local tkey = tostring(toucher)
        local start_time = TouchTimes[tkey]
        if start_time ~= nil then
            local duration = ll.GetTime() - start_time
            TouchTimes[tkey] = nil
            if duration >= LONG_TOUCH_THRESHOLD and toucher == wearer then
                start_sos_session(toucher)
            else
                if duration >= LONG_TOUCH_THRESHOLD and toucher ~= wearer then
                    send_message(toucher, "Long-touch SOS is only available to the wearer.")
                end
                start_root_session(toucher)
            end
        end
    end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    id = uuid(tostring(id))  -- SLua delivers key event params as strings; normalize to uuid
    local msg_type = get_msg_type(msg)
    if msg_type == "" then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.register.refresh" then
            declare_root_menu()  -- so kmod_chat rebuilds its alias table
        elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
        end
        return
    end

    if num == AUTH_BUS then
        if msg_type == "auth.acl.result" then
            handle_acl_result(msg)
        elseif msg_type == "auth.acl.update" then
            -- Roles changed: drop all sessions so they re-create with fresh ACL.
            for i = #Sessions, 1, -1 do
                cleanup_session(Sessions[i].user)
            end
        end
        return
    end

    if num == UI_BUS then
        if msg_type == "ui.menu.start" then handle_start(msg, id)
        elseif msg_type == "ui.chat.command" then handle_start(msg, id)
        elseif msg_type == "ui.menu.return" then handle_return(msg)
        elseif msg_type == "ui.menu.close" then handle_close(msg)
        end
        return
    end

    if num == DIALOG_BUS then
        if msg_type == "ui.dialog.response" then handle_dialog_response(msg)
        elseif msg_type == "ui.dialog.timeout" then handle_dialog_timeout(msg)
        end
        return
    end
end

-- Plugin registry changes arm a debounced rebuild; a full LSD reset too.
function LLEvents.linkset_data(action: number, name: string, value: string)
    if action == LINKSETDATA_RESET then
        schedule_rebuild()
        return
    end
    if starts_with(name, LSD_PLUGIN_REG_PREFIX) then
        schedule_rebuild()
    end
end

_on_timer = function()
    if ViewsStale then
        ViewsStale = false
        set_timer(0.0)
        rebuild_plugin_list_from_lsd()
        invalidate_all_sessions()
    end
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        ll.ResetScript()
    end
end

-- Top-level init.
main()

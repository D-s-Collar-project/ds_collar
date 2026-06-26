--[[--------------------
MODULE: kmod_ui.lua  (SLua port)
VERSION: 1.2
REVISION: 11  (SLua port rev 1)
PURPOSE: Session management, categorized per-ACL menu views (LSD-resident), and
         plugin dispatch orchestration.
ARCHITECTURE: BIND9-style views. Each plugin self-declares reg.<ctx> =
  {"cat","label","script","mask"} (mask bit L = visible at ACL level L). On any
  reg.* change a debounced rebuild composes one precomputed view per ACL level into
  LSD (ui.view.<acl> / ui.view.<acl>.sos). Per touch: one LSD read fully describes
  the menu. ACL is resolved synchronously from the user-record table by resolve_acl
  (the same ladder kmod_auth runs); no cached snapshot.

SLUA PORT NOTES:
- Ported from kmod_ui.lsl v1.2 rev 11. Wire/CROSS-MODULE contracts preserved
  exactly: emits ui.menu.render / ui.message.show (UI_BUS 900), ui.menu.start to
  plugins, ui.dialog.close (DIALOG_BUS 950), kernel.register.declare (KERNEL 500);
  consumes ui.menu.start / ui.chat.command / ui.menu.return / ui.menu.close and the
  dialog response/timeout/close. The reg.* / ui.view.* / acl.policycontext LSD shapes
  are unchanged. resolve_acl stays in lockstep with kmod_auth route_acl_query.
- GOTCHA (the one needing in-world validation): TOUCH DETECTION. SLua does not use
  llDetectedKey/llDetectedTouchPos — detected data comes from detection objects via
  methods (:getKey(), :getTouchPos()). The touch_start/touch_end handlers iterate the
  event's detection list and call those methods. The method NAMES (esp. getTouchPos)
  are the SLua detail most likely to need an in-world tweak; the surrounding guard
  logic (ZERO_VECTOR / range / long-touch duration) is unchanged.
- IDIOMATIC: the six parallel Session* lists collapse into one array of UISession
  records; the two parallel Touch* lists become a tostring(key)->start-time dict; the
  strided [label,ctx,cat,mask] rebuild table becomes an array of records (label-sorted
  via table.sort). The view object is assembled as a flat {k,v,...} table for
  List2Json(JSON_OBJECT).
- GOTCHA: bit math. mask tests use bit32.band/bit32.lshift (mask & (1<<lvl)); the
  RLV-required bit is bit32.band(mask, MASK_RLV_REQUIRED). csv_lead_int replaces the
  (integer) casts on records/flags. Page math uses floor division (//). Luau `continue`
  replaces the LSL touch-loop `jump next_touch`.
- Single debounce timer (rebuild) via the set_timer shim over LLTimers. uuid()
  normalizes JSON user strings to keys; user notices go through ui.message.show ->
  kmod_menu -> ll.RegionSayTo.
- Single LSL state -> top-level LLEvents.*; state_entry becomes main().
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local UI_BUS           = 900
local DIALOG_BUS       = 950

--[[ -------------------- ACL CONSTANTS (mirror of kmod_auth) -------------------- ]]
local ACL_BLACKLIST     = -1
local ACL_NOACCESS      = 0
local ACL_PUBLIC        = 1
local ACL_OWNED         = 2
local ACL_TRUSTEE       = 3
local ACL_UNOWNED       = 4
local ACL_PRIMARY_OWNER = 5

--[[ -------------------- CONSTANTS -------------------- ]]
local ROOT_CONTEXT = "ui.core.root"
local SOS_CONTEXT  = "ui.sos.root"
local SOS_PREFIX   = "ui.sos."
local MAX_FUNC_BTNS = 9
local TOUCH_RANGE_M = 5.0
local LONG_TOUCH_THRESHOLD = 1.5

local KEY_BOOT_READY = "boot.ready"  -- touch-guard, written by kmod_bootstrap

local MAX_SESSIONS = 5

-- User records + flags read by resolve_acl. Written solely by kmod_settings.
local USER_PREFIX       = "user."
local KEY_ISOWNED       = "access.isowned"
local KEY_PUBLIC_ACCESS = "public.mode"
local KEY_TPE_MODE      = "tpe.mode"

local LSD_REG_PREFIX  = "reg."        -- per-plugin self-declared registry entry
local LSD_VIEW_PREFIX = "ui.view."    -- per-ACL precomputed views (our derived state)
local CAT_CTX_PREFIX  = "cat:"

local CAT_STANDALONE = "Standalone"
local CAT_OTHER      = "Other"

local VIEW_LEVEL_MIN = 0
local VIEW_LEVEL_MAX = 5

-- RLV gating: mask bit 0x40 declares "needs RLV"; dropped from every view while
-- rlv.active == "0". Absent/"1" = show (fail-open).
local MASK_RLV_REQUIRED = 0x40
local KEY_RLV_ACTIVE    = "rlv.active"

local REBUILD_DEBOUNCE = 0.1

--[[ -------------------- STATE -------------------- ]]
-- Registered plugin contexts (chat dispatch + click validation). Labels/cats/masks
-- live in the LSD views, not duplicated in heap.
local PluginContexts: {string} = {}

-- Sessions: NAVIGATION STATE ONLY (ACL is resolved live every render/dispatch).
type UISession = {
    user: any,
    page: number,
    total_pages: number,
    id: string,
    context: string,   -- ROOT_CONTEXT or SOS_CONTEXT
    category: string,  -- "" = root tier; "<Cat>" = inside that category
}
local Sessions: {UISession} = {}

-- Touch tracking: tostring(toucher) -> touch-start time.
local TouchTimes: { [string]: number } = {}

local ViewsStale = false

--[[ -------------------- TIMER SHIM (single debounce timer) -------------------- ]]
local _timerHandle = nil
local _on_timer  -- forward declaration
local function set_timer(interval: number)
    if _timerHandle then
        LLTimers:off(_timerHandle)
        _timerHandle = nil
    end
    if interval > 0 then
        _timerHandle = LLTimers:every(interval, _on_timer)
    end
end

--[[ -------------------- HELPERS -------------------- ]]

local function get_msg_type(msg: string): string
    local t = ll.JsonGetValue(msg, {"type"})
    if t == JSON_INVALID then return "" end
    return t
end

local function csv_lead_int(s: string): number
    return tonumber(string.match(s, "^%s*(-?%d+)") or "") or 0
end

local function validate_required_fields(json_str: string, field_names): boolean
    for _, field in ipairs(field_names) do
        if ll.JsonGetValue(json_str, {field}) == JSON_INVALID then
            return false
        end
    end
    return true
end

local function generate_session_id(user): string
    return "ui_" .. tostring(user) .. "_" .. tostring(ll.GetUnixTime())
end

local function list_has(t: {string}, v: string): boolean
    for _, x in ipairs(t) do
        if x == v then return true end
    end
    return false
end

--[[ -------------------- ACL RESOLUTION (TABLE READ) -------------------- ]]
-- The same ladder kmod_auth's route_acl_query runs. CROSS-MODULE CONTRACT: keep in
-- lockstep with kmod_auth.
local function resolve_acl(avatar): number
    local role = csv_lead_int(ll.LinksetDataRead(USER_PREFIX .. tostring(avatar)))

    if role == ACL_BLACKLIST then return ACL_BLACKLIST end
    if role == ACL_PRIMARY_OWNER then return ACL_PRIMARY_OWNER end

    -- The wearer never has a record — derive from the flags.
    if avatar == ll.GetOwner() then
        if csv_lead_int(ll.LinksetDataRead(KEY_TPE_MODE)) ~= 0 then return ACL_NOACCESS end
        if csv_lead_int(ll.LinksetDataRead(KEY_ISOWNED)) ~= 0 then return ACL_OWNED end
        return ACL_UNOWNED
    end

    if role == ACL_TRUSTEE then return ACL_TRUSTEE end
    if csv_lead_int(ll.LinksetDataRead(KEY_PUBLIC_ACCESS)) ~= 0 then return ACL_PUBLIC end

    -- Unauthorized stranger: level -1, but NOT blacklisted (no record).
    return ACL_BLACKLIST
end

-- TRUE only for an explicit blacklist (-1) record — distinguishes barred from
-- unauthorized-stranger (both resolve to -1).
local function actor_is_blacklisted(avatar): boolean
    return csv_lead_int(ll.LinksetDataRead(USER_PREFIX .. tostring(avatar))) == ACL_BLACKLIST
end

--[[ -------------------- SESSION MANAGEMENT -------------------- ]]

local function find_session_idx(user): number?
    for i, s in ipairs(Sessions) do
        if s.user == user then return i end
    end
    return nil
end

local function find_session_by_id(session_id: string): number?
    for i, s in ipairs(Sessions) do
        if s.id == session_id then return i end
    end
    return nil
end

local function cleanup_session(user)
    local idx = find_session_idx(user)
    if idx == nil then return end
    -- Close the dialog before dropping the session.
    ll.MessageLinked(LINK_SET, DIALOG_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.dialog.close",
        "session_id", Sessions[idx].id,
    }), NULL_KEY)
    table.remove(Sessions, idx)
end

local function create_session(user, context_filter: string)
    if find_session_idx(user) ~= nil then cleanup_session(user) end
    if #Sessions >= MAX_SESSIONS then cleanup_session(Sessions[1].user) end  -- evict oldest

    Sessions[#Sessions + 1] = {
        user = user,
        page = 0,
        total_pages = 0,
        id = generate_session_id(user),
        context = context_filter,
        category = "",
    }
end

--[[ -------------------- VIEW REBUILD (registry -> LSD views) -------------------- ]]

local function rebuild_views()
    -- Wipe stale view keys first.
    for _, k in ipairs(ll.LinksetDataFindKeys("^ui\\.view\\.", 0, -1)) do
        ll.LinksetDataDelete(k)
    end

    local keys = ll.LinksetDataFindKeys("^reg\\.", 0, -1)
    local prefix_len = ll.StringLength(LSD_REG_PREFIX)
    local rlv_off = (ll.LinksetDataRead(KEY_RLV_ACTIVE) == "0")

    -- Registry table: {label, ctx, cat, mask} records, label-sorted.
    local tab: {{ label: string, ctx: string, cat: string, mask: number }} = {}
    for _, k in ipairs(keys) do
        local entry = ll.LinksetDataRead(k)
        local label = ll.JsonGetValue(entry, {"label"})
        if label ~= JSON_INVALID then
            local cat = ll.JsonGetValue(entry, {"cat"})
            if cat == JSON_INVALID then cat = "" end
            local mask = csv_lead_int(ll.JsonGetValue(entry, {"mask"}))
            if not (rlv_off and bit32.band(mask, MASK_RLV_REQUIRED) ~= 0) then
                tab[#tab + 1] = {
                    label = label,
                    ctx = ll.GetSubString(k, prefix_len, -1),
                    cat = cat,
                    mask = mask,
                }
            end
        end
    end
    table.sort(tab, function(a, b) return a.label < b.label end)

    -- Contexts cached in heap for chat dispatch + click validation only.
    PluginContexts = {}
    for _, row in ipairs(tab) do
        PluginContexts[#PluginContexts + 1] = row.ctx
    end

    -- Compose one view per ACL level.
    for lvl = VIEW_LEVEL_MIN, VIEW_LEVEL_MAX do
        local bit = bit32.lshift(1, lvl)
        local sos_pairs = {}
        local standalone_pairs = {}  -- already label-ordered (tab is sorted)
        local cats = {}              -- distinct visible category names

        for _, row in ipairs(tab) do
            if bit32.band(row.mask, bit) ~= 0 then
                if ll.SubStringIndex(row.ctx, SOS_PREFIX) == 0 then
                    sos_pairs[#sos_pairs + 1] = ll.List2Json(JSON_ARRAY, {row.ctx, row.label})
                elseif row.cat == CAT_STANDALONE then
                    standalone_pairs[#standalone_pairs + 1] = ll.List2Json(JSON_ARRAY, {row.ctx, row.label})
                else
                    local cat = row.cat
                    if cat == "" then cat = CAT_OTHER end
                    if not list_has(cats, cat) then cats[#cats + 1] = cat end
                end
            end
        end

        -- Root tier order: categories A-Z first, then Standalone plugins A-Z.
        table.sort(cats)
        local root_pairs = {}
        for _, cname in ipairs(cats) do
            -- Category buttons read "Access..." (the ellipsis signals a drill-down).
            root_pairs[#root_pairs + 1] = ll.List2Json(JSON_ARRAY, {CAT_CTX_PREFIX .. cname, cname .. "..."})
        end
        for _, sp in ipairs(standalone_pairs) do
            root_pairs[#root_pairs + 1] = sp
        end

        -- Assemble the view object: flat {k, v, ...} for List2Json(JSON_OBJECT).
        local obj = {}
        if #root_pairs > 0 then
            obj[#obj + 1] = "root"
            obj[#obj + 1] = ll.List2Json(JSON_ARRAY, root_pairs)
        end
        for _, cname2 in ipairs(cats) do
            local members = {}
            for _, row in ipairs(tab) do
                if bit32.band(row.mask, bit) ~= 0 then
                    local mcat = row.cat
                    if mcat == "" then mcat = CAT_OTHER end
                    if mcat == cname2 and ll.SubStringIndex(row.ctx, SOS_PREFIX) ~= 0 and mcat ~= CAT_STANDALONE then
                        members[#members + 1] = ll.List2Json(JSON_ARRAY, {row.ctx, row.label})
                    end
                end
            end
            obj[#obj + 1] = cname2
            obj[#obj + 1] = ll.List2Json(JSON_ARRAY, members)
        end

        if #obj > 0 then
            ll.LinksetDataWrite(LSD_VIEW_PREFIX .. tostring(lvl), ll.List2Json(JSON_OBJECT, obj))
        end
        if #sos_pairs > 0 then
            ll.LinksetDataWrite(LSD_VIEW_PREFIX .. tostring(lvl) .. ".sos", ll.List2Json(JSON_ARRAY, sos_pairs))
        end
    end
end

-- Arm the debounce timer; multiple writes within the window collapse to one rebuild.
local function schedule_rebuild()
    if not ViewsStale then
        ViewsStale = true
        set_timer(REBUILD_DEBOUNCE)
    end
end

--[[ -------------------- MENU RENDERING (delegated to kmod_menu) -------------------- ]]

-- "[Honorific] Name" for the primary owner (lowest-rank acl-5 record), or "".
local function get_primary_owner_display(): string
    local best_name = ""
    local best_hon = ""
    local best_rank = 0x7FFFFFFF
    for _, k in ipairs(ll.LinksetDataFindKeys("^user\\.", 0, -1)) do
        local rec = ll.LinksetDataRead(k)
        if csv_lead_int(rec) == 5 then
            local f = ll.CSV2List(rec)
            local rank = csv_lead_int(f[2] or "0")
            if rank < best_rank then
                best_rank = rank
                best_name = f[3] or ""
                best_hon = f[4] or ""
            end
        end
    end
    if best_name == "" then return "" end
    if best_hon ~= "" then return best_hon .. " " .. best_name end
    return best_name
end

local function send_message(user, message_text: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.message.show",
        "user", tostring(user),
        "message", message_text,
    }), NULL_KEY)
end

-- Render the session's current tier from the LSD view. ACL is resolved live here.
local function render_session(user)
    local session_idx = find_session_idx(user)
    if session_idx == nil then return end
    local s = Sessions[session_idx]

    local acl = resolve_acl(user)
    local menu_type = s.context
    local category = s.category

    local arr = ""
    if menu_type == SOS_CONTEXT then
        arr = ll.LinksetDataRead(LSD_VIEW_PREFIX .. tostring(acl) .. ".sos")
    else
        local view = ll.LinksetDataRead(LSD_VIEW_PREFIX .. tostring(acl))
        if view ~= "" then
            local sub
            if category == "" then sub = ll.JsonGetValue(view, {"root"})
            else sub = ll.JsonGetValue(view, {category}) end
            if sub ~= JSON_INVALID then arr = sub end
        end
    end

    local entries = {}
    if arr ~= "" and arr ~= "[]" then entries = ll.Json2List(arr) end
    local entry_count = #entries

    if entry_count == 0 then
        -- A category page can only be empty after a rebuild race; fall back to root.
        if category ~= "" and menu_type ~= SOS_CONTEXT then
            s.category = ""
            s.page = 0
            render_session(user)
            return
        end

        if menu_type == SOS_CONTEXT then
            send_message(user, "No emergency options are currently available.")
        else
            if acl == ACL_BLACKLIST then
                if actor_is_blacklisted(user) then
                    send_message(user, "You have been barred from using this collar.")
                else
                    local primary_owner = get_primary_owner_display()
                    if primary_owner ~= "" then
                        send_message(user, "This collar is owned by " .. primary_owner .. " and is exclusive to them.")
                    else
                        send_message(user, "This collar is not available for public use.")
                    end
                end
            elseif acl == ACL_NOACCESS then
                send_message(user, "You have relinquished control of the collar.")
            else
                send_message(user, "No plugins are currently installed.")
            end
        end

        cleanup_session(user)
        return
    end

    local current_page = s.page
    local total_pages = (entry_count + MAX_FUNC_BTNS - 1) // MAX_FUNC_BTNS
    if current_page >= total_pages then current_page = 0 end
    if current_page < 0 then current_page = total_pages - 1 end

    s.page = current_page
    s.total_pages = total_pages

    -- kmod_menu owns the page slice — hand it the FULL list.
    local button_data = {}
    for _, pair in ipairs(entries) do
        button_data[#button_data + 1] = ll.List2Json(JSON_OBJECT, {
            "context", ll.JsonGetValue(pair, {0}),
            "label", ll.JsonGetValue(pair, {1}),
        })
    end

    -- DESIGN: Navigation row is ALWAYS present (has_nav=1).
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.render",
        "user", tostring(user),
        "session_id", s.id,
        "menu_type", menu_type,
        "category", category,
        "page", current_page,
        "total_pages", total_pages,
        "buttons", ll.List2Json(JSON_ARRAY, button_data),
        "has_nav", 1,
    }), NULL_KEY)
end

--[[ -------------------- BUTTON HANDLING -------------------- ]]

-- Longest registered plugin context that exactly matches or is a dot-boundary
-- prefix of `requested`. "" if none.
local function resolve_plugin_context(requested: string): string
    if list_has(PluginContexts, requested) then return requested end

    local best_len = 0
    local best = ""
    for _, pc in ipairs(PluginContexts) do
        local plen = ll.StringLength(pc)
        if plen > best_len and ll.StringLength(requested) > plen then
            if ll.GetSubString(requested, 0, plen - 1) == pc and ll.GetSubString(requested, plen, plen) == "." then
                best = pc
                best_len = plen
            end
        end
    end
    return best
end

local function extract_subpath(requested: string, plugin_context: string): string
    local plen = ll.StringLength(plugin_context)
    if ll.StringLength(requested) <= plen + 1 then return "" end
    return ll.GetSubString(requested, plen + 1, -1)
end

-- Dispatch ui.menu.start to a plugin. ACL resolved LIVE; policy re-checked as the
-- authorization gate (the view mask only governs visibility).
local function dispatch_to_plugin(user, context: string, subpath: string)
    local user_acl = resolve_acl(user)
    local policy = ll.LinksetDataRead("acl.policycontext:" .. context)
    if policy == "" then
        send_message(user, "Access denied.")
        return
    end
    local csv = ll.JsonGetValue(policy, {tostring(user_acl)})
    if csv == JSON_INVALID then
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

local function handle_button_click(user, context: string)
    local session_idx = find_session_idx(user)
    if session_idx == nil then return end
    local s = Sessions[session_idx]

    -- Blacklist gate (resolved live).
    if actor_is_blacklisted(user) then
        send_message(user, "You have been barred from using this collar.")
        cleanup_session(user)
        return
    end

    -- Navigation routes by context (nav:*).
    if context == "nav:prev" then
        s.page = s.page - 1
        if s.page < 0 then s.page = s.total_pages - 1 end
        render_session(user)
        return
    end
    if context == "nav:next" then
        s.page = s.page + 1
        if s.page >= s.total_pages then s.page = 0 end
        render_session(user)
        return
    end
    if context == "nav:back" then
        s.category = ""
        s.page = 0
        render_session(user)
        return
    end

    -- Category button: descend.
    if ll.GetSubString(context, 0, 3) == CAT_CTX_PREFIX then
        s.category = ll.GetSubString(context, 4, -1)
        s.page = 0
        render_session(user)
        return
    end

    -- Plugin button: dispatch (session keeps its category for the plugin's Back).
    if context ~= "" then
        if list_has(PluginContexts, context) then
            dispatch_to_plugin(user, context, "")
        end
    end
end

--[[ -------------------- MESSAGE HANDLERS -------------------- ]]

-- Open a menu session (root or SOS) for a user.
local function start_session(user_key, context_filter: string)
    create_session(user_key, context_filter)
    render_session(user_key)
end

local function handle_start(msg: string, user_key)
    -- Messages with an acl field are already routed (destined for a plugin).
    if ll.JsonGetValue(msg, {"acl"}) ~= JSON_INVALID then return end

    if ll.JsonGetValue(msg, {"context"}) == JSON_INVALID then
        start_session(user_key, ROOT_CONTEXT)
        return
    end

    local context = ll.JsonGetValue(msg, {"context"})

    if context == ROOT_CONTEXT then
        start_session(user_key, ROOT_CONTEXT)
        return
    end
    if context == SOS_CONTEXT then
        start_session(user_key, SOS_CONTEXT)
        return
    end

    -- Plugin-specific context (longest-prefix match handles namespaced subcommands).
    local matched = resolve_plugin_context(context)
    if matched == "" then
        start_session(user_key, ROOT_CONTEXT)  -- unrecognized -> fall back to root
        return
    end
    local subpath = extract_subpath(context, matched)

    -- Ensure a root session exists so the plugin's Back has somewhere to land.
    if find_session_idx(user_key) == nil then
        create_session(user_key, ROOT_CONTEXT)
    end
    dispatch_to_plugin(user_key, matched, subpath)
end

local function handle_return(msg: string)
    local user_key_str = ll.JsonGetValue(msg, {"user"})
    if user_key_str == JSON_INVALID then return end
    local user_key = uuid(user_key_str)

    if find_session_idx(user_key) ~= nil then
        render_session(user_key)
    else
        start_session(user_key, ROOT_CONTEXT)
    end
end

-- Force-close a user's dialog + drop their session (e.g. plugin_tpe on acceptance).
local function handle_close(msg: string)
    local user_key_str = ll.JsonGetValue(msg, {"user"})
    if user_key_str == JSON_INVALID then return end
    cleanup_session(uuid(user_key_str))
end

local function handle_dialog_response(msg: string)
    if not validate_required_fields(msg, {"session_id", "button", "user"}) then return end

    local session_id = ll.JsonGetValue(msg, {"session_id"})
    local user = uuid(ll.JsonGetValue(msg, {"user"}))

    local context = ""
    local tmp = ll.JsonGetValue(msg, {"context"})
    if tmp ~= JSON_INVALID then context = tmp end

    if find_session_by_id(session_id) ~= nil then
        handle_button_click(user, context)
    end
end

local function handle_dialog_timeout(msg: string)
    if not validate_required_fields(msg, {"session_id", "user"}) then return end

    local session_id = ll.JsonGetValue(msg, {"session_id"})
    local user = uuid(ll.JsonGetValue(msg, {"user"}))

    if find_session_by_id(session_id) ~= nil then
        cleanup_session(user)
    end
end

--[[ -------------------- TICK BODY (rebuild debounce) -------------------- ]]

_on_timer = function()
    if ViewsStale then
        ViewsStale = false
        set_timer(0)
        rebuild_views()
    end
end

--[[ -------------------- EVENTS -------------------- ]]

local function emit_root_declare()
    -- Advertise the root menu context so kmod_chat can build a 'menu' alias. Root is
    -- NOT a plugin and gets no reg.* entry — this only feeds the alias table.
    ll.MessageLinked(LINK_SET, KERNEL_LIFECYCLE, ll.List2Json(JSON_OBJECT, {
        "type", "kernel.register.declare",
        "context", ROOT_CONTEXT,
        "label", "Menu",
        "script", ll.GetScriptName(),
    }), NULL_KEY)
end

local function main()
    PluginContexts = {}
    Sessions = {}
    TouchTimes = {}
    emit_root_declare()
    -- Prime an initial rebuild; late registrations stream in via linkset_data.
    schedule_rebuild()
end

-- TOUCH DETECTION — see SLUA PORT NOTES. SLua delivers detections as objects with
-- :getKey() / :getTouchPos() methods (NOT llDetectedKey). Iterate the event's
-- detection list; method names (esp. getTouchPos) may need an in-world tweak.
function LLEvents.touch_start(detected)
    for _, d in ipairs(detected) do
        local touch_pos = d:getTouchPos()
        if touch_pos == ZERO_VECTOR then continue end           -- skip invalid touches
        if ll.VecDist(touch_pos, ll.GetPos()) > TOUCH_RANGE_M then continue end  -- range
        TouchTimes[tostring(d:getKey())] = ll.GetTime()
    end
end

function LLEvents.touch_end(detected)
    local wearer = ll.GetOwner()
    for _, d in ipairs(detected) do
        local toucher = d:getKey()
        local tk = tostring(toucher)
        local start_time = TouchTimes[tk]
        if start_time ~= nil then
            local duration = ll.GetTime() - start_time
            TouchTimes[tk] = nil

            if duration >= LONG_TOUCH_THRESHOLD and toucher == wearer then
                -- SOS (emergency eject) is exempt from the touch-guard.
                start_session(toucher, SOS_CONTEXT)
            else
                if duration >= LONG_TOUCH_THRESHOLD and toucher ~= wearer then
                    send_message(toucher, "Long-touch SOS is only available to the wearer.")
                end
                -- Touch-guard: swallow the normal menu while still booting.
                if ll.LinksetDataRead(KEY_BOOT_READY) ~= "1" then
                    send_message(toucher, "Collar is still starting up — one moment.")
                else
                    start_session(toucher, ROOT_CONTEXT)
                end
            end
        end
    end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local msg_type = get_msg_type(msg)
    if msg_type == "" then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.register.refresh" then
            emit_root_declare()  -- re-emit so kmod_chat rebuilds its alias table
        elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.ResetScript()
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
        elseif msg_type == "ui.dialog.close" then handle_dialog_timeout(msg)  -- Close = same teardown
        end
        return
    end
end

-- Registry changes arm a debounced rebuild. Our ui.view.* writes don't match the
-- reg. prefix, so a rebuild can't retrigger itself.
function LLEvents.linkset_data(action: number, name: string, value: string)
    if action == LINKSETDATA_RESET then
        schedule_rebuild()
        return
    end
    if ll.SubStringIndex(name, LSD_REG_PREFIX) == 0 then
        schedule_rebuild()
    elseif name == KEY_RLV_ACTIVE then
        schedule_rebuild()  -- RLV detection flips which gated plugins are visible
    end
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then
        ll.ResetScript()
    end
end

main()

--[[--------------------
PLUGIN: plugin_strip.lua  (SLua port)
VERSION: 1.10
PURPOSE: Strip worn layers / attachments via RLV @remoutfit / @remattach,
         with lock detection (per-layer, per-slot, global, and folder locks).
ARCHITECTURE: Consolidated message bus lanes; RLV queries routed through kmod_rlv
              (rlv.force) with replies on RLV_CHAN.

SLUA PORT NOTES:
- Ported from plugin_strip.lsl. RLV query chain (@getoutfit / @getstatusall),
  the RLV_CHAN listen, and the UI wire format are unchanged.
- SLua conventions: LLEvents.* handlers, local main(). WornLayers is a string
  array; WornAttach is an array of {slot,item} records; lock lists are string
  arrays. Outfit-bitstring and attach-point indices convert 0-based(LSL)→1-based.
----------------------]]

--[[ -------------------- CONSOLIDATED ISP -------------------- ]]
local KERNEL_LIFECYCLE = 500
local UI_BUS           = 900
local DIALOG_BUS       = 950

--[[ -------------------- PLUGIN IDENTITY -------------------- ]]
local PLUGIN_CONTEXT = "ui.core.strip"
local PLUGIN_LABEL   = "Strip"

--[[ -------------------- RLV -------------------- ]]
local RLV_CHAN    = 1888771
local RLV_TIMEOUT = 10.0

--[[ -------------------- LAYERS / ATTACH (LSL 0-based domains) -------------------- ]]
local LAYER_NAMES = {
    "gloves", "jacket", "pants", "shirt", "shoes", "skirt", "socks",
    "underpants", "undershirt", "skull", "eyes", "hair", "shape",
    "alpha", "tattoo", "physics", "universal",
}
local STRIPPABLE_LAYER_IDX = {0, 1, 2, 3, 4, 5, 6, 7, 8, 13, 14, 15, 16}

local ATTACH_NAMES = {
    "",
    "chest", "skull", "left shoulder", "right shoulder",
    "left hand", "right hand", "left foot", "right foot",
    "spine", "pelvis",
    "mouth", "chin", "left ear", "right ear",
    "left eye", "right eye", "nose",
    "r upper arm", "r forearm", "l upper arm", "l forearm",
    "right hip", "r upper leg", "r lower leg",
    "left hip", "l upper leg", "l lower leg",
    "stomach", "left pec", "right pec",
    "center 2", "top right", "top", "top left", "center",
    "bottom left", "bottom", "bottom right",
    "neck", "root",
    "left ring finger", "right ring finger",
    "tail base", "tail tip",
    "left wing", "right wing",
    "jaw",
    "alt left ear", "alt right ear",
    "alt left eye", "alt right eye",
    "tongue",
    "groin",
    "left hind foot", "right hind foot",
}

--[[ -------------------- STATE -------------------- ]]
local CurrentUser    = NULL_KEY
local gPolicyButtons = {}
local SessionId      = ""

local QState = 0  -- 1=getoutfit 2=remoutfit 3=remattach 4=detach 0=idle

local RawOutfit          = ""
local GlobalOutfitLocked = false
local GlobalAttachLocked = false
local LockedLayers       = {}   -- layer names
local LockedAttach       = {}   -- slot names
local LockedFolders      = {}   -- detachallthis paths (header display)
local WornLayers         = {}   -- array of layer names
local WornAttach         = {}   -- array of { slot, item }

local CurrentCategory = ""      -- "" chooser, "L" layers, "A" attach
local PickPage    = 0
local LastMaxPage = 0

local AttemptedItem    = ""
local DiscoveredLocked = {}

local RlvListenHandle = 0

--[[ -------------------- HELPERS -------------------- ]]

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

local function sid(): string
    return PLUGIN_CONTEXT .. "_" .. tostring(ll.GetUnixTime())
end

local function btn(label: string, ctx: string): string
    return ll.List2Json(JSON_OBJECT, {"label", label, "context", ctx})
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

local function ellipsize(s: string, max_len: number): string
    if #s <= max_len then return s end
    if max_len <= 3 then return string.sub(s, 1, max_len) end
    return string.sub(s, 1, max_len - 3) .. "..."
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
        "1", "Strip", "2", "Strip", "3", "Strip", "4", "Strip", "5", "Strip",
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

local function stop_rlv_listen()
    if RlvListenHandle ~= 0 then
        ll.ListenRemove(RlvListenHandle)
        RlvListenHandle = 0
    end
    ll.SetTimerEvent(0.0)
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
    gPolicyButtons = {}
    QState = 0
    RawOutfit = ""
    GlobalOutfitLocked = false
    GlobalAttachLocked = false
    LockedLayers = {}
    LockedAttach = {}
    LockedFolders = {}
    WornLayers = {}
    WornAttach = {}
    CurrentCategory = ""
    PickPage = 0
    LastMaxPage = 0
    AttemptedItem = ""
    DiscoveredLocked = {}
end

local function return_to_root()
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "ui.menu.return", "context", PLUGIN_CONTEXT, "user", tostring(CurrentUser),
    }), NULL_KEY)
    cleanup_session()
end

--[[ -------------------- RLV QUERY CHAIN -------------------- ]]

local function rlv_force(command: string)
    ll.MessageLinked(LINK_SET, UI_BUS, ll.List2Json(JSON_OBJECT, {
        "type", "rlv.force", "command", command,
    }), NULL_KEY)
end

local function begin_query()
    RawOutfit = ""
    GlobalOutfitLocked = false
    GlobalAttachLocked = false
    LockedLayers = {}
    LockedAttach = {}
    LockedFolders = {}
    WornLayers = {}
    WornAttach = {}

    QState = 1
    if RlvListenHandle == 0 then RlvListenHandle = ll.Listen(RLV_CHAN, "", ll.GetOwner(), "") end
    ll.SetTimerEvent(RLV_TIMEOUT)
    rlv_force("@getoutfit=" .. tostring(RLV_CHAN))
end

-- `;|` separator: @detachallthis paths embed '/', so the default separator
-- would split mid-path.
local function advance_query()
    ll.SetTimerEvent(RLV_TIMEOUT)
    if QState == 2 then rlv_force("@getstatusall:remoutfit;|=" .. tostring(RLV_CHAN))
    elseif QState == 3 then rlv_force("@getstatusall:remattach;|=" .. tostring(RLV_CHAN))
    elseif QState == 4 then rlv_force("@getstatusall:detach;|=" .. tostring(RLV_CHAN)) end
end

--[[ -------------------- RESPONSE PARSERS -------------------- ]]

-- Parse "|key:val|key" responses. A bare key (no :val) → leading "" entry.
local function parse_status(raw: string, key_name: string)
    local out = {}
    if raw == "" then return out end
    local prefix = key_name .. ":"
    local global_seen = false
    for _, raw_p in ipairs(ll.ParseString2List(raw, {"|"}, {})) do
        local p = ll.StringTrim(raw_p, STRING_TRIM)
        if p == key_name then
            global_seen = true
        elseif starts_with(p, prefix) then
            out[#out + 1] = string.sub(p, #prefix + 1)
        end
    end
    if global_seen then table.insert(out, 1, "") end
    return out
end

local function parse_detachallthis(raw: string)
    local out = {}
    if raw == "" then return out end
    local prefix = "detachallthis:"
    for _, raw_p in ipairs(ll.ParseString2List(raw, {"|"}, {})) do
        local p = ll.StringTrim(raw_p, STRING_TRIM)
        if starts_with(p, prefix) then
            local path = string.sub(p, #prefix + 1)
            if path ~= "" then out[#out + 1] = path end
        end
    end
    return out
end

--[[ -------------------- BUILD WORN LISTS -------------------- ]]

local function build_worn_layers()
    WornLayers = {}
    local layer_count = #RawOutfit
    for _, layer_idx in ipairs(STRIPPABLE_LAYER_IDX) do  -- layer_idx is 0-based
        if layer_idx < layer_count and string.sub(RawOutfit, layer_idx + 1, layer_idx + 1) == "1" then
            local layer_name = LAYER_NAMES[layer_idx + 1]
            local skip = false
            if GlobalOutfitLocked then skip = true end
            if not skip and list_find(LockedLayers, layer_name) ~= nil then skip = true end
            -- DiscoveredLocked layers stay visible (marked " *" by show_picker).
            if not skip then WornLayers[#WornLayers + 1] = layer_name end
        end
    end
end

-- HUD attach points (31-38) skipped via the range check.
local function build_worn_attach()
    WornAttach = {}
    local attach_names_n = #ATTACH_NAMES
    for _, k in ipairs(ll.GetAttachedList(ll.GetOwner())) do
        local details = ll.GetObjectDetails(k, {OBJECT_NAME, OBJECT_ATTACHED_POINT})
        if #details >= 2 then
            local item_name = details[1]
            local pt = details[2]
            if pt > 0 and pt < attach_names_n and (pt < 31 or pt > 38) then
                local slot_name = ATTACH_NAMES[pt + 1]
                if slot_name ~= "" then
                    local skip = false
                    if GlobalAttachLocked then skip = true end
                    if not skip and list_find(LockedAttach, slot_name) ~= nil then skip = true end
                    if not skip then WornAttach[#WornAttach + 1] = { slot = slot_name, item = item_name } end
                end
            end
        end
    end
end

--[[ -------------------- POST-STRIP VERIFY -------------------- ]]

local function is_layer_still_worn(layer_name: string): boolean
    local pos = list_find(LAYER_NAMES, layer_name)
    if pos == nil then return false end
    local idx0 = pos - 1  -- 0-based bit index
    if idx0 >= #RawOutfit then return false end
    return string.sub(RawOutfit, idx0 + 1, idx0 + 1) == "1"
end

local function is_attach_slot_worn(slot_name: string): boolean
    local attach_names_n = #ATTACH_NAMES
    for _, k in ipairs(ll.GetAttachedList(ll.GetOwner())) do
        local det = ll.GetObjectDetails(k, {OBJECT_ATTACHED_POINT})
        if #det >= 1 then
            local pt = det[1]
            if pt > 0 and pt < attach_names_n and ATTACH_NAMES[pt + 1] == slot_name then
                return true
            end
        end
    end
    return false
end

local function verify_attempted_strip()
    if AttemptedItem == "" then return end
    local parts = ll.ParseString2List(AttemptedItem, {":"}, {})
    if #parts ~= 2 then
        AttemptedItem = ""
        return
    end
    local atype = parts[1]
    local aname = parts[2]

    local still_worn = false
    if atype == "L" then still_worn = is_layer_still_worn(aname)
    elseif atype == "A" then still_worn = is_attach_slot_worn(aname) end

    if still_worn then
        if list_find(DiscoveredLocked, AttemptedItem) == nil then
            DiscoveredLocked[#DiscoveredLocked + 1] = AttemptedItem
        end
        ll.RegionSayTo(CurrentUser, 0, aname .. " is locked — cannot strip.")
    end
    AttemptedItem = ""
end

--[[ -------------------- UI -------------------- ]]

local function locked_folders_line(): string
    if #LockedFolders == 0 then return "" end
    return "Locked folders: " .. ellipsize(ll.DumpList2String(LockedFolders, ", "), 48) .. "\n"
end

local function show_category_menu()
    SessionId = sid()
    CurrentCategory = ""
    PickPage = 0
    LastMaxPage = 0

    local body = "Strip menu\n\n"
        .. locked_folders_line()
        .. "Layers:      " .. tostring(#WornLayers) .. " strippable\n"
        .. "Attachments: " .. tostring(#WornAttach) .. " strippable\n\n"
        .. "Choose category."

    local button_data = {btn("Layers", "layers"), btn("Attachments", "attach"), btn("Back", "back")}

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

local function show_picker(category: string, page: number)
    local total, header
    if category == "L" then
        total = #WornLayers
        header = "Strip — Layers\n"
    else
        total = #WornAttach
        header = "Strip — Attachments\n"
    end

    SessionId = sid()
    CurrentCategory = category

    local page_size = 9
    local max_page = 0
    if total > 0 then max_page = (total - 1) // page_size end
    if page < 0 then page = 0 end
    if page > max_page then page = max_page end
    PickPage = page
    LastMaxPage = max_page

    local start_idx = page * page_size  -- 0-based
    local end_idx = start_idx + page_size
    if end_idx > total then end_idx = total end
    local count = end_idx - start_idx

    local body = header .. locked_folders_line()
    if #DiscoveredLocked > 0 then body = body .. "* = locked\n" end
    if total == 0 then
        body = body .. "\nNothing to strip."
    else
        body = body .. "Page " .. tostring(page + 1) .. " of " .. tostring(max_page + 1) .. "\n\n"
        for k = 0, count - 1 do
            local item_idx = start_idx + k  -- 0-based
            local mark = ""
            if category == "L" then
                local layer_name = WornLayers[item_idx + 1]
                if list_find(DiscoveredLocked, "L:" .. layer_name) ~= nil then mark = " *" end
                body = body .. tostring(k + 1) .. ". " .. ellipsize(layer_name, 28) .. mark .. "\n"
            else
                local rec = WornAttach[item_idx + 1]
                if list_find(DiscoveredLocked, "A:" .. rec.slot) ~= nil then mark = " *" end
                local disp = ellipsize(rec.item .. " @" .. rec.slot, 30)
                body = body .. tostring(k + 1) .. ". " .. disp .. mark .. "\n"
            end
        end
    end

    -- Layout: slots 0-2 nav, 3-11 content top→bottom.
    local button_data = {btn("<<", "prev"), btn(">>", "next"), btn("Back", "back")}
    for _ = 1, count do button_data[#button_data + 1] = btn(" ", " ") end

    local total_buttons = 3 + count
    local target_slots = {}
    local function add(s) target_slots[#target_slots + 1] = s end
    if total_buttons > 9 then add(9) end
    if total_buttons > 10 then add(10) end
    if total_buttons > 11 then add(11) end
    if total_buttons > 6 then add(6) end
    if total_buttons > 7 then add(7) end
    if total_buttons > 8 then add(8) end
    if total_buttons > 3 then add(3) end
    if total_buttons > 4 then add(4) end
    if total_buttons > 5 then add(5) end

    for ci = 0, count - 1 do
        button_data[target_slots[ci + 1] + 1] = btn(tostring(ci + 1), "pick:" .. tostring(start_idx + ci))
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

local function show_current_picker(page: number)
    if CurrentCategory == "L" or CurrentCategory == "A" then show_picker(CurrentCategory, page)
    else show_category_menu() end
end

local function apply_pick(item_idx: number)  -- item_idx is 0-based
    if CurrentCategory == "L" then
        if item_idx < 0 or item_idx >= #WornLayers then return end
        local layer_name = WornLayers[item_idx + 1]
        AttemptedItem = "L:" .. layer_name
        rlv_force("@remoutfit:" .. layer_name .. "=force")
    elseif CurrentCategory == "A" then
        if item_idx < 0 or item_idx >= #WornAttach then return end
        local slot_name = WornAttach[item_idx + 1].slot
        AttemptedItem = "A:" .. slot_name
        rlv_force("@remattach:" .. slot_name .. "=force")
    else
        return
    end
    begin_query()
end

--[[ -------------------- DIALOG HANDLER -------------------- ]]

local function handle_dialog_response(msg: string)
    if not json_has(msg, {"session_id"}) then return end
    if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
    if uuid(ll.JsonGetValue(msg, {"user"})) ~= CurrentUser then return end

    local ctx = ll.JsonGetValue(msg, {"context"})
    if ctx == JSON_INVALID then ctx = "" end

    if CurrentCategory == "" then
        if ctx == "layers" then show_picker("L", 0)
        elseif ctx == "attach" then show_picker("A", 0)
        elseif ctx == "back" then return_to_root() end
        return
    end

    if ctx == "back" then show_category_menu(); return end
    if ctx == "prev" then
        if PickPage == 0 then show_current_picker(LastMaxPage) else show_current_picker(PickPage - 1) end
        return
    end
    if ctx == "next" then
        if PickPage >= LastMaxPage then show_current_picker(0) else show_current_picker(PickPage + 1) end
        return
    end
    if starts_with(ctx, "pick:") then
        apply_pick(integer(string.sub(ctx, 6)))
    end
end

local function handle_dialog_timeout(msg: string)
    if not json_has(msg, {"session_id"}) then return end
    if ll.JsonGetValue(msg, {"session_id"}) ~= SessionId then return end
    cleanup_session()
end

--[[ -------------------- RLV RESPONSE -------------------- ]]

local function handle_rlv_response(message: string)
    if CurrentUser == NULL_KEY then return end

    if QState == 1 then
        RawOutfit = message
        QState = 2
        advance_query()
        return
    end
    if QState == 2 then
        local parsed = parse_status(message, "remoutfit")
        if #parsed > 0 and parsed[1] == "" then
            GlobalOutfitLocked = true
            table.remove(parsed, 1)
        end
        LockedLayers = parsed
        QState = 3
        advance_query()
        return
    end
    if QState == 3 then
        local parsed = parse_status(message, "remattach")
        if #parsed > 0 and parsed[1] == "" then
            GlobalAttachLocked = true
            table.remove(parsed, 1)
        end
        LockedAttach = parsed
        QState = 4
        advance_query()
        return
    end
    if QState == 4 then
        local parsed = parse_status(message, "detach")
        if #parsed > 0 and parsed[1] == "" then table.remove(parsed, 1) end
        for _, pt in ipairs(parsed) do
            if pt ~= "" and list_find(LockedAttach, pt) == nil then LockedAttach[#LockedAttach + 1] = pt end
        end
        LockedFolders = parse_detachallthis(message)

        verify_attempted_strip()
        build_worn_layers()
        build_worn_attach()
        QState = 0
        stop_rlv_listen()
        show_current_picker(PickPage)
    end
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

function LLEvents.on_rez(param: number)
    ll.ResetScript()
end

function LLEvents.changed(change: number)
    if bit32.band(change, CHANGED_OWNER) ~= 0 then ll.ResetScript() end
end

function LLEvents.timer()
    stop_rlv_listen()
    if CurrentUser ~= NULL_KEY then
        ll.RegionSayTo(CurrentUser, 0, "RLV not responding. Is RLV mode enabled?")
        return_to_root()
    end
end

function LLEvents.listen(channel: number, name: string, id, message: string)
    if channel == RLV_CHAN and id == ll.GetOwner() then handle_rlv_response(message) end
end

function LLEvents.link_message(sender: number, num: number, msg: string, id)
    local msg_type = ll.JsonGetValue(msg, {"type"})
    if msg_type == JSON_INVALID then return end

    if num == KERNEL_LIFECYCLE then
        if msg_type == "kernel.register.refresh" then register_self()
        elseif msg_type == "kernel.ping" then send_pong()
        elseif msg_type == "kernel.reset.soft" or msg_type == "kernel.reset.factory" then
            ll.LinksetDataDelete("plugin.reg." .. PLUGIN_CONTEXT)
            ll.LinksetDataDelete("acl.policycontext:" .. PLUGIN_CONTEXT)
            ll.ResetScript()
        end
    elseif num == UI_BUS then
        if msg_type == "ui.menu.start" then
            if ll.JsonGetValue(msg, {"acl"}) == JSON_INVALID then return end
            if ll.JsonGetValue(msg, {"context"}) ~= PLUGIN_CONTEXT then return end
            if id == NULL_KEY then return end

            local start_acl = integer(ll.JsonGetValue(msg, {"acl"}))
            gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, start_acl)
            if not btn_allowed("Strip") then
                ll.RegionSayTo(id, 0, "Access denied.")
                gPolicyButtons = {}
                return
            end
            gPolicyButtons = {}

            CurrentUser = id
            CurrentCategory = ""
            PickPage = 0
            ll.RegionSayTo(CurrentUser, 0, "Reading worn items...")
            begin_query()
        end
    elseif num == DIALOG_BUS then
        if msg_type == "ui.dialog.response" then handle_dialog_response(msg)
        elseif msg_type == "ui.dialog.timeout" then handle_dialog_timeout(msg) end
    end
end

-- Top-level init.
main()

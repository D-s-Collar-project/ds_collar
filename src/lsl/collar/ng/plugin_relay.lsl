/*--------------------
PLUGIN: plugin_relay.lsl
VERSION: 1.10
REVISION: 22
PURPOSE: Wearer-facing UI for the collar's RLV relay.
ARCHITECTURE: Menu/chat-alias front-end on top of kmod_rlv. The relay
  protocol engine (RELAY_CHANNEL listen, auth queue, ASK dialog, source
  bookkeeping, refcount, distance GC, TempObj/Av lists) lives in
  kmod_rlv; this script just renders the wearer menu, persists Mode /
  Hardcore via SETTINGS_BUS, and signals kmod_rlv on UI_BUS for safeword
  / ground-rez / source-list lookups.
CHANGES:
- v1.1 rev 22: Split off the relay engine into kmod_rlv (Mono per-script
  byte budget). plugin_relay is now ~UI-only; refcount + auth + sources
  + ASK dialog moved out. "Bound by..." is async via relay.list.request
  / relay.list.response on UI_BUS.
- v1.1 rev 21: Full rewrite as port of Satomi Ahn's multirelay (engine
  later moved to kmod_rlv in rev 22).
- v1.1 rev 20: Correct product name in IMPL_VERSION reply.
- v1.1 rev 19: Add ORG capability-probe handlers.
- v1.1 rev 18: Drop "[RELAY]" source prefix.
- v1.1 rev 17: ASK early-ack-deferred-apply (later replaced).
- v1.1 rev 16: ASK queue + cap (later replaced).
- v1.1 rev 15: persist_mode / persist_hardcore stop pre-writing LSD.
- v1.1 rev 14: Strict ORG parser.
- v1.1 rev 13: write_plugin_reg guards idempotent writes.
- v1.1 rev 12: apply_settings_sync mirrors mode-change side effects.
- v1.1 rev 11: Dormancy guard for COLLAR_UPDATER object description.
- v1.1 rev 10: Self-declare menu presence via plugin.reg.<ctx> LSD.
- v1.1 rev 9: ASK provisional-accept (superseded).
- v1.1 rev 8: User notices via llRegionSayTo.
- v1.1 rev 7: Chat command support.
- v1.1 rev 6: sos.relay.clear handler on UI_BUS.
- v1.1 rev 5: Wire-type rename.
- v1.1 rev 4: handle_ground_rez takes a reason string.
- v1.1 rev 3: Guard ui.menu.start against raw kmod_chat broadcasts.
- v1.1 rev 2: Namespace internal message type strings.
- v1.1 rev 1: Migrate settings reads from JSON broadcast to direct LSD.
- v1.1 rev 0: Self-declared button visibility policy via LSD.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.relay";
string PLUGIN_LABEL = "RLV Relay";

/* -------------------- RELAY MODE CONSTANTS -------------------- */
integer MODE_OFF = 0;
integer MODE_ON  = 1;
integer MODE_ASK = 2;

/* -------------------- SETTINGS KEYS -------------------- */
string KEY_RELAY_MODE = "relay.mode";
string KEY_RELAY_HARDCORE = "relay.hardcoremode";

/* -------------------- STATE -------------------- */

// Cached display state, read from LSD. Refreshed on menu open and on
// settings.delta.
integer Mode = MODE_ASK;
integer Hardcore = FALSE;
integer IsAttached = FALSE;

// Menu session.
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId = "";

// Pending "Bound by..." request — TRUE while we're waiting for kmod_rlv's
// relay.list.response. We render once it arrives.
integer AwaitingList = FALSE;


/* -------------------- HELPERS -------------------- */

integer lsd_int(string lsd_key, integer fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (integer)v;
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

string truncate_name(string name, integer max_len) {
    if (llStringLength(name) <= max_len) return name;
    return llGetSubString(name, 0, max_len - 4) + "...";
}

list get_policy_buttons(string ctx, integer acl) {
    string policy = llLinksetDataRead("acl.policycontext:" + ctx);
    if (policy == "") return [];
    string csv = llJsonGetValue(policy, [(string)acl]);
    if (csv == JSON_INVALID) return [];
    return llCSV2List(csv);
}

integer btn_allowed(string label) {
    return (llListFindList(gPolicyButtons, [label]) != -1);
}

string mode_str() {
    if (!IsAttached)              return "OFF (not worn)";
    if (Mode == MODE_OFF)         return "OFF";
    if (Mode == MODE_ASK)         return "ASK";
    if (Hardcore)                 return "HARDCORE";
    return "ON";
}

refresh_mode() {
    Mode = lsd_int(KEY_RELAY_MODE, MODE_ASK);
    Hardcore = lsd_int(KEY_RELAY_HARDCORE, FALSE);
}


/* -------------------- LIFECYCLE -------------------- */

write_plugin_reg(string label) {
    string k = "plugin.reg." + PLUGIN_CONTEXT;
    string v = llList2Json(JSON_OBJECT, [
        "label",  label,
        "script", llGetScriptName()
    ]);
    if (llLinksetDataRead(k) == v) return;
    llLinksetDataWrite(k, v);
}

register_self() {
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "2", "Mode,Bound by...,Safeword",
        "3", "Mode,Bound by...,Unbind,HC OFF,HC ON",
        "4", "Mode,Bound by...,Safeword",
        "5", "Mode,Bound by...,Unbind,HC OFF,HC ON"
    ]));

    write_plugin_reg(PLUGIN_LABEL);

    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
    ]), NULL_KEY);

    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "relay",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "safeword",
        "context", PLUGIN_CONTEXT + ".safeword"
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}


/* -------------------- SETTINGS -------------------- */

persist_mode(integer new_mode) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_RELAY_MODE,
        "value", (string)new_mode
    ]), NULL_KEY);
}

persist_hardcore(integer new_hardcore) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.set",
        "key", KEY_RELAY_HARDCORE,
        "value", (string)new_hardcore
    ]), NULL_KEY);
}


/* -------------------- MENU SYSTEM -------------------- */

show_main_menu() {
    SessionId = generate_session_id();
    refresh_mode();
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    string message = "RLV Relay Menu\nMode: " + mode_str();

    list buttons = ["Back"];
    if (btn_allowed("Mode"))                       buttons += ["Mode"];
    if (btn_allowed("Bound by..."))                buttons += ["Bound by..."];
    if (btn_allowed("Safeword") && !Hardcore)      buttons += ["Safeword"];
    if (btn_allowed("Unbind"))                     buttons += ["Unbind"];

    string buttons_json = llList2Json(JSON_ARRAY, buttons);
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", PLUGIN_LABEL + " Menu",
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]), NULL_KEY);
}

show_mode_menu() {
    SessionId = generate_session_id();
    refresh_mode();

    string message = "RLV Relay Mode: " + mode_str();

    list buttons = ["Back", "OFF", "ASK", "ON"];
    if (Mode == MODE_ON) {
        if (Hardcore) {
            if (btn_allowed("HC OFF")) buttons += ["HC OFF"];
        } else {
            if (btn_allowed("HC ON"))  buttons += ["HC ON"];
        }
    }

    string buttons_json = llList2Json(JSON_ARRAY, buttons);
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Relay Mode",
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]), NULL_KEY);
}

// Called when relay.list.response arrives. sources_json is a JSON array
// of {name, restr_count} objects.
render_object_list(string sources_json) {
    SessionId = generate_session_id();

    list arr = [];
    if (sources_json != "" && sources_json != JSON_INVALID) {
        // Parse the array by walking indices until JSON_INVALID.
        integer i = 0;
        string entry = llJsonGetValue(sources_json, [(string)i]);
        while (entry != JSON_INVALID) {
            arr += [entry];
            i += 1;
            entry = llJsonGetValue(sources_json, [(string)i]);
        }
    }

    integer source_count = llGetListLength(arr);
    string message;
    if (source_count == 0) {
        message = "No active sources.";
    } else {
        message = "Bound by:\n";
        integer i = 0;
        while (i < source_count) {
            string entry = llList2String(arr, i);
            string nm = llJsonGetValue(entry, ["name"]);
            string rcs = llJsonGetValue(entry, ["restr_count"]);
            message += (string)(i + 1) + ". " + truncate_name(nm, 24);
            if (rcs != JSON_INVALID && rcs != "0") {
                message += " [" + rcs + "]";
            }
            message += "\n";
            i += 1;
        }
    }

    list buttons = ["Back"];
    string buttons_json = llList2Json(JSON_ARRAY, buttons);
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Bound by",
        "message", message,
        "buttons", buttons_json,
        "timeout", 60
    ]), NULL_KEY);
}


/* -------------------- BUTTON HANDLING -------------------- */

set_mode(integer new_mode, integer clear_hardcore) {
    Mode = new_mode;
    if (clear_hardcore) Hardcore = FALSE;
    persist_mode(new_mode);
    if (clear_hardcore) persist_hardcore(FALSE);
}

handle_button_click(string button) {
    if (button == "Mode") {
        show_mode_menu();
    }
    else if (button == "Bound by...") {
        AwaitingList = TRUE;
        llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
            "type", "relay.list.request"
        ]), NULL_KEY);
    }
    else if (button == "Safeword") {
        if (btn_allowed("Safeword") && !Hardcore) {
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "relay.safeword"
            ]), NULL_KEY);
            llRegionSayTo(CurrentUser, 0, "Safeword used - all restrictions cleared");
            show_main_menu();
        }
    }
    else if (button == "Unbind") {
        if (btn_allowed("Unbind")) {
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "relay.safeword"
            ]), NULL_KEY);
            llRegionSayTo(CurrentUser, 0, "Unbound - all restrictions cleared");
            show_main_menu();
        }
    }
    else if (button == "OFF") {
        set_mode(MODE_OFF, TRUE);
        llRegionSayTo(CurrentUser, 0, "Mode set to OFF");
        show_mode_menu();
    }
    else if (button == "ASK") {
        set_mode(MODE_ASK, TRUE);
        llRegionSayTo(CurrentUser, 0, "Mode set to ASK");
        show_mode_menu();
    }
    else if (button == "ON") {
        Mode = MODE_ON;
        persist_mode(MODE_ON);
        if (!Hardcore) llRegionSayTo(CurrentUser, 0, "Mode set to ON");
        show_mode_menu();
    }
    else if (button == "HC ON") {
        if (btn_allowed("HC ON")) {
            Hardcore = TRUE;
            Mode = MODE_ON;
            persist_hardcore(TRUE);
            persist_mode(MODE_ON);
            llRegionSayTo(CurrentUser, 0, "Hardcore mode ENABLED");
            show_mode_menu();
        }
    }
    else if (button == "HC OFF") {
        if (btn_allowed("HC OFF")) {
            Hardcore = FALSE;
            Mode = MODE_ON;
            persist_hardcore(FALSE);
            persist_mode(MODE_ON);
            llRegionSayTo(CurrentUser, 0, "Hardcore mode DISABLED");
            show_mode_menu();
        }
    }
    else if (button == "Back") {
        return_to_root();
    }
    else {
        show_main_menu();
    }
}


/* -------------------- NAVIGATION -------------------- */

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user", (string)CurrentUser
    ]), CurrentUser);
    cleanup_session();
}

cleanup_session() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    gPolicyButtons = [];
    SessionId = "";
    AwaitingList = FALSE;
}


/* -------------------- MENU MESSAGE HANDLERS -------------------- */

handle_start(string msg) {
    if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["user"]) == JSON_INVALID) return;

    string context = llJsonGetValue(msg, ["context"]);
    if (context != PLUGIN_CONTEXT) return;

    key user = (key)llJsonGetValue(msg, ["user"]);
    integer acl = (integer)llJsonGetValue(msg, ["acl"]);

    string subpath = "";
    string sp = llJsonGetValue(msg, ["subpath"]);
    if (sp != JSON_INVALID) subpath = sp;

    if (subpath != "") {
        handle_subpath(user, acl, subpath);
        return;
    }

    CurrentUser = user;
    UserAcl = acl;
    show_main_menu();
}

handle_subpath(key user, integer acl_level, string subpath) {
    CurrentUser = user;
    UserAcl = acl_level;
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);

    if (subpath == "on" || subpath == "off" || subpath == "ask") {
        if (!btn_allowed("Mode")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        if (subpath == "off")      set_mode(MODE_OFF, TRUE);
        else if (subpath == "ask") set_mode(MODE_ASK, TRUE);
        else                       set_mode(MODE_ON,  FALSE);
        llRegionSayTo(user, 0, "Mode set to " + llToUpper(subpath) + ".");
        gPolicyButtons = [];
        return;
    }

    if (subpath == "safeword") {
        if (!btn_allowed("Safeword") && !btn_allowed("Unbind")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
            "type", "relay.safeword"
        ]), NULL_KEY);
        llRegionSayTo(user, 0, "Safeword used - all restrictions cleared.");
        gPolicyButtons = [];
        return;
    }

    llRegionSayTo(user, 0, "Unknown relay subcommand: " + subpath);
    gPolicyButtons = [];
}

handle_dialog_response(string msg) {
    if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID) return;
    if (llJsonGetValue(msg, ["button"]) == JSON_INVALID) return;
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session != SessionId) return;
    string button = llJsonGetValue(msg, ["button"]);
    handle_button_click(button);
}

handle_dialog_timeout(string msg) {
    string session = llJsonGetValue(msg, ["session_id"]);
    if (session == JSON_INVALID) return;
    if (session != SessionId) return;
    cleanup_session();
}


/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        if (llGetObjectDesc() == "COLLAR_UPDATER") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        cleanup_session();
        IsAttached = (llGetAttached() != 0);
        refresh_mode();

        register_self();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    attach(key id) {
        // kmod_rlv owns engine response to attach/detach; we only track
        // IsAttached for menu display.
        IsAttached = (id != NULL_KEY);
        if (IsAttached) refresh_mode();
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.register.refresh") {
                register_self();
            }
            else if (msg_type == "kernel.ping") {
                send_pong();
            }
            else if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                string ctx = llJsonGetValue(msg, ["context"]);
                if (ctx != JSON_INVALID && ctx != "" && ctx != PLUGIN_CONTEXT) return;
                llLinksetDataDelete("plugin.reg." + PLUGIN_CONTEXT);
                llLinksetDataDelete("acl.policycontext:" + PLUGIN_CONTEXT);
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            if (msg_type == "settings.sync" || msg_type == "settings.delta") {
                refresh_mode();
            }
        }
        else if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                handle_start(msg);
            }
            else if (msg_type == "relay.list.response") {
                if (!AwaitingList) return;
                AwaitingList = FALSE;
                string sources = llJsonGetValue(msg, ["sources"]);
                if (sources == JSON_INVALID) sources = "";
                render_object_list(sources);
            }
        }
        else if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                handle_dialog_response(msg);
            }
            else if (msg_type == "ui.dialog.timeout") {
                handle_dialog_timeout(msg);
            }
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}

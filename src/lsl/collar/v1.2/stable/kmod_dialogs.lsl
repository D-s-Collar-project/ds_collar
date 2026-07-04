/*--------------------
MODULE: kmod_dialogs.lsl
VERSION: 1.2
REVISION: 9
PURPOSE: Centralized dialog management for shared listener handling
ARCHITECTURE: Consolidated message bus lanes
CHANGES:
- v1.2 rev 9: retired the legacy button_data / buttons / numbered_list receive paths (the rev-8 cleanup phase). kmod_menu is the sole ui.dialog.open sender and emits only button_rows, so those branches were dead. handle_dialog_open is button_rows-only; handle_numbered_list_dialog deleted. Plugin-facing buttons->rows bridge lives in kmod_menu, unchanged.
- v1.2 rev 8: delimited button transport (dual-accept). New button_rows field carries buttons as "context\tlabel\n..." — a dialog label/context can contain neither tab nor newline, so labels with [ ] { } round-trip intact (JSON arrays collapsed them to a blank box). Context-FIRST because a JSON value that LEADS with [ or { poisons llList2Json; contexts never do, labels sit mid-value. Session click-map stores that rows string directly (build_rows) and resolves clicks via resolve_context — no llList2Json/llJson2List touches a label. The response `button` echo is guarded (placeholder when a label leads with [/{; only picker items do, and they route by context). Legacy button_data/buttons paths kept working during migration; removed once all senders emit button_rows. Toggle buttons still resolve label from config+state by context.
- v1.2 rev 7: nav:close handled centrally — a Close click closes the session and broadcasts the new ui.dialog.close (distinct from ui.dialog.timeout) so consumers tear down once instead of redrawing.
- v1.2 rev 6: revision baseline normalized to rev 6 (no functional change this rev).
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer DIALOG_BUS = 950;

/* -------------------- CONSTANTS -------------------- */
float CHANNEL_BASE = -8E07;
integer SESSION_MAX = 10;  // Maximum concurrent sessions

/* -------------------- STATE -------------------- */
// Parallel Lists for Sessions
list SessionIDs;        // [session_id]
list SessionUsers;      // [user_key]
list SessionChannels;   // [channel]
list SessionListens;    // [listen_handle]
list SessionTimeouts;   // [timeout_unix]
list SessionButtonMaps; // [json_string] [{"b":"btn","c":"ctx"},...]

integer NextChannelOffset = 1;

// Parallel Lists for Button Configs
list ButtonConfigContexts; // [context]
list ButtonConfigLabelsA;  // [button_a_label]
list ButtonConfigLabelsB;  // [button_b_label]

/* -------------------- HELPERS -------------------- */


string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
}

// MEMORY OPTIMIZATION: Compact field validation helper
integer validate_required_fields(string json_str, list field_names) {
    integer i = 0;
    integer len = llGetListLength(field_names);
    while (i < len) {
        string field = llList2String(field_names, i);
        if (llJsonGetValue(json_str, [field]) == JSON_INVALID) {
            return FALSE;
        }
        i += 1;
    }
    return TRUE;
}

integer now() {
    return llGetUnixTime();
}

/* -------------------- SESSION MANAGEMENT -------------------- */

integer find_session_idx(string session_id) {
    return llListFindList(SessionIDs, [session_id]);
}

close_session_at_idx(integer idx) {
    if (idx < 0) return;
    
    integer listen_handle = llList2Integer(SessionListens, idx);
    if (listen_handle != 0) {
        llListenRemove(listen_handle);
    }
    
    SessionIDs = llDeleteSubList(SessionIDs, idx, idx);
    SessionUsers = llDeleteSubList(SessionUsers, idx, idx);
    SessionChannels = llDeleteSubList(SessionChannels, idx, idx);
    SessionListens = llDeleteSubList(SessionListens, idx, idx);
    SessionTimeouts = llDeleteSubList(SessionTimeouts, idx, idx);
    SessionButtonMaps = llDeleteSubList(SessionButtonMaps, idx, idx);
}

close_session(string session_id) {
    integer idx = find_session_idx(session_id);
    if (idx != -1) {
        close_session_at_idx(idx);
    }
}

prune_expired_sessions() {
    integer i = 0;
    integer now_time = now();
    
    // Iterate backwards to safely delete
    integer len = llGetListLength(SessionTimeouts);
    for (i = len - 1; i >= 0; i--) {
        integer timeout = llList2Integer(SessionTimeouts, i);
        
        if (timeout > 0 && now_time >= timeout) {
            // Session expired, send timeout message
            string session_id = llList2String(SessionIDs, i);
            key user = llList2Key(SessionUsers, i);
            
            string timeout_msg = llList2Json(JSON_OBJECT, [
                "type", "ui.dialog.timeout",
                "session_id", session_id,
                "user", (string)user
            ]);
            llMessageLinked(LINK_SET, DIALOG_BUS, timeout_msg, NULL_KEY);
            
            close_session_at_idx(i);
        }
    }
}

integer get_next_channel() {
    integer channel = (integer)CHANNEL_BASE - NextChannelOffset;
    NextChannelOffset += 1;
    if (NextChannelOffset > 1000000) NextChannelOffset = 1;
    return channel;
}

/* -------------------- BUTTON CONFIG MANAGEMENT -------------------- */

integer find_button_config_idx(string context) {
    return llListFindList(ButtonConfigContexts, [context]);
}

register_button_config(string context, string button_a, string button_b) {
    integer idx = find_button_config_idx(context);

    if (idx != -1) {
        // Update existing config
        ButtonConfigLabelsA = llListReplaceList(ButtonConfigLabelsA, [button_a], idx, idx);
        ButtonConfigLabelsB = llListReplaceList(ButtonConfigLabelsB, [button_b], idx, idx);
    }
    else {
        // Add new config
        ButtonConfigContexts += [context];
        ButtonConfigLabelsA += [button_a];
        ButtonConfigLabelsB += [button_b];
    }
}

string get_button_label(string context, integer button_state) {
    integer idx = find_button_config_idx(context);

    if (idx == -1) {
        // No config found, return context as-is
        return context;
    }

    if (button_state == 0) {
        return llList2String(ButtonConfigLabelsA, idx);
    }
    else {
        return llList2String(ButtonConfigLabelsB, idx);
    }
}

// Read the toggle state for a context from LSD. Convention: the state
// lives at "plugin.<short>.state" where <short> is the trailing dotted
// segment of the plugin context. Missing key → 0 (default off).
integer read_toggle_state(string context) {
    list parts = llParseString2List(context, ["."], []);
    string short_name = llList2String(parts, -1);
    if (short_name == "") return 0;
    return (integer)llLinksetDataRead("plugin." + short_name + ".state");
}

/* -------------------- DELIMITED CLICK-MAP -------------------- */

// The session click-map is stored as the delimited button_rows string itself —
// "context\tlabel\n...". A dialog label/context can contain neither a tab nor a
// newline, so this is bracket-immune (no llList2Json ever touches a label).
// Context-FIRST: when this string rides a message field it must not lead with
// [ or { (llList2Json would auto-type it and fail); contexts never do.
string build_rows(list labels, list ctxs) {
    string s = "";
    integer n = llGetListLength(labels);
    integer i = 0;
    while (i < n) {
        if (i > 0) s += "\n";
        s += llList2String(ctxs, i) + "\t" + llList2String(labels, i);
        i += 1;
    }
    return s;
}

// Resolve a clicked button label to its context against a stored rows string.
// Row is "context\tlabel": match the clicked label (field 1), return context
// (field 0). Returns "" when not found.
string resolve_context(string rows_str, string clicked) {
    list rows = llParseStringKeepNulls(rows_str, ["\n"], []);
    integer n = llGetListLength(rows);
    integer i = 0;
    while (i < n) {
        list f = llParseStringKeepNulls(llList2String(rows, i), ["\t"], []);
        if (llGetListLength(f) > 1 && llList2String(f, 1) == clicked) {
            return llList2String(f, 0);
        }
        i += 1;
    }
    return "";
}

/* -------------------- DIALOG DISPLAY -------------------- */

handle_dialog_open(string msg) {
    if (!validate_required_fields(msg, ["session_id", "user"])) {
        return;
    }

    string session_id = llJsonGetValue(msg, ["session_id"]);
    key user = (key)llJsonGetValue(msg, ["user"]);

    // Buttons arrive ONLY as button_rows — delimited "context\tlabel\n..."
    // (bracket-immune; see build_rows). kmod_menu is the sole ui.dialog.open
    // sender and emits this format exclusively; the legacy button_data / buttons
    // / numbered_list paths were retired once every sender moved to rows.
    if (llJsonGetValue(msg, ["button_rows"]) == JSON_INVALID) return;

    list buttons = [];
    list map_ctxs = [];
    string rows_in = llJsonGetValue(msg, ["button_rows"]);
    list rows = llParseStringKeepNulls(rows_in, ["\n"], []);
    integer rlen = llGetListLength(rows);
    integer ri = 0;
    while (ri < rlen) {
        // Row is "context\tlabel". Toggle buttons resolve their label live from
        // the registered config+state, keyed by context.
        list f = llParseStringKeepNulls(llList2String(rows, ri), ["\t"], []);
        string ctx = llList2String(f, 0);
        string lbl = "";
        if (llGetListLength(f) > 1) lbl = llList2String(f, 1);
        if (find_button_config_idx(ctx) != -1) {
            lbl = get_button_label(ctx, read_toggle_state(ctx));
        }
        buttons += [lbl];
        map_ctxs += [ctx];
        ri += 1;
    }

    string title = "Menu";
    string message = "Select an option:";
    integer timeout = 60;

    string tmp = llJsonGetValue(msg, ["title"]);
    if (tmp != JSON_INVALID) {
        title = tmp;
    }
    tmp = llJsonGetValue(msg, ["body"]);
    if (tmp != JSON_INVALID) {
        message = tmp;
    }
    else if ((llJsonGetValue(msg, ["message"]) != JSON_INVALID)) {
        message = llJsonGetValue(msg, ["message"]);
    }
    tmp = llJsonGetValue(msg, ["timeout"]);
    if (tmp != JSON_INVALID) {
        timeout = (integer)tmp;
    }

    // Close existing session with same ID
    integer existing_idx = find_session_idx(session_id);
    if (existing_idx != -1) {
        close_session_at_idx(existing_idx);
    }

    // Enforce session limit
    if (llGetListLength(SessionIDs) >= SESSION_MAX) {
        // Close oldest session
        close_session_at_idx(0);
    }

    // Get channel and create listen
    integer channel = get_next_channel();
    integer listen_handle = llListen(channel, "", user, "");

    // Calculate timeout timestamp
    integer timeout_unix = 0;
    if (timeout > 0) {
        timeout_unix = now() + timeout;
    }

    // Add to sessions
    SessionIDs += [session_id];
    SessionUsers += [user];
    SessionChannels += [channel];
    SessionListens += [listen_handle];
    SessionTimeouts += [timeout_unix];
    // Store map as the delimited rows string (bracket-immune; see build_rows).
    SessionButtonMaps += [build_rows(buttons, map_ctxs)];

    // Show dialog
    llDialog(user, title + "\n\n" + message, buttons, channel);

}

handle_dialog_close(string msg) {
    string session_id = llJsonGetValue(msg, ["session_id"]);
    if (session_id == JSON_INVALID) return;
    close_session(session_id);
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {

        SessionIDs = [];
        SessionUsers = [];
        SessionChannels = [];
        SessionListens = [];
        SessionTimeouts = [];
        SessionButtonMaps = [];
        
        NextChannelOffset = 1;
        
        ButtonConfigContexts = [];
        ButtonConfigLabelsA = [];
        ButtonConfigLabelsB = [];

        // Start timer for session cleanup
        llSetTimerEvent(5.0);
    }
    
    timer() {
        prune_expired_sessions();
    }
    
    listen(integer channel, string name, key id, string message) {
        // Find session for this channel using Parallel List lookup
        integer i = llListFindList(SessionChannels, [channel]);
        
        if (i != -1) {
            key session_user = llList2Key(SessionUsers, i);

            // Verify speaker matches session user
            if (id == session_user) {
                string session_id = llList2String(SessionIDs, i);

                // Click-map is the delimited rows string; resolve label -> context
                // without any JSON (labels may contain [ ] { }). See resolve_context.
                string clicked_context = resolve_context(llList2String(SessionButtonMaps, i), message);

                // Close (nav:close) is handled centrally: tear down the session
                // and broadcast ui.dialog.close so the owning consumer clears its
                // session state — NOT a button response (the menu must not redraw).
                // ui.dialog.close is the unified "this session is closing" signal
                // (also what consumers send to close their own dialog). Timeouts
                // keep their own ui.dialog.timeout — uses stay unmuddied.
                if (clicked_context == "nav:close") {
                    close_session_at_idx(i);
                    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
                        "type", "ui.dialog.close",
                        "session_id", session_id,
                        "user", (string)id
                    ]), NULL_KEY);
                    return;
                }

                // The `button` field echoes the clicked label for consumers that
                // still read it (fixed-label menus). A label that LEADS with [ or {
                // would poison this JSON object at encode; only picker-item labels do
                // that, and picker responses route by context (never button), so a
                // placeholder is harmless there. Fixed menu labels never lead with a
                // bracket, so they pass through unchanged.
                string safe_button = message;
                string lead = llGetSubString(message, 0, 0);
                if (lead == "[" || lead == "{") safe_button = " ";
                string response = llList2Json(JSON_OBJECT, [
                    "type", "ui.dialog.response",
                    "session_id", session_id,
                    "user", (string)id,
                    "button", safe_button,
                    "context", clicked_context
                ]);
                llMessageLinked(LINK_SET, DIALOG_BUS, response, NULL_KEY);


                // Close session after response
                close_session_at_idx(i);
                return;
            }
        }
    }
    
    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        /* -------------------- KERNEL LIFECYCLE -------------------- */
        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
            return;
        }

        /* -------------------- DIALOG BUS -------------------- */
        if (num != DIALOG_BUS) return;

        if (msg_type == "ui.dialog.open") {
            handle_dialog_open(msg);
        }
        else if (msg_type == "ui.dialog.close") {
            handle_dialog_close(msg);
        }
        else if (msg_type == "ui.dialog.buttonconfig.register") {
            if (llJsonGetValue(msg, ["context"])  == JSON_INVALID) return;
            if (llJsonGetValue(msg, ["button_a"]) == JSON_INVALID) return;
            if (llJsonGetValue(msg, ["button_b"]) == JSON_INVALID) return;
            string context  = llJsonGetValue(msg, ["context"]);
            string button_a = llJsonGetValue(msg, ["button_a"]);
            string button_b = llJsonGetValue(msg, ["button_b"]);
            register_button_config(context, button_a, button_b);
        }
    }
    
    // Reset on owner change
    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}

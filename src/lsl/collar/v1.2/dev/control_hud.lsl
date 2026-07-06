/*--------------------
SCRIPT: control_hud.lsl
VERSION: 1.2
REVISION: 1
PURPOSE: Auto-detect nearby collars and connect automatically
ARCHITECTURE: RLV relay-style broadcast and listen workflow, namespaced internal message protocol
CHANGES:
- v1.2 rev 1: same-region llGetDisplayName fast path for scan labels and the
  connect message (scan responders are range-checked to 20 m, so the wearer is
  always in-region); llRequestDisplayName/llRequestAgentData remain only as
  fallback. A held-down scan loop in a crowd no longer feeds SL's average-rate
  name-request throttle. Connect message now shows the display name (was
  legacy name via DATA_NAME), matching the scan labels.
--------------------*/


/* -------------------- EXTERNAL PROTOCOL CHANNELS -------------------- */
integer COLLAR_ACL_QUERY_CHAN = -8675309;
integer COLLAR_ACL_REPLY_CHAN = -8675310;
integer COLLAR_MENU_CHAN      = -8675311;

/* -------------------- ACL CONSTANTS -------------------- */
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* -------------------- DIALOG SETTINGS -------------------- */
float QUERY_TIMEOUT_SEC = 3.0;
float COLLAR_SCAN_TIME = 2.0;
integer DIALOG_CHANNEL;  // Randomized per session in state_entry
float LONG_TOUCH_THRESHOLD = 1.5;
integer MAX_DIALOG_BUTTONS = 12;  // llDialog button limit

/* -------------------- CONSTANTS -------------------- */
string ROOT_CONTEXT = "ui.core.root";
string SOS_CONTEXT = "ui.sos.root";

/* -------------------- STATE -------------------- */
key HudWearer = NULL_KEY;
integer CollarListenHandle = 0;
integer DialogListenHandle = 0;

integer ScanningForCollars = FALSE;
integer AclPending = FALSE;
integer DisplayNamePending = FALSE;
integer AclLevel = ACL_NOACCESS;

key TargetCollarKey = NULL_KEY;
key TargetAvatarKey = NULL_KEY;
string TargetAvatarName = "";

/* Detected collars: [avatar_key, collar_key, avatar_name, ...] */
list DetectedCollars = [];
integer COLLAR_STRIDE = 3;

/* Touch tracking */
float TouchStartTime = 0.0;
string RequestedContext = "";

/* Display name lookup (post-selection "Connected to X's collar" notice) */
key DisplayNameQueryId = NULL_KEY;

/* Scan-time display name lookups: [query_id, avatar_key, ...] */
list PendingDisplayQueries = [];
integer DISPLAY_QUERY_STRIDE = 2;

/* -------------------- HELPERS -------------------- */



/* -------------------- SESSION MANAGEMENT -------------------- */

cleanup_session() {
    if (CollarListenHandle != 0) {
        llListenRemove(CollarListenHandle);
        CollarListenHandle = 0;
    }
    if (DialogListenHandle != 0) {
        llListenRemove(DialogListenHandle);
        DialogListenHandle = 0;
    }

    ScanningForCollars = FALSE;
    AclPending = FALSE;
    DisplayNamePending = FALSE;
    AclLevel = ACL_NOACCESS;
    TargetCollarKey = NULL_KEY;
    TargetAvatarKey = NULL_KEY;
    TargetAvatarName = "";
    DetectedCollars = [];
    TouchStartTime = 0.0;
    RequestedContext = "";
    DisplayNameQueryId = NULL_KEY;
    PendingDisplayQueries = [];
    llSetTimerEvent(0.0);
}

/* -------------------- COLLAR DETECTION -------------------- */

add_detected_collar(key avatar_key, key collar_key, string avatar_name) {
    // Dedup by collar prim: two collars on the same owner must remain distinct
    if (llListFindList(DetectedCollars, [collar_key]) != -1) {
        return;
    }

    DetectedCollars += [avatar_key, collar_key, avatar_name];
}

broadcast_collar_scan(string context) {
    // Store the requested context for later use
    RequestedContext = context;

    // Broadcast to find all nearby collars
    string json_msg = llList2Json(JSON_OBJECT, [
        "type", "remote.collarscan",
        "hud_wearer", (string)HudWearer
    ]);

    // Listen for collar responses
    if (CollarListenHandle != 0) {
        llListenRemove(CollarListenHandle);
    }
    CollarListenHandle = llListen(COLLAR_ACL_REPLY_CHAN, "", NULL_KEY, "");

    // Broadcast scan
    llRegionSay(COLLAR_ACL_QUERY_CHAN, json_msg);

    ScanningForCollars = TRUE;
    DetectedCollars = [];
    llSetTimerEvent(COLLAR_SCAN_TIME);
    llRegionSayTo(llGetOwner(), 0, "Scanning for nearby collars...");
}

process_scan_results() {
    ScanningForCollars = FALSE;
    llSetTimerEvent(0.0);
    
    integer num_collars = llGetListLength(DetectedCollars) / COLLAR_STRIDE;
    
    if (num_collars == 0) {
        llRegionSayTo(llGetOwner(), 0, "No collars found nearby.");
        cleanup_session();
        return;
    }
    
    if (num_collars == 1) {
        // AUTO-CONNECT to single collar (RLV relay style!)
        key avatar_key = llList2Key(DetectedCollars, 0);
        key collar_key = llList2Key(DetectedCollars, 1);

        request_acl_from_collar(avatar_key, collar_key);
        return;
    }
    
    // Multiple collars - show dialog
    show_collar_selection_dialog();
}

/* -------------------- COLLAR SELECTION DIALOG -------------------- */

show_collar_selection_dialog() {
    integer num_collars = llGetListLength(DetectedCollars) / COLLAR_STRIDE;

    if (num_collars == 0) return;

    // Disambiguate labels when multiple collars share an owner: "Name #N"
    integer i = 0;
    while (i < num_collars) {
        key owner = llList2Key(DetectedCollars, i * COLLAR_STRIDE);
        integer total = 1;
        integer position = 1;
        integer j = 0;
        while (j < num_collars) {
            if (j != i && llList2Key(DetectedCollars, j * COLLAR_STRIDE) == owner) {
                total += 1;
                if (j < i) position += 1;
            }
            j += 1;
        }
        if (total > 1) {
            string base = llList2String(DetectedCollars, i * COLLAR_STRIDE + 2);
            DetectedCollars = llListReplaceList(DetectedCollars,
                [base + " #" + (string)position],
                i * COLLAR_STRIDE + 2, i * COLLAR_STRIDE + 2);
        }
        i += 1;
    }

    // Set up dialog listener
    if (DialogListenHandle != 0) {
        llListenRemove(DialogListenHandle);
    }
    DialogListenHandle = llListen(DIALOG_CHANNEL, "", HudWearer, "");

    // Build dialog
    string text = "Collars found. Select one:\n\n";
    list buttons = [];
    i = 0;
    integer collar_count = llGetListLength(DetectedCollars);

    while (i < collar_count && (i / COLLAR_STRIDE) < MAX_DIALOG_BUTTONS) {
        buttons += [llList2String(DetectedCollars, i + 2)];
        i += COLLAR_STRIDE;
    }

    if (llGetListLength(buttons) < MAX_DIALOG_BUTTONS) {
        buttons += ["Cancel"];
    }

    llDialog(HudWearer, text, buttons, DIALOG_CHANNEL);
    llSetTimerEvent(30.0);
}

/* -------------------- ACL QUERY -------------------- */

request_acl_from_collar(key avatar_key, key collar_key) {
    string json_msg = llList2Json(JSON_OBJECT, [
        "type", "auth.aclqueryexternal",
        "avatar", (string)HudWearer,
        "hud", (string)llGetKey(),
        "target_avatar", (string)avatar_key,
        "target_collar", (string)collar_key
    ]);

    if (CollarListenHandle != 0) {
        llListenRemove(CollarListenHandle);
    }
    CollarListenHandle = llListen(COLLAR_ACL_REPLY_CHAN, "", NULL_KEY, "");

    llRegionSay(COLLAR_ACL_QUERY_CHAN, json_msg);

    AclPending = TRUE;
    TargetAvatarKey = avatar_key;
    TargetCollarKey = collar_key;
    TargetAvatarName = llKey2Name(avatar_key);
    llSetTimerEvent(QUERY_TIMEOUT_SEC);
}

/* -------------------- MENU TRIGGERING -------------------- */

// Announce the connection and ask the collar for the menu. Must run BEFORE
// cleanup_session() wipes RequestedContext/TargetCollarKey.
finish_connect(string avatar_name) {
    llRegionSayTo(llGetOwner(), 0, "Connected to " + avatar_name + "'s collar.");

    string json_msg = llList2Json(JSON_OBJECT, [
        "type", "remote.menurequest",
        "avatar", (string)HudWearer,
        "context", RequestedContext
    ]);
    llRegionSayTo(TargetCollarKey, COLLAR_MENU_CHAN, json_msg);

    cleanup_session();
}

trigger_collar_menu() {
    if (TargetCollarKey == NULL_KEY) {
        llRegionSayTo(llGetOwner(), 0, "Error: No collar connection established.");
        return;
    }

    // Same-region fast path: the collar range-checks scan/menu requests to
    // 20 m, so the target wearer is in-region and llGetDisplayName answers
    // synchronously — no throttled dataserver request needed.
    string display_name = llGetDisplayName(TargetAvatarKey);
    if (display_name != "" && display_name != "???") {
        finish_connect(display_name);
        return;
    }

    // Fallback: request the name via dataserver
    DisplayNameQueryId = llRequestAgentData(TargetAvatarKey, DATA_NAME);
    DisplayNamePending = TRUE;
    llSetTimerEvent(QUERY_TIMEOUT_SEC);

    // The actual menu triggering and success message will be handled in dataserver()
}

/* -------------------- ACL LEVEL PROCESSING -------------------- */

process_acl_result(integer level) {
    // Whitelist known ACL levels that grant access
    integer has_access = (
        level == ACL_PRIMARY_OWNER ||
        level == ACL_TRUSTEE ||
        level == ACL_OWNED ||
        level == ACL_UNOWNED ||
        level == ACL_PUBLIC
    );

    // EMERGENCY ACCESS: Allow wearer to access SOS menu even with ACL 0
    // This handles TPE mode where wearer has no normal access to their collar
    if (level == ACL_NOACCESS && RequestedContext == SOS_CONTEXT && HudWearer == TargetAvatarKey) {
        has_access = TRUE;
    }

    if (has_access) {
        trigger_collar_menu();
    }
    else {
        llRegionSayTo(llGetOwner(), 0, "Access denied.");
        cleanup_session();
    }
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        DIALOG_CHANNEL = (integer)(llFrand(-1000000.0) - 1000000);
        cleanup_session();
        HudWearer = llGetOwner();
        TouchStartTime = 0.0;
        RequestedContext = "";
        llRegionSayTo(llGetOwner(), 0, "Control HUD ready. Touch to scan for collars, long-touch for emergency access.");
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    attach(key id) {
        if (id != NULL_KEY) {
            llResetScript();
        }
        else {
            cleanup_session();
        }
    }
    
    changed(integer change_mask) {
        if (change_mask & CHANGED_OWNER) {
            llResetScript();
        }
    }
    
    touch_start(integer num_detected) {
        if (ScanningForCollars) {
            llRegionSayTo(llGetOwner(), 0, "Scan already in progress...");
            return;
        }

        if (AclPending) {
            llRegionSayTo(llGetOwner(), 0, "Still waiting for collar response...");
            return;
        }

        // Record touch start time
        TouchStartTime = llGetTime();
    }

    touch_end(integer num_detected) {
        if (ScanningForCollars || AclPending) {
            TouchStartTime = 0.0;  // Clear stale timestamp to prevent incorrect duration calculations
            return;
        }

        // Calculate touch duration
        float duration = llGetTime() - TouchStartTime;
        TouchStartTime = 0.0;


        cleanup_session();

        // Determine context based on touch duration
        string context = ROOT_CONTEXT;
        if (duration >= LONG_TOUCH_THRESHOLD) {
            context = SOS_CONTEXT;
        }

        broadcast_collar_scan(context);
    }
    
    listen(integer channel, string name, key id, string message) {
        // Handle collar scan responses
        if (channel == COLLAR_ACL_REPLY_CHAN && ScanningForCollars) {
            string msg_type = llJsonGetValue(message, ["type"]);
            if (msg_type == JSON_INVALID) return;
            if (msg_type != "remote.collarscanresponse") return;
            
            string collar_owner_str = llJsonGetValue(message, ["collar_owner"]);
            if (collar_owner_str == JSON_INVALID) return;
            key collar_owner = (key)collar_owner_str;

            // Same-region fast path: responders are range-checked to 20 m by
            // the collar, so llGetDisplayName answers synchronously and the
            // throttled llRequestDisplayName is never touched.
            string display_name = llGetDisplayName(collar_owner);
            if (display_name != "" && display_name != "???") {
                add_detected_collar(collar_owner, id, display_name);
                return;
            }

            // Placeholder label until llRequestDisplayName resolves. llKey2Name
            // is regional-only and returns "" for absent avatars, which llDialog
            // rejects as a button label.
            string placeholder = "(" + llGetSubString((string)collar_owner, 0, 7) + ")";
            add_detected_collar(collar_owner, id, placeholder);

            // One display-name lookup per owner; stripe the result across
            // same-owner collars when it returns.
            if (llListFindList(PendingDisplayQueries, [collar_owner]) == -1) {
                key dn_query = llRequestDisplayName(collar_owner);
                PendingDisplayQueries += [dn_query, collar_owner];
            }
            return;
        }
        
        // Handle collar selection dialog
        if (channel == DIALOG_CHANNEL) {
            llListenRemove(DialogListenHandle);
            DialogListenHandle = 0;
            llSetTimerEvent(0.0);
            
            if (message == "Cancel") {
                llRegionSayTo(llGetOwner(), 0, "Selection cancelled.");
                cleanup_session();
                return;
            }
            
            // Find selected collar by label
            integer i = 0;
            key selected_avatar = NULL_KEY;
            key selected_collar = NULL_KEY;
            while (i < llGetListLength(DetectedCollars)) {
                string label = llList2String(DetectedCollars, i + 2);
                if (label == message) {
                    selected_avatar = llList2Key(DetectedCollars, i);
                    selected_collar = llList2Key(DetectedCollars, i + 1);
                    i = llGetListLength(DetectedCollars);  // Exit loop
                }
                else {
                    i += COLLAR_STRIDE;
                }
            }

            if (selected_collar != NULL_KEY) {
                request_acl_from_collar(selected_avatar, selected_collar);
            }
            else {
                llRegionSayTo(llGetOwner(), 0, "Error: Selection not found.");
                cleanup_session();
            }
            return;
        }
        
        // Handle ACL responses
        if (channel == COLLAR_ACL_REPLY_CHAN && AclPending) {
            string msg_type = llJsonGetValue(message, ["type"]);
            if (msg_type == JSON_INVALID) return;
            if (msg_type != "auth.aclresultexternal") return;
            
            string response_avatar_str = llJsonGetValue(message, ["avatar"]);
            if (response_avatar_str == JSON_INVALID) return;
            key response_avatar = (key)response_avatar_str;
            
            if (response_avatar != HudWearer) return;
            
            string collar_owner_str = llJsonGetValue(message, ["collar_owner"]);
            if (collar_owner_str == JSON_INVALID) return;
            key collar_owner = (key)collar_owner_str;
            
            if (collar_owner != TargetAvatarKey) return;
            if (id != TargetCollarKey) return;

            llSetTimerEvent(0.0);
            AclPending = FALSE;

            string tmp = llJsonGetValue(message, ["level"]);
            if (tmp != JSON_INVALID) {
                AclLevel = (integer)tmp;
            }
            
            process_acl_result(AclLevel);
            
            if (CollarListenHandle != 0) {
                llListenRemove(CollarListenHandle);
                CollarListenHandle = 0;
            }
        }
    }
    
    dataserver(key query_id, string data) {
        // Scan-time display name: update every detected collar from this owner
        integer dn_idx = llListFindList(PendingDisplayQueries, [query_id]);
        if (dn_idx != -1) {
            key avatar = llList2Key(PendingDisplayQueries, dn_idx + 1);
            PendingDisplayQueries = llDeleteSubList(PendingDisplayQueries,
                dn_idx, dn_idx + DISPLAY_QUERY_STRIDE - 1);
            if (data != "") {
                integer n = llGetListLength(DetectedCollars);
                integer i = 0;
                while (i < n) {
                    if (llList2Key(DetectedCollars, i) == avatar) {
                        DetectedCollars = llListReplaceList(DetectedCollars,
                            [data], i + 2, i + 2);
                    }
                    i += COLLAR_STRIDE;
                }
            }
            return;
        }

        if (query_id == DisplayNameQueryId) {
            DisplayNameQueryId = NULL_KEY;
            DisplayNamePending = FALSE;
            llSetTimerEvent(0.0);

            // Validate that session state is still valid
            if (TargetCollarKey == NULL_KEY) {
                return;
            }

            finish_connect(data);
        }
    }

    timer() {
        if (ScanningForCollars) {
            process_scan_results();
        }
        else {
            if (AclPending) {
                llRegionSayTo(llGetOwner(), 0, "Connection failed: No response from collar.");
                cleanup_session();
            }
            else {
                if (DisplayNamePending) {
                    llRegionSayTo(llGetOwner(), 0, "Connection failed: Unable to retrieve name.");
                    cleanup_session();
                }
                else {
                    llRegionSayTo(llGetOwner(), 0, "Selection dialog timed out.");
                    cleanup_session();
                }
            }
        }
    }
}

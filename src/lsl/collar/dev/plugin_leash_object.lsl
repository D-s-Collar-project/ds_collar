/*--------------------
PLUGIN: plugin_leash_object.lsl
VERSION: 1.10
REVISION: 4
PURPOSE: Sub-plugin for object-target leash flows — Post mode. Sensor
         scan for in-world objects (posts, hitching points, leashposts),
         paginated picker, dispatches the post action to engine.
ARCHITECTURE: Hidden helper of plugin_leash. Does NOT register
              plugin.reg.* (so kmod_ui doesn't list it in the top menu).
              Receives ui.menu.start with context="ui.core.leash.object"
              + subpath ("post"); opens the object picker. After
              completion routes back to plugin_leash's main menu via
              ui.menu.start (context "ui.core.leash").
CHANGES:
- v1.10 rev 4: Dormancy guard widened to the renamed role-split markers ("D/s Collar updater v1.1" / "(updating)" / "(installing)").
- v1.10 rev 3: Wrap-around paging on `<<` / `>>` matching plugin_folders / plugin_animate. `<<` on page 0 jumps to last page; `>>` on last page jumps to first. Page-count math hoisted out of the branches to dodge the LSL Mono nested-scope redeclaration trap.
- v1.10 rev 2: Destroy picker dialog after action dispatch instead of re-opening parent leash menu — matches the project's "process finished → dialog gone" convention. Folded the dialog close into cleanupSession (mirroring plugin_leash) so completion/error paths just call cleanupSession directly; returnToParent retained only for the Back button (explicit back-navigation).
- v1.10 rev 1: Initial split out of plugin_leash. Carries the Post sensor
  scan + paginated picker. Hidden from kmod_ui's top menu. Delegated to
  via ui.menu.start with context="ui.core.leash.object" and subpath
  naming the action (currently only "post"; future static-target modes
  can land here too).
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT       = "ui.core.leash.object";
string PARENT_PLUGIN_CONTEXT = "ui.core.leash";

/* -------------------- STATE -------------------- */
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
string SessionId = "";
string MenuContext = "";              // currently only "post"
list SensorCandidates = [];           // [name, key, name, key, ...] strided
integer SensorPage = 0;

/* -------------------- HELPERS -------------------- */
string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

list reorder_item_buttons(list nav_buttons, list item_buttons) {
    integer item_count = llGetListLength(item_buttons);
    integer total = 3 + item_count;

    list slots = [];
    if (total > 9)  slots += [9];
    if (total > 10) slots += [10];
    if (total > 11) slots += [11];
    if (total > 6)  slots += [6];
    if (total > 7)  slots += [7];
    if (total > 8)  slots += [8];
    if (total > 3)  slots += [3];
    if (total > 4)  slots += [4];
    if (total > 5)  slots += [5];

    list final = nav_buttons;
    integer p = 0;
    while (p < item_count) { final += [" "]; p++; }
    integer i = 0;
    while (i < item_count) {
        integer slot = llList2Integer(slots, i);
        final = llListReplaceList(final, [llList2String(item_buttons, i)], slot, slot);
        i++;
    }
    return final;
}

/* -------------------- OBJECT PICKER -------------------- */
// Display the current page of SensorCandidates as a numbered list.
displayObjectMenu() {
    if (llGetListLength(SensorCandidates) == 0) return;

    integer total_items = llGetListLength(SensorCandidates) / 2;
    integer total_pages = (total_items + 8) / 9;
    integer start_index = SensorPage * 9;
    integer end_index = start_index + 9;
    if (end_index > total_items) end_index = total_items;

    string body = "";
    integer i = start_index;
    integer display_num = 1;
    while (i < end_index) {
        string obj_name = llList2String(SensorCandidates, i * 2);
        body += (string)display_num + ". " + obj_name + "\n";
        display_num++;
        i++;
    }

    list nav_buttons = [btn("<<", "prev"), btn(">>", "next"), btn("Back", "back")];
    list item_buttons = [];
    i = 1;
    while (i <= (end_index - start_index)) {
        item_buttons += [btn((string)i, "sel:" + (string)i)];
        i++;
    }
    list button_data = reorder_item_buttons(nav_buttons, item_buttons);

    if (total_pages > 1) {
        body += "\nPage " + (string)(SensorPage + 1) + "/" + (string)total_pages;
    }

    SessionId = generate_session_id();
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", "Post",
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 60
    ]), NULL_KEY);
}

startSensorScan() {
    SensorPage = 0;
    SensorCandidates = [];
    // Scan for stationary objects. ACTIVE is omitted because llSensor
    // returns avatars on the ACTIVE bit, and posts are by definition
    // non-physical / non-moving.
    llSensor("", NULL_KEY, PASSIVE | SCRIPTED, 96.0, PI);
}

/* -------------------- ACTION DISPATCH -------------------- */
sendActionWithTarget(string action, key target) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.action",
        "action", action,
        "target", (string)target
    ]), CurrentUser);
}

/* -------------------- NAVIGATION -------------------- */
// Back to plugin_leash's main menu. Used only for the Back button —
// an explicit back-navigation gesture. Action completions and error
// paths just call cleanupSession() directly, per the project
// convention that a finished process leaves no dialog behind.
returnToParent() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.start",
        "context", PARENT_PLUGIN_CONTEXT,
        "acl", (string)UserAcl
    ]), CurrentUser);
    cleanupSession();
}

cleanupSession() {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }
    CurrentUser = NULL_KEY;
    UserAcl = -999;
    SessionId = "";
    MenuContext = "";
    SensorCandidates = [];
    SensorPage = 0;
}

/* -------------------- SUBPATH DISPATCH -------------------- */
handleSubpath(string subpath) {
    if (subpath == "post") {
        MenuContext = "post";
        startSensorScan();
    }
    else {
        cleanupSession();
    }
}

/* -------------------- BUTTON CLICK -------------------- */
handlePickerClick(string ctx) {
    if (ctx == "back") {
        returnToParent();
        return;
    }

    // Page math hoisted once — same locals can't be redeclared in two
    // sibling scopes under LSL Mono.
    integer total_items = llGetListLength(SensorCandidates) / 2;
    integer total_pages = (total_items + 8) / 9;
    if (total_pages < 1) total_pages = 1;

    // Wrap-around paging matches plugin_folders / plugin_animate.
    if (ctx == "prev") {
        if (SensorPage == 0) SensorPage = total_pages - 1;
        else                 SensorPage--;
        displayObjectMenu();
        return;
    }
    if (ctx == "next") {
        if (SensorPage >= total_pages - 1) SensorPage = 0;
        else                               SensorPage++;
        displayObjectMenu();
        return;
    }
    if (llSubStringIndex(ctx, "sel:") == 0) {
        integer button_num = (integer)llGetSubString(ctx, 4, -1);
        if (button_num >= 1 && button_num <= 9) {
            integer actual_index = (SensorPage * 9) + (button_num - 1);
            integer list_index = actual_index * 2;
            if (list_index < llGetListLength(SensorCandidates)) {
                key selected = llList2Key(SensorCandidates, list_index + 1);
                sendActionWithTarget(MenuContext, selected);
                cleanupSession();
                return;
            }
        }
        llRegionSayTo(CurrentUser, 0, "Invalid selection.");
        cleanupSession();
    }
}

/* -------------------- EVENTS -------------------- */
default
{
    state_entry() {
        if (llGetObjectDesc() == "D/s Collar updater v1.1" || llGetObjectDesc() == "(updating)" || llGetObjectDesc() == "(installing)") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }
        cleanupSession();
        // No plugin.reg.* — hidden from kmod_ui's top menu.
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
            return;
        }

        if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;

                CurrentUser = id;
                UserAcl = (integer)llJsonGetValue(msg, ["acl"]);
                string sp = llJsonGetValue(msg, ["subpath"]);
                if (sp == JSON_INVALID) sp = "";
                handleSubpath(sp);
                return;
            }
        }

        if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                string resp_session = llJsonGetValue(msg, ["session_id"]);
                if (resp_session == JSON_INVALID) return;
                if (resp_session != SessionId) return;
                string ctx = llJsonGetValue(msg, ["context"]);
                if (ctx == JSON_INVALID) ctx = "";
                handlePickerClick(ctx);
                return;
            }
            if (msg_type == "ui.dialog.timeout") {
                string to_session = llJsonGetValue(msg, ["session_id"]);
                if (to_session == JSON_INVALID) return;
                if (to_session == SessionId) cleanupSession();
            }
        }
    }

    sensor(integer num) {
        if (MenuContext != "post") return;
        if (CurrentUser == NULL_KEY) return;

        key wearer = llGetOwner();
        key my_key = llGetKey();
        integer i = 0;

        // Build into local list (refcount 1 → in-place grow, O(n) total
        // — see plugin_leash rev 18 for why direct global += is O(n²)).
        list buf = [];
        while (i < num) {
            key detected = llDetectedKey(i);
            if (detected != my_key && detected != wearer) {
                buf += [llDetectedName(i), detected];
            }
            i = i + 1;
        }
        SensorCandidates = buf;

        if (llGetListLength(SensorCandidates) > 2) {
            SensorCandidates = llListSortStrided(SensorCandidates, 2, 0, TRUE);
        }

        if (llGetListLength(SensorCandidates) == 0) {
            llRegionSayTo(CurrentUser, 0, "No nearby objects found to post to.");
            cleanupSession();
            return;
        }
        displayObjectMenu();
    }

    no_sensor() {
        if (MenuContext != "post") return;
        if (CurrentUser == NULL_KEY) return;
        llRegionSayTo(CurrentUser, 0, "No nearby objects found to post to.");
        cleanupSession();
    }
}

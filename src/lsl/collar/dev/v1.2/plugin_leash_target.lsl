/*--------------------
PLUGIN: plugin_leash_target.lsl
VERSION: 1.2
REVISION: 0
PURPOSE: Unified hidden target-picker for all targeted leash flows. Merges the
         former plugin_leash_avatar (Clip/Pass/Offer/Coffle + offer reception)
         and plugin_leash_object (Post). One picker, two sources.
ARCHITECTURE: Hidden helper of plugin_leash (no plugin.reg.*, so kmod_ui never
              lists it). Receives ui.menu.start with context
              "ui.core.leash.target" + subpath:
                clip               -> grab immediately (no picker)
                pass/offer/coffle  -> AVATAR picker (llGetAgentList — avatars
                                      only by definition)
                post               -> OBJECT picker (llSensor PASSIVE|SCRIPTED —
                                      avatars are the AGENT sensor type and are
                                      excluded; a defensive llGetAgentSize check
                                      drops any stray agent too)
              The mode is implied by MenuContext (post => object; otherwise
              avatar), so the two sources are strictly mode-gated and can never
              cross-list. Dispatches plugin.leash.action to kmod_leash_engine,
              then returns to plugin_leash's menu via ui.menu.start. Also
              handles plugin.leash.offer.pending (offer-reception dialog).
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT       = "ui.core.leash.target";
string PARENT_PLUGIN_CONTEXT = "ui.core.leash";

/* -------------------- STATE -------------------- */
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
string SessionId = "";
string MenuContext = "";              // "pass" | "offer" | "coffle" | "post" (or "" idle)
list Candidates = [];                 // [name, key, name, key, ...] strided
integer PickPage = 0;

// Offer-reception dialog (independent session).
string OfferDialogSession = "";
key OfferTarget = NULL_KEY;
key OfferOriginator = NULL_KEY;

/* -------------------- HELPERS -------------------- */
string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

// Object mode => "object", everything else => "avatar".
integer is_object_mode() {
    return MenuContext == "post";
}

// Pass/Offer must not hand the leash to a blacklisted avatar. The engine used
// to enforce target ACL >= 1; with ACL decisions in the plugins, we check the
// canonical blacklist CSV directly (one synchronous LSD read). Pass/offer only —
// coffle/post have their own target validation in the engine.
integer is_blacklisted(key avatar) {
    string raw = llLinksetDataRead("blacklist.blklistuuid");
    if (raw == "") return FALSE;
    return llListFindList(llCSV2List(raw), [(string)avatar]) != -1;
}

string dialogTitleForContext(string ctx) {
    if (ctx == "pass") return "Pass Leash";
    if (ctx == "offer") return "Offer Leash";
    if (ctx == "coffle") return "Coffle";
    if (ctx == "post") return "Post";
    return "";
}

// Reorder items so an llDialog rendered from the returned list shows them
// top-to-bottom, left-to-right (matching the order the wearer reads in the
// body). 3 fixed nav buttons at indices 0-2 (bottom row); items fill above.
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

/* -------------------- ACTIONS -------------------- */
// The engine no longer re-verifies ACL; it trusts the policy-gated action and
// the acl level we resolved for this user (passed in via ui.menu.start).
sendAction(string action) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.action",
        "action", action,
        "acl", (string)UserAcl
    ]), CurrentUser);
}

sendActionWithTarget(string action, key target) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.action",
        "action", action,
        "target", (string)target,
        "acl", (string)UserAcl
    ]), CurrentUser);
}

/* -------------------- PICKER (shared render for both sources) -------------------- */
// Numbered-list convention (cf. plugin_outfits / plugin_animate): names are
// listed in the dialog BODY and the buttons are short numbers ("1".."9"), so a
// long avatar/object name can never exceed llDialog's 24-char button limit.
// Each number button carries the absolute candidate index as context
// ("sel:<i>") so selection is unambiguous regardless of page.
renderPickerPage(integer page) {
    integer total = llGetListLength(Candidates) / 2;
    integer total_pages = (total + 8) / 9;
    if (total_pages < 1) total_pages = 1;
    if (page < 0) page = 0;
    if (page >= total_pages) page = total_pages - 1;
    PickPage = page;

    integer start = page * 9;
    integer end = start + 9;
    if (end > total) end = total;

    string body = "Select ";
    if (is_object_mode()) body += "object:\n\n";
    else                  body += "avatar:\n\n";

    list nav_buttons = [btn("<<", "prev"), btn(">>", "next"), btn("Back", "back")];
    list item_buttons = [];
    integer i = start;
    integer display_num = 1;
    while (i < end) {
        string nm = llList2String(Candidates, i * 2);
        body += (string)display_num + ". " + nm + "\n";
        item_buttons += [btn((string)display_num, "sel:" + (string)i)];
        display_num++;
        i++;
    }
    list button_data = reorder_item_buttons(nav_buttons, item_buttons);

    if (total_pages > 1) {
        body += "\nPage " + (string)(page + 1) + "/" + (string)total_pages;
    }

    SessionId = generate_session_id();
    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", dialogTitleForContext(MenuContext),
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 60
    ]), NULL_KEY);
}

// AVATAR source — parcel agent list is avatars-only by definition.
populateAvatars() {
    list nearby = llGetAgentList(AGENT_LIST_PARCEL, []);
    key wearer = llGetOwner();
    list buf = [];
    integer i = 0;
    integer n = llGetListLength(nearby);
    while (i < n) {
        key detected = llList2Key(nearby, i);
        if (detected != wearer) buf += [llKey2Name(detected), detected];
        i++;
    }
    Candidates = buf;
    if (llGetListLength(Candidates) > 2) {
        Candidates = llListSortStrided(Candidates, 2, 0, TRUE);
    }
}

// OBJECT source — PASSIVE|SCRIPTED excludes avatars (they are AGENT type);
// ACTIVE omitted so moving avatars don't slip in.
startObjectScan() {
    PickPage = 0;
    Candidates = [];
    llSensor("", NULL_KEY, PASSIVE | SCRIPTED, 96.0, PI);
}

/* -------------------- OFFER RECEPTION DIALOG -------------------- */
showOfferDialog(key target, key originator) {
    OfferDialogSession = generate_session_id();
    OfferTarget = target;
    OfferOriginator = originator;

    string offerer_name = llKey2Name(originator);
    string wearer_name = llKey2Name(llGetOwner());

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", OfferDialogSession,
        "user", (string)target,
        "title", "Leash Offer",
        "body", offerer_name + " (" + wearer_name + ") is offering you their leash.",
        "button_data", llList2Json(JSON_ARRAY, [btn("Accept", "accept"), btn("Decline", "decline")]),
        "timeout", 60
    ]), NULL_KEY);
}

handleOfferResponse(string ctx) {
    if (ctx == "accept") {
        // Target accepts → they "grab" (engine swaps Leasher). Offer requires
        // the collar was unleashed, so this is a fresh claim and the acl tag is
        // unused engine-side; sent for protocol uniformity.
        llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
            "type", "plugin.leash.action",
            "action", "grab",
            "acl", (string)UserAcl
        ]), OfferTarget);
        llRegionSayTo(OfferOriginator, 0, llKey2Name(OfferTarget) + " accepted your leash offer.");
    }
    else {
        llRegionSayTo(OfferOriginator, 0, llKey2Name(OfferTarget) + " declined your leash offer.");
        llRegionSayTo(OfferTarget, 0, "You declined the leash offer.");
    }
    OfferDialogSession = "";
    OfferTarget = NULL_KEY;
    OfferOriginator = NULL_KEY;
}

/* -------------------- NAVIGATION -------------------- */
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
    Candidates = [];
    PickPage = 0;
}

/* -------------------- SUBPATH DISPATCH -------------------- */
handleSubpath(string subpath) {
    if (subpath == "clip") {
        sendAction("grab");
        cleanupSession();
    }
    else if (subpath == "pass" || subpath == "offer" || subpath == "coffle") {
        MenuContext = subpath;
        populateAvatars();
        if (llGetListLength(Candidates) == 0) {
            llRegionSayTo(CurrentUser, 0, "No nearby avatars found.");
            cleanupSession();
            return;
        }
        renderPickerPage(0);
    }
    else if (subpath == "post") {
        MenuContext = "post";
        startObjectScan();   // render deferred to sensor()/no_sensor()
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

    // Page math hoisted once — sibling-scope redeclaration is the LSL Mono
    // nested-scope trap (lslint misses it).
    integer total_pages = (llGetListLength(Candidates) / 2 + 8) / 9;
    if (total_pages < 1) total_pages = 1;

    if (ctx == "prev") {
        if (PickPage == 0) renderPickerPage(total_pages - 1);
        else               renderPickerPage(PickPage - 1);
        return;
    }
    if (ctx == "next") {
        if (PickPage >= total_pages - 1) renderPickerPage(0);
        else                             renderPickerPage(PickPage + 1);
        return;
    }
    if (llSubStringIndex(ctx, "sel:") == 0) {
        integer idx = (integer)llGetSubString(ctx, 4, -1);
        integer li = idx * 2;
        if (li >= 0 && li < llGetListLength(Candidates)) {
            key selected = llList2Key(Candidates, li + 1);
            if ((MenuContext == "pass" || MenuContext == "offer")
                && is_blacklisted(selected)) {
                llRegionSayTo(CurrentUser, 0,
                    "Cannot " + MenuContext + " leash: that person is blacklisted.");
                cleanupSession();
                return;
            }
            sendActionWithTarget(MenuContext, selected);
            cleanupSession();
            return;
        }
        llRegionSayTo(CurrentUser, 0, "Invalid selection.");
        cleanupSession();
    }
}

/* -------------------- EVENTS -------------------- */
default
{
    state_entry() {
        cleanupSession();
        OfferDialogSession = "";
        OfferTarget = NULL_KEY;
        OfferOriginator = NULL_KEY;
        // NB: deliberately no plugin.reg.* write — hidden from kmod_ui's top
        // menu; only plugin_leash dispatches to us via ui.menu.start.
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

            if (msg_type == "plugin.leash.offer.pending") {
                if (llJsonGetValue(msg, ["target"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["originator"]) == JSON_INVALID) return;
                key target = (key)llJsonGetValue(msg, ["target"]);
                key originator = (key)llJsonGetValue(msg, ["originator"]);
                showOfferDialog(target, originator);
                return;
            }
        }

        if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                string resp_session = llJsonGetValue(msg, ["session_id"]);
                if (resp_session == JSON_INVALID) return;
                string ctx = llJsonGetValue(msg, ["context"]);
                if (ctx == JSON_INVALID) ctx = "";

                if (resp_session == OfferDialogSession) {
                    handleOfferResponse(ctx);
                    return;
                }
                if (resp_session == SessionId) {
                    handlePickerClick(ctx);
                    return;
                }
                return;
            }
            if (msg_type == "ui.dialog.timeout") {
                string to_session = llJsonGetValue(msg, ["session_id"]);
                if (to_session == JSON_INVALID) return;
                if (to_session == OfferDialogSession) {
                    if (OfferOriginator != NULL_KEY) {
                        llRegionSayTo(OfferOriginator, 0,
                            "Leash offer to " + llKey2Name(OfferTarget) + " timed out.");
                    }
                    OfferDialogSession = "";
                    OfferTarget = NULL_KEY;
                    OfferOriginator = NULL_KEY;
                    return;
                }
                if (to_session == SessionId) {
                    cleanupSession();
                    return;
                }
            }
        }
    }

    // OBJECT mode only. PASSIVE|SCRIPTED already excludes avatars; the
    // llGetAgentSize guard is a defensive backstop so a stray agent can never
    // appear in the post list.
    sensor(integer num) {
        if (MenuContext != "post") return;
        if (CurrentUser == NULL_KEY) return;

        key wearer = llGetOwner();
        key my_key = llGetKey();
        list buf = [];
        integer i = 0;
        while (i < num) {
            key detected = llDetectedKey(i);
            if (detected != my_key && detected != wearer
                && llGetAgentSize(detected) == ZERO_VECTOR) {   // not an avatar
                buf += [llDetectedName(i), detected];
            }
            i = i + 1;
        }
        Candidates = buf;

        if (llGetListLength(Candidates) > 2) {
            Candidates = llListSortStrided(Candidates, 2, 0, TRUE);
        }
        if (llGetListLength(Candidates) == 0) {
            llRegionSayTo(CurrentUser, 0, "No nearby objects found to post to.");
            cleanupSession();
            return;
        }
        renderPickerPage(0);
    }

    no_sensor() {
        if (MenuContext != "post") return;
        if (CurrentUser == NULL_KEY) return;
        llRegionSayTo(CurrentUser, 0, "No nearby objects found to post to.");
        cleanupSession();
    }
}

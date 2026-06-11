/*--------------------
PLUGIN: plugin_leash_avatar.lsl
VERSION: 1.10
REVISION: 4
PURPOSE: Sub-plugin for avatar-target leash flows — Clip / Pass / Offer /
         Coffle. Also receives plugin.leash.offer.pending and shows the
         accept/decline dialog to the offer target.
ARCHITECTURE: Hidden helper of plugin_leash. Does NOT register
              plugin.reg.* (so kmod_ui doesn't list it in the top menu).
              Receives ui.menu.start with context="ui.core.leash.avatar"
              + subpath ("clip" | "pass" | "offer" | "coffle"); dispatches
              the corresponding plugin.leash.action to kmod_leash_engine.
              For pickers (pass/offer/coffle) shows an avatar selector and
              sends the action with target. After completion routes back
              to plugin_leash's main menu via ui.menu.start (context
              "ui.core.leash"). All four flows ultimately collapse to the
              same engine action — only the action verb and notice differ.
              Coffle and Pass differ in the engine: Pass swaps Controller,
              Coffle keeps Controller and changes FollowTarget only.
CHANGES:
- v1.10 rev 4: Dormancy guard widened to the renamed role-split markers ("D/s Collar updater v1.1" / "(updating)" / "(installing)").
- v1.10 rev 3: Real pagination on the avatar picker + wrap-around `<<` / `>>` matching plugin_folders / plugin_animate. Previously prev/next just re-scanned and re-rendered the same page; >9 nearby avatars silently overflowed reorder_item_buttons (items 10+ overwrote slot 0). Split showAvatarPicker (scan + sort) from renderAvatarPickerPage (page render), added SensorPage state, dropped the 18-cap (pagination handles it), dropped the now-redundant title parameter (dialogTitleForContext covers it).
- v1.10 rev 2: Destroy picker dialog after action dispatch instead of re-opening parent leash menu — matches the project's "process finished → dialog gone" convention. Folded the dialog close into cleanupSession (mirroring plugin_leash) so completion/error paths just call cleanupSession directly; returnToParent retained only for the Back button (explicit back-navigation).
- v1.10 rev 1: Initial split out of plugin_leash. Carries the Pass/Offer
  avatar picker, the Coffle avatar picker, and the offer-reception
  accept/decline dialog. Hidden from kmod_ui's top menu (no plugin.reg).
  Delegated to via ui.menu.start with context="ui.core.leash.avatar" and
  subpath naming the action (clip|pass|offer|coffle).
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT       = "ui.core.leash.avatar";
string PARENT_PLUGIN_CONTEXT = "ui.core.leash";

/* -------------------- STATE -------------------- */
// Active session (for picker flows).
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
string SessionId = "";
string MenuContext = "";              // "pass" | "offer" | "coffle" (or "" when idle)
list SensorCandidates = [];           // [name, key, name, key, ...] strided
integer SensorPage = 0;               // current page index for paginated picker

// Offer-reception dialog (independent session).
string OfferDialogSession = "";
key OfferTarget = NULL_KEY;
key OfferOriginator = NULL_KEY;

// We don't need Leasher state here — engine validates ACL server-side.

/* -------------------- HELPERS -------------------- */
string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

// Reorder items so an llDialog rendered from the returned list shows them
// top-to-bottom, left-to-right (matching the order the wearer reads in
// the body text). 3 fixed nav buttons at indices 0-2 (bottom row); items
// fill the three rows above in top-to-bottom order.
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

/* -------------------- AVATAR PICKER -------------------- */
// Scan + sort once, then hand off to renderAvatarPickerPage. Pagination
// fans out arbitrary agent counts across pages of 9; the old 18-cap was a
// workaround for the single-shot render and is gone.
showAvatarPicker(string action_name) {
    MenuContext = action_name;

    list nearby = llGetAgentList(AGENT_LIST_PARCEL, []);
    key wearer = llGetOwner();

    // Build into local list (refcount 1 → O(n) amortized; appending
    // directly to a global is O(n²) — see plugin_leash rev 18 fix).
    list buf = [];
    integer i = 0;
    integer n = llGetListLength(nearby);
    while (i < n) {
        key detected = llList2Key(nearby, i);
        if (detected != wearer) {
            buf += [llKey2Name(detected), detected];
        }
        i++;
    }
    SensorCandidates = buf;

    if (llGetListLength(SensorCandidates) > 2) {
        SensorCandidates = llListSortStrided(SensorCandidates, 2, 0, TRUE);
    }

    if (llGetListLength(SensorCandidates) == 0) {
        llRegionSayTo(CurrentUser, 0, "No nearby avatars found.");
        cleanupSession();
        return;
    }

    renderAvatarPickerPage(0);
}

// Render a single page of cached SensorCandidates. SensorPage is updated
// here; prev/next in handlePickerClick supplies the new index (with wrap).
renderAvatarPickerPage(integer page) {
    integer total = llGetListLength(SensorCandidates) / 2;
    integer total_pages = (total + 8) / 9;
    if (total_pages < 1) total_pages = 1;
    if (page < 0) page = 0;
    if (page >= total_pages) page = total_pages - 1;
    SensorPage = page;

    integer start = page * 9;
    integer end = start + 9;
    if (end > total) end = total;

    list nav_buttons = [btn("<<", "prev"), btn(">>", "next"), btn("Back", "back")];
    list item_buttons = [];
    integer i = start;
    while (i < end) {
        string avatar_name = llList2String(SensorCandidates, i * 2);
        item_buttons += [btn(avatar_name, "sel:" + avatar_name)];
        i++;
    }
    list button_data = reorder_item_buttons(nav_buttons, item_buttons);

    string body = "Select avatar:";
    if (total_pages > 1) {
        body += "\n\nPage " + (string)(page + 1) + "/" + (string)total_pages;
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

/* -------------------- ACTIONS -------------------- */
sendAction(string action) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.action",
        "action", action
    ]), CurrentUser);
}

sendActionWithTarget(string action, key target) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.action",
        "action", action,
        "target", (string)target
    ]), CurrentUser);
}

/* -------------------- OFFER RECEPTION DIALOG -------------------- */
// Engine fires plugin.leash.offer.pending after target ACL passes. We
// open a dialog directed at the offer target asking accept/decline.
showOfferDialog(key target, key originator) {
    OfferDialogSession = generate_session_id();
    OfferTarget = target;
    OfferOriginator = originator;

    string offerer_name = llKey2Name(originator);
    key wearer = llGetOwner();
    string wearer_name = llKey2Name(wearer);

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
        // Target accepts → they "grab" the leash (engine swaps Leasher).
        llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
            "type", "plugin.leash.action",
            "action", "grab"
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
// Called when ui.menu.start arrives with our context. subpath selects
// the action: "clip" sends grab immediately (no picker); pass/offer/
// coffle open the avatar picker.
handleSubpath(string subpath) {
    if (subpath == "clip") {
        sendAction("grab");
        cleanupSession();
    }
    else if (subpath == "pass") {
        showAvatarPicker("pass");
    }
    else if (subpath == "offer") {
        showAvatarPicker("offer");
    }
    else if (subpath == "coffle") {
        showAvatarPicker("coffle");
    }
    else {
        // Unknown subpath — nothing to do, just clean up.
        cleanupSession();
    }
}

/* -------------------- BUTTON CLICK HANDLING -------------------- */
handlePickerClick(string ctx, string clicked_btn) {
    if (ctx == "back") {
        returnToParent();
        return;
    }

    // Page math hoisted once — sibling-scope redeclaration is the LSL Mono
    // nested-scope trap (lslint misses it). Wrap-around paging matches
    // plugin_folders / plugin_animate.
    integer total_pages = (llGetListLength(SensorCandidates) / 2 + 8) / 9;
    if (total_pages < 1) total_pages = 1;

    if (ctx == "prev") {
        if (SensorPage == 0) renderAvatarPickerPage(total_pages - 1);
        else                 renderAvatarPickerPage(SensorPage - 1);
        return;
    }
    if (ctx == "next") {
        if (SensorPage >= total_pages - 1) renderAvatarPickerPage(0);
        else                               renderAvatarPickerPage(SensorPage + 1);
        return;
    }

    // Avatar selection — match the raw clicked label against SensorCandidates.
    key selected = NULL_KEY;
    integer i = 0;
    integer n = llGetListLength(SensorCandidates);
    while (i < n) {
        if (llList2String(SensorCandidates, i) == clicked_btn) {
            selected = llList2Key(SensorCandidates, i + 1);
            i = n;
        }
        else i = i + 2;
    }

    if (selected != NULL_KEY) {
        // MenuContext is the action verb ("pass" / "offer" / "coffle").
        sendActionWithTarget(MenuContext, selected);
        cleanupSession();
    }
    else {
        llRegionSayTo(CurrentUser, 0, "Avatar not found.");
        cleanupSession();
    }
}

string dialogTitleForContext(string ctx) {
    if (ctx == "pass") return "Pass Leash";
    if (ctx == "offer") return "Offer Leash";
    if (ctx == "coffle") return "Coffle";
    return "";
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
        OfferDialogSession = "";
        OfferTarget = NULL_KEY;
        OfferOriginator = NULL_KEY;
        // NB: deliberately no plugin.reg.* write — this sub-plugin is
        // hidden from kmod_ui's top menu; only plugin_leash dispatches
        // to us via ui.menu.start.
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
                string clicked_btn = llJsonGetValue(msg, ["button"]);
                if (clicked_btn == JSON_INVALID) clicked_btn = "";

                if (resp_session == OfferDialogSession) {
                    handleOfferResponse(ctx);
                    return;
                }
                if (resp_session == SessionId) {
                    handlePickerClick(ctx, clicked_btn);
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
}

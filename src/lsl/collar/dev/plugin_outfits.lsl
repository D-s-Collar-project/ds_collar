/*--------------------
PLUGIN: plugin_outfits.lsl
VERSION: 1.10
REVISION: 1
PURPOSE: Browse #RLV/.outfits subfolders and wear them. Two actions per
         outfit: Wear (attach additively) and Replace (detach all items
         under #RLV/.outfits then attach the chosen folder).
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button
             visibility. Subfolder enumeration via @getinv:.outfits=<chan>
             on every menu entry — no persisted manifest. Attach/detach
             commands route through kmod_rlv (rlv.force passthrough).
CHANGES:
- v1.10 rev 1: handle_rlv_response pre-allocates Outfits via list
  doubling and fills with llListReplaceList instead of `+=` inside
  the parse loop. Matches plugin_folders rev 26 pattern; clears the
  analyzer's O(N²) loop-concat warning on large .outfits trees.
- v1.10 rev 0: Initial implementation.
--------------------*/

/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS           = 900;
integer DIALOG_BUS       = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.outfits";
string PLUGIN_LABEL   = "Outfits";

/* -------------------- RLV -------------------- */
integer RLV_CHAN    = 1888772;
float   RLV_TIMEOUT = 10.0;
string  OUTFITS_ROOT = ".outfits";   // #RLV-relative root for outfit subfolders.

/* -------------------- STATE -------------------- */
key     CurrentUser    = NULL_KEY;
integer UserAcl        = 0;
list    gPolicyButtons = [];
string  SessionId      = "";

// "scanning" = awaiting @getinv response; "pick" = paginated picker;
// "action"   = per-outfit Wear/Replace submenu.
string  MenuContext      = "";
string  SelectedOutfit   = "";

list    Outfits          = [];
integer PickPage         = 0;
integer LastMaxPage      = 0;
integer PageSize         = 9;

integer RlvListenHandle  = 0;

/* -------------------- HELPERS -------------------- */

integer json_has(string j, list path) {
    return (llJsonGetValue(j, path) != JSON_INVALID);
}

string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

string btn(string label, string ctx) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", ctx]);
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
    // All ACL levels (including wearer + public) may browse and apply
    // outfits. Both Wear and Replace are available to every level.
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "Wear,Replace",
        "2", "Wear,Replace",
        "3", "Wear,Replace",
        "4", "Wear,Replace",
        "5", "Wear,Replace"
    ]));

    write_plugin_reg(PLUGIN_LABEL);

    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label",   PLUGIN_LABEL,
        "script",  llGetScriptName()
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

stop_rlv_listen() {
    if (RlvListenHandle != 0) {
        llListenRemove(RlvListenHandle);
        RlvListenHandle = 0;
    }
    llSetTimerEvent(0.0);
}

cleanup_session() {
    stop_rlv_listen();

    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type",       "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
    }

    SessionId       = "";
    CurrentUser     = NULL_KEY;
    UserAcl         = 0;
    gPolicyButtons  = [];
    MenuContext     = "";
    SelectedOutfit  = "";
    Outfits         = [];
    PickPage        = 0;
    LastMaxPage     = 0;
}

return_to_root() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "ui.menu.return",
        "context", PLUGIN_CONTEXT,
        "user",    (string)CurrentUser
    ]), NULL_KEY);
    cleanup_session();
}

/* -------------------- RLV -------------------- */

rlv_force(string command) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",    "rlv.force",
        "command", command
    ]), NULL_KEY);
}

scan_outfits() {
    Outfits = [];
    MenuContext = "scanning";
    stop_rlv_listen();
    RlvListenHandle = llListen(RLV_CHAN, "", llGetOwner(), "");
    llSetTimerEvent(RLV_TIMEOUT);
    rlv_force("@getinv:" + OUTFITS_ROOT + "=" + (string)RLV_CHAN);
    llRegionSayTo(CurrentUser, 0, "Reading #RLV/" + OUTFITS_ROOT + " ...");
}

/* -------------------- UI -------------------- */

show_picker(integer page) {
    integer total = llGetListLength(Outfits);

    SessionId   = generate_session_id();
    MenuContext = "pick";

    integer max_page;
    if (total == 0) max_page = 0;
    else            max_page = (total - 1) / PageSize;
    if (page < 0)        page = 0;
    if (page > max_page) page = max_page;
    PickPage    = page;
    LastMaxPage = max_page;

    integer start_idx = page * PageSize;
    integer end_idx   = start_idx + PageSize;
    if (end_idx > total) end_idx = total;
    integer count = end_idx - start_idx;

    string body = "Outfits  (#RLV/" + OUTFITS_ROOT + ")\n";
    if (total == 0) {
        body += "\nNo outfits found.\n";
        body += "Create subfolders under #RLV/" + OUTFITS_ROOT + ".";
    }
    else {
        body += "Page " + (string)(page + 1) + " of " + (string)(max_page + 1) + "\n\n";
        integer k = 0;
        while (k < count) {
            integer item_idx = start_idx + k;
            string  outfit_name = llList2String(Outfits, item_idx);
            body += (string)(k + 1) + ". " + outfit_name + "\n";
            k += 1;
        }
    }

    // Layout per project convention: slots 0-2 = nav (<<, >>, Back),
    // slots 3-11 = content, fills top-down so item 1 is always top-left.
    list button_data = [
        btn("<<",   "prev"),
        btn(">>",   "next"),
        btn("Back", "back")
    ];

    integer pad_i;
    for (pad_i = 0; pad_i < count; pad_i += 1) button_data += [btn(" ", " ")];

    integer total_buttons = 3 + count;
    list target_slots = [];
    if (total_buttons > 9)  target_slots += [9];
    if (total_buttons > 10) target_slots += [10];
    if (total_buttons > 11) target_slots += [11];
    if (total_buttons > 6)  target_slots += [6];
    if (total_buttons > 7)  target_slots += [7];
    if (total_buttons > 8)  target_slots += [8];
    if (total_buttons > 3)  target_slots += [3];
    if (total_buttons > 4)  target_slots += [4];
    if (total_buttons > 5)  target_slots += [5];

    integer ci = 0;
    while (ci < count) {
        integer slot     = llList2Integer(target_slots, ci);
        integer item_idx = start_idx + ci;
        button_data = llListReplaceList(
            button_data,
            [btn((string)(ci + 1), "pick:" + (string)item_idx)],
            slot, slot
        );
        ci += 1;
    }

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type",        "ui.dialog.open",
        "session_id",  SessionId,
        "user",        (string)CurrentUser,
        "title",       PLUGIN_LABEL,
        "body",        body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout",     60
    ]), NULL_KEY);
}

show_action(string outfit_name) {
    SessionId      = generate_session_id();
    MenuContext    = "action";
    SelectedOutfit = outfit_name;

    string body = "Outfit: " + outfit_name + "\n\n";
    body += "Wear    - attach this folder on top of what's currently worn.\n";
    body += "Replace - detach everything under #RLV/" + OUTFITS_ROOT;
    body += " first, then attach this folder.";

    // Three-button action dialog — no padding per CLAUDE.md (small
    // confirmation-style dialogs skip the multiples-of-3 cosmetic pad).
    // Slots: 0=Wear, 1=Replace, 2=Back; reading left→right.
    list button_data = [];
    if (btn_allowed("Wear"))    button_data += [btn("Wear",    "wear")];
    if (btn_allowed("Replace")) button_data += [btn("Replace", "replace")];
    button_data += [btn("Back", "back")];

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type",        "ui.dialog.open",
        "session_id",  SessionId,
        "user",        (string)CurrentUser,
        "title",       PLUGIN_LABEL,
        "body",        body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout",     60
    ]), NULL_KEY);
}

apply_wear(string outfit_name) {
    rlv_force("@attachall:" + OUTFITS_ROOT + "/" + outfit_name + "=force");
    llRegionSayTo(CurrentUser, 0, "Wearing: " + outfit_name);
}

apply_replace(string outfit_name) {
    // Detach anything currently worn from anywhere under the .outfits
    // tree, then attach the chosen folder. Items worn from outside
    // .outfits (e.g. HUDs, AOs, jewelry in other folders) are untouched.
    rlv_force("@detachall:" + OUTFITS_ROOT + "=force");
    rlv_force("@attachall:" + OUTFITS_ROOT + "/" + outfit_name + "=force");
    llRegionSayTo(CurrentUser, 0, "Replacing with: " + outfit_name);
}

/* -------------------- DIALOG HANDLER -------------------- */

handle_dialog_response(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;

    key response_user = (key)llJsonGetValue(msg, ["user"]);
    if (response_user != CurrentUser) return;

    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";

    if (MenuContext == "pick") {
        if (ctx == "back") {
            return_to_root();
            return;
        }
        if (ctx == "prev") {
            if (PickPage == 0) show_picker(LastMaxPage);
            else               show_picker(PickPage - 1);
            return;
        }
        if (ctx == "next") {
            if (PickPage >= LastMaxPage) show_picker(0);
            else                         show_picker(PickPage + 1);
            return;
        }
        if (llSubStringIndex(ctx, "pick:") == 0) {
            integer pick_idx = (integer)llGetSubString(ctx, 5, -1);
            if (pick_idx >= 0 && pick_idx < llGetListLength(Outfits)) {
                show_action(llList2String(Outfits, pick_idx));
            }
        }
        return;
    }

    if (MenuContext == "action") {
        if (ctx == "back") {
            show_picker(PickPage);
            return;
        }
        if (ctx == "wear") {
            apply_wear(SelectedOutfit);
            show_picker(PickPage);
            return;
        }
        if (ctx == "replace") {
            apply_replace(SelectedOutfit);
            show_picker(PickPage);
        }
    }
}

handle_dialog_timeout(string msg) {
    if (!json_has(msg, ["session_id"])) return;
    if (llJsonGetValue(msg, ["session_id"]) != SessionId) return;
    cleanup_session();
}

/* -------------------- RLV RESPONSE HANDLER -------------------- */

handle_rlv_response(string message) {
    stop_rlv_listen();
    if (CurrentUser == NULL_KEY) return;
    if (MenuContext != "scanning") return;

    Outfits = [];
    if (message != "") {
        // @getinv returns a CSV of immediate subfolder names. Skip
        // dot-prefixed (hidden) and tilde-prefixed (viewer-managed
        // Give-to-#RLV) entries per the project convention used in
        // plugin_folders. Pre-allocate Outfits to the parsed CSV
        // capacity via list doubling, then fill with llListReplaceList
        // and truncate — avoids O(N²) heap churn on large outfit trees
        // (matches the plugin_folders rev 26 pattern).
        list raw = llParseString2List(message, [","], []);
        integer n = llGetListLength(raw);

        if (n > 0) {
            list buf = [""];
            while (llGetListLength(buf) < n) buf = buf + buf;
            Outfits = llList2List(buf, 0, n - 1);
        }

        integer filled = 0;
        integer i = 0;
        while (i < n) {
            string entry = llStringTrim(llList2String(raw, i), STRING_TRIM);
            if (entry != "") {
                string first = llGetSubString(entry, 0, 0);
                if (first != "." && first != "~") {
                    Outfits = llListReplaceList(Outfits, [entry], filled, filled);
                    filled += 1;
                }
            }
            i += 1;
        }

        if (filled == 0)     Outfits = [];
        else if (filled < n) Outfits = llList2List(Outfits, 0, filled - 1);

        if (filled > 0) Outfits = llListSort(Outfits, 1, TRUE);
    }

    if (llGetListLength(Outfits) == 0) {
        llRegionSayTo(CurrentUser, 0,
            "No outfits found in #RLV/" + OUTFITS_ROOT + ".");
        return_to_root();
        return;
    }

    show_picker(0);
}

/* -------------------- EVENTS -------------------- */
default {
    state_entry() {
        if (llGetObjectDesc() == "COLLAR_UPDATER") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        cleanup_session();
        register_self();
    }

    on_rez(integer param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }

    timer() {
        // @getinv response timed out — viewer not RLV-enabled or not
        // responding. cleanup_session in return_to_root resets state.
        stop_rlv_listen();
        if (CurrentUser != NULL_KEY) {
            llRegionSayTo(CurrentUser, 0, "RLV not responding. Is RLV mode enabled?");
            return_to_root();
        }
    }

    listen(integer channel, string name, key id, string message) {
        if (channel == RLV_CHAN && id == llGetOwner()) {
            handle_rlv_response(message);
        }
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
                llLinksetDataDelete("plugin.reg." + PLUGIN_CONTEXT);
                llLinksetDataDelete("acl.policycontext:" + PLUGIN_CONTEXT);
                llResetScript();
            }
        }
        else if (num == UI_BUS) {
            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                string ctx = llJsonGetValue(msg, ["context"]);
                if (ctx != PLUGIN_CONTEXT) return;
                if (id == NULL_KEY) return;

                integer start_acl = (integer)llJsonGetValue(msg, ["acl"]);

                gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, start_acl);
                if (!btn_allowed("Wear") && !btn_allowed("Replace")) {
                    llRegionSayTo(id, 0, "Access denied.");
                    gPolicyButtons = [];
                    return;
                }

                CurrentUser = id;
                UserAcl     = start_acl;
                scan_outfits();
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
}

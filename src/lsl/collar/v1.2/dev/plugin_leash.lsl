/*--------------------
PLUGIN: plugin_leash.lsl
VERSION: 1.2
REVISION: 12
PURPOSE: Self-contained leash UI — main menu, Settings (length/turn/texture/
         enhanced), Get Holder, direct actions (Clip/Unclip/Yank/Take), AND
         the target picker (avatar picker for Pass/Offer/Coffle, object scan
         for Post, offer-reception modal). Absorbed plugin_leash_target.
CHANGES:
- v1.2 rev 12: main to menu.fixed (dropped showMenu page param + LeashPage cursor + main prev/next), picker to menu.ordered, offer to dialog.modal; cleans up on the new ui.dialog.close.
- v1.2 rev 11: main menu now paginates — showMenu gained a `page` arg; showMainMenu clamps/wraps a LeashPage cursor to its button count and pages on prev/next (the normalized nav contexts), settings/texture/length pass page 0 (their << >> redraw). Defensive; part of the all-pagers-operational pass.
- v1.2 rev 10: length menu reworked — -1m/ +1m are now dedicated fixed buttons (contexts len_dec/len_inc) flanking a blank spacer, landing at slots 3 and 5 in the row above nav (needs kmod_menu rev 15 pager `fixed` support). << >> revert to plain inert nav (no longer repurposed as ±1m). showMenu() gained a `fixed` param; the other three menus pass [].
- v1.2 rev 9: service nav normalized from the new nav:* contexts (was synthesized from the button labels << >> Back); the internal back/prev/next vocabulary + the length-menu << >> -1m/+1m repurposing are unchanged. No longer reads the button label.
- v1.2 rev 8: ABSORBED plugin_leash_target — the former hidden picker sub-plugin is now in-line. The main menu / chat verbs call startPicker() directly instead of delegating over ui.menu.start, so the whole delegation seam is gone (delegateTo + returnToParent + the ui.menu.start re-entry/subpath redispatch). Picker renders via OL mode, offer-reception via modal mode. The two scripts' action senders collapse onto one sendAction(action, extra, recipient). One MenuContext spans the menu (main/settings/texture/length) + picker (pass/offer/coffle/post) states; the dialog-response router dispatches picker-vs-menu by MenuContext and the offer by its own session. sensor()/no_sensor() (Post object scan) move here. Merged footprint ~56.4 KB / 86% of the Mono ceiling; retires plugin_leash_target (was leash 42.3 KB + target 25.2 KB across two scripts). Nav-row consistency: has_nav 0→1 on showMenu (full << >> Back row on every menu, per the project convention), length's << >> repurposed as -1m/+1m, catch-all redraws for the inert << >> on the other menus.
- v1.2 rev 7: menu-service migration + bytecode dedup. All four menus (main/settings/texture/length) now render via the pager (showMenu → ui.menu.render, DIALOG_BUS→UI_BUS); callers pass CONTENT buttons only and the service supplies Back + layout, so reorder_item_buttons is deleted outright. Length's << / >> (-1m/+1m fine-tune) ride as content buttons, not pager nav. Response handler maps the service's plain Back → "back" so the per-menu back branches are unchanged. The four near-identical senders (sendLeashAction / *WithTarget / sendSetLength / inline set_texture) collapse onto one sendAction(action, extra) builder — removes 3x the llMessageLinked/JSON boilerplate. PLUGIN_CATEGORY/MASK hoisted to the identity block (render_menu reads category). No behavior change beyond Back/layout now owned by the service.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. See collar_kernel rev 6.
- v1.2 rev 2: Leash UI button policy reworked. Pass → ACL {1,3,5} (was {3,4,5}): added ACL 1 (public) for a captor→slaver handoff, dropped ACL 4; the CurrentUser==Leasher guard still gates it (only the actual holder sees Pass) and the recipient still gets the accept dialog. Take → ACL 5 only (was {3,5}). Self-owned/unowned wearer (ACL 4) trimmed to {Unclip, Offer, Coffle, Get Holder, Settings}: a self-owned sub can offer its own leash (Offer) and coffle, but no longer self-clips / posts / yanks / passes. Owned wearer (ACL 2) stays Offer-only.
- v1.2 rev 1: Removed the orphaned 0.5s STATE_QUERY_DELAY (a leftover from a former blocking-llSleep pattern) that made every menu open/refresh hang half a second before even sending the state query. scheduleStateQuery now queries immediately — link messages are ordered and instant, so the reply drives the menu with no perceptible lag. Dropped STATE_QUERY_DELAY, the PendingStateQuery flag, and the now-dead timer() handler (plugin no longer uses a timer).
ARCHITECTURE: Self-contained leash UI. Menus + picker share the kmod_menu
              service (pager / OL / modal modes). Talks to kmod_leash_engine
              via plugin.leash.action and consumes plugin.leash.state +
              plugin.leash.offer.pending. The picker is internal (no
              sub-plugin); startPicker() replaces the old delegation seam.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.leash";
string PLUGIN_LABEL = "Leash";
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L = visible
// at ACL level L). Consumed by kmod_ui's view rebuild AND the menu service
// (render_menu reads category to render the Back nav + tier title).
string PLUGIN_CATEGORY = "Standalone";
integer PLUGIN_ACL_MASK = 62;


/* -------------------- STATE -------------------- */
// Current leash state (synced from core)
integer Leashed = FALSE;
key Leasher = NULL_KEY;
integer LeashLength = 3;
integer TurnToFace = FALSE;
string LeashTexture = "chain"; // "chain" / "silk" / "invisible"
integer EnhancedMode = TRUE;      // ACL 3+ intent toggle, applied locally (see sync_enhanced). ON by default — a leash should restrain.
integer EnhancedApplied = TRUE;   // whether @sittp,... is currently issued (idempotence guard).
                                  // Defaults TRUE so the first sync at boot forces a clean clear,
                                  // wiping any stale restriction left by a reset-while-worn.
integer LeashMode = 0;       // 0=avatar, 1=coffle, 2=post
key LeashTarget = NULL_KEY;  // Target for coffle/post

// Session/menu state, shared by the top-level menu + Settings + the in-line
// picker (Pass/Offer/Coffle avatar picker, Post object scan, offer reception).
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
list gPolicyButtons = [];  // Cached policy buttons for current user's ACL
string SessionId = "";
string MenuContext = "";

// Which menu to show once the queried plugin.leash.state reply lands.
string PendingQueryContext = "";

// Registration state (SYN/ACK pattern for active discovery)
integer IsRegistered = FALSE;

// --- merged from plugin_leash_target: picker + offer-reception state ---
list Candidates = [];                 // [name, key, ...] strided
integer PickPage = 0;
string OfferDialogSession = "";
key OfferTarget = NULL_KEY;
key OfferOriginator = NULL_KEY;

/* -------------------- HELPERS -------------------- */


string generate_session_id() {
    return PLUGIN_CONTEXT + "_" + (string)llGetUnixTime();
}

/* -------------------- LSD POLICY HELPER -------------------- */
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


/* -------------------- BUTTON DATA HELPER -------------------- */
string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

/* -------------------- UNIFIED MENU DISPLAY -------------------- */
showMenu(string context, string title, string body, list buttons, list fixed) {
    SessionId = generate_session_id();
    MenuContext = context;

    // menu.fixed: all four leash menus are small structural sets; never
    // paginate. `fixed` rides between nav and content (the length menu uses it
    // for the -1m / +1m buttons flanking a spacer); [] for the others.
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "menu.fixed",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "title",      title,
        "body",       body,
        "buttons",    llList2Json(JSON_ARRAY, buttons),
        "fixed",      llList2Json(JSON_ARRAY, fixed)
    ]), NULL_KEY);
}

/* -------------------- PLUGIN REGISTRATION -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// PLUGIN_CATEGORY / PLUGIN_ACL_MASK are declared in the identity block above.
register_self() {
    // Per-button visibility policy (default-deny per ACL level). Was written
    // straight to LSD here; now announced to the kernel, which is the SOLE
    // writer of acl.policycontext (and reg.<ctx>) — see collar_kernel rev 6.
    // ACL 1 (public) may Unclip, but the in-code guard at showMainMenu limits
    // the button to cases where CurrentUser == Leasher — so only a public user
    // who holds the leash themselves can release it.
    string policy = llList2Json(JSON_OBJECT, [
        "1", "Clip,Unclip,Pass,Coffle,Post,Get Holder,Settings",
        "2", "Offer",
        "3", "Clip,Unclip,Pass,Yank,Coffle,Post,Get Holder,Settings",
        "4", "Unclip,Offer,Coffle,Get Holder,Settings",
        "5", "Clip,Unclip,Pass,Yank,Take,Coffle,Post,Get Holder,Settings"
    ]);

    // Announce full registration. The kernel writes reg.<ctx> + the policy to
    // LSD itself, draining its queue serially — no concurrent write burst.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName(),
        "cat", PLUGIN_CATEGORY,
        "mask", (string)PLUGIN_ACL_MASK,
        "policy", policy
    ]), NULL_KEY);

    // Declare chat alias.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "leash",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

/* -------------------- MENU SYSTEM -------------------- */
showMainMenu() {
    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    list item_buttons = [];

    // Action buttons — policy defines the superset, state logic narrows
    if (!Leashed) {
        if (btn_allowed("Clip"))    item_buttons += [btn("Clip", "clip")];
        if (btn_allowed("Offer"))   item_buttons += [btn("Offer", "offer")];
        if (btn_allowed("Coffle"))  item_buttons += [btn("Coffle", "coffle")];
        if (btn_allowed("Post"))    item_buttons += [btn("Post", "post")];
    }
    else {
        // Unclip: policy + must be leasher or ACL 3+
        if (btn_allowed("Unclip") && (CurrentUser == Leasher || UserAcl >= 3)) {
            item_buttons += [btn("Unclip", "unclip")];
        }
        // Pass/Yank: policy + must be current leasher
        if (CurrentUser == Leasher) {
            if (btn_allowed("Pass")) item_buttons += [btn("Pass", "pass")];
            if (btn_allowed("Yank")) item_buttons += [btn("Yank", "yank")];
        }
        // Take: policy + not current leasher + ACL 3+
        if (btn_allowed("Take") && CurrentUser != Leasher && UserAcl >= 3) {
            item_buttons += [btn("Take", "clip")];
        }
    }

    if (btn_allowed("Get Holder")) item_buttons += [btn("Get Holder", "get_holder")];
    if (btn_allowed("Settings"))   item_buttons += [btn("Settings", "settings")];

    string body;
    if (Leashed) {
        string mode_text = "Avatar";
        if (LeashMode == 1) mode_text = "Coffle";
        else if (LeashMode == 2) mode_text = "Post";

        body = "Mode: " + mode_text + "\n";
        body += "Leashed to: " + llKey2Name(Leasher) + "\n";
        body += "Length: " + (string)LeashLength + "m";

        if (LeashTarget != NULL_KEY) {
            list details = llGetObjectDetails(LeashTarget, [OBJECT_NAME]);
            if (llGetListLength(details) > 0) {
                body += "\nTarget: " + llList2String(details, 0);
            }
        }
    }
    else {
        body = "Not leashed";
    }

    showMenu("main", "Leash", body, item_buttons, []);
}

showSettingsMenu() {
    list item_buttons = [btn("Length", "length")];
    if (TurnToFace) item_buttons += [btn("Turn: On",  "toggle_turn")];
    else            item_buttons += [btn("Turn: Off", "toggle_turn")];
    item_buttons += [btn("Texture", "texture")];

    // Enhanced toggle is ACL 3+ only (trustees/owners). Engine enforces
    // the same floor on the action; this just hides the button for
    // lower ACLs so they don't get a deny notice.
    if (UserAcl >= 3) {
        if (EnhancedMode) item_buttons += [btn("Enhance: Y", "toggle_enhanced")];
        else              item_buttons += [btn("Enhance: N", "toggle_enhanced")];
    }

    string texture_label = "Chain";
    if      (LeashTexture == "silk")      texture_label = "Silk";
    else if (LeashTexture == "invisible") texture_label = "Invisible";

    string turn_state = "Disabled";
    if (TurnToFace) turn_state = "Enabled";

    string body = "Leash Settings\nLength: " + (string)LeashLength
                + "m\nTurn to leasher: " + turn_state
                + "\nTexture: " + texture_label;
    if (UserAcl >= 3) {
        string enh_state = "Disabled";
        if (EnhancedMode) enh_state = "Enabled";
        body += "\nEnhanced mode: " + enh_state;
    }
    showMenu("settings", "Settings", body, item_buttons, []);
}

showTextureMenu() {
    string current = "Chain";
    if      (LeashTexture == "silk")      current = "Silk";
    else if (LeashTexture == "invisible") current = "Invisible";

    list item_buttons = [btn("Chain", "chain"), btn("Silk", "silk"), btn("Invisible", "invisible")];
    showMenu("texture", "Texture",
             "Select leash texture\nCurrent: " + current, item_buttons, []);
}

showLengthMenu() {
    // Preset lengths are the content buttons (label-on-button, caller order).
    // -1m / +1m ride as fixed buttons flanking a blank spacer so they land at
    // slots 3 and 5 (the row above nav). << >> stay as plain inert nav.
    list item_buttons = [
        btn("1m",  "1"),  btn("3m",  "3"),  btn("5m",  "5"),
        btn("10m", "10"), btn("15m", "15"), btn("20m", "20")
    ];
    list fixed = [btn("-1m", "len_dec"), btn(" ", ""), btn("+1m", "len_inc")];
    showMenu("length", "Length",
             "Select leash length\nCurrent: " + (string)LeashLength + "m",
             item_buttons, fixed);
}

/* ===== in-line target picker (absorbed from plugin_leash_target) ===== */
// The former hidden sub-plugin is now in-line: the main menu / chat verbs call
// startPicker() directly instead of delegating over ui.menu.start, so the whole
// delegation seam (delegateTo + returnToParent + re-entry) is gone.

integer is_blacklisted(key avatar) {
    return (integer)llLinksetDataRead("user." + (string)avatar) == -1;
}

string dialogTitleForContext(string ctx) {
    if (ctx == "pass") return "Pass Leash";
    if (ctx == "offer") return "Offer Leash";
    if (ctx == "coffle") return "Coffle";
    if (ctx == "post") return "Post";
    return "";
}

// OL picker render: hand the service the candidate names; it numbers the body,
// pages, adds << >> Back, returns pick:<global-index>.
renderPickerPage(integer page) {
    integer total = llGetListLength(Candidates) / 2;
    integer total_pages = (total + 8) / 9;
    if (total_pages < 1) total_pages = 1;
    if (page < 0) page = 0;
    if (page >= total_pages) page = total_pages - 1;
    PickPage = page;

    list names = [];
    integer i = 0;
    while (i < total) {
        names += [llList2String(Candidates, i * 2)];
        i++;
    }

    string body = "Select avatar:";
    if (MenuContext == "post") body = "Select object:";

    SessionId = generate_session_id();
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "menu.ordered",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      dialogTitleForContext(MenuContext),
        "body",       body,
        "items",      llList2Json(JSON_ARRAY, names),
        "page",       PickPage
    ]), NULL_KEY);
}

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

startObjectScan() {
    PickPage = 0;
    Candidates = [];
    llSensor("", NULL_KEY, PASSIVE | SCRIPTED, 96.0, PI);
}

// Entry point that replaces delegateTo: avatar picker for pass/offer/coffle,
// object scan for post (render deferred to sensor()).
startPicker(string subpath) {
    if (subpath == "pass" || subpath == "offer" || subpath == "coffle") {
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
        startObjectScan();
    }
}

// Offer-reception modal to the offer TARGET (arbitrary user), Decline-first.
showOfferDialog(key target, key originator) {
    OfferDialogSession = generate_session_id();
    OfferTarget = target;
    OfferOriginator = originator;

    string offerer_name = llKey2Name(originator);
    string wearer_name = llKey2Name(llGetOwner());

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",          "ui.menu.render",
        "mode",          "dialog.modal",
        "session_id",    OfferDialogSession,
        "user",          (string)target,
        "title",         "Leash Offer",
        "body",          offerer_name + " (" + wearer_name + ") is offering you their leash.",
        "confirm_label", "Accept",
        "cancel_label",  "Decline"
    ]), NULL_KEY);
}

handleOfferResponse(string ctx) {
    if (ctx == "confirm") {
        sendAction("grab", [], OfferTarget);
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

handlePickerClick(string ctx) {
    if (ctx == "back") {
        scheduleStateQuery("main");
        return;
    }
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
    if (llSubStringIndex(ctx, "pick:") == 0) {
        integer idx = (integer)llGetSubString(ctx, 5, -1);
        integer li = idx * 2;
        if (li >= 0 && li < llGetListLength(Candidates)) {
            key selected = llList2Key(Candidates, li + 1);
            if ((MenuContext == "pass" || MenuContext == "offer") && is_blacklisted(selected)) {
                llRegionSayTo(CurrentUser, 0, "Cannot " + MenuContext + " leash: that person is blacklisted.");
                cleanupSession();
                return;
            }
            sendAction(MenuContext, ["target", (string)selected], CurrentUser);
            cleanupSession();
            return;
        }
        llRegionSayTo(CurrentUser, 0, "Invalid selection.");
        cleanupSession();
    }
}

/* -------------------- ACTIONS -------------------- */
giveHolderObject() {
    // Policy-driven: Get Holder must be in the allowed buttons list
    if (!btn_allowed("Get Holder")) {
        llRegionSayTo(CurrentUser, 0, "Access denied: Insufficient permissions to receive leash holder.");
        return;
    }

    // Tolerant inventory lookup: match case-insensitively and ignore
    // leading/trailing whitespace, so the holder item doesn't need an
    // exact "Leash holder" spelling in the collar's inventory.
    string wanted = "leash holder";
    string holder_name = "";
    integer count = llGetInventoryNumber(INVENTORY_OBJECT);
    integer i = 0;
    while (i < count) {
        string nm = llGetInventoryName(INVENTORY_OBJECT, i);
        if (llToLower(llStringTrim(nm, STRING_TRIM)) == wanted) {
            holder_name = nm;
            i = count;
        }
        else {
            i = i + 1;
        }
    }

    if (holder_name == "") {
        llRegionSayTo(CurrentUser, 0, "Error: Leash holder object not found in collar inventory.");
        return;
    }
    llGiveInventory(CurrentUser, holder_name);
    llRegionSayTo(CurrentUser, 0, "Leash holder given.");
}

// The engine no longer re-verifies ACL; it trusts the policy-gated action and
// the acl level we already resolved for this user. (Engines process, plugins
// decide — same trust model as settings.delta over the intra-object bus.)
// Unified action sender: every leash command is plugin.leash.action + action +
// optional extra fields + acl, addressed to CurrentUser. `extra` is a flat
// [key,val,...] list spliced between action and acl. (queryState stays separate
// — it deliberately carries no acl.)
sendAction(string action, list extra, key recipient) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT,
        ["type", "plugin.leash.action", "action", action] + extra + ["acl", (string)UserAcl]),
        recipient);
}

sendLeashAction(string action) {
    sendAction(action, [], CurrentUser);
}

// Enhanced TP/sit restrictions are applied LOCALLY (no leash-engine round-trip),
// but they FOLLOW THE LEASH: active only while EnhancedMode is on AND the wearer
// is currently leashed. So they clear automatically when the leash unclips
// (Leashed -> FALSE) and re-arm on the next clip. Idempotent via EnhancedApplied
// to avoid redundant RLV chatter. Call this after any change to EnhancedMode or
// Leashed. ACL >= 3 is enforced at the toggle call site (button only shown to 3+).
sync_enhanced() {
    integer want = (EnhancedMode && Leashed);
    if (want && !EnhancedApplied) {
        llOwnerSay("@sittp=n,tploc=n,tplm=n,tplure=n");
        EnhancedApplied = TRUE;
    }
    else if (!want && EnhancedApplied) {
        llOwnerSay("@sittp=y,tploc=y,tplm=y,tplure=y");
        EnhancedApplied = FALSE;
    }
}

// Persist the enhanced INTENT through kmod_settings' single-writer CSV protocol.
// leash.enhanced is whitelisted in MANAGED_SETTINGS_KEYS and is also settable
// from the settings notecard as "leash.enhanced = 0|1". kmod_settings writes LSD
// and echoes settings.sync; our handler re-reads it (a no-op since EnhancedMode
// already matches).
persist_enhanced() {
    llMessageLinked(LINK_SET, SETTINGS_BUS,
        "settings.delta:leash.enhanced:" + (string)EnhancedMode, NULL_KEY);
}

// v1.2 seed-default: write this plugin's default into LSD only if absent
// (no broadcast). Makes LSD the complete, self-describing collar state and
// self-heals if the notecard manifest later drops the key. See kmod_settings
// settings.seed.
seed_def(string lsd_key, string value) {
    if (llLinksetDataRead(lsd_key) == "")
        llMessageLinked(LINK_SET, SETTINGS_BUS, "settings.seed:" + lsd_key + ":" + value, NULL_KEY);
}

// Pull the persisted intent from LSD into EnhancedMode (absent -> ON: restrain
// by default), then re-sync the restriction against the current leash state. LSD
// survives a script reset, so this restores the toggle across reset-while-worn;
// on a cold boot the notecard value arrives via the settings.sync that fires
// once kmod_settings finishes parsing.
load_enhanced() {
    seed_def("leash.enhanced", "1");
    string v = llLinksetDataRead("leash.enhanced");
    EnhancedMode = TRUE;   // default ON when the key is absent — restrain by default
    if (v != "") EnhancedMode = (integer)v;
    sync_enhanced();
}

sendLeashActionWithTarget(string action, key target) {
    sendAction(action, ["target", (string)target], CurrentUser);
}

sendSetLength(integer length) {
    sendAction("set_length", ["length", (string)length], CurrentUser);
}

/* -------------------- CHAT SUBCOMMAND HANDLING -------------------- */

// kmod_leash does server-side ACL verification on each action, so we just
// translate chat verbs into plugin.leash.action messages.
handle_subpath(key user, integer acl_level, string subpath) {
    CurrentUser = user;
    UserAcl = acl_level;

    list tokens = llParseString2List(subpath, ["."], []);
    integer n = llGetListLength(tokens);
    if (n == 0) return;
    string action = llList2String(tokens, 0);

    if (action == "clip") {
        sendLeashAction("grab");
        return;
    }
    if (action == "unclip") {
        sendLeashAction("release");
        return;
    }
    if (action == "turn") {
        sendLeashAction("toggle_turn");
        return;
    }
    if (action == "yank") {
        sendLeashAction("yank");
        return;
    }
    if (action == "length") {
        if (n < 2) {
            llRegionSayTo(user, 0, "Usage: leash length <meters>");
            return;
        }
        integer len = (integer)llList2String(tokens, 1);
        if (len < 1) {
            llRegionSayTo(user, 0, "Length must be at least 1 meter.");
            return;
        }
        sendSetLength(len);
        return;
    }
    if (action == "pass") {
        if (n < 2) {
            llRegionSayTo(user, 0, "Usage: leash pass <username>");
            return;
        }
        string username = llDumpList2String(llList2List(tokens, 1, -1), ".");
        key target = llName2Key(username);
        if (target == NULL_KEY) {
            llRegionSayTo(user, 0, "User not found in sim: " + username);
            return;
        }
        sendLeashActionWithTarget("pass", target);
        return;
    }
    // coffle/post delegate to sub-plugins (same flow as the dialog
    // buttons). CurrentUser is already set above so the resulting menu
    // goes to the chat user.
    if (action == "coffle") { startPicker("coffle"); return; }
    if (action == "post")   { startPicker("post"); return; }
    llRegionSayTo(user, 0, "Unknown leash subcommand: " + action);
}

/* -------------------- BUTTON HANDLERS -------------------- */
// `ctx` is the routing context resolved by kmod_dialogs (button_data
// context field, or "" when the lookup misses). The raw button label
// is unused here now — picker flows that matched on label moved to the
// sub-plugins.
handleButtonClick(string ctx) {

    if (MenuContext == "main") {
        if (ctx == "clip") {
            sendLeashAction("grab");
            cleanupSession();
        }
        else if (ctx == "unclip") {
            sendLeashAction("release");
            cleanupSession();
        }
        // Pass / Offer / Coffle / Post enter the in-line picker (avatar source
        // for pass/offer/coffle, object scan for post); it re-shows the main
        // menu on Back.
        else if (ctx == "pass" || ctx == "offer" || ctx == "coffle" || ctx == "post") {
            startPicker(ctx);
        }
        else if (ctx == "yank") {
            sendLeashAction("yank");
            cleanupSession();
        }
        else if (ctx == "get_holder") {
            giveHolderObject();
            cleanupSession();
        }
        else if (ctx == "settings") {
            showSettingsMenu();
        }
        else if (ctx == "back") {
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "ui.menu.return",
                "user", (string)CurrentUser
            ]), NULL_KEY);
            cleanupSession();
        }
        else {
            // Unknown (e.g. the inert spacer) — redraw.
            showMainMenu();
        }
    }
    else if (MenuContext == "settings") {
        if (ctx == "length") {
            showLengthMenu();
        }
        else if (ctx == "toggle_turn") {
            sendLeashAction("toggle_turn");
            scheduleStateQuery("settings");
        }
        else if (ctx == "toggle_enhanced") {
            // Local toggle — flip intent, apply against leash state, persist. No engine.
            if (UserAcl >= 3) {
                EnhancedMode = !EnhancedMode;
                sync_enhanced();
                persist_enhanced();
            }
            showSettingsMenu();
        }
        else if (ctx == "texture") {
            showTextureMenu();
        }
        else if (ctx == "back") {
            showMainMenu();
        }
        else {
            // Inert << >> — redraw.
            showSettingsMenu();
        }
    }
    else if (MenuContext == "texture") {
        if (ctx == "back") {
            showSettingsMenu();
        }
        else if (ctx == "chain" || ctx == "silk" || ctx == "invisible") {
            sendAction("set_texture", ["texture", ctx], CurrentUser);
            scheduleStateQuery("settings");
        }
        else {
            // Inert << >> — redraw.
            showTextureMenu();
        }
    }
    else if (MenuContext == "length") {
        if (ctx == "back") {
            showSettingsMenu();
        }
        else if (ctx == "len_dec") {
            sendSetLength(LeashLength - 1);
            scheduleStateQuery("length");
        }
        else if (ctx == "len_inc") {
            sendSetLength(LeashLength + 1);
            scheduleStateQuery("length");
        }
        else {
            integer sel_length = (integer)ctx;
            if (sel_length >= 1 && sel_length <= 20) {
                sendSetLength(sel_length);
                scheduleStateQuery("settings");
            }
            else {
                // Inert << >> (single page) or the blank spacer — redraw.
                showLengthMenu();
            }
        }
    }
    // The picker MenuContexts (pass/offer/coffle/post) are dispatched to
    // handlePickerClick by the dialog-response router, not here.
}

/* -------------------- NAVIGATION -------------------- */
cleanupSession() {
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
    MenuContext = "";
    Candidates = [];
    PickPage = 0;
}

queryState() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.action",
        "action", "query_state"
    ]), NULL_KEY);
}

// Query leash state and show the given menu when the reply lands. The query is
// sent immediately — link messages are ordered and near-instant, so any action
// just sent is processed before this query, and the reply (plugin.leash.state)
// drives the menu via PendingQueryContext. The old 0.5s timer wait here was
// orphaned cruft from a former blocking-llSleep pattern and made the UI sluggish.
scheduleStateQuery(string next_menu_context) {
    PendingQueryContext = next_menu_context;
    queryState();
}

/* -------------------- EVENT HANDLERS -------------------- */
default
{
    state_entry() {

        cleanupSession();
        register_self();
        // Restore the persisted enhanced intent from LSD (survives script reset)
        // and sync it. EnhancedApplied defaults TRUE so this first sync issues a
        // clean baseline @...=y when not (yet) leashed, wiping anything a
        // reset-while-worn left behind; queryState() then re-arms it if leashed.
        load_enhanced();
        queryState();
    }
    
    on_rez(integer start_param) {
        llResetScript();
    }
    
    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num == KERNEL_LIFECYCLE) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "kernel.register.refresh") {
                register_self();
                IsRegistered = TRUE;
                return;
            }
            if (msg_type == "kernel.ping") {
                send_pong();
                return;
            }
            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) return;
                }
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
                llResetScript();
            }
            return;
        }

        if (num == SETTINGS_BUS) {
            // settings.sync fires after notecard load and after any settings.delta
            // write (including our own). Re-read leash.enhanced and re-sync — the
            // notecard ("leash.enhanced = 0|1") and persisted toggle both arrive here.
            if (llJsonGetValue(msg, ["type"]) == "settings.sync") load_enhanced();
            return;
        }

        if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            // Emergency leash release (SOS Unleash). The engine also handles this
            // and will broadcast Leashed=FALSE, but an emergency escape must not
            // depend on that round-trip completing — clear the enhanced restriction
            // immediately and directly. Guarded to the wearer like the engine's own
            // handler. EnhancedMode (persisted intent) is preserved; re-leashing
            // re-arms it.
            if (msg_type == "sos.leash.release") {
                if (id == llGetOwner()) {
                    Leashed = FALSE;
                    sync_enhanced();
                }
                return;
            }

            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                integer start_acl = (integer)llJsonGetValue(msg, ["acl"]);

                string subpath = "";
                string sp = llJsonGetValue(msg, ["subpath"]);
                if (sp != JSON_INVALID) subpath = sp;

                if (subpath != "") {
                    handle_subpath(id, start_acl, subpath);
                    return;
                }

                CurrentUser = id;
                UserAcl = start_acl;
                scheduleStateQuery("main");
                return;
            }

            if (msg_type == "plugin.leash.state") {
                string tmp = llJsonGetValue(msg, ["leashed"]);
                if (tmp != JSON_INVALID) Leashed = (integer)tmp;
                tmp = llJsonGetValue(msg, ["leasher"]);
                if (tmp != JSON_INVALID) Leasher = (key)tmp;
                tmp = llJsonGetValue(msg, ["length"]);
                if (tmp != JSON_INVALID) LeashLength = (integer)tmp;
                tmp = llJsonGetValue(msg, ["turnto"]);
                if (tmp != JSON_INVALID) TurnToFace = (integer)tmp;
                tmp = llJsonGetValue(msg, ["texture"]);
                if (tmp != JSON_INVALID) LeashTexture = tmp;
                // EnhancedMode is owned locally (not read from the broadcast),
                // but the restrictions follow the leash: re-sync against the
                // just-updated Leashed so an unclip clears them and a clip
                // re-arms them.
                sync_enhanced();
                tmp = llJsonGetValue(msg, ["mode"]);
                if (tmp != JSON_INVALID) LeashMode = (integer)tmp;
                tmp = llJsonGetValue(msg, ["target"]);
                if (tmp != JSON_INVALID) LeashTarget = (key)tmp;

                // If we were waiting for state update, show the pending menu
                if (PendingQueryContext != "") {
                    string menu_to_show = PendingQueryContext;
                    PendingQueryContext = "";  // Clear before showing menu

                    if (menu_to_show == "settings") {
                        showSettingsMenu();
                    }
                    else if (menu_to_show == "length") {
                        showLengthMenu();
                    }
                    else if (menu_to_show == "main") {
                        showMainMenu();
                    }
                }
                return;
            }

            if (msg_type == "plugin.leash.offer.pending") {
                if (llJsonGetValue(msg, ["target"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["originator"]) == JSON_INVALID) return;
                showOfferDialog((key)llJsonGetValue(msg, ["target"]),
                                (key)llJsonGetValue(msg, ["originator"]));
                return;
            }
        }

        if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.dialog.response") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID || llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                string response_session = llJsonGetValue(msg, ["session_id"]);
                string ctx = llJsonGetValue(msg, ["context"]);

                if (response_session == OfferDialogSession) {
                    handleOfferResponse(ctx);
                    return;
                }
                if (response_session != SessionId) return;  // not ours

                // Service nav carries nav:* contexts; normalize them to this
                // plugin's internal nav vocabulary (back/prev/next), shared by
                // picker + menus. On single-page menus << >> are inert
                // (handleButtonClick redraws), except the length menu where
                // they mean -1m / +1m.
                if      (ctx == "nav:back") ctx = "back";
                else if (ctx == "nav:prev") ctx = "prev";
                else if (ctx == "nav:next") ctx = "next";
                if (MenuContext == "pass" || MenuContext == "offer"
                    || MenuContext == "coffle" || MenuContext == "post") {
                    handlePickerClick(ctx);
                    return;
                }
                handleButtonClick(ctx);
                return;
            }

            if (msg_type == "ui.dialog.timeout") {
                string timeout_session = llJsonGetValue(msg, ["session_id"]);
                if (timeout_session == JSON_INVALID) return;
                if (timeout_session == OfferDialogSession) {
                    if (OfferOriginator != NULL_KEY) {
                        llRegionSayTo(OfferOriginator, 0,
                            "Leash offer to " + llKey2Name(OfferTarget) + " timed out.");
                    }
                    OfferDialogSession = "";
                    OfferTarget = NULL_KEY;
                    OfferOriginator = NULL_KEY;
                    return;
                }
                if (timeout_session != SessionId) return;
                cleanupSession();
                return;
            }

            // Close (from a menu.fixed Close button, via kmod_dialogs).
            if (msg_type == "ui.dialog.close") {
                if (llJsonGetValue(msg, ["session_id"]) == SessionId) cleanupSession();
                return;
            }
            return;
        }
    }

    // OBJECT mode only (post). PASSIVE|SCRIPTED already excludes avatars; the
    // llGetAgentSize guard drops any stray agent.
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
                && llGetAgentSize(detected) == ZERO_VECTOR) {
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

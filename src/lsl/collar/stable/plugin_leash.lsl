/*--------------------
PLUGIN: plugin_leash.lsl
VERSION: 1.10
REVISION: 26
PURPOSE: Top-level UI shell — main menu, Settings (length/turn/texture),
         Get Holder, simple direct actions (Unclip/Yank/Take). Delegates
         multi-step flows (Pass/Offer/Coffle, Post) to hidden sub-plugins.
ARCHITECTURE: Renderer for the leash module. Picker flows now live in
              two hidden sub-plugins: plugin_leash_avatar (avatar picker
              for Pass/Offer/Coffle, plus offer-reception dialog) and
              plugin_leash_object (object picker for Post). This plugin
              delegates via ui.menu.start with the sub-plugin's context +
              subpath; the sub-plugin returns to us via ui.menu.start
              with our context.
CHANGES:
- v1.10 rev 26: Dormancy guard widened to the renamed role-split markers ("D/s Collar updater v1.1" / "(updating)" / "(installing)").
- v1.10 rev 25: Enhanced mode is now applied LOCALLY via llOwnerSay (no kmod_leash_engine round-trip; the engine path needed rev 34's toggle_enhanced handler and never fired). The restrictions FOLLOW THE LEASH, matching the original engine semantics: sync_enhanced() issues @sittp,tploc,tplm,tplure=n only while EnhancedMode is on AND the wearer is leashed, and =y to clear — so they lift automatically when the leash unclips and re-arm on the next clip. EnhancedMode (intent) is owned in-script; the toggle (ACL 3+) flips it and calls sync_enhanced(); the plugin.leash.state handler also calls sync_enhanced() on every Leashed change. SOS emergency Unleash (sos.leash.release on UI_BUS) is caught directly here and clears the restriction immediately — not relying on the engine's Leashed=FALSE broadcast round-trip — guarded to the wearer (id == owner) like the engine's own handler. Idempotent via EnhancedApplied, which defaults TRUE so the first sync at boot (state_entry calls load_enhanced()) forces a clean clear — enforcing the invariant "not leashed => no leash RLV restrictions" even after a bare reset-while-worn that would otherwise strand a stale @sittp. PERSISTED + ON BY DEFAULT: the intent survives via kmod_settings (settings.delta:leash.enhanced) — persist_enhanced() writes on toggle, load_enhanced() restores from LSD at state_entry (LSD survives script reset) and on every settings.sync, defaulting ON when the key is absent (a leash should restrain; notecard "leash.enhanced = 0" or the ACL3+ toggle disables it). Also settable from the settings notecard as "leash.enhanced = 0|1" (kmod_settings rev 21 whitelists the key). Toggle button "Enhance: Y" / "Enhance: N" (was "Enhanced: On/Off"); body "Enhanced mode: Enabled|Disabled" (was "Enhanced: 0|1"). Texture routing (chain/silk/invisible) unchanged, working via button_data context. Turn line relabeled "Turn to face: 0|1" -> "Turn to leasher: Enabled|Disabled" (button stays "Turn: On/Off"); Turn toggle still routes to the engine, which owns the @setrot follow-rotation.
- v1.10 rev 24: Settings menu surfaces Enhanced (ACL 3+ only) and the texture sub-menu gains Invisible. Enhanced button reflects the engine's persisted EnhancedMode (synced via new "enhanced" field on plugin.leash.state); click sends toggle_enhanced through the standard plugin.leash.action path. Texture menu now offers Chain / Silk / Invisible; settings body labels the current selection accordingly.
- v1.10 rev 23: Expose Coffle to ACL 1 (public). Previous policy listed
  Coffle for ACL 3/4/5 only; public touchers can now coffle the wearer
  to a third-party avatar via the standard avatar picker. Engine-side
  POL_COFFLE gate at kmod_leash_engine.lsl:594 already reads from this
  LSD policy, so no engine change is required.
- v1.10 rev 22: All four menus (main / settings / texture / length) now use the project's bottom-nav + top-to-bottom-L-R content convention (canonical: plugin_animate, plugin_leash_object). Length menu was rendering reversed (10/15/20 on top, 1/3/5 below); now reads 1/3/5/10/15/20 top-to-bottom. New nav-count-agnostic reorder_item_buttons helper handles both Back-only menus and the 3-button (<< >> Back) length menu without filler padding — items consume all qualifying slots, no " " survives in the final array.
- v1.10 rev 21: Add "leash yank" chat subcommand. Was missing from handle_subpath since rev 8 (chat support introduced clip/unclip/turn/length/pass but not yank). Engine-side guards (leasher-only, 5s cooldown) apply unchanged — the chat path just dispatches plugin.leash.action action=yank with id=user, same shape as the menu Yank button.
- v1.10 rev 20: Destroy dialog after one-shot action dispatch (Yank, Get Holder) instead of re-showing main menu — matches the project's "process finished → dialog gone" convention. Clip/Unclip already followed this; Yank and Get Holder were the outliers.
- v1.10 rev 19: Architectural split after recurring Mono stack-heap collisions in rev 18 (91.5% / 64KB even after consolidation). Pass/Offer/Coffle avatar picker + offer-reception dialog moved to new plugin_leash_avatar (context ui.core.leash.avatar). Post object picker + sensor scanning moved to new plugin_leash_object (context ui.core.leash.object). Both sub-plugins are hidden from kmod_ui's top menu (no plugin.reg.* write). plugin_leash now: main menu + Settings (length/turn/texture) + Get Holder + state sync + chat dispatch root + direct simple actions (Unclip/Yank/Take). Removed from plugin_leash: showPassMenu, buildAvatarMenu, startSensorScan, displayObjectMenu, showOfferDialog, handleOfferResponse, reorder_item_buttons, sensor/no_sensor events, plugin.leash.offer.pending handler, MenuContext branches for pass/coffle/post, OfferDialog* / SensorMode / SensorCandidates / SensorPage / IsOfferMode / LeashMode / LeashTarget globals. New delegateTo(sub_context, subpath) helper sends ui.menu.start to the appropriate sub-plugin and closes our current session.
- v1.10 rev 18: Fix O(n²) heap pressure in SensorCandidates construction. Both sites (buildAvatarMenu, sensor event handler) now collect into a local list and assign to the global once after the loop. The local has refcount 1 inside the loop, so Mono can grow it in-place ~O(1) per step; appending directly to a global is O(n) per step because the global slot holds an extra reference. Worst case (96m sensor with hundreds of returns) drops from ~O(N²) heap churn to ~O(N).
- v1.10 rev 17: Bytecode reduction pass after Mono stack-heap collision in rev 16 (~91.5%). (1) Consolidated showCoffleMenu + showPostMenu into one startSensorScan(mode, type_mask) helper — same shape, only the type bitmask differed. (2) Inlined three single-use helpers: sendSetTexture, cleanupOfferDialog, returnToRoot. (3) Compacted the 7-field plugin.leash.state field-read block by dropping unneeded braces on single-statement if bodies. No behavior change. Aimed to give plugin_leash runtime headroom against heap pressure during link_message dispatch.
- v1.10 rev 16: Add Texture sub-menu under Settings — wearer picks Chain or Silk for the leash particle stream. New texture field in plugin.leash.state syncs LeashTexture from kmod_leash; Settings dialog body now displays the current selection; texture menu sends set_texture action with the chosen style. Returns to Settings menu after pick so the new selection is visible.
- v1.10 rev 15: Post sensor mask drops ACTIVE (was PASSIVE|ACTIVE|SCRIPTED).
  ACTIVE matches avatars in llSensor, so the post picker was surfacing
  bystanders alongside hitching posts. Posts are stationary, so
  PASSIVE|SCRIPTED is sufficient.
- v1.10 rev 14: Pass/Offer selection now matches the raw clicked button
  label (the listen message) against SensorCandidates instead of parsing
  "sel:<name>" out of the routing context. kmod_dialogs' storage_map
  context lookup was returning "" for avatar-name buttons, so the
  "sel:" branch never fired — click did nothing. Using the button
  label directly bypasses that lookup. handleButtonClick now takes
  (ctx, btn); ctx still routes nav/main/settings/length, btn handles
  name-based selection.
- v1.10 rev 13: Sort sensor-driven candidate lists by name, and reorder
  the resulting buttons so they display top-to-bottom-left-to-right.
  Pass/Offer (buildAvatarMenu) now collects all nearby avatars, sorts
  alphabetically via llListSortStrided(SensorCandidates, 2, 0, TRUE),
  then caps at 9. Coffle/Post (sensor event) sorts the same way before
  pagination. A new reorder_item_buttons helper maps item buttons into
  llDialog's bottom-left-to-top-right grid so the visual order matches
  the sorted body text — this plugin talks to kmod_dialogs directly and
  bypasses kmod_menu's reorder, so it has to do the mapping itself.
- v1.10 rev 12: write_plugin_reg guards idempotent writes (read-before-
  write). Same-value re-registrations on state_entry and
  kernel.register.refresh no longer fire linkset_data, so kmod_ui's
  debounced rebuild + session invalidation stops triggering on
  register.refresh cascades — wearer's open menu survives the event.
- v1.10 rev 11: Add dormancy guard in state_entry — script parks itself
  if the prim's object description is "COLLAR_UPDATER" so it stays dormant
  when staged in an updater installer prim.
- v1.10 rev 10: Self-declare menu presence via LSD (plugin.reg.<ctx>).
  Label updates write the same LSD key directly; ui.label.update link_messages
  are gone. Reset handlers delete plugin.reg.<ctx> and acl.policycontext:<ctx>
  before llResetScript so kmod_ui drops the button immediately.
- v1.10 rev 9: Chat subcommands for coffle and post. Both reuse the
  existing menu flow (showCoffleMenu / showPostMenu), so "leash coffle"
  and "leash post" each trigger a sensor scan and return a dialog to
  pick from — same UX as the menu buttons, just reachable from chat.
- v1.10 rev 8: Chat command support (Phase 3). Registers "leash" alias.
  "<prefix> leash" opens menu; subcommands: clip, unclip, turn,
  length <m>, pass <username>. Username resolved via llName2Key
  (avatar must be in-sim). kmod_leash does server-side ACL enforcement
  on the resulting plugin.leash.action, so no duplicate gating here.
- v1.10 rev 7: Wire-type rename (Phase 2). kernel.register→kernel.register.declare,
  kernel.registernow→kernel.register.refresh, kernel.reset→kernel.reset.soft,
  kernel.resetall→kernel.reset.factory, plugin.leash.offerpending→
  plugin.leash.offer.pending.
- v1.10 rev 6: Guard ui.menu.start against raw kmod_chat broadcasts (no acl
  field). Fixes duplicate dialogs when commands are typed in chat.
- v1.10 rev 5: Grant Unclip to ACL 1 (public) policy so a public user who
  holds the leash can release it. The existing in-code guard still
  restricts the button to the current leasher at public level. Also
  make giveHolderObject tolerant of case and whitespace variations on
  the "Leash holder" inventory item name.
- v1.10 rev 4: Namespace internal message type strings (kernel.*, ui.*, plugin.*).
- v1.10 rev 3: Coffle now scans for nearby AVATARS instead of scripted
  objects. Was scanning SCRIPTED objects, which surfaced random in-world
  scripted props instead of avatars wearing collars. Switched the
  llSensor type to AGENT and updated the empty-result message to say
  "avatars". Post still uses object detection.
- v1.10 rev 2: Honor soft_reset / soft_reset_all from KERNEL_LIFECYCLE so
  factory reset clears cached leash state.
- v1.10 rev 1: Migrate dialog buttons to button_data format with context-based routing.
- v1.10 rev 0: Self-declares button visibility policy to LSD on registration.
  Replaces hardcoded ALLOWED_ACL_* lists and inAllowedList() with policy reads.
  Button list built from get_policy_buttons() + state-dependent logic.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.leash";
string PLUGIN_LABEL = "Leash";

/* -------------------- CONFIGURATION -------------------- */
float STATE_QUERY_DELAY = 0.5;  // 500ms delay for non-blocking state queries

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

// Session/menu state. Pass/Offer/Coffle picker + offer-reception dialog
// were moved to plugin_leash_avatar; Post picker moved to plugin_leash_object.
// What stays here is the top-level menu + Settings (length/turn/texture)
// + Get Holder, plus direct simple actions (Unclip / Yank).
key CurrentUser = NULL_KEY;
integer UserAcl = -999;
list gPolicyButtons = [];  // Cached policy buttons for current user's ACL
string SessionId = "";
string MenuContext = "";

// State query tracking (event-driven, no blocking llSleep)
integer PendingStateQuery = FALSE;
string PendingQueryContext = "";  // Which menu to show after query completes

// Registration state (SYN/ACK pattern for active discovery)
integer IsRegistered = FALSE;

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
showMenu(string context, string title, string body, list button_data) {
    SessionId = generate_session_id();
    MenuContext = context;

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SessionId,
        "user", (string)CurrentUser,
        "title", title,
        "body", body,
        "button_data", llList2Json(JSON_ARRAY, button_data),
        "timeout", 60
    ]), NULL_KEY);
}

// Lays out a dialog in the project's bottom-nav / top-to-bottom-L-R
// content convention (canonical: plugin_animate, plugin_leash_object).
// Caller provides 1-3 nav buttons (placed at slots 0..nav_count-1) and
// 0..N content items, which fill the remaining slots in visual
// top-to-bottom-L-R reading order. No filler is left in the output —
// items must fully consume the qualifying slots (true for total <= 12
// minus zero-padding gaps, which holds for all plugin_leash menus).
list reorder_item_buttons(list nav_buttons, list item_buttons) {
    integer nav_count  = llGetListLength(nav_buttons);
    integer item_count = llGetListLength(item_buttons);
    integer total      = nav_count + item_count;

    // llDialog slot indices walked in visual top-to-bottom, L-R order.
    // Filtered to slots that fit within `total` and aren't reserved
    // for nav (slots < nav_count).
    list reading_order = [9, 10, 11, 6, 7, 8, 3, 4, 5, 0, 1, 2];
    list slots = [];
    integer ri = 0;
    while (ri < 12) {
        integer rs = llList2Integer(reading_order, ri);
        if (rs < total && rs >= nav_count) slots += [rs];
        ri++;
    }

    list final_buttons = nav_buttons;
    integer p = 0;
    while (p < item_count) { final_buttons += [btn(" ", " ")]; p++; }

    integer i = 0;
    while (i < item_count) {
        integer slot = llList2Integer(slots, i);
        final_buttons = llListReplaceList(final_buttons,
            [llList2String(item_buttons, i)], slot, slot);
        i++;
    }
    return final_buttons;
}

/* -------------------- PLUGIN REGISTRATION -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
write_plugin_reg(string label) {
    string k = "plugin.reg." + PLUGIN_CONTEXT;
    string v = llList2Json(JSON_OBJECT, [
        "label",  label,
        "script", llGetScriptName()
    ]);
    // Skip the write (and its linkset_data event) when the stored value
    // is already what we would write. Idempotent re-registrations on
    // state_entry or kernel.register.refresh then no longer trigger
    // kmod_ui's debounced rebuild + session invalidation.
    if (llLinksetDataRead(k) == v) return;
    llLinksetDataWrite(k, v);
}

register_self() {
    // Write button visibility policy to LSD (default-deny per ACL level).
    // ACL 1 (public) may Unclip, but the in-code guard at showMainMenu
    // limits the button to cases where CurrentUser == Leasher — so only
    // a public user who holds the leash themselves can release it.
    llLinksetDataWrite("acl.policycontext:" + PLUGIN_CONTEXT, llList2Json(JSON_OBJECT, [
        "1", "Clip,Unclip,Coffle,Post,Get Holder,Settings",
        "2", "Offer",
        "3", "Clip,Unclip,Pass,Yank,Take,Coffle,Post,Get Holder,Settings",
        "4", "Clip,Unclip,Pass,Yank,Coffle,Post,Get Holder,Settings",
        "5", "Clip,Unclip,Pass,Yank,Take,Coffle,Post,Get Holder,Settings"
    ]));

    // Self-declared menu presence for kmod_ui.
    write_plugin_reg(PLUGIN_LABEL);

    // Register with kernel (for ping/pong health tracking and alias table).
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName()
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

    list nav_buttons  = [btn("Back", "back")];
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

    list button_data = reorder_item_buttons(nav_buttons, item_buttons);
    showMenu("main", "Leash", body, button_data);
}

showSettingsMenu() {
    list nav_buttons  = [btn("Back", "back")];
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
    list button_data = reorder_item_buttons(nav_buttons, item_buttons);
    showMenu("settings", "Settings", body, button_data);
}

showTextureMenu() {
    string current = "Chain";
    if      (LeashTexture == "silk")      current = "Silk";
    else if (LeashTexture == "invisible") current = "Invisible";

    list nav_buttons  = [btn("Back", "back")];
    list item_buttons = [btn("Chain", "chain"), btn("Silk", "silk"), btn("Invisible", "invisible")];
    list button_data  = reorder_item_buttons(nav_buttons, item_buttons);
    showMenu("texture", "Texture",
             "Select leash texture\nCurrent: " + current, button_data);
}

showLengthMenu() {
    list nav_buttons  = [btn("<<", "prev"), btn(">>", "next"), btn("Back", "back")];
    list item_buttons = [
        btn("1m",  "1"),  btn("3m",  "3"),  btn("5m",  "5"),
        btn("10m", "10"), btn("15m", "15"), btn("20m", "20")
    ];
    list button_data = reorder_item_buttons(nav_buttons, item_buttons);
    showMenu("length", "Length",
             "Select leash length\nCurrent: " + (string)LeashLength + "m",
             button_data);
}

// (Pass/Offer/Coffle avatar picker + offer-reception dialog moved to
//  plugin_leash_avatar; Post object picker + sensor handling moved to
//  plugin_leash_object. Main menu delegates to those via ui.menu.start
//  with the corresponding sub-plugin context.)

/* -------------------- SUB-PLUGIN DELEGATION -------------------- */
// Routes a click on the main menu to a hidden sub-plugin's flow via the
// standard ui.menu.start protocol with context + subpath. The sub-plugin
// opens its own dialog and returns to us by sending ui.menu.start back
// with our PLUGIN_CONTEXT. We also close our current session here so the
// sub-plugin owns the user's dialog channel until it returns.
delegateTo(string sub_context, string subpath) {
    if (SessionId != "") {
        llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.dialog.close",
            "session_id", SessionId
        ]), NULL_KEY);
        SessionId = "";
    }
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.start",
        "context", sub_context,
        "acl", (string)UserAcl,
        "subpath", subpath
    ]), CurrentUser);
    // We retain CurrentUser/UserAcl until the sub-plugin returns to us.
    MenuContext = "";
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

sendLeashAction(string action) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.action",
        "action", action
    ]), CurrentUser);
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

// Pull the persisted intent from LSD into EnhancedMode (absent -> off), then
// re-sync the restriction against the current leash state. LSD survives a script
// reset, so this restores the toggle across reset-while-worn; on a cold boot the
// notecard value arrives via the settings.sync that fires once kmod_settings
// finishes parsing.
load_enhanced() {
    string v = llLinksetDataRead("leash.enhanced");
    EnhancedMode = TRUE;   // default ON when the key is absent — restrain by default
    if (v != "") EnhancedMode = (integer)v;
    sync_enhanced();
}

sendLeashActionWithTarget(string action, key target) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.action",
        "action", action,
        "target", (string)target
    ]), CurrentUser);
}

sendSetLength(integer length) {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.action",
        "action", "set_length",
        "length", (string)length
    ]), CurrentUser);
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
    if (action == "coffle") { delegateTo("ui.core.leash.avatar", "coffle"); return; }
    if (action == "post")   { delegateTo("ui.core.leash.object", "post"); return; }
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
        // Pass / Offer / Coffle delegate to plugin_leash_avatar (avatar
        // picker). Post delegates to plugin_leash_object (object picker).
        // Each sub-plugin returns control via ui.menu.start with our
        // context, re-showing the main menu.
        else if (ctx == "pass")   delegateTo("ui.core.leash.avatar", "pass");
        else if (ctx == "offer")  delegateTo("ui.core.leash.avatar", "offer");
        else if (ctx == "coffle") delegateTo("ui.core.leash.avatar", "coffle");
        else if (ctx == "post")   delegateTo("ui.core.leash.object", "post");
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
    }
    else if (MenuContext == "texture") {
        if (ctx == "back") {
            showSettingsMenu();
        }
        else if (ctx == "chain" || ctx == "silk" || ctx == "invisible") {
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "plugin.leash.action",
                "action", "set_texture",
                "texture", ctx
            ]), CurrentUser);
            scheduleStateQuery("settings");
        }
    }
    else if (MenuContext == "length") {
        if (ctx == "back") {
            showSettingsMenu();
        }
        else if (ctx == "prev") {
            sendSetLength(LeashLength - 1);
            scheduleStateQuery("length");
        }
        else if (ctx == "next") {
            sendSetLength(LeashLength + 1);
            scheduleStateQuery("length");
        }
        else {
            integer sel_length = (integer)ctx;
            if (sel_length >= 1 && sel_length <= 20) {
                sendSetLength(sel_length);
                scheduleStateQuery("settings");
            }
        }
    }
    // Note: "pass" / "coffle" / "post" MenuContext branches are gone —
    // those flows now live in plugin_leash_avatar / plugin_leash_object.
    // The sub-plugin owns its own SessionId and dialog responses, then
    // returns to us via ui.menu.start with our context (re-entering
    // showMainMenu).
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
}

queryState() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "plugin.leash.action",
        "action", "query_state"
    ]), NULL_KEY);
}

// Schedule a state query after brief delay, then show specified menu
// Replaces blocking llSleep() + queryState() pattern
scheduleStateQuery(string next_menu_context) {
    PendingStateQuery = TRUE;
    PendingQueryContext = next_menu_context;
    llSetTimerEvent(STATE_QUERY_DELAY);
}

/* -------------------- EVENT HANDLERS -------------------- */
default
{
    state_entry() {
        if (llGetObjectDesc() == "D/s Collar updater v1.1" || llGetObjectDesc() == "(updating)" || llGetObjectDesc() == "(installing)") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

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

    timer() {
        // Handle pending state query (replaces blocking llSleep pattern)
        if (PendingStateQuery) {
            PendingStateQuery = FALSE;
            llSetTimerEvent(0.0);  // Stop timer
            queryState();
            // Menu will be shown when leash_state response arrives
        }
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
                llLinksetDataDelete("plugin.reg." + PLUGIN_CONTEXT);
                llLinksetDataDelete("acl.policycontext:" + PLUGIN_CONTEXT);
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

            // plugin.leash.offer.pending is handled by plugin_leash_avatar
            // (it shows the accept/decline dialog to the offer target).
        }

        if (num == DIALOG_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.dialog.response") {
                if (llJsonGetValue(msg, ["session_id"]) == JSON_INVALID || llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;

                string response_session = llJsonGetValue(msg, ["session_id"]);
                if (response_session != SessionId) return;  // not ours
                string ctx = llJsonGetValue(msg, ["context"]);
                handleButtonClick(ctx);
                return;
            }

            if (msg_type == "ui.dialog.timeout") {
                string timeout_session = llJsonGetValue(msg, ["session_id"]);
                if (timeout_session == JSON_INVALID) return;
                if (timeout_session != SessionId) return;
                cleanupSession();
                return;
            }
            return;
        }
    }

    // sensor() / no_sensor() moved to plugin_leash_object (the only
    // consumer was the coffle/post object scan, both now in sub-plugins).
}

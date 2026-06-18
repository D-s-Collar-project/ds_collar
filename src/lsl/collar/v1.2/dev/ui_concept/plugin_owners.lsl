/*--------------------
PLUGIN: plugin_owners.lsl
VERSION: 1.2
REVISION: 13
PURPOSE: Owner, trustee, and honorific management workflows
ARCHITECTURE: Consolidated message bus lanes, LSD policy-driven button visibility
CHANGES:
- v1.2 rev 13 (sandbox): unified the release + runaway EXIT flows into one spine keyed on OwnerConsents (1=release/owner-authorized, 0=runaway/owner-bypassed). release_owner+release_wearer+runaway (3 branches) → exit_owner_auth + exit_wearer (2): the bit gates the owner-auth step (release only) and the terminal action — release → clear_owner (→ kmod_settings soft reboot, rev 8); runaway → trigger_runaway (factory reset). All wording, notices, targets, and cancel behavior preserved; chat /access rem owner enters the same spine.
- v1.2 rev 12 (sandbox): unified owner/transfer/trustee acquisition into one spine keyed on CandidateIsOwner (1=owner, 0=trustee) + has_owner() (owner = set vs transfer). Collapsed 10 handler branches (set/transfer/trustee × select/accept/hon + set_confirm) to 4 (acq_select/acq_accept/acq_hon/acq_confirm); sensor+no_sensor dispatch merged into finish_scan(); show_honorific picks the honorific pool by the bit. All consent semantics preserved (set wearer double-confirm, trustee already-check, transfer outgoing-owner notice, distinct messages, separate honorific pools). Measured -1523B (92.1% → 89.8% Mono). Validated in-world (add owner incl. double-confirm, release).
- v1.2 rev 11 (sandbox): security fix surfaced by the chat/menu gating trace — `/access rem owner` gated release on btn_allowed("Release") alone, so a trustee (policy lists Release at ACL 3) could release the owner, which the menu forbids via its is_owner gate. Added the matching !is_owner(CurrentUser) check: release is now owner-only on both paths. ACL 3's Release policy entry is dormant (is_owner enforces); trustees exit via Rem Trustee = resign.
- v1.2 rev 10 (sandbox): optimization pass (script at 92.6% Mono, bytecode-bound). Extracted start_scan() — the avatar-scan setup was inlined at 5 sites (menu add-owner/transfer/add-trustee + chat add-owner/add-trustee); 5 callers amortize LSL's ~128B/function overhead, net -360B measured. Fixed set_confirm: it emitted ui.menu.return AFTER cleanup() (which nulls CurrentUser), so the return carried NULL_KEY — now emits before cleanup, matching the Back path. Deliberately did NOT extract finish_scan/return_to_root/notify helpers: at 2 callers each the function overhead exceeds the dedup saving (would grow bytecode).
- v1.2 rev 9 (sandbox): menu-service migration stage 3 (final) — confirms now render via the service's MODAL mode (mode "modal") instead of a raw [Yes,No] ui.dialog.open. The service forces No (the safe choice) to slot 0 and still returns confirm/cancel, so every confirm branch is unchanged — render-only swap. All owners dialogs now flow through kmod_menu (pager main / UL scans + honorific / OL remove-trustee / modal confirms); DIALOG_BUS retained for response + close routing only.
- v1.2 rev 8 (sandbox): menu-service migration stage 2 — the pickers. Owner/transfer/trustee scans render as UL (mode "unordered", {label:name, context:uuid} items; the click returns the UUID, so long/colliding display names can't misselect); show_remove_trustee + honorific pickers render via the service too (remove = OL pick:<idx> into TrusteeKeys; honorific = UL flat, click returns the honorific). Replaced open_numbered_dialog with render_list_picker; added CurrentPage + << >> paging (picker_count/redraw_picker, LIST_PAGE_SIZE 9 must match kmod_menu), dropping the 11-item cap. Nav arrives as cmd=""/label=arrow (no cmd-fallback here) so paging matches on label; content picks match on cmd. Confirms still use the legacy Yes/No show_confirm — modal migration is stage 3.
- v1.2 rev 7 (sandbox): menu-service migration stage 1 — show_main now renders via the pager (ui.menu.render, has_nav=1) instead of a raw ui.dialog.open; dropped the hand-rolled Back button (the service supplies the << >> Back nav) and added an inert-<< >> redraw fallback in the main handler block. Sub-flows (scans/confirms) still use the legacy numbered_list path; migrated in later stages.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. See collar_kernel rev 6.
- v1.2 rev 1: Read the user-record roster (kmod_settings rev 2): owners/trustees enumerate from user.<uuid> records (rank-ordered; rank 0 = primary owner) instead of the retired access.owner-/trustee- parallel CSVs. Multi-owner remains the explicit notecard-only access.multiowner policy flag (commitment semantics). Names/honorifics come from the records. Mutation messages and all menu flows unchanged.
--------------------*/


/* -------------------- ISP CHANNELS -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.owner";
string PLUGIN_LABEL = "Owners";

/* -------------------- CONSTANTS -------------------- */
// LIST picker page size = 12 slots - 3 nav (<<,>>,Back), no fixed buttons.
// CROSS-MODULE: must match kmod_menu's list-mode content slot count (UL + OL).
integer LIST_PAGE_SIZE = 9;

/* -------------------- SETTINGS KEYS -------------------- */
// The roster lives in user.<uuid> = "<acl>,<rank>,<name>,<honorific>"
// records (kmod_settings rev 2): acl 5 owner / 3 trustee / -1 blacklist;
// rank orders owners (0 = primary). This plugin enumerates them read-only
// in apply_settings_sync; mutations go through the settings.owner.* /
// settings.trustee.* messages as before.
string KEY_RUNAWAY_ENABLED    = "access.enablerunaway";
// Multi-owner POLICY flag — notecard-only (commitment semantics: ownership
// restructuring is a deliberate card edit, not a menu click); gates all
// menu owner-editing. NOT derived from the owner count.
string KEY_MULTI_OWNER_MODE   = "access.multiowner";

/* -------------------- STATE -------------------- */
// Roster cache, rebuilt from user.* records on settings.sync. OwnerKeys is
// rank-ordered (index 0 = primary); trustee lists are parallel.
integer MultiOwnerMode;        // the access.multiowner policy flag
key OwnerKey;                  // primary owner (rank 0), NULL_KEY if none
string OwnerName;              // primary owner's record name
string OwnerHonorific;         // primary owner's honorific
list OwnerKeys;                // all owner uuids, rank-ordered
list TrusteeKeys;
list TrusteeHonorifics;
list TrusteeNames;
integer RunawayEnabled = TRUE;

key CurrentUser;
integer UserAcl = -999;
list gPolicyButtons = [];
string SessionId;
string MenuContext;
integer CurrentPage;  // page cursor for the LIST pickers (scans / remove)

key PendingCandidate;
string PendingHonorific;
integer CandidateIsOwner;  // acquisition role: 1 = owner (set/transfer), 0 = trustee
integer OwnerConsents;     // exit flow: 1 = release (owner-authorized), 0 = runaway
list CandidateKeys;

list NameCache;
key ActiveNameQuery;
key ActiveQueryTarget;

list OWNER_HONORIFICS = ["Master", "Mistress", "Daddy", "Mommy", "King", "Queen"];
list TRUSTEE_HONORIFICS = ["Sir", "Madame", "Milord", "Milady"];

/* -------------------- HELPERS -------------------- */

string btn(string label, string cmd) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", cmd]);
}

integer lsd_int(string lsd_key, integer fallback) {
    string v = llLinksetDataRead(lsd_key);
    if (v == "") return fallback;
    return (integer)v;
}

string gen_session() {
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

integer has_owner() {
    if (MultiOwnerMode) return (llGetListLength(OwnerKeys) > 0);
    return (OwnerKey != NULL_KEY);
}

key get_primary_owner() {
    if (MultiOwnerMode && llGetListLength(OwnerKeys) > 0) {
        return (key)llList2String(OwnerKeys, 0);
    }
    return OwnerKey;
}

integer is_owner(key k) {
    if (MultiOwnerMode) return (llListFindList(OwnerKeys, [(string)k]) != -1);
    return (k == OwnerKey);
}

/* -------------------- NAMES -------------------- */

cache_name(key k, string n) {
    if (k == NULL_KEY || n == "" || n == "???") return;
    integer idx = llListFindList(NameCache, [k]);
    if (idx != -1) {
        NameCache = llListReplaceList(NameCache, [n], idx + 1, idx + 1);
    }
    else {
        NameCache += [k, n];
        if (llGetListLength(NameCache) > 20) {
            NameCache = llDeleteSubList(NameCache, 0, 1);
        }
    }
}

string get_name(key k) {
    if (k == NULL_KEY) return "";
    integer idx = llListFindList(NameCache, [k]);
    if (idx != -1) return llList2String(NameCache, idx + 1);

    string n = llGetDisplayName(k);
    if (n != "" && n != "???") {
        cache_name(k, n);
        return n;
    }

    if (ActiveNameQuery == NULL_KEY) {
        ActiveNameQuery = llRequestDisplayName(k);
        ActiveQueryTarget = k;
    }

    return llKey2Name(k);
}

/* -------------------- LIFECYCLE -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "Access";
integer PLUGIN_ACL_MASK = 60;

register_self() {
    // Per-button visibility policy. Was written straight to LSD here; now
    // announced to the kernel, which is the SOLE writer of acl.policycontext
    // (and reg.<ctx>) — see collar_kernel rev 6.
    // Level 2 (owned wearer) is Runaway-only BY DESIGN: an owned wearer
    // cannot add owners — additional owners only enter via multi-owner
    // mode in the settings notecard. Level 4 (unowned wearer) keeps
    // Add Owner: that's how the first owner is set.
    string policy = llList2Json(JSON_OBJECT, [
        "2", "Runaway",
        "3", "Add Trustee,Rem Trustee,Release",
        "4", "Add Owner,Runaway,Add Trustee,Rem Trustee",
        "5", "Transfer,Release,Runaway: On,Runaway: Off,Add Trustee,Rem Trustee"
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
        "alias",   "access",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

send_pong() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]), NULL_KEY);
}

/* -------------------- SETTINGS -------------------- */

// v1.2 seed-default: write this plugin's default into LSD only if absent
// (no broadcast). Makes LSD the complete, self-describing collar state and
// self-heals if the notecard manifest later drops the key. See kmod_settings
// settings.seed.
seed_def(string lsd_key, string value) {
    if (llLinksetDataRead(lsd_key) == "")
        llMessageLinked(LINK_SET, SETTINGS_BUS, "settings.seed:" + lsd_key + ":" + value, NULL_KEY);
}

apply_settings_sync() {
    seed_def(KEY_RUNAWAY_ENABLED, "1");
    MultiOwnerMode = FALSE;
    OwnerKey = NULL_KEY;
    OwnerName = "";
    OwnerHonorific = "";
    OwnerKeys = [];
    TrusteeKeys = [];
    TrusteeHonorifics = [];
    TrusteeNames = [];

    // Enumerate user.* records into rank-ordered owner/trustee caches.
    // Strided [rank, uuid, name, honorific] accumulators, sorted on rank.
    list owners = [];
    list trustees = [];
    list ks = llLinksetDataFindKeys("^user\\.", 0, -1);
    integer i = 0;
    integer n = llGetListLength(ks);
    while (i < n) {
        string k = llList2String(ks, i);
        string rec = llLinksetDataRead(k);
        integer acl = (integer)rec;
        if (acl == 5 || acl == 3) {
            list f = llCSV2List(rec);
            list row = [(integer)llList2String(f, 1), llGetSubString(k, 5, -1),
                        llList2String(f, 2), llList2String(f, 3)];
            if (acl == 5) owners += row;
            else trustees += row;
        }
        i += 1;
    }
    if (llGetListLength(owners) > 4) owners = llListSortStrided(owners, 4, 0, TRUE);
    if (llGetListLength(trustees) > 4) trustees = llListSortStrided(trustees, 4, 0, TRUE);

    n = llGetListLength(owners);
    i = 0;
    while (i < n) {
        OwnerKeys += [llList2String(owners, i + 1)];
        i += 4;
    }
    if (n > 0) {
        OwnerKey = (key)llList2String(owners, 1);
        OwnerName = llList2String(owners, 2);
        OwnerHonorific = llList2String(owners, 3);
    }
    // Policy flag, not a derived count — see KEY_MULTI_OWNER_MODE.
    MultiOwnerMode = (integer)llLinksetDataRead(KEY_MULTI_OWNER_MODE);

    n = llGetListLength(trustees);
    i = 0;
    while (i < n) {
        TrusteeKeys       += [llList2String(trustees, i + 1)];
        TrusteeNames      += [llList2String(trustees, i + 2)];
        TrusteeHonorifics += [llList2String(trustees, i + 3)];
        i += 4;
    }

    RunawayEnabled = lsd_int(KEY_RUNAWAY_ENABLED, TRUE);
}


persist_owner(key owner, string hon) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.owner.set",
        "uuid", (string)owner,
        "honorific", hon
    ]), NULL_KEY);
}

add_trustee(key trustee, string hon) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.trustee.add",
        "uuid", (string)trustee,
        "honorific", hon
    ]), NULL_KEY);
}

remove_trustee(key trustee) {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.trustee.remove",
        "uuid", (string)trustee
    ]), NULL_KEY);
}

clear_owner() {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.owner.clear"
    ]), NULL_KEY);
}

trigger_runaway() {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.runaway"
    ]), NULL_KEY);
}

/* -------------------- MENUS -------------------- */

show_main() {
    SessionId = gen_session();
    MenuContext = "main";

    // Load policy-allowed buttons for this user's ACL level
    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, UserAcl);

    string body = "Owner Management\n\n";

    if (has_owner()) {
        if (MultiOwnerMode) {
            body += "Multi-owner mode (notecard managed)\n";
            body += "Owners: " + (string)llGetListLength(OwnerKeys) + "\n";
        }
        else {
            string display_name = OwnerName;
            if (display_name == "" || display_name == "(loading...)") {
                display_name = get_name(OwnerKey);
            }
            body += "Owner: " + display_name;
            if (OwnerHonorific != "") body += " (" + OwnerHonorific + ")";
        }
    }
    else {
        body += "Unowned";
    }

    body += "\nTrustees: " + (string)llGetListLength(TrusteeKeys);

    // Content buttons only (policy-gated); the menu service (pager) adds the
    // nav row (<< >> Back). has_nav=1 keeps the full nav row on this one page.
    list button_data = [];

    // In multi-owner mode, all owner editing is disabled (notecard managed).
    // Trustee management remains available.
    if (!MultiOwnerMode) {
        // Add Owner: policy allows + wearer + no current owner
        if (btn_allowed("Add Owner") && CurrentUser == llGetOwner() && !has_owner()) {
            button_data += [btn("Add Owner", "add_owner")];
        }

        // Runaway: policy allows + wearer + has owner + runaway enabled
        if (btn_allowed("Runaway") && CurrentUser == llGetOwner() && has_owner() && RunawayEnabled) {
            button_data += [btn("Runaway", "runaway")];
        }

        // Transfer: policy allows + is_owner
        if (btn_allowed("Transfer") && is_owner(CurrentUser)) {
            button_data += [btn("Transfer", "transfer")];
        }

        // Release: policy allows + is_owner
        if (btn_allowed("Release") && is_owner(CurrentUser)) {
            button_data += [btn("Release", "release")];
        }

        // Runaway toggle: policy allows + is_owner
        if (is_owner(CurrentUser)) {
            if (RunawayEnabled && btn_allowed("Runaway: On")) {
                button_data += [btn("Runaway: On", "runaway_toggle")];
            }
            else if (!RunawayEnabled && btn_allowed("Runaway: Off")) {
                button_data += [btn("Runaway: Off", "runaway_toggle")];
            }
        }
    }

    // Trustee management: available in both modes
    if (btn_allowed("Add Trustee")) button_data += [btn("Add Trustee", "add_trustee")];
    if (btn_allowed("Rem Trustee")) button_data += [btn("Rem Trustee", "rem_trustee")];

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "session_id", SessionId,
        "user",       (string)CurrentUser,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      PLUGIN_LABEL,
        "body",       body,
        "category",   PLUGIN_CATEGORY,
        "has_nav",    1,
        "buttons",    llList2Json(JSON_ARRAY, button_data),
        "page",       0
    ]), NULL_KEY);
}

// Unified LIST picker open (menu service). Sets SessionId + MenuContext and
// emits ui.menu.render in the given mode ("unordered" UL / "ordered" OL),
// paged off CurrentPage. Used by show_candidates (UL), show_honorific (UL),
// and show_remove_trustee (OL). Items are flat strings (label == context) or
// {label,context} objects ({name, uuid} for the scan pickers).
render_list_picker(key target, string ctx, string mode, string title, string body, list items) {
    SessionId = gen_session();
    MenuContext = ctx;
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       mode,
        "session_id", SessionId,
        "user",       (string)target,
        "menu_type",  PLUGIN_CONTEXT,
        "title",      title,
        "body",       body,
        "items",      llList2Json(JSON_ARRAY, items),
        "page",       CurrentPage
    ]), NULL_KEY);
}

// Unified Yes/No confirmation, rendered via the menu service's MODAL mode.
// The service forces the SAFE choice (No/cancel) to slot 0 and returns the
// context "confirm" (Yes) / "cancel" (No) — every branch below keys on that,
// so the swap is render-only. target picks which avatar receives the dialog
// (wearer for self-confirm, candidate for accept-prompts). Default Yes/No
// labels come from the service.
show_confirm(key target, string ctx, string title, string body) {
    SessionId = gen_session();
    MenuContext = ctx;
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",       "ui.menu.render",
        "mode",       "modal",
        "session_id", SessionId,
        "user",       (string)target,
        "title",      title,
        "body",       body
    ]), NULL_KEY);
}

show_candidates(string context, string title, string prompt) {
    if (llGetListLength(CandidateKeys) == 0) {
        llRegionSayTo(CurrentUser, 0, "No nearby avatars found.");
        show_main();
        return;
    }

    // UL picker: button face = display name, context = UUID. Carrying the key
    // in the context means a name collision / >24-char truncation can't
    // ambiguate the pick — the click returns the UUID directly. The service
    // A-Z-sorts by name and pages off CurrentPage.
    list items = [];
    integer i = 0;
    integer n = llGetListLength(CandidateKeys);
    while (i < n) {
        key k = (key)llList2String(CandidateKeys, i);
        items += [btn(get_name(k), (string)k)];
        i++;
    }

    render_list_picker(CurrentUser, context, "unordered", title, prompt, items);
}

show_honorific(key target, string context) {
    PendingCandidate = target;
    // The two honorific pools stay distinct (ownership vs respect titles);
    // the acquisition bit — not the context — selects which one.
    list choices = OWNER_HONORIFICS;
    if (!CandidateIsOwner) choices = TRUSTEE_HONORIFICS;
    // UL picker, flat items (label == context == the honorific). Honorific
    // lists are short (<=6) and single-page, so pin the page cursor at 0.
    CurrentPage = 0;
    render_list_picker(target, context, "unordered", "Honorific",
        "What would you like to be called?", choices);
}

// Begin an avatar scan for the given picker context. Shared by the menu
// (Add Owner / Transfer / Add Trustee) and the chat aliases — each caller
// gates first, then calls this; the scan body itself is identical.
start_scan(string scan_ctx) {
    CurrentPage = 0;
    MenuContext = scan_ctx;
    CandidateKeys = [];
    llSensor("", NULL_KEY, AGENT, 10.0, PI);
}

// Chat subcommand handler. Routes into the existing menu flows by
// setting session state and triggering the same code paths the
// corresponding main-menu button would fire.
handle_subpath(key user, integer acl_level, string subpath) {
    list tokens = llParseString2List(subpath, ["."], []);
    if (llGetListLength(tokens) < 2) {
        llRegionSayTo(user, 0, "Usage: access <add|rem> <owner|trustee>");
        return;
    }
    string verb = llList2String(tokens, 0);
    string role = llList2String(tokens, 1);

    gPolicyButtons = get_policy_buttons(PLUGIN_CONTEXT, acl_level);

    // Session setup mirrors the menu flow entry.
    CurrentUser = user;
    UserAcl = acl_level;
    MenuContext = "main";

    if (verb == "add" && role == "owner") {
        if (!btn_allowed("Add Owner")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        gPolicyButtons = [];
        CandidateIsOwner = 1;
        start_scan("acq_scan");
        return;
    }
    if (verb == "rem" && role == "owner") {
        // Release is OWNER-ONLY — mirror the menu's is_owner gate. A trustee
        // may resign (via Rem Trustee), never release. Policy lists Release at
        // ACL 3, so this is_owner check is what actually enforces owner-only.
        if (!btn_allowed("Release") || !is_owner(CurrentUser)) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        gPolicyButtons = [];
        OwnerConsents = 1;
        show_confirm(CurrentUser, "exit_owner_auth", "Confirm Release",
            "Release " + get_name(llGetOwner()) + "?");
        return;
    }
    if (verb == "add" && role == "trustee") {
        if (!btn_allowed("Add Trustee")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        gPolicyButtons = [];
        CandidateIsOwner = 0;
        start_scan("acq_scan");
        return;
    }
    if (verb == "rem" && role == "trustee") {
        if (!btn_allowed("Rem Trustee")) {
            llRegionSayTo(user, 0, "Access denied.");
            gPolicyButtons = [];
            return;
        }
        gPolicyButtons = [];
        CurrentPage = 0;
        show_remove_trustee();
        return;
    }

    gPolicyButtons = [];
    llRegionSayTo(user, 0, "Unknown access subcommand: " + verb + " " + role);
}

show_remove_trustee() {
    if (llGetListLength(TrusteeKeys) == 0) {
        llRegionSayTo(CurrentUser, 0, "No trustees.");
        show_main();
        return;
    }

    // OL picker: names (with honorific) go in the numbered body — display
    // names can exceed llDialog's 24-char button cap — and the click returns
    // pick:<index>. names[] is built parallel to TrusteeKeys, so the index
    // maps straight back to the UUID. The service pages off CurrentPage.
    list names = [];
    integer i = 0;
    integer n = llGetListLength(TrusteeKeys);
    while (i < n) {
        string display_name = "";
        if (i < llGetListLength(TrusteeNames)) display_name = llList2String(TrusteeNames, i);
        if (display_name == "") display_name = get_name((key)llList2String(TrusteeKeys, i));
        string hon = "";
        if (i < llGetListLength(TrusteeHonorifics)) hon = llList2String(TrusteeHonorifics, i);
        if (hon != "") display_name += " (" + hon + ")";
        names += [display_name];
        i++;
    }

    render_list_picker(CurrentUser, "remove_trustee", "ordered", "Remove Trustee",
        "Select to remove:", names);
}

/* -------------------- PICKER PAGING -------------------- */

// Render the candidate picker for the active acquisition, deriving the title
// and prompt from the role bit (+ has_owner for owner = set vs transfer).
// Shared by sensor / no_sensor (scan results) and redraw_picker (paging).
finish_scan() {
    string title = "Add Trustee";
    string prompt = "Choose trustee:";
    if (CandidateIsOwner) {
        if (has_owner()) {
            title = "Transfer";
            prompt = "Choose new owner:";
        }
        else {
            title = "Set Owner";
            prompt = "Choose owner:";
        }
    }
    show_candidates("acq_select", title, prompt);
}

// Total item count for the active LIST picker — drives << >> page wrapping.
integer picker_count() {
    if (MenuContext == "acq_select") return llGetListLength(CandidateKeys);
    if (MenuContext == "remove_trustee") return llGetListLength(TrusteeKeys);
    if (MenuContext == "acq_hon") {
        if (CandidateIsOwner) return llGetListLength(OWNER_HONORIFICS);
        return llGetListLength(TRUSTEE_HONORIFICS);
    }
    return 0;
}

// Re-render the active LIST picker after a << >> page change.
redraw_picker() {
    if (MenuContext == "acq_select") finish_scan();
    else if (MenuContext == "remove_trustee") show_remove_trustee();
    else if (MenuContext == "acq_hon") show_honorific(PendingCandidate, "acq_hon");
}

/* -------------------- BUTTON HANDLING -------------------- */

handle_button(string cmd, string label) {
    // Numbered list contexts use the label as a number index; button_data contexts use cmd
    // "Back" from numbered_list has empty context, route by label
    if (cmd == "back" || (cmd == "" && label == "Back")) {
        if (MenuContext == "main") {
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "ui.menu.return", "user", (string)CurrentUser
            ]), NULL_KEY);
            cleanup();
        }
        else show_main();
        return;
    }

    if (MenuContext == "main") {
        if (cmd == "add_owner" || cmd == "transfer") {
            // Both make the candidate an owner; has_owner() at commit time
            // distinguishes set (unowned) from transfer (owned).
            CandidateIsOwner = 1;
            start_scan("acq_scan");
        }
        else if (cmd == "release") {
            // Owner-authorized exit: owner confirms first, then the wearer.
            OwnerConsents = 1;
            show_confirm(CurrentUser, "exit_owner_auth", "Confirm Release",
                "Release " + get_name(llGetOwner()) + "?");
        }
        else if (cmd == "runaway") {
            // Owner-bypassed exit: the wearer's unilateral right to leave.
            OwnerConsents = 0;
            show_confirm(CurrentUser, "exit_wearer", "Confirm Runaway",
                "Run away from " + get_name(get_primary_owner()) + "?\n\nThis removes ownership without consent.");
        }
        else if (cmd == "runaway_toggle") {
            if (RunawayEnabled) {
                // Disabling requires wearer consent — dialog goes to the
                // WEARER (not CurrentUser, who is the owner requesting it).
                string hon = OwnerHonorific;
                if (hon == "") hon = "Owner";
                show_confirm(llGetOwner(), "runaway_disable_confirm",
                    "Disable Runaway",
                    "Your " + hon + " wants to disable runaway for you.\n\nPlease confirm.");
            }
            else {
                // Enabling is direct (no consent needed)
                RunawayEnabled = TRUE;
                // Single-writer settings.delta CSV protocol — kmod_settings sole LSD writer.
                llMessageLinked(LINK_SET, SETTINGS_BUS,
                    "settings.delta:" + KEY_RUNAWAY_ENABLED + ":1", NULL_KEY);

                llRegionSayTo(CurrentUser, 0, "Runaway enabled.");
                show_main();
            }
            return;
        }
        else if (cmd == "add_trustee") {
            CandidateIsOwner = 0;
            start_scan("acq_scan");
        }
        else if (cmd == "rem_trustee") {
            CurrentPage = 0;
            show_remove_trustee();
        }
        else {
            // Inert << >> on this single-page pager — just redraw the menu.
            show_main();
        }
        return;
    }

    // LIST picker paging: << >> arrive as an empty context with the arrow as
    // the button label; wrap CurrentPage off the active picker's count and
    // redraw. (Content picks below carry their value in cmd, not the label.)
    if (label == "<<" || label == ">>") {
        integer cnt = picker_count();
        integer max_page = 0;
        if (cnt > 0) max_page = (cnt - 1) / LIST_PAGE_SIZE;
        if (label == "<<") {
            if (CurrentPage == 0) CurrentPage = max_page;
            else CurrentPage -= 1;
        }
        else {
            if (CurrentPage >= max_page) CurrentPage = 0;
            else CurrentPage += 1;
        }
        redraw_picker();
        return;
    }

    // ONE acquisition spine for owner (set + transfer) and trustee, keyed on
    // CandidateIsOwner (+ has_owner() for owner = set vs transfer).
    // UL scan pick: cmd IS the chosen UUID (validate against the live scan).
    if (MenuContext == "acq_select") {
        if (llListFindList(CandidateKeys, [cmd]) != -1) {
            PendingCandidate = (key)cmd;
            // A trustee can't be added twice.
            if (!CandidateIsOwner && llListFindList(TrusteeKeys, [(string)PendingCandidate]) != -1) {
                llRegionSayTo(CurrentUser, 0, "Already trustee.");
                show_main();
                return;
            }
            // Accept prompt — role-specific wording.
            string a_title = "Accept Trustee";
            string a_body = get_name(llGetOwner()) + " wants you as trustee.\n\nAccept?";
            if (CandidateIsOwner) {
                if (has_owner()) {
                    a_title = "Accept Transfer";
                    a_body = "Accept ownership of " + get_name(llGetOwner()) + "?";
                }
                else {
                    a_title = "Accept Ownership";
                    a_body = get_name(llGetOwner()) + " wishes to submit to you.\n\nAccept?";
                }
            }
            show_confirm(PendingCandidate, "acq_accept", a_title, a_body);
        }
    }
    else if (MenuContext == "acq_accept") {
        if (cmd == "confirm") show_honorific(PendingCandidate, "acq_hon");
        else {
            llRegionSayTo(CurrentUser, 0, "Declined.");
            show_main();
        }
    }
    else if (MenuContext == "acq_hon") {
        // UL honorific pick: cmd IS the chosen honorific. Validate against the
        // role's pool, then branch to the role's commit.
        list valid = OWNER_HONORIFICS;
        if (!CandidateIsOwner) valid = TRUSTEE_HONORIFICS;
        if (llListFindList(valid, [cmd]) != -1) {
            PendingHonorific = cmd;
            if (!CandidateIsOwner) {
                // Trustee: commit directly.
                add_trustee(PendingCandidate, PendingHonorific);
                llRegionSayTo(PendingCandidate, 0, "You are trustee of " + get_name(llGetOwner()) + " as " + PendingHonorific + ".");
                llRegionSayTo(CurrentUser, 0, get_name(PendingCandidate) + " is trustee.");
                show_main();
            }
            else if (has_owner()) {
                // Transfer: commit directly + notify the outgoing owner.
                key old = OwnerKey;
                persist_owner(PendingCandidate, PendingHonorific);
                llRegionSayTo(old, 0, "You have transferred " + get_name(llGetOwner()) + " to " + get_name(PendingCandidate) + ".");
                llRegionSayTo(PendingCandidate, 0, get_name(llGetOwner()) + " is now your property as " + PendingHonorific + ".");
                llRegionSayTo(llGetOwner(), 0, "You are now property of " + PendingHonorific + " " + get_name(PendingCandidate) + ".");
                cleanup();
            }
            else {
                // Set (first owner): the WEARER double-confirms consent to be owned.
                show_confirm(llGetOwner(), "acq_confirm", "Confirm",
                    "Submit to " + get_name(PendingCandidate) + " as your " + PendingHonorific + "?");
            }
        }
    }
    else if (MenuContext == "acq_confirm") {
        if (cmd == "confirm") {
            persist_owner(PendingCandidate, PendingHonorific);
            llRegionSayTo(PendingCandidate, 0, get_name(llGetOwner()) + " has submitted to you as their " + PendingHonorific + ".");
            llRegionSayTo(llGetOwner(), 0, "You are now property of " + PendingHonorific + " " + get_name(PendingCandidate) + ".");
            // Emit the return BEFORE cleanup — cleanup nulls CurrentUser, and
            // ui.menu.return must carry the real recipient (the Back path does
            // the same order).
            llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
                "type", "ui.menu.return", "user", (string)CurrentUser
            ]), NULL_KEY);
            cleanup();
        }
        else show_main();
    }
    else if (MenuContext == "exit_owner_auth") {
        // Release only: owner authorized → ask the wearer to confirm freedom.
        if (cmd == "confirm") {
            show_confirm(llGetOwner(), "exit_wearer", "Confirm Release",
                "Released by " + get_name(CurrentUser) + ".\n\nConfirm freedom?");
        }
        else show_main();
    }
    else if (MenuContext == "exit_wearer") {
        if (cmd == "confirm") {
            if (OwnerConsents) {
                // Release: clear the owner; kmod_settings soft-reboots (rev 8).
                clear_owner();
                llRegionSayTo(llGetOwner(), 0, "Released. You are free.");
            }
            else {
                // Runaway: notify wearer + former owner, then factory reset.
                key old = get_primary_owner();
                string old_hon = OwnerHonorific;
                if (old != NULL_KEY) {
                    string notify_msg = "You have run away from ";
                    if (old_hon != "") notify_msg += old_hon + " ";
                    notify_msg += get_name(old) + ".";
                    llRegionSayTo(llGetOwner(), 0, notify_msg);
                    llRegionSayTo(old, 0, get_name(llGetOwner()) + " ran away.");
                }
                else {
                    llRegionSayTo(llGetOwner(), 0, "You have run away.");
                }
                // Runaway = factory reset. kmod_settings wipes LSD + resets all scripts.
                trigger_runaway();
            }
            cleanup();
        }
        else {
            // Cancelled — release reports back to the owner; runaway redraws.
            if (OwnerConsents) {
                llRegionSayTo(CurrentUser, 0, "Release cancelled.");
                cleanup();
            }
            else show_main();
        }
    }
    else if (MenuContext == "runaway_disable_confirm") {
        if (cmd == "confirm") {
            // Wearer consented - disable runaway
            RunawayEnabled = FALSE;
            // Single-writer settings.delta CSV protocol — kmod_settings sole LSD writer.
            llMessageLinked(LINK_SET, SETTINGS_BUS,
                "settings.delta:" + KEY_RUNAWAY_ENABLED + ":0", NULL_KEY);

            llRegionSayTo(llGetOwner(), 0, "Runaway disabled.");
            llRegionSayTo(CurrentUser, 0, "Runaway disabled.");
            show_main();
        }
        else {
            // Wearer declined
            llRegionSayTo(llGetOwner(), 0, "You declined to disable runaway.");
            llRegionSayTo(CurrentUser, 0, get_name(llGetOwner()) + " declined to disable runaway.");
            show_main();
        }
    }
    else if (MenuContext == "remove_trustee") {
        // OL pick: cmd is "pick:<global-index>" into TrusteeKeys.
        if (llGetSubString(cmd, 0, 4) == "pick:") {
            integer idx = (integer)llGetSubString(cmd, 5, -1);
            if (idx >= 0 && idx < llGetListLength(TrusteeKeys)) {
                key trustee_key = (key)llList2String(TrusteeKeys, idx);
                remove_trustee(trustee_key);
                llRegionSayTo(CurrentUser, 0, "Removed.");
                llRegionSayTo(trustee_key, 0, "Removed as trustee.");
                show_main();
            }
        }
    }
    else show_main();
}

/* -------------------- CLEANUP -------------------- */

cleanup() {
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
    CurrentPage = 0;
    PendingCandidate = NULL_KEY;
    PendingHonorific = "";
    CandidateIsOwner = 0;
    OwnerConsents = 0;
    CandidateKeys = [];
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {

        cleanup();
        register_self();
        apply_settings_sync();
    }

    on_rez(integer p) {
        llResetScript();
    }

    changed(integer c) {
        if (c & CHANGED_OWNER) llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id) {
        string type = llJsonGetValue(msg, ["type"]);
        if (type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (type == "kernel.register.refresh") register_self();
            else if (type == "kernel.ping") send_pong();
            else if (type == "kernel.reset.soft" || type == "kernel.reset.factory") {
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) return;
                }
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
                llResetScript();
            }
        }
        else if (num == SETTINGS_BUS) {
            if (type == "settings.sync") apply_settings_sync();
        }
        else if (num == UI_BUS) {
            if (type == "ui.menu.start" && (llJsonGetValue(msg, ["context"]) != JSON_INVALID)) {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) == PLUGIN_CONTEXT) {
                    integer acl = (integer)llJsonGetValue(msg, ["acl"]);

                    string subpath = "";
                    string sp = llJsonGetValue(msg, ["subpath"]);
                    if (sp != JSON_INVALID) subpath = sp;

                    if (subpath != "") {
                        handle_subpath(id, acl, subpath);
                        return;
                    }

                    CurrentUser = id;
                    UserAcl = acl;
                    show_main();
                }
            }
        }
        else if (num == DIALOG_BUS) {
            if (type == "ui.dialog.response") {
                if (llJsonGetValue(msg, ["session_id"]) != JSON_INVALID) {
                    if (llJsonGetValue(msg, ["session_id"]) == SessionId) {
                        string resp_ctx = llJsonGetValue(msg, ["context"]);
                        if (resp_ctx == JSON_INVALID) resp_ctx = "";
                        string resp_btn = llJsonGetValue(msg, ["button"]);
                        if (resp_btn == JSON_INVALID) resp_btn = "";
                        handle_button(resp_ctx, resp_btn);
                    }
                }
            }
            else if (type == "ui.dialog.timeout") {
                if ((llJsonGetValue(msg, ["session_id"]) != JSON_INVALID)) {
                    if (llJsonGetValue(msg, ["session_id"]) == SessionId) cleanup();
                }
            }
        }
    }

    sensor(integer count) {
        if (CurrentUser == NULL_KEY) return;
        if (MenuContext != "acq_scan") return;

        list candidates = [];
        key wearer = llGetOwner();
        integer i;

        while (i < count) {
            key k = llDetectedKey(i);
            if (k != wearer) candidates += [(string)k];
            i++;
        }

        CandidateKeys = candidates;
        finish_scan();
    }

    no_sensor() {
        if (CurrentUser == NULL_KEY) return;
        if (MenuContext != "acq_scan") return;
        CandidateKeys = [];
        finish_scan();
    }

    dataserver(key qid, string data) {
        if (qid != ActiveNameQuery) return;
        if (data != "" && data != "???") cache_name(ActiveQueryTarget, data);
        ActiveNameQuery = NULL_KEY;
        ActiveQueryTarget = NULL_KEY;
    }
}

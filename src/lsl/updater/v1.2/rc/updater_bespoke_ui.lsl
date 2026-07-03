/*--------------------
SCRIPT: updater_bespoke_ui.lsl  (v1.2)
VERSION: 1.2
REVISION: 1
PURPOSE: Bespoke install UI for the install_shim (fresh-target) path.
  Driver hands off via LM_BESPOKE_START with wearer / shim / pin; this
  script presents a one-stop toggle dialog of subsystems (HUD, Animations,
  Bell, Access, Chat, Leashing, Locking, Maintenance, Public, TPE, RLV
  Subsystem). Wearer taps numbers to flip [X]/[ ] markers. The RLV
  Subsystem row drills into a secondary toggle dialog with individual
  RLV plugins (Folders, Outfits, Strip, Relay, Restrict, RLV Exceptions);
  Back from the secondary returns to main with selections preserved.
  Wearer presses [Install] to commit; emits LM_BESPOKE_DONE with the
  composed scripts CSV (core + selected subsystems + selected RLV plugins
  + kmod_rlv if any RLV plugin was chosen). [Back] cancels the whole walk
  via LM_BESPOKE_CANCEL.
ARCHITECTURE: Lives in the same prim as updater_driver (the installer
  linkset root). Split out of updater_driver at v1.10 rev 10 because the
  inline walk pushed the driver past the Mono 65 KB compiled ceiling.
  Driver remains the orchestrator — this script is purely a UI flow that
  returns a scripts list. Subsystem and core-script definitions are
  hard-coded here per the user spec rather than derived from the
  bundler's heuristic grouping.
CHANGES:
  r1 — Dropped plugin_leash_target from the Leashing subsystem CSV: it merged
       into plugin_leash (v1.2) and no longer ships. Set is now
       kmod_leash_engine,kmod_particles,plugin_leash,leash_holder — matches the
       bundler's leash_members().
--------------------*/


/* -------------------- LINK-MESSAGE NUMBERS -------------------- */
// Must match updater_driver.
integer LM_BESPOKE_START  = 91010;
integer LM_BESPOKE_DONE   = 91011;
integer LM_BESPOKE_CANCEL = 91012;


/* -------------------- CONSTANTS -------------------- */
// Object description marker; if dragged into an installer prim by the
// packager, every collar-namespace script's state_entry guard would
// park itself.
string UPDATER_MARKER = "D/s Collar Updater -- v1.2";

// Dialog timeout — wearer has 2 min between interactions before we abandon.
float DIALOG_TIMEOUT = 120.0;

// Page size = 9 content slots minus the 1 action slot (Install at 5).
integer PAGE_SIZE = 8;


/* -------------------- STATE -------------------- */
key     Wearer       = NULL_KEY;
integer DialogChan   = 0;
integer DialogListen = 0;

// Phase: "main" = subsystem toggle dialog; "rlv" = secondary RLV plugin
// dialog; "" = idle.
string  Phase = "";
integer Page  = 0;

// Existing-collar mode flag. When TRUE, MissingScripts holds the names
// of scripts the collar is missing (from the bundler's diff), DisplayedSubs
// / DisplayedRlv filter out subsystems where nothing is missing, the
// core-scripts pre-seed is skipped (collar already has them), and the
// ship list is filtered against MissingScripts at commit so already-
// installed items don't re-load.
// When FALSE (fresh-install / install_shim path), the target is empty
// by construction, Displayed* mirror the full lists, core ships, and
// kmod_rlv ships whenever any RLV plugin is picked.
integer ExistingMode    = FALSE;
list    MissingScripts  = [];

// Filtered subsystem / RLV-plugin lists used for rendering and dispatch.
// In fresh mode these mirror bespoke_subsystems() and SUBSYSTEM_PLUGINS;
// in existing mode they're filtered to entries with at least one
// missing script. Built once at LM_BESPOKE_START.
list DisplayedSubs = [];
list DisplayedRlv  = [];

// Toggle state. SubSelected is parallel to DisplayedSubs (one slot per
// displayed subsystem; the RLV row's slot is unused — its on/off mark
// is derived from RlvSelected at render time). RlvSelected is parallel
// to DisplayedRlv. Both are 0/1 integer lists.
list SubSelected = [];
list RlvSelected = [];


/* -------------------- BESPOKE DEFINITIONS -------------------- */

// Always-shipped core scripts. Composed into the final ship list at commit.
list bespoke_core_scripts() {
    return [
        "collar_kernel",
        "kmod_auth", "kmod_bootstrap", "kmod_dialogs",
        "kmod_menu", "kmod_remote", "kmod_settings", "kmod_ui"
    ];
}

// Stride-2: [label, scripts CSV]. RLV Subsystem entry's CSV is empty —
// its actual scripts come from RlvSelected via the secondary dialog,
// so the tap handler treats this row as a drill-down rather than a toggle.
list bespoke_subsystems() {
    return [
        "HUD",            "control_hud",
        "Animations",     "plugin_animate",
        "Bell",           "plugin_bell",
        "Access",         "plugin_owners,plugin_blacklist",
        "Chat",           "plugin_chat,kmod_chat",
        "Leashing",       "kmod_leash_engine,kmod_particles,plugin_leash,leash_holder",
        "Locking",        "plugin_lock",
        "Maintenance",    "plugin_maint,plugin_status",
        "Public",         "plugin_public",
        "TPE",            "plugin_tpe,plugin_sos",
        "RLV Subsystem",  ""
    ];
}

// The shared kmod for the RLV subsystem. Ships if-and-only-if at least
// one entry from SUBSYSTEM_PLUGINS was selected. The kmod-paired-with-
// plugins shape means we can't ship the kmod with no plugins (wasted
// load) and can't ship plugins without the kmod (they'd have nothing
// to talk to). One source of truth, no dedupe needed.
string SUBSYSTEM_KMOD = "kmod_rlv";

// Stride-2: [display label, script name] for the RLV subsystem plugins.
// Each is independently toggleable in the secondary RLV dialog.
list SUBSYSTEM_PLUGINS = [
    "Folders",        "plugin_folders",
    "Outfits",        "plugin_outfits",
    "Strip",          "plugin_strip",
    "Relay",          "plugin_relay",
    "Restrict",       "plugin_restrict",
    "RLV Exceptions", "plugin_rlvex"
];


/* -------------------- HELPERS -------------------- */

integer random_channel() {
    return -((integer)llFrand(2147483600.0) + 1);
}

notice(string s) {
    if (Wearer != NULL_KEY) llRegionSayTo(Wearer, 0, s);
}

cleanup() {
    if (DialogListen) llListenRemove(DialogListen);
    DialogListen = 0;
    DialogChan   = 0;
    llSetTimerEvent(0.0);
    Wearer = NULL_KEY;
    Phase  = "";
    Page   = 0;
    SubSelected = [];
    RlvSelected = [];
    ExistingMode = FALSE;
    MissingScripts = [];
    DisplayedSubs = [];
    DisplayedRlv = [];
}

// Build target_slots top-to-bottom, left-to-right, skipping action_slot
// if one is claimed (-1 = no action). Matches the project's dialog
// convention; duplicates the helper in updater_driver because LSL has
// no shared-code mechanism.
list build_target_slots(integer total_buttons, integer action_slot) {
    list slots = [];
    if (total_buttons > 9)  slots += [9];
    if (total_buttons > 10) slots += [10];
    if (total_buttons > 11) slots += [11];
    if (total_buttons > 6)  slots += [6];
    if (total_buttons > 7)  slots += [7];
    if (total_buttons > 8)  slots += [8];
    if (total_buttons > 3 && action_slot != 3) slots += [3];
    if (total_buttons > 4 && action_slot != 4) slots += [4];
    if (total_buttons > 5 && action_slot != 5) slots += [5];
    return slots;
}

integer wrap_prev(integer page, integer max_page) {
    page -= 1;
    if (page < 0) page = max_page;
    return page;
}

integer wrap_next(integer page, integer max_page) {
    page += 1;
    if (page > max_page) page = 0;
    return page;
}

// TRUE iff at least one RLV plugin is currently selected. Renders the
// RLV Subsystem row's [X]/[ ] mark in the main dialog.
integer rlv_any_selected() {
    integer i = 0;
    integer n = llGetListLength(RlvSelected);
    while (i < n) {
        if (llList2Integer(RlvSelected, i)) return TRUE;
        i += 1;
    }
    return FALSE;
}

// Returns `parts` with entries not in MissingScripts removed.
// In fresh mode the filter is a pass-through (everything is "missing"
// because the target is empty). In existing-collar mode, scripts the
// collar already has fall out.
list filter_missing(list parts) {
    if (!ExistingMode) return parts;
    list out = [];
    integer n = llGetListLength(parts);
    integer i = 0;
    while (i < n) {
        string s = llList2String(parts, i);
        if (llListFindList(MissingScripts, [s]) != -1) {
            out += [s];
        }
        i += 1;
    }
    return out;
}

// Build the filtered subsystem list. For fresh mode, this mirrors
// bespoke_subsystems(); for existing mode, only subsystems with at
// least one script in MissingScripts are kept (the "RLV Subsystem"
// row is kept iff any RLV plugin or kmod_rlv is missing).
list build_displayed_subs() {
    if (!ExistingMode) return bespoke_subsystems();

    list out = [];
    list subs = bespoke_subsystems();
    integer n = llGetListLength(subs) / 2;
    integer i = 0;
    while (i < n) {
        string label = llList2String(subs, i * 2);
        string csv   = llList2String(subs, i * 2 + 1);
        integer keep = FALSE;
        if (label == "RLV Subsystem") {
            // Keep if any RLV plugin (or the shared kmod) is missing.
            integer rn = llGetListLength(SUBSYSTEM_PLUGINS) / 2;
            integer r = 0;
            while (r < rn && !keep) {
                if (llListFindList(MissingScripts,
                        [llList2String(SUBSYSTEM_PLUGINS, r * 2 + 1)]) != -1) {
                    keep = TRUE;
                }
                r += 1;
            }
            if (!keep && llListFindList(MissingScripts, [SUBSYSTEM_KMOD]) != -1) {
                keep = TRUE;
            }
        }
        else {
            // Keep if any script in the subsystem CSV is missing.
            list parts = llCSV2List(csv);
            integer pn = llGetListLength(parts);
            integer p = 0;
            while (p < pn && !keep) {
                if (llListFindList(MissingScripts, [llList2String(parts, p)]) != -1) {
                    keep = TRUE;
                }
                p += 1;
            }
        }
        if (keep) out += [label, csv];
        i += 1;
    }
    return out;
}

// Build the filtered RLV plugin list. For fresh mode, mirrors
// SUBSYSTEM_PLUGINS; for existing mode, only plugins whose script is
// in MissingScripts are kept.
list build_displayed_rlv() {
    if (!ExistingMode) return SUBSYSTEM_PLUGINS;

    list out = [];
    integer n = llGetListLength(SUBSYSTEM_PLUGINS) / 2;
    integer i = 0;
    while (i < n) {
        string label  = llList2String(SUBSYSTEM_PLUGINS, i * 2);
        string script = llList2String(SUBSYSTEM_PLUGINS, i * 2 + 1);
        if (llListFindList(MissingScripts, [script]) != -1) {
            out += [label, script];
        }
        i += 1;
    }
    return out;
}

open_dialog(string body, list buttons) {
    if (DialogListen) llListenRemove(DialogListen);
    DialogChan   = random_channel();
    DialogListen = llListen(DialogChan, "", Wearer, "");
    llDialog(Wearer, body, buttons, DialogChan);
    llSetTimerEvent(DIALOG_TIMEOUT);
}

emit_done(list ship) {
    string payload = llList2Json(JSON_OBJECT, [
        "scripts", llDumpList2String(ship, ",")
    ]);
    llMessageLinked(LINK_SET, LM_BESPOKE_DONE, payload, NULL_KEY);
    cleanup();
}

emit_cancel() {
    llMessageLinked(LINK_SET, LM_BESPOKE_CANCEL, "", NULL_KEY);
    cleanup();
}

// Compose the final ship list from current SubSelected / RlvSelected and
// emit LM_BESPOKE_DONE. Fresh mode pre-seeds core scripts; existing mode
// skips core (collar already has it) and filters every selected script
// through MissingScripts so already-installed items don't re-load.
// kmod_rlv ships only when at least one RLV plugin is selected AND
// (fresh mode OR kmod_rlv itself is missing) — same structural pairing
// as before, plus the missing-list filter.
commit() {
    list ship = [];
    if (!ExistingMode) ship = bespoke_core_scripts();

    integer sn = llGetListLength(DisplayedSubs) / 2;
    integer i = 0;
    while (i < sn) {
        if (llList2Integer(SubSelected, i)) {
            string label = llList2String(DisplayedSubs, i * 2);
            if (label != "RLV Subsystem") {
                string csv = llList2String(DisplayedSubs, i * 2 + 1);
                if (csv != "") ship += filter_missing(llCSV2List(csv));
            }
        }
        i += 1;
    }

    // RLV subsystem: collect every selected plugin into a local list,
    // then if that list is non-empty prepend SUBSYSTEM_KMOD. The kmod
    // can never appear without at least one plugin (gated on the local
    // list being non-empty); in existing mode filter_missing drops the
    // kmod if the collar already has it. No selected plugins → no kmod,
    // no script-slot waste in the wearer's collar.
    list rlv_ship = [];
    integer rn = llGetListLength(DisplayedRlv) / 2;
    i = 0;
    while (i < rn) {
        if (llList2Integer(RlvSelected, i)) {
            rlv_ship += [llList2String(DisplayedRlv, i * 2 + 1)];
        }
        i += 1;
    }
    if (llGetListLength(rlv_ship) > 0) {
        ship += filter_missing([SUBSYSTEM_KMOD]) + rlv_ship;
    }

    emit_done(ship);
}


/* -------------------- RENDERING -------------------- */

// Main toggle dialog: subsystems with [X]/[ ] markers. Slot layout per
// the project dialog convention — << >> Back at 0/1/2, Install at slot 5,
// digit buttons at the remaining content slots. Pagination wraps.
show_main() {
    Phase = "main";
    integer n = llGetListLength(DisplayedSubs) / 2;
    integer pages = (n + PAGE_SIZE - 1) / PAGE_SIZE;
    if (pages < 1) pages = 1;

    integer start = Page * PAGE_SIZE;
    integer stop = start + PAGE_SIZE;
    if (stop > n) stop = n;
    integer count = stop - start;

    integer total_buttons = 4 + count;
    if (total_buttons < 6) total_buttons = 6;

    list final_buttons = ["<<", ">>", "Back"];
    integer p = 0;
    while (p < total_buttons - 3) {
        final_buttons += [" "];
        p += 1;
    }
    final_buttons = llListReplaceList(final_buttons, ["Install"], 5, 5);

    list target_slots = build_target_slots(total_buttons, 5);
    integer i = 0;
    while (i < count) {
        integer slot = llList2Integer(target_slots, i);
        final_buttons = llListReplaceList(final_buttons, [(string)(i + 1)], slot, slot);
        i += 1;
    }

    string body = "Choose components to install. Tap a number to toggle, then Install.\n";
    if (pages > 1) body += "Page " + (string)(Page + 1) + " of " + (string)pages + "\n";
    body += "\n";

    integer k = 0;
    while (k < count) {
        integer abs_idx = start + k;
        string label = llList2String(DisplayedSubs, abs_idx * 2);
        string mark = "[ ]";
        if (label == "RLV Subsystem") {
            if (rlv_any_selected()) mark = "[X]";
        }
        else {
            if (llList2Integer(SubSelected, abs_idx)) mark = "[X]";
        }
        body += (string)(k + 1) + ". " + mark + " " + label + "\n";
        k += 1;
    }

    open_dialog(body, final_buttons);
}

// Secondary dialog: RLV plugin toggles. No Install action here — Back
// returns to main with RlvSelected preserved. 6 plugins fit on one page
// so no wrap actually happens; << / >> remain per convention but no-op.
show_rlv() {
    Phase = "rlv";
    integer n = llGetListLength(DisplayedRlv) / 2;
    integer total_buttons = 3 + n;

    list final_buttons = ["<<", ">>", "Back"];
    integer p = 0;
    while (p < n) {
        final_buttons += [" "];
        p += 1;
    }

    list target_slots = build_target_slots(total_buttons, -1);
    integer i = 0;
    while (i < n) {
        integer slot = llList2Integer(target_slots, i);
        final_buttons = llListReplaceList(final_buttons, [(string)(i + 1)], slot, slot);
        i += 1;
    }

    string body = "RLV plugins. Tap a number to toggle, Back when done.\n\n";
    integer k = 0;
    while (k < n) {
        string label = llList2String(DisplayedRlv, k * 2);
        string mark = "[ ]";
        if (llList2Integer(RlvSelected, k)) mark = "[X]";
        body += (string)(k + 1) + ". " + mark + " " + label + "\n";
        k += 1;
    }

    open_dialog(body, final_buttons);
}


/* -------------------- DISPATCH -------------------- */

handle_main(string btn) {
    if (btn == "Back") {
        emit_cancel();
        return;
    }
    if (btn == "Install") {
        commit();
        return;
    }

    integer n = llGetListLength(DisplayedSubs) / 2;
    integer pages = (n + PAGE_SIZE - 1) / PAGE_SIZE;
    integer max_page = pages - 1;
    if (max_page < 0) max_page = 0;

    if (btn == "<<") {
        Page = wrap_prev(Page, max_page);
        show_main();
        return;
    }
    if (btn == ">>") {
        Page = wrap_next(Page, max_page);
        show_main();
        return;
    }

    integer pos = (integer)btn;
    if (pos < 1) return;
    if ((string)pos != btn) return;
    integer abs_idx = Page * PAGE_SIZE + (pos - 1);
    if (abs_idx >= n) return;

    string label = llList2String(DisplayedSubs, abs_idx * 2);
    if (label == "RLV Subsystem") {
        show_rlv();
        return;
    }

    integer cur = llList2Integer(SubSelected, abs_idx);
    SubSelected = llListReplaceList(SubSelected, [!cur], abs_idx, abs_idx);
    show_main();
}

handle_rlv(string btn) {
    if (btn == "Back") {
        show_main();
        return;
    }
    // << / >> are no-ops on the single-page RLV view, but per convention
    // we accept them and just re-render.
    if (btn == "<<" || btn == ">>") {
        show_rlv();
        return;
    }

    integer pos = (integer)btn;
    if (pos < 1) return;
    if ((string)pos != btn) return;
    integer n = llGetListLength(DisplayedRlv) / 2;
    if (pos - 1 >= n) return;

    integer cur = llList2Integer(RlvSelected, pos - 1);
    RlvSelected = llListReplaceList(RlvSelected, [!cur], pos - 1, pos - 1);
    show_rlv();
}


/* -------------------- EVENTS -------------------- */

default {
    state_entry() {
        llSetObjectDesc(UPDATER_MARKER);
        cleanup();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) llResetScript();
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num != LM_BESPOKE_START) return;
        if (Phase != "") return;  // already walking; ignore stray start

        string wearer_str = llJsonGetValue(msg, ["wearer"]);
        if (wearer_str == JSON_INVALID) return;
        Wearer = (key)wearer_str;
        if (Wearer == NULL_KEY) return;
        // shim / pin come through here but are only needed by the driver
        // (which retains them for dispatch_shim_ship).

        // Existing-collar mode: filter Displayed* to subsystems / RLV
        // plugins where at least one script is missing in the collar,
        // skip the core-scripts pre-seed, and apply filter_missing at
        // commit. Fresh-install mode (no "existing" field): Displayed*
        // mirror the full lists, core ships, no filtering.
        string ex_str = llJsonGetValue(msg, ["existing"]);
        ExistingMode = (ex_str == "1");
        MissingScripts = [];
        if (ExistingMode) {
            string missing_csv = llJsonGetValue(msg, ["missing"]);
            if (missing_csv != JSON_INVALID && missing_csv != "") {
                MissingScripts = llCSV2List(missing_csv);
            }
        }
        DisplayedSubs = build_displayed_subs();
        DisplayedRlv  = build_displayed_rlv();

        // Initialise toggle state, parallel to the Displayed lists.
        // Default is all OFF — wearer opts in explicitly. List-doubling
        // pre-allocation dodges O(n²) heap pressure from repeated += in
        // a loop.
        integer sn = llGetListLength(DisplayedSubs) / 2;
        SubSelected = [];
        if (sn > 0) {
            list buf = [FALSE];
            while (llGetListLength(buf) < sn) buf = buf + buf;
            SubSelected = llList2List(buf, 0, sn - 1);
        }
        integer rn = llGetListLength(DisplayedRlv) / 2;
        RlvSelected = [];
        if (rn > 0) {
            list rbuf = [FALSE];
            while (llGetListLength(rbuf) < rn) rbuf = rbuf + rbuf;
            RlvSelected = llList2List(rbuf, 0, rn - 1);
        }

        Page = 0;
        show_main();
    }

    listen(integer channel, string name, key id, string message) {
        if (channel != DialogChan) return;
        if (id != Wearer) return;
        if (Phase == "main")     handle_main(message);
        else if (Phase == "rlv") handle_rlv(message);
    }

    timer() {
        notice("Bespoke install timed out.");
        emit_cancel();
    }
}

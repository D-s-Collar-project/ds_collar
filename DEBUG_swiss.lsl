/*--------------------
THROWAWAY DEBUG TOOL — NOT part of the product. DELETE before any build/bundle.

DS Collar Swiss-army debugger. Drop into ANY prim of the collar linkset (it
shares the internal link-message bus, so it sees every ISP lane natively — the
lanes are llMessageLinked(LINK_SET,...) and never leave the object, which is
why this has to live IN the collar, not in a detached HUD).

FOUR tools, one script:
  • LSD INSPECTOR  — dump live LSD state by group (sentinel/flags, roster,
                     registrations, ui.views, leash). Sidesteps boot-timing:
                     read the truth NOW instead of catching a transient.
  • SNAPSHOT       — one shot: owner-change sentinel vs current owner, the
                     bootstrap sentinel, ownership flags, and counts of
                     roster / registrations / views. The "what's broken now".
  • LANE TAP       — live print of all ISP lanes (500 KERNEL, 600 REMOTE,
                     700 AUTH, 800 SETTINGS, 900 UI) with timing. Toggle +
                     verbose.
  • INJECTOR       — fire test messages onto the lanes (ACL self-query,
                     register.refresh, settings reload/restream, menu self).

USAGE:
  - Wearer: touch this prim → dialog menu. Output is llOwnerSay (wearer-only).
  - Separate console prim: chat a command on DEBUG_CMD_CHAN (e.g. "snapshot",
    "dump roster", "tap on", "inject acl"); replies come back on DEBUG_OUT_CHAN
    AND llOwnerSay. (Lets you drive it from another prim — comms over channel.)
--------------------*/

/* -------------------- ISP LANES (link-message buses) -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer REMOTE_BUS       = 600;
integer AUTH_BUS         = 700;
integer SETTINGS_BUS     = 800;
integer UI_BUS           = 900;

/* -------------------- CONSOLE CHANNELS (throwaway) -----------------------
   CMD is POSITIVE so you can drive it straight from the viewer chat bar:
   the chat bar refuses negative channels, but "/9090 snapshot" works.   */
integer DEBUG_CMD_CHAN = 9090;       // you (chat) / console -> agent commands
integer DEBUG_OUT_CHAN = -90909091;  // agent -> external console replies (mirror)

/* -------------------- STATE -------------------- */
integer DialogChan;
integer DialogListen;
integer CmdListen;

integer TapOn      = FALSE;   // live lane printing
integer TapVerbose = FALSE;   // TRUE: raw msg too, not just the type
float   LastT;

key   Speaker = NULL_KEY;     // last console speaker (for OUT replies)

/* -------------------- OUTPUT -------------------- */
// Everything goes to the wearer; if a console drove the last command, mirror
// it back on the OUT channel too.
out(string s) {
    llOwnerSay(s);
    if (Speaker != NULL_KEY) llRegionSayTo(Speaker, DEBUG_OUT_CHAN, s);
}

string fnum(float f, integer places) {
    string s = (string)f;
    integer dot = llSubStringIndex(s, ".");
    if (dot == -1) return s;
    return llGetSubString(s, 0, dot + places);
}

// Readable label from a JSON envelope ({"type":...}) or a CSV envelope
// (settings.delta:key:val -> "settings.delta:key").
string label_of(string msg) {
    if (llGetSubString(msg, 0, 0) == "{") {
        string t = llJsonGetValue(msg, ["type"]);
        if (t == JSON_INVALID) return "(json,no-type)";
        return t;
    }
    list p = llParseString2List(msg, [":"], []);
    if (llGetListLength(p) >= 2) return llList2String(p, 0) + ":" + llList2String(p, 1);
    return msg;
}

string lane_name(integer num) {
    if (num == KERNEL_LIFECYCLE) return "KERNEL";
    if (num == REMOTE_BUS)       return "REMOTE";
    if (num == AUTH_BUS)         return "AUTH";
    if (num == SETTINGS_BUS)     return "SETTINGS";
    if (num == UI_BUS)           return "UI";
    return (string)num;
}

/* -------------------- LSD INSPECTOR -------------------- */

// Dump every LSD key matching a regex prefix, value alongside. Returns count.
integer dump_prefix(string pattern, string heading) {
    list keys = llLinksetDataFindKeys(pattern, 0, -1);
    integer n = llGetListLength(keys);
    out("-- " + heading + " (" + (string)n + ") --");
    integer i = 0;
    while (i < n) {
        string k = llList2String(keys, i);
        out("   " + k + " = " + llLinksetDataRead(k));
        i += 1;
    }
    if (n == 0) out("   (none)");
    return n;
}

dump_group(string grp) {
    if (grp == "sentinel") {
        out("settings.bootstrapped = '" + llLinksetDataRead("settings.bootstrapped") + "'");
        out("safeguard.last_owner  = " + llLinksetDataRead("safeguard.last_owner"));
        out("current owner         = " + (string)llGetOwner());
    }
    else if (grp == "flags") {
        out("access.isowned     = " + llLinksetDataRead("access.isowned"));
        out("access.multiowner  = " + llLinksetDataRead("access.multiowner"));
        out("access.enablerunaway = " + llLinksetDataRead("access.enablerunaway"));
        out("public.mode        = " + llLinksetDataRead("public.mode"));
        out("tpe.mode           = " + llLinksetDataRead("tpe.mode"));
        out("lock.locked        = " + llLinksetDataRead("lock.locked"));
    }
    else if (grp == "roster")   dump_prefix("^user\\.", "user.* roster");
    else if (grp == "scratch")  dump_prefix("^access\\.(owner|trustee)", "access.* card scratch");
    else if (grp == "reg")      dump_prefix("^reg\\.", "reg.* registrations");
    else if (grp == "views")    dump_prefix("^ui\\.view", "ui.view* menu views");
    else if (grp == "leash")    dump_prefix("^leash\\.", "leash.* state");
    else out("? unknown group: " + grp);
}

snapshot() {
    out("===== SNAPSHOT @ t=" + fnum(llGetTime(), 1) + " =====");
    string sent = llLinksetDataRead("settings.bootstrapped");
    string lo   = llLinksetDataRead("safeguard.last_owner");
    string cur  = (string)llGetOwner();
    out("bootstrapped sentinel : '" + sent + "'  <- empty == auth NEVER ready (no UI)");
    out("cardapplied marker    : '" + llLinksetDataRead("settings.cardapplied") + "'");
    out("last_owner / current  : " + lo + " / " + cur
        + "   match=" + (string)(lo == cur));
    out("access.isowned        : " + llLinksetDataRead("access.isowned"));
    out("tpe.mode              : " + llLinksetDataRead("tpe.mode"));
    integer nUser = llGetListLength(llLinksetDataFindKeys("^user\\.", 0, -1));
    integer nReg  = llGetListLength(llLinksetDataFindKeys("^reg\\.", 0, -1));
    integer nView = llGetListLength(llLinksetDataFindKeys("^ui\\.view", 0, -1));
    out("roster / reg / views  : " + (string)nUser + " / " + (string)nReg + " / " + (string)nView);
    out("=====================================");
}

// Count reg.* entries right now.
integer reg_count() {
    return llGetListLength(llLinksetDataFindKeys("^reg\\.", 0, -1));
}

// Prune-vs-write test: sample reg.* before a refresh, ~0.5s after (before the
// kernel's 3s prune sweep), and ~4.5s after (after a prune sweep). If the
// middle sample is high and the last drops back, the kernel is deleting valid
// registrations. If all three stay low, the plugins aren't writing reg.* at all.
regtest() {
    out("regtest: before = " + (string)reg_count());
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register.refresh"]), NULL_KEY);
    llSleep(0.6);
    out("regtest: +0.6s (post-refresh, pre-prune) = " + (string)reg_count());
    llSleep(4.0);
    out("regtest: +4.6s (post-prune) = " + (string)reg_count());
    out("regtest: high-then-low => kernel pruning; flat-low => plugins not writing");
}

// Fine-grained prune detector: fire a refresh, then sample reg.* every 0.3s
// for ~5s. A spike above 6 that then drops = kernel pruning valid writes (and
// we see WHEN). A flat 6 throughout = the 13 plugins never write reg.* at all.
regwatch() {
    out("regwatch: refresh sent; sampling reg every 0.3s for ~5s...");
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register.refresh"]), NULL_KEY);
    integer i = 0;
    while (i < 16) {
        llSleep(0.3);
        i += 1;
        out("  +" + fnum((float)i * 0.3, 1) + "s  reg=" + (string)reg_count());
    }
    out("regwatch: spike-then-drop => kernel pruning; flat-6 => not written");
}

// Staggered re-registration test: llResetOtherScript every plugin one at a
// time, 0.4s apart, so each re-registers in isolation (no write burst). This is
// the exact mechanism the kernel fix would use on owner-change. If reg climbs to
// ~18 and holds, the staggered-reset approach is validated.
sweep(float gap) {
    if (gap < 0.1) gap = 0.4;
    list plugins = ["plugin_animate","plugin_bell","plugin_blacklist","plugin_chat",
        "plugin_folders","plugin_leash","plugin_lock","plugin_maint","plugin_outfits",
        "plugin_owners","plugin_public","plugin_relay","plugin_restrict","plugin_rlvex",
        "plugin_sos","plugin_status","plugin_strip","plugin_tpe"];
    integer n = llGetListLength(plugins);
    out("sweep: staggered llResetOtherScript over " + (string)n + " plugins, "
        + fnum(gap, 1) + "s apart...");
    integer found = 0;
    integer i = 0;
    while (i < n) {
        string sn = llList2String(plugins, i);
        if (llGetInventoryType(sn) == INVENTORY_SCRIPT) {
            llResetOtherScript(sn);
            found += 1;
        }
        else {
            out("  ! not in inventory by that name: " + sn);
        }
        llSleep(gap);
        i += 1;
    }
    out("sweep done: reset " + (string)found + " scripts. reg now = "
        + (string)reg_count() + " (give kmod_ui a sec, then /9090 reg)");
}

// Like sweep, but FIRST does a full llLinksetDataReset() — the real reset path
// (Escape/owner-change) wipes LSD then re-registers, so this reproduces it: from
// reg=0, does a staggered bring-up climb back to ~18? Destructive: nukes the
// sentinel/roster/settings too, so the collar needs a re-wear afterward (the
// kmods aren't reset here — only the plugins).
wipesweep(float gap) {
    out("=== WIPESWEEP: full llLinksetDataReset(), then staggered plugin reset ===");
    out("(nukes sentinel/roster/settings/reg — re-wear the collar afterward)");
    llLinksetDataReset();
    sweep(gap);
}

/* -------------------- INJECTOR -------------------- */

inject(string what) {
    if (what == "acl") {
        llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
            "type", "auth.acl.query", "avatar", (string)llGetOwner(), "id", "dbg"]), NULL_KEY);
        out("injected -> [700] auth.acl.query (self); watch tap for auth.acl.result");
    }
    else if (what == "reg") {
        llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
            "type", "kernel.register.refresh"]), NULL_KEY);
        out("injected -> [500] kernel.register.refresh (rebuild registrations/views)");
    }
    else if (what == "reload") {
        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
            "type", "settings.get"]), NULL_KEY);
        out("injected -> [800] settings.get (Reload Settings; clears+restreams card)");
    }
    else if (what == "restream") {
        llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
            "type", "settings.card.restream"]), NULL_KEY);
        out("injected -> [800] settings.card.restream");
    }
    else if (what == "menu") {
        llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
            "type", "ui.menu.start", "context", "ui.core.root"]), llGetOwner());
        out("injected -> [900] ui.menu.start root (self); a menu should open if UI is alive");
    }
    else out("? unknown inject: " + what);
}

/* -------------------- COMMAND DISPATCH (dialog label or console text) ---- */

run_command(string cmd) {
    cmd = llStringTrim(llToLower(cmd), STRING_TRIM);

    if      (cmd == "snapshot")  snapshot();
    else if (cmd == "sentinel")  dump_group("sentinel");
    else if (cmd == "flags")     dump_group("flags");
    else if (cmd == "roster")    dump_group("roster");
    else if (cmd == "scratch")   dump_group("scratch");
    else if (cmd == "reg")       dump_group("reg");
    else if (cmd == "views")     dump_group("views");
    else if (cmd == "leash")     dump_group("leash");
    else if (cmd == "regtest")   regtest();
    else if (cmd == "regwatch")  regwatch();
    else if (cmd == "sweep")     sweep(0.4);
    else if (llSubStringIndex(cmd, "sweep ") == 0) sweep((float)llGetSubString(cmd, 6, -1));
    else if (cmd == "wipesweep") wipesweep(0.4);
    else if (llSubStringIndex(cmd, "wipesweep ") == 0) wipesweep((float)llGetSubString(cmd, 10, -1));
    else if (cmd == "lsd") {
        out("LSD keys = " + (string)llLinksetDataCountKeys()
            + "   free bytes = " + (string)llLinksetDataAvailable()
            + "   (store full == 0 free → writes silently fail)");
    }
    else if (cmd == "tap on")  { TapOn = TRUE;  LastT = llGetTime(); out("tap ON  (verbose=" + (string)TapVerbose + ")"); }
    else if (cmd == "tap off") { TapOn = FALSE; out("tap OFF"); }
    else if (cmd == "verbose") { TapVerbose = !TapVerbose; out("tap verbose=" + (string)TapVerbose); }
    else if (llSubStringIndex(cmd, "hardreset ") == 0) {
        string sn = llGetSubString(cmd, 10, -1);
        llResetOtherScript(sn);
        out("llResetOtherScript('" + sn + "') sent — direct same-prim reset, "
            + "bypasses the script's event queue. (No effect if it's in another prim.)");
    }
    else if (llSubStringIndex(cmd, "reset ") == 0) {
        string ctx = llGetSubString(cmd, 6, -1);
        llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
            "type", "kernel.reset.soft", "context", ctx]), NULL_KEY);
        out("sent kernel.reset.soft to '" + ctx + "' (forces its llResetScript -> state_entry)");
    }
    else if (llSubStringIndex(cmd, "inject ") == 0) inject(llGetSubString(cmd, 7, -1));
    else if (llSubStringIndex(cmd, "dump ")   == 0) dump_group(llGetSubString(cmd, 5, -1));
    else out("? unknown command: " + cmd);
}

/* -------------------- DIALOGS -------------------- */

show_main(key who) {
    Speaker = NULL_KEY;  // dialog-driven: wearer output only
    list b = [
        "Snapshot", "Tap On", "Tap Off",
        "Roster", "Reg", "Views",
        "Flags", "Leash", "Sentinel",
        "Inject", "Verbose", "Scratch"];
    llDialog(who, "DS Collar debugger — pick a probe.\ntap verbose=" + (string)TapVerbose
        + "  tap=" + (string)TapOn, b, DialogChan);
}

show_inject(key who) {
    list b = ["ACL self", "Reg refresh", "Reload card",
              "Restream", "Menu self", "Back"];
    llDialog(who, "Inject a test message onto the lanes:", b, DialogChan);
}

/* -------------------- EVENTS -------------------- */
default {
    state_entry() {
        DialogChan = -1000000 - (integer)llFrand(8000000.0);
        if (DialogListen) llListenRemove(DialogListen);
        DialogListen = llListen(DialogChan, "", llGetOwner(), "");
        if (CmdListen) llListenRemove(CmdListen);
        CmdListen = llListen(DEBUG_CMD_CHAN, "", llGetOwner(), "");
        LastT = llGetTime();
        llOwnerSay("=== DS Collar Swiss debugger armed ===\n"
            + "Type commands in chat, e.g.:  /9090 snapshot   /9090 tap on   "
            + "/9090 inject menu   /9090 inject acl   /9090 dump views");
    }

    touch_start(integer n) {
        show_main(llDetectedKey(0));
    }

    listen(integer channel, string nm, key id, string message) {
        if (channel == DialogChan) {
            if (message == "Inject")       { show_inject(id); return; }
            if (message == "Back")         { show_main(id); return; }
            if (message == "ACL self")     { inject("acl");      return; }
            if (message == "Reg refresh")  { inject("reg");      return; }
            if (message == "Reload card")  { inject("reload");   return; }
            if (message == "Restream")     { inject("restream"); return; }
            if (message == "Menu self")    { inject("menu");     return; }
            run_command(message);
            return;
        }
        if (channel == DEBUG_CMD_CHAN) {
            Speaker = id;          // reply to this console too
            run_command(message);
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (!TapOn) return;
        if (num != KERNEL_LIFECYCLE && num != REMOTE_BUS && num != AUTH_BUS
            && num != SETTINGS_BUS && num != UI_BUS) return;

        float t = llGetTime();
        float d = t - LastT;
        LastT = t;
        string line = "  t=" + fnum(t, 2) + " +" + fnum(d, 2)
            + " [" + lane_name(num) + "] " + label_of(msg);
        if (id != NULL_KEY) line += "  id=" + llGetSubString((string)id, 0, 7);
        llOwnerSay(line);
        if (TapVerbose) llOwnerSay("       " + msg);
    }
}

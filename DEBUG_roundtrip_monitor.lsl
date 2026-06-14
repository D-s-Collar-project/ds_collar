/*--------------------
THROWAWAY DEBUG TOOL — NOT part of the product. DELETE before any build/bundle.

Roundtrip monitor: drop this into the collar (any prim in the linkset — it just
needs to share the link-message bus). It passively prints the settings / auth /
kernel handshake traffic with timing, so you can watch:

  • card stream:  settings.card.restream → settings.card.streamed → settings.sync
                  (+ settings.notecard.loaded)
  • ACL/touch:    auth.acl.query → auth.acl.result   (and auth.acl.update)
  • reset paths:  settings.reset.config, kernel.reset.factory

Usage in-world:
  - Touch the prim holding this script to print a "--- MARK ---" line and zero
    the delta clock, then immediately do the action (touch collar / re-wear /
    Reload Settings / Reset Config) and watch the sequence.
  - Output is llOwnerSay (wearer-only). Flip VERBOSE for ALL bus traffic
    (incl. settings.delta/seed CSV writes); default is the handshake types only.
--------------------*/

integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS         = 700;
integer SETTINGS_BUS     = 800;

// FALSE: only the handshake types in FOCUS below. TRUE: everything on the
// watched buses (noisy — every settings.delta, ACL query, etc.).
integer VERBOSE = FALSE;

// Comma-wrapped on both ends so the membership test matches whole types. Must
// be a single literal — LSL global initializers can't use concatenation.
string FOCUS = ",settings.card.restream,settings.card.streamed,settings.sync,settings.notecard.loaded,settings.get,settings.reset.config,settings.runaway,kernel.reset.factory,kernel.reset.soft,kernel.register.refresh,auth.acl.query,auth.acl.result,auth.acl.update,";

float LastT;

// Pull a readable label out of either a JSON envelope ({"type":...}) or a CSV
// envelope (settings.delta:key:val → "settings.delta:key").
string label_of(string msg) {
    if (llGetSubString(msg, 0, 0) == "{") {
        string t = llJsonGetValue(msg, ["type"]);
        if (t == JSON_INVALID) return "(json,no-type)";
        return t;
    }
    list p = llParseString2List(msg, [":"], []);
    if (llGetListLength(p) >= 2) {
        return llList2String(p, 0) + ":" + llList2String(p, 1);
    }
    return msg;
}

integer interesting(string lbl) {
    if (VERBOSE) return TRUE;
    return (llSubStringIndex(FOCUS, "," + lbl + ",") != -1);
}

// Short fixed-width-ish float for display (no real formatting in LSL).
string fnum(float f, integer places) {
    string s = (string)f;
    integer dot = llSubStringIndex(s, ".");
    if (dot == -1) return s;
    return llGetSubString(s, 0, dot + places);
}

trace(integer num, string msg) {
    string lbl = label_of(msg);
    if (!interesting(lbl)) return;

    float t = llGetTime();
    float d = t - LastT;
    LastT = t;

    llOwnerSay("  t=" + fnum(t, 2) + "  +" + fnum(d, 2)
        + "  [" + (string)num + "] " + lbl);
}

default
{
    state_entry() {
        LastT = llGetTime();
        llOwnerSay("=== roundtrip monitor armed"
            + " (verbose=" + (string)VERBOSE + ") — touch to MARK ===");
    }

    touch_start(integer n) {
        LastT = llGetTime();
        llOwnerSay("--- MARK ---");
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num == KERNEL_LIFECYCLE || num == AUTH_BUS || num == SETTINGS_BUS) {
            trace(num, msg);
        }
    }
}

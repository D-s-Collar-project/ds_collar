/*--------------------
THROWAWAY DEBUG TOOL — NOT part of the product. DELETE before any build/bundle.

Leash + particles monitor: drop into the collar (any prim in the linkset). Taps
the leash<->particles handshake so you can see why particles aren't drawing.

Two channels of traffic:
  • UI_BUS (900) link messages — the leash engine drives the particle renderer:
      leash_engine -> particles:  particles.start / particles.stop /
                                  particles.update / particles.lm.enable /
                                  particles.lm.disable
      particles -> leash_engine:  particles.lm.grabbed / particles.lm.released
      leash state:                plugin.leash.state / plugin.leash.offer.pending
  • Chat -8888 (LEASH_CHAN) — inter-collar + Lockmeister protocol:
      plugin.leash.target / plugin.leash.request (JSON), and the raw LMV2
      "<uuid>|LMV2|RequestPoint|..." / "<uuid>collar|handle" handshake strings.

WHAT TO LOOK FOR (particles not drawn):
  - Clip a leash. You SHOULD see "particles.start" on [900]. If you DON'T, the
    leash engine never told the renderer to draw — problem is upstream in
    kmod_leash_engine (state/target logic), not the renderer.
  - If you DO see "particles.start" but nothing renders, the message arrived and
    the bug is inside kmod_particles (llParticleSystem params / missing texture /
    target key). The monitor can't see inside that call, but it isolates the side.
  - For Lockmeister grabs, watch -8888 for RequestPoint and particles.lm.grabbed.

Usage: touch the prim to print "--- MARK ---" and zero the delta clock, then do
the action. Output is llOwnerSay (wearer-only). Flip VERBOSE for ALL UI_BUS
link traffic; -8888 chat is always shown.
--------------------*/

integer KERNEL_LIFECYCLE = 500;
integer UI_BUS           = 900;
integer LEASH_CHAN       = -8888;

// FALSE: only the leash/particle types in FOCUS. TRUE: every UI_BUS link msg.
integer VERBOSE = FALSE;

// Single literal (LSL global initializers can't concatenate); comma-wrapped so
// the membership test matches whole types.
string FOCUS = ",particles.start,particles.stop,particles.update,particles.lm.enable,particles.lm.disable,particles.lm.grabbed,particles.lm.released,plugin.leash.offer.pending,plugin.leash.state,plugin.leash.target,plugin.leash.request,";

integer ChatListen;
float LastT;

string label_of(string msg) {
    if (llGetSubString(msg, 0, 0) == "{") {
        string t = llJsonGetValue(msg, ["type"]);
        if (t == JSON_INVALID) return "(json,no-type)";
        return t;
    }
    return msg;
}

integer interesting(string lbl) {
    if (VERBOSE) return TRUE;
    return (llSubStringIndex(FOCUS, "," + lbl + ",") != -1);
}

string fnum(float f, integer places) {
    string s = (string)f;
    integer dot = llSubStringIndex(s, ".");
    if (dot == -1) return s;
    return llGetSubString(s, 0, dot + places);
}

string clip(string s) {
    if (llStringLength(s) > 120) return llGetSubString(s, 0, 119) + "…";
    return s;
}

default
{
    state_entry() {
        LastT = llGetTime();
        if (ChatListen) llListenRemove(ChatListen);
        ChatListen = llListen(LEASH_CHAN, "", NULL_KEY, "");
        llOwnerSay("=== leash/particles monitor armed"
            + " (verbose=" + (string)VERBOSE + ") — touch to MARK ===");
    }

    touch_start(integer n) {
        LastT = llGetTime();
        llOwnerSay("--- MARK ---");
    }

    link_message(integer sender, integer num, string msg, key id) {
        if (num != UI_BUS && num != KERNEL_LIFECYCLE) return;
        string lbl = label_of(msg);
        if (!interesting(lbl)) return;

        float t = llGetTime();
        float d = t - LastT;
        LastT = t;
        string idstr = "";
        if (id != NULL_KEY) idstr = "  id=" + llGetSubString((string)id, 0, 7);
        llOwnerSay("  t=" + fnum(t, 2) + "  +" + fnum(d, 2)
            + "  [" + (string)num + "] " + lbl + idstr);
    }

    listen(integer channel, string name, key id, string message) {
        float t = llGetTime();
        float d = t - LastT;
        LastT = t;
        llOwnerSay("  t=" + fnum(t, 2) + "  +" + fnum(d, 2)
            + "  [" + (string)channel + " chat] "
            + llGetSubString((string)id, 0, 7) + ": " + clip(message));
    }
}

/*--------------------
THROWAWAY RECOVERY — release a bricked / locked ds_collar.

Drop into the stuck collar's Contents. Because it runs INSIDE the collar object,
its @clear drops every RLV restriction THIS collar issued — including @detach=n —
so you can take the collar off. It also clears the persisted lock flag so a
recovered collar won't immediately re-lock. Touch to re-run. DELETE when done.
--------------------*/
release() {
    // Drop every RLV restriction this collar issued (incl. @detach=n).
    llOwnerSay("@clear");
    // Clear the persisted lock flag (0 = unlocked).
    llLinksetDataWrite("lock.locked", "0");
    llOwnerSay("RECOVERY: RLV cleared (@clear) + lock.locked=0 — you can detach the collar now.");
}

default {
    state_entry() {
        release();
    }

    touch_start(integer n) {
        release();
    }
}

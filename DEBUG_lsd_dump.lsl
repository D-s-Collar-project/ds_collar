/*--------------------
THROWAWAY DIAGNOSTIC — ds_collar v1.1 -> v1.2 update brick.

Drop this into the BRICKED collar's Contents. LinksetData is shared across the
linkset, so it dumps the collar's live LSD config + the "settings" notecard
lines straight to you (owner-only). Touch the collar to re-run. DELETE when done.

Tells us: is the v1.1 owner data still in access.*? did any user.* records get
built? is settings.cardapplied stuck? and does the card itself carry an owner.
--------------------*/

integer gLine;
key     gQuery;

dump_key(string k) {
    llOwnerSay("  " + k + " = " + llLinksetDataRead(k));
}

dump_ns(string label, string pat) {
    list ks = llLinksetDataFindKeys(pat, 0, -1);
    integer n = llGetListLength(ks);
    llOwnerSay("-- " + label + " (" + (string)n + ") --");
    if (n == 0) {
        llOwnerSay("  (none)");
        return;
    }
    integer i = 0;
    while (i < n) {
        string k = llList2String(ks, i);
        llOwnerSay("  " + k + " = " + llLinksetDataRead(k));
        i += 1;
    }
}

dump_lsd() {
    llOwnerSay("===== LSD DUMP =====");
    dump_ns("access.*",    "^access\\.");
    dump_ns("user.*",      "^user\\.");
    dump_ns("settings.*",  "^settings\\.");
    dump_ns("blacklist.*", "^blacklist\\.");
    dump_key("lock.locked");
    list allk = llLinksetDataFindKeys("", 0, -1);
    llOwnerSay("-- total LSD keys: " + (string)llGetListLength(allk) + " --");
}

read_card() {
    if (llGetInventoryType("settings") != INVENTORY_NOTECARD) {
        llOwnerSay("===== NO 'settings' notecard in Contents =====");
        return;
    }
    llOwnerSay("===== 'settings' CARD CONTENTS =====");
    gLine  = 0;
    gQuery = llGetNotecardLine("settings", gLine);
}

default {
    state_entry() {
        dump_lsd();
        read_card();
    }

    touch_start(integer n) {
        dump_lsd();
        read_card();
    }

    dataserver(key q, string data) {
        if (q != gQuery) return;
        if (data == EOF) {
            llOwnerSay("===== END CARD =====");
            return;
        }
        llOwnerSay("  [" + (string)gLine + "] " + data);
        gLine  += 1;
        gQuery  = llGetNotecardLine("settings", gLine);
    }
}

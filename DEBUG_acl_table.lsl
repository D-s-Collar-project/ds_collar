/*--------------------
THROWAWAY DEBUG TOOL — NOT part of the product. DELETE before any build/bundle.

ACL TABLE MONITOR. Drop into the collar (any prim — it shares the link bus).
Tests the hypothesis "ACL is a table you read, not a value you compute": for
every ACL resolution it puts the COMPUTED level (kmod_auth's auth.acl.result)
next to the STORED user.<uuid> record's leading acl field, and flags agreement.

  • ROSTER actor (owner/trustee/blacklist — has a user.<uuid> record): stored vs
    computed should ALWAYS match. Every match is evidence the record IS the
    source of truth and the auth ladder is re-deriving a stored fact.
  • WEARER / STRANGER: no record — derived from access.isowned / tpe.mode /
    public.mode. These are the only cases a FULL table model would still need to
    absorb (a kept-current wearer row + one public default row).

A *** MISMATCH *** line is the thing to hunt: it means the record and the
computation disagree, i.e. the table can't yet be trusted as the sole source.

Usage:
  - Passive: every menu touch fires an ACL query; watch the compare lines.
  - Touch THIS prim: dumps the roster table + the three flags, then queries the
    toucher's own acl (compare line comes back on the bus).
  Output is llOwnerSay (wearer-only).
--------------------*/

integer AUTH_BUS = 700;

integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

string acl_name(integer lvl) {
    if (lvl == ACL_BLACKLIST)     return "BLACKLIST(-1)";
    if (lvl == ACL_NOACCESS)      return "NOACCESS(0)";
    if (lvl == ACL_PUBLIC)        return "PUBLIC(1)";
    if (lvl == ACL_OWNED)         return "OWNED(2)";
    if (lvl == ACL_TRUSTEE)       return "TRUSTEE(3)";
    if (lvl == ACL_UNOWNED)       return "UNOWNED(4)";
    if (lvl == ACL_PRIMARY_OWNER) return "PRIMARY(5)";
    return "?(" + (string)lvl + ")";
}

string short8(string s) { return llGetSubString(s, 0, 7); }

// Put the computed level next to the stored record for one avatar.
report(string avatar, integer computed) {
    string rec = llLinksetDataRead("user." + avatar);

    string klass = "STRANGER";
    if ((key)avatar == llGetOwner()) klass = "WEARER";
    else if (rec != "") klass = "ROSTER";

    if (rec != "") {
        integer stored = (integer)rec;   // record = "acl,rank,name,honorific"
        string verdict = "match";
        if (stored != computed) verdict = "*** MISMATCH ***";
        llOwnerSay("ACL " + short8(avatar) + " [" + klass + "]  computed="
            + acl_name(computed) + "  record=" + acl_name(stored) + "  " + verdict);
    }
    else {
        llOwnerSay("ACL " + short8(avatar) + " [" + klass + "]  computed="
            + acl_name(computed) + "  record=NONE  (derived from flags)");
    }
}

dump_table() {
    llOwnerSay("--- roster table (user.* records) ---");
    list ks = llLinksetDataFindKeys("^user\\.", 0, -1);
    integer n = llGetListLength(ks);
    if (n == 0) llOwnerSay("   (empty — no named actors; every acl is derived)");
    integer i = 0;
    while (i < n) {
        string k = llList2String(ks, i);
        string rec = llLinksetDataRead(k);
        llOwnerSay("   " + short8(llGetSubString(k, 5, -1)) + "..  acl="
            + acl_name((integer)rec) + "  rec=" + rec);
        i += 1;
    }
    llOwnerSay("--- flags (the wearer/stranger derivation inputs) ---");
    llOwnerSay("   access.isowned=" + llLinksetDataRead("access.isowned")
        + "  tpe.mode=" + llLinksetDataRead("tpe.mode")
        + "  public.mode=" + llLinksetDataRead("public.mode"));
}

default {
    state_entry() {
        llOwnerSay("=== ACL table monitor armed — touch to dump table + query self ===");
    }

    touch_start(integer num_det) {
        key toucher = llDetectedKey(0);
        dump_table();
        llOwnerSay("querying acl for toucher " + short8((string)toucher) + " ...");
        llMessageLinked(LINK_SET, AUTH_BUS, llList2Json(JSON_OBJECT, [
            "type",   "auth.acl.query",
            "avatar", (string)toucher,
            "id",     "acltrace"
        ]), NULL_KEY);
    }

    link_message(integer sender, integer chan, string msg, key id) {
        if (chan != AUTH_BUS) return;
        string t = llJsonGetValue(msg, ["type"]);
        if (t == "auth.acl.result") {
            report(llJsonGetValue(msg, ["avatar"]), (integer)llJsonGetValue(msg, ["level"]));
        }
        else if (t == "auth.acl.update") {
            llOwnerSay(">>> auth.acl.update (roster/flags changed — table re-derives next query)");
        }
    }
}

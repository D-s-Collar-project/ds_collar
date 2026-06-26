/*--------------------
THROWAWAY DEBUG TOOL — NOT part of the product. DELETE before any build/bundle.

UI BUTTON / CONTEXT MONITOR. Drop into the collar (any prim — shares the link
bus). Traces the whole menu chain on UI_BUS (900) + DIALOG_BUS (950) with a
delta clock, so a UI stall shows up as a BROKEN chain. Pair it with
DEBUG_acl_table: run both and watch whether an auth.acl recompute lands exactly
where the button/context chain stops.

Healthy interaction (one click) looks like:
  RESP   (the click)            session S, button "Foo", context "cat:Foo"
  RENDER (the re-draw)          session S, menu_type/category, buttons
  OPEN   (handed to dialogs)    session S, button=context pairs

A STALL looks like one of:
  • RESP with no following RENDER  → kmod_ui swallowed/ignored the click
  • RENDER with no following OPEN  → kmod_menu didn't forward it
  • a TIMEOUT line ~60s later      → the session was stranded (the classic hang)

Touch THIS prim = "--- MARK ---" + zero the clock, then do the failing action.
Output is llOwnerSay (wearer-only).
--------------------*/

integer UI_BUS     = 900;
integer DIALOG_BUS = 950;

float LastT;

string jv(string msg, string field) {
    string v = llJsonGetValue(msg, [field]);
    if (v == JSON_INVALID) return "";
    return v;
}

string clip(string s, integer n) {
    integer len = llStringLength(s);
    if (len > n) return llGetSubString(s, 0, n - 1) + " …(+" + (string)(len - n) + ")";
    return s;
}

// Compact "label=context|label=context" from button_data, "label|label" from a
// plain buttons array, OR "name|name" from a picker's items array (menu.ordered
// /unordered send `items`, NOT `buttons` — the original tool missed this and
// printed "(no buttons)", hiding exactly the empty-picker case). Truncated for
// sanity on big menus.
string btn_summary(string msg) {
    string bd = llJsonGetValue(msg, ["button_data"]);
    if (bd != JSON_INVALID) {
        list items = llJson2List(bd);
        integer n = llGetListLength(items);
        list pairs = [];
        integer i = 0;
        while (i < n && i < 14) {
            string it = llList2String(items, i);
            pairs += (jv(it, "label") + "=" + jv(it, "context"));
            i += 1;
        }
        return "btn_data " + (string)n + ":[" + clip(llDumpList2String(pairs, " | "), 500) + "]";
    }
    string b = llJsonGetValue(msg, ["buttons"]);
    if (b != JSON_INVALID) {
        list items = llJson2List(b);
        return "buttons " + (string)llGetListLength(items) + ":[" + clip(llDumpList2String(items, " | "), 500) + "]";
    }
    string it2 = llJsonGetValue(msg, ["items"]);
    if (it2 != JSON_INVALID) {
        list items = llJson2List(it2);
        return "items " + (string)llGetListLength(items) + ":[" + clip(llDumpList2String(items, " | "), 500) + "]";
    }
    return "(no buttons/items)";
}

// Short fixed-ish float (LSL has no real number formatting).
string fnum(float f) {
    string s = (string)f;
    integer dot = llSubStringIndex(s, ".");
    if (dot == -1) return s;
    return llGetSubString(s, 0, dot + 2);
}

emit(string tag, string detail) {
    float t = llGetTime();
    float d = t - LastT;
    LastT = t;
    llOwnerSay("  +" + fnum(d) + "  " + tag + "  " + detail);
}

default {
    state_entry() {
        LastT = llGetTime();
        llOwnerSay("=== UI flow monitor armed (render/open/resp/timeout) — touch to MARK ===");
    }

    touch_start(integer num_det) {
        LastT = llGetTime();
        llOwnerSay("--- MARK ---");
    }

    link_message(integer sender, integer chan, string msg, key id) {
        if (chan != UI_BUS && chan != DIALOG_BUS) return;
        string t = llJsonGetValue(msg, ["type"]);
        if (t == JSON_INVALID) return;

        string sess = jv(msg, "session_id");

        if (t == "ui.dialog.response") {
            emit("RESP  ", "sess=" + sess + "  btn=\"" + jv(msg, "button")
                + "\"  ctx=" + jv(msg, "context"));
        }
        else if (t == "ui.menu.render") {
            emit("RENDER", "sess=" + sess + "  mode=" + jv(msg, "mode")
                + "  type=" + jv(msg, "menu_type") + "  page=" + jv(msg, "page")
                + "  " + btn_summary(msg));
        }
        else if (t == "ui.dialog.open") {
            emit("OPEN  ", "sess=" + sess + "  title=\"" + jv(msg, "title")
                + "\"  " + btn_summary(msg));
        }
        else if (t == "ui.dialog.timeout") {
            emit("TIMEOUT", "sess=" + sess + "  <-- session expired (this is the hang)");
        }
        else if (t == "ui.menu.start") {
            emit("START ", "sess=" + sess + "  ctx=" + jv(msg, "context")
                + "  user=" + llGetSubString(jv(msg, "user"), 0, 7));
        }
        else if (t == "ui.menu.return") {
            emit("RETURN", "sess=" + sess + "  ctx=" + jv(msg, "context"));
        }
        else if (t == "ui.menu.close") {
            emit("CLOSE ", "sess=" + sess);
        }
    }
}

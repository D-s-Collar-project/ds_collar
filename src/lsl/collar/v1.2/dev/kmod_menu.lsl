/*--------------------
MODULE: kmod_menu.lsl
VERSION: 1.2
REVISION: 22
CHANGES:
- v1.2 rev 22: fixed actions are now ACL-gated + never leak. (1) LEAK FIX: handle_sensor_request clears PickerFixed (menu.sensor was inheriting a prior menu.picker's fixed buttons — e.g. animate's [Stop]/[Close] bled onto the force-sit picker). (2) ACL GATE: `fixed` rows gain a mask -> "context\tlabel\tslot\tmask", and the request carries the toucher's `acl`; render_picker (pass 1) shows a fixed button only if bit `acl` of its mask is set, otherwise that slot rejoins the content pool as a normal candidate button. page_size shrinks only for fixed buttons that ACTUALLY show. Mask absent -> visible to all (back-compat).
- v1.2 rev 21: explicit-slot fixed actions. menu.picker `fixed` rows are "context\tlabel\tslot"; render_picker pins each fixed button to its declared dialog slot (3..11) and fills the LEFTOVER slots with candidates in reading order — so a picker can flank content with actions (e.g. [Stop]@3 . anim@4 . [Close]@5) instead of packing them contiguously low. No-fixed pickers (menu.sensor) render identically to before.
- v1.2 rev 20: DISAMBIGUATION bump — the menu.picker wire contract changed WITHIN rev 19 (parallel labels/keys -> single `items` key-first rows) without a rev bump, so an in-world rev-19 kmod_menu silently mismatched a plugin sending `items` (parsed n=0 -> "Nothing to select"). Current: `items` = "key\tlabel\n...". Also added page round-tripping (optional `page` in the request, current `page` returned in the result, so re-opening after a pick lands on the same page). TEMP [picker] diagnostic removed.
- v1.2 rev 19: delimited button transport + central picker (kmod_dialogs rev 8). (1) Every button is a "context\tlabel" row (btn_row, was nav_obj); render_paged/modal/info emit "button_rows" (\n-joined) not a JSON button_data array — no llList2Json ever encodes a label, so [ ] { } ride through intact. Context-FIRST because a JSON value leading with [ or { poisons llList2Json; the rows string starts with a nav context. Incoming `fixed`/`buttons` JSON still converted to rows here (bridge). (2) New menu.picker mode: plugin sends {items,fixed?,shape?,title,prompt} where items = key-first rows "key\tlabel\n..." (key leads each row so the field never [/{-leads; label sits mid-value) and fixed = optional action rows "context\tlabel\n..."; we own the list + paging + resolve and reply ui.menu.picker.result {context} (context = picked key or fixed-action context; cancelled -> {cancelled}). Generalises menu.sensor — both render via render_picker (delimited, real brackets) and route by pick:<index> uniformly (dropped the UUID-only (key)-cast). json_safe DELETED. ui.sensor.result name is lead_safe'd against leading-bracket poison. Legacy menu.unordered/ordered still route via render_paged (removed after the 7 pickers migrate).
- v1.2 rev 18: FIX — a sensor picker still collapsed to one blank box when a candidate name CONTAINED a '[' or '{' (e.g. "[Ds] Chesterfield…", "HUD-Foo 2.0 [FULL PERMS]…"). The rev-17 {label}-wrap only protected a name that WAS a bare '[…]' element; LSL's JSON array/object splitters don't skip brackets inside a quoted value, so a bracket within the name still mis-tracked nesting and JSON_INVALID-collapsed the array (rendered as a single blank box). New json_safe() neutralises [ ] { } in the DISPLAY name only ([]→(), {}→()); pickers return keys / pick-indices and the result name comes from SensorCands, so the real name is unaffected. NOTE: plugin-side pickers (blacklist/animate/outfits/owners/folders/leash/strip) build their own items and carry the same latent bug — they need the same json_safe on display strings.
- v1.2 rev 17: new menu.sensor picker mode — a scan-and-pick service. A plugin sends ui.menu.render {mode:"menu.sensor",kind,range,title,prompt,requester,user}; kmod_menu owns the llSensor + sensor()/no_sensor() + the picker session + the pick->key resolve, and replies ui.sensor.result {requester,name,key}|{cancelled}. Render shape keys off kind: objects->OL (object key), agents->UL (avatar key), collars->scan collars + resolve OBJECT_OWNER deduped->UL (avatar key, so coffle is leash-to-avatar). Centralising the scan also centralises the JSON-safe {label} build, so a candidate name beginning with '[' or '{' can never collapse the array (the picker-empty bug, fixed once for all sensor pickers). kmod_menu is no longer stateless (holds the single-flight scan session); it now also listens on DIALOG_BUS for its own picker session only. First consumer: plugin_restrict force-sit.
- v1.2 rev 16: render unified — render_menu + render_list collapse into one render_paged(shape) covering the four menu.x shapes (fixed/pager/unordered/ordered); dialog.modal flanked to [No, spacer, Yes]; dispatch switches the six explicit menu.x / dialog.x modes (bare-name transition aliases dropped).
- v1.2 rev 15: the pager (render_menu) now accepts the optional `fixed` action-button list, like render_list — fixed buttons reserve the low slots right after nav and page_size shrinks by the fixed count. A blank spacer ({label:" ",context:""}) among the fixed buttons positions them (plugin_leash's length menu uses [-1m," ",+1m] to flank -1m/+1m at slots 3 and 5). Menus that send no `fixed` are unchanged (page_size stays PAGE_SIZE).
- v1.2 rev 14: nav buttons now carry contexts (nav:prev/nav:next/nav:back/nav:close) via the new btn_row() helper — in render_menu + render_list — instead of bare label strings. The dialog layer already context-routes {label,context} objects, so consumers route nav by context like every other button (no more label-routing exception); the visible label is now free to restyle (e.g. UTF-8 arrows) with zero routing impact.
- v1.2 rev 13: added the INFO mode (render_info) — a terminal informational dialog: title + body + a single OK button (context "ok"), NO nav row (info dialogs are not navigable menus, so they deliberately skip the << >> Back row). ok_label optional (default "OK"). First consumer: plugin_status. Other view-only displays (e.g. blacklist's list) can adopt it.
- v1.2 rev 12: merged render_unordered + render_ordered into one render_list(msg, isOrdered) — they shared ~70% boilerplate (validate, reserve nav+fixed, page-math, layout_buttons, forward). isOrdered drives the only differences: UL(0) A-Z-sorts + names the buttons + returns context; OL(1) preserves order + numbers the buttons + appends a numbered body + returns pick:<index>. Wire stays descriptive: mode "unordered"/"ordered" dispatch to render_list(msg, FALSE/TRUE). OL's fix0/fix1 fields fold into the shared `fixed` list (no OL consumer used them). No behavior change for animate (UL) or blacklist (OL).
- v1.2 rev 11: (1) UNORDERED mode now accepts {label,context} items (not just flat names) — sorts by label, returns the context, so a people-picker can show the name but return the UUID (no name-collision / truncation risk); flat-name items (animate) still work (label==context). (2) Added the MODAL mode (render_modal): forced Yes/No, NO nav row, No/cancel always at slot 0 (enforced in the service), rendered to an arbitrary target; returns context confirm/cancel. For plugin_owners (UL scans + modal confirms).
- v1.2 rev 10: added the ORDERED picker mode (render_ordered). Items keep caller order, numbered 1..N (page-relative) as index buttons + a matching numbered body; context "pick:<global-index>". Nav (<<,>>,Back) + optional fixed action buttons (fix0/fix1, policy pre-checked by the plugin) reserve the low slots; content packs above them via the shared layout_buttons — NO padding (page_size = 12 - reserved). First consumer: plugin_blacklist (remove + add-scan). NOTE: a "flanking" fixed-button layout (fixed buttons straddling content) would need partial-page padding, which this system forbids — deferred until a fixed-button OL consumer exists.
- v1.2 rev 9: ui.menu.render is now mode-switched (default "pager"). Added the UNORDERED picker mode (render_unordered): caller sends a flat `items` name list + optional `fixed` buttons; the service A-Z-sorts, pages (page_size = 12 - 3 nav - fixed_count), builds name-buttons, and lays out via the shared layout_buttons. First consumer: plugin_animate (sheds its hand-rolled slot map + inventory-order list → alphabetized). Pager path unchanged.
- v1.2 rev 8: replaced reverse_complete_rows/reorder_buttons_for_display with the CANONICAL reverse-map layout_buttons (proven in plugin_animate/plugin_leash/plugin_leash_target). The old reverse-complete-rows was correct for whole rows + tiny partials but SCRAMBLED "full rows + a partial" (e.g. 4 content items read b3,b0,b1,b2) — root/category dodged it by being small; pickers would hit it every page. layout_buttons places nav at the low slots and fills content into reading-order slots [9,10,11,6,7,8,3,4,5,0,1,2]; correct for every count. This is the single layout law all menu modes will share.
- v1.2 rev 7: the menu service now OWNS paging. render_menu takes the caller's FULL button list + a page index and slices the page itself (PAGE_SIZE, cross-module with kmod_ui MAX_FUNC_BTNS) instead of receiving a pre-sliced page + total_pages. Same slot layout/nav/title-pagination; callers stop slicing. Foundation for uniform paging across menu + picker shapes — no plugin re-implements page slicing.
- v1.2 rev 6: revision baseline normalized to rev 6 (no functional change this rev).
- v1.2 rev 1: Drop the empty state_entry (stateless renderer; other handlers satisfy the at-least-one-event rule) — clears the empty-event-body analyzer hint.
PURPOSE: Menu rendering and visual presentation service
ARCHITECTURE: Consolidated message bus lanes
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;
integer DIALOG_BUS = 950;

/* -------------------- CONTEXT CONSTANTS -------------------- */
// Must match ROOT_CONTEXT / SOS_CONTEXT in kmod_ui.lsl, control_hud.lsl, kmod_remote.lsl
string ROOT_CONTEXT = "ui.core.root";
string SOS_CONTEXT  = "ui.sos.root";

// llDialog is a 3x4 grid — MENU_SLOTS button slots total. Content capacity is
// MENU_SLOTS minus the reserved low slots (nav + any fixed action buttons), so a
// standard 3-nav menu holds 9 content buttons — which kmod_ui's MAX_FUNC_BTNS
// must match (cross-module contract).
integer MENU_SLOTS = 12;

// menu.* render shapes — all flow through the one render_paged():
integer SHAPE_FIXED = 0;  // [Close . - . Back], single page (never paginates)
integer SHAPE_PAGER = 1;  // [<< . >> . exit], paginates
integer SHAPE_UL    = 2;  // unordered picker: A-Z sort, name on the button
integer SHAPE_OL    = 3;  // ordered picker: number on the button + numbered body
integer UL_MAX      = 24; // menu.picker auto-shape: all labels <= this -> UL, else OL

/* -------------------- PICKER (menu.sensor + menu.picker) -------------------- */
// One scan/list-and-pick service, single-flight, sharing all state below.
//   menu.sensor {kind,range,title,prompt,requester,user} — we own the llSensor,
//     build candidates from the scan, and reply ui.sensor.result {name,key}.
//   menu.picker {items,fixed?,shape?,page?,acl?,title,prompt,requester,user} — the
//     plugin provides candidates as key-first rows "key\tlabel\n..." (key = its
//     own routing token: an index or a UUID; it leads each row so the field value
//     is never [ / { -led) plus optional fixed action rows "context\tlabel\tslot\tmask"
//     (each pinned to slot 3..11, shown only if bit `acl` of mask is set, else the
//     slot becomes a normal candidate button); we reply ui.menu.picker.result
//     {context,page} — context is the picked key or a fixed-action context
//     (cancelled -> {cancelled}).
// Either way we own the picker session + paging + the pick resolve. BOTH UL and
// OL route by pick:<absolute-index> into SensorCands (uniform); the shape only
// changes DISPLAY (UL = name on the button; OL = number + numbered body). No JSON
// touches a label on the render path, so names show their real [ ] { }.
integer SensorActive    = FALSE;
integer PickerProvided  = FALSE; // TRUE = menu.picker (plugin list); FALSE = menu.sensor (scan)
list    PickerFixed     = [];    // menu.picker fixed action rows "context\tlabel\tslot\tmask"
integer PickerAcl       = 0;     // toucher's ACL level — gates which fixed buttons show
string  SensorRequester = "";   // plugin context to return the result to
string  SensorUserStr   = "";   // (string) of the driving avatar
string  SensorKind      = "";   // "objects" | "agents" | "collars"
string  SensorTitle     = "";
string  SensorPrompt    = "";
integer SensorShape     = 2;    // SHAPE_UL or SHAPE_OL
string  SensorSession   = "";   // dialog session id for the picker
integer SensorPage      = 0;
list    SensorCands     = [];   // resolved stride list [label, keyval, ...]

/* -------------------- HELPERS -------------------- */

string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
}

integer validate_required_fields(string json_str, list field_names) {
    integer i = 0;
    integer len = llGetListLength(field_names);
    while (i < len) {
        string field = llList2String(field_names, i);
        if (llJsonGetValue(json_str, [field]) == JSON_INVALID) {
            return FALSE;
        }
        i += 1;
    }
    return TRUE;
}

// A JSON value must not LEAD with [ or { — llList2Json auto-types it as nested
// JSON and returns JSON_INVALID for the whole message if it isn't valid. Brackets
// elsewhere in a value are fine. Used only for the ui.sensor.result `name` echo
// (routing is by key, so swapping a leading bracket for a paren is display-only).
// The picker DISPLAY never needs this — button_rows is delimited, not JSON.
string lead_safe(string s) {
    string c = llGetSubString(s, 0, 0);
    if (c == "[" || c == "{") return "(" + llGetSubString(s, 1, -1);
    return s;
}

/* -------------------- BUTTON LAYOUT (canonical reverse-map) -------------------- */

// llDialog fills its 3-wide grid bottom-left → top-right, so a naive button
// list reads UPWARD and backwards to a human. This is the project's canonical
// reverse-layout — proven in plugin_animate / plugin_leash / plugin_leash_target
// and shared, byte-identical, by every menu mode. nav/fixed buttons take the
// low slots 0..nav_count-1 (physical bottom row, left); content fills the
// remaining slots walked in VISUAL reading order (top row first, L→R) so the
// list reads top-to-bottom, L→R. Requires nav_count in 1..3 and
// nav_count + content_count <= 12 (PAGE_SIZE 9 + 3 nav). Every placeholder is
// replaced — no filler survives in the output.
list layout_buttons(list nav_buttons, list content_buttons) {
    integer nav_count     = llGetListLength(nav_buttons);
    integer content_count = llGetListLength(content_buttons);
    integer total         = nav_count + content_count;

    // Slot indices in visual top-to-bottom, L→R reading order. Keep only the
    // slots that fit within `total` and aren't reserved for nav — that set is
    // exactly the integers [nav_count, total), so every content item lands and
    // no slot is left blank.
    list reading_order = [9, 10, 11, 6, 7, 8, 3, 4, 5, 0, 1, 2];
    list slots = [];
    integer ri = 0;
    while (ri < 12) {
        integer rs = llList2Integer(reading_order, ri);
        if (rs < total && rs >= nav_count) slots += [rs];
        ri += 1;
    }

    list final_buttons = nav_buttons;
    integer p = 0;
    while (p < content_count) { final_buttons += [" "]; p += 1; }

    integer i = 0;
    while (i < content_count) {
        integer slot = llList2Integer(slots, i);
        final_buttons = llListReplaceList(final_buttons,
            [llList2String(content_buttons, i)], slot, slot);
        i += 1;
    }
    return final_buttons;
}

// Build a routable button as a delimited "label\tcontext" row. Every button —
// nav (nav:prev/next/back/close), content, fixed — is this shape, so the dialog
// layer splits on \t and consumers route by CONTEXT, never by the visible label
// (label stays free to restyle, e.g. UTF-8 arrows). A dialog label can contain
// neither tab nor newline, so a label with [ ] { } rides through intact — no JSON
// ever touches a label on the render path.
string btn_row(string label, string ctx) {
    return ctx + "\t" + label;
}

/* -------------------- RENDERING -------------------- */

// ====================== UNIFIED NAVIGABLE RENDERER (menu.*) ======================
// The four menu.* shapes share ONE process: reserve the bottom slots (nav +
// optional fixed action buttons), lay content above them via the canonical
// layout_buttons reverse-map, page if the shape paginates, forward to DIALOG_BUS.
// Only two things vary by shape — the NAV ROW and how the CONTENT BUTTONS are
// produced from the input:
//   SHAPE_FIXED — [Close . - . Back], single page (caller guarantees it fits);
//                 content = the caller's pre-built `buttons`.
//   SHAPE_PAGER — [<< . >> . exit] (exit = Close at root / Back in a category;
//                 has_nav=0 → a lone exit). Paginates. content = `buttons`.
//   SHAPE_UL    — [<< . >> . Back]. Paginates. content from raw `items`, A-Z
//                 sorted, NAME on the button, click returns the item's context.
//   SHAPE_OL    — [<< . >> . Back]. Paginates. content from raw `items` in caller
//                 order, NUMBER on the button + a numbered body line, click
//                 returns pick:<global-index> (for names that overflow a button).
render_paged(string msg, integer shape) {
    if (!validate_required_fields(msg, ["user", "session_id"])) return;

    key user = (key)llJsonGetValue(msg, ["user"]);
    string session_id = llJsonGetValue(msg, ["session_id"]);
    integer current_page = (integer)llJsonGetValue(msg, ["page"]);

    string category = "";
    string cat_tmp = llJsonGetValue(msg, ["category"]);
    if (cat_tmp != JSON_INVALID) category = cat_tmp;

    // ---- nav row (per-shape difference #1) ----
    list nav;
    if (shape == SHAPE_FIXED) {
        // Two-sided: Close (leave the menu system) + inert spacer + Back (up one
        // level). A fixed menu frees the << >> slots, which pays for showing both.
        nav = [btn_row("Close", "nav:close"), btn_row("-", ""), btn_row("Back", "nav:back")];
    }
    else if (shape == SHAPE_PAGER) {
        // Exit is Close at the root tier (ends the session) and Back inside a
        // category (pops to root). has_nav=0 → a lone exit (no << >>).
        string exit_obj = btn_row("Close", "nav:close");
        if (category != "") exit_obj = btn_row("Back", "nav:back");
        nav = [exit_obj];
        if ((integer)llJsonGetValue(msg, ["has_nav"])) {
            nav = [btn_row("<<", "nav:prev"), btn_row(">>", "nav:next"), exit_obj];
        }
    }
    else {
        nav = [btn_row("<<", "nav:prev"), btn_row(">>", "nav:next"), btn_row("Back", "nav:back")];
    }

    // ---- optional fixed action buttons (any shape; e.g. leash length's ±1m) ----
    // Still arrive as a JSON array of {label,context} objects; convert each to a
    // context-first delimited row (fixed labels are controlled, bracket-free).
    list fixed = [];
    string fixed_json = llJsonGetValue(msg, ["fixed"]);
    if (fixed_json != JSON_INVALID) {
        list fj = llJson2List(fixed_json);
        integer fn = llGetListLength(fj);
        integer fi = 0;
        while (fi < fn) {
            string fel = llList2String(fj, fi);
            string flabel = llJsonGetValue(fel, ["label"]);
            string fctx = llJsonGetValue(fel, ["context"]);
            if (flabel == JSON_INVALID) flabel = fel;
            if (fctx == JSON_INVALID) fctx = "";
            fixed += [btn_row(flabel, fctx)];
            fi += 1;
        }
    }
    list reserved = nav + fixed;
    integer page_size = MENU_SLOTS - llGetListLength(reserved);
    if (page_size < 1) page_size = 1;

    // ---- content source + count (per-shape difference #2, part A) ----
    // Button shapes (fixed/pager) take a pre-built `buttons` array; list shapes
    // (UL/OL) take raw `items` parsed into a [label,context] stride table.
    integer is_list = (shape == SHAPE_UL || shape == SHAPE_OL);
    list full_buttons;
    list pairs;
    integer item_count;
    if (is_list) {
        list raw = llJson2List(llJsonGetValue(msg, ["items"]));
        integer ri = 0;
        integer rn = llGetListLength(raw);
        while (ri < rn) {
            string it = llList2String(raw, ri);
            string lbl = llJsonGetValue(it, ["label"]);
            string ctx;
            if (lbl == JSON_INVALID) { lbl = it; ctx = it; }   // flat string: label IS the value
            else {
                ctx = llJsonGetValue(it, ["context"]);
                if (ctx == JSON_INVALID) ctx = lbl;
            }
            pairs += [lbl, ctx];
            ri += 1;
        }
        // UL sorts A-Z by label; OL preserves the caller's order.
        if (shape == SHAPE_UL && llGetListLength(pairs) > 2) {
            pairs = llListSortStrided(pairs, 2, 0, TRUE);
        }
        item_count = llGetListLength(pairs) / 2;
    }
    else {
        // `buttons` arrives as a JSON array of {label,context} objects (menu
        // category/action buttons); convert each to a context-first row.
        string buttons_json = llJsonGetValue(msg, ["buttons"]);
        if (buttons_json != JSON_INVALID) {
            list bj = llJson2List(buttons_json);
            integer bn = llGetListLength(bj);
            integer bi = 0;
            while (bi < bn) {
                string bel = llList2String(bj, bi);
                string blabel = llJsonGetValue(bel, ["label"]);
                string bctx = llJsonGetValue(bel, ["context"]);
                if (blabel == JSON_INVALID) blabel = bel;
                if (bctx == JSON_INVALID) bctx = "";
                full_buttons += [btn_row(blabel, bctx)];
                bi += 1;
            }
        }
        item_count = llGetListLength(full_buttons);
    }

    // ---- page math (fixed never paginates: one page, no slice, no counter) ----
    integer total_pages = 1;
    integer pstart = 0;
    integer pend = item_count;
    if (shape != SHAPE_FIXED) {
        total_pages = (item_count + page_size - 1) / page_size;
        if (total_pages < 1) total_pages = 1;
        if (current_page >= total_pages) current_page = 0;
        if (current_page < 0) current_page = total_pages - 1;
        pstart = current_page * page_size;
        pend = pstart + page_size;
        if (pend > item_count) pend = item_count;
    }

    // ---- body (default up front; OL appends numbered lines below) ----
    string body_text = llJsonGetValue(msg, ["body"]);
    if (body_text == JSON_INVALID) {
        if (shape == SHAPE_PAGER && llJsonGetValue(msg, ["menu_type"]) == SOS_CONTEXT) {
            body_text = "Emergency options:";
        }
        else body_text = "Select an option:";
    }

    // ---- build the page's content buttons (per-shape difference #2, part B) ----
    list content;
    if (is_list) {
        integer i = pstart;
        while (i < pend) {
            string lbl = llList2String(pairs, i * 2);
            if (shape == SHAPE_OL) {
                string num = (string)(i - pstart + 1);
                content += [btn_row(num, "pick:" + (string)i)];
                body_text += "\n" + num + ". " + lbl;
            }
            else {
                content += [btn_row(lbl, llList2String(pairs, i * 2 + 1))];
            }
            i += 1;
        }
    }
    else if (item_count > 0) {
        content = llList2List(full_buttons, pstart, pend - 1);
    }

    list final_button_data = layout_buttons(reserved, content);

    // ---- title (pager derives from category/menu_type; + page counter) ----
    string title = llJsonGetValue(msg, ["title"]);
    if (title == JSON_INVALID) {
        if (shape == SHAPE_PAGER && category != "") {
            title = category;
        }
        else if (shape == SHAPE_PAGER) {
            string menu_type = llJsonGetValue(msg, ["menu_type"]);
            if (menu_type == ROOT_CONTEXT) title = "Main Menu";
            else if (menu_type == SOS_CONTEXT) title = "Emergency Menu";
            else title = "Menu";
        }
        else title = "Menu";
    }
    if (total_pages > 1) {
        title = title + " (" + (string)(current_page + 1) + "/" + (string)total_pages + ")";
    }

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", session_id,
        "user", (string)user,
        "title", title,
        "body", body_text,
        "button_rows", llDumpList2String(final_button_data, "\n"),
        "timeout", 60
    ]), NULL_KEY);
}

// dialog.modal: a forced Yes/No confirmation (terminal — NOT a navigable menu).
// Bottom row [No . - . Yes]: No/cancel first (reflexive-safe) + an inert spacer
// so No and Yes are never adjacent (fat-finger guard on destructive confirms).
// Rendered to an arbitrary `user` target — confirm prompts often go to a
// different avatar than the operator (e.g. the candidate being asked to accept
// ownership). Labels default to Yes/No; the click always returns context
// "confirm" (Yes) or "cancel" (No).
render_modal(string msg) {
    if (!validate_required_fields(msg, ["user", "session_id"])) {
        return;
    }

    key user = (key)llJsonGetValue(msg, ["user"]);
    string session_id = llJsonGetValue(msg, ["session_id"]);

    string confirm_label = llJsonGetValue(msg, ["confirm_label"]);
    if (confirm_label == JSON_INVALID) confirm_label = "Yes";
    string cancel_label = llJsonGetValue(msg, ["cancel_label"]);
    if (cancel_label == JSON_INVALID) cancel_label = "No";

    // Bottom row [No . - . Yes]: No (cancel) ALWAYS at slot 0 (a reflexive click
    // hits the non-destructive option), an inert spacer at slot 1 so No and Yes
    // are NEVER adjacent (fat-finger guard on destructive confirms), Yes (confirm)
    // at slot 2. Mirrors menu.fixed's [Close . - . Back] bottom row.
    list button_rows_list = [
        btn_row(cancel_label,  "cancel"),
        btn_row("-",           ""),
        btn_row(confirm_label, "confirm")
    ];

    string title = llJsonGetValue(msg, ["title"]);
    if (title == JSON_INVALID) title = "Confirm";
    string body_text = llJsonGetValue(msg, ["body"]);
    if (body_text == JSON_INVALID) body_text = "Are you sure?";

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", session_id,
        "user", (string)user,
        "title", title,
        "body", body_text,
        "button_rows", llDumpList2String(button_rows_list, "\n"),
        "timeout", 60
    ]), NULL_KEY);
}

// INFO mode: a terminal informational dialog — title + body + a single OK that
// dismisses. NO nav row (it isn't a navigable menu, so it deliberately does NOT
// get the << >> Back row every real menu shares). The click returns context
// "ok"; the caller decides what that means (usually close the UI).
render_info(string msg) {
    if (!validate_required_fields(msg, ["user", "session_id"])) {
        return;
    }

    key user = (key)llJsonGetValue(msg, ["user"]);
    string session_id = llJsonGetValue(msg, ["session_id"]);

    string ok_label = llJsonGetValue(msg, ["ok_label"]);
    if (ok_label == JSON_INVALID) ok_label = "OK";
    string title = llJsonGetValue(msg, ["title"]);
    if (title == JSON_INVALID) title = "Info";
    string body_text = llJsonGetValue(msg, ["body"]);
    if (body_text == JSON_INVALID) body_text = "";

    list button_rows_list = [btn_row(ok_label, "ok")];

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", session_id,
        "user", (string)user,
        "title", title,
        "body", body_text,
        "button_rows", llDumpList2String(button_rows_list, "\n"),
        "timeout", 60
    ]), NULL_KEY);
}

show_message(string msg) {
    if (!validate_required_fields(msg, ["user", "message"])) {
        return;
    }

    key user = (key)llJsonGetValue(msg, ["user"]);
    string message_text = llJsonGetValue(msg, ["message"]);

    llRegionSayTo(user, 0, message_text);
}

/* -------------------- SENSOR PICKER -------------------- */

// Map the requested kind to llSensor type flags. Unknown -> objects.
integer sensor_flags_for(string kind) {
    if (kind == "agents")  return AGENT;
    if (kind == "collars") return PASSIVE | SCRIPTED;
    return PASSIVE | ACTIVE | SCRIPTED;
}

// Reply to the requesting plugin, then clear SensorActive so a stray late dialog
// event can't double-fire. idx = the picked absolute index into SensorCands
// (ignored when cancelled). menu.sensor -> ui.sensor.result {name,key};
// menu.picker -> ui.menu.picker.result {index,context}. Routing is by key/index/
// context, never the name (name is lead_safe'd against leading-bracket poison).
send_pick_result(integer idx, integer cancelled) {
    SensorActive = FALSE;
    string rtype = "ui.sensor.result";
    if (PickerProvided) rtype = "ui.menu.picker.result";
    list f = ["type", rtype, "requester", SensorRequester, "user", SensorUserStr];
    if (cancelled) {
        f += ["cancelled", "1"];
    }
    else {
        string kv = llList2String(SensorCands, idx * 2 + 1);
        if (PickerProvided) {
            f += ["context", kv];
        }
        else {
            f += ["name", lead_safe(llList2String(SensorCands, idx * 2)), "key", kv];
        }
    }
    // Current page travels back so the requester can re-open on the same page.
    if (PickerProvided) f += ["page", (string)SensorPage];
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, f), NULL_KEY);
}

// A fixed action button (context-first row, e.g. "stop\t[Stop]") was clicked in a
// provided picker — return its context as an action so the plugin branches on it.
// No candidate index: it's an action, not a pick. Page travels back too.
send_pick_action(string action_ctx) {
    SensorActive = FALSE;
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.menu.picker.result",
        "requester", SensorRequester,
        "user", SensorUserStr,
        "context", action_ctx,
        "page", (string)SensorPage
    ]), NULL_KEY);
}

// No candidates: tell the user, then hand a cancel back to the requester so it
// can redraw its own menu.
sensor_done_none() {
    string noun = "objects";
    if (SensorKind != "objects") noun = "people";
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.message.show",
        "user", SensorUserStr,
        "message", "No " + noun + " found nearby."
    ]), NULL_KEY);
    send_pick_result(-1, TRUE);
}

// menu.picker with an empty candidate list — tell the user, hand back a cancel so
// the requester redraws its own menu.
picker_none() {
    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.message.show",
        "user", SensorUserStr,
        "message", "Nothing to select."
    ]), NULL_KEY);
    send_pick_result(-1, TRUE);
}

// Render the held candidates (SensorCands, stride [label, keyval]) straight to
// the dialog bus as delimited button_rows — no JSON on any label, no json_safe,
// so names show their real [ ] { }. BOTH UL and OL route by pick:<absolute-index>
// into SensorCands; UL puts the name on the button, OL a number + numbered body
// line (for names that overflow a 24-char button). SensorSession is fixed for the
// session so paging re-renders replace the same dialog.
render_picker() {
    integer n = llGetListLength(SensorCands) / 2;

    // Pass 1: decide which fixed buttons this toucher's ACL qualifies for. A fixed
    // row is "context\tlabel\tslot\tmask"; it shows only if bit PickerAcl of mask is
    // set (mask absent -> always). Qualified buttons occupy their slot; an
    // ACL-denied fixed slot is NOT occupied, so it rejoins the content pool and
    // becomes a normal candidate button. nav always occupies 0,1,2.
    list occupied = [0, 1, 2];
    list fixed_place = [];               // stride [slot, "context\tlabel", ...]
    integer fc = llGetListLength(PickerFixed);
    integer fi = 0;
    while (fi < fc) {
        list ff = llParseStringKeepNulls(llList2String(PickerFixed, fi), ["\t"], []);
        integer fslot = (integer)llList2String(ff, 2);
        integer fmask = -1;              // no mask -> visible to all
        if (llGetListLength(ff) > 3) fmask = (integer)llList2String(ff, 3);
        if (fslot >= 3 && fslot < MENU_SLOTS && (fmask & (1 << PickerAcl))
            && llListFindList(occupied, [fslot]) == -1) {
            occupied += [fslot];
            fixed_place += [fslot, llList2String(ff, 0) + "\t" + llList2String(ff, 1)];
        }
        fi += 1;
    }

    // Content slots = everything not occupied, in visual reading order. page_size
    // is however many that leaves (shrinks only for fixed buttons that ACTUALLY show).
    list reading_order = [9, 10, 11, 6, 7, 8, 3, 4, 5, 0, 1, 2];
    list content_slots = [];
    integer ro = 0;
    while (ro < 12) {
        integer rs = llList2Integer(reading_order, ro);
        if (llListFindList(occupied, [rs]) == -1) content_slots += [rs];
        ro += 1;
    }
    integer page_size = llGetListLength(content_slots);
    if (page_size < 1) page_size = 1;

    integer total_pages = (n + page_size - 1) / page_size;
    if (total_pages < 1) total_pages = 1;
    if (SensorPage >= total_pages) SensorPage = 0;
    if (SensorPage < 0) SensorPage = total_pages - 1;
    integer pstart = SensorPage * page_size;
    integer pend = pstart + page_size;
    if (pend > n) pend = n;

    // Build the 12-slot output: nav, then qualified fixed buttons, then candidates
    // into the content slots (in order), then blank fillers for anything left.
    list out = [];
    integer s = 0;
    while (s < MENU_SLOTS) { out += [""]; s += 1; }
    out = llListReplaceList(out, ["nav:prev\t<<"],   0, 0);
    out = llListReplaceList(out, ["nav:next\t>>"],   1, 1);
    out = llListReplaceList(out, ["nav:back\tBack"], 2, 2);

    integer fp = 0;
    integer fpn = llGetListLength(fixed_place);
    while (fp < fpn) {
        out = llListReplaceList(out, [llList2String(fixed_place, fp + 1)],
                                llList2Integer(fixed_place, fp), llList2Integer(fixed_place, fp));
        fp += 2;
    }

    string body = SensorPrompt;
    integer ci = pstart;
    integer csi = 0;
    integer csn = llGetListLength(content_slots);
    while (ci < pend && csi < csn) {
        integer slot = llList2Integer(content_slots, csi);
        string nm = llList2String(SensorCands, ci * 2);
        if (SensorShape == SHAPE_OL) {
            string num = (string)(ci - pstart + 1);
            out = llListReplaceList(out, [btn_row(num, "pick:" + (string)ci)], slot, slot);
            body += "\n" + num + ". " + nm;
        }
        else {
            if (llStringLength(nm) > 24) nm = llGetSubString(nm, 0, 23);
            out = llListReplaceList(out, [btn_row(nm, "pick:" + (string)ci)], slot, slot);
        }
        ci += 1;
        csi += 1;
    }

    // Unfilled slots -> blank filler (" " label, empty context — llDialog needs a
    // non-empty label, never "").
    integer oi = 0;
    while (oi < MENU_SLOTS) {
        if (llList2String(out, oi) == "") out = llListReplaceList(out, ["\t "], oi, oi);
        oi += 1;
    }

    string title = SensorTitle;
    if (total_pages > 1) title += " (" + (string)(SensorPage + 1) + "/" + (string)total_pages + ")";

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", SensorSession,
        "user", SensorUserStr,
        "title", title,
        "body", body,
        "button_rows", llDumpList2String(out, "\n"),
        "timeout", 60
    ]), NULL_KEY);
}

// Kick off a scan. Single-flight: a new request supersedes any in-flight one.
handle_sensor_request(string msg) {
    if (!validate_required_fields(msg, ["user", "requester"])) return;

    SensorRequester = llJsonGetValue(msg, ["requester"]);
    SensorUserStr   = llJsonGetValue(msg, ["user"]);

    SensorKind = llJsonGetValue(msg, ["kind"]);
    if (SensorKind == JSON_INVALID || SensorKind == "") SensorKind = "objects";

    SensorTitle = llJsonGetValue(msg, ["title"]);
    if (SensorTitle == JSON_INVALID) SensorTitle = "Select";
    SensorPrompt = llJsonGetValue(msg, ["prompt"]);
    if (SensorPrompt == JSON_INVALID) SensorPrompt = "Select an option:";

    // objects -> OL; people (agents/collars) -> UL.
    if (SensorKind == "objects") SensorShape = SHAPE_OL;
    else                         SensorShape = SHAPE_UL;

    float range = (float)llJsonGetValue(msg, ["range"]);
    if (range <= 0.0) range = 10.0;

    SensorSession = "sensor_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
    SensorCands  = [];
    SensorPage   = 0;
    PickerFixed  = [];   // scans carry no fixed actions — clear any left by a prior menu.picker
    PickerProvided = FALSE;
    SensorActive = TRUE;
    llSensor("", NULL_KEY, sensor_flags_for(SensorKind), range, PI);
}

// menu.picker: the plugin provides the candidate list directly (no scan). labels
// is a \n-delimited display list; keys (optional) is a parallel \n-delimited list
// of routing tokens (UUIDs for people; omit for inventory items — the pick then
// returns index only). Auto-shape: explicit `shape` (UL/OL) wins, else all labels
// fitting a button -> UL, else OL. Single-flight, shares the picker session.
handle_picker_request(string msg) {
    if (!validate_required_fields(msg, ["user", "requester"])) return;

    SensorRequester = llJsonGetValue(msg, ["requester"]);
    SensorUserStr   = llJsonGetValue(msg, ["user"]);
    SensorKind      = "";

    SensorTitle = llJsonGetValue(msg, ["title"]);
    if (SensorTitle == JSON_INVALID) SensorTitle = "Select";
    SensorPrompt = llJsonGetValue(msg, ["prompt"]);
    if (SensorPrompt == JSON_INVALID) SensorPrompt = "Select an option:";

    // Candidates arrive as key-first rows "key\tlabel\n...". The key never leads
    // with [ or {, so the field value is poison-safe; the label (which may) sits
    // in field 2. The key is the plugin's own routing token (index or UUID) and
    // is exactly what comes back in the result context.
    list rows = [];
    string items_str = llJsonGetValue(msg, ["items"]);
    if (items_str != JSON_INVALID && items_str != "") rows = llParseStringKeepNulls(items_str, ["\n"], []);

    integer n = llGetListLength(rows);
    SensorCands = [];
    integer maxlen = 0;
    integer i = 0;
    while (i < n) {
        list f = llParseStringKeepNulls(llList2String(rows, i), ["\t"], []);
        string kv = llList2String(f, 0);
        string lbl = "";
        if (llGetListLength(f) > 1) lbl = llList2String(f, 1);
        SensorCands += [lbl, kv];
        if (llStringLength(lbl) > maxlen) maxlen = llStringLength(lbl);
        i += 1;
    }

    // Optional fixed action buttons as rows "context\tlabel\tslot\tmask\n..." (e.g.
    // "stop\t[Stop]\t3\t62\nclose\t[Close]\t5\t62") — each pinned to its explicit
    // dialog slot (3..11) by render_picker IF bit PickerAcl of its mask is set;
    // otherwise the slot rejoins the content pool (falls back to a normal button).
    PickerFixed = [];
    string fixed_str = llJsonGetValue(msg, ["fixed"]);
    if (fixed_str != JSON_INVALID && fixed_str != "") PickerFixed = llParseStringKeepNulls(fixed_str, ["\n"], []);
    PickerAcl = (integer)llJsonGetValue(msg, ["acl"]);   // (integer)JSON_INVALID -> 0

    string shp = llJsonGetValue(msg, ["shape"]);
    if (shp == "UL")      SensorShape = SHAPE_UL;
    else if (shp == "OL") SensorShape = SHAPE_OL;
    else if (maxlen <= UL_MAX) SensorShape = SHAPE_UL;
    else                       SensorShape = SHAPE_OL;

    // UL is alphabetised; keep the parallel key with its label via strided sort.
    if (SensorShape == SHAPE_UL && n > 1) SensorCands = llListSortStrided(SensorCands, 2, 0, TRUE);

    SensorSession = "picker_" + (string)llGetKey() + "_" + (string)llGetUnixTime();
    // Optional starting page — lets a plugin re-open the picker on the same page
    // after acting on a pick (render_picker clamps it to range).
    SensorPage   = 0;
    string pg = llJsonGetValue(msg, ["page"]);
    if (pg != JSON_INVALID) SensorPage = (integer)pg;
    PickerProvided = TRUE;
    SensorActive = TRUE;

    // Empty only counts if there are also no fixed actions — a picker that is all
    // action buttons (e.g. [Stop] with no anims) should still render.
    if (n == 0 && llGetListLength(PickerFixed) == 0) { picker_none(); return; }
    render_picker();
}

// Pick / nav / cancel for the active picker session (DIALOG_BUS responses).
// Both UL and OL route by pick:<absolute-index> into SensorCands — uniform, so
// no per-shape resolution and no (key)-cast that only worked for UUID contexts.
handle_sensor_response(string msg) {
    if (!SensorActive) return;
    if (llJsonGetValue(msg, ["session_id"]) != SensorSession) return;

    string ctx = llJsonGetValue(msg, ["context"]);
    if (ctx == JSON_INVALID) ctx = "";

    if (ctx == "nav:back") { send_pick_result(-1, TRUE); return; }
    if (ctx == "nav:prev") { SensorPage -= 1; render_picker(); return; }
    if (ctx == "nav:next") { SensorPage += 1; render_picker(); return; }

    if (llGetSubString(ctx, 0, 4) == "pick:") {
        integer idx = (integer)llGetSubString(ctx, 5, -1);
        if (idx * 2 + 1 < llGetListLength(SensorCands)) send_pick_result(idx, FALSE);
        return;
    }
    // A non-empty, non-nav, non-pick context in a provided picker is a fixed
    // action button (e.g. [Stop]); hand its context back to the requester.
    if (ctx != "" && PickerProvided) { send_pick_action(ctx); return; }
}

/* -------------------- EVENTS -------------------- */

// Stateless renderer — no init needed, so no state_entry; the state's
// other handlers satisfy LSL's at-least-one-event requirement.
default
{
    link_message(integer sender_num, integer num, string msg, key id) {
        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        if (num == KERNEL_LIFECYCLE) {
            // Owner-change wipe / external soft reset from collar_kernel.
            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
            return;
        }

        if (num == UI_BUS) {
            if (msg_type == "ui.menu.render") {
                // Two families: navigable menus (menu.*) all flow through the one
                // render_paged(shape); terminal dialogs (dialog.*) are their own
                // small renderers. menu.sensor scans first, then renders an OL/UL
                // picker over the result. A missing/unknown mode defaults to the
                // safe paginating pager.
                string mode = llJsonGetValue(msg, ["mode"]);
                if      (mode == "menu.fixed")     render_paged(msg, SHAPE_FIXED);
                else if (mode == "menu.unordered") render_paged(msg, SHAPE_UL);
                else if (mode == "menu.ordered")   render_paged(msg, SHAPE_OL);
                else if (mode == "menu.sensor")    handle_sensor_request(msg);
                else if (mode == "menu.picker")    handle_picker_request(msg);
                else if (mode == "dialog.modal")   render_modal(msg);
                else if (mode == "dialog.info")    render_info(msg);
                else                               render_paged(msg, SHAPE_PAGER);
            }
            else if (msg_type == "ui.message.show") {
                show_message(msg);
            }
            return;
        }

        // DIALOG_BUS: only our own sensor-picker session concerns us — kmod_ui
        // owns the menu sessions, and handle_sensor_response self-gates on
        // SensorSession. A close/timeout on our session is a cancel.
        if (num == DIALOG_BUS) {
            if (msg_type == "ui.dialog.response") {
                handle_sensor_response(msg);
            }
            else if (msg_type == "ui.dialog.timeout" || msg_type == "ui.dialog.close") {
                if (SensorActive && llJsonGetValue(msg, ["session_id"]) == SensorSession) {
                    send_pick_result(-1, TRUE);
                }
            }
            return;
        }
    }

    // menu.sensor scan results. Resolution is kind-specific: agents -> the
    // avatar; collars -> the collar's OBJECT_OWNER (deduped, so coffle leashes to
    // a person); objects -> the object. Excludes the collar prim + the wearer.
    sensor(integer num_detected) {
        if (!SensorActive) return;

        key wearer = llGetOwner();
        key my_key = llGetKey();
        SensorCands = [];

        integer i = 0;
        while (i < num_detected) {
            key dk = llDetectedKey(i);
            if (SensorKind == "agents") {
                if (dk != wearer) SensorCands += [llDetectedName(i), dk];
            }
            else if (SensorKind == "collars") {
                key owner = llGetOwnerKey(dk);
                if (dk != my_key && owner != wearer && owner != NULL_KEY
                    && llListFindList(SensorCands, [owner]) == -1) {
                    SensorCands += [llKey2Name(owner), owner];
                }
            }
            else {
                if (dk != my_key && dk != wearer) SensorCands += [llDetectedName(i), dk];
            }
            i += 1;
        }

        if (llGetListLength(SensorCands) == 0) {
            sensor_done_none();
            return;
        }
        if (SensorShape == SHAPE_UL && llGetListLength(SensorCands) > 2)
            SensorCands = llListSortStrided(SensorCands, 2, 0, TRUE);
        render_picker();
    }

    no_sensor() {
        if (!SensorActive) return;
        sensor_done_none();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}

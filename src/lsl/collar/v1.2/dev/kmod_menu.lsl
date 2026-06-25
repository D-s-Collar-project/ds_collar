/*--------------------
MODULE: kmod_menu.lsl
VERSION: 1.2
REVISION: 16
CHANGES:
- v1.2 rev 16: render unified — render_menu + render_list collapse into one render_paged(shape) covering the four menu.x shapes (fixed/pager/unordered/ordered); dialog.modal flanked to [No, spacer, Yes]; dispatch switches the six explicit menu.x / dialog.x modes (bare-name transition aliases dropped).
- v1.2 rev 15: the pager (render_menu) now accepts the optional `fixed` action-button list, like render_list — fixed buttons reserve the low slots right after nav and page_size shrinks by the fixed count. A blank spacer ({label:" ",context:""}) among the fixed buttons positions them (plugin_leash's length menu uses [-1m," ",+1m] to flank -1m/+1m at slots 3 and 5). Menus that send no `fixed` are unchanged (page_size stays PAGE_SIZE).
- v1.2 rev 14: nav buttons now carry contexts (nav:prev/nav:next/nav:back/nav:close) via the new nav_obj() helper — in render_menu + render_list — instead of bare label strings. The dialog layer already context-routes {label,context} objects, so consumers route nav by context like every other button (no more label-routing exception); the visible label is now free to restyle (e.g. UTF-8 arrows) with zero routing impact.
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

// Build a routable nav button. Nav buttons carry a context (nav:prev /
// nav:next / nav:back / nav:close) exactly like content buttons, so the
// dialog layer maps the click to a context and consumers route by context,
// never by the visible label. This keeps the label free to restyle (e.g.
// UTF-8 arrows) without touching any routing.
string nav_obj(string label, string ctx) {
    return llList2Json(JSON_OBJECT, ["label", label, "context", ctx]);
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
        nav = [nav_obj("Close", "nav:close"), nav_obj("-", ""), nav_obj("Back", "nav:back")];
    }
    else if (shape == SHAPE_PAGER) {
        // Exit is Close at the root tier (ends the session) and Back inside a
        // category (pops to root). has_nav=0 → a lone exit (no << >>).
        string exit_obj = nav_obj("Close", "nav:close");
        if (category != "") exit_obj = nav_obj("Back", "nav:back");
        nav = [exit_obj];
        if ((integer)llJsonGetValue(msg, ["has_nav"])) {
            nav = [nav_obj("<<", "nav:prev"), nav_obj(">>", "nav:next"), exit_obj];
        }
    }
    else {
        nav = [nav_obj("<<", "nav:prev"), nav_obj(">>", "nav:next"), nav_obj("Back", "nav:back")];
    }

    // ---- optional fixed action buttons (any shape; e.g. leash length's ±1m) ----
    list fixed = [];
    string fixed_json = llJsonGetValue(msg, ["fixed"]);
    if (fixed_json != JSON_INVALID) fixed = llJson2List(fixed_json);
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
        string buttons_json = llJsonGetValue(msg, ["buttons"]);
        if (buttons_json != JSON_INVALID) full_buttons = llJson2List(buttons_json);
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
                content += [llList2Json(JSON_OBJECT, ["label", num, "context", "pick:" + (string)i])];
                body_text += "\n" + num + ". " + lbl;
            }
            else {
                content += [llList2Json(JSON_OBJECT,
                    ["label", lbl, "context", llList2String(pairs, i * 2 + 1)])];
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
        "button_data", llList2Json(JSON_ARRAY, final_button_data),
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
    list button_data = [
        llList2Json(JSON_OBJECT, ["label", cancel_label,  "context", "cancel"]),
        llList2Json(JSON_OBJECT, ["label", "-",           "context", ""]),
        llList2Json(JSON_OBJECT, ["label", confirm_label, "context", "confirm"])
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
        "button_data", llList2Json(JSON_ARRAY, button_data),
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

    list button_data = [llList2Json(JSON_OBJECT, ["label", ok_label, "context", "ok"])];

    llMessageLinked(LINK_SET, DIALOG_BUS, llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", session_id,
        "user", (string)user,
        "title", title,
        "body", body_text,
        "button_data", llList2Json(JSON_ARRAY, button_data),
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
                // small renderers. menu.* share render_paged (four shapes);
                // dialog.* are terminal. A missing/unknown mode defaults to the
                // safe paginating pager.
                string mode = llJsonGetValue(msg, ["mode"]);
                if      (mode == "menu.fixed")     render_paged(msg, SHAPE_FIXED);
                else if (mode == "menu.unordered") render_paged(msg, SHAPE_UL);
                else if (mode == "menu.ordered")   render_paged(msg, SHAPE_OL);
                else if (mode == "dialog.modal")   render_modal(msg);
                else if (mode == "dialog.info")    render_info(msg);
                else                               render_paged(msg, SHAPE_PAGER);
            }
            else if (msg_type == "ui.message.show") {
                show_message(msg);
            }
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}

/*--------------------
MODULE: kmod_menu.lsl
VERSION: 1.2
REVISION: 12
CHANGES:
- v1.2 rev 12 (sandbox): merged render_unordered + render_ordered into one render_list(msg, isOrdered) — they shared ~70% boilerplate (validate, reserve nav+fixed, page-math, layout_buttons, forward). isOrdered drives the only differences: UL(0) A-Z-sorts + names the buttons + returns context; OL(1) preserves order + numbers the buttons + appends a numbered body + returns pick:<index>. Wire stays descriptive: mode "unordered"/"ordered" dispatch to render_list(msg, FALSE/TRUE). OL's fix0/fix1 fields fold into the shared `fixed` list (no OL consumer used them). No behavior change for animate (UL) or blacklist (OL).
- v1.2 rev 11 (sandbox): (1) UNORDERED mode now accepts {label,context} items (not just flat names) — sorts by label, returns the context, so a people-picker can show the name but return the UUID (no name-collision / truncation risk); flat-name items (animate) still work (label==context). (2) Added the MODAL mode (render_modal): forced Yes/No, NO nav row, No/cancel always at slot 0 (enforced in the service), rendered to an arbitrary target; returns context confirm/cancel. For plugin_owners (UL scans + modal confirms).
- v1.2 rev 10 (sandbox): added the ORDERED picker mode (render_ordered). Items keep caller order, numbered 1..N (page-relative) as index buttons + a matching numbered body; context "pick:<global-index>". Nav (<<,>>,Back) + optional fixed action buttons (fix0/fix1, policy pre-checked by the plugin) reserve the low slots; content packs above them via the shared layout_buttons — NO padding (page_size = 12 - reserved). First consumer: plugin_blacklist (remove + add-scan). NOTE: a "flanking" fixed-button layout (fixed buttons straddling content) would need partial-page padding, which this system forbids — deferred until a fixed-button OL consumer exists.
- v1.2 rev 9 (sandbox): ui.menu.render is now mode-switched (default "pager"). Added the UNORDERED picker mode (render_unordered): caller sends a flat `items` name list + optional `fixed` buttons; the service A-Z-sorts, pages (page_size = 12 - 3 nav - fixed_count), builds name-buttons, and lays out via the shared layout_buttons. First consumer: plugin_animate (sheds its hand-rolled slot map + inventory-order list → alphabetized). Pager path unchanged.
- v1.2 rev 8 (sandbox): replaced reverse_complete_rows/reorder_buttons_for_display with the CANONICAL reverse-map layout_buttons (proven in plugin_animate/plugin_leash/plugin_leash_target). The old reverse-complete-rows was correct for whole rows + tiny partials but SCRAMBLED "full rows + a partial" (e.g. 4 content items read b3,b0,b1,b2) — root/category dodged it by being small; pickers would hit it every page. layout_buttons places nav at the low slots and fills content into reading-order slots [9,10,11,6,7,8,3,4,5,0,1,2]; correct for every count. This is the single layout law all menu modes will share.
- v1.2 rev 7 (sandbox): the menu service now OWNS paging. render_menu takes the caller's FULL button list + a page index and slices the page itself (PAGE_SIZE, cross-module with kmod_ui MAX_FUNC_BTNS) instead of receiving a pre-sliced page + total_pages. Same slot layout/nav/title-pagination; callers stop slicing. Foundation for uniform paging across menu + picker shapes — no plugin re-implements page slicing.
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

// Content buttons per page. The menu service owns paging now: callers hand
// over the FULL button list and a page index; we slice it. MUST match
// kmod_ui's MAX_FUNC_BTNS (cross-module contract).
integer PAGE_SIZE = 9;

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

/* -------------------- RENDERING -------------------- */

render_menu(string msg) {
    if (!validate_required_fields(msg, ["user", "session_id", "menu_type", "buttons"])) {
        return;
    }

    key user = (key)llJsonGetValue(msg, ["user"]);

    string session_id = llJsonGetValue(msg, ["session_id"]);
    string menu_type = llJsonGetValue(msg, ["menu_type"]);
    integer current_page = (integer)llJsonGetValue(msg, ["page"]);
    string buttons_json = llJsonGetValue(msg, ["buttons"]);
    integer has_nav = (integer)llJsonGetValue(msg, ["has_nav"]);

    // Category tier (kmod_ui sets "category" when rendering inside one):
    // nav swaps Close for Back (returns to the root tier) and the title is
    // the category name.
    string category = "";
    string cat_tmp = llJsonGetValue(msg, ["category"]);
    if (cat_tmp != JSON_INVALID) category = cat_tmp;

    // The caller hands the FULL button list; the menu service owns paging.
    // Compute total pages, clamp/wrap the requested page, and slice it. The
    // page cursor lives in the caller's session; this slice is deterministic
    // off the same list + page, so the two never disagree.
    list full_buttons = llJson2List(buttons_json);
    integer btn_count = llGetListLength(full_buttons);
    integer total_pages = (btn_count + PAGE_SIZE - 1) / PAGE_SIZE;
    if (total_pages < 1) total_pages = 1;
    if (current_page >= total_pages) current_page = 0;
    if (current_page < 0) current_page = total_pages - 1;

    integer pstart = current_page * PAGE_SIZE;
    integer pend = pstart + PAGE_SIZE;
    if (pend > btn_count) pend = btn_count;
    list page_buttons = [];
    if (btn_count > 0) page_buttons = llList2List(full_buttons, pstart, pend - 1);

    // Nav takes the low slots; content fills the rest in reading order.
    // Paginated menus lead with the full << >> <exit> row; others a lone exit.
    string nav_exit = "Close";
    if (category != "") nav_exit = "Back";

    list nav = [nav_exit];
    if (has_nav) nav = ["<<", ">>", nav_exit];

    list final_button_data = layout_buttons(nav, page_buttons);

    // Plugins may supply their own title (e.g. bell's "Bell"); else derive one
    // from the category / menu_type for the root + category tiers.
    string title = llJsonGetValue(msg, ["title"]);
    if (title == JSON_INVALID) {
        if (category != "") {
            title = category;
        }
        else if (menu_type == ROOT_CONTEXT) {
            title = "Main Menu";
        }
        else if (menu_type == SOS_CONTEXT) {
            title = "Emergency Menu";
        }
        else {
            title = "Menu";
        }
    }

    if (total_pages > 1) {
        title = title + " (" + (string)(current_page + 1) + "/" + (string)total_pages + ")";
    }

    // Plugins may supply their own status body (e.g. bell's volume/visibility
    // readout); fall back to the generic prompt keyed by menu_type.
    string body_text = llJsonGetValue(msg, ["body"]);
    if (body_text == JSON_INVALID) {
        if (menu_type == SOS_CONTEXT) {
            body_text = "Emergency options:";
        }
        else {
            body_text = "Select an option:";
        }
    }

    string final_button_data_json = llList2Json(JSON_ARRAY, final_button_data);

    string dialog_msg = llList2Json(JSON_OBJECT, [
        "type", "ui.dialog.open",
        "session_id", session_id,
        "user", (string)user,
        "title", title,
        "body", body_text,
        "button_data", final_button_data_json,
        "timeout", 60
    ]);

    llMessageLinked(LINK_SET, DIALOG_BUS, dialog_msg, NULL_KEY);
}

// LIST picker mode — a paginated list. The << >> Back nav (+ optional `fixed`
// action buttons) reserve the low slots; content packs above via layout_buttons
// (NO padding — short lists just have fewer rows). page_size = 12 - reserved.
// Page state + wrap stay with the caller. `isOrdered` selects the flavor:
//   UL (0): no predetermined order → A-Z sort by label; the NAME is the button.
//           Items may be flat strings (label == context, e.g. animations) or
//           {label,context} objects (e.g. a person: name shown, UUID returned).
//           Body is the caller's; the click returns the item's context.
//   OL (1): caller order preserved; the NUMBER (1..N page-relative) is the
//           button with a matching numbered body line; the click returns
//           "pick:<global-index>" — for long names that overflow a button.
render_list(string msg, integer isOrdered) {
    if (!validate_required_fields(msg, ["user", "session_id", "items"])) {
        return;
    }

    key user = (key)llJsonGetValue(msg, ["user"]);
    string session_id = llJsonGetValue(msg, ["session_id"]);
    integer current_page = (integer)llJsonGetValue(msg, ["page"]);

    // Optional fixed action buttons ({label,context}) after the nav.
    list fixed = [];
    string fixed_json = llJsonGetValue(msg, ["fixed"]);
    if (fixed_json != JSON_INVALID) fixed = llJson2List(fixed_json);
    list reserved = ["<<", ">>", "Back"] + fixed;
    integer page_size = 12 - llGetListLength(reserved);
    if (page_size < 1) page_size = 1;

    // Parse items into a strided [label, context] table. Flat strings →
    // label == context; {label,context} objects keep their own context.
    list raw = llJson2List(llJsonGetValue(msg, ["items"]));
    list pairs = [];
    integer ri = 0;
    integer rn = llGetListLength(raw);
    while (ri < rn) {
        string it = llList2String(raw, ri);
        string lbl = llJsonGetValue(it, ["label"]);
        string ctx;
        if (lbl == JSON_INVALID) {
            lbl = it;     // flat string: label IS the value
            ctx = it;
        }
        else {
            ctx = llJsonGetValue(it, ["context"]);
            if (ctx == JSON_INVALID) ctx = lbl;
        }
        pairs += [lbl, ctx];
        ri += 1;
    }
    // UL sorts A-Z by label; OL preserves the caller's order.
    if (!isOrdered && llGetListLength(pairs) > 2) {
        pairs = llListSortStrided(pairs, 2, 0, TRUE);
    }

    integer item_count = llGetListLength(pairs) / 2;
    integer total_pages = (item_count + page_size - 1) / page_size;
    if (total_pages < 1) total_pages = 1;
    if (current_page >= total_pages) current_page = 0;
    if (current_page < 0) current_page = total_pages - 1;

    integer pstart = current_page * page_size;
    integer pend = pstart + page_size;
    if (pend > item_count) pend = item_count;

    // Build the page's content buttons; OL also appends a numbered body line.
    list content = [];
    string body_text = llJsonGetValue(msg, ["body"]);
    if (body_text == JSON_INVALID) body_text = "Select an option:";

    integer i = pstart;
    while (i < pend) {
        string lbl = llList2String(pairs, i * 2);
        if (isOrdered) {
            string num = (string)(i - pstart + 1);
            content += [llList2Json(JSON_OBJECT, [
                "label", num, "context", "pick:" + (string)i
            ])];
            body_text += "\n" + num + ". " + lbl;
        }
        else {
            content += [llList2Json(JSON_OBJECT, [
                "label", lbl, "context", llList2String(pairs, i * 2 + 1)
            ])];
        }
        i += 1;
    }

    list final_button_data = layout_buttons(reserved, content);

    string title = llJsonGetValue(msg, ["title"]);
    if (title == JSON_INVALID) title = "Menu";
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

// MODAL mode: a forced Yes/No confirmation. NO nav row — the two choices sit in
// the bottom row with the SAFE choice (No/cancel) ALWAYS first at slot 0, so a
// reflexive click hits the non-destructive option (enforced here, not trusted
// to the caller). Rendered to an arbitrary `user` target — confirm prompts
// often go to a different avatar than the operator (e.g. the candidate being
// asked to accept ownership). Labels default to Yes/No; the click always
// returns context "confirm" (Yes) or "cancel" (No).
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

    // No (cancel) at slot 0, Yes (confirm) at slot 1 — No always first.
    list button_data = [
        llList2Json(JSON_OBJECT, ["label", cancel_label, "context", "cancel"]),
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
                // Mode-switch: each mode prepares its slots differently, then
                // shares the one layout_buttons primitive. Default = pager.
                // unordered/ordered share one render_list (the bit picks the
                // flavor); modal + pager are their own renderers.
                string mode = llJsonGetValue(msg, ["mode"]);
                if (mode == "unordered") render_list(msg, FALSE);
                else if (mode == "ordered") render_list(msg, TRUE);
                else if (mode == "modal") render_modal(msg);
                else render_menu(msg);
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

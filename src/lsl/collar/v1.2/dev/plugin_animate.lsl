/*--------------------
PLUGIN: plugin_animate.lsl
VERSION: 1.2
REVISION: 13
PURPOSE: Paginated animation menu driven by inventory contents
ARCHITECTURE: Consolidated message bus lanes. Access gated by the primary
  collar ACL check (kmod_ui visibility + dispatch against acl.policycontext);
  no per-button policy filtering (animation buttons are dynamic content).
CHANGES:
- v1.2 rev 13: fixed-row format simplified to "context\tlabel\tmask" (kmod_menu rev 24 dropped explicit slots + the flanking layout — fixed buttons are always contiguous now, which the shared layout_buttons renders with zero padding). [Stop]/[Close] now sit contiguous at slots 3/4, content above; both keep PLUGIN_ACL_MASK so they show for anyone who can open Animate.
- v1.2 rev 12: fixed buttons now carry an ACL mask — [Stop]/[Close] + the toucher's `acl` (captured from ui.menu.start into CurrentAcl); both use PLUGIN_ACL_MASK (62) so they show for anyone who can open Animate.
- v1.2 rev 11: two fixed actions flank the action row via explicit slots (kmod_menu rev 21) — [Stop]@3 and [Close]@5, so slot 4 stays a content anim. New "close" branch in handle_picker_result exits the menu (no re-show, no return-to-root).
- v1.2 rev 10: migrated to menu.picker (central picker, kmod_menu rev 19+). Sends candidates as key-first rows "index\tname\n..." (index leads each row so the field never [/{-leads; anim names with [ ] { } render for real) + a fixed [Stop]; kmod_menu owns the session, paging, and the click and replies ONE ui.menu.picker.result. Dropped the plugin-side dialog session (SessionId), page cursor (CurrentPage/PAGE_SIZE), generate_session_id, handle_button_click, and the whole DIALOG_BUS handler. New handle_picker_result(context,cancelled,page): cancelled -> root; "stop" -> stop+reshow; else context is the anim index -> play+reshow. Re-shows land on the SAME page (page round-trips via the result). No longer routes by anim name (was context==name, which poisoned on bracket-leading names).
- v1.2 rev 9: animation picker mode renamed unordered to menu.unordered (menu-mode taxonomy; no behavior change).
- v1.2 rev 8: response handler routes every button by context — nav (nav:*), [Stop] (context "stop"), anim items (UL flat item: context == anim name) — was button-label-routed. handle_button_click takes context, not the raw label.
- v1.2 rev 7: render via the menu service's UNORDERED picker mode (ui.menu.render mode="unordered") instead of building the slot-mapped dialog locally. Hands kmod_menu the full anim list + [Stop] as a fixed button; kmod_menu A-Z-sorts, pages, and lays out. Deleted ~90 lines of hand-rolled slot mapping + the empty-case dialog. Anims are now alphabetized (was inventory order); page indicator moved to the title. Handler/events unchanged (still name-based). PAGE_SIZE 8 must match kmod_menu's 12-3-1.
- v1.2 rev 6: stopped writing reg.<ctx> + acl.policycontext directly to LSD (self-declare write-storm); register_self now announces cat/mask/policy in kernel.register.declare; kernel is sole serial writer. Removed write_plugin_reg + reset-handler LSD deletes. See collar_kernel rev 6.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer UI_BUS = 900;
// menu.picker: kmod_menu owns the dialog session; the result returns on UI_BUS,
// so this plugin no longer talks to DIALOG_BUS directly.

/* -------------------- PLUGIN IDENTITY -------------------- */
string PLUGIN_CONTEXT = "ui.core.animate";
string PLUGIN_LABEL = "Animate";

/* -------------------- OTHER CONSTANTS -------------------- */

integer MAX_ANIMATIONS = 128;

/* -------------------- STATE -------------------- */
// The active menu user + their ACL level (from ui.menu.start). kmod_menu owns the
// picker session + paging + the click (menu.picker), so there is no per-plugin
// session id or page cursor anymore. CurrentAcl gates which fixed buttons show.
key CurrentUser = NULL_KEY;
integer CurrentAcl = 0;

// Animation inventory — read live from inventory; LastAnimCount only used to detect
// add/remove deltas in CHANGED_INVENTORY so the plugin can reset itself.
integer LastAnimCount = -1;
string LastPlayedAnim = "";

// Permissions
integer HasPermission = FALSE;

/* -------------------- HELPERS -------------------- */



/* -------------------- ANIMATION INVENTORY MANAGEMENT -------------------- */

// Returns the number of animations the plugin will expose, capped at MAX_ANIMATIONS.
// All other access sites query inventory live via llGetInventoryName.
integer get_animation_count() {
    integer count = llGetInventoryNumber(INVENTORY_ANIMATION);
    if (count > MAX_ANIMATIONS) return MAX_ANIMATIONS;
    return count;
}

/* -------------------- ANIMATION CONTROL -------------------- */

ensure_permissions() {
    key owner = llGetOwner();
    if (llGetPermissions() & PERMISSION_TRIGGER_ANIMATION) {
        HasPermission = TRUE;
    }
    else {
        llRequestPermissions(owner, PERMISSION_TRIGGER_ANIMATION);
    }
}

start_animation(string anim_name) {
    if (!HasPermission) {
        llRegionSayTo(CurrentUser, 0, "No animation permission granted.");
        return;
    }

    // Stop last animation if there was one
    if (LastPlayedAnim != "") {
        llStopAnimation(LastPlayedAnim);
    }

    // Start new animation
    if (llGetInventoryType(anim_name) == INVENTORY_ANIMATION) {
        llStartAnimation(anim_name);
        LastPlayedAnim = anim_name;
        llRegionSayTo(CurrentUser, 0, "Playing: " + anim_name);
    }
    else {
        llRegionSayTo(CurrentUser, 0, "Animation not found: " + anim_name);
    }
}

stop_all_animations() {
    if (LastPlayedAnim != "") {
        llStopAnimation(LastPlayedAnim);
        LastPlayedAnim = "";
        llRegionSayTo(CurrentUser, 0, "Animation stopped.");
    }
    else {
        llRegionSayTo(CurrentUser, 0, "No animation playing.");
    }
}

/* -------------------- LIFECYCLE MANAGEMENT -------------------- */

// Self-declared menu presence. kmod_ui enumerates via llLinksetDataFindKeys
// and rebuilds its view tables on linkset_data events touching this key.
// v1.2 categorized UI: menu category + per-ACL visibility mask (bit L =
// visible at ACL level L). Consumed by kmod_ui's view rebuild.
string PLUGIN_CATEGORY = "Standalone";
integer PLUGIN_ACL_MASK = 62;

register_self() {
    // Per-button visibility policy (all ACL levels see same buttons). Was
    // written straight to LSD here; now announced to the kernel, which is the
    // SOLE writer of acl.policycontext (and reg.<ctx>) — see collar_kernel rev 6.
    string policy = llList2Json(JSON_OBJECT, [
        "1", "<<,>>,Stop",
        "2", "<<,>>,Stop",
        "3", "<<,>>,Stop",
        "4", "<<,>>,Stop",
        "5", "<<,>>,Stop"
    ]);

    // Register with kernel (for ping/pong health tracking and alias table).
    // The kernel writes reg.<ctx> + the policy to LSD itself, draining its
    // queue serially — no concurrent write burst.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.register.declare",
        "context", PLUGIN_CONTEXT,
        "label", PLUGIN_LABEL,
        "script", llGetScriptName(),
        "cat", PLUGIN_CATEGORY,
        "mask", (string)PLUGIN_ACL_MASK,
        "policy", policy
    ]), NULL_KEY);

    // Declare chat subcommand roots. Consumed by kmod_chat only; invisible
    // to the kernel plugin list, so these never render as root buttons.
    // "pose <name>" plays the named animation; "stand" stops the current one.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "pose",
        "context", PLUGIN_CONTEXT + ".pose"
    ]), NULL_KEY);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type",    "chat.alias.declare",
        "alias",   "stand",
        "context", PLUGIN_CONTEXT + ".stand"
    ]), NULL_KEY);
}

send_pong() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "kernel.pong",
        "context", PLUGIN_CONTEXT
    ]);
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, msg, NULL_KEY);
}

/* -------------------- UI / MENU SYSTEM -------------------- */

show_animation_menu(integer page) {
    integer total_anims = get_animation_count();

    string body = "Select an animation to play.";
    if (total_anims == 0) {
        body = "No animations found in inventory.";
    }
    else if (LastPlayedAnim != "") {
        body += "\nPlaying: " + LastPlayedAnim;
    }

    // Candidates as key-first rows "index\tname\n...": the index is our routing
    // token (it leads each row, so the field value never [/{-leads) and comes
    // back verbatim as the result context; the name (which may hold [ ] { }) sits
    // in field 2, safe. kmod_menu auto-shapes, paginates, owns the click, and
    // replies with ONE ui.menu.picker.result. [Stop] rides as a fixed action.
    string items = "";
    integer i = 0;
    while (i < total_anims) {
        if (i > 0) items += "\n";
        items += (string)i + "\t" + llGetInventoryName(INVENTORY_ANIMATION, i);
        i += 1;
    }

    llMessageLinked(LINK_SET, UI_BUS, llList2Json(JSON_OBJECT, [
        "type",      "ui.menu.render",
        "mode",      "menu.picker",
        "requester", PLUGIN_CONTEXT,
        "user",      (string)CurrentUser,
        "title",     PLUGIN_LABEL,
        "prompt",    body,
        "items",     items,
        "fixed",     "stop\t[Stop]\t" + (string)PLUGIN_ACL_MASK + "\nclose\t[Close]\t" + (string)PLUGIN_ACL_MASK,
        "acl",       (string)CurrentAcl,
        "page",      (string)page
    ]), NULL_KEY);
}

/* -------------------- CHAT SUBCOMMAND HANDLING -------------------- */

// Execute a namespaced chat subcommand without opening the menu.
// Examples:
//   "pose.nadu"  -> play animation "nadu"
//   "pose.stop"  -> stop current animation (equivalent to "stand")
//   "stand"      -> stop current animation
handle_subpath(string subpath) {
    list tokens = llParseString2List(subpath, ["."], []);
    if (llGetListLength(tokens) == 0) return;
    string action = llList2String(tokens, 0);

    if (action == "stand") {
        stop_all_animations();
        return;
    }

    if (action == "pose") {
        if (llGetListLength(tokens) < 2) {
            llRegionSayTo(CurrentUser, 0, "Usage: pose <animation name>");
            return;
        }
        string anim = llDumpList2String(llList2List(tokens, 1, -1), ".");
        if (anim == "stop") {
            stop_all_animations();
            return;
        }
        start_animation(anim);
        return;
    }

    llRegionSayTo(CurrentUser, 0, "Unknown animate subcommand: " + action);
}

/* -------------------- BUTTON HANDLING -------------------- */

// One ui.menu.picker.result per interaction (kmod_menu owns the picker, paging,
// and the click). `page` is the page the pick happened on, so re-shows land back
// there instead of jumping to page 0. cancelled -> Back/timeout: pop to the root
// menu. "stop" -> the fixed [Stop] action: stop, then re-show. Otherwise context
// is the animation index we handed out: play it, then re-show for another pick.
handle_picker_result(string context, integer cancelled, integer page) {
    if (cancelled) {
        ui_return_root();
        CurrentUser = NULL_KEY;
        return;
    }

    if (context == "close") {
        // Close exits the menu entirely — kmod_menu already closed the picker
        // session on the action click, so just drop our state: no re-show, no root.
        CurrentUser = NULL_KEY;
        return;
    }

    if (context == "stop") {
        stop_all_animations();
        show_animation_menu(page);
        return;
    }

    // Candidate pick: context is the inventory index we handed out. Inventory is
    // stable (CHANGED_INVENTORY resets the plugin), so index -> name is consistent.
    string anim = llGetInventoryName(INVENTORY_ANIMATION, (integer)context);
    if (anim != "") start_animation(anim);
    show_animation_menu(page);
}

/* -------------------- UI NAVIGATION -------------------- */

ui_return_root() {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "ui.menu.return",
        "user", (string)CurrentUser
    ]);
    llMessageLinked(LINK_SET, UI_BUS, msg, NULL_KEY);
}

/* -------------------- SESSION CLEANUP -------------------- */

// kmod_menu owns the picker session now; nothing plugin-side to close. On reset
// an open picker simply times out. Just drop the active user.
cleanup_session() {
    CurrentUser = NULL_KEY;
}

/* -------------------- EVENTS -------------------- */

default {
    state_entry() {

        // Snapshot animation count so CHANGED_INVENTORY can detect deltas and reset.
        integer raw_count = llGetInventoryNumber(INVENTORY_ANIMATION);
        if (raw_count > MAX_ANIMATIONS) {
            llRegionSayTo(llGetOwner(), 0, "WARNING: Too many animations (" + (string)raw_count + "). Only the first " + (string)MAX_ANIMATIONS + " are reachable.");
        }
        LastAnimCount = raw_count;

        cleanup_session();
        ensure_permissions();
        register_self();
    }

    on_rez(integer start_param) {
        llResetScript();
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }

        if (change & CHANGED_INVENTORY) {
            // Only animation-count deltas matter to this plugin; other inventory
            // changes (notecards, sounds, etc.) are ignored. Any change in the
            // animation set fully invalidates open menus, so reset the script.
            if (llGetInventoryNumber(INVENTORY_ANIMATION) != LastAnimCount) {
                llResetScript();
            }
        }
    }

    run_time_permissions(integer perm) {
        if (perm & PERMISSION_TRIGGER_ANIMATION) {
            HasPermission = TRUE;
        }
    }

    link_message(integer sender, integer num, string msg, key id) {
        /* -------------------- KERNEL LIFECYCLE -------------------- */if (num == KERNEL_LIFECYCLE) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            // Registration request
            if (msg_type == "kernel.register.refresh") {
                register_self();
                return;
            }

            // Heartbeat ping
            if (msg_type == "kernel.ping") {
                send_pong();
                return;
            }

            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                string target_context = llJsonGetValue(msg, ["context"]);
                if (target_context != JSON_INVALID) {
                    if (target_context != "" && target_context != PLUGIN_CONTEXT) return;
                }
                // Kernel owns clearing reg.<ctx>/acl.policycontext now (rev 6).
                llResetScript();
            }

            return;
        }

        /* -------------------- UI START -------------------- */if (num == UI_BUS) {
            string msg_type = llJsonGetValue(msg, ["type"]);
            if (msg_type == JSON_INVALID) return;

            if (msg_type == "ui.menu.start") {
                if (llJsonGetValue(msg, ["acl"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) == JSON_INVALID) return;
                if (llJsonGetValue(msg, ["context"]) != PLUGIN_CONTEXT) return;

                if (id == NULL_KEY) return;

                CurrentUser = id;
                CurrentAcl  = (integer)llJsonGetValue(msg, ["acl"]);

                string subpath = "";
                string sp = llJsonGetValue(msg, ["subpath"]);
                if (sp != JSON_INVALID) subpath = sp;

                if (subpath != "") {
                    handle_subpath(subpath);
                    return;
                }

                show_animation_menu(0);
                return;
            }

            // Picker result from kmod_menu (menu.picker). Filter to our requester
            // and the active user; branch in handle_picker_result.
            if (msg_type == "ui.menu.picker.result") {
                if (llJsonGetValue(msg, ["requester"]) != PLUGIN_CONTEXT) return;
                string ru = llJsonGetValue(msg, ["user"]);
                if (ru == JSON_INVALID || (key)ru != CurrentUser) return;
                integer was_cancelled = (llJsonGetValue(msg, ["cancelled"]) != JSON_INVALID);
                string ctx = llJsonGetValue(msg, ["context"]);
                if (ctx == JSON_INVALID) ctx = "";
                integer page = (integer)llJsonGetValue(msg, ["page"]);
                handle_picker_result(ctx, was_cancelled, page);
                return;
            }

            return;
        }
    }
}

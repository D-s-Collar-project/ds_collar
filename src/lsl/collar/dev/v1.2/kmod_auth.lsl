/*--------------------
MODULE: kmod_auth.lsl
VERSION: 1.2
REVISION: 1
PURPOSE: Authoritative ACL engine over the user-record roster
CHANGES:
- v1.2 rev 1: Rebuilt on user.<uuid> records (kmod_settings rev 2). ACL for a named actor is ONE LSD read (the record's leading acl field); wearer/stranger paths read the isowned/tpe/public scalars. Deleted: the in-memory roster mirror + apply_settings_sync re-reads, enforce_role_exclusivity (structural now), the JSON list-compare change detection, the acl.<uuid>.cache layer (TTL cache, store/clear, precompute_known_acl), acl.timestamp, and the write-only acl.owners/trustees/blacklist/public/wearertpe debris keys. auth.acl.update now fires from a debounced linkset_data watch on user.* / public.mode / tpe.mode / access.isowned. Query queueing until the first settings.sync is kept (boot-order safety). Response templates and the auth.acl.query/result protocol are unchanged.
ARCHITECTURE: Dispatch table pattern with JSON response templates. The
  roster lives in LSD as user.<uuid> = "<acl>,<rank>,<name>,<honorific>"
  records (written solely by kmod_settings); this module only reads them.
  Consumers with a hot path (kmod_ui, kmod_chat) compute ACL from the same
  records directly — kmod_auth remains the authoritative responder for
  async auth.acl.query traffic (plugins, external HUD queries) and the
  sole broadcaster of auth.acl.update on roster/flag changes.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer AUTH_BUS = 700;
integer SETTINGS_BUS = 800;

/* -------------------- ACL CONSTANTS -------------------- */
integer ACL_BLACKLIST     = -1;
integer ACL_NOACCESS      = 0;
integer ACL_PUBLIC        = 1;
integer ACL_OWNED         = 2;
integer ACL_TRUSTEE       = 3;
integer ACL_UNOWNED       = 4;
integer ACL_PRIMARY_OWNER = 5;

/* -------------------- SETTINGS KEYS -------------------- */
// User records (written by kmod_settings): user.<uuid> =
// "<acl>,<rank>,<name>,<honorific>". The leading field parses straight
// off the raw value with an integer cast. CROSS-MODULE CONTRACT.
string USER_PREFIX = "user.";

string KEY_ISOWNED       = "access.isowned";
string KEY_PUBLIC_ACCESS = "public.mode";
string KEY_TPE_MODE      = "tpe.mode";

// Debounce for the linkset_data-driven auth.acl.update broadcast: a card
// parse writes many records back-to-back; one broadcast covers the burst.
float ACL_UPDATE_DEBOUNCE = 0.2;

/* -------------------- JSON RESPONSE TEMPLATES -------------------- */
// Pre-built templates for fast response construction
string JSON_TEMPLATE_BLACKLIST = "";
string JSON_TEMPLATE_UNAUTHORIZED = "";
string JSON_TEMPLATE_NOACCESS = "";
string JSON_TEMPLATE_PUBLIC = "";
string JSON_TEMPLATE_OWNED = "";
string JSON_TEMPLATE_TRUSTEE = "";
string JSON_TEMPLATE_UNOWNED = "";
string JSON_TEMPLATE_PRIMARY = "";

/* -------------------- STATE -------------------- */
// Queries arriving before the first settings.sync (fresh boot, card still
// parsing) are queued so early touches can't read a half-built roster.
integer SettingsReady = FALSE;
list PendingQueries = [];  // [avatar_key, correlation_id, ...]
integer PENDING_STRIDE = 2;
integer MAX_PENDING_QUERIES = 50;

// Debounce flag for the auth.acl.update broadcast.
integer AclUpdatePending = FALSE;

/* -------------------- RECORD HELPERS -------------------- */

// Role of a uuid: 5/3/-1, or 0 when no record.
integer user_role(key avatar) {
    string rec = llLinksetDataRead(USER_PREFIX + (string)avatar);
    if (rec == "") return 0;
    return (integer)rec;
}

integer has_owner() {
    return (integer)llLinksetDataRead(KEY_ISOWNED);
}

/* -------------------- JSON TEMPLATE INITIALIZATION -------------------- */

init_json_templates() {
    // Blacklist: No access (actually on blacklist)
    JSON_TEMPLATE_BLACKLIST = llList2Json(JSON_OBJECT, [
        "type", "auth.acl.result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_BLACKLIST,
        "is_wearer", 0,
        "is_blacklisted", 1,
        "owner_set", 0
    ]);

    // Unauthorized: stranger with public off (not blacklisted, just no access)
    JSON_TEMPLATE_UNAUTHORIZED = llList2Json(JSON_OBJECT, [
        "type", "auth.acl.result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_BLACKLIST,
        "is_wearer", 0,
        "is_blacklisted", 0,
        "owner_set", "OWNER_SET_PLACEHOLDER"
    ]);

    // No Access: TPE wearer
    JSON_TEMPLATE_NOACCESS = llList2Json(JSON_OBJECT, [
        "type", "auth.acl.result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_NOACCESS,
        "is_wearer", 1,
        "is_blacklisted", 0,
        "owner_set", "OWNER_SET_PLACEHOLDER"
    ]);

    // Public: Non-wearer with public access
    JSON_TEMPLATE_PUBLIC = llList2Json(JSON_OBJECT, [
        "type", "auth.acl.result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_PUBLIC,
        "is_wearer", 0,
        "is_blacklisted", 0,
        "owner_set", "OWNER_SET_PLACEHOLDER"
    ]);

    // Owned: Wearer with owner set
    JSON_TEMPLATE_OWNED = llList2Json(JSON_OBJECT, [
        "type", "auth.acl.result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_OWNED,
        "is_wearer", 1,
        "is_blacklisted", 0,
        "owner_set", 1
    ]);

    // Trustee: Trustee access
    JSON_TEMPLATE_TRUSTEE = llList2Json(JSON_OBJECT, [
        "type", "auth.acl.result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_TRUSTEE,
        "is_wearer", 0,
        "is_blacklisted", 0,
        "owner_set", "OWNER_SET_PLACEHOLDER"
    ]);

    // Unowned: Wearer with no owner
    JSON_TEMPLATE_UNOWNED = llList2Json(JSON_OBJECT, [
        "type", "auth.acl.result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_UNOWNED,
        "is_wearer", 1,
        "is_blacklisted", 0,
        "owner_set", 0
    ]);

    // Primary Owner: Owner access
    JSON_TEMPLATE_PRIMARY = llList2Json(JSON_OBJECT, [
        "type", "auth.acl.result",
        "avatar", "AVATAR_PLACEHOLDER",
        "level", ACL_PRIMARY_OWNER,
        "is_wearer", 0,
        "is_blacklisted", 0,
        "owner_set", 1
    ]);
}

/* -------------------- JSON TEMPLATE RESPONSE BUILDER -------------------- */

send_acl_from_template(string template, key avatar, integer owner_set, string correlation_id) {
    string msg = template;

    msg = llJsonSetValue(msg, ["avatar"], (string)avatar);

    if (llSubStringIndex(msg, "OWNER_SET_PLACEHOLDER") != -1) {
        msg = llJsonSetValue(msg, ["owner_set"], (string)owner_set);
    }

    if (correlation_id != "") {
        msg = llJsonSetValue(msg, ["id"], correlation_id);
    }

    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

/* -------------------- ACL LEVEL COMPUTATION (DISPATCH ROUTER) -------------------- */

// Determine ACL level from the user record + flags and answer. One LSD
// read for named actors; wearer/stranger paths read the scalars.
route_acl_query(key avatar, string correlation_id) {
    integer role = user_role(avatar);

    // Blacklist first (most restrictive).
    if (role == ACL_BLACKLIST) {
        send_acl_from_template(JSON_TEMPLATE_BLACKLIST, avatar, 0, correlation_id);
        return;
    }

    // Owner (highest privilege).
    if (role == ACL_PRIMARY_OWNER) {
        send_acl_from_template(JSON_TEMPLATE_PRIMARY, avatar, 1, correlation_id);
        return;
    }

    integer owner_set = has_owner();

    // Wearer paths (the wearer never has a record).
    if (avatar == llGetOwner()) {
        if ((integer)llLinksetDataRead(KEY_TPE_MODE)) {
            send_acl_from_template(JSON_TEMPLATE_NOACCESS, avatar, owner_set, correlation_id);
            return;
        }
        if (owner_set) {
            send_acl_from_template(JSON_TEMPLATE_OWNED, avatar, 1, correlation_id);
            return;
        }
        send_acl_from_template(JSON_TEMPLATE_UNOWNED, avatar, 0, correlation_id);
        return;
    }

    // Trustee.
    if (role == ACL_TRUSTEE) {
        send_acl_from_template(JSON_TEMPLATE_TRUSTEE, avatar, owner_set, correlation_id);
        return;
    }

    // Public mode.
    if ((integer)llLinksetDataRead(KEY_PUBLIC_ACCESS)) {
        send_acl_from_template(JSON_TEMPLATE_PUBLIC, avatar, owner_set, correlation_id);
        return;
    }

    // Unauthorized stranger (not blacklisted, just no access).
    send_acl_from_template(JSON_TEMPLATE_UNAUTHORIZED, avatar, owner_set, correlation_id);
}

/* -------------------- ACL CHANGE BROADCAST -------------------- */

broadcast_acl_change(string scope, key avatar) {
    string msg = llList2Json(JSON_OBJECT, [
        "type", "auth.acl.update",
        "scope", scope,
        "avatar", (string)avatar
    ]);
    llMessageLinked(LINK_SET, AUTH_BUS, msg, NULL_KEY);
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_acl_query(string msg) {
    string av_str = llJsonGetValue(msg, ["avatar"]);
    if (av_str == JSON_INVALID) return;
    key av = (key)av_str;
    if (av == NULL_KEY) return;

    string correlation_id = llJsonGetValue(msg, ["id"]);
    if (correlation_id == JSON_INVALID) correlation_id = "";

    if (!SettingsReady) {
        if (llGetListLength(PendingQueries) / PENDING_STRIDE >= MAX_PENDING_QUERIES) {
            PendingQueries = llDeleteSubList(PendingQueries, 0, PENDING_STRIDE - 1);
        }
        PendingQueries += [av, correlation_id];
        return;
    }

    route_acl_query(av, correlation_id);
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {
        SettingsReady = FALSE;
        PendingQueries = [];
        AclUpdatePending = FALSE;

        init_json_templates();
    }

    link_message(integer sender, integer num, string msg, key id) {
        string msg_type = llJsonGetValue(msg, ["type"]);
        if (msg_type == JSON_INVALID) return;

        if (num == KERNEL_LIFECYCLE) {
            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
        }
        else if (num == AUTH_BUS) {
            if (msg_type == "auth.acl.query") {
                handle_acl_query(msg);
            }
        }
        else if (num == SETTINGS_BUS) {
            // First sync marks the roster usable (card parse done or no
            // card); queued boot-time queries drain against final state.
            if (msg_type == "settings.sync") {
                if (!SettingsReady) {
                    SettingsReady = TRUE;
                    broadcast_acl_change("global", NULL_KEY);
                }
                integer i = 0;
                while (i < llGetListLength(PendingQueries)) {
                    route_acl_query(llList2Key(PendingQueries, i),
                        llList2String(PendingQueries, i + 1));
                    i = i + PENDING_STRIDE;
                }
                PendingQueries = [];
            }
        }
    }

    // Roster/flag changes: any user.* record write/delete (or a flip of the
    // isowned/tpe/public scalars) arms a debounced auth.acl.update so
    // session-holding consumers (kmod_ui) invalidate. Card-parse bursts
    // collapse into a single broadcast.
    linkset_data(integer action, string name, string value) {
        if (action == LINKSETDATA_RESET) return;
        integer relevant = (llSubStringIndex(name, USER_PREFIX) == 0);
        if (!relevant) relevant = (name == KEY_ISOWNED);
        if (!relevant) relevant = (name == KEY_TPE_MODE);
        if (!relevant) relevant = (name == KEY_PUBLIC_ACCESS);
        if (!relevant) return;

        if (!AclUpdatePending) {
            AclUpdatePending = TRUE;
            llSetTimerEvent(ACL_UPDATE_DEBOUNCE);
        }
    }

    timer() {
        if (AclUpdatePending) {
            AclUpdatePending = FALSE;
            llSetTimerEvent(0.0);
            broadcast_acl_change("global", NULL_KEY);
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            llResetScript();
        }
    }
}

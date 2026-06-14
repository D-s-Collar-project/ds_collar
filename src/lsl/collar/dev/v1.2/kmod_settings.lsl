/*--------------------
MODULE: kmod_settings.lsl
VERSION: 1.2
REVISION: 3
PURPOSE: Notecard parser, validation guards, and LSD settings store
CHANGES:
- v1.2 rev 3: Version-stamped bootstrap + combined re-bootstrap. The sentinel now stores SCHEMA_VERSION (was "1") instead of a bare flag, so a roster-format upgrade is detected on boot: sentinel == current ⇒ LSD authoritative, just announce; absent or older ⇒ clear sentinel and re-bootstrap from whichever source exists — carded (existing notecard parse) OR cardless (migrate_legacy_roster converts the legacy access.owner / trustee / blacklist LSD keys into user.* records by replaying them through the same card builders, then deletes them; flag scalars are shared and untouched). Both paths converge on the new finalize_bootstrap() (manifest + stamp SCHEMA_VERSION + sync + notecard.loaded). Fixes the rev-2 "clean break re-seed from notecard" never firing because the persisted sentinel gated start_notecard_reading. CROSS-MODULE: kmod_auth gates readiness on the same SCHEMA_VERSION sentinel.
- v1.2 rev 2: User-record roster (/etc/passwd model). The 13 role-segregated keys (the access.owner- and access.trustee- parallel CSVs, access.multiowner, the blacklist.blklist- pair) are replaced by one record per person: user.<uuid> = "<acl>,<rank>,<name>,<honorific>" (acl 5/3/-1; rank orders owners, 0 = primary, and correlates card honorifics). Role exclusivity is structural (one record per uuid; a role write overwrites). access.multiowner KEPT as an explicit notecard-only POLICY flag (commitment semantics, never derived from count): off ⇒ the parser refuses extra card owners ("there can be only one"), on ⇒ several owner records permitted; runtime writes refused; preserved by reset-config. access.isowned kept as the derived fast flag. Card syntax unchanged: roster lines build records (uuid+honorific lines order-independent via EOF application; *names lines accepted-and-ignored; place access.multiowner BEFORE the owner lines). Name policy: username at write when in-region, else placeholder + async upgrade (display name for owners/trustees, username for blacklist); handle_name_response collapses to a single record-field update. Reset-config preserves owner records dynamically. CLEAN BREAK: no legacy keys, no migration — existing collars re-seed from the notecard.
- v1.2 rev 1: Blacklist display names parallel CSV (superseded by rev 2's records).
ARCHITECTURE: People live in user.<uuid> records (see USER RECORDS below);
              wearer and public are not records — they derive from
              access.isowned / tpe.mode / public.mode. Multi-owner is
              defined ONLY by the settings notecard listing several owners;
              the menu manages at most one (refusals guard the >1 case).
              Display names resolve asynchronously via llRequestDisplayName
              (owners/trustees) or llRequestUsername (blacklist).
              kmod_settings is the SOLE LSD WRITER for user.* records and
              for keys listed in MANAGED_SETTINGS_KEYS — plugins request
              writes via the CSV-envelope settings.delta / settings.delete
              protocol on SETTINGS_BUS, and roster changes via the dedicated
              owner/trustee/blacklist messages. The notecard is
              authoritative only for keys it itself provides: a
              card-ownership manifest records what the card set last parse,
              so on reload the card re-asserts its current keys and clears
              ones it has dropped, while runtime-set keys the card never
              listed survive (last-writer-wins between reloads).
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;

/* -------------------- SETTINGS KEYS -------------------- */
// Owned-state flag (derived from owner records; kept as a fast scalar for
// auth's wearer 2/4 split and external consumers).
string KEY_ISOWNED          = "access.isowned";

/* -------------------- USER RECORDS -------------------- */
// The people roster. One LSD key per person (/etc/passwd style):
//   user.<uuid> = "<acl>,<rank>,<name>,<honorific>"
// acl: 5 owner / 3 trustee / -1 blacklist (wearer and public are not
// records — they derive from isowned/tpe.mode/public.mode). rank orders
// owners (0 = primary) and correlates card honorifics; name and honorific
// are comma-stripped at write. Role exclusivity is structural: one record
// per uuid, a role write overwrites the previous role. kmod_settings is
// the sole writer of user.* (records replace the former parallel-CSV
// rosters: access.owner*/trustee* and blacklist.blklist*).
string USER_PREFIX = "user.";

// Multi-owner POLICY flag — notecard-only. Multiple owner records are
// permitted ONLY while this is 1. With it off (default), "there can be
// only one": the parser refuses extra card owners and the menu manages
// the single owner. Deliberately a stored flag, NOT derived from the
// owner count: the collar is a token of commitment, so restructuring its
// ownership must be an explicit act on the settings card — never an
// emergent state, never a menu click.
string KEY_MULTI_OWNER_MODE = "access.multiowner";

// Card-syntax tokens. The settings notecard keeps its established line
// syntax; these lines now BUILD user records instead of writing LSD keys
// of their own. *names lines are accepted-and-ignored (names resolve
// automatically).
string CARD_MULTI_OWNER     = "access.multiowner";
string CARD_OWNER           = "access.owner";
string CARD_OWNER_NAME      = "access.ownername";
string CARD_OWNER_HON       = "access.ownerhonorific";
string CARD_OWNER_UUIDS     = "access.owneruuids";
string CARD_OWNER_NAMES     = "access.ownernames";
string CARD_OWNER_HONS      = "access.ownerhonorifics";
string CARD_TRUSTEE_UUIDS   = "access.trusteeuuids";
string CARD_TRUSTEE_NAMES   = "access.trusteenames";
string CARD_TRUSTEE_HONS    = "access.trusteehonorifics";
string CARD_BLACKLIST       = "blacklist.blklistuuid";

// Other access flags
string KEY_RUNAWAY_ENABLED    = "access.enablerunaway";

// Behaviour scalars
string KEY_PUBLIC_ACCESS = "public.mode";
string KEY_TPE_MODE      = "tpe.mode";
string KEY_LOCKED        = "lock.locked";

// Bootstrap sentinel — holds the SCHEMA_VERSION the roster was last
// bootstrapped under. A plain restart whose sentinel already matches skips
// re-parsing (so script restarts can't re-arm a hostile notecard); a fresh
// install (absent) or a roster-format upgrade (older value) re-bootstraps.
// Also cleared by Reload Settings, Reset Config, CHANGED_INVENTORY
// notecard-changed, or llLinksetDataReset().
string KEY_SENTINEL = "settings.bootstrapped";

// Roster record-format version. BUMP this whenever the user.<uuid> record
// shape (or any roster key the boot path depends on) changes — an existing
// collar whose sentinel holds an older value then auto-re-bootstraps from
// whichever source is present (notecard, else legacy LSD keys). The value is
// a CROSS-MODULE CONTRACT: kmod_auth gates its readiness on the same string.
string SCHEMA_VERSION = "userrec-1";

// Card-ownership manifest — CSV of tokens the settings notecard provided on its
// last parse: "@owner"/"@trustees"/"@blacklist" units plus individual managed/
// generic LSD keys. On reparse we clear only what the card managed last time, so
// a key the card has dropped is removed while runtime-set keys the card never
// listed survive. Rebuilt into CardProvided each parse; persisted at finalize.
string KEY_CARDMANIFEST = "settings.cardmanifest";

// Placeholder used while a display name is being resolved
string NAME_LOADING = "(loading...)";

/* -------------------- NOTECARD CONFIG -------------------- */
string NOTECARD_NAME = "settings";
string COMMENT_PREFIX = "#";
string SEPARATOR = "=";

/* -------------------- STATE -------------------- */
key LastOwner = NULL_KEY;

key NotecardQuery = NULL_KEY;
integer NotecardLine = 0;
integer IsLoadingNotecard = FALSE;
key NotecardKey = NULL_KEY;

// Tokens recorded during the in-progress notecard parse (see KEY_CARDMANIFEST).
list CardProvided = [];

// Reset Config in-flight state. When TRUE, dataserver EOF routes to
// finalize_reset_config() instead of the normal bootstrap broadcast.
integer InResetConfig = FALSE;
list ResetConfigKeys   = [];
list ResetConfigValues = [];

integer MaxListLen = 64;

// Pending name queries (display-name or username): parallel lists. The
// response updates the matching user record's name field directly, so no
// role tag is needed.
list NameQueryIds   = [];
list NameQueryUuids = [];

// Card honorifics buffered during a parse: the card's honorific lines may
// precede or follow the uuid lines, so they're applied by rank at EOF
// (apply_card_honorifics) instead of inline.
list CardOwnerHons   = [];
list CardTrusteeHons = [];

/* -------------------- HELPERS -------------------- */

string get_msg_type(string msg) {
    string t = llJsonGetValue(msg, ["type"]);
    if (t == JSON_INVALID) return "";
    return t;
}

string normalize_bool(string s) {
    integer v = (integer)s;
    if (v != 0) v = 1;
    return (string)v;
}

list csv_read(string key_name) {
    string raw = llLinksetDataRead(key_name);
    if (raw == "") return [];
    return llCSV2List(raw);
}

csv_write(string key_name, list values) {
    if (llGetListLength(values) == 0) {
        llLinksetDataDelete(key_name);
    }
    else {
        llLinksetDataWrite(key_name, llList2CSV(values));
    }
}

list list_remove_at(list source_list, integer idx) {
    return llDeleteSubList(source_list, idx, idx);
}

/* -------------------- USER RECORD PRIMITIVES -------------------- */

// CSV field sanitizer — record fields may not contain commas.
string san_field(string s) {
    return llDumpList2String(llParseString2List(s, [","], []), " ");
}

string user_read(string uuid_str) {
    return llLinksetDataRead(USER_PREFIX + uuid_str);
}

user_write(string uuid_str, integer acl, integer rank, string name_str, string hon) {
    llLinksetDataWrite(USER_PREFIX + uuid_str, llDumpList2String(
        [(string)acl, (string)rank, san_field(name_str), san_field(hon)], ","));
}

user_delete(string uuid_str) {
    llLinksetDataDelete(USER_PREFIX + uuid_str);
}

// Role of a uuid: 5/3/-1, or 0 when no record. The acl is the record's
// leading field, so the integer cast parses it straight off the raw value.
integer user_role(string uuid_str) {
    string rec = user_read(uuid_str);
    if (rec == "") return 0;
    return (integer)rec;
}

// Update one field (2 = name, 3 = honorific) of an existing record.
user_set_field(string uuid_str, integer field_idx, string value) {
    string rec = user_read(uuid_str);
    if (rec == "") return;
    list f = llCSV2List(rec);
    f = llListReplaceList(f, [san_field(value)], field_idx, field_idx);
    llLinksetDataWrite(USER_PREFIX + uuid_str, llDumpList2String(f, ","));
}

list user_keys() {
    return llLinksetDataFindKeys("^user\\.", 0, -1);
}

// All uuids holding a role, rank-ordered (rank 0 first — the primary
// owner, and card-honorific correlation order for trustees).
list role_uuids(integer acl) {
    list ranked = [];   // strided [rank, uuid]
    list ks = user_keys();
    integer i = 0;
    integer n = llGetListLength(ks);
    while (i < n) {
        string k = llList2String(ks, i);
        string rec = llLinksetDataRead(k);
        if ((integer)rec == acl) {
            list f = llCSV2List(rec);
            ranked += [(integer)llList2String(f, 1), llGetSubString(k, 5, -1)];
        }
        i += 1;
    }
    if (llGetListLength(ranked) > 2) {
        ranked = llListSortStrided(ranked, 2, 0, TRUE);
    }
    list uuids = [];
    n = llGetListLength(ranked);
    i = 1;
    while (i < n) {
        uuids += [llList2String(ranked, i)];
        i += 2;
    }
    return uuids;
}

integer role_count(integer acl) {
    return llGetListLength(role_uuids(acl));
}

delete_role(integer acl) {
    list ks = user_keys();
    integer i = 0;
    integer n = llGetListLength(ks);
    while (i < n) {
        string k = llList2String(ks, i);
        if ((integer)llLinksetDataRead(k) == acl) {
            llLinksetDataDelete(k);
        }
        i += 1;
    }
}

// Multi-owner is an explicit POLICY flag (notecard-only), not a derived
// count — see KEY_MULTI_OWNER_MODE. Gates the menu owner.set/clear
// handlers and the parser's extra-owner refusal.
integer is_multi_owner_mode() {
    return (integer)llLinksetDataRead(KEY_MULTI_OWNER_MODE);
}

/* -------------------- BROADCASTING -------------------- */

broadcast_settings_changed() {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.sync"
    ]), NULL_KEY);
}

/* -------------------- CSV WRITE PROTOCOL (settings.delta / settings.delete) --

Single-writer protocol. Plugins send write requests as CSV (no JSON parsing
needed in kmod_settings — preserves the JSON-free invariant). Envelope:

    settings.delta:<key>:<value>     write/update LSD key (broadcasts sync)
    settings.delete:<key>            delete LSD key (exactly 2 fields; broadcasts)
    settings.seed:<key>:<value>      write the key's default ONLY IF ABSENT;
                                     no broadcast (bootstrap, not a change)

Strict arity. Trailing/extra separators are malformed and silently rejected.
is_writable_key gates which keys this protocol may mutate — plugin
registration keys (reg.*) and ACL policy keys (acl.policycontext:*)
remain plugin-owned and are NOT eligible. After every successful delta/delete,
broadcast_settings_changed fires settings.sync so consumers re-read; seed is
silent so bootstrap seeding (every plugin populating its defaults) does not
trigger a sync-storm.

-------------------- */

// Canonical list of LSD keys that kmod_settings manages on behalf of consumer
// plugins, writable via the settings.delta CSV protocol (is_writable_key gate).
// Notecard reload no longer blanket-clears this list; the card-ownership
// manifest (apply_card_manifest_clear) clears only keys the card itself
// provided, and consumers fall back to in-script defaults via
// lsd_int(key, fallback) when a key is absent.
// Grow this list as more plugins migrate to the single-writer protocol.
// @lsl-ide lsd-owner
list MANAGED_SETTINGS_KEYS = [
    "lock.locked",            // plugin_lock
    "public.mode",            // plugin_public
    "tpe.mode",               // plugin_tpe
    "folders.locked",         // plugin_folders
    "outfits.locked",         // plugin_outfits
    "plugin.outfit.active",   // plugin_outfits on/off toggle
    "relay.mode",             // plugin_relay
    "relay.hardcoremode",     // plugin_relay
    "chat.prefix",            // plugin_chat
    "chat.channel",           // plugin_chat
    "chat.public",            // plugin_chat
    "bell.visible",           // plugin_bell
    "bell.enablesound",       // plugin_bell
    "bell.volume",            // plugin_bell
    "bell.sound",             // plugin_bell
    "rlvex.ownertp",          // plugin_rlvex
    "rlvex.ownerim",          // plugin_rlvex
    "rlvex.trusteetp",        // plugin_rlvex
    "rlvex.trusteeim",        // plugin_rlvex
    "restrict.list",          // plugin_restrict
    "access.enablerunaway",   // plugin_access
    "leash.enhanced",         // plugin_leash (enhanced mode; delta-native + notecard "leash.enhanced = 0|1")
    // Keys still on the old settings.set JSON path (handle_set, dynamic key)
    // but conceptually owned by kmod_settings just the same. Listed here for
    // correct cross-script attribution; migrate these emitters to settings.delta
    // CSV in a future pass.
    "leash.leashedavatar",    // kmod_leash
    "leash.leasherkey",       // kmod_leash
    "leash.length",           // kmod_leash
    "leash.turnto",           // kmod_leash
    "leash.texture"           // kmod_leash
];

integer is_writable_key(string lsd_key) {
    return llListFindList(MANAGED_SETTINGS_KEYS, [lsd_key]) != -1;
}

handle_settings_delta_csv(string msg) {
    // KeepNulls preserves a trailing empty token. With llParseString2List
    // the message `settings.delta:foo:` parsed to length 2 and was silently
    // dropped — a caller asking to set foo="" got no write, leaving a
    // stale value in LSD. Manifested as plugin_folders/plugin_restrict
    // unlock-to-empty leaving stale CSV that re-locked on next sync.
    list parts = llParseStringKeepNulls(msg, [":"], []);
    if (llGetListLength(parts) != 3) return;
    string lsd_key = llList2String(parts, 1);
    string value   = llList2String(parts, 2);
    if (lsd_key == "" || !is_writable_key(lsd_key)) return;
    llLinksetDataWrite(lsd_key, value);
    broadcast_settings_changed();
}

handle_settings_delete_csv(string msg) {
    list parts = llParseString2List(msg, [":"], []);
    if (llGetListLength(parts) != 2) return;
    string lsd_key = llList2String(parts, 1);
    if (lsd_key == "" || !is_writable_key(lsd_key)) return;
    llLinksetDataDelete(lsd_key);
    broadcast_settings_changed();
}

handle_settings_seed_csv(string msg) {
    // Seed a plugin's default: write ONLY IF ABSENT, and do NOT broadcast.
    // Each plugin seeds its own managed keys at bootstrap (defaults live in the
    // plugins, not a central table) so LSD becomes a complete, self-describing
    // picture — no consumer ever has to guess a default at read time. Because a
    // seeded value equals the default the plugin would have fallen back to, it
    // is not a "change": broadcasting would only trigger a needless sync-storm
    // as every plugin seeds during bootstrap. Absent is the only "unset" state,
    // so an already-present key (even "") is never overwritten.
    list parts = llParseStringKeepNulls(msg, [":"], []);
    if (llGetListLength(parts) != 3) return;
    string lsd_key = llList2String(parts, 1);
    string value   = llList2String(parts, 2);
    if (lsd_key == "" || !is_writable_key(lsd_key)) return;
    if (llLinksetDataRead(lsd_key) != "") return;   // already set — never clobber
    llLinksetDataWrite(lsd_key, value);
}

/* -------------------- LSD CLEAR & FACTORY RESET -------------------- */

clear_owner_keys() {
    delete_role(5);
    llLinksetDataDelete(KEY_ISOWNED);
}

clear_trustee_keys() {
    delete_role(3);
}

/* -------------------- CARD-OWNERSHIP MANIFEST -------------------- */

// Record a manifest token the current parse provided (deduped).
record_card_key(string tok) {
    if (llListFindList(CardProvided, [tok]) == -1) CardProvided += [tok];
}

// Pre-parse clear: remove only what the card managed on its last parse. Units
// map to the family-clear helpers; every other token is a single LSD key.
// Card-present keys are re-written by the parse; dropped ones stay cleared;
// runtime-set keys the card never listed are never touched.
apply_card_manifest_clear() {
    list old_manifest = csv_read(KEY_CARDMANIFEST);
    integer i;
    integer n = llGetListLength(old_manifest);
    for (i = 0; i < n; i++) {
        string tok = llList2String(old_manifest, i);
        if      (tok == "@owner")     clear_owner_keys();
        else if (tok == "@trustees")  clear_trustee_keys();
        else if (tok == "@blacklist") delete_role(-1);
        else                          llLinksetDataDelete(tok);
    }
}

// Persist the manifest built during this parse (csv_write deletes when empty).
finalize_card_manifest() {
    csv_write(KEY_CARDMANIFEST, CardProvided);
}

// Shared bootstrap tail for BOTH re-bootstrap sources (carded notecard EOF and
// cardless legacy migration): persist the card manifest, stamp the sentinel
// with the CURRENT schema version (this is the signal kmod_auth gates on, so it
// marks "roster is final under this format"), announce, and notify the kernel.
finalize_bootstrap() {
    finalize_card_manifest();
    llLinksetDataWrite(KEY_SENTINEL, SCHEMA_VERSION);
    broadcast_settings_changed();
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "settings.notecard.loaded"
    ]), NULL_KEY);
}

factory_reset() {
    llRegionSayTo(llGetOwner(), 0, "Collar factory reset triggered.");

    // Zero-trust: assume the notecard is poisoned (an abusive owner could
    // have baked owner/lock/restriction values into it). Remove it before
    // wiping so post-reset state_entry can't re-arm the collar from card.
    // The queued CHANGED_INVENTORY event is wiped by llResetScript below.
    if (llGetInventoryType(NOTECARD_NAME) == INVENTORY_NOTECARD) {
        llRemoveInventory(NOTECARD_NAME);
    }

    llLinksetDataReset();

    // Reset all scripts in the linkset
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.reset.factory",
        "from", "factory_reset"
    ]), NULL_KEY);

    llResetScript();
}

/* -------------------- VALIDATION HELPERS -------------------- */

// Returns TRUE if any external owner exists. Records never contain the
// wearer or NULL_KEY (guarded at every write), so any owner record counts.
integer has_external_owner() {
    return role_count(5) > 0;
}


/* -------------------- ASYNC NAME RESOLUTION -------------------- */

// Display-name upgrade for owners/trustees.
request_name(string uuid_str) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) return;
    key qid = llRequestDisplayName((key)uuid_str);
    NameQueryIds   += [qid];
    NameQueryUuids += [uuid_str];
}

// Username variant — the blacklist's human-readable fallback for avatars
// who may be absent (usernames are stable; display names can churn).
// Replies route through the same dataserver → handle_name_response path.
request_username(string uuid_str) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) return;
    key qid = llRequestUsername((key)uuid_str);
    NameQueryIds   += [qid];
    NameQueryUuids += [uuid_str];
}

// One response path for every role: a resolved name just updates the
// record's name field, if the record still exists. The four per-roster
// branches of the CSV era collapsed into this.
handle_name_response(key query_id, string name) {
    integer idx = llListFindList(NameQueryIds, [query_id]);
    if (idx == -1) return;

    string uuid_str = llList2String(NameQueryUuids, idx);

    NameQueryIds   = list_remove_at(NameQueryIds, idx);
    NameQueryUuids = list_remove_at(NameQueryUuids, idx);

    if (name == "") return;
    if (user_read(uuid_str) == "") return;

    user_set_field(uuid_str, 2, name);
    broadcast_settings_changed();
}

/* -------------------- INTERNAL MUTATORS -------------------- */

// Menu owner set: single-owner semantics — replaces the current owner
// record. Role exclusivity is structural: user_write overwrites whatever
// role the uuid previously held. Name: username when resolvable in-region,
// else "(loading...)"; either way an async display-name upgrade is fired.
integer set_owner_record(string uuid_str, string honorific) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) return FALSE;
    if ((key)uuid_str == llGetOwner()) {
        llRegionSayTo(llGetOwner(), 0, "ERROR: Cannot add wearer as owner (role separation required)");
        return FALSE;
    }

    delete_role(5);

    string nm = llGetUsername((key)uuid_str);
    if (nm == "") nm = NAME_LOADING;
    user_write(uuid_str, 5, 0, nm, honorific);
    llLinksetDataWrite(KEY_ISOWNED, "1");

    request_name(uuid_str);
    return TRUE;
}

clear_owner_records() {
    delete_role(5);
    llLinksetDataDelete(KEY_ISOWNED);
}

integer add_trustee_internal(string uuid_str, string honorific) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) return FALSE;
    if ((key)uuid_str == llGetOwner()) return FALSE;
    if (user_role(uuid_str) == 5) return FALSE;
    if (user_role(uuid_str) == 3) return FALSE;
    if (role_count(3) >= MaxListLen) return FALSE;

    // Overwrites a blacklist record for this uuid, if any (exclusivity).
    string nm = llGetUsername((key)uuid_str);
    if (nm == "") nm = NAME_LOADING;
    user_write(uuid_str, 3, role_count(3), nm, honorific);

    request_name(uuid_str);
    return TRUE;
}

integer remove_trustee_internal(string uuid_str) {
    if (user_role(uuid_str) != 3) return FALSE;
    user_delete(uuid_str);
    return TRUE;
}

integer add_blacklist_internal(string uuid_str, string name_str) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) return FALSE;
    if ((key)uuid_str == llGetOwner()) return FALSE;
    if (user_role(uuid_str) == 5) return FALSE;
    if (user_role(uuid_str) == 3) return FALSE;
    if (user_role(uuid_str) == -1) return FALSE;
    if (role_count(-1) >= MaxListLen) return FALSE;

    // Name chain: provided (picker resolves while the avatar is in-region)
    // → username → UUID placeholder + async username upgrade.
    string nm = san_field(name_str);
    if (nm == "") nm = llGetUsername((key)uuid_str);
    if (nm == "") {
        nm = uuid_str;
        request_username(uuid_str);
    }

    user_write(uuid_str, -1, 0, nm, "");
    return TRUE;
}

integer remove_blacklist_internal(string uuid_str) {
    if (user_role(uuid_str) != -1) return FALSE;
    user_delete(uuid_str);
    return TRUE;
}

/* -------------------- CARD ROSTER BUILDERS -------------------- */

// Append an owner from the card. rank = current owner count, so card
// order is preserved (rank 0 = primary). With multi-owner mode OFF
// (default), "there can be only one": extra card owners are refused.
card_add_owner(string uuid_str) {
    key u = (key)uuid_str;
    if (u == NULL_KEY || u == llGetOwner()) return;
    if (user_role(uuid_str) == 5) return;

    if (!is_multi_owner_mode() && role_count(5) >= 1) {
        llRegionSayTo(llGetOwner(), 0,
            "WARNING: Multi-owner mode is off — additional card owner ignored. Set access.multiowner = 1 BEFORE the owner lines to allow several owners.");
        return;
    }

    string nm = llGetUsername(u);
    if (nm == "") nm = NAME_LOADING;
    user_write(uuid_str, 5, role_count(5), nm, "");
    llLinksetDataWrite(KEY_ISOWNED, "1");
    request_name(uuid_str);
}

card_add_trustee(string uuid_str) {
    key u = (key)uuid_str;
    if (u == NULL_KEY || u == llGetOwner()) return;
    if (user_role(uuid_str) == 5) return;
    if (user_role(uuid_str) == 3) return;
    if (role_count(3) >= MaxListLen) return;

    string nm = llGetUsername(u);
    if (nm == "") nm = NAME_LOADING;
    user_write(uuid_str, 3, role_count(3), nm, "");
    request_name(uuid_str);
}

// Apply card honorific lines at EOF, by rank, so the card's uuid and
// honorific lines work in either order.
apply_card_honorifics() {
    list owners = role_uuids(5);
    integer n = llGetListLength(CardOwnerHons);
    if (n > llGetListLength(owners)) n = llGetListLength(owners);
    integer i = 0;
    while (i < n) {
        user_set_field(llList2String(owners, i), 3, llList2String(CardOwnerHons, i));
        i += 1;
    }

    list trustees = role_uuids(3);
    n = llGetListLength(CardTrusteeHons);
    if (n > llGetListLength(trustees)) n = llGetListLength(trustees);
    i = 0;
    while (i < n) {
        user_set_field(llList2String(trustees, i), 3, llList2String(CardTrusteeHons, i));
        i += 1;
    }

    CardOwnerHons = [];
    CardTrusteeHons = [];
}

// Cardless re-bootstrap: convert any legacy roster keys still in LSD into
// user.<uuid> records. The legacy (pre-record) format stored the roster under
// the SAME key names the notecard uses (access.owner*/trustee*, blacklist.*),
// so this replays them through the exact card builders — same dedup, rank, and
// honorific-by-rank rules. Flag scalars (isowned/public/tpe/lock/multiowner)
// are unchanged keys and need no conversion. Used on an update that ships no
// notecard, where the legacy LSD keys are the only roster source. A no-op when
// none are present (e.g. a collar already on this schema). Defined after the
// card builders it reuses — LSL has no forward references.
migrate_legacy_roster() {
    integer i;
    integer n;
    list items;

    // Owners: multi-owner list preferred, else the single-owner scalar.
    string owners_csv = llLinksetDataRead(CARD_OWNER_UUIDS);
    if (owners_csv != "") {
        items = llCSV2List(owners_csv);
        n = llGetListLength(items);
        if (n > MaxListLen) n = MaxListLen;
        for (i = 0; i < n; i++) card_add_owner(llList2String(items, i));
        string ohons = llLinksetDataRead(CARD_OWNER_HONS);
        if (ohons != "") CardOwnerHons = llCSV2List(ohons);
    }
    else {
        string owner1 = llLinksetDataRead(CARD_OWNER);
        if (owner1 != "") {
            card_add_owner(owner1);
            string ohon1 = llLinksetDataRead(CARD_OWNER_HON);
            if (ohon1 != "") CardOwnerHons = [ohon1];
        }
    }

    // Trustees.
    string tru_csv = llLinksetDataRead(CARD_TRUSTEE_UUIDS);
    if (tru_csv != "") {
        items = llCSV2List(tru_csv);
        n = llGetListLength(items);
        if (n > MaxListLen) n = MaxListLen;
        for (i = 0; i < n; i++) card_add_trustee(llList2String(items, i));
        string thons = llLinksetDataRead(CARD_TRUSTEE_HONS);
        if (thons != "") CardTrusteeHons = llCSV2List(thons);
    }

    // Blacklist.
    string bl_csv = llLinksetDataRead(CARD_BLACKLIST);
    if (bl_csv != "") {
        items = llCSV2List(bl_csv);
        n = llGetListLength(items);
        if (n > MaxListLen) n = MaxListLen;
        for (i = 0; i < n; i++) add_blacklist_internal(llList2String(items, i), "");
    }

    // Apply buffered honorifics by rank (mirrors the card EOF step).
    apply_card_honorifics();

    // Drop the now-converted legacy roster keys; the flag scalars stay.
    llLinksetDataDelete(CARD_OWNER);
    llLinksetDataDelete(CARD_OWNER_NAME);
    llLinksetDataDelete(CARD_OWNER_HON);
    llLinksetDataDelete(CARD_OWNER_UUIDS);
    llLinksetDataDelete(CARD_OWNER_NAMES);
    llLinksetDataDelete(CARD_OWNER_HONS);
    llLinksetDataDelete(CARD_TRUSTEE_UUIDS);
    llLinksetDataDelete(CARD_TRUSTEE_NAMES);
    llLinksetDataDelete(CARD_TRUSTEE_HONS);
    llLinksetDataDelete(CARD_BLACKLIST);
}

/* -------------------- NOTECARD PARSING -------------------- */

parse_notecard_line(string line) {
    line = llStringTrim(line, STRING_TRIM);
    if (line == "") return;
    if (llGetSubString(line, 0, 0) == COMMENT_PREFIX) return;

    integer sep_pos = llSubStringIndex(line, SEPARATOR);
    if (sep_pos == -1) return;

    string key_name = llStringTrim(llGetSubString(line, 0, sep_pos - 1), STRING_TRIM);
    string value    = llStringTrim(llGetSubString(line, sep_pos + 1, -1), STRING_TRIM);

    // Provenance: record which manifest token this card line contributes, so a
    // later reload that drops the line clears it (runtime-only keys, never
    // recorded here, survive). Owner/trustee/blacklist collapse to family units.
    if (key_name == CARD_OWNER || key_name == CARD_OWNER_HON
        || key_name == CARD_OWNER_UUIDS || key_name == CARD_OWNER_NAMES
        || key_name == CARD_OWNER_HONS) {
        record_card_key("@owner");
    }
    else if (key_name == CARD_TRUSTEE_UUIDS || key_name == CARD_TRUSTEE_NAMES
        || key_name == CARD_TRUSTEE_HONS) {
        record_card_key("@trustees");
    }
    else if (key_name == CARD_BLACKLIST) {
        record_card_key("@blacklist");
    }
    else if (llSubStringIndex(key_name, ".") != -1) {
        record_card_key(key_name);
    }

    // Multi-owner policy flag (notecard-only). Card convention: place it
    // BEFORE the owner lines — the parser enforces single-owner as it
    // reads, so a late flag can't retroactively admit dropped owners.
    if (key_name == CARD_MULTI_OWNER) {
        llLinksetDataWrite(KEY_MULTI_OWNER_MODE, normalize_bool(value));
        return;
    }

    // No-op roster lines: *names resolve automatically — accept and ignore.
    if (key_name == CARD_OWNER_NAMES) return;
    if (key_name == CARD_TRUSTEE_NAMES) return;
    if (key_name == CARD_OWNER_NAME) return;

    // Owner lines — each uuid becomes a rank-ordered owner record.
    if (key_name == CARD_OWNER) {
        card_add_owner(value);
        return;
    }
    if (key_name == CARD_OWNER_UUIDS) {
        list uuids = llCSV2List(value);
        if (llGetListLength(uuids) > MaxListLen) {
            uuids = llList2List(uuids, 0, MaxListLen - 1);
        }
        integer i;
        integer len = llGetListLength(uuids);
        for (i = 0; i < len; i++) {
            card_add_owner(llList2String(uuids, i));
        }
        return;
    }

    // Honorific lines are buffered and applied by rank at EOF, so the
    // card's uuid and honorific lines work in either order.
    if (key_name == CARD_OWNER_HON) {
        CardOwnerHons = [value];
        return;
    }
    if (key_name == CARD_OWNER_HONS) {
        CardOwnerHons = llCSV2List(value);
        return;
    }
    if (key_name == CARD_TRUSTEE_HONS) {
        CardTrusteeHons = llCSV2List(value);
        return;
    }

    // Trustee uuids
    if (key_name == CARD_TRUSTEE_UUIDS) {
        list uuids = llCSV2List(value);
        if (llGetListLength(uuids) > MaxListLen) {
            uuids = llList2List(uuids, 0, MaxListLen - 1);
        }
        integer i;
        integer len = llGetListLength(uuids);
        for (i = 0; i < len; i++) {
            card_add_trustee(llList2String(uuids, i));
        }
        return;
    }

    // Blacklist uuids. NOTE: like TPE-after-owner, exclusivity checks here
    // see only roles defined EARLIER in the card — list owners/trustees
    // before the blacklist line (established card convention).
    if (key_name == CARD_BLACKLIST) {
        list bl = llCSV2List(value);
        if (llGetListLength(bl) > MaxListLen) {
            bl = llList2List(bl, 0, MaxListLen - 1);
        }
        integer i;
        integer len = llGetListLength(bl);
        for (i = 0; i < len; i++) {
            add_blacklist_internal(llList2String(bl, i), "");
        }
        return;
    }

    // Boolean scalars
    if (key_name == KEY_PUBLIC_ACCESS
        || key_name == KEY_LOCKED
        || key_name == KEY_RUNAWAY_ENABLED
        || key_name == KEY_ISOWNED) {
        llLinksetDataWrite(key_name, normalize_bool(value));
        return;
    }

    // TPE — requires external owner
    if (key_name == KEY_TPE_MODE) {
        value = normalize_bool(value);
        if ((integer)value == 1 && !has_external_owner()) {
            llRegionSayTo(llGetOwner(), 0, "ERROR: Cannot enable TPE via notecard - requires external owner");
            llRegionSayTo(llGetOwner(), 0, "HINT: Set owner BEFORE tpe.mode in notecard");
            return;
        }
        llLinksetDataWrite(KEY_TPE_MODE, value);
        return;
    }

    // Generic plugin scalars (any other dotted key) — write through.
    // user.* records are kmod_settings-internal: a card may only define
    // people via the roster lines above, never by raw record writes.
    if (llSubStringIndex(key_name, USER_PREFIX) == 0) return;
    if (llSubStringIndex(key_name, ".") != -1) {
        llLinksetDataWrite(key_name, value);
    }
}

integer start_notecard_reading() {
    // Sentinel-gated: callers wanting an explicit re-parse (Reload Settings,
    // Reset Config, CHANGED_INVENTORY notecard-changed) must clear the
    // sentinel first. Boot/restart paths fall through this guard so a
    // hostile notecard cannot self-arm a wiped collar.
    CardProvided = [];   // reset provenance accumulator for this parse
    CardOwnerHons = [];
    CardTrusteeHons = [];
    if (llLinksetDataRead(KEY_SENTINEL) != "") return FALSE;

    if (llGetInventoryType(NOTECARD_NAME) != INVENTORY_NOTECARD) {
        return FALSE;
    }
    // Clear only what the card itself managed on its last parse (the manifest),
    // so a key the card has since dropped is removed, while runtime-set keys the
    // card never listed survive. Card-present keys are re-asserted by the parse.
    apply_card_manifest_clear();

    IsLoadingNotecard = TRUE;
    NotecardLine = 0;
    NotecardQuery = llGetNotecardLine(NOTECARD_NAME, NotecardLine);
    return TRUE;
}

/* -------------------- MESSAGE HANDLERS -------------------- */

handle_settings_get() {
    // UI contract ("Reload Settings" button): re-read the notecard and let
    // plugins resync from the refreshed LSD. Falling back to a plain
    // rebroadcast when no notecard is present or a reload is already in
    // flight — broadcast_settings_changed will also fire from the EOF
    // branch of the dataserver handler once the in-flight read completes.
    if (IsLoadingNotecard) return;

    // Reload Settings is an explicit re-arm: clear the sentinel so
    // start_notecard_reading() proceeds past its bootstrap guard.
    llLinksetDataDelete(KEY_SENTINEL);

    if (!start_notecard_reading()) {
        broadcast_settings_changed();
    }
}

// Generic scalar set for non-access keys (and a few access scalars).
// Owner/trustee/blacklist data must use the dedicated handlers below.
handle_set(string msg) {
    string key_name = llJsonGetValue(msg, ["key"]);
    if (key_name == JSON_INVALID) return;

    string value = llJsonGetValue(msg, ["value"]);
    if (value == JSON_INVALID) return;

    // Refuse direct roster writes: user.* records mutate ONLY through the
    // dedicated owner/trustee/blacklist handlers, and the legacy roster
    // key names no longer exist as LSD keys. The multi-owner policy flag
    // is notecard-only (commitment semantics — never runtime-settable).
    if (llSubStringIndex(key_name, USER_PREFIX) == 0) return;
    if (key_name == KEY_MULTI_OWNER_MODE) return;

    // Boolean normalization
    if (key_name == KEY_PUBLIC_ACCESS
        || key_name == KEY_LOCKED
        || key_name == KEY_RUNAWAY_ENABLED
        || key_name == KEY_ISOWNED) {
        value = normalize_bool(value);
    }

    // TPE validation
    if (key_name == KEY_TPE_MODE) {
        value = normalize_bool(value);
        if ((integer)value == 1 && !has_external_owner()) {
            llRegionSayTo(llGetOwner(), 0, "ERROR: Cannot enable TPE - requires external owner");
            return;
        }
    }

    // isowned = 0 → factory reset trigger
    if (key_name == KEY_ISOWNED && value == "0") {
        factory_reset();
        return;
    }

    if (llLinksetDataRead(key_name) == value) return;
    llLinksetDataWrite(key_name, value);
    broadcast_settings_changed();
}

handle_set_owner(string msg) {
    if (is_multi_owner_mode()) {
        llRegionSayTo(llGetOwner(), 0, "ERROR: Cannot set owner via menu in multi-owner mode (notecard managed)");
        return;
    }

    string uuid_str  = llJsonGetValue(msg, ["uuid"]);
    string honorific = llJsonGetValue(msg, ["honorific"]);
    if (uuid_str == JSON_INVALID || honorific == JSON_INVALID) return;

    if (set_owner_record(uuid_str, honorific)) {
        broadcast_settings_changed();
    }
}

handle_clear_owner() {
    if (is_multi_owner_mode()) {
        llRegionSayTo(llGetOwner(), 0, "ERROR: Cannot clear owner via menu in multi-owner mode (notecard managed)");
        return;
    }
    clear_owner_records();
    broadcast_settings_changed();
}

handle_add_trustee(string msg) {
    string uuid_str  = llJsonGetValue(msg, ["uuid"]);
    string honorific = llJsonGetValue(msg, ["honorific"]);
    if (uuid_str == JSON_INVALID || honorific == JSON_INVALID) return;

    if (add_trustee_internal(uuid_str, honorific)) {
        broadcast_settings_changed();
    }
}

handle_remove_trustee(string msg) {
    string uuid_str = llJsonGetValue(msg, ["uuid"]);
    if (uuid_str == JSON_INVALID) return;

    if (remove_trustee_internal(uuid_str)) {
        broadcast_settings_changed();
    }
}

handle_blacklist_add(string msg) {
    string uuid_str = llJsonGetValue(msg, ["uuid"]);
    if (uuid_str == JSON_INVALID) return;

    // Optional display name captured by the sender at add-time (the avatar
    // is in-region during the picker flow, so resolution is reliable there).
    string name_str = llJsonGetValue(msg, ["name"]);
    if (name_str == JSON_INVALID) name_str = "";

    if (add_blacklist_internal(uuid_str, name_str)) {
        broadcast_settings_changed();
    }
}

handle_blacklist_remove(string msg) {
    string uuid_str = llJsonGetValue(msg, ["uuid"]);
    if (uuid_str == JSON_INVALID) return;

    if (remove_blacklist_internal(uuid_str)) {
        broadcast_settings_changed();
    }
}

handle_runaway() {
    factory_reset();
}

/* -------------------- RESET CONFIG (preserve owner+lock) -------------------- */

// Reset Config: wipe LSD except owner block and lock state, then re-parse the
// notecard so its defaults re-populate everything else. Card writes win for
// any key the card touches; preserved values fill the slots the card is
// silent on. Sentinel is set on completion so subsequent restarts don't
// re-parse. Trust assumption: wearer is consenting and the notecard is fine.
// Abuse-recovery is the Runaway path, not this.
handle_reset_config() {
    // Preserve the owner block (every acl-5 user record) + flags. Keys are
    // enumerated dynamically; the snapshot/restore loops below are generic.
    ResetConfigKeys = [KEY_ISOWNED, KEY_MULTI_OWNER_MODE, KEY_LOCKED];
    list ks = user_keys();
    integer ki;
    integer kn = llGetListLength(ks);
    for (ki = 0; ki < kn; ki++) {
        string uk = llList2String(ks, ki);
        if ((integer)llLinksetDataRead(uk) == 5) {
            ResetConfigKeys += [uk];
        }
    }
    ResetConfigValues = [];

    integer i;
    integer n = llGetListLength(ResetConfigKeys);
    for (i = 0; i < n; i++) {
        ResetConfigValues += [llLinksetDataRead(llList2String(ResetConfigKeys, i))];
    }

    llRegionSayTo(llGetOwner(), 0, "Resetting configuration...");

    // Wipe LSD. Sentinel is removed implicitly so start_notecard_reading
    // below will proceed. Notecard stays in inventory (preserve trust).
    llLinksetDataReset();

    InResetConfig = TRUE;

    if (!start_notecard_reading()) {
        // No notecard — restore + finalize immediately.
        finalize_reset_config();
    }
    // else: dataserver chain runs; EOF routes to finalize_reset_config.
}

finalize_reset_config() {
    integer i;
    integer n = llGetListLength(ResetConfigKeys);
    for (i = 0; i < n; i++) {
        string k = llList2String(ResetConfigKeys, i);
        if (llLinksetDataRead(k) == "") {
            string v = llList2String(ResetConfigValues, i);
            if (v != "") {
                llLinksetDataWrite(k, v);
            }
        }
    }

    // Persist the card manifest (the restored owner/lock keys are runtime-owned
    // and intentionally not in it), then mark bootstrap complete.
    finalize_card_manifest();
    llLinksetDataWrite(KEY_SENTINEL, SCHEMA_VERSION);

    InResetConfig = FALSE;
    ResetConfigKeys = [];
    ResetConfigValues = [];

    // Tell other plugins to reset against the final LSD state.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.reset.factory",
        "from", "reset_config"
    ]), NULL_KEY);

    broadcast_settings_changed();
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {

        LastOwner = llGetOwner();
        NotecardKey = llGetInventoryKey(NOTECARD_NAME);

        // Already bootstrapped under the CURRENT schema: LSD is authoritative,
        // just announce so consumers resync. (Sentinel-gated re-parse is
        // intentionally skipped here so a plain restart can't re-arm a card.)
        if (llLinksetDataRead(KEY_SENTINEL) == SCHEMA_VERSION) {
            broadcast_settings_changed();
            return;
        }

        // Fresh install (sentinel absent) OR a roster-format upgrade (sentinel
        // holds an older value). Drop the stale sentinel so start_notecard_reading
        // proceeds and so ACL consumers queue until the new roster is stamped,
        // then re-bootstrap from whichever source exists.
        llLinksetDataDelete(KEY_SENTINEL);

        if (start_notecard_reading()) {
            // Carded: dataserver EOF runs finalize_bootstrap().
            return;
        }

        // Cardless (e.g. an update that ships no notecard): convert any legacy
        // roster keys left in LSD into user.* records, then finalize.
        migrate_legacy_roster();
        finalize_bootstrap();
    }

    on_rez(integer start_param) {
        key current_owner = llGetOwner();
        if (current_owner != LastOwner) {
            LastOwner = current_owner;
            llResetScript();
        }
    }

    attach(key id) {
        if (id == NULL_KEY) return;

        key current_owner = llGetOwner();
        if (current_owner != LastOwner) {
            LastOwner = current_owner;
            llResetScript();
        }
    }

    changed(integer change) {
        if (change & CHANGED_OWNER) {
            key current_owner = llGetOwner();
            if (current_owner != LastOwner) {
                LastOwner = current_owner;
                llResetScript();
            }
        }

        if (change & CHANGED_INVENTORY) {
            key current_notecard_key = llGetInventoryKey(NOTECARD_NAME);
            if (current_notecard_key != NotecardKey) {
                if (current_notecard_key == NULL_KEY) {
                    // Notecard removed → factory reset
                    factory_reset();
                }
                else {
                    // Wearer/owner swapped or edited the notecard. Clear the
                    // bootstrap sentinel so start_notecard_reading proceeds —
                    // the new card is an explicit re-arm signal.
                    NotecardKey = current_notecard_key;
                    llLinksetDataDelete(KEY_SENTINEL);
                    start_notecard_reading();
                }
            }
        }
    }

    dataserver(key query_id, string data) {
        // Notecard line read
        if (query_id == NotecardQuery) {
            if (data != EOF) {
                parse_notecard_line(data);
                NotecardLine += 1;
                NotecardQuery = llGetNotecardLine(NOTECARD_NAME, NotecardLine);
            }
            else {
                IsLoadingNotecard = FALSE;

                // Card honorific lines apply by rank now that every card
                // uuid line has been processed (order-independent cards).
                apply_card_honorifics();

                if (InResetConfig) {
                    // Reset Config in flight: restore preserved keys for any
                    // slot the card was silent on, set sentinel, broadcast.
                    finalize_reset_config();
                }
                else {
                    // Normal bootstrap completion (carded). Persist the card
                    // manifest, stamp the schema-versioned sentinel, announce.
                    finalize_bootstrap();
                }
            }
            return;
        }

        // Display name response
        handle_name_response(query_id, data);
    }

    link_message(integer sender, integer num, string msg, key id) {
        // CSV envelope (single-writer protocol) — detect before JSON parsing
        // so kmod_settings stays JSON-free for the new write path.
        if (num == SETTINGS_BUS) {
            if (llSubStringIndex(msg, "settings.delta:") == 0) {
                handle_settings_delta_csv(msg);
                return;
            }
            if (llSubStringIndex(msg, "settings.delete:") == 0) {
                handle_settings_delete_csv(msg);
                return;
            }
            if (llSubStringIndex(msg, "settings.seed:") == 0) {
                handle_settings_seed_csv(msg);
                return;
            }
        }

        string msg_type = get_msg_type(msg);
        if (msg_type == "") return;

        if (num == KERNEL_LIFECYCLE) {
            // External kernel-driven reset (e.g., owner-change wipe in
            // collar_kernel). Just llResetScript — do NOT remove the
            // notecard. Notecard removal stays exclusive to the wearer
            // Runaway path (handle_runaway → factory_reset).
            if (msg_type == "kernel.reset.soft" || msg_type == "kernel.reset.factory") {
                llResetScript();
            }
            return;
        }

        if (num != SETTINGS_BUS) return;

        if      (msg_type == "settings.get")            handle_settings_get();
        else if (msg_type == "settings.set")            handle_set(msg);
        else if (msg_type == "settings.owner.set")       handle_set_owner(msg);
        else if (msg_type == "settings.owner.clear")     handle_clear_owner();
        else if (msg_type == "settings.trustee.add")     handle_add_trustee(msg);
        else if (msg_type == "settings.trustee.remove")  handle_remove_trustee(msg);
        else if (msg_type == "settings.blacklist.add")   handle_blacklist_add(msg);
        else if (msg_type == "settings.blacklist.remove") handle_blacklist_remove(msg);
        else if (msg_type == "settings.runaway")        handle_runaway();
        else if (msg_type == "settings.reset.config")   handle_reset_config();
    }
}

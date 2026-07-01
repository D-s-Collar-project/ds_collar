/*--------------------
MODULE: kmod_settings.lsl
VERSION: 1.2
REVISION: 10
PURPOSE: Validation guards, roster conversion, and LSD settings store
CHANGES:
- v1.2 rev 10 [experimental]: Card is a ONE-TIME seed, not a re-parseable config. migrate_legacy_roster → seed_card_roster, NON-destructive: the owner overwrites ONLY when the card declares one (card-over-LSD scalar); trustees/blacklist UNION in (a card silent on them never clears UI-set entries — fixes the blacklist wiped on update/reload). isOwned is DERIVED from the roster post-seed, not read as a card flag. process_streamed_card now self-deletes the card after seeding (new CardConsumed flag marks the removal benign so changed() doesn't read it as a hostile card-removal → factory_reset). With no card on disk there is nothing to re-parse, so LSD is the sole source of truth and a re-read can never wipe the roster again. Card lifecycle: present → stream → seed → delete; absent → boot from LSD.
- v1.2 rev 9: whitelisted safeword.word (owned by plugin_maint) in MANAGED_SETTINGS_KEYS so the wearer's personal safeword persists via the single-writer settings.delta protocol.
- v1.2 rev 8: ownership changes now REBOOT the collar instead of a light settings.sync, split by ENTRY vs EXIT. ENTRY (handle_set_owner: add/transfer) → request_owner_reboot() = kernel.reset.soft: scripts reset, roster + notecard KEPT (the new owner inherits a working collar; the card's "only one" guard blocks any stale card owner re-streaming). EXIT (handle_clear_owner: release) → factory_reset() = notecard removed + LSD wiped, SAME as runaway: a released/fled wearer's collar is fully cleared because the dom's authority — and their card settings — cease to apply, and an emptied owner slot would otherwise let the card re-stream the owner back. Removed clear_owner_records (subsumed by the wipe). Boot-safe: card path seeds via card_add_owner → user_write, never these handlers; trustee/blacklist mutations keep the light sync.
- v1.2 rev 7: Reset Config no longer has its own card parser. The bespoke path (snapshot owner+lock → llLinksetDataReset → request card re-stream → finalize_reset_config) was redundant with kmod_bootstrap (which owns card I/O) AND bricked: readiness was stamped only in finalize, which fired only after the card re-stream handshake completed — a stalled stream (e.g. bootstrap's `Streaming` in-flight guard stuck) left the sentinel unset = pre-boot brick. Now handle_reset_config just WIPES config (deletes every LSD key except user.* roster + access.isowned/multiowner + lock.locked + safeguard.last_owner) and broadcasts kernel.reset.factory — the standard boot rebuilds everything: plugins re-seed their OWN defaults (the config source; the card is NOT — see feedback_card_not_config_source), kmod_settings re-stamps readiness, kmod_bootstrap re-applies the card OVERRIDE if present / ignores if absent (the wipe cleared settings.cardapplied). Removed finalize_reset_config + the InResetConfig/ResetConfigKeys/ResetConfigValues state. Reload/card-edit paths unchanged.
- v1.2 rev 6: The notecard is an OVERRIDE, never a requirement — decouple readiness from the card so a present-but-unstreamable card can't brick the UI. Two markers now: settings.bootstrapped (readiness; kmod_auth's gate) is stamped IMMEDIATELY in state_entry on any fresh boot (the old "card present → wait for settings.card.streamed" branch is gone — that branch left the sentinel unstamped forever on owner-change boots whose card handshake didn't land, so auth never went ready = no UI). New settings.cardapplied marker gates the card override: process_streamed_card + finalize_reset_config set it; Reload Settings / card-edit clear it (NOT the readiness sentinel, so the UI stays up through a reload); a wipe clears both so the card re-applies for a new owner. kmod_bootstrap now streams the card gated on settings.cardapplied, not the readiness sentinel.
- v1.2 rev 3: Notecard I/O relocated to kmod_bootstrap (memory: rev 2 sat at 90.6% of the Mono budget and stack-heap-collided when it parsed). kmod_settings no longer reads the card: kmod_bootstrap streams each card line into LSD verbatim and signals "settings.card.streamed"; we convert in process_streamed_card() (normalize flag scalars, migrate_legacy_roster() rebuilds the user.* roster from the deposited access-roster and blacklist scratch keys via the retained card builders, deferred TPE guard, stamp sentinel, broadcast). kmod_settings stays the SOLE user.* writer (bootstrap only deposits scratch + scalar keys). Removed: parse_notecard_line, start_notecard_reading, the card-ownership manifest (record_card_key / apply_card_manifest_clear / finalize_card_manifest — migrate clears+rebuilds wholesale via delete_role), clear_owner_keys / clear_trustee_keys, csv_read / csv_write, the notecard dataserver branch, and the Notecard-reading globals (CardProvided, COMMENT_PREFIX, SEPARATOR, CARD_MULTI_OWNER, KEY_CARDMANIFEST). Reload Settings / Reset Config / card-edit now request a re-stream (settings.card.restream) instead of reading directly; no-card paths rebroadcast/finalize without touching the roster. Estimator: 90.6% -> 82.7%. The multiowner FEATURE is unchanged (KEY_MULTI_OWNER_MODE + is_multi_owner_mode + card_add_owner refusal all intact).
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
              owner/trustee/blacklist messages. The notecard is a ONE-TIME
              seed (not a live config): on boot it is streamed, seeded into
              LSD non-destructively (seed_card_roster — owner overwrites if
              declared, sets union in), then DELETED. There is no re-parse,
              so LSD is the single source of truth and UI-set state is never
              clobbered by a card re-read.
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

// Readiness sentinel — kmod_auth gates ACL readiness on its presence. Stamped
// IMMEDIATELY on a fresh boot (state_entry) from LSD alone: the collar is
// operable without a notecard, so readiness must NEVER wait on the card. Only
// llLinksetDataReset (owner-change wipe / factory / reset-config) clears it.
string KEY_SENTINEL = "settings.bootstrapped";

// Card-override applied marker. The notecard is an OVERRIDE for UI-set settings,
// not a requirement: kmod_bootstrap streams it (gated on THIS, not the readiness
// sentinel) once per fresh boot, and process_streamed_card() sets this after
// applying. A normal reboot (marker set) keeps UI/LSD values; Reload Settings, a
// card edit, or a wipe clear it so the card re-applies. Decoupling this from
// readiness is what stops a present-but-unstreamable card from bricking the UI.
string KEY_CARD_APPLIED = "settings.cardapplied";

// Placeholder used while a display name is being resolved
string NAME_LOADING = "(loading...)";

/* -------------------- NOTECARD CONFIG -------------------- */
// kmod_settings no longer reads the card (kmod_bootstrap streams it); the name
// is kept only to detect add/remove/edit in changed().
string NOTECARD_NAME = "settings";

/* -------------------- STATE -------------------- */
key LastOwner = NULL_KEY;

key NotecardKey = NULL_KEY;

// The settings card is a ONE-TIME seed: process_streamed_card() removes it after
// seeding LSD, so it can never be re-parsed (the old roster-wipe-on-reload). That
// self-delete fires CHANGED_INVENTORY; this flag marks it benign so changed()
// doesn't read it as a hostile card removal and factory_reset().
integer CardConsumed = FALSE;

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

// Owner ADD / TRANSFER (owner.set) soft-reboots the collar: every script resets
// and re-reads LSD with the roster + notecard KEPT, so the new ownership applies
// cleanly everywhere — the "confirms everything" reinit, WITHOUT a card wipe (the
// new owner inherits a working collar; the card's "only one" guard blocks any
// stale card owner from re-streaming). EXITS (release/runaway) instead END
// authority and factory-wipe. Supersedes the light settings.sync. Boot-safe: the
// card path seeds owners via card_add_owner -> user_write, never this handler.
request_owner_reboot() {
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.reset.soft",
        "from", "owner_change"
    ]), NULL_KEY);
}

// Ask kmod_bootstrap to (re-)stream the notecard into LSD. It deposits the raw
// card keys and replies with "settings.card.streamed", which we convert in
// process_streamed_card(). Used for boot is implicit (bootstrap self-triggers);
// this is for the explicit re-arm paths (Reload Settings, Reset Config, a card
// edit). The caller has already confirmed a notecard is present.
request_card_restream() {
    llMessageLinked(LINK_SET, SETTINGS_BUS, llList2Json(JSON_OBJECT, [
        "type", "settings.card.restream"
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
    "safeword.word",          // plugin_maint (wearer's personal safeword)
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

// (Card-ownership manifest + clear_owner_keys/clear_trustee_keys removed: the
// card is now a one-time seed — kmod_bootstrap streams it once, seed_card_roster()
// upserts it non-destructively, and the card is deleted, so there is no recurring
// re-parse for per-key drop-tracking to defend against.)

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
            "WARNING: Multi-owner mode is off — additional card owner ignored. Set access.multiowner = 1 in the notecard to allow several owners.");
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

/* -------------------- STREAMED-CARD CONVERSION --------------------

kmod_bootstrap does the heavy notecard I/O now: it streams each card line as a
raw key=value into LSD (the card key names ARE the LSD key names), then emits
"settings.card.streamed". We convert that raw deposit into final state here —
the lighter half of the old parse, with no per-line dataserver state — so this
script never holds the parse's memory. kmod_settings remains the sole writer of
user.* records (bootstrap only deposits the legacy access.* / blacklist.* scratch
keys; we build the records and delete the scratch). See kmod_bootstrap rev for
the streaming side. CROSS-MODULE CONTRACT: the streamed key names + the
"settings.card.streamed" signal.

-------------------- */

// Normalize a boolean flag the card deposited raw ("true"/"1"/"yes" → 1/0).
normalize_flag(string k) {
    string v = llLinksetDataRead(k);
    if (v != "") llLinksetDataWrite(k, normalize_bool(v));
}

// Seed the card's roster declaration into user.<uuid> records — NON-DESTRUCTIVE.
// The card is one of two sources for the same setting (UI is the other); a seed
// writes only what the card declares and never wipes what it doesn't, so UI-set
// state survives. Two data shapes:
//   • Owner = scalar, card-over-LSD: the card overwrites the owner ONLY when it
//     declares one (conditional delete_role(5) + rebuild). Card silent on the
//     owner → the existing LSD/UI owner stands untouched.
//   • Trustees / blacklist = sets, union: the card's members are upserted (the
//     builders skip existing uuids); a card silent on them changes nothing, so
//     UI-set entries — especially the safety-critical blacklist — are preserved.
// Flag scalars are deposited/normalized separately; isOwned is derived from the
// resulting roster by the caller. The scratch keys are deleted once converted.
seed_card_roster() {
    integer i;
    integer n;
    list items;

    // Owner (scalar, card-over-LSD): replace the owner ONLY if the card names one.
    string owners_csv = llLinksetDataRead(CARD_OWNER_UUIDS);
    if (owners_csv != "") {
        delete_role(5);                       // card declares owner(s) → overwrite
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
            delete_role(5);                   // card declares a single owner → overwrite
            card_add_owner(owner1);
            string ohon1 = llLinksetDataRead(CARD_OWNER_HON);
            if (ohon1 != "") CardOwnerHons = [ohon1];
        }
        // else: card silent on owner → keep the existing LSD/UI owner.
    }

    // Trustees (set, union): card adds; existing trustees are kept.
    string tru_csv = llLinksetDataRead(CARD_TRUSTEE_UUIDS);
    if (tru_csv != "") {
        items = llCSV2List(tru_csv);
        n = llGetListLength(items);
        if (n > MaxListLen) n = MaxListLen;
        for (i = 0; i < n; i++) card_add_trustee(llList2String(items, i));
        string thons = llLinksetDataRead(CARD_TRUSTEE_HONS);
        if (thons != "") CardTrusteeHons = llCSV2List(thons);
    }

    // Blacklist (set, union): card adds; existing UI-set entries are kept. This
    // is the original-bug fix — a card silent on the blacklist never clears it.
    string bl_csv = llLinksetDataRead(CARD_BLACKLIST);
    if (bl_csv != "") {
        items = llCSV2List(bl_csv);
        n = llGetListLength(items);
        if (n > MaxListLen) n = MaxListLen;
        for (i = 0; i < n; i++) add_blacklist_internal(llList2String(items, i), "");
    }

    // Honorifics by rank (mirrors the old card EOF step).
    apply_card_honorifics();

    // Deferred TPE guard: tpe.mode was deposited raw; enforce "requires an
    // external owner" now that the roster exists.
    if ((integer)llLinksetDataRead(KEY_TPE_MODE) && !has_external_owner()) {
        llLinksetDataWrite(KEY_TPE_MODE, "0");
        llRegionSayTo(llGetOwner(), 0,
            "ERROR: TPE disabled - it requires an external owner.");
    }

    // Drop the converted scratch keys; flag scalars stay.
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

// Entry point when kmod_bootstrap signals the card has been streamed into LSD.
// Normalize the flag scalars, convert the roster, then finalize: Reset-Config
// restores the preserved owner+lock block; a normal bootstrap stamps the
// sentinel and announces.
process_streamed_card() {
    normalize_flag(KEY_PUBLIC_ACCESS);
    normalize_flag(KEY_LOCKED);
    normalize_flag(KEY_RUNAWAY_ENABLED);
    // KEY_ISOWNED is NOT read from the card — it's derived from the roster below.
    normalize_flag(KEY_MULTI_OWNER_MODE);
    normalize_flag(KEY_TPE_MODE);

    seed_card_roster();

    // isOwned is derived from the roster: owned iff an external owner resolves
    // (from either source). A card silent on the owner that left no owner in LSD
    // → self-owned. Written directly (not via handle_set) so it never trips the
    // isowned==0 release path.
    if (has_external_owner()) llLinksetDataWrite(KEY_ISOWNED, "1");
    else                      llLinksetDataWrite(KEY_ISOWNED, "0");

    // Readiness is normally already stamped (state_entry on a fresh boot); keep
    // it idempotent here for the boot/Reload paths.
    llLinksetDataWrite(KEY_SENTINEL, "1");
    llLinksetDataWrite(KEY_CARD_APPLIED, "1");
    broadcast_settings_changed();
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "settings.notecard.loaded"
    ]), NULL_KEY);

    // The card is a ONE-TIME seed: LSD now holds everything it carried, so remove
    // it. With no card on disk there is nothing to re-parse, so a re-read can
    // never wipe UI-set roster again (the original bug dies by construction).
    // CardConsumed marks this removal benign so changed() doesn't factory_reset.
    if (llGetInventoryType(NOTECARD_NAME) == INVENTORY_NOTECARD) {
        CardConsumed = TRUE;
        llRemoveInventory(NOTECARD_NAME);
    }
}


/* -------------------- MESSAGE HANDLERS -------------------- */

handle_settings_get() {
    // UI "Reload Settings": with a card present, clear the sentinel and ask
    // kmod_bootstrap to re-stream it (→ settings.card.streamed → convert). With
    // no card, there's nothing to reload — just rebroadcast so plugins resync
    // from the existing LSD (the roster is NOT touched).
    if (llGetInventoryType(NOTECARD_NAME) != INVENTORY_NOTECARD) {
        broadcast_settings_changed();
        return;
    }
    // Re-arm the card override (keep readiness up so the UI doesn't drop during
    // a reload). process_streamed_card re-applies and re-sets the marker.
    llLinksetDataDelete(KEY_CARD_APPLIED);
    request_card_restream();
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
        // Owned-state change (add / transfer) — reboot, don't just sync.
        request_owner_reboot();
    }
}

handle_clear_owner() {
    if (is_multi_owner_mode()) {
        llRegionSayTo(llGetOwner(), 0, "ERROR: Cannot clear owner via menu in multi-owner mode (notecard managed)");
        return;
    }
    // Release ends the owner's authority, so the collar is wiped entirely —
    // card + roster + settings, SAME as runaway. The dom's settings cease to
    // apply once released, and an emptied owner slot would otherwise let the
    // card re-stream the owner straight back on a later reboot / Reset Config.
    // The consent bit (plugin_owners) gates only the owner-auth step, not this.
    factory_reset();
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

/* -------------------- RESET CONFIG -------------------- */

// Reset Config: wipe the config and let the STANDARD boot rebuild it. Delete
// every LSD key EXCEPT the roster (user.*) + ownership flags + lock + the
// kernel's owner-identity marker, then broadcast kernel.reset.factory. That's
// all — bootstrap re-stamps readiness, every plugin re-seeds its OWN defaults
// (the config source; the card is NOT — see feedback_card_not_config_source),
// and bootstrap re-applies the card OVERRIDE if present (the wipe cleared
// settings.cardapplied) or ignores it if absent. No card parsing / re-stream /
// finalize here — that was redundant with bootstrap and bricked on a stalled
// card stream. The reset handler wipes config and calls bootstrap, nothing more.
handle_reset_config() {
    llRegionSayTo(llGetOwner(), 0, "Resetting configuration...");

    // Delete all config keys; keep the roster + ownership flags + lock + the
    // kernel's owner-identity marker. (settings.bootstrapped / settings.cardapplied
    // are NOT preserved — gone with the wipe, so readiness re-stamps and the card
    // override re-applies on the reboot.)
    list all = llLinksetDataFindKeys("", 0, -1);
    integer n = llGetListLength(all);
    integer i = 0;
    while (i < n) {
        string k = llList2String(all, i);
        if (llSubStringIndex(k, "user.") != 0
            && k != KEY_ISOWNED
            && k != KEY_MULTI_OWNER_MODE
            && k != KEY_LOCKED
            && k != "safeguard.last_owner") {
            llLinksetDataDelete(k);
        }
        i += 1;
    }

    // Hand off to the standard boot: resets every script; bootstrap + plugins
    // rebuild config, readiness, and (if present) the card override.
    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
        "type", "kernel.reset.factory",
        "from", "reset_config"
    ]), NULL_KEY);
}

/* -------------------- EVENTS -------------------- */

default
{
    state_entry() {

        LastOwner = llGetOwner();
        NotecardKey = llGetInventoryKey(NOTECARD_NAME);

        // kmod_settings no longer reads the notecard — kmod_bootstrap streams it
        // and signals settings.card.streamed, which we convert. The notecard is
        // an OVERRIDE, never a requirement, so readiness is decided from LSD
        // alone and NEVER waits for the card:
        //   • sentinel set → already bootstrapped, LSD authoritative, rebroadcast.
        //   • sentinel unset → fresh boot (install / post-wipe): stamp + broadcast
        //     NOW so ACL/consumers come up immediately. If a card is present,
        //     kmod_bootstrap streams it in parallel (gated on KEY_CARD_APPLIED)
        //     and process_streamed_card() applies the override on top, then
        //     rebroadcasts. A missing or unstreamable card simply leaves the
        //     LSD/UI values in place — the collar still works.
        if (llLinksetDataRead(KEY_SENTINEL) != "") {
            broadcast_settings_changed();
        }
        else {
            llLinksetDataWrite(KEY_SENTINEL, "1");
            broadcast_settings_changed();
        }
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
                    if (CardConsumed) {
                        // Our own post-seed self-delete — benign, NOT hostile.
                        CardConsumed = FALSE;
                        NotecardKey  = NULL_KEY;
                    }
                    else {
                        // Foreign card removal → zero-trust factory reset.
                        factory_reset();
                    }
                }
                else {
                    // Wearer/owner swapped or edited the notecard — an explicit
                    // re-arm of the override. Clear the card marker (NOT readiness)
                    // and ask bootstrap to re-stream.
                    NotecardKey = current_notecard_key;
                    llLinksetDataDelete(KEY_CARD_APPLIED);
                    request_card_restream();
                }
            }
        }
    }

    dataserver(key query_id, string data) {
        // Notecard reading moved to kmod_bootstrap. The only dataserver traffic
        // left here is async display-name resolution for roster records.
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

        if      (msg_type == "settings.card.streamed")  process_streamed_card();
        else if (msg_type == "settings.get")            handle_settings_get();
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

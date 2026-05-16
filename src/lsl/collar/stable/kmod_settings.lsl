/*--------------------
MODULE: kmod_settings.lsl
VERSION: 1.10
REVISION: 16
PURPOSE: Notecard parser, validation guards, and LSD settings store
ARCHITECTURE: Two-mode access model. Single-owner mode uses scalar keys
              (access.owner, access.ownername, access.ownerhonorific) and
              is set via the menu UI. Multi-owner mode uses parallel CSVs
              (access.owneruuids/names/honorifics) and is set ONLY via the
              settings notecard. Mode is selected by access.multiowner.
              Trustees and blacklist always use CSVs. Display names are
              resolved asynchronously via llRequestDisplayName.
              kmod_settings is the SOLE LSD WRITER for keys listed in
              MANAGED_SETTINGS_KEYS — plugins request writes via the
              CSV-envelope settings.delta / settings.delete protocol on
              SETTINGS_BUS. Managed keys are also reset to absent on
              notecard reload; consumers fall back to in-script defaults
              via lsd_int(key, fallback) when the notecard omits a key.
CHANGES:
- v1.1 rev 16: Fix settings.delta CSV parser silently dropping empty-value writes. llParseString2List discards trailing empty tokens, so `settings.delta:foo:` parsed to length 2 and bailed the `!= 3` guard, leaving LSD with the stale previous value. Switched to llParseStringKeepNulls. Root cause of the folder-lock reactivation: plugin_folders' unlock-last sent an empty-CSV delta, kmod_settings dropped it, folders.locked stayed populated, next settings.sync re-applied. Plugins should also prefer settings.delete for empty/no-value cases — see plugin_folders rev 31 / plugin_restrict rev 15.
- v1.1 rev 15: Register leash.texture in MANAGED_SETTINGS_KEYS — new wearer-pick visual style for the leash particle stream (chain / silk). Still on the settings.set JSON path along with the rest of the leash.* family.
- v1.1 rev 14: Expand MANAGED_SETTINGS_KEYS to the full plugin settings family (19 keys). Plugin migrations to the settings.delta CSV protocol: plugin_public, plugin_tpe, plugin_folders, plugin_relay, plugin_chat, plugin_bell, plugin_rlvex, plugin_restrict, plugin_access (runaway).
- v1.1 rev 13: Notecard reload reverts managed settings keys to "absent" before re-parsing. Any key listed in MANAGED_SETTINGS_KEYS that's not in the new notecard ends up deleted, so consumer plugins fall back to in-script defaults via their existing lsd_int(key, fallback) reads. Replaces ad-hoc reload preservation with a uniform "notecard is canonical" model for managed keys.
- v1.1 rev 12: Add CSV-envelope settings.delta / settings.delete write protocol. Plugins request writes via `settings.delta:<key>:<value>` (or `settings.delete:<key>`); kmod_settings validates against MANAGED_SETTINGS_KEYS whitelist, writes LSD, broadcasts settings.sync. Initial whitelist: lock.locked (plugin_lock PoC). Single-writer pattern eliminates LSD-ownership conflicts and routes settings changes through one authority.
- v1.1 rev 11: Listen for kernel.reset.factory / kernel.reset.soft on
  KERNEL_LIFECYCLE and llResetScript on receipt. Notecard NOT touched
  in this path — that's exclusive to handle_runaway/factory_reset.
  Lets the kernel's owner-change wipe (collar_kernel rev 6) flush
  kmod_settings's stale in-memory state cleanly so the next state_entry
  re-parses the notecard against fresh LSD.
- v1.1 rev 10: Notecard parsing gated by settings.bootstrapped sentinel —
  state_entry no longer re-parses card after first bootstrap. New
  settings.reset.config message snapshots owner+lock keys, llLinksetDataReset,
  re-parses card, restores preserved keys for card-silent slots, sets sentinel,
  broadcasts. factory_reset (Runaway) now llRemoveInventory(notecard) before
  wipe — disarms hostile notecards. Reload Settings and CHANGED_INVENTORY
  notecard-changed paths clear sentinel before re-parsing.
- v1.1 rev 9: settings.get now re-reads the notecard when one is present,
  matching the UI contract that "Reload Settings" re-reads the notecard.
  Previous behavior rebroadcast LSD only, so a wearer who had (e.g.)
  unlocked the collar via menu would see "Reload Settings" do nothing for
  lock state — the notecard's lock.locked=1 was never re-applied. Guarded
  against concurrent reloads via IsLoadingNotecard.
- v1.1 rev 8: Add dormancy guard in state_entry — script parks itself
  if the prim's object description is "COLLAR_UPDATER" so it stays dormant
  when staged in an updater installer prim.
- v1.1 rev 7: Consistency pass — 6 ERROR/HINT notices (wearer-as-owner
  guard, TPE guards, multi-owner menu guards) converted from llOwnerSay
  to llRegionSayTo(llGetOwner(), 0, ...).
- v1.1 rev 6: SETTINGS_BUS rename (Phase 1). Mutation handlers now
  dispatch on namespaced family names: settings.setowner→settings.owner.set,
  settings.clearowner→settings.owner.clear, settings.addtrustee→
  settings.trustee.add, settings.removetrustee→settings.trustee.remove,
  settings.blacklistadd→settings.blacklist.add, settings.blacklistremove→
  settings.blacklist.remove. Generics (settings.sync/delta/get/set/runaway)
  unchanged.
- v1.1 rev 5: KERNEL_LIFECYCLE rename (Phase 1). kernel.resetall→
  kernel.reset.factory, settings.notecardloaded→settings.notecard.loaded.
- v1.1 rev 4: Namespace internal message type strings (e.g. "set" →
  "settings.set", "settings_sync" → "settings.sync") for ISP clarity.
- v1.1 rev 3: Replace JSON object owner/trustee storage with explicit
  two-mode flat scheme (scalars for single-owner, parallel CSVs for
  multi-owner). Async display name resolution. access.isowned = 0
  triggers factory reset. New API messages: set_owner, clear_owner,
  add_trustee, remove_trustee, blacklist_add, blacklist_remove, runaway.
- v1.1 rev 2: Remove KvJson. All kv_* operations now read/write LSD
  directly. Remove recover_lsd_settings (LSD is authoritative). Remove
  ForceReseed (notecard parsing always writes to LSD). Simplify
  handle_settings_restore to write each key to LSD.
- v1.1 rev 1: Simplify broadcasts to lightweight signals. Consumers now
  read directly from LSD; four broadcast functions replaced by a single
  broadcast_settings_changed() signal. Notecard parsing now always writes
  validated values to LSD. Notecard removal clears LSD settings keys.
- v1.1 rev 0: Version bump for LSD policy architecture. No functional changes to this module.
--------------------*/


/* -------------------- CONSOLIDATED ISP -------------------- */
integer KERNEL_LIFECYCLE = 500;
integer SETTINGS_BUS = 800;

/* -------------------- SETTINGS KEYS -------------------- */
// Sentinel and mode
string KEY_ISOWNED          = "access.isowned";
string KEY_MULTI_OWNER_MODE = "access.multiowner";

// Single-owner mode (scalars)
string KEY_OWNER            = "access.owner";
string KEY_OWNER_NAME       = "access.ownername";
string KEY_OWNER_HONORIFIC  = "access.ownerhonorific";

// Multi-owner mode (parallel CSVs, notecard only)
string KEY_OWNER_UUIDS        = "access.owneruuids";
string KEY_OWNER_NAMES        = "access.ownernames";
string KEY_OWNER_HONORIFICS   = "access.ownerhonorifics";

// Trustees (parallel CSVs)
string KEY_TRUSTEE_UUIDS      = "access.trusteeuuids";
string KEY_TRUSTEE_NAMES      = "access.trusteenames";
string KEY_TRUSTEE_HONORIFICS = "access.trusteehonorifics";

// Blacklist (CSV of UUIDs only)
string KEY_BLACKLIST          = "blacklist.blklistuuid";

// Other access flags
string KEY_RUNAWAY_ENABLED    = "access.enablerunaway";

// Behaviour scalars
string KEY_PUBLIC_ACCESS = "public.mode";
string KEY_TPE_MODE      = "tpe.mode";
string KEY_LOCKED        = "lock.locked";

// Bootstrap sentinel — set after first notecard parse completes.
// Gates start_notecard_reading() so subsequent script restarts don't
// re-arm a hostile notecard. Cleared by Reload Settings, Reset Config,
// CHANGED_INVENTORY notecard-changed, or llLinksetDataReset().
string KEY_SENTINEL = "settings.bootstrapped";

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

// Reset Config in-flight state. When TRUE, dataserver EOF routes to
// finalize_reset_config() instead of the normal bootstrap broadcast.
integer InResetConfig = FALSE;
list ResetConfigKeys   = [];
list ResetConfigValues = [];

integer MaxListLen = 64;

// Pending display-name queries: parallel lists.
// Role values: "owner_scalar", "owner_csv", "trustee_csv"
list NameQueryIds   = [];
list NameQueryUuids = [];
list NameQueryRoles = [];

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

    settings.delta:<key>:<value>     write/update LSD key
    settings.delete:<key>            delete LSD key (exactly 2 fields)

Strict arity. Trailing/extra separators are malformed and silently rejected.
is_writable_key gates which keys this protocol may mutate — plugin
registration keys (plugin.reg.*) and ACL policy keys (acl.policycontext:*)
remain plugin-owned and are NOT eligible. After every successful write or
delete, broadcast_settings_changed fires settings.sync so consumers re-read.

-------------------- */

// Canonical list of LSD keys that kmod_settings manages on behalf of consumer
// plugins. These keys are:
//   (1) writable via the settings.delta CSV protocol (is_writable_key gate)
//   (2) reset to absent on notecard reload (clear_managed_settings) so consumers
//       fall back to in-script defaults via lsd_int(key, fallback).
// Grow this list as more plugins migrate to the single-writer protocol.
// @lsl-ide lsd-owner
list MANAGED_SETTINGS_KEYS = [
    "lock.locked",            // plugin_lock
    "public.mode",            // plugin_public
    "tpe.mode",               // plugin_tpe
    "folders.locked",         // plugin_folders
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

clear_managed_settings() {
    integer i;
    integer n = llGetListLength(MANAGED_SETTINGS_KEYS);
    for (i = 0; i < n; i++) {
        llLinksetDataDelete(llList2String(MANAGED_SETTINGS_KEYS, i));
    }
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

/* -------------------- LSD CLEAR & FACTORY RESET -------------------- */

clear_owner_keys() {
    // Clear both single and multi-owner key sets, plus the sentinel.
    llLinksetDataDelete(KEY_ISOWNED);
    llLinksetDataDelete(KEY_OWNER);
    llLinksetDataDelete(KEY_OWNER_NAME);
    llLinksetDataDelete(KEY_OWNER_HONORIFIC);
    llLinksetDataDelete(KEY_OWNER_UUIDS);
    llLinksetDataDelete(KEY_OWNER_NAMES);
    llLinksetDataDelete(KEY_OWNER_HONORIFICS);
}

clear_trustee_keys() {
    llLinksetDataDelete(KEY_TRUSTEE_UUIDS);
    llLinksetDataDelete(KEY_TRUSTEE_NAMES);
    llLinksetDataDelete(KEY_TRUSTEE_HONORIFICS);
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

// Returns TRUE if any external owner exists (not the wearer, not NULL_KEY)
integer has_external_owner() {
    key wearer = llGetOwner();

    if (is_multi_owner_mode()) {
        list uuids = csv_read(KEY_OWNER_UUIDS);
        integer i;
        integer len = llGetListLength(uuids);
        for (i = 0; i < len; i++) {
            key owner = (key)llList2String(uuids, i);
            if (owner != wearer && owner != NULL_KEY) return TRUE;
        }
        return FALSE;
    }

    key primary = (key)llLinksetDataRead(KEY_OWNER);
    if (primary != NULL_KEY && primary != wearer) return TRUE;
    return FALSE;
}

integer is_owner(string who) {
    if (is_multi_owner_mode()) {
        return (llListFindList(csv_read(KEY_OWNER_UUIDS), [who]) != -1);
    }
    return (llLinksetDataRead(KEY_OWNER) == who);
}

integer is_trustee(string who) {
    return (llListFindList(csv_read(KEY_TRUSTEE_UUIDS), [who]) != -1);
}

/* -------------------- ASYNC NAME RESOLUTION -------------------- */

request_name(string uuid_str, string role) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) return;
    key qid = llRequestDisplayName((key)uuid_str);
    NameQueryIds   += [qid];
    NameQueryUuids += [uuid_str];
    NameQueryRoles += [role];
}

handle_name_response(key query_id, string name) {
    integer idx = llListFindList(NameQueryIds, [query_id]);
    if (idx == -1) return;

    string uuid_str = llList2String(NameQueryUuids, idx);
    string role     = llList2String(NameQueryRoles, idx);

    NameQueryIds   = list_remove_at(NameQueryIds, idx);
    NameQueryUuids = list_remove_at(NameQueryUuids, idx);
    NameQueryRoles = list_remove_at(NameQueryRoles, idx);

    if (name == "") return;

    if (role == "owner_scalar") {
        // Confirm the uuid still matches before writing
        if (llLinksetDataRead(KEY_OWNER) == uuid_str) {
            llLinksetDataWrite(KEY_OWNER_NAME, name);
            broadcast_settings_changed();
        }
        return;
    }

    if (role == "owner_csv") {
        list uuids = csv_read(KEY_OWNER_UUIDS);
        integer slot = llListFindList(uuids, [uuid_str]);
        if (slot == -1) return;
        list names = csv_read(KEY_OWNER_NAMES);
        while (llGetListLength(names) <= slot) names += [NAME_LOADING];
        names = llListReplaceList(names, [name], slot, slot);
        csv_write(KEY_OWNER_NAMES, names);
        broadcast_settings_changed();
        return;
    }

    if (role == "trustee_csv") {
        list uuids = csv_read(KEY_TRUSTEE_UUIDS);
        integer slot = llListFindList(uuids, [uuid_str]);
        if (slot == -1) return;
        list names = csv_read(KEY_TRUSTEE_NAMES);
        while (llGetListLength(names) <= slot) names += [NAME_LOADING];
        names = llListReplaceList(names, [name], slot, slot);
        csv_write(KEY_TRUSTEE_NAMES, names);
        broadcast_settings_changed();
    }
}

/* -------------------- INTERNAL MUTATORS -------------------- */

// Single-owner: write the scalar trio. Also sets isowned and clears any
// stale multi-owner CSV data.
integer set_single_owner(string uuid_str, string honorific) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) return FALSE;
    if ((key)uuid_str == llGetOwner()) {
        llRegionSayTo(llGetOwner(), 0, "ERROR: Cannot add wearer as owner (role separation required)");
        return FALSE;
    }

    // Role exclusivity: drop from trustees and blacklist
    remove_trustee_internal(uuid_str);
    remove_blacklist_internal(uuid_str);

    // Clear multi-owner CSVs (we are in single-owner mode now)
    llLinksetDataDelete(KEY_OWNER_UUIDS);
    llLinksetDataDelete(KEY_OWNER_NAMES);
    llLinksetDataDelete(KEY_OWNER_HONORIFICS);
    llLinksetDataDelete(KEY_MULTI_OWNER_MODE);

    llLinksetDataWrite(KEY_OWNER, uuid_str);
    llLinksetDataWrite(KEY_OWNER_NAME, NAME_LOADING);
    llLinksetDataWrite(KEY_OWNER_HONORIFIC, honorific);
    llLinksetDataWrite(KEY_ISOWNED, "1");

    request_name(uuid_str, "owner_scalar");
    return TRUE;
}

clear_single_owner() {
    llLinksetDataDelete(KEY_OWNER);
    llLinksetDataDelete(KEY_OWNER_NAME);
    llLinksetDataDelete(KEY_OWNER_HONORIFIC);
    llLinksetDataDelete(KEY_ISOWNED);
}

integer add_trustee_internal(string uuid_str, string honorific) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) return FALSE;
    if ((key)uuid_str == llGetOwner()) return FALSE;
    if (is_owner(uuid_str)) return FALSE;

    list uuids = csv_read(KEY_TRUSTEE_UUIDS);
    if (llListFindList(uuids, [uuid_str]) != -1) return FALSE;
    if (llGetListLength(uuids) >= MaxListLen) return FALSE;

    remove_blacklist_internal(uuid_str);

    list names = csv_read(KEY_TRUSTEE_NAMES);
    list hons  = csv_read(KEY_TRUSTEE_HONORIFICS);

    uuids += [uuid_str];
    names += [NAME_LOADING];
    hons  += [honorific];

    csv_write(KEY_TRUSTEE_UUIDS,      uuids);
    csv_write(KEY_TRUSTEE_NAMES,      names);
    csv_write(KEY_TRUSTEE_HONORIFICS, hons);

    request_name(uuid_str, "trustee_csv");
    return TRUE;
}

integer remove_trustee_internal(string uuid_str) {
    list uuids = csv_read(KEY_TRUSTEE_UUIDS);
    integer idx = llListFindList(uuids, [uuid_str]);
    if (idx == -1) return FALSE;

    list names = csv_read(KEY_TRUSTEE_NAMES);
    list hons  = csv_read(KEY_TRUSTEE_HONORIFICS);

    uuids = list_remove_at(uuids, idx);
    if (idx < llGetListLength(names)) names = list_remove_at(names, idx);
    if (idx < llGetListLength(hons))  hons  = list_remove_at(hons,  idx);

    csv_write(KEY_TRUSTEE_UUIDS,      uuids);
    csv_write(KEY_TRUSTEE_NAMES,      names);
    csv_write(KEY_TRUSTEE_HONORIFICS, hons);
    return TRUE;
}

integer add_blacklist_internal(string uuid_str) {
    if (uuid_str == "" || (key)uuid_str == NULL_KEY) return FALSE;
    if ((key)uuid_str == llGetOwner()) return FALSE;
    if (is_owner(uuid_str)) return FALSE;
    if (is_trustee(uuid_str)) return FALSE;

    list bl = csv_read(KEY_BLACKLIST);
    if (llListFindList(bl, [uuid_str]) != -1) return FALSE;
    if (llGetListLength(bl) >= MaxListLen) return FALSE;

    bl += [uuid_str];
    csv_write(KEY_BLACKLIST, bl);
    return TRUE;
}

integer remove_blacklist_internal(string uuid_str) {
    list bl = csv_read(KEY_BLACKLIST);
    integer idx = llListFindList(bl, [uuid_str]);
    if (idx == -1) return FALSE;
    bl = list_remove_at(bl, idx);
    csv_write(KEY_BLACKLIST, bl);
    return TRUE;
}

/* -------------------- NOTECARD-ONLY KEYS -------------------- */

// Keys that may only be set via notecard, not the runtime API
integer is_notecard_only_key(string k) {
    if (k == KEY_MULTI_OWNER_MODE) return TRUE;
    if (k == KEY_OWNER_UUIDS)      return TRUE;
    if (k == KEY_OWNER_NAMES)      return TRUE;
    if (k == KEY_OWNER_HONORIFICS) return TRUE;
    return FALSE;
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

    // Multi-owner mode flag
    if (key_name == KEY_MULTI_OWNER_MODE) {
        llLinksetDataWrite(KEY_MULTI_OWNER_MODE, normalize_bool(value));
        return;
    }

    // Single-owner scalar (notecard can also use single-owner mode)
    if (key_name == KEY_OWNER) {
        key u = (key)value;
        if (u == NULL_KEY || u == llGetOwner()) return;
        llLinksetDataWrite(KEY_OWNER, value);
        if (llLinksetDataRead(KEY_OWNER_NAME) == "") {
            llLinksetDataWrite(KEY_OWNER_NAME, NAME_LOADING);
        }
        llLinksetDataWrite(KEY_ISOWNED, "1");
        request_name(value, "owner_scalar");
        return;
    }

    if (key_name == KEY_OWNER_HONORIFIC) {
        llLinksetDataWrite(KEY_OWNER_HONORIFIC, value);
        return;
    }

    // Multi-owner CSVs (notecard only)
    if (key_name == KEY_OWNER_UUIDS) {
        list uuids = llCSV2List(value);
        if (llGetListLength(uuids) > MaxListLen) {
            uuids = llList2List(uuids, 0, MaxListLen - 1);
        }
        list valid = [];
        integer i;
        integer len = llGetListLength(uuids);
        for (i = 0; i < len; i++) {
            key u = (key)llList2String(uuids, i);
            if (u != NULL_KEY && u != llGetOwner()) {
                valid += [(string)u];
                request_name((string)u, "owner_csv");
            }
        }
        csv_write(KEY_OWNER_UUIDS, valid);
        // Initialize names CSV with placeholders
        list placeholders = [];
        integer pi = 0;
        integer plen = llGetListLength(valid);
        while (pi < plen) {
            placeholders += [NAME_LOADING];
            pi += 1;
        }
        csv_write(KEY_OWNER_NAMES, placeholders);
        if (llGetListLength(valid) > 0) {
            llLinksetDataWrite(KEY_ISOWNED, "1");
        }
        return;
    }

    if (key_name == KEY_OWNER_HONORIFICS) {
        list hons = llCSV2List(value);
        csv_write(KEY_OWNER_HONORIFICS, hons);
        return;
    }

    // Trustees CSVs
    if (key_name == KEY_TRUSTEE_UUIDS) {
        list uuids = llCSV2List(value);
        if (llGetListLength(uuids) > MaxListLen) {
            uuids = llList2List(uuids, 0, MaxListLen - 1);
        }
        list valid = [];
        integer i;
        integer len = llGetListLength(uuids);
        for (i = 0; i < len; i++) {
            key u = (key)llList2String(uuids, i);
            if (u != NULL_KEY && u != llGetOwner() && !is_owner((string)u)) {
                valid += [(string)u];
                request_name((string)u, "trustee_csv");
            }
        }
        csv_write(KEY_TRUSTEE_UUIDS, valid);
        list placeholders = [];
        integer pi = 0;
        integer plen = llGetListLength(valid);
        while (pi < plen) {
            placeholders += [NAME_LOADING];
            pi += 1;
        }
        csv_write(KEY_TRUSTEE_NAMES, placeholders);
        return;
    }

    if (key_name == KEY_TRUSTEE_HONORIFICS) {
        list hons = llCSV2List(value);
        csv_write(KEY_TRUSTEE_HONORIFICS, hons);
        return;
    }

    // Blacklist CSV
    if (key_name == KEY_BLACKLIST) {
        list bl = llCSV2List(value);
        if (llGetListLength(bl) > MaxListLen) {
            bl = llList2List(bl, 0, MaxListLen - 1);
        }
        list valid = [];
        integer i;
        integer len = llGetListLength(bl);
        for (i = 0; i < len; i++) {
            key u = (key)llList2String(bl, i);
            if (u != NULL_KEY && u != llGetOwner() && !is_owner((string)u) && !is_trustee((string)u)) {
                valid += [(string)u];
            }
        }
        csv_write(KEY_BLACKLIST, valid);
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

    // Generic plugin scalars (any other dotted key) — write through
    if (llSubStringIndex(key_name, ".") != -1) {
        llLinksetDataWrite(key_name, value);
    }
}

integer start_notecard_reading() {
    // Sentinel-gated: callers wanting an explicit re-parse (Reload Settings,
    // Reset Config, CHANGED_INVENTORY notecard-changed) must clear the
    // sentinel first. Boot/restart paths fall through this guard so a
    // hostile notecard cannot self-arm a wiped collar.
    if (llLinksetDataRead(KEY_SENTINEL) != "") return FALSE;

    if (llGetInventoryType(NOTECARD_NAME) != INVENTORY_NOTECARD) {
        return FALSE;
    }
    // Notecard is canonical for ownership data — clear it before reading
    // so removed entries don't persist as stale data.
    clear_owner_keys();
    clear_trustee_keys();
    llLinksetDataDelete(KEY_BLACKLIST);
    // Same rule for the managed-settings family: any key absent from the new
    // notecard reverts to its in-script default (consumer plugins read with
    // lsd_int(key, fallback) so an empty LSD value resolves to the default).
    clear_managed_settings();

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
    if (is_notecard_only_key(key_name)) return;

    string value = llJsonGetValue(msg, ["value"]);
    if (value == JSON_INVALID) return;

    // Refuse direct writes to managed access lists
    if (key_name == KEY_OWNER
        || key_name == KEY_OWNER_NAME
        || key_name == KEY_OWNER_HONORIFIC
        || key_name == KEY_TRUSTEE_UUIDS
        || key_name == KEY_TRUSTEE_NAMES
        || key_name == KEY_TRUSTEE_HONORIFICS
        || key_name == KEY_BLACKLIST) {
        return;
    }

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

    if (set_single_owner(uuid_str, honorific)) {
        broadcast_settings_changed();
    }
}

handle_clear_owner() {
    if (is_multi_owner_mode()) {
        llRegionSayTo(llGetOwner(), 0, "ERROR: Cannot clear owner via menu in multi-owner mode (notecard managed)");
        return;
    }
    clear_single_owner();
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

    if (add_blacklist_internal(uuid_str)) {
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
    ResetConfigKeys = [
        KEY_OWNER,
        KEY_OWNER_NAME,
        KEY_OWNER_HONORIFIC,
        KEY_OWNER_UUIDS,
        KEY_OWNER_NAMES,
        KEY_OWNER_HONORIFICS,
        KEY_MULTI_OWNER_MODE,
        KEY_ISOWNED,
        KEY_LOCKED
    ];
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

    // Mark bootstrap complete; subsequent restarts skip notecard parse.
    llLinksetDataWrite(KEY_SENTINEL, "1");

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
        if (llGetObjectDesc() == "COLLAR_UPDATER") {
            llSetScriptState(llGetScriptName(), FALSE);
            return;
        }

        LastOwner = llGetOwner();
        NotecardKey = llGetInventoryKey(NOTECARD_NAME);

        integer notecard_found = start_notecard_reading();

        if (!notecard_found) {
            // No notecard — LSD already has settings from previous session
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

                if (InResetConfig) {
                    // Reset Config in flight: restore preserved keys for any
                    // slot the card was silent on, set sentinel, broadcast.
                    finalize_reset_config();
                }
                else {
                    // Normal bootstrap completion. Mark sentinel so the next
                    // script restart doesn't re-parse the card automatically.
                    llLinksetDataWrite(KEY_SENTINEL, "1");
                    broadcast_settings_changed();

                    llMessageLinked(LINK_SET, KERNEL_LIFECYCLE, llList2Json(JSON_OBJECT, [
                        "type", "settings.notecard.loaded"
                    ]), NULL_KEY);
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

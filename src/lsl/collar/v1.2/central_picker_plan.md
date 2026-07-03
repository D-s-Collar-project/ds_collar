# Central Picker Refactor — Design Plan (for review, NOT yet implemented)

**Status:** DRAFT for sign-off. No code written yet.
**Goal (user, verbatim intent):** Option **B** — real brackets shown, zero sanitization —
plus a **central picker process** in the module, differentiated by what's being targeted:
short/direct things (animations, avatar names) render **UL** (name on the button); longer
things (outfits, folders, objects) render **OL** (numbered body + index).

---

## 1. The bug, precisely (why this is a transport problem, not a naming problem)

A picker label containing `[` `]` `{` `}` (e.g. `[Ds] Chesterfield`, `HUD 2.0 [FULL PERMS]`)
survives fine in an LSL list and in `llDialog`. It dies **only** when passed through
`llList2Json` / `llJson2List`, because the array/object splitter counts brackets *inside a
quoted value* as real structural opens, collapsing the whole array to `JSON_INVALID` — which
renders as a single blank box, hiding every item in the picker.

There are **three** JSON hops in the current picker pipeline, and a bracket dies at the first
one it hits:

1. **Plugin → menu.** Plugin builds `llList2Json(JSON_ARRAY, items)` and puts it in the
   `items` field of `ui.menu.render`. Collapse #1 — happens *inside the plugin*, before the
   module ever sees the names. (This is why a module-side `json_safe` cannot work: the data
   arrives pre-shredded.)
2. **menu → dialogs.** `render_paged` emits `button_data` as
   `llList2Json(JSON_ARRAY, final_button_data)` (kmod_menu.lsl:320). Collapse #2.
3. **dialogs internal.** `kmod_dialogs.handle_dialog_open` decodes `button_data`
   (kmod_dialogs.lsl:202), then stores the click-map as `llList2Json(JSON_ARRAY, buttons)`
   (kmod_dialogs.lsl:322). Collapse #3. This store is also the **click-resolution key**: a
   click returns the button *label*, matched by `llListFindList` against the stored labels
   (kmod_dialogs.lsl:477). So the label must round-trip **byte-for-byte** or the click can't
   be resolved.

**Conclusion:** to show real brackets end-to-end (Option B), the **label transport must stop
being JSON** on every hop it travels. `llDialog` and `llParseStringKeepNulls` are both
bracket-immune, so once JSON is out of the *label* path the entire bug class disappears and
`json_safe()` is deleted, not centralized.

Contexts (`nav:*`, `pick:<i>`, UUIDs) are our own tokens and never contain brackets, so they
can stay as-is; only **labels** need the delimited treatment.

---

## 2. Design

### 2.0 Hard LSL constraint discovered mid-build: no JSON value may LEAD with `[` or `{`

`llList2Json` treats a list value/element that *starts* with `[` or `{` as nested JSON and
returns `JSON_INVALID` for the whole structure if it isn't valid. Brackets **inside** a value
are fine (that's why OL bodies already show `1. [Ds] Chesterfield`). Consequences baked into the
design:

- **Rows are `context\tlabel` (context-first).** The `button_rows` message value is a big
  user-content string; putting the context first guarantees it starts with a nav context
  (`nav:prev…`), never `[`. (Labels — which may lead with `[` — sit in field 2, mid-value.)
- **Routing is context-only in every result/response.** A response/result field that echoes a
  raw label could lead with `[` and poison the message. Consumers already route by context
  (verified: kmod_menu sensor by `context`, plugin_restrict by `key`), so no label is echoed
  for routing.
- **The one legacy label-echo field (`ui.dialog.response.button`, read by kmod_ui/bell/maint/
  status/blacklist for fixed menus) is guarded** in kmod_dialogs: if the clicked label leads
  with `[`/`{` (only picker items do), `button` is sent as a placeholder. Fixed menu labels
  never lead with a bracket, so those consumers are unaffected.

### 2.1 Delimited label transport (bracket-immune)

Introduce a delimited encoding for the button set on the picker path. A dialog *label* can
never contain a newline or a tab, so:

- **Record separator:** `\n` (between buttons)
- **Field separator:** `\t` (between a button's label and its context)

One button = `label \t context`. A button list = records joined by `\n`, carried in a new
message field **`button_rows`**. Parse with `llParseStringKeepNulls(s, ["\n"], [])` then
`llParseStringKeepNulls(row, ["\t"], [])` (KeepNulls so an empty context — e.g. a spacer —
survives). No `llList2Json`/`llJson2List` touches a label anywhere on this path.

kmod_dialogs also stores the per-session click-map **as the `button_rows` string itself** (not
`llList2Json(JSON_ARRAY, buttons)` — that was poison point #3). On click it parses the stored
rows, `llListFindList`es the clicked label, and returns the parallel context.

> **Decision C = ALL dialogs delimited.** Every `ui.dialog.open` sender emits `button_rows`;
> the JSON `button_data`/`buttons` paths are removed once migration completes. During
> migration kmod_dialogs accepts both (field-name versioning) so the collar works at every
> commit.

### 2.2 `menu.picker` — the one central picker

Generalize the existing `menu.sensor` mechanism (kmod_menu already **holds candidates**,
**auto-selects UL/OL**, **paginates**, and **returns a result** to the requester). The only
new thing is accepting a **plugin-supplied** candidate list instead of an `llSensor` scan.

**Request** — plugin → UI bus (`ui.menu.render`):

| field       | meaning                                                            |
|-------------|-------------------------------------------------------------------|
| `mode`      | `"menu.picker"`                                                    |
| `requester` | plugin context (so the result is routed back to it)               |
| `user`      | avatar the dialog is shown to                                     |
| `title`     | dialog title                                                      |
| `prompt`    | body prompt                                                       |
| `labels`    | candidate labels, **`\n`-delimited** (raw names, brackets intact) |
| `keys`      | optional parallel **`\n`-delimited** contexts (e.g. UUIDs). If omitted, the picker routes purely by index. |
| `shape`     | optional override `"UL"`/`"OL"`. If omitted, auto-selected (§2.3). |

kmod_menu stores the candidates in a held stride list (like `SensorCands`), renders via the
delimited transport, pages, and on selection emits a **result**:

**Result** — kmod_menu → plugin (`ui.menu.picker.result`, mirrors `ui.sensor.result`):

| field       | meaning                                                        |
|-------------|----------------------------------------------------------------|
| `requester` | echoes the request's requester                                 |
| `user`      | the avatar                                                     |
| `context`   | **the selected item's context — the ONLY routing token.** UUID or `pick:<i>`. Clean, stable, bracket-free. |
| `index`     | selected candidate index (convenience; −1 if cancelled)        |
| `cancelled` | TRUE on Back/timeout/close                                     |

> **INVARIANT ([[project_v12_buttons_by_context]]): plugins branch on `context`, NEVER on a
> label.** The result deliberately carries **no label field** — a label is display-only and
> must never reach a consumer as a routing key. `context` is the clean stable identity (UUID
> for people; `pick:<i>` into the held candidate list for inventory items). Whatever the button
> showed — truncated, bracketed, decorated with `" *"` — is irrelevant to routing.

**The plugin never handles the button click.** It fires a picker request and waits for one
result message, then branches on `context`. That is the DRY win: all seven bespoke item-build
+ click-route blocks collapse into `send_picker(...)` + one `ui.menu.picker.result` handler
that switches on `context`.

### 2.2a Context vs. label — the hard rule

Each candidate is a **(context, label)** pair:
- **context** — clean, stable, unique, bracket-free identity. UUID or `pick:<i>`. This is what
  the picker returns and what the plugin routes on.
- **label** — the display string. May contain `[ ] { }`, may be ellipsized to fit a 24-char
  button, may carry decoration (`" *"` locked, worn glyphs, `"N. "` numbering). Travels in the
  bracket-immune **delimited** field so it *renders* correctly, and is used for nothing else.

The single unavoidable llDialog boundary (llDialog returns the clicked button's visible text)
stays sealed **inside kmod_dialogs**, which maps that text → context once, centrally, exactly
as it does today for every button. Nothing upstream/downstream ever routes by label. OL's
digit buttons make that map collision-free; UL's name buttons rely on label uniqueness (the
reason UL is reserved for short, effectively-unique things — anims, avatar names), and even a
UL label collision only ever resolves to *a* context, never leaks a label to the consumer.

Request field note: `labels` and the parallel `keys` (§2.2) are the per-candidate
label/context columns. `keys` is REQUIRED when routing by UUID; when omitted, kmod_menu assigns
`pick:<i>` as each item's context automatically.

### 2.3 UL vs OL auto-selection

Encodes the user's rule ("direct-to-read → UL, else OL"). Operational proxy = label length,
since UL puts the name on a 24-char button and OL exists precisely for names that overflow it:

- If `shape` override present → use it.
- Else if **every** candidate label length ≤ `UL_MAX` (proposed **24**) → **UL**.
- Else → **OL**.

This makes anims and avatar names (short) land on UL and outfits/folders/objects (long) land
on OL automatically, with no per-plugin decision. Plugins may still force a shape via `shape`.

> **Open question A:** length-auto vs. explicit per-plugin `shape`. Proposal: length-auto as
> default, `shape` as override. Confirm the `UL_MAX` threshold (24?).

---

## 3. Per-file edits

### 3.1 `kmod_dialogs.lsl` (foundation)
- Add a **picker-open** path (new `dialog_type` = `"picker"`, or a dedicated field) that reads
  the button set from a **delimited** field instead of JSON `button_data`.
- Store that session's click-map **delimited** (labels `\n`-joined, contexts `\n`-joined) —
  NOT `llList2Json` — so bracketed labels round-trip.
- Click resolution: split the delimited label store, `llListFindList` the clicked label,
  return the parallel context. `nav:close` handling unchanged.
- **Existing JSON `button_data` path stays untouched** for all non-picker dialogs.
- Rev bump + changelog.

### 3.2 `kmod_menu.lsl` (central picker)
- Add `menu.picker` mode: parse `labels`/`keys` (delimited), hold candidates, auto-select
  UL/OL (§2.3), render through the new delimited dialogs path, paginate, return
  `ui.menu.picker.result`. Reuse as much of the `menu.sensor` code as possible (ideally
  `menu.sensor` becomes "picker fed by a sensor scan" so there's literally one render+return
  core).
- Convert `render_sensor_picker` to the delimited transport and **delete `json_safe()`**
  (its only caller). Sensor picker now shows real brackets too.
- `render_paged`/`render_modal`/`render_info` for non-picker modes: **unchanged** (still JSON
  button_data).
- Rev bump + changelog. Update memory [[project_v12_menu_modes]].

### 3.3 The 7 list-picker plugins — uniform migration
`plugin_animate, plugin_outfits, plugin_folders, plugin_blacklist, plugin_owners,
plugin_leash, plugin_strip`

For each:
- **Delete** the hand-rolled `items` build + `llList2Json(JSON_ARRAY, items)` +
  `ui.menu.render`(unordered/ordered) send. Replace with a `menu.picker` request carrying
  `labels` (`\n`-joined raw names) and, where routing needs it, `keys`.
- **Delete** the picker-click branch in the response handler. **Add** a
  `ui.menu.picker.result` handler that acts on `index`/`key`/`label`.
- Remove any `{label}`-wrap hack (plugin_outfits rev 15) and any other bracket workaround —
  no longer needed.
- Rev bump + changelog per script.

### 3.4 Direct-dialog plugins — audit only (may be no-ops)
`plugin_blacklist, plugin_owners, plugin_chat, plugin_status` send `ui.dialog.open` directly.
- `plugin_status` → `render_info`/OK, fixed labels → **no change**.
- `plugin_chat` → textbox/menu? audit; likely fixed labels → **no change**.
- `plugin_blacklist, plugin_owners` → if they render **avatar-name** pickers directly, migrate
  those to `menu.picker` too (they're already in the §3.3 list). Confirm none build a bespoke
  name dialog outside the picker.

---

### 3.5 NOT touched (scope boundary)

**Toggle-only / menu-only plugins need no surgery.** Any plugin that renders through kmod_menu
(`ui.menu.render`) rather than sending `ui.dialog.open` itself is carried transparently once
kmod_menu emits `button_rows` (Phase 2). kmod_dialogs resolves a toggle button's label from its
registered config+state **keyed by context**, and that path is preserved in the `button_rows`
input handler — so the toggle mechanism is unchanged. Untouched: bell, lock, public, tpe,
relay, rlvex, status's toggle buttons, and every other menu-via-kmod_menu consumer. Only the
**7 pickers** (§3.3) and the **4 direct `ui.dialog.open` senders** (§3.4) are edited.

## 4. Routing table (what each picker returns to its plugin)

| Plugin          | Candidates              | Shape (auto) | Context returned (routing token) |
|-----------------|-------------------------|--------------|----------------------------------|
| plugin_animate  | animation inv names     | UL (short)   | `pick:<i>` → play `anims[i]`      |
| plugin_owners   | avatar names            | UL (short)   | UUID                             |
| plugin_blacklist| avatar names            | UL (short)   | UUID                             |
| plugin_outfits  | outfit folder names     | OL (long)    | `pick:<i>`                       |
| plugin_folders  | folder names            | OL (long)    | `pick:<i>`                       |
| plugin_leash    | nearby object/av names  | OL/UL        | UUID                             |
| plugin_strip    | worn layer/attach names | OL (long)    | `pick:<i>`                       |

**Every entry routes on `context` — a UUID or `pick:<i>` — never on the label.** Plugins that
route by an inventory position hold their own ordered candidate list and index into it with
`pick:<i>`; plugins that route by avatar use the UUID. The decorated/bracketed display name is
never a routing token. (This resolves the earlier "route by name" framing: animate's old
`context == anim name` becomes `context == pick:<i>`, and the plugin does `anims[i]`.)

---

## 5. Phasing (all-delimited)

1. **kmod_dialogs — dual-accept.** Add the `button_rows` delimited path + delimited session
   click-map storage; KEEP legacy `button_data`/`buttons` working. Nothing else changes yet, so
   the collar is unaffected. Lint.
2. **kmod_menu — emit `button_rows`.** Convert render_paged (fixed/pager/UL/OL), render_modal,
   render_info to emit `button_rows` instead of `button_data`. Add `menu.picker`; convert the
   sensor picker to it and **delete `json_safe`**. Validate the **force-sit** picker in-world —
   it must now show real `[Ds] …` names.
3. **Pilot — plugin_animate.** Migrate to `menu.picker` (UL, `pick:<i>` routing). Test picker +
   Stop + play.
4. **Sweep — remaining 6 list pickers** (outfits, folders, blacklist, owners, leash, strip),
   one commit each, lint-clean.
5. **Direct-dialog plugins** (blacklist, owners, chat, status): convert any remaining direct
   `ui.dialog.open` sends to `button_rows`.
6. **Cleanup:** remove the legacy `button_data`/`buttons` paths from kmod_dialogs (+ the
   `numbered_list` path if unused). Single-format end state.
7. Reconcile dev→rc→stable, regen dashboard, re-bundle updater.

---

## 6. Risks / watch-items

- **Mono size:** `menu.picker` adds code to kmod_menu; converting sensor to share the core
  should net-neutralize. Measure with `lslinterpreter --mem-detail` before/after
  ([[reference_lslanalyzer_memory_estimator]]). kmod_menu is already the heaviest UI module.
- **Empty candidate list:** picker must degrade to a "None found" info dialog, not a blank
  box (menu.sensor already does this — reuse it).
- **`llCSV2List("")` / empty delimited string:** guard the empty-`labels` case before
  `llParseStringKeepNulls` ([[feedback_lsl_csv2list_empty]]).
- **Session/paging:** picker holds candidates across page flips (like `SensorSession`); ensure
  a new picker request supersedes an in-flight one (single-flight, as sensor does).
- **Two dialog formats coexisting in kmod_dialogs:** the delimited picker path and the JSON
  button_data path must not cross-talk; select strictly on the message's `dialog_type`.

---

## 7. Sign-off checklist

- **A. RESOLVED — OK.** UL/OL length-auto, threshold **24**, optional `shape` override.
- **B. RESOLVED — OK (no functional change), routing is CONTEXT-only.** Per
  [[project_v12_buttons_by_context]], plugins branch on `context`, never on a label. The
  `menu.picker` result carries **`context`** (UUID or `pick:<i>`) + `index`, and deliberately
  **no label field** — labels are display-only (§2.2a). Per-plugin the only change is plumbing:
  send `menu.picker` instead of building the dialog, and read `ui.menu.picker.result` (branch
  on `context`) instead of parsing a `ui.dialog.response`. Same action on the same click —
  nothing user-visible changes. (Corrects the earlier draft, which wrongly exposed `label` as
  actionable and framed name-routing as a fallback — both rejected; context is the sole routing
  token.)
- **C. RESOLVED — ALL DIALOGS DELIMITED.** One button transport everywhere; the JSON
  `button_data`/`buttons` paths are deleted at the end. Cleaner end state (single source of
  truth for button transport), larger change: convert render_modal/render_info/render_paged +
  the 4 direct-dialog plugins too.
  **Transition strategy:** kmod_dialogs temporarily accepts BOTH the new delimited field
  (`button_rows`) AND legacy `button_data`/`buttons`, so senders migrate one at a time with the
  collar working at every commit. Once all senders emit `button_rows`, the legacy paths are
  removed in a final cleanup commit. Transient dual-accept is scaffolding; the end state is
  single-format.
- **D. RESOLVED — OK.** Foundation + animate pilot, test in-world, then the other 6.
- **E. RESOLVED — OK.** Result message = `ui.menu.picker.result`.

# D/s Collar — Two-Agent In-World Smoketest

Automated end-to-end smoketest for the collar (v1.2). Two **scripted agents**
(SL bot accounts) log in together and exercise the collar exactly the way real
users do — one as the **collar wearer**, one as the **primary owner** — through
touch, menus, and the chat-command API. No collar code changes are needed.

This complements `LSLTestHarness`/`DSCollarTests` (offline unit tests): those
verify script logic in isolation; this verifies the real collar in a real
region — boot, RLV probing, ACL, dialogs, ownership handshakes, leash physics.

## Why bots (and not an LSL test HUD)

The collar is hardened against object-spoofed input, which rules out an
LSL-only driver:

- `kmod_dialogs` listens are key-scoped to the **avatar** (`llListen(chan, "",
  user, "")`) — a worn HUD speaks with the *object's* key and is filtered out.
- `kmod_chat` authorises the **speaker key** against the user roster
  (`user.<uuid>`), so commands must come from the avatar itself.

A scripted agent (LibreMetaverse bot) *is* the avatar: it touches, chats on
channel 1, and answers `llDialog` menus with the same packets a viewer sends.

## What the harness observes (assertion signals)

| Signal | Used for |
| --- | --- |
| Script dialogs (buttons + body) | menu structure, ACL-filtered views, consent flows |
| OwnerSay `@…` lines to the wearer | every RLV emission: lock, restrictions, exceptions, leash restraints, relay, safeword |
| Chat notices / channel 0 output | access list, status prints, denials |
| Inventory offers | Get HUD / User Manual handouts |
| Avatar positions (both bots) | leash follow and yank physically work |

The wearer bot also **emulates an RLV viewer**: the collar probes
`@versionnew=4711` at boot; the listener accepts any reply *from the wearer*,
so the bot answers like Firestorm would and all RLV-gated plugins activate.
RLV *enforcement* is a viewer concern — the smoketest asserts the collar
**emits** the right commands, which is precisely the collar's contract.

## Setup

1. **Accounts** — two alts registered as scripted agents. Park them in a quiet
   region you control, within 5 m of each other (touch range) and ideally with
   rez rights (for the fixture).
2. **Collar** — the wearer alt wears a fully loaded v1.2 collar, factory-fresh
   (no owner). `CollarObjectName` in the config must match a substring of the
   worn object's name.
3. **Fixture (optional, for the relay suite)** — rez a prim, drop in
   [fixtures/fixture_relay_trap.lsl](fixtures/fixture_relay_trap.lsl). It
   emulates an RLV-relay trap on the standard relay channel, commanded by the
   bots on positive channel 907001. Without it, the relay suite skips.
4. **Config** — copy `smoketest.example.json` → `smoketest.json` (gitignored)
   and fill in credentials.

## Run

```bash
cd test_harness/SmokeTest
dotnet run -- --config smoketest.json                # all non-destructive suites
dotnet run -- --suites baseline,ownership            # subset
dotnet run -- --config smoketest.json --destructive  # include Release/Runaway teardown
```

Exit code 0 = all pass. A markdown report is written to `smoketest-report.md`.

## Suites

| Suite | Covers |
| --- | --- |
| `baseline` | collar discovery, RLV probe, root menu (unowned ACL 4), `status`/`menu` chat commands, lock → `@detach=n/y`, Public off ⇒ stranger denied, Public on ⇒ minimal menu, animate |
| `ownership` | full Add Owner handshake (sensor pick → owner accept → honorific → wearer double-confirm → soft reboot), owner menu gains TPE, wearer loses Add Owner, owned-wearer lock denied (ACL 2) |
| `owner-controls` | owner lock/unlock, bell menu, Maintenance access list, Get HUD inventory offer, blacklist add ⇒ owner locked out ⇒ remove restores |
| `leash` | clip, length, **physical follow** (owner walks, wearer tracks), yank, unclip |
| `rlv` | Restrict menu applies `@…=n`, `restrict clear` lifts, owner-IM exception toggles |
| `relay` | ASK mode: apply + consent dialog; object release; ON mode + bare-word **safeword** clears (needs fixture) |
| `tpe-sos` | TPE enable w/ wearer consent, wearer menu gone, long-touch SOS (Runaway present), `sos` chat verb, TPE disable |
| `teardown` | *destructive, opt-in:* owner Release (both confirm, factory reset), re-own, wearer `sosrunaway` (factory reset) |

Suites assume the canonical order — `ownership` expects an unowned collar,
`owner-controls` an owned one. Running a subset out of order is fine as long
as the collar is in the matching state.

## Design notes / limits

- **Timing**: menus time out after 60 s; per-wait timeout is configurable
  (`WaitTimeoutSec`, default 20 s). Ownership changes soft-reboot the collar —
  `RebootWaitSec` (45 s) pads for that.
- Button matching is exact-then-substring, so cosmetic label tweaks
  (e.g. `Locked: N`) don't break tests.
- Bots cannot chat on negative channels (sim-enforced), hence the fixture
  bridge for the relay channel. The control-HUD remote protocol
  (-8675309/-10/-11) is not driven directly for the same reason; its
  functionality is covered via the menus it proxies.
- Multi-owner mode, settings-notecard seeding, coffle (needs a second collar),
  post leashing, and `#RLV` folder/outfit suites are not yet automated —
  natural next increments.
- Report + exit code make it CI-friendly for an OpenSim-based collar test
  region; against the SL main grid, run it manually and mind the ToS
  (register the alts as scripted agents).

## Files

- `Program.cs` — CLI entry: login both bots, run suites, write report.
- `BotAgent.cs` — one scripted agent: capture (chat / RLV OwnerSay / dialogs /
  inventory offers) + act (say, command, touch, long-touch, click, walk).
- `Scenarios.cs` — the test plan.
- `TestRunner.cs` — sequential runner, assertions, markdown report.
- `Config.cs` — smoketest.json schema.
- `fixtures/fixture_relay_trap.lsl` — in-world relay-trap emulator.

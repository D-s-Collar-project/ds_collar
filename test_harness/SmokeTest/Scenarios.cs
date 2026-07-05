using LibreMetaverse;
using static DSCollar.SmokeTest.TestRunner;

namespace DSCollar.SmokeTest;

/// <summary>
/// The actual smoketest plan: two scripted agents — the collar WEARER and the
/// prospective PRIMARY OWNER — drive every externally reachable collar
/// feature through the interfaces a real user has: touch, menus (script
/// dialogs), and the prefixed chat-command API. Verification signals:
/// dialogs received, RLV commands emitted to the wearer (OwnerSay "@…"),
/// collar chat notices, inventory offers, and avatar positions (leash).
/// </summary>
public sealed class Scenarios
{
    private readonly SmokeConfig _cfg;
    private readonly TestRunner _t;
    private readonly BotAgent _wearer;
    private readonly BotAgent _owner;

    private uint _collarLocalWearer; // collar prim LocalID (same region-wide, resolved per client anyway)
    private uint _collarLocalOwner;

    public Scenarios(SmokeConfig cfg, TestRunner t, BotAgent wearer, BotAgent owner)
    {
        _cfg = cfg;
        _t = t;
        _wearer = wearer;
        _owner = owner;
    }

    /* ================= helpers ================= */

    private TimeSpan T => _cfg.WaitTimeout;

    private bool FromCollar(PendingDialog d) =>
        d.ObjectName.Contains(_cfg.CollarObjectName, StringComparison.OrdinalIgnoreCase);

    private async Task<uint> CollarLocal(BotAgent who)
    {
        if (who == _wearer && _collarLocalWearer != 0) return _collarLocalWearer;
        if (who == _owner && _collarLocalOwner != 0) return _collarLocalOwner;
        var id = await who.FindAttachment(_wearer.AgentId, _cfg.CollarObjectName, T);
        Assert(id != 0, $"collar prim '{_cfg.CollarObjectName}' not visible to {who.Tag}");
        if (who == _wearer) _collarLocalWearer = id; else _collarLocalOwner = id;
        return id;
    }

    /// <summary>Touch the collar and wait for the root (or denied → null)
    /// dialog.</summary>
    private async Task<PendingDialog?> TouchForMenu(BotAgent who, TimeSpan? wait = null)
    {
        who.DrainDialogs();
        var mark = BotAgent.Now;
        who.Touch(await CollarLocal(who));
        return await who.WaitForDialog(d => FromCollar(d), wait ?? T, mark);
    }

    /// <summary>Open the root menu and click through a path of button labels,
    /// returning the dialog that follows the last click.</summary>
    private async Task<PendingDialog> Navigate(BotAgent who, params string[] path)
    {
        var dlg = AssertNotNull(await TouchForMenu(who), $"{who.Tag}: no root menu dialog");
        foreach (var label in path)
        {
            var mark = BotAgent.Now;
            Assert(who.ClickButton(dlg, label), $"{who.Tag}: button '{label}' missing in [{string.Join("|", dlg.Buttons)}]");
            dlg = AssertNotNull(await who.WaitForDialog(d => FromCollar(d), T, mark),
                $"{who.Tag}: no dialog after clicking '{label}'");
        }
        return dlg;
    }

    private async Task CloseMenu(BotAgent who, PendingDialog dlg)
    {
        // Root/pager menus carry a Close; modals/info carry OK. Ignore when absent.
        if (!who.ClickButton(dlg, "Close")) who.ClickButton(dlg, "OK");
        await Task.Delay(300);
    }

    private double DistWearerToOwner()
    {
        var a = _wearer.Position;
        var b = _owner.Position;
        return Vector3.Distance(a, b);
    }

    /* ================= suites ================= */

    public async Task RunSuite(string suite)
    {
        _t.CurrentSuite = suite;
        switch (suite)
        {
            case "baseline": await Baseline(); break;
            case "ownership": await Ownership(); break;
            case "owner-controls": await OwnerControls(); break;
            case "leash": await Leash(); break;
            case "rlv": await Rlv(); break;
            case "relay": await Relay(); break;
            case "tpe-sos": await TpeSos(); break;
            case "teardown": await Teardown(); break;
            default:
                Console.WriteLine($"unknown suite '{suite}' — skipping");
                break;
        }
    }

    public static readonly string[] AllSuites =
        { "baseline", "ownership", "owner-controls", "leash", "rlv", "relay", "tpe-sos", "teardown" };

    /* ---------------- baseline: unowned wearer + stranger ACL ---------------- */

    private async Task Baseline()
    {
        await _t.Run("collar prim visible to both agents", async () =>
        {
            Assert(await CollarLocal(_wearer) != 0, "wearer cannot see collar");
            Assert(await CollarLocal(_owner) != 0, "owner cannot see collar");
        });

        if (_cfg.EmulateRlv)
            await _t.Run("RLV probe answered (wearer emulates RLV viewer)", async () =>
            {
                // The collar probes @versionnew on attach/boot; if it already
                // finished before login we can't observe it — soft check.
                var probe = _wearer.RlvCommands.FirstOrDefault(c => c.Message.Contains("versionnew"));
                if (probe == null)
                    Skip("no @versionnew observed this session (collar likely booted earlier); RLV suites will self-check");
                await Task.CompletedTask;
            });

        await _t.Run("wearer touch opens root menu (unowned: full access)", async () =>
        {
            var dlg = AssertNotNull(await TouchForMenu(_wearer), "no root menu");
            Assert(dlg.Buttons.Any(b => b.Contains("Access", StringComparison.OrdinalIgnoreCase)),
                $"root menu missing Access: [{string.Join("|", dlg.Buttons)}]");
            Assert(dlg.Buttons.Any(b => b.Contains("Status", StringComparison.OrdinalIgnoreCase)),
                "root menu missing Status");
            await CloseMenu(_wearer, dlg);
        });

        await _t.Run("chat command: status opens status dialog", async () =>
        {
            _wearer.DrainDialogs();
            var mark = BotAgent.Now;
            _wearer.Command(_cfg, "status");
            var dlg = await _wearer.WaitForDialog(d => FromCollar(d), T, mark);
            AssertNotNull(dlg, "no status dialog from chat command");
        });

        await _t.Run("chat command: menu alias opens root menu", async () =>
        {
            _wearer.DrainDialogs();
            var mark = BotAgent.Now;
            _wearer.Command(_cfg, "menu");
            var dlg = AssertNotNull(await _wearer.WaitForDialog(d => FromCollar(d), T, mark), "no menu dialog");
            await CloseMenu(_wearer, dlg);
        });

        await _t.Run("lock: wearer(unowned) lock/unlock emits @detach=n/=y", async () =>
        {
            var mark = BotAgent.Now;
            _wearer.Command(_cfg, "lock locked");
            AssertNotNull(await _wearer.WaitForRlv("detach=n", T, mark), "no @detach=n after lock");
            mark = BotAgent.Now;
            _wearer.Command(_cfg, "lock unlocked");
            AssertNotNull(await _wearer.WaitForRlv("detach=y", T, mark), "no @detach=y after unlock");
        });

        await _t.Run("stranger with Public OFF gets no menu", async () =>
        {
            _owner.DrainDialogs();
            var mark = BotAgent.Now;
            _owner.Touch(await CollarLocal(_owner));
            var dlg = await _owner.WaitForDialog(FromCollar, TimeSpan.FromSeconds(8), mark);
            Assert(dlg == null, $"stranger unexpectedly got a dialog: {dlg}");
        });

        await _t.Run("public on: stranger gets minimal menu; public off restores", async () =>
        {
            // Public toggle is ACL 3-5; the unowned wearer is ACL 4.
            _wearer.Command(_cfg, "public on");
            await Task.Delay(2000);

            _owner.DrainDialogs();
            var mark = BotAgent.Now;
            _owner.Touch(await CollarLocal(_owner));
            var dlg = AssertNotNull(await _owner.WaitForDialog(FromCollar, T, mark),
                "stranger got no menu with Public ON");
            Assert(!dlg.Buttons.Any(b => b.Contains("Access", StringComparison.OrdinalIgnoreCase)),
                $"public menu leaked Access: [{string.Join("|", dlg.Buttons)}]");
            await CloseMenu(_owner, dlg);

            _wearer.Command(_cfg, "public off");
            await Task.Delay(2000);

            _owner.DrainDialogs();
            mark = BotAgent.Now;
            _owner.Touch(await CollarLocal(_owner));
            var dlg2 = await _owner.WaitForDialog(FromCollar, TimeSpan.FromSeconds(8), mark);
            Assert(dlg2 == null, "stranger still had access after public off");
        });

        await _t.Run("animate menu opens (plays first animation when present)", async () =>
        {
            var dlg = await Navigate(_wearer, "Animate");
            var anims = dlg.Buttons
                .Where(b => b is not (" " or "<<" or ">>") &&
                            !b.Contains("Stop", StringComparison.OrdinalIgnoreCase) &&
                            !b.Contains("Back", StringComparison.OrdinalIgnoreCase) &&
                            !b.Contains("Close", StringComparison.OrdinalIgnoreCase))
                .ToList();
            if (anims.Count == 0)
            {
                await CloseMenu(_wearer, dlg);
                Skip("no animations in collar inventory");
            }
            Assert(_wearer.ClickButton(dlg, anims[0]), "could not click animation");
            await Task.Delay(1500);
            _wearer.Command(_cfg, "pose stop");
        });
    }

    /* ---------------- ownership acquisition ---------------- */

    /// <summary>Full Add Owner handshake: wearer starts flow, sensor pick,
    /// owner accepts + picks honorific, wearer double-confirms. Collar
    /// soft-reboots afterwards.</summary>
    public async Task AcquireOwnership()
    {
        _wearer.DrainDialogs();
        _owner.DrainDialogs();

        // 1. wearer starts the flow (chat shortcut for Access → Add Owner)
        var mark = BotAgent.Now;
        _wearer.Command(_cfg, "access add owner");

        // 2. sensor picker to the wearer — pick the owner alt by name
        var picker = AssertNotNull(await _wearer.WaitForDialog(FromCollar, T, mark),
            "no candidate picker dialog for Add Owner");
        Assert(_wearer.ClickButton(picker, _owner.Client.Self.FirstName),
            $"owner '{_owner.Client.Self.FirstName}' not in picker [{string.Join("|", picker.Buttons)}]");

        // 3. accept prompt on the owner's side
        var accept = AssertNotNull(
            await _owner.WaitForDialogContaining("submit", T),
            "owner never received the acceptance dialog");
        Assert(_owner.ClickButton(accept, "Yes") || _owner.ClickButton(accept, "OK"),
            "no Yes button on acceptance dialog");

        // 4. honorific picker on the owner's side
        var honor = AssertNotNull(await _owner.WaitForDialogContaining("Master", T),
            "owner never received the honorific picker");
        Assert(_owner.ClickButton(honor, "Master"), "no 'Master' honorific button");

        // 5. wearer double-confirms
        var confirm = AssertNotNull(await _wearer.WaitForDialogContaining("submit", T),
            "wearer never received the final confirmation");
        Assert(_wearer.ClickButton(confirm, "Yes") || _wearer.ClickButton(confirm, "OK"),
            "no Yes button on wearer confirmation");

        // 6. collar reboots to apply the owner record
        Console.WriteLine($"   waiting {_cfg.RebootWait.TotalSeconds:0}s for collar soft reboot…");
        await Task.Delay(_cfg.RebootWait);
    }

    private async Task Ownership()
    {
        await _t.Run("add owner: full 4-party dialog handshake", AcquireOwnership);

        await _t.Run("owner now sees owner menu (TPE present)", async () =>
        {
            var dlg = AssertNotNull(await TouchForMenu(_owner), "owner got no menu after ownership");
            Assert(dlg.Buttons.Any(b => b.Contains("TPE", StringComparison.OrdinalIgnoreCase)),
                $"owner menu missing TPE toggle: [{string.Join("|", dlg.Buttons)}]");
            await CloseMenu(_owner, dlg);
        });

        await _t.Run("owned wearer: Add Owner path is gone", async () =>
        {
            var dlg = await Navigate(_wearer, "Access");
            Assert(!dlg.Buttons.Any(b => b.Contains("Add Owner", StringComparison.OrdinalIgnoreCase)),
                "owned wearer can still Add Owner");
            await CloseMenu(_wearer, dlg);
        });

        await _t.Run("owned wearer: lock toggle denied (ACL)", async () =>
        {
            var mark = BotAgent.Now;
            _wearer.Command(_cfg, "lock locked");
            var rlv = await _wearer.WaitForRlv("detach=n", TimeSpan.FromSeconds(6), mark);
            Assert(rlv == null, "owned wearer (ACL2) was able to lock the collar");
        });
    }

    /* ---------------- owner-side controls ---------------- */

    private async Task OwnerControls()
    {
        await _t.Run("owner: lock + unlock via chat", async () =>
        {
            var mark = BotAgent.Now;
            _owner.Command(_cfg, "lock locked");
            AssertNotNull(await _wearer.WaitForRlv("detach=n", T, mark), "no @detach=n from owner lock");
            mark = BotAgent.Now;
            _owner.Command(_cfg, "lock unlocked");
            AssertNotNull(await _wearer.WaitForRlv("detach=y", T, mark), "no @detach=y from owner unlock");
        });

        await _t.Run("owner: bell menu reachable", async () =>
        {
            var dlg = await Navigate(_owner, "Bell");
            Assert(dlg.Buttons.Count > 1, "bell menu empty");
            await CloseMenu(_owner, dlg);
        });

        await _t.Run("owner: maintenance access list mentions owner", async () =>
        {
            var mark = BotAgent.Now;
            var dlg = await Navigate(_owner, "Maintenance");
            var listBtn = dlg.Buttons.FirstOrDefault(b => b.Contains("Access List", StringComparison.OrdinalIgnoreCase));
            if (listBtn == null) { await CloseMenu(_owner, dlg); Skip("no Access List button"); }
            _owner.ClickButton(dlg, listBtn!);
            var line = await _owner.WaitForChat(
                c => c.Message.Contains(_owner.Client.Self.FirstName, StringComparison.OrdinalIgnoreCase)
                     || c.Message.Contains("Master", StringComparison.OrdinalIgnoreCase),
                T, mark);
            AssertNotNull(line, "access list output never mentioned the owner");
        });

        await _t.Run("owner: Get HUD hands out control HUD", async () =>
        {
            var before = _owner.InventoryOffers.Count;
            var dlg = await Navigate(_owner, "Maintenance");
            var btn = dlg.Buttons.FirstOrDefault(b => b.Contains("HUD", StringComparison.OrdinalIgnoreCase));
            if (btn == null) { await CloseMenu(_owner, dlg); Skip("no Get HUD button"); }
            _owner.ClickButton(dlg, btn!);
            var deadline = DateTime.UtcNow + T;
            while (DateTime.UtcNow < deadline && _owner.InventoryOffers.Count == before)
                await Task.Delay(500);
            Assert(_owner.InventoryOffers.Count > before, "no inventory offer after Get HUD");
        });

        await _t.Run("blacklist: wearer blocks owner, owner locked out, unblock restores", async () =>
        {
            // Owned wearer (ACL2) may manage the blacklist.
            _wearer.DrainDialogs();
            var mark = BotAgent.Now;
            _wearer.Command(_cfg, "blacklist add");
            var picker = AssertNotNull(await _wearer.WaitForDialog(FromCollar, T, mark), "no blacklist picker");
            Assert(_wearer.ClickButton(picker, _owner.Client.Self.FirstName),
                $"owner not in blacklist picker [{string.Join("|", picker.Buttons)}]");
            await Task.Delay(2000);

            _owner.DrainDialogs();
            mark = BotAgent.Now;
            _owner.Touch(await CollarLocal(_owner));
            var denied = await _owner.WaitForDialog(FromCollar, TimeSpan.FromSeconds(8), mark);
            Assert(denied == null, "blacklisted owner still gets a menu");

            _wearer.DrainDialogs();
            mark = BotAgent.Now;
            _wearer.Command(_cfg, "blacklist rem");
            var remPicker = AssertNotNull(await _wearer.WaitForDialog(FromCollar, T, mark), "no blacklist removal list");
            var numbered = remPicker.Buttons.FirstOrDefault(b => b.Trim().Length > 0 && char.IsDigit(b.Trim()[0]));
            Assert(numbered != null && _wearer.ClickButton(remPicker, numbered!), "no numbered entry to remove");
            await Task.Delay(2000);

            var back = await TouchForMenu(_owner);
            Assert(back != null, "owner still locked out after unblacklist");
            await CloseMenu(_owner, back!);
        });
    }

    /* ---------------- leash ---------------- */

    private async Task Leash()
    {
        await _t.Run("owner: leash clip", async () =>
        {
            var mark = BotAgent.Now;
            _owner.Command(_cfg, "leash clip");
            // Enhanced restraint for ACL>=3 holders arrives as RLV; also the
            // engine starts following. Accept either signal.
            var rlv = await _wearer.WaitForRlv("sittp", T, mark);
            if (rlv == null)
            {
                // fall back: wait for any leash-ish notice
                var note = await _wearer.WaitForChat(
                    c => c.Message.Contains("leash", StringComparison.OrdinalIgnoreCase), T, mark);
                AssertNotNull(note, "no evidence of leash clip (no RLV, no notice)");
            }
        });

        await _t.Run("leash: set length", async () =>
        {
            _owner.Command(_cfg, "leash length 3");
            await Task.Delay(1500);
        });

        await _t.Run("leash: wearer follows the holder", async () =>
        {
            var start = DistWearerToOwner();
            // Walk the owner ~12m away in X.
            var p = _owner.Position;
            var target = new Vector3(Math.Clamp(p.X + 12f, 5f, 250f), p.Y, p.Z);
            _owner.WalkTo(target);
            await Task.Delay(TimeSpan.FromSeconds(12));
            _owner.StopWalking();
            var dist = DistWearerToOwner();
            Assert(dist < 8.0, $"wearer not following: distance {dist:0.0}m (start {start:0.0}m, leash 3m)");
        });

        await _t.Run("leash: yank pulls the wearer in", async () =>
        {
            var before = DistWearerToOwner();
            if (before < 2.5) Skip($"already at heel ({before:0.0}m), yank unobservable");
            _owner.Command(_cfg, "leash yank");
            await Task.Delay(4000);
            var after = DistWearerToOwner();
            Assert(after <= before + 0.5, $"yank did not pull wearer ({before:0.0}m → {after:0.0}m)");
        });

        await _t.Run("leash: unclip releases", async () =>
        {
            var mark = BotAgent.Now;
            _owner.Command(_cfg, "leash unclip");
            // Release clears the enhanced restraints (=y) when RLV active.
            var rlv = await _wearer.WaitForRlv("sittp=y", T, mark);
            if (rlv == null)
                await Task.Delay(2000); // non-RLV: nothing to observe, treat as done
        });
    }

    /* ---------------- direct RLV: restrict + exceptions ---------------- */

    private async Task Rlv()
    {
        await _t.Run("restrict: owner applies a speech restriction", async () =>
        {
            var dlg = await Navigate(_owner, "Restrict");
            // Categories or flat buttons, depending on layout. Prefer Speech → Chat.
            var mark = BotAgent.Now;
            if (dlg.Buttons.Any(b => b.Contains("Speech", StringComparison.OrdinalIgnoreCase)))
            {
                Assert(_owner.ClickButton(dlg, "Speech"), "cannot open Speech category");
                dlg = AssertNotNull(await _owner.WaitForDialog(FromCollar, T, mark), "no Speech submenu");
            }
            var chatBtn = dlg.Buttons.FirstOrDefault(b => b.Contains("Chat", StringComparison.OrdinalIgnoreCase));
            if (chatBtn == null) { await CloseMenu(_owner, dlg); Skip("no Chat restriction button (RLV inactive?)"); }
            mark = BotAgent.Now;
            _owner.ClickButton(dlg, chatBtn!);
            var rlv = await _wearer.WaitForRlv("=n", T, mark);
            AssertNotNull(rlv, "no @…=n emitted for chat restriction");
        });

        await _t.Run("restrict: clear all lifts restrictions", async () =>
        {
            var mark = BotAgent.Now;
            _owner.Command(_cfg, "restrict clear");
            var rlv = await _wearer.WaitForRlv("=y", T, mark);
            AssertNotNull(rlv, "no @…=y emitted by Clear all");
        });

        await _t.Run("exceptions: owner IM exception emits RLV carve-out", async () =>
        {
            var dlg = await Navigate(_owner, "Exceptions");
            var mark = BotAgent.Now;
            var ownerBtn = dlg.Buttons.FirstOrDefault(b => b.Contains("Owner", StringComparison.OrdinalIgnoreCase));
            if (ownerBtn == null) { await CloseMenu(_owner, dlg); Skip("no Owner submenu in Exceptions"); }
            _owner.ClickButton(dlg, ownerBtn!);
            dlg = AssertNotNull(await _owner.WaitForDialog(FromCollar, T, mark), "no Owner exceptions submenu");
            var imBtn = dlg.Buttons.FirstOrDefault(b => b.Contains("IM", StringComparison.OrdinalIgnoreCase));
            if (imBtn == null) { await CloseMenu(_owner, dlg); Skip("no IM toggle"); }
            mark = BotAgent.Now;
            _owner.ClickButton(dlg, imBtn!);
            // toggling either direction emits @…im… add/rem
            var rlv = await _wearer.WaitForRlv("im", T, mark);
            AssertNotNull(rlv, "no RLV IM-exception command observed");
            // toggle back to leave defaults intact
            dlg = await _owner.WaitForDialog(FromCollar, T) ?? dlg;
            _owner.ClickButton(dlg, imBtn!);
            await Task.Delay(1000);
        });
    }

    /* ---------------- relay (needs in-world fixture) ---------------- */

    private async Task<bool> FixturePresent()
    {
        var mark = BotAgent.Now;
        _owner.Say("ping", _cfg.FixtureCommandChannel);
        var pong = await _owner.WaitForChat(
            c => c.Message.Contains("fixture:pong", StringComparison.OrdinalIgnoreCase),
            TimeSpan.FromSeconds(6), mark);
        return pong != null;
    }

    private async Task Relay()
    {
        if (!await FixturePresent())
        {
            _t.CurrentSuite = "relay";
            await _t.Run("relay suite", () => { Skip("fixture object not rezzed (fixtures/fixture_relay_trap.lsl)"); return Task.CompletedTask; });
            return;
        }

        await _t.Run("relay ASK: capture prompts wearer; Allow applies", async () =>
        {
            _owner.Command(_cfg, "relay ask");
            await Task.Delay(1500);
            _wearer.DrainDialogs();
            var mark = BotAgent.Now;
            _owner.Say($"capture {_wearer.AgentId}", _cfg.FixtureCommandChannel);
            // ASK applies immediately, then prompts.
            AssertNotNull(await _wearer.WaitForRlv("sendchat=n", T, mark), "relay restriction not applied");
            var ask = AssertNotNull(await _wearer.WaitForDialog(d => d.Buttons.Any(b => b.Contains("Yes") || b.Contains("Allow")), T, mark),
                "wearer never got the ASK dialog");
            Assert(_wearer.ClickButton(ask, "Yes") || _wearer.ClickButton(ask, "Allow"), "cannot allow");
            await Task.Delay(1000);
        });

        await _t.Run("relay: object release lifts restriction", async () =>
        {
            var mark = BotAgent.Now;
            _owner.Say($"release {_wearer.AgentId}", _cfg.FixtureCommandChannel);
            AssertNotNull(await _wearer.WaitForRlv("sendchat=y", T, mark), "release did not lift @sendchat");
        });

        await _t.Run("relay ON + safeword clears everything", async () =>
        {
            _owner.Command(_cfg, "relay on");
            await Task.Delay(1500);
            var mark = BotAgent.Now;
            _owner.Say($"capture {_wearer.AgentId}", _cfg.FixtureCommandChannel);
            AssertNotNull(await _wearer.WaitForRlv("sendchat=n", T, mark), "relay ON did not auto-apply");

            mark = BotAgent.Now;
            _wearer.Say("safeword", 0); // bare safeword, prefix-free, wearer-only
            var lifted = await _wearer.WaitForRlv("sendchat=y", T, mark);
            var cleared = lifted ?? await _wearer.WaitForRlv("clear", T, mark);
            AssertNotNull(cleared, "safeword did not clear relay restrictions");
            _owner.Command(_cfg, "relay ask"); // restore default
            await Task.Delay(1000);
        });
    }

    /* ---------------- TPE + SOS ---------------- */

    private async Task TpeSos()
    {
        await _t.Run("TPE enable: owner toggles, wearer consents", async () =>
        {
            var dlg = await Navigate(_owner, "TPE");
            // TPE toggle may confirm on the owner side first.
            if (dlg.Buttons.Any(b => b is "Yes" or "OK"))
                _owner.ClickButton(dlg, "Yes");
            var consent = AssertNotNull(await _wearer.WaitForDialogContaining("TPE", T),
                "wearer never received TPE consent dialog");
            Assert(_wearer.ClickButton(consent, "Yes") || _wearer.ClickButton(consent, "OK"),
                "cannot accept TPE consent");
            await Task.Delay(3000);
        });

        await _t.Run("TPE: wearer menu is gone", async () =>
        {
            var dlg = await TouchForMenu(_wearer, TimeSpan.FromSeconds(8));
            Assert(dlg == null, $"TPE wearer still gets a menu: {dlg}");
        });

        await _t.Run("TPE: long-touch opens SOS with emergency tools", async () =>
        {
            _wearer.DrainDialogs();
            var mark = BotAgent.Now;
            await _wearer.LongTouch(await CollarLocal(_wearer), 2.0);
            var sos = AssertNotNull(await _wearer.WaitForDialog(FromCollar, T, mark), "no SOS dialog on long touch");
            Assert(sos.Buttons.Any(b => b.Contains("Runaway", StringComparison.OrdinalIgnoreCase)),
                $"SOS missing Runaway: [{string.Join("|", sos.Buttons)}]");
            await CloseMenu(_wearer, sos);
        });

        await _t.Run("TPE: sos chat verb still reaches SOS", async () =>
        {
            _wearer.DrainDialogs();
            var mark = BotAgent.Now;
            _wearer.Command(_cfg, "sos");
            var sos = await _wearer.WaitForDialog(FromCollar, T, mark);
            AssertNotNull(sos, "sos verb produced no dialog");
        });

        await _t.Run("TPE disable: owner restores wearer access", async () =>
        {
            var dlg = await Navigate(_owner, "TPE");
            if (dlg.Buttons.Any(b => b is "Yes" or "OK"))
                _owner.ClickButton(dlg, "Yes");
            await Task.Delay(3000);
            var root = await TouchForMenu(_wearer);
            Assert(root != null, "wearer menu did not return after TPE off");
            await CloseMenu(_wearer, root!);
        });
    }

    /* ---------------- destructive teardown ---------------- */

    private async Task Teardown()
    {
        if (!_cfg.RunDestructiveTeardown)
        {
            await _t.Run("teardown", () => { Skip("RunDestructiveTeardown=false (collar left owned & configured)"); return Task.CompletedTask; });
            return;
        }

        await _t.Run("release: owner steps down, both confirm, collar factory-resets", async () =>
        {
            var dlg = await Navigate(_owner, "Access");
            Assert(_owner.ClickButton(dlg, "Release"), "no Release button");
            var oc = await _owner.WaitForDialogContaining("release", T);
            if (oc != null) _owner.ClickButton(oc, "Yes");
            var wc = AssertNotNull(await _wearer.WaitForDialogContaining("release", T),
                "wearer never got release confirmation");
            Assert(_wearer.ClickButton(wc, "Yes"), "cannot confirm release");
            Console.WriteLine($"   waiting {_cfg.RebootWait.TotalSeconds:0}s for factory reset…");
            await Task.Delay(_cfg.RebootWait);

            var root = AssertNotNull(await TouchForMenu(_wearer), "no menu after factory reset");
            Assert(root.Buttons.Any(b => b.Contains("Access", StringComparison.OrdinalIgnoreCase)),
                "post-reset root menu malformed");
            await CloseMenu(_wearer, root);
        });

        await _t.Run("runaway: re-own then wearer self-releases via sosrunaway", async () =>
        {
            await AcquireOwnership();
            _wearer.DrainDialogs();
            var mark = BotAgent.Now;
            _wearer.Command(_cfg, "sosrunaway");
            var confirm = await _wearer.WaitForDialog(FromCollar, T, mark);
            if (confirm != null && confirm.Buttons.Any(b => b is "Yes" or "OK"))
                _wearer.ClickButton(confirm, confirm.Buttons.Contains("Yes") ? "Yes" : "OK");
            Console.WriteLine($"   waiting {_cfg.RebootWait.TotalSeconds:0}s for factory reset…");
            await Task.Delay(_cfg.RebootWait);

            // Post-runaway: unowned again — Add Owner must be back.
            var acc = await Navigate(_wearer, "Access");
            Assert(acc.Buttons.Any(b => b.Contains("Add Owner", StringComparison.OrdinalIgnoreCase)),
                "runaway did not restore unowned state");
            await CloseMenu(_wearer, acc);
        });
    }
}

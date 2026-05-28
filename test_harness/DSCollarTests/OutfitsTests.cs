using NUnit.Framework;
using LSLTestHarness;
using static DSCollarTests.TestHelpers;

namespace DSCollarTests;

/// <summary>
/// Tests for plugin_outfits.lsl — focused on the behavioral changes in
/// rev 11 → rev 13: the three-phase Wear strip sequence and the
/// ~outfits/~base folder naming convention. Drives apply_wear directly
/// via InvokeFunction so the menu state machine doesn't have to be
/// stood up just to exercise the RLV emission path.
/// </summary>
[TestFixture]
public class OutfitsTests
{
    private const int RLV_BUS_NUM = TestHelpers.UI_BUS;  // plugin_outfits sends rlv.force via UI_BUS

    private LSLTestHarness.LSLTestHarness? _harness;

    [SetUp]
    public void Setup()
    {
        _harness = new LSLTestHarness.LSLTestHarness();
        string script = LoadScript("plugin_outfits.lsl");
        _harness.LoadScript(script);
        // state_entry emits registration / settings.sync chatter — drop it
        // so each test's assertions start clean.
        _harness.ClearOutputs();
    }

    [TearDown]
    public void TearDown()
    {
        _harness?.Reset();
    }

    /// <summary>
    /// Wear must emit four rlv.force messages in this exact order:
    ///   1. @detachallthis:~outfits=force       — clears the ~outfits subtree
    ///   2. @remattach=force                    — attachments worn from outside ~outfits
    ///   3. @remoutfit=force                    — clothing layers worn from outside ~outfits
    ///   4. @attachall:~outfits/&lt;name&gt;=force    — attaches the chosen outfit
    /// Phase ordering matters: any attach issued before the strip completes
    /// would have its items pulled off by the strip phases that follow.
    /// </summary>
    [Test]
    public void TestApplyWear_EmitsThreePhaseStripThenAttach()
    {
        _harness!.InvokeFunction("apply_wear", "Casual");

        var rlvCommands = ExtractRlvForceCommands(_harness.GetLinkMessages());

        Assert.That(rlvCommands.Count, Is.EqualTo(4),
            $"Expected 4 rlv.force commands, got {rlvCommands.Count}: [{string.Join(", ", rlvCommands)}]");

        Assert.That(rlvCommands[0], Is.EqualTo("@detachallthis:~outfits=force"),
            "Phase 1 must clear the ~outfits subtree first");
        Assert.That(rlvCommands[1], Is.EqualTo("@remattach=force"),
            "Phase 2 must strip outside-of-~outfits attachments");
        Assert.That(rlvCommands[2], Is.EqualTo("@remoutfit=force"),
            "Phase 3 must strip outside-of-~outfits clothing layers");
        Assert.That(rlvCommands[3], Is.EqualTo("@attachall:~outfits/Casual=force"),
            "Phase 4 attaches the chosen outfit AFTER the strip completes");
    }

    /// <summary>
    /// Wear must use @attachall (NOT @attachallthis) on the attach phase.
    /// The *this family is for locks and self-referential detach forces only;
    /// @attachallthis:&lt;path&gt;=force silently no-ops in some viewers, which
    /// was the rev 12 → rev 12 (post-rev-fix) regression that produced
    /// "strips but doesn't wear" behavior.
    /// </summary>
    [Test]
    public void TestApplyWear_AttachPhaseUsesAttachallNotAttachallthis()
    {
        _harness!.InvokeFunction("apply_wear", "Formal");

        var rlvCommands = ExtractRlvForceCommands(_harness.GetLinkMessages());

        Assert.That(rlvCommands.Count, Is.GreaterThan(0),
            "apply_wear must emit at least one rlv.force command");
        // The attach phase is the last command.
        string attachPhase = rlvCommands[rlvCommands.Count - 1];
        Assert.That(attachPhase, Does.StartWith("@attachall:"),
            $"Attach phase must use @attachall, got: {attachPhase}");
        Assert.That(attachPhase, Does.Not.StartWith("@attachallthis:"),
            "Attach phase must NOT use @attachallthis (silent no-op in some viewers)");
    }

    /// <summary>
    /// Wear must reference the tilde-prefixed folder name (~outfits, not .outfits).
    /// Guards against accidental regression of the rev 13 rename.
    /// </summary>
    [Test]
    public void TestApplyWear_UsesTildePrefixedFolderName()
    {
        _harness!.InvokeFunction("apply_wear", "BDSM");

        var rlvCommands = ExtractRlvForceCommands(_harness.GetLinkMessages());

        Assert.That(rlvCommands, Has.Some.Contains("~outfits"),
            "rlv.force commands must reference ~outfits (tilde-prefixed)");
        Assert.That(rlvCommands, Has.None.Contains(".outfits"),
            "rlv.force commands must NOT reference .outfits (legacy dot-prefix)");
    }

    /// <summary>
    /// Add uses @attachallover (additive — does not kick slot occupants)
    /// and emits exactly one rlv.force command. No strip phases.
    /// </summary>
    [Test]
    public void TestApplyAdd_EmitsSingleAttachalloverCommand()
    {
        _harness!.InvokeFunction("apply_add", "Casual");

        var rlvCommands = ExtractRlvForceCommands(_harness.GetLinkMessages());

        Assert.That(rlvCommands.Count, Is.EqualTo(1),
            "Add is additive — must emit exactly one rlv.force command");
        Assert.That(rlvCommands[0], Is.EqualTo("@attachallover:~outfits/Casual=force"),
            "Add must use @attachallover to layer on top without kicking slot occupants");
    }

    // ------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------

    /// <summary>
    /// Filter the captured link messages down to rlv.force command strings.
    /// plugin_outfits.rlv_force() sends a JSON envelope:
    ///   {"type":"rlv.force","command":"@..."}
    /// We extract just the "command" field in emission order.
    /// </summary>
    private static List<string> ExtractRlvForceCommands(List<LinkMessage> messages)
    {
        var commands = new List<string>();
        foreach (var m in messages)
        {
            if (GetJsonField(m.Msg, "type") != "rlv.force") continue;
            string command = GetJsonField(m.Msg, "command");
            if (!string.IsNullOrEmpty(command)) commands.Add(command);
        }
        return commands;
    }
}

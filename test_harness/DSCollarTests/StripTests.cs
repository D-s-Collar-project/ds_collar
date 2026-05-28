using NUnit.Framework;
using LSLTestHarness;
using static DSCollarTests.TestHelpers;

namespace DSCollarTests;

/// <summary>
/// Tests for plugin_strip.lsl rev 15 — the @getpath-based pre-filter pass
/// that hides @detachallthis-locked attachments from the picker. The
/// pre-filter pipeline has three parts: parse_detachallthis extracts
/// folder paths from @getstatusall:detach responses; QState=5 probes
/// each worn slot via @getpath; filter_worn_attach_by_folder drops slots
/// whose paths fall under any LockedFolders entry.
/// </summary>
[TestFixture]
public class StripTests
{
    private LSLTestHarness.LSLTestHarness? _harness;

    [SetUp]
    public void Setup()
    {
        _harness = new LSLTestHarness.LSLTestHarness();
        string script = LoadScript("plugin_strip.lsl");
        _harness.LoadScript(script);
        _harness.ClearOutputs();
    }

    [TearDown]
    public void TearDown()
    {
        _harness?.Reset();
    }

    /// <summary>
    /// Smoke test: plugin_strip loads cleanly with rev 15 additions
    /// (LockedFolders global, parse_detachallthis helper,
    /// filter_worn_attach_by_folder helper, QState=5 plumbing).
    /// </summary>
    [Test]
    public void TestStripLoadsCleanly()
    {
        // Already loaded in Setup; if we got here, syntax validation and
        // initial parse succeeded. Confirm the architecture-defining
        // globals are reachable.
        var lf = _harness!.GetGlobal("LockedFolders");
        Assert.That(lf, Is.Not.Null, "LockedFolders global must be defined");
    }

    /// <summary>
    /// filter_worn_attach_by_folder must be a no-op when LockedFolders is
    /// empty — wearers with no folder locks active see no added latency
    /// from the pre-filter pass.
    /// </summary>
    [Test]
    public void TestFilter_NoOpWhenNoFolderLocks()
    {
        _harness!.SetGlobal("LockedFolders", "[]");
        _harness.SetGlobal("WornAttach", "[\"chest\",\"Body Mesh\",\"left hand\",\"Gloves\"]");
        _harness.SetGlobal("AttachPaths", "[]");

        _harness.InvokeFunction("filter_worn_attach_by_folder");

        // WornAttach should be unchanged.
        var wornAfter = _harness.GetGlobal("WornAttach");
        Assert.That(wornAfter, Does.Contain("chest"),
            "Empty LockedFolders must leave WornAttach untouched");
        Assert.That(wornAfter, Does.Contain("left hand"),
            "Empty LockedFolders must leave WornAttach untouched");
    }

    /// <summary>
    /// filter_worn_attach_by_folder must also no-op when WornAttach is empty
    /// — the early-return guard avoids work when there's nothing to filter.
    /// </summary>
    [Test]
    public void TestFilter_NoOpWhenWornAttachEmpty()
    {
        _harness!.SetGlobal("LockedFolders", "[\"~outfits/~base\"]");
        _harness.SetGlobal("WornAttach", "[]");
        _harness.SetGlobal("AttachPaths", "[]");

        _harness.InvokeFunction("filter_worn_attach_by_folder");

        // No crash, no changes.
        var wornAfter = _harness.GetGlobal("WornAttach");
        Assert.That(wornAfter, Is.EqualTo("[]").Or.EqualTo(""),
            "Empty WornAttach must stay empty after filter");
    }
}

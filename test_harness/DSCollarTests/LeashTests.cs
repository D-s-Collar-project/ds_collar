using NUnit.Framework;
using LSLTestHarness;
using static DSCollarTests.TestHelpers;

namespace DSCollarTests;

/// <summary>
/// Tests for kmod_leash_engine.lsl rev 34 enhanced-mode behavior. Enhanced
/// mode is a persisted wearer toggle that issues @sittp,tploc,tplm,tplure=n
/// for the duration of a leash, but only when the leasher's ACL >= 3.
/// Restrictions follow the leash, not the leasher's presence — cleared
/// inside clearLeashState for every release path.
/// </summary>
[TestFixture]
public class LeashTests
{
    private const string ENHANCED_RESTRICTIONS_ON  = "@sittp=n,tploc=n,tplm=n,tplure=n";
    private const string ENHANCED_RESTRICTIONS_OFF = "@sittp=y,tploc=y,tplm=y,tplure=y";

    private LSLTestHarness.LSLTestHarness? _harness;

    [SetUp]
    public void Setup()
    {
        _harness = new LSLTestHarness.LSLTestHarness();
        string script = LoadScript("kmod_leash_engine.lsl");
        _harness.LoadScript(script);
        _harness.ClearOutputs();
    }

    [TearDown]
    public void TearDown()
    {
        _harness?.Reset();
    }

    /// <summary>
    /// applyEnhancedRestrictions must issue the four restrictions when
    /// EnhancedMode is on AND the captured leasher ACL is >= 3.
    /// </summary>
    [Test]
    public void TestEnhancedApply_FiresWhenToggleOnAndAclThree()
    {
        _harness!.SetGlobal("EnhancedMode", "1");
        _harness.SetGlobal("LeasherAcl", "3");
        _harness.SetGlobal("EnhancedActive", "0");

        _harness.InvokeFunction("applyEnhancedRestrictions");

        var ownerSay = _harness.GetOwnerSayMessages();
        Assert.That(ownerSay, Has.Some.EqualTo(ENHANCED_RESTRICTIONS_ON),
            $"Expected '{ENHANCED_RESTRICTIONS_ON}' in llOwnerSay, got: [{string.Join(", ", ownerSay)}]");
    }

    /// <summary>
    /// applyEnhancedRestrictions must NOT fire when the leasher's ACL is
    /// below 3 — the hard floor protects the wearer from a low-ACL leasher
    /// inheriting an enabled toggle from a previous session.
    /// </summary>
    [Test]
    public void TestEnhancedApply_GatedOffByLowAcl()
    {
        _harness!.SetGlobal("EnhancedMode", "1");
        _harness.SetGlobal("LeasherAcl", "2");
        _harness.SetGlobal("EnhancedActive", "0");

        _harness.InvokeFunction("applyEnhancedRestrictions");

        var ownerSay = _harness.GetOwnerSayMessages();
        Assert.That(ownerSay, Has.None.EqualTo(ENHANCED_RESTRICTIONS_ON),
            "ACL < 3 must not trigger enhanced restrictions even when toggle is on");
    }

    /// <summary>
    /// applyEnhancedRestrictions must NOT fire when the toggle is off,
    /// regardless of leasher ACL.
    /// </summary>
    [Test]
    public void TestEnhancedApply_GatedOffByToggleOff()
    {
        _harness!.SetGlobal("EnhancedMode", "0");
        _harness.SetGlobal("LeasherAcl", "5");
        _harness.SetGlobal("EnhancedActive", "0");

        _harness.InvokeFunction("applyEnhancedRestrictions");

        var ownerSay = _harness.GetOwnerSayMessages();
        Assert.That(ownerSay, Has.None.EqualTo(ENHANCED_RESTRICTIONS_ON),
            "Toggle off must suppress restrictions even at maximum ACL");
    }

    /// <summary>
    /// clearEnhancedRestrictions must issue the y-form when EnhancedActive
    /// is set (i.e. restrictions were previously applied).
    /// </summary>
    [Test]
    public void TestEnhancedClear_FiresWhenActive()
    {
        _harness!.SetGlobal("EnhancedActive", "1");

        _harness.InvokeFunction("clearEnhancedRestrictions");

        var ownerSay = _harness.GetOwnerSayMessages();
        Assert.That(ownerSay, Has.Some.EqualTo(ENHANCED_RESTRICTIONS_OFF),
            $"Expected '{ENHANCED_RESTRICTIONS_OFF}' in llOwnerSay, got: [{string.Join(", ", ownerSay)}]");
    }

    /// <summary>
    /// clearEnhancedRestrictions must be a no-op when EnhancedActive is
    /// already FALSE — idempotence guard so clear paths can fire blindly
    /// (unleash, offsim auto-release, region-change cleanup) without
    /// emitting spurious =y commands every time.
    /// </summary>
    [Test]
    public void TestEnhancedClear_IsNoOpWhenInactive()
    {
        _harness!.SetGlobal("EnhancedActive", "0");

        _harness.InvokeFunction("clearEnhancedRestrictions");

        var ownerSay = _harness.GetOwnerSayMessages();
        Assert.That(ownerSay, Has.None.EqualTo(ENHANCED_RESTRICTIONS_OFF),
            "clearEnhancedRestrictions must be idempotent — no emission when already cleared");
    }
}

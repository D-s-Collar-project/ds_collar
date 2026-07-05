using System.Text.Json;
using System.Text.Json.Serialization;

namespace DSCollar.SmokeTest;

public sealed class BotAccount
{
    public string FirstName { get; set; } = "";
    public string LastName { get; set; } = "Resident";
    public string Password { get; set; } = "";
}

public sealed class SmokeConfig
{
    /// <summary>Login URI. Defaults to the SL main grid (agni). Use your
    /// OpenSim/local grid URI when rehearsing off the main grid.</summary>
    public string LoginUri { get; set; } = "https://login.agni.lindenlab.com/cgi-bin/login.cgi";

    /// <summary>Login start location, e.g. "last", "home", or
    /// "uri:RegionName&amp;128&amp;128&amp;25".</summary>
    public string StartLocation { get; set; } = "last";

    public BotAccount Wearer { get; set; } = new();
    public BotAccount Owner { get; set; } = new();

    /// <summary>Substring of the collar object's name, used to locate the worn
    /// collar prim on the wearer.</summary>
    public string CollarObjectName { get; set; } = "collar";

    /// <summary>Collar chat command channel (chat.channel, default 1).</summary>
    public int ChatChannel { get; set; } = 1;

    /// <summary>Collar chat prefix. Empty = derive the collar default: the
    /// first two characters of the wearer's username, lowercased.</summary>
    public string ChatPrefix { get; set; } = "";

    /// <summary>Positive channel used to command the in-world test fixture
    /// object (fixtures/fixture_relay_trap.lsl). Must match FIXTURE_CMD_CHAN
    /// in the fixture script.</summary>
    public int FixtureCommandChannel { get; set; } = 907001;

    /// <summary>Wearer emulates an RLV viewer (answers the collar's
    /// @versionnew probe on channel 4711) so RLV-gated plugins are testable.</summary>
    public bool EmulateRlv { get; set; } = true;

    /// <summary>Default per-wait timeout in seconds for dialogs/chat.</summary>
    public double WaitTimeoutSec { get; set; } = 20.0;

    /// <summary>Seconds to allow for the collar's soft reboot after ownership
    /// changes / factory resets.</summary>
    public double RebootWaitSec { get; set; } = 45.0;

    /// <summary>Suites to run, in order. Empty = all. Names: baseline,
    /// ownership, owner-controls, rlv, relay, leash, tpe-sos, teardown.</summary>
    public List<string> Suites { get; set; } = new();

    /// <summary>Run destructive end-of-run tests (Release / Runaway factory
    /// resets). Leave false to keep the collar configured after the run.</summary>
    public bool RunDestructiveTeardown { get; set; } = false;

    /// <summary>Path of the markdown report to write. Empty = smoketest-report.md
    /// next to the binary.</summary>
    public string ReportPath { get; set; } = "";

    [JsonIgnore]
    public TimeSpan WaitTimeout => TimeSpan.FromSeconds(WaitTimeoutSec);
    [JsonIgnore]
    public TimeSpan RebootWait => TimeSpan.FromSeconds(RebootWaitSec);

    public static SmokeConfig Load(string path)
    {
        var json = File.ReadAllText(path);
        var cfg = JsonSerializer.Deserialize<SmokeConfig>(json, new JsonSerializerOptions
        {
            PropertyNameCaseInsensitive = true,
            ReadCommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true,
        }) ?? throw new InvalidOperationException($"Could not parse config {path}");

        if (string.IsNullOrWhiteSpace(cfg.Wearer.FirstName) ||
            string.IsNullOrWhiteSpace(cfg.Owner.FirstName))
            throw new InvalidOperationException("Config must set Wearer and Owner accounts.");

        if (cfg.ChatPrefix == "")
        {
            // Collar default: first two characters of the wearer's username,
            // lowercased ("firstname.lastname" -> "fi").
            var uname = cfg.Wearer.FirstName.ToLowerInvariant();
            cfg.ChatPrefix = uname.Length >= 2 ? uname[..2] : uname;
        }
        return cfg;
    }
}

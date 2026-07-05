using DSCollar.SmokeTest;

// D/s Collar in-world smoketest — two scripted agents (wearer + primary
// owner) drive every externally reachable collar feature and assert on the
// observable protocol: dialogs, RLV OwnerSay, chat notices, inventory
// offers, and positions.
//
// Usage:
//   dotnet run -- --config smoketest.json [--suites baseline,ownership,…] [--destructive]

string configPath = "smoketest.json";
string? suitesArg = null;
bool destructive = false;

for (var i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--config" when i + 1 < args.Length: configPath = args[++i]; break;
        case "--suites" when i + 1 < args.Length: suitesArg = args[++i]; break;
        case "--destructive": destructive = true; break;
        case "--help":
            Console.WriteLine("options: --config <path> --suites <csv> --destructive");
            Console.WriteLine("suites: " + string.Join(", ", Scenarios.AllSuites));
            return 0;
    }
}

if (!File.Exists(configPath))
{
    Console.Error.WriteLine($"Config not found: {configPath}");
    Console.Error.WriteLine("Copy smoketest.example.json to smoketest.json and fill in the bot accounts.");
    return 2;
}

var cfg = SmokeConfig.Load(configPath);
if (destructive) cfg.RunDestructiveTeardown = true;
if (!string.IsNullOrWhiteSpace(suitesArg))
    cfg.Suites = suitesArg.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries).ToList();

var suites = cfg.Suites.Count > 0 ? cfg.Suites : Scenarios.AllSuites.ToList();

Console.WriteLine($"D/s Collar smoketest — prefix '{cfg.ChatPrefix}', channel {cfg.ChatChannel}");
Console.WriteLine($"suites: {string.Join(" → ", suites)}");

using var wearer = new BotAgent("WEARER", cfg.Wearer.FirstName) { EmulateRlv = cfg.EmulateRlv };
using var owner = new BotAgent("OWNER", cfg.Owner.FirstName);
wearer.Log += m => Console.WriteLine("  " + m);
owner.Log += m => Console.WriteLine("  " + m);

using var cts = new CancellationTokenSource(TimeSpan.FromMinutes(45));

var loggedIn = await Task.WhenAll(
    wearer.LoginAsync(cfg, cfg.Wearer, cts.Token),
    owner.LoginAsync(cfg, cfg.Owner, cts.Token));
if (loggedIn.Contains(false))
{
    Console.Error.WriteLine("Login failed — aborting.");
    return 2;
}

// Let object updates stream in before we go hunting for the collar.
await Task.Delay(TimeSpan.FromSeconds(10));

var runner = new TestRunner();
var scenarios = new Scenarios(cfg, runner, wearer, owner);

foreach (var suite in suites)
{
    if (cts.IsCancellationRequested) break;
    await scenarios.RunSuite(suite);
}

var report = runner.BuildMarkdownReport("D/s Collar smoketest report");
var reportPath = string.IsNullOrWhiteSpace(cfg.ReportPath) ? "smoketest-report.md" : cfg.ReportPath;
File.WriteAllText(reportPath, report);
Console.WriteLine();
Console.WriteLine(report);
Console.WriteLine($"report written to {Path.GetFullPath(reportPath)}");

wearer.Logout();
owner.Logout();
await Task.Delay(2000); // let logout packets flush

return runner.FailCount > 0 ? 1 : 0;

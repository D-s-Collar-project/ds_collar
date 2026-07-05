using System.Text;

namespace DSCollar.SmokeTest;

public enum Verdict { Pass, Fail, Skip }

public sealed record TestResult(string Suite, string Name, Verdict Verdict, string Detail, TimeSpan Elapsed);

/// <summary>
/// Sequential scenario runner. Each test is an async lambda that throws
/// AssertException (or returns) — the runner records PASS/FAIL/SKIP, keeps
/// going, and writes a console + markdown report at the end.
/// </summary>
public sealed class TestRunner
{
    private readonly List<TestResult> _results = new();
    public string CurrentSuite { get; set; } = "general";
    public IReadOnlyList<TestResult> Results => _results;

    public sealed class AssertException(string message) : Exception(message);
    public sealed class SkipException(string message) : Exception(message);

    public static void Assert(bool cond, string what)
    {
        if (!cond) throw new AssertException(what);
    }

    public static T AssertNotNull<T>(T? value, string what) where T : class
    {
        if (value == null) throw new AssertException(what);
        return value;
    }

    public static void Skip(string why) => throw new SkipException(why);

    public async Task<bool> Run(string name, Func<Task> body)
    {
        var started = DateTime.UtcNow;
        Verdict verdict;
        string detail;
        try
        {
            Console.WriteLine($"── {CurrentSuite} :: {name}");
            await body();
            verdict = Verdict.Pass;
            detail = "";
        }
        catch (SkipException ex)
        {
            verdict = Verdict.Skip;
            detail = ex.Message;
        }
        catch (AssertException ex)
        {
            verdict = Verdict.Fail;
            detail = ex.Message;
        }
        catch (Exception ex)
        {
            verdict = Verdict.Fail;
            detail = $"unhandled {ex.GetType().Name}: {ex.Message}";
        }
        var elapsed = DateTime.UtcNow - started;
        _results.Add(new TestResult(CurrentSuite, name, verdict, detail, elapsed));
        var tagline = verdict switch
        {
            Verdict.Pass => "PASS",
            Verdict.Skip => $"SKIP ({detail})",
            _ => $"FAIL ({detail})",
        };
        Console.WriteLine($"   {tagline}  [{elapsed.TotalSeconds:0.0}s]");
        return verdict != Verdict.Fail;
    }

    public int FailCount => _results.Count(r => r.Verdict == Verdict.Fail);

    public string BuildMarkdownReport(string title)
    {
        var sb = new StringBuilder();
        sb.AppendLine($"# {title}");
        sb.AppendLine();
        sb.AppendLine($"Run finished: {DateTime.Now:yyyy-MM-dd HH:mm:ss}");
        sb.AppendLine();
        var pass = _results.Count(r => r.Verdict == Verdict.Pass);
        var skip = _results.Count(r => r.Verdict == Verdict.Skip);
        sb.AppendLine($"**{pass} passed, {FailCount} failed, {skip} skipped** of {_results.Count} tests.");
        sb.AppendLine();
        foreach (var suite in _results.GroupBy(r => r.Suite))
        {
            sb.AppendLine($"## {suite.Key}");
            sb.AppendLine();
            sb.AppendLine("| Test | Verdict | Detail | Time |");
            sb.AppendLine("| --- | --- | --- | --- |");
            foreach (var r in suite)
            {
                var v = r.Verdict switch
                {
                    Verdict.Pass => "✅ pass",
                    Verdict.Skip => "⏭ skip",
                    _ => "❌ FAIL",
                };
                sb.AppendLine($"| {r.Name} | {v} | {r.Detail.Replace("|", "\\|")} | {r.Elapsed.TotalSeconds:0.0}s |");
            }
            sb.AppendLine();
        }
        return sb.ToString();
    }
}

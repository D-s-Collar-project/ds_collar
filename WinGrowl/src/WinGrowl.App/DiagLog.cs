using System.IO;

namespace WinGrowl.App;

public sealed class DiagLog : IDisposable
{
    private readonly StreamWriter _writer;
    private readonly object _lock = new();
    public string Path { get; }

    public DiagLog()
    {
        var dir = System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WinGrowl");
        Directory.CreateDirectory(dir);
        Path = System.IO.Path.Combine(dir, "wingrowl.log");
        _writer = new StreamWriter(new FileStream(Path, FileMode.Append, FileAccess.Write, FileShare.Read)) { AutoFlush = true };
        Write("--- WinGrowl started ---");
    }

    public void Write(string msg)
    {
        var line = $"{DateTime.Now:yyyy-MM-dd HH:mm:ss.fff} {msg}";
        lock (_lock) _writer.WriteLine(line);
    }

    public void Dispose() => _writer.Dispose();
}

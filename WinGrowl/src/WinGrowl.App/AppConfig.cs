using System.IO;
using System.Net;
using System.Text.Json;

namespace WinGrowl.App;

public sealed class AppConfig
{
    public string ListenAddress { get; set; } = "127.0.0.1";
    public int Port { get; set; } = 23053;
    public string? Password { get; set; }
    public bool AllowNetworkClients { get; set; } = false;
    public bool ShowToasts { get; set; } = true;
    public bool PlaySound { get; set; } = true;

    public IPEndPoint GetEndpoint()
    {
        if (!IPAddress.TryParse(ListenAddress, out var addr))
            addr = AllowNetworkClients ? IPAddress.Any : IPAddress.Loopback;
        return new IPEndPoint(addr, Port);
    }

    private static string DefaultPath()
    {
        var appData = Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData);
        var dir = Path.Combine(appData, "WinGrowl");
        Directory.CreateDirectory(dir);
        return Path.Combine(dir, "config.json");
    }

    public static AppConfig Load()
    {
        var path = DefaultPath();
        if (!File.Exists(path)) return new AppConfig();
        try
        {
            var json = File.ReadAllText(path);
            return JsonSerializer.Deserialize<AppConfig>(json) ?? new AppConfig();
        }
        catch
        {
            return new AppConfig();
        }
    }

    public void Save()
    {
        var path = DefaultPath();
        var json = JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true });
        File.WriteAllText(path, json);
    }
}

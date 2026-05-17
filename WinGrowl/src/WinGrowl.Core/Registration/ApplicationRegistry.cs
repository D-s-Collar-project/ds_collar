using WinGrowl.Core.Gntp.Messages;

namespace WinGrowl.Core.Registration;

public sealed class RegisteredApplication
{
    public required string Name { get; init; }
    public byte[]? Icon { get; set; }
    public Dictionary<string, RegisteredType> Types { get; } = new(StringComparer.OrdinalIgnoreCase);
}

public sealed class ApplicationRegistry
{
    private readonly Dictionary<string, RegisteredApplication> _apps = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _lock = new();

    public void Register(RegisterMessage msg)
    {
        lock (_lock)
        {
            if (!_apps.TryGetValue(msg.ApplicationName, out var app))
            {
                app = new RegisteredApplication { Name = msg.ApplicationName };
                _apps[msg.ApplicationName] = app;
            }
            if (msg.ApplicationIcon is not null) app.Icon = msg.ApplicationIcon.Data;
            foreach (var t in msg.Types)
            {
                app.Types[t.Name] = t;
            }
        }
    }

    public bool TryGet(string applicationName, out RegisteredApplication app)
    {
        lock (_lock)
        {
            if (_apps.TryGetValue(applicationName, out var a)) { app = a; return true; }
            app = null!;
            return false;
        }
    }

    public bool IsEnabled(string applicationName, string notificationName)
    {
        lock (_lock)
        {
            if (!_apps.TryGetValue(applicationName, out var app)) return false;
            if (!app.Types.TryGetValue(notificationName, out var t)) return false;
            return t.Enabled;
        }
    }

    // Auto-register a notification type the first time a NOTIFY references
    // it (Growl-for-Windows behavior). Returns true if the app is known
    // (newly added type or pre-existing); false if the app itself is not
    // registered yet — caller should reject NOTIFY in that case. Newly
    // added types default to Enabled=true and DisplayName=Name; the user
    // can disable them later via the tray UI.
    public bool EnsureType(string applicationName, string notificationName)
    {
        lock (_lock)
        {
            if (!_apps.TryGetValue(applicationName, out var app)) return false;
            if (!app.Types.ContainsKey(notificationName))
            {
                app.Types[notificationName] = new RegisteredType(
                    notificationName, notificationName, true, null, null);
            }
            return true;
        }
    }

    public IReadOnlyList<RegisteredApplication> Snapshot()
    {
        lock (_lock) return _apps.Values.ToArray();
    }
}

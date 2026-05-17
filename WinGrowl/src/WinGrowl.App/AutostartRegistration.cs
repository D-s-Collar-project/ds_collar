using Microsoft.Win32;

namespace WinGrowl.App;

// HKCU Run-key wrapper for "Start with Windows" toggle. Value name
// matches the installer's [Registry] entry so toggling here doesn't
// fight the installer-time checkbox — both paths write/clear the same
// "WinGrowl" value. Per-user scope (HKCU, not HKLM) so no elevation
// needed and the entry tracks the install scope the user picked.
internal static class AutostartRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "WinGrowl";

    public static bool IsEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: false);
        return key?.GetValue(ValueName) is string s && s.Length > 0;
    }

    public static void Enable()
    {
        var exe = Environment.ProcessPath;
        if (string.IsNullOrEmpty(exe)) return;
        using var key = Registry.CurrentUser.CreateSubKey(RunKey, writable: true);
        key.SetValue(ValueName, $"\"{exe}\"", RegistryValueKind.String);
    }

    public static void Disable()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey, writable: true);
        key?.DeleteValue(ValueName, throwOnMissingValue: false);
    }
}

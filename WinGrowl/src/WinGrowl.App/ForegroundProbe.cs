using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

namespace WinGrowl.App;

// Diagnostic helper. Captures "what window currently has focus" so the
// log can show, for every incoming NOTIFY, whether the sending app is
// actually foreground at the moment its notification arrived. This
// pins down the "is WinGrowl missing toasts when the app is unfocused
// but visible?" question with hard evidence instead of guesswork —
// before this we could only see that a NOTIFY arrived, not what the
// desktop state was around it.
internal static class ForegroundProbe
{
    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = false)]
    private static extern int GetWindowText(IntPtr hWnd, StringBuilder lpString, int nMaxCount);

    [DllImport("user32.dll", SetLastError = false)]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);

    // Returns "ProcessName (pid) \"window title\"" for the currently
    // focused window, or "<none>" if nothing is foreground. Single-line
    // by design — meant to be appended to a log message.
    public static string Snapshot()
    {
        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return "<none>";

        GetWindowThreadProcessId(hwnd, out var pid);
        string processName = "?";
        try
        {
            using var p = Process.GetProcessById((int)pid);
            processName = p.ProcessName;
        }
        catch
        {
            // Process exited between GetForegroundWindow and Process.GetProcessById,
            // or access denied on a protected process — fall back to "?".
        }

        var title = new StringBuilder(256);
        GetWindowText(hwnd, title, title.Capacity);
        return $"{processName} ({pid}) \"{title}\"";
    }

    // Focus watchdog. Returns true when the current foreground window
    // belongs to a process whose name prefix-matches the first token of
    // the GNTP Application-Name. Same matching rule as
    // WindowActivator.FocusByApplicationName, so the round-trip is
    // symmetric: any app we can route a toast click back to is an app
    // we can recognize as currently-foreground.
    public static bool IsApplicationForeground(string applicationName)
    {
        if (string.IsNullOrWhiteSpace(applicationName)) return false;
        var token = applicationName.Split(new[] { ' ', '-', '_' }, 2,
            StringSplitOptions.RemoveEmptyEntries)[0];
        if (token.Length == 0) return false;

        var hwnd = GetForegroundWindow();
        if (hwnd == IntPtr.Zero) return false;
        GetWindowThreadProcessId(hwnd, out var pid);
        try
        {
            using var p = Process.GetProcessById((int)pid);
            return p.ProcessName.StartsWith(token, StringComparison.OrdinalIgnoreCase);
        }
        catch
        {
            return false;
        }
    }
}

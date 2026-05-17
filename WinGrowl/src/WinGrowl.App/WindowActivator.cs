using System.Diagnostics;
using System.Runtime.InteropServices;

namespace WinGrowl.App;

// Toast-click focus router. Given the GNTP Application-Name from the
// notification's payload, locate a running process whose name matches
// and pull its main window to the foreground. Heuristic: prefix-match
// on the first delimited token of Application-Name against ProcessName,
// case-insensitive. Examples:
//   "Firestorm"      → Firestorm-Releasex64.exe, Firestorm-Beta_x64.exe
//   "Pidgin"         → pidgin.exe
//   "foobar2000"     → foobar2000.exe
// The token-based match deliberately handles channel/variant suffixes
// that desktop apps tack onto their process names.
internal static class WindowActivator
{
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsIconic(IntPtr hWnd);

    private const int SW_RESTORE = 9;

    public static bool FocusByApplicationName(string applicationName)
    {
        if (string.IsNullOrWhiteSpace(applicationName)) return false;
        var token = applicationName.Split(new[] { ' ', '-', '_' }, 2,
            StringSplitOptions.RemoveEmptyEntries)[0];
        if (token.Length == 0) return false;

        Process? target = null;
        foreach (var p in Process.GetProcesses())
        {
            try
            {
                if (p.ProcessName.StartsWith(token, StringComparison.OrdinalIgnoreCase) &&
                    p.MainWindowHandle != IntPtr.Zero)
                {
                    target = p;
                    break;
                }
            }
            catch
            {
                // Access denied on protected system processes — skip.
            }
        }

        if (target is null) return false;
        var hwnd = target.MainWindowHandle;
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        return SetForegroundWindow(hwnd);
    }
}

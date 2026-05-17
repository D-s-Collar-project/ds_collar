using System.Drawing;
using System.IO;
using System.Windows.Forms;
using WinGrowl.Core.Registration;

namespace WinGrowl.App;

public sealed class TrayIconHost : IDisposable
{
    private readonly NotifyIcon _icon;
    private readonly ContextMenuStrip _menu;
    private readonly ApplicationRegistry _registry;

    public TrayIconHost(ApplicationRegistry registry, AppConfig config, Action onQuit)
    {
        _ = config;
        _registry = registry;

        _menu = new ContextMenuStrip();
        _menu.Items.Add("WinGrowl").Enabled = false;
        _menu.Items.Add(new ToolStripSeparator());
        var statusItem = _menu.Items.Add("Status: starting…");
        statusItem.Enabled = false;
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add("Show registered apps", null, (_, _) => ShowApps());
        _menu.Items.Add(new ToolStripSeparator());
        var autostart = new ToolStripMenuItem("Start with Windows")
        {
            CheckOnClick = true,
            Checked = AutostartRegistration.IsEnabled(),
        };
        autostart.CheckedChanged += (_, _) =>
        {
            if (autostart.Checked) AutostartRegistration.Enable();
            else AutostartRegistration.Disable();
        };
        _menu.Items.Add(autostart);
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add("Quit", null, (_, _) => onQuit());

        _icon = new NotifyIcon
        {
            Visible = true,
            Icon = LoadTrayIcon(),
            Text = "WinGrowl",
            ContextMenuStrip = _menu,
        };
        _icon.MouseUp += (_, e) => { if (e.Button == MouseButtons.Left) ShowApps(); };
    }

    // Load the tray icon from the assembly's embedded resource stream
    // (csproj <EmbeddedResource Include="Assets\wingrowl.ico"> with the
    // pinned LogicalName below). Same source .ico that <ApplicationIcon>
    // embeds as the Win32 exe icon — single source of truth, no loose
    // file shipped alongside the exe. Pass an explicit
    // SystemInformation.SmallIconSize hint so Windows picks the closest
    // size from the .ico instead of downsampling 256×256 to the tray's
    // ~16×16 every paint. Falls back to SystemIcons.Information if the
    // resource is missing (shouldn't happen in a shipped build).
    private static Icon LoadTrayIcon()
    {
        var asm = typeof(TrayIconHost).Assembly;
        using var stream = asm.GetManifestResourceStream("WinGrowl.App.Assets.wingrowl.ico");
        if (stream is not null)
        {
            try
            {
                var size = SystemInformation.SmallIconSize;
                return new Icon(stream, size.Width, size.Height);
            }
            catch { }
        }
        return SystemIcons.Information;
    }

    public void SetStatus(string text)
    {
        if (_menu.Items.Count >= 3)
        {
            _menu.Items[2].Text = $"Status: {text}";
        }
        _icon.Text = $"WinGrowl — {text}".Substring(0, Math.Min(63, $"WinGrowl — {text}".Length));
    }

    private void ShowApps()
    {
        var apps = _registry.Snapshot();
        if (apps.Count == 0)
        {
            MessageBox.Show("No applications have registered yet.", "WinGrowl", MessageBoxButtons.OK, MessageBoxIcon.Information);
            return;
        }
        var lines = apps.Select(a => $"• {a.Name} ({a.Types.Count} notification types)");
        MessageBox.Show(string.Join("\n", lines), "WinGrowl — Registered apps", MessageBoxButtons.OK, MessageBoxIcon.Information);
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _menu.Dispose();
    }
}

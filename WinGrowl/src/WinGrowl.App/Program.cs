using System.Windows.Forms;
using Microsoft.Toolkit.Uwp.Notifications;
using WinGrowl.Core.Gntp;
using WinGrowl.Core.Registration;

namespace WinGrowl.App;

public static class Program
{
    [STAThread]
    public static void Main()
    {
        ApplicationConfiguration.Initialize();

        var config = AppConfig.Load();
        var registry = new ApplicationRegistry();
        var toaster = new ToastBridge();
        using var log = new DiagLog();

        var serverOptions = new GntpServerOptions
        {
            Endpoint = config.GetEndpoint(),
            Password = config.Password,
            AllowNetworkClients = config.AllowNetworkClients,
        };

        var server = new GntpServer(serverOptions, registry);
        var syncCtx = new WindowsFormsSynchronizationContext();
        SynchronizationContext.SetSynchronizationContext(syncCtx);

        // Route toast clicks back to the sending app's window. The
        // AddArgument calls in ToastBridge attach 'applicationName';
        // WindowActivator does a process-name prefix match and pulls
        // the matching window forward. Fires on a background thread —
        // P/Invoke and process enumeration don't need UI marshaling.
        ToastNotificationManagerCompat.OnActivated += args =>
        {
            try
            {
                var parsed = ToastArguments.Parse(args.Argument);
                if (parsed.TryGetValue("applicationName", out var appName) && !string.IsNullOrEmpty(appName))
                {
                    var focused = WindowActivator.FocusByApplicationName(appName);
                    log.Write($"toast-click app='{appName}' focused={focused}");
                }
            }
            catch (Exception ex) { log.Write($"toast-click-error: {ex.Message}"); }
        };

        server.Diagnostic += msg => log.Write(msg);
        server.Registered += (_, r) => log.Write($"REGISTER app='{r.ApplicationName}' types={r.Types.Count}");
        server.Notification += (_, n) =>
        {
            var fg = ForegroundProbe.Snapshot();
            var senderIsForeground = ForegroundProbe.IsApplicationForeground(n.ApplicationName);
            log.Write($"NOTIFY app='{n.ApplicationName}' name='{n.NotificationName}' title='{n.Title}' foreground={fg} senderIsForeground={senderIsForeground}");
            if (!config.ShowToasts) return;
            // Focus watchdog gate: skip standard toast dispatch when the
            // sender app is currently the foreground window. The user is
            // already looking at the source; a toast in that state is
            // noise. When unfocused (the path the user actually cares
            // about) we dispatch a normal Windows toast — no scenario
            // escalation, no stickiness, just the platform default.
            if (senderIsForeground)
            {
                log.Write($"toast-skipped sender-foreground app='{n.ApplicationName}' name='{n.NotificationName}'");
                return;
            }
            syncCtx.Post(_ =>
            {
                try
                {
                    toaster.Show(n);
                    log.Write($"toast-dispatched app='{n.ApplicationName}' name='{n.NotificationName}'");
                }
                catch (Exception ex) { log.Write($"toast-error: {ex.Message}"); }
            }, null);
        };
        server.ProtocolError += (_, ex) => log.Write($"protocol-error {ex.Code}: {ex.Message}");

        var tray = new TrayIconHost(registry, config, () => Application.Exit());

        try
        {
            server.StartAsync().GetAwaiter().GetResult();
            var host = serverOptions.AllowNetworkClients ? "all interfaces" : "localhost";
            var status = $"Listening on {host} port {serverOptions.Endpoint.Port}";
            tray.SetStatus(status);
            log.Write(status + $" — log at {log.Path}");
        }
        catch (Exception ex)
        {
            tray.SetStatus($"listen failed: {ex.Message}");
            log.Write($"listen failed: {ex.Message}");
            MessageBox.Show($"Could not bind :{serverOptions.Endpoint.Port}:\n{ex.Message}", "WinGrowl", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }

        Application.ApplicationExit += async (_, _) =>
        {
            try { await server.DisposeAsync(); } catch { }
        };

        Application.Run();

        tray.Dispose();
    }
}

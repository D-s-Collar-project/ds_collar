using System.IO;
using Microsoft.Windows.AppNotifications;
using Microsoft.Windows.AppNotifications.Builder;
using WinGrowl.Core.Gntp.Messages;

namespace WinGrowl.App;

public sealed class ToastBridge
{
    private readonly string _iconCacheDir;

    public ToastBridge()
    {
        _iconCacheDir = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "WinGrowl", "icons");
        Directory.CreateDirectory(_iconCacheDir);
    }

    public void Show(NotifyMessage n, int? senderPid = null)
    {
        // WinAppSDK 2.x AppNotificationBuilder. Replaces the deprecated
        // Microsoft.Toolkit.Uwp.Notifications ToastContentBuilder path.
        // Builds the same underlying toast XML schema, but routed via
        // AppNotificationManager.Default which auto-registers the COM
        // activator needed for click handling in unpackaged apps.
        var builder = new AppNotificationBuilder()
            .AddText(n.Title)
            .AddText(n.Text);

        if (!string.IsNullOrEmpty(n.ApplicationName))
        {
            // No first-class attribution helper in AppNotificationBuilder;
            // a third AddText reads as a small line under the message,
            // close enough to GfW's source-app footer.
            builder.AddText(n.ApplicationName);
        }

        var iconUri = ResolveIcon(n);
        if (iconUri is not null)
        {
            try { builder.SetAppLogoOverride(iconUri, AppNotificationImageCrop.Default); } catch { }
        }

        if (!string.IsNullOrEmpty(n.NotificationId))
        {
            builder.AddArgument("notificationId", n.NotificationId);
        }
        builder.AddArgument("applicationName", n.ApplicationName);
        builder.AddArgument("notificationName", n.NotificationName);
        // PID lets the click handler focus the exact instance that sent
        // this notification, instead of name-prefix-matching and possibly
        // picking the wrong Firestorm. Omitted when unresolved (remote
        // GNTP client, race with connection teardown, etc.); handler
        // falls back to FocusByApplicationName.
        if (senderPid is int pid && pid > 0)
        {
            builder.AddArgument("senderPid", pid.ToString());
        }

        var notification = builder.BuildNotification();
        notification.Tag = n.NotificationId ?? Guid.NewGuid().ToString("N");
        notification.Group = n.ApplicationName ?? string.Empty;
        // No Expiration: that property controls how long the notification
        // stays in Action Center after first showing, not the banner
        // duration (banner duration is the user's system setting).
        // Setting it to a few seconds, as earlier versions did, deleted
        // the notification from Action Center seconds after it appeared
        // — meaning nothing the user actually wanted to review later
        // was findable. Let Windows apply its default retention.
        AppNotificationManager.Default.Show(notification);
    }

    private Uri? ResolveIcon(NotifyMessage n)
    {
        if (n.Icon is { } binary)
        {
            var name = SafeName(n.IconValue ?? Guid.NewGuid().ToString("N")) + GuessExtension(binary.Data);
            var path = Path.Combine(_iconCacheDir, name);
            if (!File.Exists(path))
            {
                try { File.WriteAllBytes(path, binary.Data); } catch { return null; }
            }
            return new Uri(path);
        }
        if (!string.IsNullOrEmpty(n.IconValue) && Uri.TryCreate(n.IconValue, UriKind.Absolute, out var u) &&
            (u.Scheme == Uri.UriSchemeHttp || u.Scheme == Uri.UriSchemeHttps))
        {
            return u;
        }
        return null;
    }

    private static string SafeName(string s)
    {
        var bad = Path.GetInvalidFileNameChars();
        var chars = s.ToCharArray();
        for (int i = 0; i < chars.Length; i++)
            if (Array.IndexOf(bad, chars[i]) >= 0) chars[i] = '_';
        return new string(chars);
    }

    private static string GuessExtension(byte[] data)
    {
        if (data.Length >= 8 && data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4e && data[3] == 0x47) return ".png";
        if (data.Length >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff) return ".jpg";
        if (data.Length >= 4 && data[0] == 0x47 && data[1] == 0x49 && data[2] == 0x46) return ".gif";
        return ".bin";
    }
}

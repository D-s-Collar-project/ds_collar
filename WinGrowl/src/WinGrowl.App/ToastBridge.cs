using System.IO;
using Microsoft.Toolkit.Uwp.Notifications;
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

    public void Show(NotifyMessage n)
    {
        var builder = new ToastContentBuilder()
            .AddText(n.Title)
            .AddText(n.Text);

        if (!string.IsNullOrEmpty(n.ApplicationName))
        {
            builder.AddAttributionText(n.ApplicationName);
        }

        var iconPath = ResolveIcon(n);
        if (iconPath is not null)
        {
            try { builder.AddAppLogoOverride(new Uri(iconPath), ToastGenericAppLogoCrop.Default); } catch { }
        }

        if (!string.IsNullOrEmpty(n.NotificationId))
        {
            builder.AddArgument("notificationId", n.NotificationId);
        }
        builder.AddArgument("applicationName", n.ApplicationName);
        builder.AddArgument("notificationName", n.NotificationName);

        builder.Show(toast =>
        {
            toast.Tag = (n.NotificationId ?? Guid.NewGuid().ToString("N"));
            toast.Group = n.ApplicationName;
            if (n.Sticky)
            {
                toast.ExpirationTime = null;
            }
            else
            {
                toast.ExpirationTime = DateTimeOffset.Now.AddSeconds(n.Priority >= NotifyPriority.High ? 15 : 8);
            }
        });
    }

    private string? ResolveIcon(NotifyMessage n)
    {
        if (n.Icon is { } binary)
        {
            var name = SafeName(n.IconValue ?? Guid.NewGuid().ToString("N")) + GuessExtension(binary.Data);
            var path = Path.Combine(_iconCacheDir, name);
            if (!File.Exists(path))
            {
                try { File.WriteAllBytes(path, binary.Data); } catch { return null; }
            }
            return path;
        }
        if (!string.IsNullOrEmpty(n.IconValue) && Uri.TryCreate(n.IconValue, UriKind.Absolute, out var u) &&
            (u.Scheme == Uri.UriSchemeHttp || u.Scheme == Uri.UriSchemeHttps))
        {
            return u.AbsoluteUri;
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

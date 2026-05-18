using System.Net;

namespace WinGrowl.Core.Gntp.Messages;

public enum NotifyPriority { VeryLow = -2, Low = -1, Normal = 0, High = 1, Emergency = 2 }

public sealed class NotifyMessage
{
    public required string ApplicationName { get; init; }
    public required string NotificationName { get; init; }
    public string? NotificationId { get; init; }
    public required string Title { get; init; }
    public string Text { get; init; } = string.Empty;
    public bool Sticky { get; init; }
    public NotifyPriority Priority { get; init; } = NotifyPriority.Normal;
    public string? IconValue { get; init; }
    public GntpResource? Icon { get; init; }
    public string? CoalescingId { get; init; }
    public string? CallbackContext { get; init; }
    public string? CallbackContextType { get; init; }
    public string? CallbackTarget { get; init; }

    // Client-side TCP endpoint of the inbound NOTIFY. Set by the server,
    // not parsed from GNTP. Lets the App layer resolve the sender's PID
    // (via TcpPidResolver) to disambiguate multiple instances of the
    // same exe — necessary for two Firestorms etc.
    public IPEndPoint? SenderEndPoint { get; init; }

    public static NotifyMessage From(GntpMessage msg, IPEndPoint? senderEndPoint = null)
    {
        if (msg.Type != GntpMessageType.Notify) throw new InvalidOperationException("Expected NOTIFY message.");
        var iconValue = msg.Headers["Notification-Icon"];
        GntpResource? icon = null;
        if (iconValue is not null) msg.TryResolveResource(iconValue, out icon);

        int priority = msg.Headers.GetInt("Notification-Priority", 0);
        if (priority < -2) priority = -2;
        if (priority > 2) priority = 2;

        return new NotifyMessage
        {
            ApplicationName = msg.Headers.Require("Application-Name"),
            NotificationName = msg.Headers.Require("Notification-Name"),
            NotificationId = msg.Headers["Notification-ID"],
            Title = msg.Headers.Require("Notification-Title"),
            Text = msg.Headers["Notification-Text"] ?? string.Empty,
            Sticky = msg.Headers.GetBool("Notification-Sticky"),
            Priority = (NotifyPriority)priority,
            IconValue = iconValue,
            Icon = icon,
            CoalescingId = msg.Headers["Notification-Coalescing-ID"],
            CallbackContext = msg.Headers["Notification-Callback-Context"],
            CallbackContextType = msg.Headers["Notification-Callback-Context-Type"],
            CallbackTarget = msg.Headers["Notification-Callback-Target"],
            SenderEndPoint = senderEndPoint,
        };
    }
}

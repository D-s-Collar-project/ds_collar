using System.Text;

namespace WinGrowl.Core.Gntp;

public static class GntpWriter
{
    public static byte[] WriteResponse(GntpMessage msg)
    {
        var sb = new StringBuilder();
        sb.Append("GNTP/").Append(msg.Version).Append(' ').Append(msg.Type.ToWire()).Append(" NONE\r\n");
        msg.Headers.WriteTo(sb);
        sb.Append("\r\n");
        return Encoding.UTF8.GetBytes(sb.ToString());
    }

    public static GntpMessage Ok(string? originatingType = null, string? notificationId = null)
    {
        var m = new GntpMessage { Type = GntpMessageType.Ok };
        if (originatingType is not null) m.Headers["Response-Action"] = originatingType;
        if (notificationId is not null) m.Headers["Notification-ID"] = notificationId;
        m.Headers["X-Generator"] = "WinGrowl/0.1";
        return m;
    }

    public static GntpMessage Error(GntpErrorCode code, string description, string? originatingType = null)
    {
        var m = new GntpMessage { Type = GntpMessageType.Error };
        if (originatingType is not null) m.Headers["Response-Action"] = originatingType;
        m.Headers["Error-Code"] = ((int)code).ToString();
        m.Headers["Error-Description"] = description;
        m.Headers["X-Generator"] = "WinGrowl/0.1";
        return m;
    }

    public static GntpMessage Callback(string applicationName, string notificationId, string callbackResult, string contextType, string context)
    {
        var m = new GntpMessage { Type = GntpMessageType.Callback };
        m.Headers["Application-Name"] = applicationName;
        m.Headers["Notification-ID"] = notificationId;
        m.Headers["Notification-Callback-Result"] = callbackResult;
        m.Headers["Notification-Callback-Timestamp"] = DateTime.UtcNow.ToString("O");
        m.Headers["Notification-Callback-Context"] = context;
        m.Headers["Notification-Callback-Context-Type"] = contextType;
        m.Headers["X-Generator"] = "WinGrowl/0.1";
        return m;
    }
}

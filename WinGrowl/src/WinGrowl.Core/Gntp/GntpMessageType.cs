namespace WinGrowl.Core.Gntp;

public enum GntpMessageType
{
    Register,
    Notify,
    Subscribe,
    Ok,
    Error,
    Callback,
}

public static class GntpMessageTypeExtensions
{
    public static string ToWire(this GntpMessageType type) => type switch
    {
        GntpMessageType.Register => "REGISTER",
        GntpMessageType.Notify => "NOTIFY",
        GntpMessageType.Subscribe => "SUBSCRIBE",
        GntpMessageType.Ok => "-OK",
        GntpMessageType.Error => "-ERROR",
        GntpMessageType.Callback => "-CALLBACK",
        _ => throw new ArgumentOutOfRangeException(nameof(type)),
    };

    public static bool TryParse(string token, out GntpMessageType type)
    {
        switch (token)
        {
            case "REGISTER": type = GntpMessageType.Register; return true;
            case "NOTIFY": type = GntpMessageType.Notify; return true;
            case "SUBSCRIBE": type = GntpMessageType.Subscribe; return true;
            case "-OK": type = GntpMessageType.Ok; return true;
            case "-ERROR": type = GntpMessageType.Error; return true;
            case "-CALLBACK": type = GntpMessageType.Callback; return true;
            default: type = default; return false;
        }
    }
}

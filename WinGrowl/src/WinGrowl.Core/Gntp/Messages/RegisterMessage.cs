namespace WinGrowl.Core.Gntp.Messages;

public sealed record RegisteredType(
    string Name,
    string DisplayName,
    bool Enabled,
    string? IconValue,
    GntpResource? IconResource);

public sealed class RegisterMessage
{
    public required string ApplicationName { get; init; }
    public string? ApplicationIconValue { get; init; }
    public GntpResource? ApplicationIcon { get; init; }
    public IReadOnlyList<RegisteredType> Types { get; init; } = Array.Empty<RegisteredType>();

    public static RegisterMessage From(GntpMessage msg)
    {
        if (msg.Type != GntpMessageType.Register) throw new InvalidOperationException("Expected REGISTER message.");
        var app = msg.Headers.Require("Application-Name");
        string? appIconValue = msg.Headers["Application-Icon"];
        GntpResource? appIcon = null;
        if (appIconValue is not null) msg.TryResolveResource(appIconValue, out appIcon);

        var types = new List<RegisteredType>();
        foreach (var block in msg.NotificationTypes)
        {
            var name = block.Require("Notification-Name");
            var display = block["Notification-Display-Name"] ?? name;
            var enabled = block.GetBool("Notification-Enabled", true);
            var iconValue = block["Notification-Icon"];
            GntpResource? icon = null;
            if (iconValue is not null) msg.TryResolveResource(iconValue, out icon);
            types.Add(new RegisteredType(name, display, enabled, iconValue, icon));
        }
        return new RegisterMessage
        {
            ApplicationName = app,
            ApplicationIconValue = appIconValue,
            ApplicationIcon = appIcon,
            Types = types,
        };
    }
}

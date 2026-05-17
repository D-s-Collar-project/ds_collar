namespace WinGrowl.Core.Gntp.Messages;

public sealed class SubscribeMessage
{
    public required string SubscriberId { get; init; }
    public required string SubscriberName { get; init; }
    public int Port { get; init; }

    public static SubscribeMessage From(GntpMessage msg)
    {
        if (msg.Type != GntpMessageType.Subscribe) throw new InvalidOperationException("Expected SUBSCRIBE message.");
        return new SubscribeMessage
        {
            SubscriberId = msg.Headers.Require("Subscriber-ID"),
            SubscriberName = msg.Headers.Require("Subscriber-Name"),
            Port = msg.Headers.GetInt("Subscriber-Port"),
        };
    }
}

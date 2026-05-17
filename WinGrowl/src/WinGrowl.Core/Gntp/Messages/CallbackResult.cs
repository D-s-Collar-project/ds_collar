namespace WinGrowl.Core.Gntp.Messages;

public enum CallbackResult { Clicked, Closed, TimedOut }

public static class CallbackResultExtensions
{
    public static string ToWire(this CallbackResult r) => r switch
    {
        CallbackResult.Clicked => "CLICK",
        CallbackResult.Closed => "CLOSE",
        CallbackResult.TimedOut => "TIMEDOUT",
        _ => throw new ArgumentOutOfRangeException(nameof(r)),
    };
}

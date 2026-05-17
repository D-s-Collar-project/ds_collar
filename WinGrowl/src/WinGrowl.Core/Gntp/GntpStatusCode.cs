namespace WinGrowl.Core.Gntp;

public enum GntpErrorCode
{
    Reserved = 100,
    TimedOut = 200,
    NetworkFailure = 201,
    InvalidRequest = 300,
    UnknownProtocol = 301,
    UnknownProtocolVersion = 302,
    RequiredHeaderMissing = 303,
    NotAuthorized = 400,
    UnknownApplication = 401,
    UnknownNotification = 402,
    AlreadyProcessed = 403,
    NotificationDisabled = 404,
    InternalServerError = 500,
}

public sealed class GntpException : Exception
{
    public GntpErrorCode Code { get; }

    public GntpException(GntpErrorCode code, string message) : base(message)
    {
        Code = code;
    }
}

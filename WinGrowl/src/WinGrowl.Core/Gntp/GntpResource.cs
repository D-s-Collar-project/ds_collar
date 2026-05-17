namespace WinGrowl.Core.Gntp;

public sealed class GntpResource
{
    public string Identifier { get; }
    public byte[] Data { get; }

    public GntpResource(string identifier, byte[] data)
    {
        Identifier = identifier;
        Data = data;
    }

    public const string UriScheme = "x-growl-resource://";

    public static bool IsResourceReference(string value, out string identifier)
    {
        if (value.StartsWith(UriScheme, StringComparison.OrdinalIgnoreCase))
        {
            identifier = value.Substring(UriScheme.Length);
            return true;
        }
        identifier = string.Empty;
        return false;
    }
}

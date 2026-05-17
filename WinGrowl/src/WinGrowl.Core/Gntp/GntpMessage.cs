namespace WinGrowl.Core.Gntp;

public sealed class GntpMessage
{
    public string Version { get; set; } = "1.0";
    public GntpMessageType Type { get; set; }
    public GntpHeaders Headers { get; } = new();
    public List<GntpHeaders> NotificationTypes { get; } = new();
    public Dictionary<string, GntpResource> Resources { get; } = new(StringComparer.OrdinalIgnoreCase);

    public bool TryResolveResource(string headerValue, out GntpResource? resource)
    {
        if (GntpResource.IsResourceReference(headerValue, out var id) && Resources.TryGetValue(id, out var r))
        {
            resource = r;
            return true;
        }
        resource = null;
        return false;
    }
}

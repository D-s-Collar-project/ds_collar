using System.Net;
using System.Net.Sockets;
using System.Text;
using WinGrowl.Core.Gntp.Messages;
using WinGrowl.Core.Registration;

namespace WinGrowl.Core.Gntp;

public sealed class GntpServerOptions
{
    public IPEndPoint Endpoint { get; init; } = new(IPAddress.Loopback, 23053);
    public string? Password { get; init; }
    public bool AllowNetworkClients { get; init; }
    public int MaxMessageBytes { get; init; } = 4 * 1024 * 1024;
    public TimeSpan ReadTimeout { get; init; } = TimeSpan.FromSeconds(30);
}

public sealed class GntpServer : IAsyncDisposable
{
    private readonly GntpServerOptions _options;
    private readonly ApplicationRegistry _registry;
    private readonly List<TcpListener> _listeners = new();
    private CancellationTokenSource? _cts;
    private readonly List<Task> _acceptLoops = new();

    public event EventHandler<RegisterMessage>? Registered;
    public event EventHandler<NotifyMessage>? Notification;
    public event EventHandler<SubscribeMessage>? Subscribed;
    public event EventHandler<GntpException>? ProtocolError;
    public event Action<string>? Diagnostic;

    private void Diag(string s) => Diagnostic?.Invoke(s);

    // Diagnostic-only: emit a hex+ASCII dump of a rejected payload so we
    // can see exactly what the client sent. Writes through Diag so it
    // lands in the normal log stream. Hex view is 16 bytes per line,
    // CR/LF rendered as ⏎/⏎ marks in the ASCII column for legibility.
    private void DumpRawForDiagnosis(byte[] raw)
    {
        Diag($"raw-dump: {raw.Length} bytes follow");
        var sb = new StringBuilder();
        for (int off = 0; off < raw.Length; off += 16)
        {
            sb.Clear();
            sb.Append($"  {off:x4}: ");
            int end = Math.Min(off + 16, raw.Length);
            for (int i = off; i < end; i++) sb.Append(raw[i].ToString("x2")).Append(' ');
            for (int pad = end; pad < off + 16; pad++) sb.Append("   ");
            sb.Append(' ');
            for (int i = off; i < end; i++)
            {
                byte b = raw[i];
                if (b == 0x0d) sb.Append("\\r");
                else if (b == 0x0a) sb.Append("\\n");
                else if (b >= 0x20 && b < 0x7f) sb.Append((char)b);
                else sb.Append('.');
            }
            Diag(sb.ToString());
        }
    }

    public GntpServer(GntpServerOptions options, ApplicationRegistry registry)
    {
        _options = options;
        _registry = registry;
    }

    public Task StartAsync()
    {
        if (_listeners.Count > 0) throw new InvalidOperationException("Already started.");
        var port = _options.Endpoint.Port;
        var v4Addr = _options.AllowNetworkClients ? IPAddress.Any : IPAddress.Loopback;
        var v6Addr = _options.AllowNetworkClients ? IPAddress.IPv6Any : IPAddress.IPv6Loopback;

        var v4 = new TcpListener(new IPEndPoint(v4Addr, port));
        v4.Start();
        _listeners.Add(v4);

        if (Socket.OSSupportsIPv6)
        {
            try
            {
                var v6 = new TcpListener(new IPEndPoint(v6Addr, port));
                v6.Server.SetSocketOption(SocketOptionLevel.IPv6, SocketOptionName.IPv6Only, 1);
                v6.Start();
                _listeners.Add(v6);
            }
            catch (SocketException) { }
        }

        _cts = new CancellationTokenSource();
        foreach (var l in _listeners)
        {
            var listener = l;
            _acceptLoops.Add(Task.Run(() => AcceptLoopAsync(listener, _cts.Token)));
        }
        return Task.CompletedTask;
    }

    private async Task AcceptLoopAsync(TcpListener listener, CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            TcpClient client;
            try { client = await listener.AcceptTcpClientAsync(ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { break; }
            catch (ObjectDisposedException) { break; }
            _ = Task.Run(() => HandleClientAsync(client, ct), ct);
        }
    }

    private async Task HandleClientAsync(TcpClient client, CancellationToken ct)
    {
        var remote = client.Client.RemoteEndPoint?.ToString() ?? "?";
        Diag($"accept {remote}");
        using (client)
        {
            try
            {
                if (!_options.AllowNetworkClients && client.Client.RemoteEndPoint is IPEndPoint ep && !IPAddress.IsLoopback(ep.Address))
                {
                    Diag($"reject {remote}: non-loopback");
                    return;
                }
                client.ReceiveTimeout = (int)_options.ReadTimeout.TotalMilliseconds;
                using var stream = client.GetStream();
                var raw = await ReadFullMessageAsync(stream, _options.MaxMessageBytes, ct).ConfigureAwait(false);
                Diag($"read {remote}: {raw.Length} bytes");
                if (raw.Length == 0) return;

                var parser = new GntpParser { Password = _options.Password };
                GntpMessage parsed;
                try
                {
                    parsed = parser.Parse(raw);
                    Diag($"parsed {remote}: {parsed.Type.ToWire()}");
                }
                catch (GntpException pex)
                {
                    Diag($"parse-error {remote}: {pex.Code} {pex.Message}");
                    DumpRawForDiagnosis(raw);
                    ProtocolError?.Invoke(this, pex);
                    var err = GntpWriter.WriteResponse(GntpWriter.Error(pex.Code, pex.Message));
                    await stream.WriteAsync(err, ct).ConfigureAwait(false);
                    return;
                }

                await DispatchAsync(stream, parsed, ct).ConfigureAwait(false);
            }
            catch (IOException ex) { Diag($"io-error {remote}: {ex.Message}"); }
            catch (OperationCanceledException) { }
            catch (Exception ex) { Diag($"unhandled {remote}: {ex.GetType().Name} {ex.Message}"); }
        }
    }

    private async Task DispatchAsync(NetworkStream stream, GntpMessage msg, CancellationToken ct)
    {
        try
        {
            switch (msg.Type)
            {
                case GntpMessageType.Register:
                {
                    var rm = RegisterMessage.From(msg);
                    _registry.Register(rm);
                    Registered?.Invoke(this, rm);
                    var ok = GntpWriter.WriteResponse(GntpWriter.Ok("REGISTER"));
                    await stream.WriteAsync(ok, ct).ConfigureAwait(false);
                    break;
                }
                case GntpMessageType.Notify:
                {
                    var nm = NotifyMessage.From(msg);
                    if (!_registry.TryGet(nm.ApplicationName, out _))
                    {
                        var e = GntpWriter.WriteResponse(GntpWriter.Error(GntpErrorCode.UnknownApplication, $"Application '{nm.ApplicationName}' not registered.", "NOTIFY"));
                        await stream.WriteAsync(e, ct).ConfigureAwait(false);
                        return;
                    }
                    // Auto-register the notification type on first NOTIFY
                    // (Growl-for-Windows behavior). Firestorm and other
                    // clients declare Notifications-Count in REGISTER but
                    // ship zero type blocks, expecting types to be added
                    // implicitly as they fire. EnsureType is idempotent
                    // for already-known names. After this call we know
                    // IsEnabled will return true (auto-added defaults to
                    // enabled), unless the user has explicitly disabled
                    // it via the tray UI in the meantime.
                    _registry.EnsureType(nm.ApplicationName, nm.NotificationName);
                    if (!_registry.IsEnabled(nm.ApplicationName, nm.NotificationName))
                    {
                        var e = GntpWriter.WriteResponse(GntpWriter.Error(GntpErrorCode.NotificationDisabled, $"Notification '{nm.NotificationName}' is disabled.", "NOTIFY"));
                        await stream.WriteAsync(e, ct).ConfigureAwait(false);
                        return;
                    }
                    Notification?.Invoke(this, nm);
                    var ok = GntpWriter.WriteResponse(GntpWriter.Ok("NOTIFY", nm.NotificationId));
                    await stream.WriteAsync(ok, ct).ConfigureAwait(false);
                    break;
                }
                case GntpMessageType.Subscribe:
                {
                    var sm = SubscribeMessage.From(msg);
                    Subscribed?.Invoke(this, sm);
                    var ok = GntpWriter.Ok("SUBSCRIBE");
                    ok.Headers["Subscription-TTL"] = "300";
                    await stream.WriteAsync(GntpWriter.WriteResponse(ok), ct).ConfigureAwait(false);
                    break;
                }
                default:
                {
                    var e = GntpWriter.WriteResponse(GntpWriter.Error(GntpErrorCode.InvalidRequest, "Unsupported message type."));
                    await stream.WriteAsync(e, ct).ConfigureAwait(false);
                    break;
                }
            }
        }
        catch (GntpException pex)
        {
            ProtocolError?.Invoke(this, pex);
            var e = GntpWriter.WriteResponse(GntpWriter.Error(pex.Code, pex.Message));
            await stream.WriteAsync(e, ct).ConfigureAwait(false);
        }
    }

    // Structural GNTP message reader. The protocol has no top-level
    // content-length, so the receiver has to determine completion from
    // the body's shape:
    //
    //   * Main headers, terminated by CRLFCRLF.
    //   * For REGISTER, Notifications-Count type blocks follow, each
    //     terminated by CRLFCRLF.
    //   * Optional resource sections: each is a small header block
    //     (Identifier:, Length:) terminated by CRLFCRLF, then exactly
    //     Length raw bytes of binary, then an optional trailing CRLF.
    //
    // After main headers complete we drop the socket ReadTimeout to a
    // short quiescence window. That lets us cope with real-world clients
    // (Firestorm's GNTP impl in particular) that declare Notifications-
    // Count but ship zero type blocks: we wait briefly for the blocks
    // that never come, give up on the next read's timeout, and return
    // the partial message. The parser tolerates zero type blocks per
    // the auto-register-on-NOTIFY contract.
    private static async Task<byte[]> ReadFullMessageAsync(NetworkStream stream, int maxBytes, CancellationToken ct)
    {
        using var ms = new MemoryStream();
        var buf = new byte[8192];

        int headersEnd = -1;          // offset of main-headers CRLFCRLF
        int expectedTypeBlocks = 0;   // Notifications-Count (REGISTER) or 0
        int typeBlocksEnd = -1;       // cursor past last type block CRLFCRLF
        int messageEnd = -1;          // cursor past last resource section

        // NetworkStream.ReadAsync(buf, ct) ignores the stream's
        // ReadTimeout property — the cancellation token is the only
        // timeout mechanism that works with the async overload. We
        // build per-read linked CTSes so we can apply a brief
        // quiescence cap *after* main headers are in, while still
        // honoring the outer caller's cancellation.
        while (true)
        {
            int n;
            CancellationTokenSource? quietCts = null;
            CancellationToken effective = ct;
            if (headersEnd >= 0)
            {
                quietCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                quietCts.CancelAfter(TimeSpan.FromMilliseconds(250));
                effective = quietCts.Token;
            }
            try
            {
                try
                {
                    n = await stream.ReadAsync(buf, effective).ConfigureAwait(false);
                }
                catch (OperationCanceledException) when (headersEnd >= 0 && !ct.IsCancellationRequested)
                {
                    // 250 ms passed with no more bytes after main
                    // headers — assume the sender is done. Real-world
                    // pattern: Firestorm declares Notifications-Count
                    // but ships zero inline type blocks, expecting
                    // server-side auto-register on first NOTIFY.
                    break;
                }
            }
            finally
            {
                quietCts?.Dispose();
            }
            if (n == 0) break;
            ms.Write(buf, 0, n);
            if (ms.Length > maxBytes) throw new GntpException(GntpErrorCode.InvalidRequest, "Message exceeds maximum size.");

            var data = ms.GetBuffer();
            int len = (int)ms.Length;

            // Phase 1: main headers
            if (headersEnd < 0)
            {
                headersEnd = FindCrLfCrLf(data, 0, len);
                if (headersEnd < 0) continue;
                expectedTypeBlocks = ParseNotificationsCountIfRegister(data, 0, headersEnd);
            }

            // Phase 2: notification-type blocks (REGISTER)
            if (typeBlocksEnd < 0)
            {
                int cursor = headersEnd + 4;
                int seen = 0;
                while (seen < expectedTypeBlocks)
                {
                    int next = FindCrLfCrLf(data, cursor, len);
                    if (next < 0) break;
                    cursor = next + 4;
                    seen++;
                }
                if (seen < expectedTypeBlocks) continue;
                typeBlocksEnd = cursor;
            }

            // Phase 3: resource sections (each: <headers>\r\n\r\n<Length bytes>[\r\n])
            if (messageEnd < 0)
            {
                int cursor = typeBlocksEnd;
                bool resourcesComplete = true;
                while (cursor < len)
                {
                    int sep = FindCrLfCrLf(data, cursor, len);
                    if (sep < 0)
                    {
                        resourcesComplete = false;
                        break;
                    }
                    int length = ParseResourceLength(data, cursor, sep);
                    if (length <= 0)
                    {
                        // No Length declared — treat as a trailing
                        // empty section that terminates the message.
                        cursor = sep + 4;
                        break;
                    }
                    int dataStart = sep + 4;
                    int dataEnd = dataStart + length;
                    if (dataEnd > len)
                    {
                        resourcesComplete = false;
                        break;
                    }
                    cursor = dataEnd;
                    // Optional trailing CRLF after binary
                    if (cursor + 2 <= len && data[cursor] == 0x0d && data[cursor + 1] == 0x0a)
                    {
                        cursor += 2;
                    }
                }
                if (!resourcesComplete) continue;
                messageEnd = cursor;
            }

            if (len >= messageEnd)
            {
                var trimmed = new byte[messageEnd];
                Buffer.BlockCopy(data, 0, trimmed, 0, messageEnd);
                return trimmed;
            }
        }

        // Reached on EOF / timeout before structural completion — return
        // whatever we accumulated and let the parser do its best.
        return ms.ToArray();
    }

    private static int FindCrLfCrLf(byte[] data, int start, int length)
    {
        for (int i = start; i <= length - 4; i++)
        {
            if (data[i] == 0x0d && data[i + 1] == 0x0a && data[i + 2] == 0x0d && data[i + 3] == 0x0a)
                return i;
        }
        return -1;
    }

    // Parse Notifications-Count out of the main-headers section, but
    // only if the headline declares this is a REGISTER message. NOTIFY
    // and SUBSCRIBE never have type blocks, so we return 0 and the type-
    // block phase becomes a no-op.
    private static int ParseNotificationsCountIfRegister(byte[] data, int start, int end)
    {
        var text = Encoding.UTF8.GetString(data, start, end - start);
        int firstCrLf = text.IndexOf("\r\n", StringComparison.Ordinal);
        if (firstCrLf < 0) return 0;
        var headline = text.Substring(0, firstCrLf);
        var parts = headline.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 2 || !parts[1].Equals("REGISTER", StringComparison.OrdinalIgnoreCase)) return 0;
        var headersText = text.Substring(firstCrLf + 2);
        foreach (var line in headersText.Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries))
        {
            if (line.StartsWith("Notifications-Count:", StringComparison.OrdinalIgnoreCase))
            {
                if (int.TryParse(line.AsSpan(20).Trim(), out var count)) return count;
            }
        }
        return 0;
    }

    // Pull Length out of a resource-section header block.
    private static int ParseResourceLength(byte[] data, int start, int end)
    {
        var text = Encoding.UTF8.GetString(data, start, end - start);
        foreach (var line in text.Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries))
        {
            if (line.StartsWith("Length:", StringComparison.OrdinalIgnoreCase))
            {
                if (int.TryParse(line.AsSpan(7).Trim(), out var v)) return v;
            }
        }
        return 0;
    }

    public async ValueTask DisposeAsync()
    {
        try { _cts?.Cancel(); } catch { }
        foreach (var l in _listeners) { try { l.Stop(); } catch { } }
        foreach (var t in _acceptLoops) { try { await t.ConfigureAwait(false); } catch { } }
        _cts?.Dispose();
    }
}

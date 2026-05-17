using System.Globalization;
using System.Text;
using WinGrowl.Core.Gntp.Crypto;

namespace WinGrowl.Core.Gntp;

public sealed class GntpParser
{
    private static readonly byte[] CrLfCrLf = new byte[] { 0x0d, 0x0a, 0x0d, 0x0a };
    private static readonly byte[] CrLf = new byte[] { 0x0d, 0x0a };

    public string? Password { get; init; }

    public GntpMessage Parse(byte[] raw)
    {
        var headlineEnd = IndexOf(raw, CrLf, 0);
        if (headlineEnd < 0) throw new GntpException(GntpErrorCode.InvalidRequest, "Missing headline terminator.");
        var headline = Encoding.UTF8.GetString(raw, 0, headlineEnd);
        var msg = new GntpMessage();
        var (encryption, iv, keyHashAlgo, keyHashBytes, salt) = ParseHeadline(headline, msg);

        byte[] decrypted;
        int bodyStart = headlineEnd + 2;

        if (encryption == EncryptionAlgorithm.None)
        {
            decrypted = SliceFromTo(raw, bodyStart, raw.Length);
        }
        else
        {
            if (Password is null) throw new GntpException(GntpErrorCode.NotAuthorized, "Encrypted message received but no password configured.");
            if (!GntpCrypto.VerifyKeyHash(Password, keyHashAlgo, keyHashBytes!, salt!, out var key))
                throw new GntpException(GntpErrorCode.NotAuthorized, "Key hash mismatch.");

            var encryptedBlobEnd = IndexOf(raw, CrLfCrLf, bodyStart);
            if (encryptedBlobEnd < 0) encryptedBlobEnd = raw.Length;
            var ct = SliceFromTo(raw, bodyStart, encryptedBlobEnd);
            var pt = GntpCrypto.Decrypt(encryption, ct, key, iv!);

            var trailing = encryptedBlobEnd < raw.Length ? SliceFromTo(raw, encryptedBlobEnd, raw.Length) : Array.Empty<byte>();
            decrypted = new byte[pt.Length + trailing.Length];
            Buffer.BlockCopy(pt, 0, decrypted, 0, pt.Length);
            if (trailing.Length > 0) Buffer.BlockCopy(trailing, 0, decrypted, pt.Length, trailing.Length);
        }

        ParseBody(decrypted, msg, keyHashAlgo, Password);
        return msg;
    }

    private static (EncryptionAlgorithm enc, byte[]? iv, KeyHashAlgorithm hash, byte[]? keyHash, byte[]? salt) ParseHeadline(string headline, GntpMessage msg)
    {
        var parts = headline.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length < 3) throw new GntpException(GntpErrorCode.InvalidRequest, "Malformed headline.");
        var proto = parts[0];
        var slash = proto.IndexOf('/');
        if (slash < 0 || !proto.StartsWith("GNTP", StringComparison.Ordinal))
            throw new GntpException(GntpErrorCode.UnknownProtocol, "Unknown protocol identifier.");
        msg.Version = proto.Substring(slash + 1);
        if (msg.Version != "1.0") throw new GntpException(GntpErrorCode.UnknownProtocolVersion, $"Unsupported version {msg.Version}.");

        if (!GntpMessageTypeExtensions.TryParse(parts[1], out var mt))
            throw new GntpException(GntpErrorCode.InvalidRequest, $"Unknown message type {parts[1]}.");
        msg.Type = mt;

        var encField = parts[2];
        EncryptionAlgorithm enc;
        byte[]? iv = null;
        var colon = encField.IndexOf(':');
        if (colon >= 0)
        {
            if (!EncryptionAlgorithmExtensions.TryParse(encField.Substring(0, colon), out enc))
                throw new GntpException(GntpErrorCode.InvalidRequest, "Unknown encryption algorithm.");
            iv = GntpCrypto.HexDecode(encField.Substring(colon + 1));
        }
        else
        {
            if (!EncryptionAlgorithmExtensions.TryParse(encField, out enc))
                throw new GntpException(GntpErrorCode.InvalidRequest, "Unknown encryption algorithm.");
        }

        KeyHashAlgorithm hash = KeyHashAlgorithm.None;
        byte[]? keyHash = null;
        byte[]? salt = null;

        if (parts.Length >= 4)
        {
            var keyField = parts[3];
            var k1 = keyField.IndexOf(':');
            var k2 = keyField.IndexOf('.', k1 + 1);
            if (k1 < 0 || k2 < 0) throw new GntpException(GntpErrorCode.InvalidRequest, "Malformed key hash field.");
            if (!KeyHashAlgorithmExtensions.TryParse(keyField.Substring(0, k1), out hash))
                throw new GntpException(GntpErrorCode.InvalidRequest, "Unknown key hash algorithm.");
            keyHash = GntpCrypto.HexDecode(keyField.Substring(k1 + 1, k2 - k1 - 1));
            salt = GntpCrypto.HexDecode(keyField.Substring(k2 + 1));
        }

        if (enc != EncryptionAlgorithm.None && (keyHash is null || salt is null))
            throw new GntpException(GntpErrorCode.NotAuthorized, "Encryption requires key hash + salt.");

        return (enc, iv, hash, keyHash, salt);
    }

    private static void ParseBody(byte[] body, GntpMessage msg, KeyHashAlgorithm _, string? __)
    {
        var sectionEnd = IndexOf(body, CrLfCrLf, 0);
        if (sectionEnd < 0) sectionEnd = body.Length;

        var headerText = Encoding.UTF8.GetString(body, 0, sectionEnd);
        var headerLines = headerText.Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries);

        int notifCount = 0;
        foreach (var line in headerLines)
        {
            var (name, value) = SplitHeader(line);
            if (name.StartsWith("Notification-", StringComparison.OrdinalIgnoreCase) &&
                msg.Type == GntpMessageType.Register && IsTypeBlockHeader(name))
            {
                continue;
            }
            msg.Headers[name] = value;
            if (name.Equals("Notifications-Count", StringComparison.OrdinalIgnoreCase))
            {
                int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out notifCount);
            }
        }

        int cursor = sectionEnd + 4;

        if (msg.Type == GntpMessageType.Register && notifCount > 0)
        {
            for (int i = 0; i < notifCount; i++)
            {
                // Notifications-Count is advisory: clients like Firestorm
                // announce a count but ship zero (or fewer than declared)
                // type blocks in the REGISTER body, expecting the server
                // to auto-register on first NOTIFY (the canonical Growl-
                // for-Windows behavior). Treat both running off the end
                // of the body AND not finding the next CRLFCRLF as
                // "no more blocks supplied" — break cleanly and let the
                // registry hold whatever we got, including zero blocks.
                if (cursor >= body.Length) break;
                var endOfBlock = IndexOf(body, CrLfCrLf, cursor);
                int blockEnd;
                int nextCursor;
                if (endOfBlock < 0)
                {
                    // Last block may omit the trailing CRLFCRLF — accept
                    // the remainder of the body as that final block.
                    blockEnd = body.Length;
                    nextCursor = body.Length;
                }
                else
                {
                    blockEnd = endOfBlock;
                    nextCursor = endOfBlock + 4;
                }
                var blockText = Encoding.UTF8.GetString(body, cursor, blockEnd - cursor);
                var typeHeaders = new GntpHeaders();
                foreach (var line in blockText.Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries))
                {
                    var (name, value) = SplitHeader(line);
                    typeHeaders[name] = value;
                }
                msg.NotificationTypes.Add(typeHeaders);
                cursor = nextCursor;
            }
        }

        while (cursor < body.Length)
        {
            var endOfBlock = IndexOf(body, CrLfCrLf, cursor);
            if (endOfBlock < 0) break;
            var blockText = Encoding.UTF8.GetString(body, cursor, endOfBlock - cursor);
            string? identifier = null;
            int length = 0;
            foreach (var line in blockText.Split(new[] { "\r\n" }, StringSplitOptions.RemoveEmptyEntries))
            {
                var (name, value) = SplitHeader(line);
                if (name.Equals("Identifier", StringComparison.OrdinalIgnoreCase)) identifier = value;
                else if (name.Equals("Length", StringComparison.OrdinalIgnoreCase))
                    int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out length);
            }
            cursor = endOfBlock + 4;
            if (identifier is null || length <= 0) break;
            if (cursor + length > body.Length) throw new GntpException(GntpErrorCode.InvalidRequest, "Resource length exceeds payload.");
            var data = new byte[length];
            Buffer.BlockCopy(body, cursor, data, 0, length);
            msg.Resources[identifier] = new GntpResource(identifier, data);
            cursor += length;
            while (cursor < body.Length && (body[cursor] == 0x0d || body[cursor] == 0x0a)) cursor++;
        }
    }

    private static bool IsTypeBlockHeader(string name) =>
        name.Equals("Notification-Name", StringComparison.OrdinalIgnoreCase)
        || name.Equals("Notification-Display-Name", StringComparison.OrdinalIgnoreCase)
        || name.Equals("Notification-Enabled", StringComparison.OrdinalIgnoreCase)
        || name.Equals("Notification-Icon", StringComparison.OrdinalIgnoreCase);

    private static (string name, string value) SplitHeader(string line)
    {
        var colon = line.IndexOf(':');
        if (colon < 0) throw new GntpException(GntpErrorCode.InvalidRequest, $"Malformed header line: {line}");
        return (line.Substring(0, colon).Trim(), line.Substring(colon + 1).Trim());
    }

    private static int IndexOf(byte[] hay, byte[] needle, int start)
    {
        for (int i = start; i <= hay.Length - needle.Length; i++)
        {
            bool match = true;
            for (int j = 0; j < needle.Length; j++)
            {
                if (hay[i + j] != needle[j]) { match = false; break; }
            }
            if (match) return i;
        }
        return -1;
    }

    private static byte[] SliceFromTo(byte[] src, int from, int to)
    {
        var len = to - from;
        var dst = new byte[len];
        if (len > 0) Buffer.BlockCopy(src, from, dst, 0, len);
        return dst;
    }
}

using System.Security.Cryptography;

namespace WinGrowl.Core.Gntp.Crypto;

public enum KeyHashAlgorithm
{
    None,
    Md5,
    Sha1,
    Sha256,
    Sha512,
}

public static class KeyHashAlgorithmExtensions
{
    public static string ToWire(this KeyHashAlgorithm h) => h switch
    {
        KeyHashAlgorithm.Md5 => "MD5",
        KeyHashAlgorithm.Sha1 => "SHA1",
        KeyHashAlgorithm.Sha256 => "SHA256",
        KeyHashAlgorithm.Sha512 => "SHA512",
        KeyHashAlgorithm.None => "NONE",
        _ => throw new ArgumentOutOfRangeException(nameof(h)),
    };

    public static bool TryParse(string token, out KeyHashAlgorithm h)
    {
        switch (token.ToUpperInvariant())
        {
            case "MD5": h = KeyHashAlgorithm.Md5; return true;
            case "SHA1": h = KeyHashAlgorithm.Sha1; return true;
            case "SHA256": h = KeyHashAlgorithm.Sha256; return true;
            case "SHA512": h = KeyHashAlgorithm.Sha512; return true;
            case "NONE": h = KeyHashAlgorithm.None; return true;
            default: h = default; return false;
        }
    }

    public static byte[] Compute(this KeyHashAlgorithm h, byte[] data) => h switch
    {
        KeyHashAlgorithm.Md5 => MD5.HashData(data),
        KeyHashAlgorithm.Sha1 => SHA1.HashData(data),
        KeyHashAlgorithm.Sha256 => SHA256.HashData(data),
        KeyHashAlgorithm.Sha512 => SHA512.HashData(data),
        _ => throw new InvalidOperationException("No hash algorithm specified."),
    };
}

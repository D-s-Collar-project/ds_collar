namespace WinGrowl.Core.Gntp.Crypto;

public enum EncryptionAlgorithm
{
    None,
    Aes,
    Des,
    TripleDes,
}

public static class EncryptionAlgorithmExtensions
{
    public static string ToWire(this EncryptionAlgorithm a) => a switch
    {
        EncryptionAlgorithm.None => "NONE",
        EncryptionAlgorithm.Aes => "AES",
        EncryptionAlgorithm.Des => "DES",
        EncryptionAlgorithm.TripleDes => "3DES",
        _ => throw new ArgumentOutOfRangeException(nameof(a)),
    };

    public static bool TryParse(string token, out EncryptionAlgorithm a)
    {
        switch (token.ToUpperInvariant())
        {
            case "NONE": a = EncryptionAlgorithm.None; return true;
            case "AES": a = EncryptionAlgorithm.Aes; return true;
            case "DES": a = EncryptionAlgorithm.Des; return true;
            case "3DES":
            case "TRIPLEDES": a = EncryptionAlgorithm.TripleDes; return true;
            default: a = default; return false;
        }
    }

    public static int KeyByteSize(this EncryptionAlgorithm a) => a switch
    {
        EncryptionAlgorithm.Aes => 24,        // AES-192
        EncryptionAlgorithm.Des => 8,
        EncryptionAlgorithm.TripleDes => 24,
        EncryptionAlgorithm.None => 0,
        _ => 0,
    };

    public static int BlockByteSize(this EncryptionAlgorithm a) => a switch
    {
        EncryptionAlgorithm.Aes => 16,
        EncryptionAlgorithm.Des => 8,
        EncryptionAlgorithm.TripleDes => 8,
        EncryptionAlgorithm.None => 0,
        _ => 0,
    };
}

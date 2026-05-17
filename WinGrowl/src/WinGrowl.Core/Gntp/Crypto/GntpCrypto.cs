using System.Security.Cryptography;
using System.Text;

namespace WinGrowl.Core.Gntp.Crypto;

public readonly record struct DerivedKey(byte[] Key, byte[] KeyHash, byte[] Salt);

public static class GntpCrypto
{
    public static byte[] HexDecode(string hex)
    {
        if (hex.Length % 2 != 0) throw new FormatException("Hex string must have even length.");
        var bytes = new byte[hex.Length / 2];
        for (int i = 0; i < bytes.Length; i++)
        {
            bytes[i] = Convert.ToByte(hex.Substring(i * 2, 2), 16);
        }
        return bytes;
    }

    public static string HexEncode(byte[] bytes)
    {
        var sb = new StringBuilder(bytes.Length * 2);
        foreach (var b in bytes) sb.Append(b.ToString("x2"));
        return sb.ToString();
    }

    public static byte[] RandomBytes(int length)
    {
        var b = new byte[length];
        RandomNumberGenerator.Fill(b);
        return b;
    }

    public static DerivedKey DeriveKey(string password, KeyHashAlgorithm hash, byte[]? salt = null)
    {
        salt ??= RandomBytes(16);
        var pwBytes = Encoding.UTF8.GetBytes(password);
        var keyBasis = new byte[pwBytes.Length + salt.Length];
        Buffer.BlockCopy(pwBytes, 0, keyBasis, 0, pwBytes.Length);
        Buffer.BlockCopy(salt, 0, keyBasis, pwBytes.Length, salt.Length);
        var key = hash.Compute(keyBasis);
        var keyHash = hash.Compute(key);
        return new DerivedKey(key, keyHash, salt);
    }

    public static bool VerifyKeyHash(string password, KeyHashAlgorithm hash, byte[] expectedKeyHash, byte[] salt, out byte[] derivedKey)
    {
        var d = DeriveKey(password, hash, salt);
        derivedKey = d.Key;
        return CryptographicOperations.FixedTimeEquals(d.KeyHash, expectedKeyHash);
    }

    public static byte[] Decrypt(EncryptionAlgorithm alg, byte[] ciphertext, byte[] key, byte[] iv)
    {
        return alg switch
        {
            EncryptionAlgorithm.Aes => DecryptAes(ciphertext, key, iv),
            EncryptionAlgorithm.Des => DecryptDes(ciphertext, key, iv),
            EncryptionAlgorithm.TripleDes => DecryptTripleDes(ciphertext, key, iv),
            EncryptionAlgorithm.None => ciphertext,
            _ => throw new ArgumentOutOfRangeException(nameof(alg)),
        };
    }

    public static byte[] Encrypt(EncryptionAlgorithm alg, byte[] plaintext, byte[] key, out byte[] iv)
    {
        iv = Array.Empty<byte>();
        return alg switch
        {
            EncryptionAlgorithm.Aes => EncryptAes(plaintext, key, out iv),
            EncryptionAlgorithm.Des => EncryptDes(plaintext, key, out iv),
            EncryptionAlgorithm.TripleDes => EncryptTripleDes(plaintext, key, out iv),
            EncryptionAlgorithm.None => plaintext,
            _ => throw new ArgumentOutOfRangeException(nameof(alg)),
        };
    }

    private static byte[] TruncatedKey(byte[] key, int size)
    {
        if (key.Length == size) return key;
        if (key.Length < size) throw new CryptographicException($"Hash output too small for cipher key (need {size}, got {key.Length}).");
        var k = new byte[size];
        Buffer.BlockCopy(key, 0, k, 0, size);
        return k;
    }

    private static byte[] DecryptAes(byte[] ct, byte[] key, byte[] iv)
    {
        using var aes = Aes.Create();
        aes.Mode = CipherMode.CBC;
        aes.Padding = PaddingMode.PKCS7;
        aes.Key = TruncatedKey(key, 24);
        aes.IV = iv;
        using var dec = aes.CreateDecryptor();
        return dec.TransformFinalBlock(ct, 0, ct.Length);
    }

    private static byte[] EncryptAes(byte[] pt, byte[] key, out byte[] iv)
    {
        using var aes = Aes.Create();
        aes.Mode = CipherMode.CBC;
        aes.Padding = PaddingMode.PKCS7;
        aes.Key = TruncatedKey(key, 24);
        aes.GenerateIV();
        iv = aes.IV;
        using var enc = aes.CreateEncryptor();
        return enc.TransformFinalBlock(pt, 0, pt.Length);
    }

    private static byte[] DecryptDes(byte[] ct, byte[] key, byte[] iv)
    {
        using var des = DES.Create();
        des.Mode = CipherMode.CBC;
        des.Padding = PaddingMode.PKCS7;
        des.Key = TruncatedKey(key, 8);
        des.IV = iv;
        using var dec = des.CreateDecryptor();
        return dec.TransformFinalBlock(ct, 0, ct.Length);
    }

    private static byte[] EncryptDes(byte[] pt, byte[] key, out byte[] iv)
    {
        using var des = DES.Create();
        des.Mode = CipherMode.CBC;
        des.Padding = PaddingMode.PKCS7;
        des.Key = TruncatedKey(key, 8);
        des.GenerateIV();
        iv = des.IV;
        using var enc = des.CreateEncryptor();
        return enc.TransformFinalBlock(pt, 0, pt.Length);
    }

    private static byte[] DecryptTripleDes(byte[] ct, byte[] key, byte[] iv)
    {
        using var tdes = TripleDES.Create();
        tdes.Mode = CipherMode.CBC;
        tdes.Padding = PaddingMode.PKCS7;
        tdes.Key = TruncatedKey(key, 24);
        tdes.IV = iv;
        using var dec = tdes.CreateDecryptor();
        return dec.TransformFinalBlock(ct, 0, ct.Length);
    }

    private static byte[] EncryptTripleDes(byte[] pt, byte[] key, out byte[] iv)
    {
        using var tdes = TripleDES.Create();
        tdes.Mode = CipherMode.CBC;
        tdes.Padding = PaddingMode.PKCS7;
        tdes.Key = TruncatedKey(key, 24);
        tdes.GenerateIV();
        iv = tdes.IV;
        using var enc = tdes.CreateEncryptor();
        return enc.TransformFinalBlock(pt, 0, pt.Length);
    }
}

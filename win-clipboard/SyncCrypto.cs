using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ClipShelfWin;

/// iPhone 用 Web アプリ（clip-send/index.html の SYNC-BEGIN〜END）・Mac のクリップ棚（SyncCrypto.swift）と同じ暗号の取り決め。
/// 固定の値で、ほかの実装と同じ結果になることをテストしている（win-clipboard.Tests）。
///
///   秘密 K（32バイト）→ HKDF-SHA256（salt = "clipshelf-v1"）で
///     部屋ID = HKDF(info = "clipshelf-v1 room", 16バイト) の base64url（22文字）
///     暗号鍵 = HKDF(info = "clipshelf-v1 enc", 32バイト) を AES-256-GCM に使う
///   送るデータ   = [0x01][nonce 12バイト][AES-GCM の暗号文＋タグ16バイト（追加認証データ = "clipshelf-v1"）]
///   暗号化する中身 = [メタ情報の長さ 4バイト（ビッグエンディアン）][メタ情報 JSON][本体]
///   高速モード（iPhone のショートカットから直接送られたもの）= [0x02][使い捨ての公開鍵 65バイト][nonce 12バイト][暗号文＋タグ]
///     ECDH P-256 → HKDF-SHA256（salt = "clipshelf-v1", info = "clipshelf-v1 quick"）→ AES-256-GCM
public static class SyncCrypto
{
    static readonly byte[] Tag = Encoding.UTF8.GetBytes("clipshelf-v1");

    public sealed record Keys(string Room, byte[] Key);

    /// Kind は "text" か "image"。Body は、テキストなら UTF-8、画像ならファイルの中身
    public sealed record Opened(string Kind, string Name, string Mime, byte[] Body);

    // ---- base64url ----

    public static string Base64Url(byte[] data) =>
        Convert.ToBase64String(data).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    /// base64url（普通の base64 も可）→ バイト列。読めなければ null
    public static byte[]? FromBase64(string s)
    {
        try
        {
            s = s.Replace('-', '+').Replace('_', '/');
            while (s.Length % 4 != 0) s += "=";
            return Convert.FromBase64String(s);
        }
        catch (FormatException)
        {
            return null;
        }
    }

    // ---- 鍵 ----

    public static string NewSecret() => Base64Url(RandomNumberGenerator.GetBytes(32));

    public static Keys Derive(string secret)
    {
        var raw = FromBase64(secret);
        if (raw is null || raw.Length != 32) throw new ArgumentException("秘密の長さが正しくありません");
        byte[] Bits(string info, int n) =>
            HKDF.DeriveKey(HashAlgorithmName.SHA256, raw, n, salt: Tag, info: Encoding.UTF8.GetBytes("clipshelf-v1 " + info));
        return new Keys(Base64Url(Bits("room", 16)), Bits("enc", 32));
    }

    // ---- 暗号化・復号 ----

    /// nonce はテスト用（普通は省略して、毎回ランダムにする）
    public static byte[] Seal(Keys keys, byte[] meta, byte[] body, byte[]? nonce = null)
    {
        var plain = new byte[4 + meta.Length + body.Length];
        BinaryPrimitives.WriteUInt32BigEndian(plain, (uint)meta.Length);
        meta.CopyTo(plain, 4);
        body.CopyTo(plain, 4 + meta.Length);

        nonce ??= RandomNumberGenerator.GetBytes(12);
        var cipher = new byte[plain.Length];
        var tag = new byte[16];
        using (var aes = new AesGcm(keys.Key, 16)) aes.Encrypt(nonce, plain, cipher, tag, Tag);

        var output = new byte[1 + 12 + cipher.Length + 16];
        output[0] = 1;
        nonce.CopyTo(output, 1);
        cipher.CopyTo(output, 13);
        tag.CopyTo(output, 13 + cipher.Length);
        return output;
    }

    public static byte[] Seal(Keys keys, string kind, string name, string mime, byte[] body)
    {
        var meta = JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, string> { ["k"] = kind, ["name"] = name, ["mime"] = mime });
        return Seal(keys, meta, body);
    }

    /// 方式 1（端末で暗号化したもの）を開く。壊れている・鍵が違うときは例外
    public static Opened Open(Keys keys, byte[] data)
    {
        if (data.Length <= 1 + 12 + 16 || data[0] != 1) throw new CryptographicException("未対応の形式です");
        var nonce = data.AsSpan(1, 12);
        var cipher = data.AsSpan(13, data.Length - 13 - 16);
        var tag = data.AsSpan(data.Length - 16, 16);
        var plain = new byte[cipher.Length];
        using (var aes = new AesGcm(keys.Key, 16)) aes.Decrypt(nonce, cipher, tag, plain, Tag);
        return Parse(plain);
    }

    /// 方式 2（高速モード。サーバーが Mac などの公開鍵で暗号化したもの）を開く。
    /// quickKey は 04 ‖ X ‖ Y ‖ D の 97 バイト（Mac が出す「Windows・Android 用コード」の q）
    public static Opened OpenQuick(byte[] quickKey, byte[] data)
    {
        if (quickKey.Length != 97 || quickKey[0] != 4) throw new ArgumentException("高速モードの鍵の形式が正しくありません");
        if (data.Length <= 1 + 65 + 12 + 16 || data[0] != 2) throw new CryptographicException("未対応の形式です");

        var curve = ECCurve.NamedCurves.nistP256;
        using var mine = ECDiffieHellman.Create(new ECParameters
        {
            Curve = curve,
            Q = new ECPoint { X = quickKey[1..33], Y = quickKey[33..65] },
            D = quickKey[65..97],
        });
        using var theirs = ECDiffieHellman.Create(new ECParameters
        {
            Curve = curve,
            Q = new ECPoint { X = data[2..34], Y = data[34..66] },  // data[1] は 0x04（圧縮なしの印）
        });
        var shared = mine.DeriveRawSecretAgreement(theirs.PublicKey);
        var key = HKDF.DeriveKey(HashAlgorithmName.SHA256, shared, 32, salt: Tag, info: Encoding.UTF8.GetBytes("clipshelf-v1 quick"));

        var nonce = data.AsSpan(66, 12);
        var cipher = data.AsSpan(78, data.Length - 78 - 16);
        var tag = data.AsSpan(data.Length - 16, 16);
        var plain = new byte[cipher.Length];
        using (var aes = new AesGcm(key, 16)) aes.Decrypt(nonce, cipher, tag, plain, Tag);
        return Parse(plain);
    }

    /// [メタ情報の長さ 4バイト][メタ情報 JSON][本体] を分ける
    static Opened Parse(byte[] plain)
    {
        if (plain.Length < 4) throw new CryptographicException("壊れたデータです");
        var n = (int)BinaryPrimitives.ReadUInt32BigEndian(plain);
        if (n < 0 || 4 + n > plain.Length) throw new CryptographicException("壊れたデータです");
        using var doc = JsonDocument.Parse(plain.AsMemory(4, n));
        string Field(string name) =>
            doc.RootElement.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
        return new Opened(Field("k"), Field("name"), Field("mime"), plain[(4 + n)..]);
    }
}

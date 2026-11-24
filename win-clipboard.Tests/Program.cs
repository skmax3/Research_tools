// 暗号とペアリングコードの確認（GitHub Actions で実行: dotnet run --project win-clipboard.Tests）
// 固定の値は、iPhone 用ページ（clip-send/test/crypto-vector.mjs）と、サーバー（clip-relay/test/quick.mjs）が作ったもの。
// Mac（Swift）のテストと同じ値で、どの実装でも同じ結果になることを確かめる。
using System.Security.Cryptography;
using System.Text;
using ClipShelfWin;

var failed = 0;

void Check(string name, string got, string want)
{
    if (got == want)
    {
        Console.WriteLine("PASS " + name);
    }
    else
    {
        failed++;
        Console.WriteLine($"FAIL {name}\n  got:  {got}\n  want: {want}");
    }
}

string Hex(byte[] bytes) => Convert.ToHexString(bytes).ToLowerInvariant();
bool Throws(Action action)
{
    try { action(); return false; }
    catch (Exception) { return true; }
}

// ---- 端末で暗号化する方式（方式 1）----
const string vecSecret = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
const string vecRoom = "yPw6bue3EVsxQB8TPGB-HA";
const string vecMeta = "{\"k\":\"text\",\"name\":\"\",\"mime\":\"text/plain\"}";
const string vecBody = "こんにちは, clip!";
const string vecNonceHex = "000102030405060708090a0b";
const string vecSealedHex = "01000102030405060708090a0b7715f50bcb4cd950d51bc4cdda6bd8f671145bf5a1efd5a27a1f2991c52b183940310f6d6bdf7fbbd1ead04782c961d91c8e7215a0805ac880c782d5e23ab38677bdb2f863b8c33e4f067c0818ed497221987d2f";

var keys = SyncCrypto.Derive(vecSecret);
Check("部屋ID", keys.Room, vecRoom);
var sealedBytes = SyncCrypto.Seal(keys, Encoding.UTF8.GetBytes(vecMeta), Encoding.UTF8.GetBytes(vecBody), Convert.FromHexString(vecNonceHex));
Check("暗号文が Web 版・Mac 版と一致", Hex(sealedBytes), vecSealedHex);

var opened = SyncCrypto.Open(keys, Convert.FromHexString(vecSealedHex));
Check("Web 版の暗号文を復号（本体）", Encoding.UTF8.GetString(opened.Body), vecBody);
Check("Web 版の暗号文を復号（種類）", opened.Kind, "text");

var a = SyncCrypto.Seal(keys, "image", "a.jpg", "image/jpeg", new byte[] { 1, 2, 3, 255 });
var b = SyncCrypto.Seal(keys, "image", "a.jpg", "image/jpeg", new byte[] { 1, 2, 3, 255 });
Check("nonce は毎回違う", (Hex(a) == Hex(b)).ToString(), "False");
var back = SyncCrypto.Open(keys, a);
Check("往復（本体）", Hex(back.Body), "010203ff");
Check("往復（名前）", back.Name, "a.jpg");
Check("往復（種類）", back.Mime, "image/jpeg");

var tampered = Convert.FromHexString(vecSealedHex);
tampered[^1] ^= 1;
Check("改ざんは復号できない", Throws(() => SyncCrypto.Open(keys, tampered)).ToString(), "True");
var other = SyncCrypto.Derive(SyncCrypto.NewSecret());
Check("別の鍵では復号できない", Throws(() => SyncCrypto.Open(other, Convert.FromHexString(vecSealedHex))).ToString(), "True");
Check("別の秘密は別の部屋ID", (other.Room == keys.Room).ToString(), "False");
Check("部屋IDは22文字", keys.Room.Length.ToString(), "22");
Check("短い秘密は拒否", Throws(() => SyncCrypto.Derive("short")).ToString(), "True");

// 大きいデータ（3MB）
var big = new byte[3 * 1024 * 1024 + 5];
for (var i = 0; i < big.Length; i++) big[i] = (byte)(i * 7);
var bigBack = SyncCrypto.Open(keys, SyncCrypto.Seal(keys, "image", "big.png", "image/png", big));
Check("3MBの往復", bigBack.Body.AsSpan().SequenceEqual(big).ToString(), "True");

// ---- 高速モード（方式 2。サーバーのコードが作った暗号文）----
const string quickPrivateHex = "0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20";
const string quickPublicHex = "04515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f4536be3a50f318fbf9a5475902a221502bef0d57e08c53b2cc0a56f17d9f9354";
const string quickBody = "ショートカット, quick!";
const string quickSealedHex = "02045142f48a7c80caf47544a428fc57d272a6c678ad5e93ffcba36666a99639e51dd1bdb6fb598144567a2657e8ff3619fbaa0cd2a040c19ab22af910c705a757ba32333435363738393a3b3c3dafe2cdb9a9657b9efb6f60e5d0be037c5a235c218b07897ef820877373b1c402aa78749039c8e032ffd4057a61316f031e1579d2b31fc6b42a4c544403be5582d43be73117746ed28afef4306d031f17d75de7fc475332a76b2fdb";

var quickKey = Convert.FromHexString(quickPublicHex).Concat(Convert.FromHexString(quickPrivateHex)).ToArray();  // 04‖X‖Y‖D
var quickOpened = SyncCrypto.OpenQuick(quickKey, Convert.FromHexString(quickSealedHex));
Check("quick: サーバーが作った暗号文を復号（本体）", Encoding.UTF8.GetString(quickOpened.Body), quickBody);
Check("quick: 復号（種類）", quickOpened.Kind, "text");

var quickBad = Convert.FromHexString(quickSealedHex);
quickBad[^1] ^= 1;
Check("quick: 改ざんは復号できない", Throws(() => SyncCrypto.OpenQuick(quickKey, quickBad)).ToString(), "True");

var wrongKey = new byte[97];
using (var ecdh = ECDiffieHellman.Create(ECCurve.NamedCurves.nistP256))
{
    var p = ecdh.ExportParameters(true);
    wrongKey[0] = 4;
    p.Q.X!.CopyTo(wrongKey, 1);
    p.Q.Y!.CopyTo(wrongKey, 33);
    p.D!.CopyTo(wrongKey, 65);
}
Check("quick: 別の鍵では復号できない", Throws(() => SyncCrypto.OpenQuick(wrongKey, Convert.FromHexString(quickSealedHex))).ToString(), "True");
Check("quick: 形式の違う鍵は拒否", Throws(() => SyncCrypto.OpenQuick(new byte[10], Convert.FromHexString(quickSealedHex))).ToString(), "True");

// ---- ペアリングコード ----
var quickCode = SyncCrypto.Base64Url(quickKey);
var full = PairInfo.Parse($"k={vecSecret}&s=https%3A%2F%2Fexample.workers.dev&q={quickCode}");
Check("コード: 秘密", full?.Secret ?? "", vecSecret);
Check("コード: 中継サーバー", full?.Relay ?? "", "https://example.workers.dev");
Check("コード: 高速モードの鍵", full?.Quick ?? "", quickCode);

var url = PairInfo.Parse($"https://skmax3.github.io/Research_tools/clip-send/#k={vecSecret}&s=https%3A%2F%2Ffwr-clip.fwrtools.workers.dev");
Check("iPhone 用コード（アドレス全体）: 秘密", url?.Secret ?? "", vecSecret);
Check("iPhone 用コード: 高速モードの鍵なし", url?.Quick ?? "x", "");
Check("秘密だけでも読める（中継は既定）", PairInfo.Parse("  " + vecSecret + "\n")?.Relay ?? "", PairInfo.DefaultRelay);
Check("ホスト名だけの中継は https を補う", PairInfo.Parse($"k={vecSecret}&s=relay.example.com")?.Relay ?? "", "https://relay.example.com");
Check("形の違う高速モードの鍵は無視する", PairInfo.Parse($"k={vecSecret}&q=AAAA")?.Quick ?? "x", "");
Check("でたらめは拒否", (PairInfo.Parse("でたらめ") is null).ToString(), "True");
Check("空は拒否", (PairInfo.Parse("") is null).ToString(), "True");
Check("短い秘密は拒否", (PairInfo.Parse("k=short") is null).ToString(), "True");

if (failed > 0)
{
    Console.WriteLine($"{failed} 件失敗");
    return 1;
}
Console.WriteLine("すべて成功");
return 0;

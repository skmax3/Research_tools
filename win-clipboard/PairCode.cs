using System.Text.RegularExpressions;

namespace ClipShelfWin;

/// Mac のクリップ棚が出す「Windows・Android 用コード」（k=…&s=…&q=…）を読む。
/// iPhone 用のペアリングコード（アドレス全体、# 以降だけ、秘密だけ）も読める（その場合は高速モードの鍵なし）
public sealed record PairInfo(string Secret, string Relay, string Quick)
{
    public const string DefaultRelay = "https://fwr-clip.fwrtools.workers.dev";

    static readonly Regex SecretShape = new("^[A-Za-z0-9_-]{43}$", RegexOptions.Compiled);

    public static PairInfo? Parse(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        var t = text.Trim();
        var hash = t.IndexOf('#');
        if (hash >= 0) t = t[(hash + 1)..];
        t = t.TrimStart('?', '#');

        var query = new Dictionary<string, string>();
        foreach (var part in t.Split('&', StringSplitOptions.RemoveEmptyEntries))
        {
            var eq = part.IndexOf('=');
            if (eq <= 0) continue;
            try { query[part[..eq]] = Uri.UnescapeDataString(part[(eq + 1)..]); }
            catch (UriFormatException) { /* 読めない項目は飛ばす */ }
        }

        var secret = query.GetValueOrDefault("k") ?? (SecretShape.IsMatch(t) ? t : null);
        if (secret is null || !SecretShape.IsMatch(secret)) return null;

        var relay = (query.GetValueOrDefault("s") ?? DefaultRelay).Trim();
        if (!relay.StartsWith("http://") && !relay.StartsWith("https://")) relay = "https://" + relay;

        // 高速モードの鍵。形が正しいものだけ受け取る
        var quick = query.GetValueOrDefault("q") ?? "";
        var raw = quick.Length > 0 ? SyncCrypto.FromBase64(quick) : null;
        if (raw is null || raw.Length != 97 || raw[0] != 4) quick = "";

        return new PairInfo(secret, relay.TrimEnd('/'), quick);
    }
}

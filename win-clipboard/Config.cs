using System.Text.Json;

namespace ClipShelfWin;

/// 設定。%APPDATA%\ClipShelfWin\config.json に保存する（自分のユーザーだけが読める場所）。外部には送らない
public sealed class Config
{
    public string Secret { get; set; } = "";
    public string Relay { get; set; } = PairInfo.DefaultRelay;
    /// 高速モードの鍵（04‖X‖Y‖D の 97 バイトの base64url）。空なら、高速モードで届いたものは開けない
    public string Quick { get; set; } = "";
    /// コピーするたびに、ほかの端末へ自動で送る（最初はオフ。パスワードなども送ってしまうため）
    public bool AutoSend { get; set; }
    /// 届いたものを、すぐクリップボードに入れる（Ctrl+V で貼れる）
    public bool AutoCopy { get; set; } = true;
    public long LastSeq { get; set; }

    public bool Paired => Secret.Length > 0;

    public static string Dir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ClipShelfWin");

    static string FilePath => Path.Combine(Dir, "config.json");

    public static Config Load()
    {
        try { return JsonSerializer.Deserialize<Config>(File.ReadAllText(FilePath)) ?? new Config(); }
        catch (Exception) { return new Config(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(Dir);
        File.WriteAllText(FilePath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }

    /// 端末の名前（中継サーバーの x-device）。同じ Windows が2台あっても区別できるように、PC 名から短い印を付ける
    public static string DeviceName
    {
        get
        {
            var hash = System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(Environment.MachineName));
            return "windows-" + Convert.ToHexString(hash, 0, 2).ToLowerInvariant();
        }
    }
}

/// 動いている様子を残す（うまくいかないときに見る）。%APPDATA%\ClipShelfWin\log.txt（大きくなったら作り直す）
public static class Log
{
    public static void Write(string message)
    {
        try
        {
            Directory.CreateDirectory(Config.Dir);
            var path = Path.Combine(Config.Dir, "log.txt");
            if (File.Exists(path) && new FileInfo(path).Length > 512 * 1024) File.Delete(path);
            File.AppendAllText(path, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
        }
        catch (Exception) { /* ログが書けなくても、動作には影響させない */ }
    }
}

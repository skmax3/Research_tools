using System.Security.Cryptography;
using System.Text.Json;

namespace ClipShelfWin;

/// ほかの端末から届いたもの
public sealed record Received(string Device, ClipContent Content, DateTime At);

/// 送受信の本体。画面の操作と同じスレッド（UI スレッド）で作り、通知・クリップボードの操作は UI スレッドで行う
public sealed class Agent : IDisposable
{
    readonly Config config;
    readonly HistoryStore history;
    readonly SynchronizationContext ui;
    readonly SemaphoreSlim pollGate = new(1, 1);
    readonly List<Received> recent = new();

    RelayClient? relay;
    SyncCrypto.Keys? keys;
    byte[]? quickKey;
    CancellationTokenSource? cts;
    System.Threading.Timer? timer;

    DateTime suppressUntil = DateTime.MinValue;
    string lastAppliedHash = "";
    string lastSentHash = "";
    DateTime lastSentAt = DateTime.MinValue;
    bool warnedQuick;
    /// ペアリング直後の最初の受信（24時間分の履歴）は、一覧に入れるだけで、クリップボードも通知も変えない
    bool silentNext;

    /// 通知（タイトル, 本文）
    public event Action<string, string>? Notify;
    public event Action? StateChanged;

    public bool Connected { get; private set; }
    public IReadOnlyList<Received> Recent => recent;

    public Agent(Config config, HistoryStore history, SynchronizationContext ui)
    {
        this.config = config;
        this.history = history;
        this.ui = ui;
    }

    public string StateText =>
        !config.Paired ? "未ペアリング" : Connected ? "ペアリング済み・接続中" : "ペアリング済み・接続できていません";

    // ---- 開始・停止・ペアリング ----

    public void Start()
    {
        Stop();
        if (!config.Paired)
        {
            StateChanged?.Invoke();
            return;
        }
        try
        {
            keys = SyncCrypto.Derive(config.Secret);
        }
        catch (ArgumentException e)
        {
            Log.Write("ペアリング情報が正しくありません: " + e.Message);
            return;
        }
        quickKey = config.Quick.Length > 0 ? SyncCrypto.FromBase64(config.Quick) : null;
        silentNext = config.LastSeq == 0;
        var client = new RelayClient(config.Relay, keys.Room, Config.DeviceName);
        relay = client;
        cts = new CancellationTokenSource();
        var token = cts.Token;
        // 新着の知らせ（WebSocket）。切れていても届くように、30秒ごとにも確かめる
        _ = Task.Run(() => client.ListenAsync(() => _ = PollAsync(), token));
        timer = new System.Threading.Timer(_ => _ = PollAsync(), null, TimeSpan.Zero, TimeSpan.FromSeconds(30));
        StateChanged?.Invoke();
    }

    void Stop()
    {
        cts?.Cancel();
        timer?.Dispose();
        timer = null;
        relay?.Dispose();
        relay = null;
        keys = null;
        Connected = false;
    }

    public void Pair(PairInfo info)
    {
        config.Secret = info.Secret;
        config.Relay = info.Relay;
        config.Quick = info.Quick;
        config.LastSeq = 0;
        config.Save();
        warnedQuick = false;
        Start();
    }

    public void Unpair()
    {
        Stop();
        config.Secret = "";
        config.Quick = "";
        config.LastSeq = 0;
        config.Save();
        recent.Clear();
        StateChanged?.Invoke();
    }

    public void Dispose() => Stop();

    // ---- 受信 ----

    void SetConnected(bool value)
    {
        if (Connected == value) return;
        Connected = value;
        ui.Post(_ => StateChanged?.Invoke(), null);
    }

    void Advance(long seq)
    {
        if (seq > config.LastSeq) config.LastSeq = seq;
    }

    async Task PollAsync()
    {
        var client = relay;
        var k = keys;
        var token = cts?.Token ?? CancellationToken.None;
        if (client is null || k is null || !await pollGate.WaitAsync(0)) return;
        try
        {
            while (!token.IsCancellationRequested)
            {
                var list = await client.ListAsync(config.LastSeq, token);
                SetConnected(true);
                var silent = silentNext;
                var got = new List<Received>();
                var stopped = false;
                foreach (var item in list)
                {
                    if (item.Device == Config.DeviceName)  // 自分が置いたもの
                    {
                        Advance(item.Seq);
                        continue;
                    }
                    var blob = item.Inline;
                    if (blob is null)
                    {
                        try { blob = await client.GetAsync(item.Seq, token); }
                        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
                        {
                            stopped = true;  // 通信に失敗。ここで止めて、あとでやり直す（この項目は飛ばさない）
                            break;
                        }
                        if (blob is null)  // 24時間たって消えた
                        {
                            Advance(item.Seq);
                            continue;
                        }
                    }
                    Advance(item.Seq);
                    var content = Decode(k, blob);
                    if (content is not null) got.Add(new Received(DeviceLabel(item.Device), content, DateTime.Now));
                }
                config.Save();
                if (got.Count > 0) ui.Post(_ => Deliver(got, silent), null);
                if (stopped || list.Count < 50)  // 50件ずつ返ってくる。続きがなければ終わり
                {
                    if (!stopped) silentNext = false;
                    break;
                }
            }
        }
        catch (OperationCanceledException)
        {
            // 止められた
        }
        catch (Exception e)
        {
            SetConnected(false);
            Log.Write("受信できませんでした: " + e.Message);
        }
        finally
        {
            pollGate.Release();
        }
    }

    /// 先頭の1バイトで方式を見分ける（1: 端末で暗号化、2: 高速モード）。開けないもの（鍵が違う・壊れている）は null
    ClipContent? Decode(SyncCrypto.Keys k, byte[] blob)
    {
        try
        {
            SyncCrypto.Opened opened;
            if (blob.Length > 0 && blob[0] == 2)
            {
                if (quickKey is null)
                {
                    if (!warnedQuick)
                    {
                        warnedQuick = true;
                        ui.Post(_ => Notify?.Invoke("高速モードで届いたものを開けません",
                            "Mac の「Windows・Android アプリ用のコード」でペアリングし直してください。"), null);
                    }
                    return null;
                }
                opened = SyncCrypto.OpenQuick(quickKey, blob);
            }
            else
            {
                opened = SyncCrypto.Open(k, blob);
            }
            return opened.Kind switch
            {
                "text" => new ClipContent("text", "", "text/plain", opened.Body),
                "image" => new ClipContent("image", opened.Name, opened.Mime.Length > 0 ? opened.Mime : "image/png", opened.Body),
                _ => null,
            };
        }
        catch (Exception e) when (e is CryptographicException or ArgumentException or JsonException)
        {
            return null;
        }
    }

    static string DeviceLabel(string device)
    {
        var d = device.ToLowerInvariant();
        if (d.StartsWith("iphone")) return "iPhone";
        if (d.StartsWith("windows")) return "Windows";
        if (d.StartsWith("android")) return "Android";
        if (d == "mac") return "Mac";
        return device.Length > 0 ? device : "他の端末";
    }

    /// 届いたものを受け取る（UI スレッド）
    void Deliver(List<Received> got, bool silent)
    {
        foreach (var r in got)
        {
            recent.Insert(0, r);
            history.Add(r.Content, r.Device, remote: true);
        }
        while (recent.Count > 10) recent.RemoveAt(recent.Count - 1);
        if (silent)
        {
            StateChanged?.Invoke();
            return;
        }
        var newest = got[^1];  // 一覧は古い順なので、最後がいちばん新しい
        if (config.AutoCopy) Apply(newest.Content);
        Notify?.Invoke($"{newest.Device}から届きました",
            (config.AutoCopy ? "Ctrl+V で貼り付けられます。" : "トレイのアイコンから取り出せます。") + $"（{newest.Content.Summary}）");
        StateChanged?.Invoke();
    }

    /// クリップボードに入れる。自分が入れた変更は、送り返さない
    void Apply(ClipContent content)
    {
        suppressUntil = DateTime.UtcNow.AddSeconds(2);
        lastAppliedHash = content.Hash;
        try
        {
            ClipboardIO.Write(content);
        }
        catch (Exception e)
        {
            Log.Write("クリップボードに入れられませんでした: " + e.Message);
            Notify?.Invoke("クリップボードに入れられませんでした", "もう一度、トレイのアイコンの「届いたもの」から選んでください。");
        }
    }

    /// トレイのメニューの「届いたもの」から選んだとき
    public void CopyRecent(Received received) => Apply(received.Content);

    // ---- 送信 ----

    /// クリップボードが変わったとき（UI スレッド）。履歴に入れ、自動で送る設定なら送る
    public void OnClipboardChanged()
    {
        if (config.Paused) return;
        if (DateTime.UtcNow < suppressUntil) return;
        var content = ClipboardIO.Read();
        if (content is null) return;
        var hash = content.Hash;
        if (hash == lastAppliedHash) return;
        // 1回のコピーで、変更の知らせが何度も来ることがある。同じものは、続けて扱わない
        if (hash == lastSentHash && DateTime.UtcNow - lastSentAt < TimeSpan.FromSeconds(3)) return;
        lastSentHash = hash;
        lastSentAt = DateTime.UtcNow;
        history.Add(content, Win32.ProcessName(Win32.Foreground()), remote: false);
        if (config.AutoSend && config.Paired) Send(content, quiet: true);
    }

    /// 今のクリップボードを、すぐ送る（ショートカットキー・メニュー）
    public void SendClipboardNow()
    {
        var content = ClipboardIO.Read();
        if (content is null)
        {
            Notify?.Invoke("送れません", "クリップボードにテキストか画像がありません。");
            return;
        }
        lastSentHash = content.Hash;
        lastSentAt = DateTime.UtcNow;
        Send(content, quiet: false);
    }

    /// 履歴から選んだものを、ほかの端末へ送る
    public void SendItems(IReadOnlyList<HistoryItem> items)
    {
        for (var i = 0; i < items.Count; i++)
        {
            var content = history.ToContent(items[i]);
            if (content is not null) Send(content, quiet: i < items.Count - 1);
        }
    }

    /// 履歴の1つを、クリップボードに入れる
    public void CopyItem(HistoryItem item)
    {
        var content = history.ToContent(item);
        if (content is not null) Apply(content);
    }

    /// 履歴から選んだものを、前に使っていたアプリへ貼り付ける。
    /// 複数なら、順に貼る（テキストの間には Enter を入れる）。together なら、テキストを改行でつないで1回で貼る
    public async Task PasteAsync(IReadOnlyList<HistoryItem> items, bool together, IntPtr target)
    {
        if (items.Count == 0) return;
        var contents = items.Select(history.ToContent).Where(c => c is not null).Select(c => c!).ToList();
        if (contents.Count == 0) return;
        if (together && contents.All(c => c.Kind == "text"))
        {
            var joined = string.Join("\n", contents.Select(c => System.Text.Encoding.UTF8.GetString(c.Body)));
            contents = new List<ClipContent> { new("text", "", "text/plain", System.Text.Encoding.UTF8.GetBytes(joined)) };
        }
        await Task.Delay(120);  // 窓が閉じて、前のアプリに入力が戻るのを待つ
        Win32.Activate(target);
        await Task.Delay(120);
        for (var i = 0; i < contents.Count; i++)
        {
            Apply(contents[i]);
            await Task.Delay(120);
            Win32.SendPaste();
            await Task.Delay(220);
            if (i < contents.Count - 1 && contents[i].Kind == "text") Win32.SendEnter();
            await Task.Delay(120);
        }
    }

    void Send(ClipContent content, bool quiet)
    {
        var k = keys;
        var client = relay;
        if (k is null || client is null)
        {
            if (!quiet) Notify?.Invoke("送れません", "先にペアリングしてください。");
            return;
        }
        _ = Task.Run(async () =>
        {
            var ok = false;
            try
            {
                var encrypted = SyncCrypto.Seal(k, content.Kind, content.Name, content.Mime, content.Body);
                ok = await client.PostAsync(encrypted, CancellationToken.None);
            }
            catch (Exception e)
            {
                Log.Write("送れませんでした: " + e.Message);
            }
            ui.Post(_ =>
            {
                if (!ok) Notify?.Invoke("送れませんでした", "通信できているか確かめてください。");
                else if (!quiet) Notify?.Invoke("送りました", content.Summary);
            }, null);
        });
    }
}

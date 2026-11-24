using System.Net;
using System.Net.Http.Headers;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace ClipShelfWin;

/// 中継サーバーに置かれている1件（Inline は、小さいものだけ一覧に入っている中身）
public sealed record RelayItem(long Seq, string Device, byte[]? Inline);

/// 中継サーバー（clip-relay）との通信。サーバーには、端末で暗号化したデータしか渡さない
public sealed class RelayClient : IDisposable
{
    readonly HttpClient http = new() { Timeout = TimeSpan.FromSeconds(30) };
    readonly string baseUrl;
    readonly string room;
    readonly string device;

    public RelayClient(string baseUrl, string room, string device)
    {
        this.baseUrl = baseUrl.TrimEnd('/');
        this.room = room;
        this.device = device;
    }

    string Url(string path) => $"{baseUrl}/r/{room}{path}";

    /// after より新しい項目の一覧
    public async Task<List<RelayItem>> ListAsync(long after, CancellationToken ct)
    {
        using var response = await http.GetAsync(Url($"/items?after={after}"), ct);
        response.EnsureSuccessStatusCode();
        using var doc = JsonDocument.Parse(await response.Content.ReadAsStringAsync(ct));
        var list = new List<RelayItem>();
        foreach (var e in doc.RootElement.GetProperty("items").EnumerateArray())
        {
            byte[]? inline = null;
            if (e.TryGetProperty("data", out var d) && d.ValueKind == JsonValueKind.String) inline = SyncCrypto.FromBase64(d.GetString() ?? "");
            var dev = e.TryGetProperty("dev", out var v) ? v.GetString() ?? "" : "";
            list.Add(new RelayItem(e.GetProperty("seq").GetInt64(), dev, inline));
        }
        return list;
    }

    /// 1件の中身。24時間たって消えていたら null
    public async Task<byte[]?> GetAsync(long seq, CancellationToken ct)
    {
        using var response = await http.GetAsync(Url($"/items/{seq}"), ct);
        if (response.StatusCode == HttpStatusCode.NotFound) return null;
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadAsByteArrayAsync(ct);
    }

    /// 暗号化したデータを置く
    public async Task<bool> PostAsync(byte[] encrypted, CancellationToken ct)
    {
        using var content = new ByteArrayContent(encrypted);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        using var request = new HttpRequestMessage(HttpMethod.Post, Url("/items")) { Content = content };
        request.Headers.Add("x-device", device);
        using var response = await http.SendAsync(request, ct);
        return response.StatusCode == HttpStatusCode.Created;
    }

    /// 新着の知らせ（WebSocket）を待ち続ける。切れたら、間隔を空けてつなぎ直す。ct を止めるまで戻らない
    public async Task ListenAsync(Action onNotify, CancellationToken ct)
    {
        var wsUrl = baseUrl.Replace("https://", "wss://").Replace("http://", "ws://") + $"/r/{room}/ws";
        var delay = 2;
        while (!ct.IsCancellationRequested)
        {
            try
            {
                using var ws = new ClientWebSocket();
                await ws.ConnectAsync(new Uri(wsUrl), ct);
                delay = 2;
                onNotify();  // つながったら、取りこぼしがないか1回確かめる

                using var pinger = new PeriodicTimer(TimeSpan.FromSeconds(25));
                var pingLoop = Task.Run(async () =>
                {
                    try
                    {
                        while (await pinger.WaitForNextTickAsync(ct))
                        {
                            if (ws.State == WebSocketState.Open)
                                await ws.SendAsync(Encoding.UTF8.GetBytes("ping"), WebSocketMessageType.Text, true, ct);
                        }
                    }
                    catch (Exception) { /* 切れた・止められた。受信側の処理が気づく */ }
                }, ct);

                var buffer = new byte[4096];
                while (ws.State == WebSocketState.Open)
                {
                    var result = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), ct);
                    if (result.MessageType == WebSocketMessageType.Close) break;
                    if (result.MessageType == WebSocketMessageType.Text)
                    {
                        var text = Encoding.UTF8.GetString(buffer, 0, result.Count);
                        if (text != "pong") onNotify();  // 新着の知らせ
                    }
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception e)
            {
                Log.Write("WebSocket が切れました: " + e.Message);
            }
            try { await Task.Delay(TimeSpan.FromSeconds(delay), ct); }
            catch (OperationCanceledException) { break; }
            delay = Math.Min(60, delay * 2);
        }
    }

    public void Dispose() => http.Dispose();
}

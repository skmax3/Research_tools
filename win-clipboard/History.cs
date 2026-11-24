using System.Drawing;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ClipShelfWin;

/// 履歴の1件。画像・書式付きの中身は別ファイルに保存し、ここには情報だけ持つ
public sealed class HistoryItem
{
    public Guid Id { get; set; } = Guid.NewGuid();
    /// "text" か "image"
    public string Kind { get; set; } = "text";
    /// テキストなら本文、画像ならファイル名
    public string Text { get; set; } = "";
    public string Mime { get; set; } = "";
    public int Width { get; set; }
    public int Height { get; set; }
    /// コピー元。この PC なら、アプリの名前（chrome など）。ほかの端末から届いたものは、端末の名前（iPhone・Mac…）
    public string Source { get; set; } = "";
    /// ほかの端末から届いたもの
    public bool Remote { get; set; }
    /// 同じ内容かどうかの判定用
    public string Hash { get; set; } = "";
    public DateTime Time { get; set; } = DateTime.Now;
    public bool Pinned { get; set; }
    /// 保存している画像ファイルの大きさ
    public long Bytes { get; set; }

    /// 色分けの種類: "text"（青）・"link"（紫）・"image"（橙）
    [JsonIgnore]
    public string Category
    {
        get
        {
            if (Kind == "image") return "image";
            var t = Text.Trim();
            if (t.Length > 0 && !t.Contains('\n') && !t.Contains(' ') && Uri.TryCreate(t, UriKind.Absolute, out var u)
                && (u.Scheme == Uri.UriSchemeHttp || u.Scheme == Uri.UriSchemeHttps))
                return "link";
            return "text";
        }
    }
}

/// 履歴の保存場所: %APPDATA%\ClipShelfWin\history\（index.json と images\）。この PC の中だけに保存し、外部には送らない。
/// ピン留め以外は、新しい順に 300 件・合計 500MB まで。超えたら、ピン留め以外の古いものから消す
public sealed class HistoryStore
{
    public const int MaxItems = 300;
    public const long MaxBytes = 500L * 1024 * 1024;

    readonly string dir = Path.Combine(Config.Dir, "history");
    readonly List<HistoryItem> items = new();  // 新しい順
    readonly Dictionary<Guid, Bitmap> thumbs = new();
    readonly Queue<Guid> thumbOrder = new();

    string IndexPath => Path.Combine(dir, "index.json");
    string ImagesDir => Path.Combine(dir, "images");

    public IReadOnlyList<HistoryItem> Items => items;
    public event Action? Changed;

    string ImagePath(HistoryItem item) => Path.Combine(ImagesDir, item.Id + ExtensionOf(item.Mime));

    static string ExtensionOf(string mime) => mime switch
    {
        "image/jpeg" => ".jpg",
        "image/gif" => ".gif",
        "image/webp" => ".webp",
        "image/heic" => ".heic",
        _ => ".png",
    };

    public void Load()
    {
        try
        {
            if (!File.Exists(IndexPath)) return;
            var loaded = JsonSerializer.Deserialize<List<HistoryItem>>(File.ReadAllText(IndexPath));
            if (loaded is null) return;
            items.Clear();
            items.AddRange(loaded.Where(i => i.Kind == "text" || File.Exists(ImagePath(i))));
        }
        catch (Exception e)
        {
            Log.Write("履歴を読めませんでした: " + e.Message);
        }
    }

    void Save()
    {
        try
        {
            Directory.CreateDirectory(dir);
            File.WriteAllText(IndexPath, JsonSerializer.Serialize(items));
        }
        catch (Exception e)
        {
            Log.Write("履歴を保存できませんでした: " + e.Message);
        }
    }

    /// 先頭に追加する。同じ内容がすでにあれば、新しく作らずに、先頭へ移動する
    public HistoryItem Add(ClipContent content, string source, bool remote)
    {
        var hash = content.Hash;
        var existing = items.FirstOrDefault(i => i.Kind == content.Kind && i.Hash == hash);
        if (existing is not null)
        {
            items.Remove(existing);
            existing.Time = DateTime.Now;
            if (source.Length > 0) { existing.Source = source; existing.Remote = remote; }
            items.Insert(0, existing);
            Save();
            Changed?.Invoke();
            return existing;
        }

        var item = new HistoryItem
        {
            Kind = content.Kind,
            Text = content.Kind == "text" ? Encoding.UTF8.GetString(content.Body) : content.Name,
            Mime = content.Mime,
            Source = source,
            Remote = remote,
            Hash = hash,
        };
        if (content.Kind == "image")
        {
            try
            {
                Directory.CreateDirectory(ImagesDir);
                File.WriteAllBytes(ImagePath(item), content.Body);
                item.Bytes = content.Body.Length;
                using var ms = new MemoryStream(content.Body);
                using var image = Image.FromStream(ms, false, false);
                item.Width = image.Width;
                item.Height = image.Height;
            }
            catch (ArgumentException)
            {
                // Windows が開けない形式（HEIC など）。大きさは分からないが、ファイルとしては保存する
            }
            catch (Exception e)
            {
                Log.Write("画像を保存できませんでした: " + e.Message);
            }
        }
        items.Insert(0, item);
        Trim();
        Save();
        Changed?.Invoke();
        return item;
    }

    /// 履歴の項目を、送ったり貼ったりできる形に戻す
    public ClipContent? ToContent(HistoryItem item)
    {
        if (item.Kind == "text") return new ClipContent("text", "", "text/plain", Encoding.UTF8.GetBytes(item.Text));
        try
        {
            return new ClipContent("image", item.Text, item.Mime.Length > 0 ? item.Mime : "image/png", File.ReadAllBytes(ImagePath(item)));
        }
        catch (Exception e)
        {
            Log.Write("画像を読めませんでした: " + e.Message);
            return null;
        }
    }

    /// 画面に出す縮小画像（長辺 320px）。読めない形式は null
    public Bitmap? Thumbnail(HistoryItem item)
    {
        if (item.Kind != "image") return null;
        if (thumbs.TryGetValue(item.Id, out var cached)) return cached;
        try
        {
            using var source = Image.FromFile(ImagePath(item));
            var scale = Math.Min(1.0, 320.0 / Math.Max(source.Width, source.Height));
            var thumb = new Bitmap(Math.Max(1, (int)(source.Width * scale)), Math.Max(1, (int)(source.Height * scale)));
            using (var g = Graphics.FromImage(thumb))
            {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(source, 0, 0, thumb.Width, thumb.Height);
            }
            thumbs[item.Id] = thumb;
            thumbOrder.Enqueue(item.Id);
            while (thumbOrder.Count > 60)
            {
                var old = thumbOrder.Dequeue();
                if (thumbs.Remove(old, out var bmp)) bmp.Dispose();
            }
            return thumb;
        }
        catch (Exception)
        {
            return null;
        }
    }

    public void TogglePin(Guid id)
    {
        var item = items.FirstOrDefault(i => i.Id == id);
        if (item is null) return;
        item.Pinned = !item.Pinned;
        Save();
        Changed?.Invoke();
    }

    public void Delete(IEnumerable<Guid> ids)
    {
        var set = ids.ToHashSet();
        foreach (var item in items.Where(i => set.Contains(i.Id)).ToList()) Remove(item);
        Save();
        Changed?.Invoke();
    }

    public void ClearUnpinned()
    {
        foreach (var item in items.Where(i => !i.Pinned).ToList()) Remove(item);
        Save();
        Changed?.Invoke();
    }

    public long TotalBytes() => items.Sum(i => i.Bytes);

    void Remove(HistoryItem item)
    {
        items.Remove(item);
        if (thumbs.Remove(item.Id, out var bmp)) bmp.Dispose();
        if (item.Kind != "image") return;
        try { File.Delete(ImagePath(item)); }
        catch (Exception) { /* 消せなくても、一覧からは消える */ }
    }

    /// 件数と容量の上限を超えた分を、古いものから消す。ピン留めと、いちばん新しい1件は消さない
    void Trim()
    {
        var count = 0;
        foreach (var item in items.Where(i => !i.Pinned).ToList())
        {
            count++;
            if (count > MaxItems) Remove(item);
        }
        for (var i = items.Count - 1; i > 0 && TotalBytes() > MaxBytes; i--)
        {
            if (!items[i].Pinned && items[i].Bytes > 0) Remove(items[i]);
        }
    }
}

using System.Drawing.Drawing2D;
using Microsoft.Win32;

namespace ClipShelfWin;

/// 色・文字（Windows の「ライト／ダーク」の設定に合わせる）
public static class Theme
{
    public static bool Dark { get; private set; }
    public static Color Bg { get; private set; }
    public static Color Card { get; private set; }
    public static Color Text { get; private set; }
    public static Color Muted { get; private set; }
    public static Color Border { get; private set; }
    public static readonly Color Accent = Color.FromArgb(10, 132, 255);

    public static readonly Font Body = new("Yu Gothic UI", 10f);
    public static readonly Font Small = new("Yu Gothic UI", 8.5f);
    public static readonly Font SmallBold = new("Yu Gothic UI", 8.5f, FontStyle.Bold);

    public static void Refresh()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            Dark = key?.GetValue("AppsUseLightTheme") is int v && v == 0;
        }
        catch (Exception) { Dark = false; }
        Bg = Dark ? Color.FromArgb(32, 34, 40) : Color.FromArgb(245, 245, 248);
        Card = Dark ? Color.FromArgb(44, 47, 54) : Color.White;
        Text = Dark ? Color.FromArgb(242, 242, 247) : Color.FromArgb(28, 28, 30);
        Muted = Dark ? Color.FromArgb(160, 160, 168) : Color.FromArgb(110, 110, 115);
        Border = Dark ? Color.FromArgb(70, 74, 82) : Color.FromArgb(217, 217, 222);
    }

    /// 種類の色: テキスト＝青、リンク＝紫、画像＝橙（Mac 版と同じ）
    public static Color CategoryColor(string category) => category switch
    {
        "link" => Color.FromArgb(175, 82, 222),
        "image" => Color.FromArgb(255, 149, 0),
        _ => Color.FromArgb(10, 132, 255),
    };

    public static string CategoryLabel(string category) => category switch
    {
        "link" => "リンク",
        "image" => "画像",
        _ => "テキスト",
    };

    public static GraphicsPath Rounded(Rectangle r, int radius)
    {
        var d = radius * 2;
        var path = new GraphicsPath();
        path.AddArc(r.X, r.Y, d, d, 180, 90);
        path.AddArc(r.Right - d, r.Y, d, d, 270, 90);
        path.AddArc(r.Right - d, r.Bottom - d, d, d, 0, 90);
        path.AddArc(r.X, r.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}

/// 絞り込み用の小さなボタンの列（種類・コピー元）
public sealed class ChipBar : Control
{
    public sealed record Chip(string Text, Color Color, bool On, object? Tag);

    List<Chip> chips = new();
    readonly List<Rectangle> rects = new();

    public event Action<Chip>? ChipClicked;

    public ChipBar()
    {
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        Height = 28;
    }

    public void SetChips(List<Chip> list)
    {
        chips = list;
        Invalidate();
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Theme.Bg);
        rects.Clear();
        var x = 0;
        foreach (var chip in chips)
        {
            var size = TextRenderer.MeasureText(g, chip.Text, Theme.SmallBold);
            var rect = new Rectangle(x, 2, size.Width + 18, Height - 6);
            if (rect.Right > Width) break;
            rects.Add(rect);
            using (var path = Theme.Rounded(rect, rect.Height / 2))
            {
                using var fill = new SolidBrush(chip.On ? chip.Color : Color.FromArgb(Theme.Dark ? 60 : 38, chip.Color));
                g.FillPath(fill, path);
                if (!chip.On)
                {
                    using var pen = new Pen(Color.FromArgb(110, chip.Color));
                    g.DrawPath(pen, path);
                }
            }
            TextRenderer.DrawText(g, chip.Text, Theme.SmallBold, rect, chip.On ? Color.White : Theme.Text,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);
            x = rect.Right + 6;
        }
    }

    protected override void OnMouseClick(MouseEventArgs e)
    {
        base.OnMouseClick(e);
        for (var i = 0; i < rects.Count; i++)
        {
            if (rects[i].Contains(e.Location)) { ChipClicked?.Invoke(chips[i]); return; }
        }
    }
}

/// カードを横に並べて見せる部分（Mac 版のパネルと同じ見た目）
public sealed class CardStrip : Control
{
    public const int CardW = 230, CardH = 224, Gap = 12, Pad = 16;

    readonly HistoryStore history;
    List<HistoryItem> items = new();
    int scrollX;

    /// 枠が付いている（カーソルのある）カード
    public int CurrentIndex { get; private set; }
    /// 複数選択したもの（選んだ順）
    public List<Guid> Picked { get; } = new();

    /// ダブルクリックしたとき
    public event Action<HistoryItem>? Activated;
    /// カーソルや選択が変わったとき
    public event Action? SelectionChanged;
    /// 右クリックしたとき
    public event Action<HistoryItem, Point>? ContextRequested;

    public CardStrip(HistoryStore history)
    {
        this.history = history;
        SetStyle(ControlStyles.OptimizedDoubleBuffer | ControlStyles.AllPaintingInWmPaint | ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        TabStop = false;
    }

    public IReadOnlyList<HistoryItem> Items => items;
    public HistoryItem? Current => CurrentIndex >= 0 && CurrentIndex < items.Count ? items[CurrentIndex] : null;

    public void SetItems(List<HistoryItem> list)
    {
        items = list;
        CurrentIndex = Math.Clamp(CurrentIndex, 0, Math.Max(0, items.Count - 1));
        Picked.RemoveAll(id => items.All(i => i.Id != id));
        ClampScroll();
        Invalidate();
        SelectionChanged?.Invoke();
    }

    public void ResetPosition()
    {
        CurrentIndex = 0;
        scrollX = 0;
        Picked.Clear();
    }

    Rectangle CardRect(int i) => new(Pad + i * (CardW + Gap) - scrollX, 6, CardW, CardH);

    void ClampScroll()
    {
        var total = Pad * 2 + items.Count * (CardW + Gap) - Gap;
        scrollX = Math.Clamp(scrollX, 0, Math.Max(0, total - Width));
    }

    void EnsureVisible()
    {
        if (items.Count == 0) return;
        var r = CardRect(CurrentIndex);
        if (r.Left < Pad) scrollX += r.Left - Pad;
        else if (r.Right > Width - Pad) scrollX += r.Right - (Width - Pad);
        ClampScroll();
    }

    public void MoveCursor(int delta, bool extendPick)
    {
        if (items.Count == 0) return;
        if (extendPick && !Picked.Contains(items[CurrentIndex].Id)) Picked.Add(items[CurrentIndex].Id);
        CurrentIndex = Math.Clamp(CurrentIndex + delta, 0, items.Count - 1);
        if (extendPick && !Picked.Contains(items[CurrentIndex].Id)) Picked.Add(items[CurrentIndex].Id);
        EnsureVisible();
        Invalidate();
        SelectionChanged?.Invoke();
    }

    public void TogglePick(HistoryItem item)
    {
        if (!Picked.Remove(item.Id)) Picked.Add(item.Id);
        Invalidate();
        SelectionChanged?.Invoke();
    }

    public void SelectAll()
    {
        Picked.Clear();
        Picked.AddRange(items.Select(i => i.Id));
        Invalidate();
        SelectionChanged?.Invoke();
    }

    public void ClearPicks()
    {
        Picked.Clear();
        Invalidate();
        SelectionChanged?.Invoke();
    }

    int IndexAt(Point p)
    {
        for (var i = 0; i < items.Count; i++)
        {
            if (CardRect(i).Contains(p)) return i;
        }
        return -1;
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        var i = IndexAt(e.Location);
        if (i < 0) return;
        CurrentIndex = i;
        if (e.Button == MouseButtons.Left)
        {
            // ⌘クリックに当たる Ctrl+クリック、Shift+クリック、すでに選択中のときは、選ぶ（貼り付けない）
            if ((ModifierKeys & (Keys.Control | Keys.Shift)) != 0 || Picked.Count > 0) TogglePick(items[i]);
        }
        Invalidate();
        SelectionChanged?.Invoke();
        if (e.Button == MouseButtons.Right) ContextRequested?.Invoke(items[i], e.Location);
    }

    protected override void OnMouseDoubleClick(MouseEventArgs e)
    {
        base.OnMouseDoubleClick(e);
        var i = IndexAt(e.Location);
        if (i >= 0 && e.Button == MouseButtons.Left && Picked.Count == 0) Activated?.Invoke(items[i]);
    }

    protected override void OnMouseWheel(MouseEventArgs e)
    {
        base.OnMouseWheel(e);
        scrollX -= e.Delta;
        ClampScroll();
        Invalidate();
    }

    static string Ago(DateTime t)
    {
        var span = DateTime.Now - t;
        if (span.TotalSeconds < 60) return "たった今";
        if (span.TotalMinutes < 60) return $"{(int)span.TotalMinutes}分前";
        if (span.TotalHours < 24) return $"{(int)span.TotalHours}時間前";
        return t.ToString("M/d HH:mm");
    }

    static string SizeText(long bytes) =>
        bytes < 1024 * 1024 ? $"{Math.Max(1, bytes / 1024)} KB" : $"{bytes / 1024.0 / 1024.0:0.0} MB";

    protected override void OnPaint(PaintEventArgs e)
    {
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        g.Clear(Theme.Bg);
        if (items.Count == 0)
        {
            TextRenderer.DrawText(g, "まだ何もありません。コピーすると、ここにたまります。", Theme.Body, ClientRectangle, Theme.Muted,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            return;
        }
        for (var i = 0; i < items.Count; i++)
        {
            var r = CardRect(i);
            if (r.Right < 0 || r.Left > Width) continue;
            DrawCard(g, r, items[i], i, i == CurrentIndex, Picked.IndexOf(items[i].Id) + 1);
        }
    }

    void DrawCard(Graphics g, Rectangle r, HistoryItem item, int index, bool current, int pickOrder)
    {
        var category = item.Category;
        var color = Theme.CategoryColor(category);
        using var path = Theme.Rounded(r, 12);
        using (var fill = new SolidBrush(Theme.Card)) g.FillPath(fill, path);
        if (pickOrder > 0)
        {
            using var tint = new SolidBrush(Color.FromArgb(34, Theme.Accent));
            g.FillPath(tint, path);
        }
        // 上の色の帯（種類の色）
        g.SetClip(path);
        using (var bar = new SolidBrush(color)) g.FillRectangle(bar, r.X, r.Y, r.Width, 4);
        g.ResetClip();

        // 種類のラベル
        var label = Theme.CategoryLabel(category);
        var labelSize = TextRenderer.MeasureText(g, label, Theme.SmallBold);
        var capsule = new Rectangle(r.X + 10, r.Y + 12, labelSize.Width + 14, 20);
        using (var capsulePath = Theme.Rounded(capsule, 10))
        using (var capsuleFill = new SolidBrush(color))
            g.FillPath(capsuleFill, capsulePath);
        TextRenderer.DrawText(g, label, Theme.SmallBold, capsule, Color.White,
            TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);

        // 右上: ピン留め・選択の丸
        var circle = new Rectangle(r.Right - 30, r.Y + 12, 20, 20);
        using (var pen = new Pen(pickOrder > 0 ? Theme.Accent : Theme.Muted, 1.6f)) g.DrawEllipse(pen, circle);
        if (pickOrder > 0)
        {
            using var dot = new SolidBrush(Theme.Accent);
            g.FillEllipse(dot, circle);
            TextRenderer.DrawText(g, pickOrder.ToString(), Theme.SmallBold, circle, Color.White,
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);
        }
        if (item.Pinned)
            TextRenderer.DrawText(g, "★", Theme.Body, new Rectangle(r.Right - 56, r.Y + 11, 22, 22), Color.FromArgb(255, 159, 10),
                TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPadding);

        // 中身
        var content = new Rectangle(r.X + 10, r.Y + 40, r.Width - 20, r.Height - 40 - 30);
        if (item.Kind == "text")
        {
            var text = item.Text.Length > 600 ? item.Text[..600] : item.Text;
            TextRenderer.DrawText(g, text, Theme.Body, content, category == "link" ? Color.FromArgb(175, 82, 222) : Theme.Text,
                TextFormatFlags.WordBreak | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix | TextFormatFlags.Left | TextFormatFlags.Top);
        }
        else
        {
            var thumb = history.Thumbnail(item);
            if (thumb is null)
            {
                TextRenderer.DrawText(g, item.Mime == "image/heic" ? "HEIC" : "画像", Theme.Body, content, Theme.Muted,
                    TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter);
            }
            else
            {
                var scale = Math.Min((double)content.Width / thumb.Width, (double)content.Height / thumb.Height);
                var w = (int)(thumb.Width * scale);
                var h = (int)(thumb.Height * scale);
                g.DrawImage(thumb, content.X + (content.Width - w) / 2, content.Y + (content.Height - h) / 2, w, h);
            }
        }

        // 下: コピー元・大きさ・時間、番号
        var meta = new List<string>();
        if (item.Source.Length > 0) meta.Add(item.Source);
        if (item.Kind == "text") meta.Add($"{item.Text.Length}文字");
        else
        {
            if (item.Width > 0) meta.Add($"{item.Width}×{item.Height}");
            if (item.Bytes > 0) meta.Add(SizeText(item.Bytes));
        }
        meta.Add(Ago(item.Time));
        var footer = new Rectangle(r.X + 10, r.Bottom - 26, r.Width - 70, 20);
        TextRenderer.DrawText(g, string.Join("・", meta), Theme.Small, footer, Theme.Muted,
            TextFormatFlags.Left | TextFormatFlags.VerticalCenter | TextFormatFlags.EndEllipsis | TextFormatFlags.NoPrefix);
        if (index < 9)
            TextRenderer.DrawText(g, $"Ctrl+{index + 1}", Theme.Small, new Rectangle(r.Right - 62, r.Bottom - 26, 54, 20), Theme.Muted,
                TextFormatFlags.Right | TextFormatFlags.VerticalCenter | TextFormatFlags.NoPrefix);

        // 枠: カーソルは太い青、選択中は細い青、ふだんは薄い線
        var borderColor = current ? Theme.Accent : pickOrder > 0 ? Color.FromArgb(160, Theme.Accent) : Theme.Border;
        using var border = new Pen(borderColor, current ? 3f : pickOrder > 0 ? 2f : 1f);
        g.DrawPath(border, path);
    }
}

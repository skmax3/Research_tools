namespace ClipShelfWin;

/// 画面の下から出てくる履歴パネル（Mac 版と同じ見た目・操作）
public sealed class PanelForm : Form
{
    const int PanelHeight = 372;

    readonly HistoryStore history;
    readonly Agent agent;
    readonly TextBox search = new();
    readonly ChipBar chips = new();
    readonly CardStrip strip;
    readonly Label hint = new();

    IntPtr target = IntPtr.Zero;
    string kindFilter = "all";
    string? sourceFilter;
    bool busy;
    bool confirmDelete;

    public PanelForm(HistoryStore history, Agent agent)
    {
        this.history = history;
        this.agent = agent;
        strip = new CardStrip(history);

        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        TopMost = true;
        StartPosition = FormStartPosition.Manual;
        KeyPreview = true;
        Padding = new Padding(16, 12, 16, 8);

        search.PlaceholderText = "検索（コピーした文字を探す）";
        search.Font = Theme.Body;
        search.BorderStyle = BorderStyle.FixedSingle;
        search.Dock = DockStyle.Top;
        search.TextChanged += (_, _) => { strip.ResetPosition(); ApplyFilter(); };

        chips.Dock = DockStyle.Top;
        chips.ChipClicked += OnChip;

        hint.Dock = DockStyle.Bottom;
        hint.Height = 26;
        hint.Font = Theme.Small;
        hint.TextAlign = ContentAlignment.MiddleLeft;

        strip.Dock = DockStyle.Fill;
        strip.Activated += item => _ = PasteAsync(new List<HistoryItem> { item }, false);
        strip.SelectionChanged += UpdateHint;
        strip.ContextRequested += ShowContext;

        // 追加する順番に注意（Dock は後から足したものが外側）
        Controls.Add(strip);
        Controls.Add(hint);
        Controls.Add(new Panel { Dock = DockStyle.Top, Height = 6 });
        Controls.Add(chips);
        Controls.Add(new Panel { Dock = DockStyle.Top, Height = 6 });
        Controls.Add(search);

        history.Changed += () => { if (Visible) ApplyFilter(); };
        Deactivate += (_, _) => { if (!busy && Visible) Hide(); };
    }

    protected override bool ShowWithoutActivation => false;

    /// パネルを出す／しまう（ショートカットキー・トレイから）
    public void Toggle()
    {
        if (Visible) { Hide(); return; }
        target = Win32.Foreground();
        Theme.Refresh();
        BackColor = Theme.Bg;
        search.BackColor = Theme.Card;
        search.ForeColor = Theme.Text;
        hint.BackColor = Theme.Bg;
        hint.ForeColor = Theme.Muted;

        var screen = Screen.FromPoint(Cursor.Position).WorkingArea;
        Bounds = new Rectangle(screen.X, screen.Bottom - PanelHeight, screen.Width, PanelHeight);
        search.Text = "";
        kindFilter = "all";
        sourceFilter = null;
        confirmDelete = false;
        strip.ResetPosition();
        ApplyFilter();
        Show();
        Activate();
        search.Focus();
    }

    // ---- 絞り込み ----

    void OnChip(ChipBar.Chip chip)
    {
        if (chip.Tag is string tag)
        {
            if (tag.StartsWith("kind:")) kindFilter = tag[5..];
            else if (tag.StartsWith("src:")) sourceFilter = sourceFilter == tag[4..] ? null : tag[4..];
        }
        strip.ResetPosition();
        ApplyFilter();
        search.Focus();
    }

    void CycleKind()
    {
        var order = new[] { "all", "text", "link", "image" };
        kindFilter = order[(Array.IndexOf(order, kindFilter) + 1) % order.Length];
        strip.ResetPosition();
        ApplyFilter();
    }

    void ApplyFilter()
    {
        var q = search.Text.Trim();
        var list = history.Items.AsEnumerable();
        if (kindFilter != "all") list = list.Where(i => i.Category == kindFilter);
        if (sourceFilter is not null) list = list.Where(i => i.Source == sourceFilter);
        if (q.Length > 0) list = list.Where(i => i.Kind == "text" ? i.Text.Contains(q, StringComparison.CurrentCultureIgnoreCase)
                                                                    : i.Source.Contains(q, StringComparison.CurrentCultureIgnoreCase));
        // ピン留めを先頭に
        var ordered = list.OrderByDescending(i => i.Pinned).ToList();
        strip.SetItems(ordered);

        var chipList = new List<ChipBar.Chip>
        {
            new("すべて", Theme.Accent, kindFilter == "all", "kind:all"),
            new("テキスト", Theme.CategoryColor("text"), kindFilter == "text", "kind:text"),
            new("リンク", Theme.CategoryColor("link"), kindFilter == "link", "kind:link"),
            new("画像", Theme.CategoryColor("image"), kindFilter == "image", "kind:image"),
        };
        var sources = history.Items.Where(i => i.Source.Length > 0).GroupBy(i => i.Source)
            .OrderByDescending(g => g.Count()).Take(6).Select(g => g.Key);
        foreach (var s in sources)
            chipList.Add(new ChipBar.Chip(s, Color.FromArgb(120, 120, 128), sourceFilter == s, "src:" + s));
        chips.SetChips(chipList);
        UpdateHint();
    }

    void UpdateHint()
    {
        if (confirmDelete)
        {
            hint.Text = $"選んだ {strip.Picked.Count} 件を削除します。もう一度 Delete で実行、Esc でやめる";
            return;
        }
        hint.Text = strip.Picked.Count > 0
            ? $"{strip.Picked.Count} 件選択中。Enter＝順に貼る　Shift+Enter＝まとめて貼る　Ctrl+I＝ほかの端末へ送る　Delete＝削除"
            : $"{strip.Items.Count} 件　Enter＝貼る　Space＝選ぶ（複数）　Ctrl+1〜9＝番号で貼る　Ctrl+I＝ほかの端末へ送る　Ctrl+P＝ピン留め　Esc＝閉じる";
    }

    // ---- 操作 ----

    List<HistoryItem> Targets()
    {
        if (strip.Picked.Count > 0)
            return strip.Picked.Select(id => strip.Items.FirstOrDefault(i => i.Id == id)).Where(i => i is not null).Select(i => i!).ToList();
        return strip.Current is { } cur ? new List<HistoryItem> { cur } : new List<HistoryItem>();
    }

    async Task PasteAsync(List<HistoryItem> items, bool together)
    {
        if (items.Count == 0) return;
        Hide();
        await agent.PasteAsync(items, together, target);
    }

    void ShowContext(HistoryItem item, Point at)
    {
        busy = true;
        try
        {
            var menu = new ContextMenuStrip();
            menu.Items.Add("貼り付け", null, (_, _) => _ = PasteAsync(Targets(), false));
            menu.Items.Add("クリップボードに入れるだけ", null, (_, _) => { foreach (var i in Targets().Take(1)) agent.CopyItem(i); Hide(); });
            menu.Items.Add("ほかの端末へ送る", null, (_, _) => { agent.SendItems(Targets()); });
            menu.Items.Add(item.Pinned ? "ピン留めを外す" : "ピン留め", null, (_, _) => { history.TogglePin(item.Id); });
            menu.Items.Add(new ToolStripSeparator());
            menu.Items.Add("削除", null, (_, _) => history.Delete(Targets().Select(i => i.Id)));
            menu.Closed += (_, _) => { busy = false; };
            menu.Show(strip, at);
        }
        catch (Exception)
        {
            busy = false;
        }
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        var searchEmpty = search.Text.Length == 0;
        var shift = (keyData & Keys.Shift) != 0;
        var ctrl = (keyData & Keys.Control) != 0;
        var key = keyData & Keys.KeyCode;

        if (key == Keys.Escape)
        {
            if (confirmDelete) { confirmDelete = false; UpdateHint(); }
            else if (strip.Picked.Count > 0) strip.ClearPicks();
            else Hide();
            return true;
        }
        if (confirmDelete && key != Keys.Delete)
        {
            confirmDelete = false;
            UpdateHint();
        }
        switch (key)
        {
            case Keys.Left when !ctrl: strip.MoveCursor(-1, shift); return true;
            case Keys.Right when !ctrl: strip.MoveCursor(1, shift); return true;
            case Keys.Return:
                _ = PasteAsync(Targets(), shift);
                return true;
            case Keys.Space when searchEmpty && !ctrl:
                if (strip.Current is { } c) strip.TogglePick(c);
                return true;
            case Keys.Tab:
                CycleKind();
                return true;
            case Keys.Delete when searchEmpty:
                {
                    var targets = Targets();
                    if (targets.Count == 0) return true;
                    if (strip.Picked.Count > 1 && !confirmDelete)
                    {
                        confirmDelete = true;
                        UpdateHint();
                        return true;
                    }
                    confirmDelete = false;
                    history.Delete(targets.Select(i => i.Id));
                    return true;
                }
            case Keys.A when ctrl && searchEmpty:
                strip.SelectAll();
                return true;
            case Keys.P when ctrl:
                if (strip.Current is { } p) history.TogglePin(p.Id);
                return true;
            case Keys.I when ctrl:
                agent.SendItems(Targets());
                return true;
            case >= Keys.D1 and <= Keys.D9 when ctrl:
                {
                    var index = key - Keys.D1;
                    if (index < strip.Items.Count) _ = PasteAsync(new List<HistoryItem> { strip.Items[index] }, false);
                    return true;
                }
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }
}

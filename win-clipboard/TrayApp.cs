using Microsoft.Win32;

namespace ClipShelfWin;

/// タスクトレイ（画面右下の通知領域）に住むアプリ。画面は、トレイのメニューとペアリングの窓だけ
public sealed class TrayApp : ApplicationContext
{
    const int HotKeySend = 1;
    const int HotKeyPanel = 2;
    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string ReleasePage = "https://github.com/skmax3/Research_tools/releases/tag/clipshelf-win-latest";

    readonly Config config = Config.Load();
    readonly HistoryStore history = new();
    readonly Agent agent;
    readonly PanelForm panel;
    readonly MessageWindow window = new();
    readonly NotifyIcon tray = new();
    readonly ContextMenuStrip menu = new();
    readonly ToolStripMenuItem stateItem = new("状態") { Enabled = false };
    readonly ToolStripMenuItem recentItem = new("届いたもの");
    readonly ToolStripMenuItem autoSendItem = new("コピーするたびに、ほかの端末へ自動で送る");
    readonly ToolStripMenuItem autoCopyItem = new("届いたら、すぐクリップボードに入れる");
    readonly ToolStripMenuItem pauseItem = new("記録を一時停止する");
    readonly ToolStripMenuItem startupItem = new("Windows の起動時に自動で開始");

    public TrayApp()
    {
        Theme.Refresh();
        history.Load();
        agent = new Agent(config, history, SynchronizationContext.Current ?? new SynchronizationContext());
        panel = new PanelForm(history, agent);
        agent.Notify += (title, text) => tray.ShowBalloonTip(4000, title, text, ToolTipIcon.Info);
        agent.StateChanged += UpdateText;

        var open = new ToolStripMenuItem("履歴を開く（Ctrl+Alt+X）", null, (_, _) => panel.Toggle());
        var send = new ToolStripMenuItem("今のコピーを、ほかの端末へ送る（Ctrl+Alt+S）", null, (_, _) => agent.SendClipboardNow());
        var pair = new ToolStripMenuItem("ペアリング…", null, (_, _) => ShowPairForm());
        var update = new ToolStripMenuItem("最新版をダウンロードするページを開く", null, (_, _) => OpenUrl(ReleasePage));
        var quit = new ToolStripMenuItem("終了", null, (_, _) => ExitThread());

        autoSendItem.CheckOnClick = true;
        autoSendItem.Checked = config.AutoSend;
        autoSendItem.CheckedChanged += (_, _) => { config.AutoSend = autoSendItem.Checked; config.Save(); };
        autoCopyItem.CheckOnClick = true;
        autoCopyItem.Checked = config.AutoCopy;
        autoCopyItem.CheckedChanged += (_, _) => { config.AutoCopy = autoCopyItem.Checked; config.Save(); };
        pauseItem.CheckOnClick = true;
        pauseItem.Checked = config.Paused;
        pauseItem.CheckedChanged += (_, _) => { config.Paused = pauseItem.Checked; config.Save(); };
        startupItem.CheckOnClick = true;
        startupItem.Checked = StartupEnabled();
        startupItem.CheckedChanged += (_, _) => SetStartup(startupItem.Checked);

        menu.Items.AddRange(new ToolStripItem[]
        {
            stateItem, new ToolStripSeparator(), open, send, recentItem, new ToolStripSeparator(),
            autoSendItem, autoCopyItem, pauseItem, startupItem, new ToolStripSeparator(), pair, update, quit,
        });
        menu.Opening += (_, _) => RefreshMenu();

        tray.Icon = LoadIcon();
        tray.Text = "クリップ棚";
        tray.ContextMenuStrip = menu;
        tray.DoubleClick += (_, _) => panel.Toggle();
        tray.Visible = true;

        window.ClipboardChanged += agent.OnClipboardChanged;
        window.HotKeyPressed += id =>
        {
            if (id == HotKeySend) agent.SendClipboardNow();
            else if (id == HotKeyPanel) panel.Toggle();
        };
        if (!window.RegisterHotKey(HotKeySend, MessageWindow.Control | MessageWindow.Alt, Keys.S))
            tray.ShowBalloonTip(5000, "Ctrl+Alt+S を登録できませんでした", "ほかのアプリが使っているようです。トレイのメニューからも送れます。", ToolTipIcon.Warning);

        if (!window.RegisterHotKey(HotKeyPanel, MessageWindow.Control | MessageWindow.Alt, Keys.X))
            tray.ShowBalloonTip(5000, "Ctrl+Alt+X を登録できませんでした", "ほかのアプリが使っているようです。トレイのメニューからも開けます。", ToolTipIcon.Warning);

        UpdateText();
        agent.Start();
        if (!config.Paired) ShowPairForm();  // 最初に起動したときは、ペアリングの窓を出す
    }

    static Icon LoadIcon()
    {
        try
        {
            var path = Environment.ProcessPath;
            if (path is not null) return Icon.ExtractAssociatedIcon(path) ?? SystemIcons.Application;
        }
        catch (Exception) { /* アイコンが読めなくても動く */ }
        return SystemIcons.Application;
    }

    void UpdateText() => tray.Text = "クリップ棚: " + agent.StateText;

    /// メニューを開いたときに、最新の状態にする
    void RefreshMenu()
    {
        stateItem.Text = "状態: " + agent.StateText;
        recentItem.DropDownItems.Clear();
        if (agent.Recent.Count == 0)
        {
            recentItem.DropDownItems.Add(new ToolStripMenuItem("まだ届いていません") { Enabled = false });
            return;
        }
        foreach (var r in agent.Recent)
        {
            var item = r;
            recentItem.DropDownItems.Add(new ToolStripMenuItem($"{item.At:HH:mm}  {item.Device}・{item.Content.Summary}", null,
                (_, _) => agent.CopyRecent(item)));
        }
    }

    void ShowPairForm()
    {
        using var form = new PairForm(config.Paired, config.Paired ? PairInfo.Link(config.Secret, config.Relay, config.Quick) : "");
        if (form.ShowDialog() != DialogResult.OK) return;
        if (form.Unpair) agent.Unpair();
        else if (form.Result is not null) agent.Pair(form.Result);
        UpdateText();
    }

    static void OpenUrl(string url)
    {
        try { System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true }); }
        catch (Exception e) { Log.Write("ページを開けませんでした: " + e.Message); }
    }

    // ---- Windows の起動時に自動で開始（現在のユーザーの Run に登録する） ----

    static bool StartupEnabled()
    {
        using var key = Registry.CurrentUser.OpenSubKey(RunKey);
        return key?.GetValue("ClipShelfWin") is string;
    }

    static void SetStartup(bool on)
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(RunKey, true);
            if (key is null) return;
            if (on) key.SetValue("ClipShelfWin", $"\"{Environment.ProcessPath}\"");
            else key.DeleteValue("ClipShelfWin", false);
        }
        catch (Exception e)
        {
            Log.Write("起動時の設定を変えられませんでした: " + e.Message);
        }
    }

    protected override void ExitThreadCore()
    {
        tray.Visible = false;
        tray.Dispose();
        window.Dispose();
        panel.Dispose();
        agent.Dispose();
        base.ExitThreadCore();
    }
}

using System.Runtime.InteropServices;

namespace ClipShelfWin;

/// 画面を持たない窓。クリップボードが変わった知らせと、ショートカットキーの知らせを受け取る
public sealed class MessageWindow : NativeWindow, IDisposable
{
    const int WM_CLIPBOARDUPDATE = 0x031D;
    const int WM_HOTKEY = 0x0312;
    const uint MOD_NOREPEAT = 0x4000;

    public const uint Alt = 0x0001;
    public const uint Control = 0x0002;

    public event Action? ClipboardChanged;
    public event Action<int>? HotKeyPressed;

    readonly List<int> hotKeys = new();

    public MessageWindow()
    {
        // 画面に出ない「メッセージ専用」の窓（親が HWND_MESSAGE = -3）
        CreateHandle(new CreateParams { Parent = new IntPtr(-3) });
        AddClipboardFormatListener(Handle);
    }

    /// どのアプリを使っていても効くショートカットキーを登録する。ほかのアプリが使っていたら false
    public bool RegisterHotKey(int id, uint modifiers, Keys key)
    {
        var ok = NativeRegisterHotKey(Handle, id, modifiers | MOD_NOREPEAT, (uint)key);
        if (ok) hotKeys.Add(id);
        return ok;
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_CLIPBOARDUPDATE) ClipboardChanged?.Invoke();
        else if (m.Msg == WM_HOTKEY) HotKeyPressed?.Invoke(m.WParam.ToInt32());
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        foreach (var id in hotKeys) UnregisterHotKey(Handle, id);
        RemoveClipboardFormatListener(Handle);
        DestroyHandle();
    }

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool AddClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool RemoveClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", EntryPoint = "RegisterHotKey", SetLastError = true)]
    static extern bool NativeRegisterHotKey(IntPtr hwnd, int id, uint modifiers, uint vk);

    [DllImport("user32.dll", SetLastError = true)]
    static extern bool UnregisterHotKey(IntPtr hwnd, int id);
}

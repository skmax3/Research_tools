using System.Diagnostics;
using System.Runtime.InteropServices;

namespace ClipShelfWin;

/// Windows の操作（いま使っているアプリ・貼り付けのキー）
public static class Win32
{
    const ushort VK_CONTROL = 0x11;
    const ushort VK_V = 0x56;
    const ushort VK_RETURN = 0x0D;
    const uint KEYEVENTF_KEYUP = 0x0002;
    const uint INPUT_KEYBOARD = 1;
    const int SW_RESTORE = 9;

    [StructLayout(LayoutKind.Sequential)]
    struct MOUSEINPUT
    {
        public int dx;
        public int dy;
        public uint mouseData;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL;
        public ushort wParamH;
    }

    [StructLayout(LayoutKind.Explicit)]
    struct InputUnion
    {
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    struct INPUT
    {
        public uint type;
        public InputUnion U;
    }

    [DllImport("user32.dll")]
    static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern bool IsIconic(IntPtr hWnd);

    [DllImport("user32.dll")]
    static extern bool ShowWindow(IntPtr hWnd, int cmd);

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    [DllImport("user32.dll", SetLastError = true)]
    static extern uint SendInput(uint inputs, INPUT[] data, int size);

    public static IntPtr Foreground() => GetForegroundWindow();

    /// 前に使っていたアプリの窓を、前面に戻す
    public static void Activate(IntPtr hwnd)
    {
        if (hwnd == IntPtr.Zero) return;
        if (IsIconic(hwnd)) ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
    }

    /// その窓のアプリの名前（chrome など）。分からなければ空
    public static string ProcessName(IntPtr hwnd)
    {
        try
        {
            if (hwnd == IntPtr.Zero) return "";
            GetWindowThreadProcessId(hwnd, out var pid);
            using var process = Process.GetProcessById((int)pid);
            return process.ProcessName;
        }
        catch (Exception)
        {
            return "";  // 管理者権限のアプリなどは、名前を調べられない
        }
    }

    static INPUT Key(ushort vk, bool up) => new()
    {
        type = INPUT_KEYBOARD,
        U = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = up ? KEYEVENTF_KEYUP : 0 } },
    };

    /// Ctrl+V を押したことにする
    public static void SendPaste()
    {
        var inputs = new[] { Key(VK_CONTROL, false), Key(VK_V, false), Key(VK_V, true), Key(VK_CONTROL, true) };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }

    /// Enter を押したことにする（複数のテキストを順に貼るとき、間に入れる）
    public static void SendEnter()
    {
        var inputs = new[] { Key(VK_RETURN, false), Key(VK_RETURN, true) };
        SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
    }
}

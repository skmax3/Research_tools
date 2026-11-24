namespace ClipShelfWin;

internal static class Program
{
    [STAThread]
    static void Main()
    {
        // 二重に起動しない
        using var mutex = new Mutex(true, "ClipShelfWin-single-instance", out var created);
        if (!created) return;

        ApplicationConfiguration.Initialize();
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        Application.ThreadException += (_, e) => Log.Write("エラー: " + e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log.Write("致命的なエラー: " + e.ExceptionObject);
        Application.Run(new TrayApp());
    }
}

using System.Globalization;
using System.Windows;

namespace Iap2Loc.Desktop;

public partial class App : Application
{
    private Mutex? _instance;

    protected override void OnStartup(StartupEventArgs e)
    {
        CultureInfo.DefaultThreadCurrentCulture = CultureInfo.GetCultureInfo("zh-CN");
        CultureInfo.DefaultThreadCurrentUICulture = CultureInfo.GetCultureInfo("zh-CN");
        _instance = new Mutex(true, "Local\\SuixingLoc.Desktop", out var first);
        if (!first && !e.Args.Contains("--smoke-test"))
        {
            MessageBox.Show("随行定位已在运行，请从任务栏切换到应用窗口。", "随行定位");
            Shutdown(); return;
        }
        DispatcherUnhandledException += (_, args) =>
        {
            MessageBox.Show("操作未完成：" + ChineseText.Error(args.Exception), "随行定位", MessageBoxButton.OK, MessageBoxImage.Warning);
            args.Handled = true;
        };
        base.OnStartup(e);
        MainWindow = new MainWindow(e.Args);
        MainWindow.Show();
    }

    protected override void OnExit(ExitEventArgs e)
    {
        _instance?.Dispose();
        base.OnExit(e);
    }
}

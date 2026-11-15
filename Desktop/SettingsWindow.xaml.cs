using System.Diagnostics;
using System.IO;
using System.Net.Http;
using System.Security.Cryptography.X509Certificates;
using System.Windows;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;

namespace Iap2Loc.Desktop;

public partial class SettingsWindow : Window
{
    private readonly DesktopSettings _settings;
    private readonly DesktopIdentityProvider _identity;
    internal SettingsWindow(DesktopSettings settings, DesktopIdentityProvider identity)
    {
        _settings = settings; _identity = identity;
        InitializeComponent();
        ProviderBox.SelectedIndex = settings.SearchProvider switch { "amap" => 1, "photon" => 2, _ => 0 };
        AmapKeyBox.Password = settings.AmapKey; CityBox.Text = settings.SearchCity; EndpointBox.Text = settings.PhotonEndpoint;
        VerboseBox.IsChecked = Log.Verbose;
        IdentityText.Text = identity.Detail;
        try { RuntimeText.Text = "地图组件已安装 · WebView2 " + CoreWebView2Environment.GetAvailableBrowserVersionString(); }
        catch { RuntimeText.Text = "未检测到地图组件，点击下方按钮安装。"; }
    }

    private void Save_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var provider = ProviderBox.SelectedIndex switch { 1 => "amap", 2 => "photon", _ => "auto" };
            if (provider == "amap" && string.IsNullOrWhiteSpace(AmapKeyBox.Password)) throw new ArgumentException("使用高德搜索前，请填写 Web 服务 Key");
            var endpoint = EndpointBox.Text.Trim();
            if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var uri) || (uri.Scheme != "https" && !(uri.IsLoopback && uri.Scheme == "http")))
                throw new ArgumentException("开放地图服务地址必须是 HTTPS，或本机 HTTP 地址");
            _settings.SearchProvider = provider; _settings.AmapKey = AmapKeyBox.Password;
            _settings.SearchCity = CityBox.Text.Trim(); _settings.PhotonEndpoint = endpoint;
            _settings.Save(); Log.Verbose = VerboseBox.IsChecked == true;
            DialogResult = true;
        }
        catch (Exception ex) { MessageBox.Show(this, ChineseText.Error(ex), "设置未保存", MessageBoxButton.OK, MessageBoxImage.Warning); }
    }

    private void Import_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog { Title = "导入配件身份", Filter = "支持的身份来源|*.apk;*.pk8|DiPlay 安装包|*.apk|PKCS#8 私钥（同目录需有证书）|*.pk8" };
        if (dialog.ShowDialog(this) != true) return;
        try { _identity.Import(dialog.FileName); IdentityText.Text = _identity.Detail; }
        catch (Exception ex) { MessageBox.Show(this, ChineseText.Error(ex), "身份导入未完成", MessageBoxButton.OK, MessageBoxImage.Warning); }
    }
    private void BuiltIn_Click(object sender, RoutedEventArgs e) { _identity.UseBuiltIn(); IdentityText.Text = _identity.Detail; }
    private void Check_Click(object sender, RoutedEventArgs e) { _identity.Prime(); IdentityText.Text = _identity.Detail; }
    private void OpenData_Click(object sender, RoutedEventArgs e) => Process.Start(new ProcessStartInfo(DesktopSettings.DataDirectory) { UseShellExecute = true });

    private async void Runtime_Click(object sender, RoutedEventArgs e)
    {
        RuntimeButton.IsEnabled = false;
        RuntimeText.Text = "正在下载微软地图组件安装程序…";
        var installer = Path.Combine(DesktopSettings.DataDirectory, "MicrosoftEdgeWebview2Setup.exe");
        try
        {
            using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(3) };
            var bytes = await http.GetByteArrayAsync("https://go.microsoft.com/fwlink/p/?LinkId=2124703");
            await File.WriteAllBytesAsync(installer, bytes);
            // Require Microsoft's signed bootstrapper before executing downloaded code.
            var signature = await Task.Run(() => InstallerSignature.VerifyMicrosoft(installer));
            if (!signature) throw new InvalidOperationException("安装程序的微软数字签名校验未通过，请稍后重试");
            RuntimeText.Text = "正在安装地图组件，请稍候…";
            using var process = Process.Start(new ProcessStartInfo(installer, "/silent /install") { UseShellExecute = false, CreateNoWindow = true });
            if (process is null) throw new IOException("无法启动地图组件安装程序");
            await process.WaitForExitAsync();
            RuntimeText.Text = "安装完成。地图组件版本：" + CoreWebView2Environment.GetAvailableBrowserVersionString() + "。请重新启动随行定位。";
        }
        catch (Exception ex) { RuntimeText.Text = "组件安装未完成：" + ChineseText.Error(ex); }
        finally { RuntimeButton.IsEnabled = true; }
    }
}

internal static class InstallerSignature
{
    public static bool VerifyMicrosoft(string path)
    {
        // WinVerifyTrust validates both the signature and the Authenticode trust chain.
        using var info = new TrustFile(path);
        var file = new WinTrustFileInfo { Size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<WinTrustFileInfo>(), FilePath = info.Path };
        var filePointer = System.Runtime.InteropServices.Marshal.AllocHGlobal(System.Runtime.InteropServices.Marshal.SizeOf<WinTrustFileInfo>());
        try
        {
            System.Runtime.InteropServices.Marshal.StructureToPtr(file, filePointer, false);
            var trust = new WinTrustData { Size = (uint)System.Runtime.InteropServices.Marshal.SizeOf<WinTrustData>(), UiChoice = 2, RevocationChecks = 0, UnionChoice = 1, File = filePointer, ProviderFlags = 0x1000 };
            var action = new Guid("00AAC56B-CD44-11D0-8CC2-00C04FC295EE");
            if (WinVerifyTrust(new IntPtr(-1), ref action, ref trust) != 0) return false;
#pragma warning disable SYSLIB0057
            using var cert = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
#pragma warning restore SYSLIB0057
            return cert.GetNameInfo(X509NameType.SimpleName, false) == "Microsoft Corporation";
        }
        finally { System.Runtime.InteropServices.Marshal.FreeHGlobal(filePointer); }
    }
    private sealed class TrustFile(string path) : IDisposable
    {
        public IntPtr Path { get; } = System.Runtime.InteropServices.Marshal.StringToCoTaskMemUni(path);
        public void Dispose() => System.Runtime.InteropServices.Marshal.FreeCoTaskMem(Path);
    }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct WinTrustFileInfo { public uint Size; public IntPtr FilePath; public IntPtr FileHandle; public IntPtr KnownSubject; }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct WinTrustData
    {
        public uint Size; public IntPtr PolicyCallbackData; public IntPtr SipClientData; public uint UiChoice;
        public uint RevocationChecks; public uint UnionChoice; public IntPtr File; public uint StateAction;
        public IntPtr StateData; public IntPtr UrlReference; public uint ProviderFlags; public uint UiContext;
        public IntPtr SignatureSettings;
    }
    [System.Runtime.InteropServices.DllImport("wintrust.dll", ExactSpelling = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int WinVerifyTrust(IntPtr window, ref Guid action, ref WinTrustData data);
}

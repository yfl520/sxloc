using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Threading;
using Iap2Loc.Engine;
using Iap2Loc.Protocol;
using Iap2Loc.Transport;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;

namespace Iap2Loc.Desktop;

public partial class MainWindow : Window
{
    private const string MapDocument = "https://map.suixing.local/index.html";
    private readonly DesktopSettings _settings;
    private readonly DesktopIdentityProvider _identity;
    private readonly AppConfig _config;
    private readonly SessionManager _manager;
    private readonly FavoriteStore _favorites;
    private readonly PlaceSearchService _search = new();
    private readonly ObservableCollection<SessionRow> _sessions = new();
    private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromMilliseconds(800) };
    private readonly List<string> _logs = new();
    private readonly string[] _args;
    private List<BluetoothDevice> _devices = new();
    private CancellationTokenSource? _searchCancellation;
    private bool _initialized, _loading, _mapReady, _closed, _connecting;
    private string _destination = "地图选点 / 手动输入";

    public MainWindow(string[] args)
    {
        _args = args;
        _settings = DesktopSettings.Load();
        InitializeComponent();
        Directory.CreateDirectory(DesktopSettings.DataDirectory);
        Log.Emitted += OnLog;
        _identity = new DesktopIdentityProvider(_settings);
        IdentitySource.Provider = _identity;
        _identity.Prime();
        _config = AppConfig.Load(Path.Combine(DesktopSettings.DataDirectory, "iap2loc.json"));
        _config.PrepareForRun(null);
        _manager = new SessionManager(_settings.Latitude, _settings.Longitude, _config);
        _manager.ApplyTarget(_settings.ToTargetUpdate(), _settings.Rate);
        _favorites = new FavoriteStore(_config);
        SessionsList.ItemsSource = _sessions;
        LoadInputs();
        _initialized = true;
        UpdateIdentity(); LoadFavorites(); LoadHistory();
        UpdateApplied();
        _poll.Tick += (_, _) => RefreshSessions();
        _poll.Start();
        Loaded += Window_Loaded;
        AddLog("就绪", "桌面应用已启动，身份材料检查完成；地图和搜索需要网络。");
        InputBindings.Add(new KeyBinding(new ActionCommand(() => ApplyTarget()), new KeyGesture(Key.Enter, ModifierKeys.Control)));
    }

    private async void Window_Loaded(object sender, RoutedEventArgs e)
    {
        var mapTask = InitializeMap();
        await RefreshDevices();
        await mapTask;
        if (_args.Contains("--smoke-test")) await RunSmokeTest();
    }

    private void LoadInputs()
    {
        _loading = true;
        LatitudeBox.Text = Format(_settings.Latitude, "F6"); LongitudeBox.Text = Format(_settings.Longitude, "F6");
        AltitudeBox.Text = Format(_settings.Altitude); AccuracyBox.Text = Format(_settings.Accuracy);
        RateBox.Text = _settings.Rate.ToString(); QualityBox.SelectedIndex = Math.Clamp(_settings.Quality, 0, 8);
        SatellitesBox.Text = _settings.Satellites.ToString(); SpeedBox.Text = Format(_settings.Speed); BearingBox.Text = Format(_settings.Bearing);
        JitterPositionBox.IsChecked = _settings.JitterPosition; JitterAccuracyBox.IsChecked = _settings.JitterAccuracy;
        JitterMetersBox.Text = Format(_settings.JitterMeters); AccuracyMinBox.Text = Format(_settings.AccuracyMin); AccuracyMaxBox.Text = Format(_settings.AccuracyMax);
        DatumBox.SelectedIndex = _settings.Datum == "gcj" ? 0 : 1;
        _loading = false;
    }

    private static string Format(double value, string format = "0.######") => value.ToString(format, CultureInfo.InvariantCulture);
    private static double Number(TextBox box, string name, double minimum, double maximum)
    {
        if (!double.TryParse(box.Text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) || !double.IsFinite(value) || value < minimum || value > maximum)
            throw new ArgumentException($"{name}必须在 {minimum} 到 {maximum} 之间");
        return value;
    }
    private static int Integer(TextBox box, string name, int minimum, int maximum)
    {
        var value = Number(box, name, minimum, maximum);
        if (value != Math.Truncate(value)) throw new ArgumentException(name + "必须为整数");
        return (int)value;
    }

    private bool ApplyTarget(bool reportError = true)
    {
        try
        {
            var update = new TargetUpdate
            {
                Latitude = Number(LatitudeBox, "纬度", -90, 90), Longitude = Number(LongitudeBox, "经度", -180, 180),
                Altitude = Number(AltitudeBox, "高度", -12000, 100000), Accuracy = Number(AccuracyBox, "精度", .1, 100000),
                Speed = Number(SpeedBox, "速度", 0, 1000), Bearing = Number(BearingBox, "航向", 0, 359.999999),
                Quality = QualityBox.SelectedIndex, Satellites = Integer(SatellitesBox, "卫星数", 0, 99),
                JitterPosition = JitterPositionBox.IsChecked == true, JitterAccuracy = JitterAccuracyBox.IsChecked == true,
                JitterMeters = Number(JitterMetersBox, "偏移半径", 0, 10000),
                AccuracyMin = Number(AccuracyMinBox, "精度下限", .1, 100000), AccuracyMax = Number(AccuracyMaxBox, "精度上限", .1, 100000),
            };
            var rate = Integer(RateBox, "发送周期", 10, 60000);
            _manager.ApplyTarget(update, rate);
            var target = _manager.Target.Snapshot();
            _settings.Latitude = target.Latitude; _settings.Longitude = target.Longitude;
            _settings.Altitude = target.Altitude ?? 10; _settings.Accuracy = target.Accuracy ?? 5;
            _settings.Speed = target.Speed ?? 0; _settings.Bearing = target.Bearing ?? 0;
            _settings.Quality = target.Quality; _settings.Satellites = target.Satellites; _settings.Rate = rate;
            _settings.JitterPosition = target.JitterPosition; _settings.JitterAccuracy = target.JitterAccuracy;
            _settings.JitterMeters = target.JitterMeters; _settings.AccuracyMin = target.AccuracyMin; _settings.AccuracyMax = target.AccuracyMax;
            _settings.Save();
            DraftHint.Text = "已应用，下次发送使用当前目标";
            DestinationText.Text = _destination;
            UpdateApplied();
            _ = MapScript($"setPosition({Format(target.Latitude)},{Format(target.Longitude)},false);setApplied({Format(target.ResolvedLatitude)},{Format(target.ResolvedLongitude)})");
            Status("目标位置已应用，所有会话跟随该位置");
            return true;
        }
        catch (Exception ex) { if (reportError) ShowError(ex); return false; }
    }

    private void UpdateApplied()
    {
        var target = _manager.Target.Snapshot();
        AppliedText.Text = $"已应用目标  {target.Latitude:F6}, {target.Longitude:F6}";
        ResolvedText.Text = target.JitterPosition || target.JitterAccuracy
            ? $"实际发送 {target.ResolvedLatitude:F6}, {target.ResolvedLongitude:F6} · 精度 {target.ResolvedAccuracy:F1} 米"
            : $"WGS-84 · 共享目标 · 配置周期 {_settings.Rate} 毫秒（设备订阅优先）";
    }

    private async Task InitializeMap()
    {
        try
        {
            var options = new CoreWebView2EnvironmentOptions { Language = "zh-CN", AreBrowserExtensionsEnabled = false };
            var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(DesktopSettings.DataDirectory, "WebView2"), options);
            await MapView.EnsureCoreWebView2Async(environment);
            if (_closed) return;
            MapView.CoreWebView2.Settings.AreDefaultContextMenusEnabled = false;
            MapView.CoreWebView2.Settings.AreDevToolsEnabled = false;
            MapView.CoreWebView2.Settings.AreBrowserAcceleratorKeysEnabled = false;
            MapView.CoreWebView2.Settings.IsStatusBarEnabled = false;
            MapView.CoreWebView2.NewWindowRequested += (_, e) => e.Handled = true;
            MapView.CoreWebView2.NavigationStarting += (_, e) =>
            {
                if (e.Uri != MapDocument) e.Cancel = true;
                if (Log.Verbose) AddLog("详细", "地图页面导航：" + (e.Cancel ? "已阻止外部页面" : "内置地图"));
            };
            MapView.CoreWebView2.NavigationCompleted += (_, e) =>
            {
                if (_closed) return;
                if (Log.Verbose) AddLog("详细", e.IsSuccess ? "内置地图页面加载成功" : "内置地图页面加载失败，请重新启动应用");
            };
            MapView.CoreWebView2.WebMessageReceived += Map_MessageReceived;
            MapView.CoreWebView2.ProcessFailed += (_, _) => { _mapReady = false; MapPlaceholder.Visibility = Visibility.Visible; MapPlaceholder.Text = "地图组件异常，请重新启动应用；坐标输入仍可使用。"; MapView.Visibility = Visibility.Collapsed; };
            var html = Resource("map.html").Replace("/*LEAFLET_CSS*/", Resource("leaflet.css")).Replace("/*LEAFLET_JS*/", Resource("leaflet.js"));
            var mapDirectory = Path.Combine(DesktopSettings.DataDirectory, "Map");
            Directory.CreateDirectory(mapDirectory);
            await File.WriteAllTextAsync(Path.Combine(mapDirectory, "index.html"), html, Encoding.UTF8);
            if (_closed) return;
            MapView.CoreWebView2.SetVirtualHostNameToFolderMapping("map.suixing.local", mapDirectory, CoreWebView2HostResourceAccessKind.DenyCors);
            MapView.CoreWebView2.Navigate(MapDocument);
        }
        catch (Exception ex)
        {
            MapView.Visibility = Visibility.Collapsed;
            MapPlaceholder.Text = "地图组件未能启动。请在设置中安装或修复 WebView2，然后重启应用。\n搜索和手动输入坐标仍可使用。";
            AddLog("提示", "地图组件启动失败：" + ChineseText.Error(ex));
        }
    }

    private static string Resource(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Iap2Loc.Desktop.Assets." + name) ?? throw new FileNotFoundException(name);
        using var reader = new StreamReader(stream, Encoding.UTF8); return reader.ReadToEnd();
    }

    private async void Map_MessageReceived(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        try
        {
            if (e.Source != MapDocument || _closed) return;
            using var data = JsonDocument.Parse(e.WebMessageAsJson);
            var root = data.RootElement;
            var type = root.GetProperty("type").GetString();
            if (type == "ready")
            {
                _mapReady = true;
                MapPlaceholder.Visibility = Visibility.Collapsed;
                await MapScript($"setDatum({JsonSerializer.Serialize(_settings.Datum)});setPosition({Format(_settings.Latitude)},{Format(_settings.Longitude)},true);setApplied({Format(_manager.Target.Next().Latitude)},{Format(_manager.Target.Next().Longitude)})");
                Status("地图已就绪，可搜索地点或点击地图选点");
            }
            else if (type == "pick")
            {
                Pick(root.GetProperty("latitude").GetDouble(), root.GetProperty("longitude").GetDouble(), "地图选点", false);
            }
        }
        catch (Exception ex) { AddLog("提示", "地图消息处理失败：" + ChineseText.Error(ex)); }
    }

    private async Task MapScript(string script)
    {
        if (!_mapReady || _closed) return;
        try { await MapView.ExecuteScriptAsync(script); }
        catch (Exception ex) when (ex is ObjectDisposedException or InvalidOperationException) { }
    }

    private void Pick(double lat, double lon, string name, bool pan = true)
    {
        if (!double.IsFinite(lat) || !double.IsFinite(lon) || Math.Abs(lat) > 90 || Math.Abs(lon) > 180) return;
        _loading = true;
        LatitudeBox.Text = Format(lat, "F6"); LongitudeBox.Text = Format(lon, "F6");
        _loading = false;
        _destination = name; DestinationText.Text = name;
        MarkDirty();
        _ = MapScript($"setPosition({Format(lat)},{Format(lon)},{pan.ToString().ToLowerInvariant()})");
    }

    private void MarkDirty() { if (_initialized) DraftHint.Text = "有未应用的修改 · 点击应用定位"; }
    private void Target_Edited(object sender, TextChangedEventArgs e) { if (_initialized && !_loading) MarkDirty(); }
    private void Target_SelectionChanged(object sender, RoutedEventArgs e) { if (_initialized && !_loading) MarkDirty(); }
    private void Apply_Click(object sender, RoutedEventArgs e) => ApplyTarget();
    private void SearchBox_KeyDown(object sender, KeyEventArgs e) { if (e.Key == Key.Enter) { e.Handled = true; Search_Click(sender, e); } }

    private async void Search_Click(object sender, RoutedEventArgs e)
    {
        var query = SearchBox.Text.Trim();
        if (query.Length == 0) { SearchBox.Focus(); return; }
        _searchCancellation?.Cancel();
        var cancellation = new CancellationTokenSource(); _searchCancellation = cancellation;
        SearchButton.IsEnabled = false; SearchHint.Text = "正在搜索，请稍候…";
        try
        {
            var results = await _search.SearchAsync(query, _settings, cancellation.Token);
            if (cancellation.IsCancellationRequested || _closed) return;
            ResultsList.ItemsSource = results;
            SearchHint.Text = results.Length == 0 ? "未找到结果，请补充城市或详细地址；国内地点建议使用高德搜索。" : $"找到 {results.Length} 个地点，选择结果后点击应用定位";
            _settings.SearchHistory.RemoveAll(item => item == query);
            _settings.SearchHistory.Insert(0, query);
            _settings.SearchHistory = _settings.SearchHistory.Take(15).ToList();
            _settings.Save(); LoadHistory();
            if (results.Length > 0) ResultsList.SelectedIndex = 0;
        }
        catch (OperationCanceledException) { }
        catch (Exception ex) { if (!_closed) SearchHint.Text = ChineseText.Error(ex); }
        finally { if (ReferenceEquals(_searchCancellation, cancellation)) { SearchButton.IsEnabled = true; _searchCancellation = null; } cancellation.Dispose(); }
    }

    private void Result_Selected(object sender, SelectionChangedEventArgs e)
    {
        if (ResultsList.SelectedItem is SearchPlace { HasCoordinates: true, Latitude: { } lat, Longitude: { } lon } place) Pick(lat, lon, place.Name);
    }
    private void LoadHistory() { HistoryBox.ItemsSource = _settings.SearchHistory.ToArray(); HistoryBox.Visibility = _settings.SearchHistory.Count > 0 ? Visibility.Visible : Visibility.Collapsed; }
    private void History_Changed(object sender, SelectionChangedEventArgs e) { if (HistoryBox.SelectedItem is string query) SearchBox.Text = query; }

    private async Task RefreshDevices()
    {
        RefreshButton.IsEnabled = false;
        DevicesHint.Text = "正在读取已配对设备…";
        try
        {
            _devices = await Task.Run(BluetoothDevices.GetDevices);
            if (_closed) return;
            FilterDevices();
            DevicesHint.Text = _devices.Count == 0 ? "未发现已配对设备，请先打开系统蓝牙设置进行配对。" : $"发现 {_devices.Count} 台设备，请选择你的 iPhone。";
        }
        catch (Exception ex) { if (!_closed) { DevicesHint.Text = ChineseText.Error(ex); AddLog("提示", DevicesHint.Text); } }
        finally { if (!_closed) RefreshButton.IsEnabled = true; }
    }
    private void FilterDevices()
    {
        var previous = (DevicesBox.SelectedItem as BluetoothDevice)?.Address;
        var devices = _devices.Where(device => ShowAllBox.IsChecked == true || device.LikelyApple).ToArray();
        DevicesBox.ItemsSource = devices;
        DevicesBox.SelectedItem = devices.FirstOrDefault(device => device.Address == previous) ?? devices.FirstOrDefault();
    }
    private async void Refresh_Click(object sender, RoutedEventArgs e) => await RefreshDevices();
    private void DeviceFilter_Changed(object sender, RoutedEventArgs e) { if (_initialized) FilterDevices(); }

    private async void Connect_Click(object sender, RoutedEventArgs e)
    {
        if (_connecting) return;
        if (DevicesBox.SelectedItem is not BluetoothDevice device) { Status("请先配对并选择一台 iPhone"); return; }
        if (_manager.Sessions.Any(session => session.Request.Mac == device.Address && (session.Running || session.Starting)))
        { Status("该设备已经连接或正在连接"); return; }
        if (_identity.Warning is not null) { MessageBox.Show(this, _identity.Detail + "\n请在设置中检查或导入身份。", "配件身份不可用", MessageBoxButton.OK, MessageBoxImage.Warning); return; }
        if (!ApplyTarget()) return;
        _connecting = true; ConnectButton.IsEnabled = false; ConnectButton.Content = "正在连接…";
        var rate = _settings.Rate;
        Status("正在连接 " + device.Name + "，最长等待 20 秒");
        try
        {
            var session = await Task.Run(() => _manager.Add(new RunRequest { Transport = "bt", Mac = device.Address, Label = device.Name, Rate = rate }));
            if (!_closed) { RefreshSessions(); Status(session.Error is null ? "蓝牙已连接，等待设备完成识别与认证" : ChineseText.Log(session.Error)); }
        }
        catch (Exception ex) { if (!_closed) ShowError(ex); }
        finally { _connecting = false; if (!_closed) { ConnectButton.IsEnabled = true; ConnectButton.Content = "连接设备"; } }
    }

    private void RefreshSessions()
    {
        if (_closed) return;
        var active = _manager.Sessions;
        foreach (var old in _sessions.Where(row => active.All(session => session.Id != row.Id)).ToArray()) _sessions.Remove(old);
        foreach (var session in active)
        {
            var row = _sessions.FirstOrDefault(item => item.Id == session.Id);
            if (row is null) { row = new SessionRow(session.Id, session.Label, session.Request.Mac ?? ""); _sessions.Add(row); }
            var error = session.Error;
            var status = error is not null ? "连接异常" : session.Starting ? "正在连接蓝牙…" : !session.Running ? "已停止"
                : session.LinkState == "Detect" ? "正在探测协议…" : session.LinkState == "Negotiate" ? "正在握手…"
                : !session.Identified ? "正在识别配件…" : !session.Authenticated ? "正在认证…"
                : session.Subscribed ? "正在发送定位" : "认证通过 · 等待订阅";
            row.Update(status, error is not null ? ChineseText.Log(error) : $"已发送 {session.Sent} 条定位消息",
                error is not null ? "#A84C34" : session.Subscribed && session.Authenticated ? "#146C5C" : "#A4742E");
        }
    }
    private async void Disconnect_Click(object sender, RoutedEventArgs e)
    {
        if (sender is Button { Tag: string id }) { await Task.Run(() => _manager.Remove(id)); if (!_closed) RefreshSessions(); }
    }
    private async void StopAll_Click(object sender, RoutedEventArgs e) { await Task.Run(_manager.StopAll); if (!_closed) { RefreshSessions(); Status("全部设备已停止"); } }
    private void BluetoothSettings_Click(object sender, RoutedEventArgs e) { try { Process.Start(new ProcessStartInfo("ms-settings:bluetooth") { UseShellExecute = true }); } catch (Exception ex) { ShowError(ex); } }

    private void SaveFavorite_Click(object sender, RoutedEventArgs e)
    {
        try
        {
            var lat = Number(LatitudeBox, "纬度", -90, 90); var lon = Number(LongitudeBox, "经度", -180, 180);
            var dialog = new NameDialog(_destination == "地图选点 / 手动输入" || _destination == "地图选点" ? $"{lat:F4}, {lon:F4}" : _destination) { Owner = this };
            if (dialog.ShowDialog() != true) return;
            _favorites.Add(dialog.FavoriteName, lat, lon, Number(AltitudeBox, "高度", -12000, 100000), Number(AccuracyBox, "精度", .1, 100000));
            LoadFavorites(); Status("已保存收藏位置");
        }
        catch (Exception ex) { ShowError(ex); }
    }
    private void LoadFavorites()
    {
        var favorites = _favorites.All.Select(f => new FavoriteRow(f.Id, f.Name, $"{f.Latitude:F5}, {f.Longitude:F5}", f)).ToArray();
        FavoritesList.ItemsSource = favorites;
        FavoritesHint.Text = favorites.Length == 0 ? "收藏常用地点，随时快速切换" : $"已收藏 {favorites.Length} 个位置，点击选择";
    }
    private void Favorite_Selected(object sender, SelectionChangedEventArgs e)
    {
        if (FavoritesList.SelectedItem is not FavoriteRow row) return;
        if (row.Value.Altitude.HasValue) AltitudeBox.Text = Format(row.Value.Altitude.Value);
        if (row.Value.Accuracy.HasValue) AccuracyBox.Text = Format(row.Value.Accuracy.Value);
        Pick(row.Value.Latitude, row.Value.Longitude, row.Name);
    }
    private void DeleteFavorite_Click(object sender, RoutedEventArgs e) { if (sender is Button { Tag: string id }) { _favorites.Remove(id); LoadFavorites(); e.Handled = true; } }
    private void Copy_Click(object sender, RoutedEventArgs e)
    {
        try { Clipboard.SetText($"{Format(Number(LatitudeBox, "纬度", -90, 90), "F6")},{Format(Number(LongitudeBox, "经度", -180, 180), "F6")}"); Status("WGS-84 坐标已复制"); }
        catch (Exception ex) { ShowError(ex); }
    }
    private async void Datum_Changed(object sender, SelectionChangedEventArgs e)
    {
        if (!_initialized || _loading) return;
        _settings.Datum = DatumBox.SelectedIndex == 0 ? "gcj" : "wgs";
        _settings.Save(); await MapScript("setDatum(" + JsonSerializer.Serialize(_settings.Datum) + ")");
    }
    private void RotateIdentity_Click(object sender, RoutedEventArgs e) { _manager.RotateIdentity(null); UpdateIdentity(); Status("配件名称、序列号和报告地址已更新，对之后新连接的设备生效"); }
    private void UpdateIdentity() { IdentityStatus.Text = _identity.Detail; AccessoryText.Text = $"序列号 {_manager.Profile.Serial}\n报告地址 {_manager.Profile.AdapterAddress ?? "本机地址"}"; }
    private void Settings_Click(object sender, RoutedEventArgs e)
    {
        new SettingsWindow(_settings, _identity) { Owner = this }.ShowDialog(); UpdateIdentity();
        SearchHint.Text = _settings.SearchProvider == "amap" || (_settings.SearchProvider == "auto" && _settings.AmapKey.Length > 0)
            ? "当前使用高德搜索，可输入地名或详细地址。" : "当前使用免 Key 开放地图搜索，也支持直接输入坐标。";
    }
    private void Help_Click(object sender, RoutedEventArgs e) => new HelpWindow { Owner = this }.ShowDialog();
    private void Logs_Click(object sender, RoutedEventArgs e) => LogPanel.Visibility = LogPanel.Visibility == Visibility.Visible ? Visibility.Collapsed : Visibility.Visible;

    private void OnLog(DateTime timestamp, string level, string message)
    {
        if (_closed) return;
        var label = level.Trim() switch { "error" => "错误", "warn" => "提示", "step" => "进度", "ok" => "成功", "trace" => "详细", _ => "信息" };
        Dispatcher.BeginInvoke(() => { if (!_closed) AddLog(label, ChineseText.Log(message), timestamp); });
    }
    private void AddLog(string label, string text, DateTime? time = null)
    {
        var line = $"{time ?? DateTime.Now:HH:mm:ss} [{label}] {text}";
        _logs.Add(line); if (_logs.Count > 600) _logs.RemoveRange(0, _logs.Count - 600);
        LogBox.Text = string.Join(Environment.NewLine, _logs); LogBox.ScrollToEnd();
    }
    private void Status(string text) { StatusText.Text = text; }
    private void ShowError(Exception ex) { var text = ChineseText.Error(ex); Status(text); AddLog("错误", text); MessageBox.Show(this, text, "操作未完成", MessageBoxButton.OK, MessageBoxImage.Warning); }
    private void ClearLogs_Click(object sender, RoutedEventArgs e) { _logs.Clear(); LogBox.Clear(); }
    private void ExportLogs_Click(object sender, RoutedEventArgs e)
    {
        var dialog = new SaveFileDialog { Title = "导出诊断日志", Filter = "文本文件|*.txt", FileName = "随行定位日志-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".txt" };
        if (dialog.ShowDialog(this) != true) return;
        try { File.WriteAllLines(dialog.FileName, _logs, Encoding.UTF8); Status("诊断日志已导出"); } catch (Exception ex) { ShowError(ex); }
    }

    private void Window_Closing(object? sender, CancelEventArgs e)
    {
        if (_closed) return;
        _closed = true; _poll.Stop(); _searchCancellation?.Cancel();
        Log.Emitted -= OnLog;
        _manager.Dispose(); _search.Dispose(); MapView.Dispose();
    }

    private async Task RunSmokeTest()
    {
        try
        {
            for (var i = 0; !_mapReady && i < 40; i++) await Task.Delay(250);
            var result = new { title = Title, mapReady = _mapReady, identityValid = _identity.Warning is null,
                targetValid = ApplyTarget(false), sessions = _sessions.Count, consoleWindow = GetConsoleWindow() != IntPtr.Zero,
                logs = _logs.ToArray(), time = DateTimeOffset.Now };
            File.WriteAllText(Path.Combine(DesktopSettings.DataDirectory, "smoke-result.json"), JsonSerializer.Serialize(result, new JsonSerializerOptions { WriteIndented = true }));
        }
        catch (Exception ex) { File.WriteAllText(Path.Combine(DesktopSettings.DataDirectory, "smoke-error.txt"), ex.ToString()); }
        if (!_args.Contains("--keep-open")) Close();
    }
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern IntPtr GetConsoleWindow();
}

internal sealed class SessionRow(string id, string name, string address) : INotifyPropertyChanged
{
    public string Id { get; } = id;
    public string Name { get; } = name;
    public string Address { get; } = address;
    public string Status { get; private set; } = "正在连接…";
    public string Detail { get; private set; } = "";
    public string Color { get; private set; } = "#A4742E";
    public event PropertyChangedEventHandler? PropertyChanged;
    public void Update(string status, string detail, string color)
    {
        if (Status == status && Detail == detail && Color == color) return;
        Status = status; Detail = detail; Color = color; PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(null));
    }
}
internal sealed record FavoriteRow(string Id, string Name, string Position, Favorite Value);
internal sealed class ActionCommand(Action action) : ICommand
{
    public bool CanExecute(object? parameter) => true;
    public void Execute(object? parameter) => action();
    public event EventHandler? CanExecuteChanged { add { } remove { } }
}

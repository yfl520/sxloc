using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using Iap2Loc;
using Iap2Loc.Desktop;
using Iap2Loc.Engine;
using Iap2Loc.Protocol;
using Iap2Loc.Transport;

namespace SuixingLoc.Core;

internal static class Program
{
    private static readonly JsonSerializerOptions Json = new() { PropertyNamingPolicy = JsonNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true };
    private static readonly object OutputGate = new();
    private static readonly object SettingsGate = new();
    private static readonly object SearchGate = new();
    private static readonly SemaphoreSlim ConnectGate = new(1, 1);
    private static readonly PlaceSearchService Search = new();
    private static readonly UsbDeveloperService Usb = new();
    private static DesktopSettings Settings = null!;
    private static DesktopIdentityProvider Identity = null!;
    private static SessionManager Manager = null!;
    private static FavoriteStore Favorites = null!;
    private static CancellationTokenSource? SearchCancellation;
    private static long SearchId, LatestSearchId;
    private static TextWriter Output = null!;
    private static volatile bool ShuttingDown;
    private static string? StartupWarning;

    public static async Task Main(string[] args)
    {
        if (args is ["--apply-update", var plan])
        {
            await DesktopUpdater.RunHelper(plan);
            return;
        }
        // The Flutter host redirects these anonymous pipes. No HTTP listener or browser is used.
        Console.InputEncoding = new UTF8Encoding(false);
        Console.OutputEncoding = new UTF8Encoding(false);
        Output = Console.Out;
        Console.SetOut(TextWriter.Null);
        CultureInfo.DefaultThreadCurrentCulture = CultureInfo.GetCultureInfo("zh-CN");
        CultureInfo.DefaultThreadCurrentUICulture = CultureInfo.GetCultureInfo("zh-CN");
        try
        {
            Settings = DesktopSettings.Load();
            Directory.CreateDirectory(DesktopSettings.DataDirectory);
            Identity = new DesktopIdentityProvider(Settings);
            IdentitySource.Provider = Identity;
            Identity.Prime();
            var config = AppConfig.Load(Path.Combine(DesktopSettings.DataDirectory, "iap2loc.json"));
            StartupWarning = string.Join(" ", new[] { Settings.LoadWarning, config.LoadWarning }.Where(s => s is not null));
            config.PrepareForRun(null);
            Manager = new SessionManager(Settings.Latitude, Settings.Longitude, config);
            Manager.ApplyTarget(Settings.ToTargetUpdate(), Settings.Rate);
            Usb.Remember(Manager.Target.Snapshot());
            Favorites = new FavoriteStore(config);
            string? line;
            var running = new List<Task>();
            while ((line = await Console.In.ReadLineAsync()) is not null)
            {
                if (line.Length > 1024 * 1024) continue;
                if (ShuttingDown) break;
                var request = line;
                running.RemoveAll(task => task.IsCompleted);
                // Bound work queued by a faulty host, while allowing stop during a slow connection.
                if (running.Count >= 32) await Task.WhenAny(running);
                running.Add(Task.Run(() => Handle(request)));
            }
        }
        catch (Exception ex) { Send(new { eventName = "fatal", error = ChineseText.Error(ex) }); }
        finally
        {
            ShuttingDown = true;
            CancelSearch();
            await Usb.DisposeAsync();
            Manager?.Dispose();
            Search.Dispose();
        }
    }

    private static async Task Handle(string line)
    {
        int? id = null;
        try
        {
            using var document = JsonDocument.Parse(line);
            var root = document.RootElement;
            id = root.GetProperty("id").GetInt32();
            var method = root.GetProperty("method").GetString();
            var args = root.TryGetProperty("args", out var value) ? value : default;
            object? result = method switch
            {
                "init" or "snapshot" => Snapshot(),
                "devices" => BluetoothDevices.GetDevices(),
                "search" => await SearchPlaces(args, "legacy"),
                "search.places" => await SearchPlaces(args, "places"),
                "search.resolve" => await SearchPlaces(args, "resolve"),
                "cancelSearch" => CancelSearch(args),
                "apply" => await Apply(args),
                "usb.devices" => await Usb.Devices(),
                "usb.connect" => await Usb.Connect(Text(args, "udid")),
                "usb.revealDeveloperMode" => await Usb.RevealDeveloperMode(Text(args, "udid")),
                "usb.stop" => await Usb.Stop(),
                "usb.clearError" => await Usb.ClearError(),
                "connect" => await Connect(args),
                "disconnect" => Manager.Remove(Text(args, "id")),
                "stopAll" => await StopAll(),
                "favorites.add" => Favorites.Add(Text(args, "name"), Number(args, "latitude"), Number(args, "longitude"), Number(args, "altitude", 10), Number(args, "accuracy", 5)),
                "favorites.remove" => Favorites.Remove(Text(args, "id")),
                "settings.save" => SaveSettings(args),
                "identity.import" => ImportIdentity(Text(args, "path")),
                "identity.builtin" => UseBuiltIn(),
                "identity.check" => CheckIdentity(),
                "identity.rotate" => Manager.RotateIdentity(null),
                "openData" => Open(DesktopSettings.DataDirectory),
                "openGithub" => OpenGithub(Text(args, "url")),
                "update.directory" => DesktopUpdater.DownloadDirectory,
                "update.install" => await DesktopUpdater.Prepare(
                    Text(args, "path"), Text(args, "sha256"),
                    Integer(args, "appPid", 0, 1, int.MaxValue),
                    Text(args, "version"), Integer(args, "buildNumber", 0, 1, int.MaxValue)),
                "openBluetooth" => Open("ms-settings:bluetooth"),
                "shutdown" => await Shutdown(),
                _ => throw new ArgumentException("不支持的操作"),
            };
            Send(new { id, result });
        }
        catch (OperationCanceledException) { Send(new { id, error = "搜索已取消", cancelled = true }); }
        catch (Exception ex) { Send(new { id, error = ChineseText.Error(ex) }); }
    }

    private static object Snapshot()
    {
        lock (SettingsGate)
        {
            return new
            {
                target = Manager.Target.Snapshot(), rate = Settings.Rate,
                startupWarning = StartupWarning,
                applyBlockedReason = ApplyBlockedReason(),
                settings = new { Settings.SearchProvider, Settings.SearchCity, Settings.PhotonEndpoint,
                    hasAmapKey = Settings.AmapKey.Length > 0, Settings.Datum, Settings.SearchHistory },
                identity = new { Identity.Name, Identity.Detail, valid = Identity.Warning is null,
                    Manager.Profile.Serial, Manager.Profile.AdapterAddress },
                favorites = Favorites.All,
                usb = Usb.Snapshot(),
                sessions = Manager.Sessions.Select(session => new
                {
                    session.Id, session.Label, session.Request.Mac, session.Running, session.Starting,
                    session.Authenticated, session.Identified, session.Subscribed, session.Sent,
                    report = session.LastQueuedReport,
                    sendError = session.SendError is { } sendError ? ChineseText.Log(sendError) : null,
                    error = session.Error is { } error ? ChineseText.Log(error) : null,
                    status = SessionStatus(session),
                }).ToArray(),
            };
        }
    }

    private static string SessionStatus(RunSession session) => session.Error is not null ? "连接异常"
        : session.Starting ? "正在连接" : !session.Running ? "已停止"
        : session.LinkState == "Detect" ? "正在探测协议" : session.LinkState == "Negotiate" ? "正在握手"
        : !session.Identified ? "正在识别配件" : !session.Authenticated ? "正在认证"
        : session.Subscribed ? "正在发送定位" : "已认证 · 等待订阅";

    private static async Task<object> SearchPlaces(JsonElement args, string mode)
    {
        var cancellation = new CancellationTokenSource();
        var searchId = RequestSearchId(args);
        lock (SearchGate)
        {
            if (searchId is { } id && id <= LatestSearchId)
            {
                cancellation.Dispose();
                throw new OperationCanceledException();
            }
            if (searchId is { } current) LatestSearchId = current;
            SearchCancellation?.Cancel();
            SearchCancellation = cancellation;
            SearchId = searchId ?? 0;
        }
        try
        {
            var query = Text(args, "query").Trim();
            DesktopSettings settings;
            lock (SettingsGate) settings = new DesktopSettings
            {
                SearchProvider = Settings.SearchProvider, SearchCity = Settings.SearchCity,
                ProtectedAmapKey = Settings.ProtectedAmapKey, PhotonEndpoint = Settings.PhotonEndpoint,
            };
            var suggestions = Boolean(args, "suggestions", false);
            PlaceSearchResult results;
            if (mode == "resolve")
            {
                var place = args.TryGetProperty("place", out var value) ? value.Deserialize<SearchPlace>(Json) : null;
                if (place is null) throw new ArgumentException("请选择需要查找坐标的地点");
                results = await Search.ResolveAsync(place, settings, cancellation.Token);
            }
            else results = await Search.SearchDetailedAsync(query, settings, cancellation.Token, suggestions);
            lock (SearchGate)
            {
                cancellation.Token.ThrowIfCancellationRequested();
                if (mode != "resolve" && !suggestions && query.Length > 0)
                {
                    lock (SettingsGate)
                    {
                        if (!Settings.RememberSearch(query))
                            results = results with { Notice = string.Join(" ", new[] { results.Notice,
                                "已找到搜索结果，但搜索历史未能保存，请检查磁盘空间和目录权限。" }.Where(s => s is not null)) };
                    }
                }
            }
            return mode == "legacy" ? results.Places.Where(p => p.HasCoordinates).ToArray() : results;
        }
        finally
        {
            lock (SearchGate)
            {
                if (ReferenceEquals(SearchCancellation, cancellation)) SearchCancellation = null;
                cancellation.Dispose();
            }
        }
    }

    // A delayed cancellation may invalidate its own request, never a newer one.
    private static long? RequestSearchId(JsonElement args) => args.ValueKind == JsonValueKind.Object
        && args.TryGetProperty("searchId", out var value) && value.TryGetInt64(out var id) && id > 0 ? id : null;
    private static object CancelSearch(JsonElement args = default)
    {
        lock (SearchGate)
        {
            var id = RequestSearchId(args);
            if (id is { } value) LatestSearchId = Math.Max(LatestSearchId, value);
            if (id is null || id >= SearchId) SearchCancellation?.Cancel();
        }
        return true;
    }

    private static string? ApplyBlockedReason()
    {
        var usb = Usb.Snapshot();
        var phase = usb.TryGetProperty("phase", out var value) ? value.GetString() : null;
        var usbFailed = usb.TryGetProperty("error", out var error) && error.ValueKind != JsonValueKind.Null;
        return ApplyAvailability.BlockedReason(Manager.Sessions.Select(s =>
            new PhoneConnection(s.Running, s.Starting, s.Identified, s.Authenticated, s.Error is not null)), phase, usbFailed);
    }

    private static async Task<object> Apply(JsonElement args)
    {
        TargetState target;
        lock (SettingsGate)
        {
            // Recheck in the core so stale UI state cannot apply while disconnected.
            if (ApplyBlockedReason() is { } reason) throw new InvalidOperationException(reason);
            var old = Manager.Target.Snapshot();
            var update = new TargetUpdate
            {
                Latitude = Number(args, "latitude", old.Latitude), Longitude = Number(args, "longitude", old.Longitude),
                Altitude = Range(args, "altitude", old.Altitude ?? 10, -12000, 100000), Accuracy = Range(args, "accuracy", old.Accuracy ?? 5, .1, 100000),
                Speed = Range(args, "speed", old.Speed ?? 0, 0, 1000), Bearing = Range(args, "bearing", old.Bearing ?? 0, 0, 359.999999),
                Quality = Integer(args, "quality", old.Quality, 0, 8), Satellites = Integer(args, "satellites", old.Satellites, 0, 99),
                JitterPosition = Boolean(args, "jitterPosition", old.JitterPosition), JitterAccuracy = Boolean(args, "jitterAccuracy", old.JitterAccuracy),
                JitterMeters = Range(args, "jitterMeters", old.JitterMeters, 0, 10000),
                AccuracyMin = Range(args, "accuracyMin", old.AccuracyMin, .1, 100000), AccuracyMax = Range(args, "accuracyMax", old.AccuracyMax, .1, 100000),
            };
            var rate = Integer(args, "rate", Settings.Rate, 10, 60000);
            // Validate the whole update before saving or touching the live Bluetooth target.
            var validated = new LocationTarget(update.Latitude!.Value, update.Longitude!.Value);
            validated.Apply(update);
            var next = Settings.Copy();
            next.Latitude = update.Latitude.Value; next.Longitude = update.Longitude.Value;
            next.Altitude = update.Altitude!.Value; next.Accuracy = update.Accuracy!.Value;
            next.Speed = update.Speed!.Value; next.Bearing = update.Bearing!.Value;
            next.Quality = update.Quality!.Value; next.Satellites = update.Satellites!.Value; next.Rate = rate;
            next.JitterPosition = update.JitterPosition!.Value; next.JitterAccuracy = update.JitterAccuracy!.Value;
            next.JitterMeters = update.JitterMeters!.Value; next.AccuracyMin = update.AccuracyMin!.Value; next.AccuracyMax = update.AccuracyMax!.Value;
            Settings.Commit(next);
            Manager.ApplyTarget(update, rate);
            target = Manager.Target.Snapshot();
        }
        await Usb.UpdateTarget(target);
        return target;
    }

    private static async Task<object> Connect(JsonElement args)
    {
        if (!await ConnectGate.WaitAsync(0)) throw new InvalidOperationException("正在连接设备，请稍候");
        try
        {
            if (Identity.Warning is not null) throw new InvalidOperationException(Identity.Detail);
            var mac = Text(args, "mac");
            if (Manager.Sessions.Any(s => s.Request.Mac == mac && (s.Starting || s.Running)))
                throw new InvalidOperationException("该设备已经连接或正在连接");
            var session = Manager.Add(new RunRequest { Mac = mac, Label = Text(args, "name"), Rate = Settings.Rate });
            if (session.Error is { } error) throw new IOException(ChineseText.Log(error));
            return true;
        }
        finally { ConnectGate.Release(); }
    }

    private static object SaveSettings(JsonElement args)
    {
        lock (SettingsGate)
        {
            var provider = Text(args, "searchProvider", Settings.SearchProvider);
            if (provider is not ("auto" or "amap" or "photon")) throw new ArgumentException("搜索服务无效");
            var key = Text(args, "amapKey", "").Trim();
            var clear = Boolean(args, "clearAmapKey", false);
            if (provider == "amap" && (clear || (key.Length == 0 && Settings.AmapKey.Length == 0)))
                throw new ArgumentException("请填写高德 Web 服务 Key");
            var endpoint = Text(args, "photonEndpoint", Settings.PhotonEndpoint).Trim();
            if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var uri) || (uri.Scheme != "https" && !(uri.IsLoopback && uri.Scheme == "http")))
                throw new ArgumentException("开放地图服务地址必须是 HTTPS，或本机 HTTP 地址");
            var datum = Text(args, "datum", Settings.Datum);
            if (datum is not ("gcj" or "wgs")) throw new ArgumentException("地图类型无效");
            var next = Settings.Copy();
            next.SearchProvider = provider; next.SearchCity = Text(args, "searchCity", Settings.SearchCity).Trim();
            next.PhotonEndpoint = endpoint; next.Datum = datum;
            if (clear) next.AmapKey = ""; else if (key.Length > 0) next.AmapKey = key;
            Settings.Commit(next);
            return true;
        }
    }

    private static object ImportIdentity(string path) { lock (SettingsGate) { Identity.Import(path); return true; } }
    private static object UseBuiltIn() { lock (SettingsGate) { Identity.UseBuiltIn(); return true; } }
    private static object CheckIdentity() { Identity.Prime(); return true; }
    private static async Task<object> StopAll() { Manager.StopAll(); await Usb.Stop(); return true; }
    private static async Task<object> Shutdown() { ShuttingDown = true; return await StopAll(); }
    private static object Open(string path) { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); return true; }
    private static object OpenGithub(string url)
    {
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != "https" || uri.Host != "github.com"
            || uri.UserInfo.Length > 0 || !uri.IsDefaultPort || uri.AbsolutePath.Split('/', StringSplitOptions.RemoveEmptyEntries).Length != 2
            || uri.Query.Length > 0 || uri.Fragment.Length > 0) throw new ArgumentException("GitHub 地址无效");
        return Open(uri.AbsoluteUri);
    }

    private static void Send(object value) { lock (OutputGate) { Output.WriteLine(JsonSerializer.Serialize(value, Json)); Output.Flush(); } }
    private static string Text(JsonElement root, string name, string fallback = "") => root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? fallback : fallback;
    private static double Number(JsonElement root, string name, double fallback = 0) => root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out var value) ? value.GetDouble() : fallback;
    private static bool Boolean(JsonElement root, string name, bool fallback) => root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out var value) ? value.GetBoolean() : fallback;
    private static double Range(JsonElement root, string name, double fallback, double min, double max)
    {
        var number = Number(root, name, fallback);
        if (!double.IsFinite(number) || number < min || number > max) throw new ArgumentException("定位参数超出允许范围");
        return number;
    }
    private static int Integer(JsonElement root, string name, int fallback, int min, int max)
    {
        var number = Range(root, name, fallback, min, max);
        if (number != Math.Truncate(number)) throw new ArgumentException("周期、卫星数和质量必须是整数");
        return (int)number;
    }
}

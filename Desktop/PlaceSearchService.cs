using System.Collections.Concurrent;
using System.Globalization;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Iap2Loc.Desktop;

internal sealed record SearchPlace(string Name, string Address, double? Latitude, double? Longitude, string Source)
{
    public string Id { get; init; } = "";
    public string Region { get; init; } = "";
    public string Adcode { get; init; } = "";
    public string Category { get; init; } = "";
    public bool HasCoordinates => Latitude is { } lat && Longitude is { } lon && double.IsFinite(lat) && double.IsFinite(lon) && Math.Abs(lat) <= 90 && Math.Abs(lon) <= 180;
    public string CoordinateText => HasCoordinates ? $"{Latitude:F6}, {Longitude:F6} · {Source}" : "点击查找这个地点的坐标";
}

internal sealed record PlaceSearchResult(SearchPlace[] Places, string Source, string? Notice = null, bool NeedsConfirmation = false);

internal sealed class PlaceSearchService : IDisposable
{
    private sealed record Options(string Provider, string Key, string City, string Endpoint)
    {
        public bool UseAmap => Provider == "amap" || (Provider == "auto" && Key.Length > 0);
        public static Options From(DesktopSettings settings) => new(settings.SearchProvider, settings.AmapKey, settings.SearchCity.Trim(), settings.PhotonEndpoint);
    }
    private sealed record CacheEntry(PlaceSearchResult Result, long Expires);
    private readonly HttpClient _http;
    private readonly SemaphoreSlim _requestGate = new(1, 1);
    private readonly ConcurrentDictionary<string, CacheEntry> _cache = new();
    private readonly TimeSpan _interval, _requestTimeout;
    private long _lastRequest;

    public PlaceSearchService(HttpMessageHandler? handler = null, TimeSpan? requestInterval = null, TimeSpan? requestTimeout = null)
    {
        _http = handler is null ? new HttpClient() : new HttpClient(handler);
        _http.Timeout = Timeout.InfiniteTimeSpan;
        _http.MaxResponseContentBufferSize = 2 * 1024 * 1024;
        _http.DefaultRequestHeaders.UserAgent.ParseAdd("SuixingLoc/1.1 (Windows desktop; place search)");
        _http.DefaultRequestHeaders.AcceptLanguage.ParseAdd("zh-CN,zh;q=0.9,en;q=0.6");
        _interval = requestInterval ?? TimeSpan.FromMilliseconds(1100);
        _requestTimeout = requestTimeout ?? TimeSpan.FromSeconds(5);
    }

    public static SearchPlace? ParseCoordinate(string query)
    {
        var text = query.Trim();
        var gcj = Regex.IsMatch(text, @"^(?:gcj|高德)[:：]", RegexOptions.IgnoreCase);
        text = Regex.Replace(text, @"^(?:wgs(?:84)?|gcj|高德)[:：]\s*", "", RegexOptions.IgnoreCase);
        var match = Regex.Match(text, @"^\s*([+-]?\d+(?:\.\d+)?)\s*[,，;；\s]\s*([+-]?\d+(?:\.\d+)?)\s*$");
        if (!match.Success) return null;
        var lat = double.Parse(match.Groups[1].Value, CultureInfo.InvariantCulture);
        var lon = double.Parse(match.Groups[2].Value, CultureInfo.InvariantCulture);
        if (Math.Abs(lat) > 90 && Math.Abs(lat) <= 180 && Math.Abs(lon) <= 90) (lat, lon) = (lon, lat);
        if (!double.IsFinite(lat) || !double.IsFinite(lon) || Math.Abs(lat) > 90 || Math.Abs(lon) > 180) throw new ArgumentException("坐标超出范围，请使用“纬度,经度”格式");
        if (gcj) (lat, lon) = CoordinateConverter.GcjToWgs(lat, lon);
        return new SearchPlace("输入的坐标", gcj ? "已从高德 GCJ-02 转换为 WGS-84" : "WGS-84 坐标，可直接应用", lat, lon, "坐标解析");
    }

    // Kept for the legacy WPF client. Flutter uses the structured result below.
    public async Task<SearchPlace[]> SearchAsync(string query, DesktopSettings settings, CancellationToken token)
        => (await SearchDetailedAsync(query, settings, token)).Places.Where(p => p.HasCoordinates).ToArray();

    public async Task<PlaceSearchResult> SearchDetailedAsync(string query, DesktopSettings settings, CancellationToken token, bool suggestions = false)
    {
        token.ThrowIfCancellationRequested();
        query = query.Trim();
        if (query.Length == 0) return new([], "");
        if (query.Length > 200) throw new ArgumentException("搜索内容过长，请控制在 200 字以内");
        if (ParseCoordinate(query) is { } coordinate) return new([coordinate], "坐标解析");
        var options = Options.From(settings);
        if (options.UseAmap && options.Key.Length == 0) throw new InvalidOperationException("请先在设置中填写高德 Web 服务 Key，或选择自动／开放地图搜索");
        var fingerprint = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(options.Key)));
        var cacheKey = JsonSerializer.Serialize(new { options.Provider, options.Endpoint, options.City, fingerprint, query, suggestions });
        return await Run(async ct =>
        {
            ct.ThrowIfCancellationRequested();
            if (_cache.TryGetValue(cacheKey, out var cached) && cached.Expires > Environment.TickCount64) return cached.Result;
            var result = await SearchProviders(query, options, suggestions, ct);
            ct.ThrowIfCancellationRequested();
            // Do not hide recovery from a transient outage or a changed API credential.
            if (result.Places.Length > 0 && result.Notice is null)
            {
                if (_cache.Count >= 150) _cache.Clear();
                _cache[cacheKey] = new(result, Environment.TickCount64 + 300000);
            }
            return result;
        }, token);
    }

    private async Task<PlaceSearchResult> SearchProviders(string query, Options options, bool suggestions, CancellationToken token)
    {
        if (!options.UseAmap) return new(await SearchPhoton(query, options.City, options.Endpoint, token), "开放地图 · © OpenStreetMap");
        SearchPlace[] places = [];
        Exception? amapError = null;
        try
        {
            places = await SearchAmap(query, options, suggestions, token);
            if (options.Provider != "auto" || places.Any(p => p.HasCoordinates) || (suggestions && places.Length > 0)) return new(places, "高德搜索");
        }
        catch (Exception ex) when (Recoverable(ex))
        {
            if (options.Provider != "auto") throw;
            amapError = ex;
        }
        try
        {
            var extra = await SearchPhoton(query, options.City, options.Endpoint, token);
            return new(Merge(places.Concat(extra), query), extra.Length > 0 ? "开放地图 · © OpenStreetMap" : "高德搜索",
                amapError is null ? "高德暂无可用坐标，已补查开放地图。" : amapError.Message + " 已改用开放地图。");
        }
        catch (Exception ex) when (Recoverable(ex) && places.Length > 0)
        {
            return new(places, "高德搜索", "开放地图暂不可用，仍可点击已有建议继续查找。");
        }
    }

    public async Task<PlaceSearchResult> ResolveAsync(SearchPlace place, DesktopSettings settings, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (place.HasCoordinates) return new([place], place.Source);
        place = place with { Name = Clean(place.Name, 200), Address = Clean(place.Address, 400), Region = Clean(place.Region, 200), Id = Clean(place.Id, 100), Adcode = Clean(place.Adcode, 20) };
        if (place.Name.Length == 0) throw new ArgumentException("地点名称为空，请重新搜索或在地图上选点");
        var query = ContextualQuery(place);
        var options = Options.From(settings);
        if (options.UseAmap && options.Key.Length == 0) throw new InvalidOperationException("请先填写高德 Web 服务 Key，或选择自动／开放地图搜索");
        return await Run(async ct =>
        {
            SearchPlace[] alternatives = [];
            Exception? lastError = null;
            var city = place.Adcode.Length > 0 ? place.Adcode : place.Region.Length > 0 ? "" : options.City;
            if (options.UseAmap)
            {
                if (place.Id.Length > 0 && place.Source == "高德搜索")
                {
                    try
                    {
                        var details = (await AmapPlaces("/v3/place/detail", new() { ["id"] = place.Id, ["extensions"] = "all" }, options.Key, false, ct))
                            .Where(p => p.HasCoordinates && CompatibleRegion(place.Adcode, p.Adcode)).ToArray();
                        if (details.Length > 0) return new(details, "高德搜索", MatchesContext(place, details[0]) ? null : "请核对地点所在地区后选择。", details.Length > 1 || !MatchesContext(place, details[0]));
                    }
                    catch (Exception ex) when (Recoverable(ex)) { lastError = ex; }
                }
                try
                {
                    alternatives = (await AmapText(query, city, options.Key, place.Adcode.Length > 0, ct)).Where(p => p.HasCoordinates && CompatibleRegion(place.Adcode, p.Adcode)).ToArray();
                    var exact = alternatives.Where(p => p.Name == place.Name && MatchesContext(place, p)).ToArray();
                    if (exact.Length > 0) return new(exact, "高德搜索", exact.Length > 1 ? "找到多个同名地点，请核对地址后选择。" : null, exact.Length > 1);
                }
                catch (Exception ex) when (Recoverable(ex)) { lastError = ex; }
                try
                {
                    var geocodes = (await AmapGeocode(query, city, options.Key, ct)).Where(p => CompatibleRegion(place.Adcode, p.Adcode)).ToArray();
                    if (geocodes.Length > 0) return new(geocodes, "高德地址解析", "已按完整地址找到位置，请核对地址和匹配级别后选择。", true);
                }
                catch (Exception ex) when (Recoverable(ex)) { lastError = ex; }
            }
            if (options.Provider != "amap")
            {
                try
                {
                    var extra = await SearchPhoton(query, place.Region.Length == 0 && place.Address.Length == 0 ? options.City : "", options.Endpoint, ct);
                    if (extra.Length > 0) return new(Merge(extra.Concat(alternatives), place.Name), "开放地图 · © OpenStreetMap", "已补查开放地图，请核对地区后选择具体位置。", true);
                }
                catch (Exception ex) when (Recoverable(ex)) { lastError = ex; }
            }
            if (alternatives.Length > 0) return new(alternatives, "高德搜索", "找到相关地点，请核对名称和地址后选择。", true);
            if (lastError is not null) throw new IOException(lastError.Message + " 仍可在地图上选点。");
            return new([], "地址补查", "暂未查到这个地点的坐标，可补充乡镇、街道，或直接在地图上选点。");
        }, token);
    }

    public static string ContextualQuery(SearchPlace place)
    {
        var query = "";
        foreach (var part in new[] { place.Region, place.Address, place.Name })
        {
            var value = part.Trim();
            if (value.Length == 0 || query.Contains(value, StringComparison.Ordinal)) continue;
            query = value.Contains(query, StringComparison.Ordinal) ? value : query + value;
        }
        return query;
    }

    private static bool SameRegion(string expected, string actual)
    {
        if (expected.Length == 0) return true;
        if (actual.Length == 0) return false;
        if (expected.Length == 6 && actual.Length == 6)
        {
            var length = expected.EndsWith("0000", StringComparison.Ordinal) ? 2 : expected.EndsWith("00", StringComparison.Ordinal) ? 4 : 6;
            return expected[..length] == actual[..length];
        }
        return expected == actual;
    }
    private static bool CompatibleRegion(string expected, string actual) => actual.Length == 0 || SameRegion(expected, actual);
    private static bool MatchesContext(SearchPlace expected, SearchPlace actual)
        => expected.Adcode.Length > 0 ? SameRegion(expected.Adcode, actual.Adcode)
        : expected.Region.Length == 0 || Regex.Replace(actual.Region, @"\s+|·", "").Contains(Regex.Replace(expected.Region, @"\s+|·", ""), StringComparison.Ordinal);

    private async Task<SearchPlace[]> SearchAmap(string query, Options options, bool suggestions, CancellationToken token)
    {
        if (suggestions) return await AmapTips(query, options.City, options.Key, token);
        var found = await AmapText(query, options.City, options.Key, false, token);
        if (found.Length == 0)
        {
            Exception? error = null;
            try { found = await AmapTips(query, options.City, options.Key, token); }
            catch (Exception ex) when (Recoverable(ex)) { error = ex; }
            try { found = Merge(found.Concat(await AmapGeocode(query, options.City, options.Key, token)), query); }
            catch (Exception ex) when (Recoverable(ex)) { error = ex; }
            if (found.Length == 0 && error is not null) throw error;
        }
        else if (Regex.IsMatch(query, @"村|乡|镇|街道|\d+号") && !found.Any(p => p.Name == query || (p.Name.Length > 1 && query.EndsWith(p.Name, StringComparison.Ordinal))))
        {
            try { found = Merge(found.Concat(await AmapGeocode(query, options.City, options.Key, token)), query); }
            catch (Exception ex) when (Recoverable(ex)) { /* Optional enrichment must keep usable POIs. */ }
        }
        return found;
    }

    private Task<SearchPlace[]> AmapText(string query, string city, string key, bool strict, CancellationToken token)
        => AmapPlaces("/v3/place/text", new() { ["keywords"] = query, ["city"] = city, ["citylimit"] = strict ? "true" : "false", ["offset"] = "20", ["page"] = "1", ["extensions"] = "all" }, key, false, token);
    private Task<SearchPlace[]> AmapTips(string query, string city, string key, CancellationToken token)
        => AmapPlaces("/v3/assistant/inputtips", new() { ["keywords"] = query, ["city"] = city, ["citylimit"] = "false", ["datatype"] = "all" }, key, true, token);

    private async Task<SearchPlace[]> AmapPlaces(string path, Dictionary<string, string> parameters, string key, bool tips, CancellationToken token)
    {
        parameters["key"] = key; parameters["output"] = "json";
        using var doc = await GetJson(AmapUrl(path, parameters), token);
        CheckAmap(doc.RootElement);
        var found = new List<SearchPlace>();
        foreach (var item in Items(doc.RootElement, tips ? "tips" : "pois"))
        {
            var name = Text(item, "name");
            if (name.Length == 0) continue;
            var region = tips ? Text(item, "district") : Join(item, "pname", "cityname", "adname");
            var address = JoinParts(region, Text(item, "address"));
            var valid = ParseAmapLocation(Text(item, "location"), out var point);
            if (!tips && !valid) continue;
            found.Add(new(name, address, valid ? point.Lat : null, valid ? point.Lon : null, "高德搜索")
            {
                Id = Text(item, "id"), Region = region, Adcode = Text(item, "adcode"), Category = Text(item, "type")
            });
        }
        return Merge(found, "");
    }

    private async Task<SearchPlace[]> AmapGeocode(string query, string city, string key, CancellationToken token)
    {
        using var doc = await GetJson(AmapUrl("/v3/geocode/geo", new() { ["address"] = query, ["city"] = city, ["key"] = key, ["output"] = "json" }), token);
        CheckAmap(doc.RootElement);
        var found = new List<SearchPlace>();
        foreach (var item in Items(doc.RootElement, "geocodes"))
        {
            var name = Text(item, "formatted_address");
            if (name.Length == 0 || !ParseAmapLocation(Text(item, "location"), out var point)) continue;
            var level = Text(item, "level");
            found.Add(new(name, name, point.Lat, point.Lon, "高德地址解析") { Region = Join(item, "province", "city", "district"), Adcode = Text(item, "adcode"), Category = "地址匹配 · " + (level.Length > 0 ? level : "级别未知") });
        }
        return found.ToArray();
    }

    private async Task<SearchPlace[]> SearchPhoton(string query, string city, string endpoint, CancellationToken token)
    {
        if (!Uri.TryCreate(endpoint, UriKind.Absolute, out var uri) || (uri.Scheme != "https" && !(uri.IsLoopback && uri.Scheme == "http"))) throw new ArgumentException("开放地图服务地址必须是 HTTPS，或本机 HTTP 地址");
        var fullQuery = city.Length == 0 || query.Contains(city, StringComparison.Ordinal) ? query : city + " " + query;
        var builder = new UriBuilder(uri) { Fragment = "" };
        builder.Query = (builder.Query.Length > 1 ? builder.Query[1..] + "&" : "") + "q=" + Uri.EscapeDataString(fullQuery) + "&limit=20";
        using var doc = await GetJson(builder.Uri.AbsoluteUri, token);
        if (doc.RootElement.ValueKind != JsonValueKind.Object || !doc.RootElement.TryGetProperty("features", out var features) || features.ValueKind != JsonValueKind.Array) throw new IOException("搜索服务返回异常，请稍后重试");
        var found = new List<SearchPlace>();
        foreach (var item in features.EnumerateArray())
        {
            if (item.ValueKind != JsonValueKind.Object || !item.TryGetProperty("geometry", out var geometry) || geometry.ValueKind != JsonValueKind.Object
                || !geometry.TryGetProperty("coordinates", out var points) || points.ValueKind != JsonValueKind.Array || points.GetArrayLength() < 2
                || points[0].ValueKind != JsonValueKind.Number || !points[0].TryGetDouble(out var lon) || points[1].ValueKind != JsonValueKind.Number || !points[1].TryGetDouble(out var lat)
                || !double.IsFinite(lat) || !double.IsFinite(lon) || Math.Abs(lat) > 90 || Math.Abs(lon) > 180
                || !item.TryGetProperty("properties", out var properties) || properties.ValueKind != JsonValueKind.Object) continue;
            var name = Text(properties, "name");
            found.Add(new(name.Length > 0 ? name : query, JoinParts(new[] { "country", "state", "county", "city", "district", "street", "housenumber" }.Select(p => Text(properties, p)).ToArray()), lat, lon, "开放地图 · © OpenStreetMap")
            { Region = JoinParts(new[] { "state", "county", "city", "district" }.Select(p => Text(properties, p)).ToArray()), Category = Text(properties, "osm_value") });
        }
        return Merge(found, query);
    }

    private async Task<PlaceSearchResult> Run(Func<CancellationToken, Task<PlaceSearchResult>> action, CancellationToken external)
    {
        using var operation = CancellationTokenSource.CreateLinkedTokenSource(external);
        operation.CancelAfter(TimeSpan.FromSeconds(28));
        var entered = false;
        try
        {
            await _requestGate.WaitAsync(operation.Token); entered = true;
            var result = await action(operation.Token);
            operation.Token.ThrowIfCancellationRequested();
            return result;
        }
        catch (OperationCanceledException) when (!external.IsCancellationRequested) { throw new TimeoutException("搜索超时，请重试或直接在地图上选点"); }
        finally { if (entered) _requestGate.Release(); }
    }

    private async Task<JsonDocument> GetJson(string url, CancellationToken token)
    {
        var delay = _interval.TotalMilliseconds - (Environment.TickCount64 - _lastRequest);
        if (delay > 0) await Task.Delay(TimeSpan.FromMilliseconds(delay), token);
        _lastRequest = Environment.TickCount64;
        using var request = CancellationTokenSource.CreateLinkedTokenSource(token);
        request.CancelAfter(_requestTimeout);
        try
        {
            using var response = await _http.GetAsync(url, request.Token);
            if (response.StatusCode == HttpStatusCode.TooManyRequests) throw new IOException("搜索服务请求过于频繁，请稍后重试");
            if (!response.IsSuccessStatusCode) throw new IOException($"搜索服务暂时不可用（HTTP {(int)response.StatusCode}）");
            return JsonDocument.Parse(await response.Content.ReadAsStringAsync(request.Token));
        }
        catch (OperationCanceledException) when (!token.IsCancellationRequested) { throw new TimeoutException("搜索服务响应超时"); }
        catch (HttpRequestException) { throw new IOException("无法连接搜索服务，请检查网络，或在设置中切换服务"); }
        catch (JsonException) { throw new IOException("搜索服务返回异常，请稍后重试"); }
    }

    private static string AmapUrl(string path, Dictionary<string, string> parameters) => "https://restapi.amap.com" + path + "?" + string.Join("&", parameters.Select(p => Uri.EscapeDataString(p.Key) + "=" + Uri.EscapeDataString(p.Value)));
    private static bool Recoverable(Exception ex) => ex is IOException or TimeoutException;
    private static string Clean(string? value, int max) => (value ?? "").Trim() is var text && text.Length <= max ? text : throw new ArgumentException("地点信息过长，请重新搜索");
    private static string Join(JsonElement item, params string[] fields) => JoinParts(fields.Select(p => Text(item, p)).ToArray());
    private static string JoinParts(params string[] parts) => string.Join(" ", parts.Where(s => s.Length > 0).Distinct());
    private static string Text(JsonElement item, string key) => item.ValueKind == JsonValueKind.Object && item.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
    private static IEnumerable<JsonElement> Items(JsonElement root, string name) => root.ValueKind == JsonValueKind.Object && root.TryGetProperty(name, out var items) && items.ValueKind == JsonValueKind.Array ? items.EnumerateArray().Where(p => p.ValueKind == JsonValueKind.Object) : [];
    private static SearchPlace[] Merge(IEnumerable<SearchPlace> places, string query) => places.DistinctBy(p => (p.Name, p.Address, p.Latitude, p.Longitude, p.Adcode))
        .OrderByDescending(p => p.Name == query).ThenByDescending(p => p.HasCoordinates).Take(30).ToArray();
    private static bool ParseAmapLocation(string text, out (double Lat, double Lon) result)
    {
        result = default;
        var parts = text.Split(',');
        if (parts.Length != 2 || !double.TryParse(parts[0], CultureInfo.InvariantCulture, out var lon) || !double.TryParse(parts[1], CultureInfo.InvariantCulture, out var lat)
            || !double.IsFinite(lat) || !double.IsFinite(lon) || Math.Abs(lat) > 90 || Math.Abs(lon) > 180) return false;
        result = CoordinateConverter.GcjToWgs(lat, lon); return true;
    }
    private static void CheckAmap(JsonElement root)
    {
        if (Text(root, "status") == "1") return;
        throw new IOException(Text(root, "infocode") switch
        {
            "10001" => "高德 Key 无效，请检查设置中的 Web 服务 Key",
            "10003" or "10004" or "10021" or "10044" => "高德调用额度已用完或权限受限，请检查开放平台配额",
            "10009" => "高德 Key 平台类型错误，请使用 Web 服务类型",
            "10005" or "10006" or "10007" => "高德 Key 的访问限制未通过，请检查 IP 或权限设置",
            _ => "高德搜索未完成，请检查服务配置后重试",
        });
    }
    public void Dispose() => _http.Dispose();
}

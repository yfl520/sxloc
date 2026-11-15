using System.IO;
using System.Net;
using System.Net.Http;
using System.Text.Json;
using Iap2Loc.Desktop;

internal static class PlaceSearchRegression
{
    private const string Empty = """{"status":"1","pois":[],"tips":[],"geocodes":[]}""";
    private const string Poi = """{"status":"1","pois":[{"id":"village","name":"幸福村","location":"120.1,30.2","pname":"浙江省","cityname":"杭州市","adname":"富阳区","adcode":"330111","address":"新登镇"}]}""";
    private const string Tips = """{"status":"1","tips":[{"id":[],"name":"幸福村","location":[],"district":"浙江省杭州市富阳区","adcode":"330111","address":"新登镇"}]}""";
    private const string Geo = """{"status":"1","geocodes":[{"formatted_address":"浙江省杭州市富阳区新登镇幸福村","location":"120.1,30.2","province":"浙江省","city":"杭州市","district":"富阳区","adcode":"330111","level":"村庄"}]}""";
    private const string Photon = """{"features":[{"geometry":{"coordinates":[120.1,30.2]},"properties":{"name":"幸福村","state":"浙江省","city":"杭州市","district":"富阳区"}}]}""";
    private static int _checks;
    private static DesktopSettings Settings(string provider = "amap") => new() { SearchProvider = provider, AmapKey = "offline-test-key", SearchCity = "上海" };
    private static SearchPlace Village(string id = "") => new("幸福村", "新登镇", null, null, "高德搜索") { Id = id, Region = "浙江省杭州市富阳区", Adcode = "330111" };
    private static void Check(bool condition, string message) { if (!condition) throw new Exception(message); _checks++; }
    private static HttpResponseMessage Json(string value) => new(HttpStatusCode.OK) { Content = new StringContent(value) };
    private static PlaceSearchService Service(Func<Uri, string> response) => new(new Stub((r, _) => Task.FromResult(Json(response(r.RequestUri!)))), TimeSpan.Zero);
    private static string Param(Uri uri, string key)
    {
        foreach (var entry in uri.Query.TrimStart('?').Split('&'))
        {
            var pair = entry.Split('=', 2);
            if (Uri.UnescapeDataString(pair[0]) == key) return pair.Length > 1 ? Uri.UnescapeDataString(pair[1]) : "";
        }
        return "";
    }
    private static async Task Cancelled(Func<Task> action)
    {
        try { await action(); } catch (OperationCanceledException) { _checks++; return; }
        throw new Exception("取消没有传播");
    }

    public static async Task Run()
    {
        await SuggestionsAndResolve();
        await RegionsAndAmbiguity();
        await FallbackAndCache();
        await ParsingAndCancellation();
        Console.WriteLine($"PASS: {_checks} 项桌面搜索离线检查（未联网、未连接设备）");
    }

    private static async Task SuggestionsAndResolve()
    {
        var calls = new List<Uri>();
        using var search = Service(uri => { calls.Add(uri); return uri.AbsolutePath.EndsWith("inputtips") ? Tips : uri.AbsolutePath.EndsWith("geo") ? Geo : Empty; });
        var settings = Settings();
        var result = await search.SearchDetailedAsync("幸福", settings, default, suggestions: true);
        var village = result.Places.Single();
        Check(calls.Count == 1 && calls[0].AbsolutePath == "/v3/assistant/inputtips", "输入联想不应提前请求详情");
        Check(village.Latitude is null && village.Longitude is null && !village.HasCoordinates, "缺失坐标被误变成有效点");
        Check(village.Region == "浙江省杭州市富阳区" && village.Adcode == "330111" && village.Id == "", "联想丢失了行政区或错误解析数组 ID");
        var resultJson = JsonSerializer.Serialize(result, new JsonSerializerOptions { PropertyNamingPolicy = JsonNamingPolicy.CamelCase });
        Check(resultJson.Contains("\"latitude\":null") && resultJson.Contains("\"hasCoordinates\":false"), "Flutter 管道空坐标契约错误");
        calls.Clear();
        var resolved = await search.ResolveAsync(village, settings, default);
        Check(resolved.Places.Single().HasCoordinates && resolved.NeedsConfirmation, "村名未通过地理编码补查并确认");
        Check(resolved.Places.Single().Category == "地址匹配 · 村庄", "地址匹配级别丢失");
        var geoCall = calls.Single(uri => uri.AbsolutePath.EndsWith("geo"));
        Check(Param(geoCall, "address").Replace(" ", "") == "浙江省杭州市富阳区新登镇幸福村" && Param(geoCall, "city") == "330111", "补查未保留完整地址和区县");
        Check(Param(calls[0], "citylimit") == "true", "补查未限制已选行政区");
        var count = calls.Count;
        var point = resolved.Places.Single();
        Check((await search.ResolveAsync(point, new DesktopSettings { SearchProvider = "amap" }, default)).Places.Single() == point && calls.Count == count, "已有坐标仍依赖 Key 或详情网络");
        Check(PlaceSearchService.ContextualQuery(Village() with { Address = "浙江省杭州市富阳区新登镇幸福村" }) == "浙江省杭州市富阳区新登镇幸福村", "完整地址重复拼接");

        using var stale = Service(uri => uri.AbsolutePath.EndsWith("detail") ? Empty : uri.AbsolutePath.EndsWith("text") ? Poi : Empty);
        var recovered = await stale.ResolveAsync(Village("stale-id"), settings, default);
        Check(recovered.Places.Single().HasCoordinates && !recovered.NeedsConfirmation, "失效 ID 阻止了后续同名地点补查");

        using var address = Service(uri => uri.AbsolutePath.EndsWith("inputtips") ? Tips : uri.AbsolutePath.EndsWith("geo") ? Geo : Empty);
        var full = await address.SearchDetailedAsync("幸福村", settings, default);
        Check(full.Places.Any(p => p.HasCoordinates) && full.Places.Any(p => !p.HasCoordinates), "完整搜索未合并建议和地址坐标");

        using var nearby = Service(uri => uri.AbsolutePath.EndsWith("geo") ? Geo : Poi.Replace("\"幸福村\"", "\"幸福村卫生室\""));
        var enriched = await nearby.SearchDetailedAsync("幸福村", settings, default);
        Check(enriched.Places.Any(p => p.Source == "高德地址解析") && enriched.Places.Any(p => p.Name == "幸福村卫生室"), "相关 POI 阻止了村庄地址解析");

        using var optional = new PlaceSearchService(new Stub((r, _) => r.RequestUri!.AbsolutePath.EndsWith("geo")
            ? Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable))
            : Task.FromResult(Json(Poi.Replace("\"幸福村\"", "\"幸福村卫生室\"")))), TimeSpan.Zero);
        Check((await optional.SearchDetailedAsync("幸福村", settings, default)).Places.Single().HasCoordinates, "可选补查失败清空了已取得的坐标");
    }

    private static async Task RegionsAndAmbiguity()
    {
        var settings = Settings();
        var wrong = Poi.Replace("330111", "330110");
        using var exclude = Service(uri => uri.AbsolutePath.EndsWith("text") || uri.AbsolutePath.EndsWith("detail") ? wrong : Empty);
        Check((await exclude.ResolveAsync(Village("id"), settings, default)).Places.Length == 0, "错误区县的同名点没有排除");
        using var province = Service(_ => Poi);
        var broad = await province.ResolveAsync(Village() with { Adcode = "330000", Region = "浙江省" }, settings, default);
        Check(broad.Places.Length == 1 && !broad.NeedsConfirmation, "省级编码未匹配下属区县");
        using var city = Service(_ => Poi);
        Check((await city.ResolveAsync(Village() with { Adcode = "330100" }, settings, default)).Places.Length == 1, "市级编码未匹配下属区县");
        using var unknown = Service(uri => uri.AbsolutePath.EndsWith("text") ? Poi.Replace("330111", "") : Empty);
        var uncertain = await unknown.ResolveAsync(Village(), settings, default);
        Check(uncertain.Places.Single().HasCoordinates && uncertain.NeedsConfirmation, "缺地区编码的结果被自动选中");
        using var noCode = Service(uri => uri.AbsolutePath.EndsWith("text") ? Poi : Empty);
        Check(!(await noCode.ResolveAsync(Village() with { Adcode = "" }, settings, default)).NeedsConfirmation, "无编码时没有按地区文本匹配");
        using var wrongText = Service(uri => uri.AbsolutePath.EndsWith("text") ? wrong.Replace("富阳区", "余杭区") : Empty);
        Check((await wrongText.ResolveAsync(Village() with { Adcode = "" }, settings, default)).NeedsConfirmation, "无编码时错误地区被自动选中");
        // Build two distinct same-name candidates, with both in the selected county.
        using var multiple = Service(_ => """{"status":"1","pois":[{"name":"幸福村","location":"120.1,30.2","adcode":"330111"},{"name":"幸福村","location":"120.2,30.3","adcode":"330111"}]}""");
        var ambiguous = await multiple.ResolveAsync(Village(), settings, default);
        Check(ambiguous.Places.Length == 2 && ambiguous.NeedsConfirmation, "多个同名点被静默选第一个");
        using var detailUnknown = Service(uri => uri.AbsolutePath.EndsWith("detail") ? Poi.Replace("330111", "") : Empty);
        Check((await detailUnknown.ResolveAsync(Village("id"), settings, default)).NeedsConfirmation, "详情无地区信息时未要求确认");

        Uri? photonCall = null;
        using var regionalFallback = Service(uri =>
        {
            if (uri.Host.Contains("photon")) { photonCall = uri; return Photon; }
            return Empty;
        });
        var fallback = await regionalFallback.ResolveAsync(Village(), Settings("auto"), default);
        Check(fallback.NeedsConfirmation && fallback.Places.Single().HasCoordinates, "地址补查未使用开放地图兜底");
        Check(photonCall is not null && Param(photonCall, "q") == "浙江省杭州市富阳区新登镇幸福村", "补查加入了错误的原优先城市");
    }

    private static async Task FallbackAndCache()
    {
        var hosts = new List<string>();
        using var empty = Service(uri => { hosts.Add(uri.Host); return uri.Host.Contains("photon") ? Photon : Empty; });
        var auto = Settings("auto");
        var result = await empty.SearchDetailedAsync("幸福村", auto, default);
        Check(result.Places.Single().HasCoordinates && result.Notice is not null && hosts.Any(h => h.Contains("photon")), "高德空结果没有跨源补查");
        hosts.Clear();
        using var explicitOnly = Service(uri => { hosts.Add(uri.Host); return Empty; });
        Check((await explicitOnly.SearchDetailedAsync("幸福村", Settings(), default)).Places.Length == 0 && hosts.All(h => h == "restapi.amap.com"), "指定高德仍跨源查询");
        using var error = Service(uri => uri.Host.Contains("photon") ? Photon : """{"status":"0","infocode":"10001"}""");
        Check((await error.SearchDetailedAsync("幸福", auto, default)).Notice!.Contains("Key 无效"), "自动模式错误没有提示并兜底");
        var cachedCalls = 0;
        using var cache = Service(_ => { cachedCalls++; return Poi; });
        var settings = Settings();
        await cache.SearchDetailedAsync("幸福村", settings, default);
        await cache.SearchDetailedAsync("幸福村", settings, default);
        Check(cachedCalls == 1, "正常结果未缓存");
        settings.AmapKey = "another-offline-key";
        await cache.SearchDetailedAsync("幸福村", settings, default);
        Check(cachedCalls == 2, "更换 Key 后错误复用了旧缓存");
        var emptyCalls = 0;
        using var notCached = Service(_ => { emptyCalls++; return Empty; });
        await notCached.SearchDetailedAsync("测试", Settings(), default);
        var before = emptyCalls;
        await notCached.SearchDetailedAsync("测试", Settings(), default);
        Check(emptyCalls > before, "空结果被缓存");
        var recovered = false;
        using var transient = Service(uri => uri.Host.Contains("photon") ? Photon : recovered ? Poi : """{"status":"0","infocode":"10003"}""");
        await transient.SearchDetailedAsync("幸福村", auto, default);
        recovered = true;
        Check((await transient.SearchDetailedAsync("幸福村", auto, default)).Notice is null, "故障兜底被缓存，恢复后未查询高德");
        using var unavailable = new PlaceSearchService(new Stub((r, _) => Task.FromResult(r.RequestUri!.Host.Contains("photon")
            ? new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)
            : Json(r.RequestUri.AbsolutePath.EndsWith("inputtips") ? Tips : Empty))), TimeSpan.Zero);
        var kept = await unavailable.SearchDetailedAsync("幸福村", auto, default);
        Check(kept.Places.Single().Name == "幸福村" && kept.Notice is not null, "兜底失败丢失了已有的无坐标建议");

        using var timeout = new PlaceSearchService(new Stub(async (r, ct) =>
        {
            if (r.RequestUri!.Host.Contains("amap")) await Task.Delay(1000, ct);
            return Json(Photon);
        }), TimeSpan.Zero, TimeSpan.FromMilliseconds(25));
        Check((await timeout.SearchDetailedAsync("测试", auto, default)).Places.Single().HasCoordinates, "请求超时未执行自动兜底");
    }

    private static async Task ParsingAndCancellation()
    {
        using var malformed = Service(_ => """{"features":[null,{"geometry":{"coordinates":{}},"properties":{}},{"geometry":{"coordinates":["120",30]},"properties":{}},{"geometry":{"coordinates":[181,30]},"properties":{}},{"geometry":{"coordinates":[120,91]},"properties":{}},{"geometry":{"coordinates":[0,0]},"properties":{"name":"零点"}}]}""");
        var parsed = await malformed.SearchDetailedAsync("测试", Settings("photon"), default);
        Check(parsed.Places.Length == 1 && parsed.Places[0].Latitude == 0 && parsed.Places[0].Longitude == 0, "异常 Photon 数据产生了假坐标或拒绝真实零点");
        using var invalid = Service(_ => """{"status":"1","tips":[{"name":"坏点","location":"NaN,30"},{"name":"坏点2","location":[0,0]},{"name":"越界","location":"200,99"},{"name":"零点","location":"0,0"}]}""");
        var tips = await invalid.SearchDetailedAsync("测试", Settings(), default, true);
        Check(tips.Places.Count(p => p.HasCoordinates) == 1 && tips.Places.Single(p => p.HasCoordinates).Name == "零点", "无效高德坐标通过校验");
        var coordinates = PlaceSearchService.ParseCoordinate("高德：30.2,120.1")!;
        var expected = CoordinateConverter.GcjToWgs(30.2, 120.1);
        Check(coordinates.Latitude == expected.Lat && coordinates.Longitude == expected.Lon, "中文冒号坐标未纠偏");
        using var zeroNetwork = Service(_ => throw new Exception("不应联网"));
        Check((await zeroNetwork.SearchDetailedAsync("0,0", Settings(), default)).Places.Single().HasCoordinates, "离线坐标解析失败");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        await Cancelled(() => malformed.SearchDetailedAsync("测试", Settings("photon"), cancelled.Token));
        await Cancelled(() => zeroNetwork.ResolveAsync(new("零点", "", 0, 0, "坐标"), Settings(), cancelled.Token));
        var requested = new List<string>();
        var entered = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        using var waiting = new PlaceSearchService(new Stub(async (r, ct) =>
        {
            requested.Add(r.RequestUri!.Host);
            if (Param(r.RequestUri, "keywords") == "旧搜索")
            {
                entered.TrySetResult();
                await Task.Delay(5000, ct);
            }
            return Json(Poi);
        }), TimeSpan.Zero);
        using var old = new CancellationTokenSource();
        var first = waiting.SearchDetailedAsync("旧搜索", Settings("auto"), old.Token);
        await entered.Task;
        old.Cancel();
        var newer = waiting.SearchDetailedAsync("新搜索", Settings(), default);
        await Cancelled(() => first);
        Check((await newer).Places.Single().HasCoordinates && requested.All(h => !h.Contains("photon")), "取消未释放门控或旧查询仍跨源继续");
        using var broken = Service(_ => "not-json-with-offline-test-key");
        try { await broken.SearchDetailedAsync("测试", Settings(), default); throw new Exception("异常 JSON 未报错"); }
        catch (IOException ex) { Check(!ex.Message.Contains("offline-test-key") && !ex.Message.Contains("https"), "异常泄露请求 Key 或地址"); }
    }

    private sealed class Stub(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) => respond(request, token);
    }
}

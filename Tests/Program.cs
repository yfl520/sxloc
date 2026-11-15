using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Sockets;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.Json;
using Iap2Loc;
using Iap2Loc.Desktop;
using Iap2Loc.Engine;
using Iap2Loc.Protocol;
using Iap2Loc.Transport;

internal static class Program
{
    private static int _passed;
    private static readonly List<string> Results = new();

    public static async Task<int> Main()
    {
        var output = Environment.GetEnvironmentVariable("SUIXING_TEST_OUTPUT") ?? Path.Combine(Path.GetTempPath(), "SuixingLoc-tests", Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(output);
        Environment.SetEnvironmentVariable("SUIXING_DATA", Path.Combine(output, "data"));
        try
        {
            await Test("乱序接收跨 255/0 回绕及重复包确认", SequenceWrap);
            await Test("NMEA 校验和、南西半球与无效坐标", NmeaAndValidation);
            await Test("GCJ/WGS 转换往返及坐标搜索", CoordinateTests);
            await Test("内置身份校验、导入加密与不匹配拒绝", () => IdentityTests(output));
            await Test("搜索结果解析、高德纠偏、错误与离线坐标", SearchTests);
            await Test("桌面联想、村庄补查、地区确认、跨源兜底与取消", PlaceSearchRegression.Run);
            await Test("iAP2 握手、识别、认证门控及定位订阅", ProtocolRoundtrip);
            await Test("连接失败与状态读取、停止的并发退出", () => ConcurrentStop(output));
            await Test("桌面配置保存、恢复及搜索 Key 加密", SettingsRoundtrip);
            File.WriteAllText(Path.Combine(output, "test-results.json"), JsonSerializer.Serialize(new { passed = _passed, results = Results }, new JsonSerializerOptions { WriteIndented = true }));
            Console.WriteLine($"PASS: {_passed} 项测试全部通过"); return 0;
        }
        catch (Exception ex)
        {
            File.WriteAllText(Path.Combine(output, "test-failure.txt"), ex.ToString());
            Console.Error.WriteLine("FAIL: " + ex); return 1;
        }
        finally { IdentitySource.Provider = null; }
    }

    private static async Task Test(string name, Func<Task> test)
    {
        await test().WaitAsync(TimeSpan.FromSeconds(20));
        ++_passed; Results.Add(name); Console.WriteLine("PASS: " + name);
    }
    private static void Assert(bool condition, string message) { if (!condition) throw new Exception(message); }
    private static void Throws(Action action, string message) { try { action(); } catch { return; } throw new Exception(message); }
    private static void Field(object instance, string name, object value) => instance.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.SetValue(instance, value);
    private static T Get<T>(object instance, string name) => (T)instance.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)!.GetValue(instance)!;

    private static Task SequenceWrap()
    {
        var stream = new CaptureTransport();
        using var link = new Iap2Link(stream, true, "wrap-test");
        Field(link, "_acknowledge", (byte)254);
        Field(link, "_state", LinkState.Normal);
        var accept = typeof(Iap2Link).GetMethod("AcceptSequence", BindingFlags.Instance | BindingFlags.NonPublic)!;
        void Receive(byte sequence) => accept.Invoke(link, [sequence, (byte)99, new byte[] { 1 }]);
        Receive(1);
        Assert(stream.Packets.Count == 1 && stream.Packets[0].AsSpan(9, 2).SequenceEqual(new byte[] { 255, 0 }), "缺失列表未按 8 位回绕");
        Receive(255); Receive(0);
        Assert(Get<byte>(link, "_acknowledge") == 1, "乱序缓冲未按 255,0,1 顺序交付");
        var before = stream.Packets.Count; Receive(0);
        Assert(stream.Packets.Count == before + 1 && stream.Packets[^1][6] == 1, "重复包没有重新确认");
        return Task.CompletedTask;
    }

    private static Task NmeaAndValidation()
    {
        var nmea = Nmea.Encode(-33.86, -70.12, 10, null, 1, 5, 1, 8, new DateTime(2026,11,15,1,2,3,DateTimeKind.Utc));
        var sentences = nmea.Split("\r\n", StringSplitOptions.RemoveEmptyEntries);
        Assert(sentences.Length == 2 && nmea.Contains(",S,") && nmea.Contains(",W,"), "NMEA 半球或语句数错误");
        foreach (var sentence in sentences)
        {
            var star = sentence.IndexOf('*'); var sum = 0;
            foreach (var ch in sentence.AsSpan(1, star - 1)) sum ^= ch;
            Assert(sum.ToString("X2") == sentence[(star+1)..], "NMEA 校验和不正确");
        }
        var target = new LocationTarget(31,121);
        Throws(() => target.Apply(new TargetUpdate { Latitude = 91 }), "接受了无效纬度");
        Throws(() => target.Apply(new TargetUpdate { Speed = double.NaN }), "接受了 NaN");
        Assert(target.Snapshot().Latitude == 31, "失败更新改变了目标");
        target.Apply(new TargetUpdate { JitterPosition = true, JitterMeters = 10 });
        Assert(target.Next() == target.Next(), "随机位置没有保持稳定");
        return Task.CompletedTask;
    }

    private static Task CoordinateTests()
    {
        foreach (var point in new[] { (31.2304,121.4737), (39.9042,116.4074), (-33.86,151.2), (0.0,0.0) })
        {
            var gcj = CoordinateConverter.WgsToGcj(point.Item1,point.Item2);
            var back = CoordinateConverter.GcjToWgs(gcj.Lat,gcj.Lon);
            Assert(Math.Abs(back.Lat-point.Item1)<1e-7 && Math.Abs(back.Lon-point.Item2)<1e-7,"坐标往返误差过大");
        }
        var coordinate = PlaceSearchService.ParseCoordinate("121.4737,31.2304")!;
        Assert(coordinate.Latitude == 31.2304 && coordinate.Longitude == 121.4737, "经纬度顺序识别错误");
        Assert(PlaceSearchService.ParseCoordinate("上海外滩") is null,"地点被误识别为坐标");
        Throws(() => PlaceSearchService.ParseCoordinate("999,999"), "无效坐标未拒绝");
        return Task.CompletedTask;
    }

    private static Task IdentityTests(string output)
    {
        var settings = new DesktopSettings();
        var provider = new DesktopIdentityProvider(settings); provider.Prime();
        Assert(provider.Warning is null, "内置身份校验失败："+provider.Warning);
        using(var signer = provider.Resolve(null,out _)) Assert(signer!.SignChallenge(RandomNumberGenerator.GetBytes(32)).Length == 64,"内置签名长度错误");
        using var key = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        using var cert = new CertificateRequest("CN=SuixingLoc test only",key,HashAlgorithmName.SHA256).CreateSelfSigned(DateTimeOffset.UtcNow.AddDays(-1),DateTimeOffset.UtcNow.AddDays(2));
        var pk = key.ExportPkcs8PrivateKey(); var certificate = cert.Export(X509ContentType.Cert);
        var directory = Path.Combine(output,"temporary-test-identity"); Directory.CreateDirectory(directory);
        File.WriteAllBytes(Path.Combine(directory,"identity.pk8"),pk); File.WriteAllBytes(Path.Combine(directory,"certificate.p7b"),certificate);
        provider.Import(Path.Combine(directory,"identity.pk8"));
        Assert(settings.UseImportedIdentity && provider.Warning is null,"导入身份未生效");
        var encrypted = File.ReadAllBytes(Path.Combine(DesktopSettings.DataDirectory,"identity.dpapi"));
        Assert(encrypted.AsSpan().IndexOf(pk) < 0,"私钥以明文保存");
        using var other = ECDsa.Create(ECCurve.NamedCurves.nistP256);
        Throws(()=>MfiSigner.FromMaterial(other.ExportPkcs8PrivateKey(),certificate),"证书与私钥不匹配仍被接受");
        provider.UseBuiltIn(); Assert(!settings.UseImportedIdentity && provider.Warning is null,"恢复内置身份失败");
        CryptographicOperations.ZeroMemory(pk);
        return Task.CompletedTask;
    }

    private static async Task SearchTests()
    {
        var response = """{"features":[{"geometry":{"coordinates":[121.48,31.24]},"properties":{"name":"上海外滩","city":"上海","country":"中国"}}]}""";
        using var photon = new PlaceSearchService(new StubHandler(_=>response));
        var settings = new DesktopSettings { SearchProvider = "photon" };
        var results = await photon.SearchAsync("上海外滩", settings, CancellationToken.None);
        Assert(results.Length==1 && results[0].Name=="上海外滩" && results[0].Latitude==31.24,"开放地图搜索解析错误");
        using var amap = new PlaceSearchService(new StubHandler(_=>"""{"status":"1","pois":[{"name":"外滩","location":"121.480237,31.228457","pname":"上海市","address":"中山东一路"}]}"""));
        settings.SearchProvider="amap"; settings.AmapKey="test-only-not-real-key";
        var poi = (await amap.SearchAsync("外滩",settings,CancellationToken.None))[0];
        var expected = CoordinateConverter.GcjToWgs(31.228457,121.480237);
        Assert(Math.Abs(poi.Latitude!.Value-expected.Lat)<1e-9,"高德结果未转换为 WGS-84");
        using var invalid = new PlaceSearchService(new StubHandler(_=>"""{"status":"0","infocode":"10001"}"""));
        try { await invalid.SearchAsync("无效测试",settings,CancellationToken.None); throw new Exception("无效 Key 没有报错"); }
        catch(IOException ex) { Assert(ex.Message.Contains("Key 无效"),"高德错误未转换为中文"); }
        using var offline = new PlaceSearchService(new StubHandler(_=>throw new HttpRequestException("offline")));
        Assert((await offline.SearchAsync("31.23,121.47",settings,CancellationToken.None)).Length==1,"离线坐标解析不可用");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        try { await photon.SearchAsync("新的搜索",settings,cancelled.Token); throw new Exception("取消未生效"); } catch(OperationCanceledException) { }
    }

    private static async Task ProtocolRoundtrip()
    {
        var (accessoryTransport,phoneTransport) = MemoryTransport.Pair();
        using var phone = new Iap2Link(phoneTransport,false,"test-phone");
        using var accessory = new Iap2Link(accessoryTransport,true,"test-accessory");
        var provider = new DesktopIdentityProvider(new DesktopSettings());
        using var signer = provider.Resolve(null,out _);
        using var location = new LocationSession(accessory,new LocationTarget(31.23,121.47),AccessoryProfile.Default.ToIdentity(),signer,250,[1,2,3,4,5,6]);
        var received = new ConcurrentQueue<ushort>();
        phone.CsmReceived += (id,_)=>received.Enqueue(id);
        phone.Start(); accessory.Start();
        await Wait(()=>phone.State==LinkState.Normal && accessory.State==LinkState.Normal);
        phone.Send(0x1D00); await Wait(()=>received.Contains((ushort)0x1D01));
        phone.Send(0x1D02); phone.Send(0xAA00); await Wait(()=>received.Contains((ushort)0xAA01));
        phone.Send(0xAA02,Csm.Param(0,RandomNumberGenerator.GetBytes(32))); await Wait(()=>received.Contains((ushort)0xAA03));
        phone.Send(0xFFFA,Csm.Param(1,[]),Csm.Param(2,[]),Csm.Param(0x8001,[0,0,0,30]),Csm.Param(0x8002,[0,0,0,90]));
        await Task.Delay(100); Assert(location.MessagesPushed==0,"未认证时发送了定位");
        phone.Send(0xAA05); await Wait(()=>location.MessagesPushed>=3);
        Assert(location.Authenticated && location.Identified && location.Subscribed,"会话状态不正确");
        for(var i=0;i<12;i++) phone.Send(0xFFFA,Csm.Param(1,[]),Csm.Param(2,[]));
        await Task.Delay(100);
        phone.Send(0xAA04); await Wait(()=>!location.Authenticated);
        Assert(!location.Subscribed,"认证失败后仍在订阅");
        var count = location.MessagesPushed; await Task.Delay(130); Assert(location.MessagesPushed<=count+1,"认证失败后持续发送");
        phone.Send(0xFFFC); await Task.Delay(30);
    }

    private static async Task ConcurrentStop(string output)
    {
        IdentitySource.Provider = new DesktopIdentityProvider(new DesktopSettings());
        for(var i=0;i<15;i++)
        {
            var listener = new TcpListener(IPAddress.Loopback,0); listener.Start();
            using var manager = new SessionManager(31,121,AppConfig.Load(Path.Combine(output,"session-config.json")));
            var server = Task.Run(async()=>{using var socket=await listener.AcceptTcpClientAsync(); await Task.Delay(8);});
            var add = Task.Run(()=>manager.Add(new RunRequest{Transport="tcp",Host="127.0.0.1",Port=((IPEndPoint)listener.LocalEndpoint).Port}));
            var state = Task.Run(async()=>{for(var n=0;n<25;n++){_ = manager.Snapshot(); await Task.Delay(1);}});
            await Task.Delay(3);
            var stop = Task.Run(manager.StopAll);
            await Task.WhenAll(add,state,stop,server).WaitAsync(TimeSpan.FromSeconds(3));
            listener.Stop();
        }
        IdentitySource.Provider = null;
    }

    private static Task SettingsRoundtrip()
    {
        var settings = new DesktopSettings { Latitude=-33.86,Longitude=151.2,Rate=123,SearchCity="上海" };
        settings.AmapKey="fake-test-map-key"; settings.Save();
        Assert(!File.ReadAllText(DesktopSettings.SettingsPath).Contains("fake-test-map-key"),"地图 Key 明文写入设置");
        var restored = DesktopSettings.Load();
        Assert(restored.AmapKey=="fake-test-map-key" && restored.Latitude==settings.Latitude && restored.Rate==123 && restored.SearchCity=="上海","桌面设置恢复失败");
        settings.Rate = -1; settings.Save();
        Assert(DesktopSettings.Load().Rate == 250, "损坏的发送周期未恢复默认值");
        settings.Rate = 250; settings.AccuracyMin = 20; settings.AccuracyMax = 3; settings.Save();
        Assert(DesktopSettings.Load().AccuracyMin == 3, "损坏的精度范围未恢复默认值");
        return Task.CompletedTask;
    }

    private static async Task Wait(Func<bool> predicate)
    {
        for(var i=0;i<250;i++){if(predicate())return;await Task.Delay(10);}
        throw new TimeoutException("等待测试协议状态超时");
    }

    private sealed class StubHandler(Func<HttpRequestMessage,string> result):HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token)
            => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK){Content=new StringContent(result(request))});
    }
    private sealed class CaptureTransport:ITransport
    {
        public string Describe=>"test";
        public List<byte[]> Packets {get;}=new();
        public int Read(byte[] buffer,int offset,int count)=>0;
        public void Write(byte[] buffer,int offset,int count)=>Packets.Add(buffer.AsSpan(offset,count).ToArray());
        public void Dispose(){}
    }
    private sealed class MemoryTransport:ITransport
    {
        private readonly BlockingCollection<byte[]> _incoming;
        private readonly BlockingCollection<byte[]> _outgoing;
        private byte[]? _current;
        private int _offset;
        private MemoryTransport(BlockingCollection<byte[]> incoming,BlockingCollection<byte[]> outgoing){_incoming=incoming;_outgoing=outgoing;}
        public static (MemoryTransport,MemoryTransport) Pair(){var a=new BlockingCollection<byte[]>();var b=new BlockingCollection<byte[]>();return(new(a,b),new(b,a));}
        public string Describe=>"memory";
        public int Read(byte[] buffer,int offset,int count)
        {
            if(_current is null||_offset==_current.Length){try{_current=_incoming.Take();_offset=0;}catch(InvalidOperationException){return 0;}}
            var size=Math.Min(count,_current.Length-_offset);Array.Copy(_current,_offset,buffer,offset,size);_offset+=size;return size;
        }
        public void Write(byte[] buffer,int offset,int count){try{_outgoing.Add(buffer.AsSpan(offset,count).ToArray());}catch(InvalidOperationException){throw new IOException("test peer closed");}}
        public void Dispose(){_incoming.CompleteAdding();_outgoing.CompleteAdding();}
    }
}

using Iap2Loc.Protocol;
using Iap2Loc.Transport;

namespace Iap2Loc.Engine;

internal sealed record RunRequest
{
    public string Transport { get; init; } = "bt";
    public string? Mac { get; init; }
    public string? Host { get; init; }
    public int Port { get; init; }
    public string? IdentityDirectory { get; init; }
    public int Rate { get; init; } = 250;
    public AccessoryProfile Profile { get; init; } = AccessoryProfile.Default;
    public string Label { get; init; } = "iPhone";
}

/// <summary>One accessory session. Several can run at once; all of them follow the shared target.</summary>
internal sealed class RunSession : IDisposable
{
    private readonly RunRequest _request;
    private readonly LocationTarget _target;
    private readonly object _gate = new();

    private ITransport? _transport;
    private Iap2Link? _link;
    private LocationSession? _location;
    private MfiSigner? _signer;
    private volatile string? _error;
    private volatile bool _running;
    private bool _starting;
    private int _generation;

    public RunSession(string id, RunRequest request, LocationTarget target)
    {
        Id = id;
        _request = request;
        _target = target;
    }

    public string Id { get; }

    public RunRequest Request => _request;

    public string Label => string.IsNullOrWhiteSpace(_request.Label) ? "iPhone" : _request.Label;

    public bool Running
    {
        get { lock (_gate) { return _running; } }
    }

    public string LinkState
    {
        get { lock (_gate) { return _link?.State.ToString() ?? "Idle"; } }
    }

    public bool Authenticated
    {
        get { lock (_gate) { return _location?.Authenticated ?? false; } }
    }

    public bool Subscribed
    {
        get { lock (_gate) { return _location?.Subscribed ?? false; } }
    }

    public int Sent
    {
        get { lock (_gate) { return _location?.MessagesPushed ?? 0; } }
    }

    public QueuedLocationReport? LastQueuedReport
    {
        get { lock (_gate) { return _location?.LastQueuedReport; } }
    }

    public string? SendError
    {
        get { lock (_gate) { return _location?.SendError; } }
    }

    public string? Error
    {
        get { lock (_gate) { return _error ?? _location?.Error; } }
    }

    public bool Identified { get { lock (_gate) { return _location?.Identified ?? false; } } }

    public bool Starting { get { lock (_gate) { return _starting; } } }

    public void Start()
    {
        int generation;
        lock (_gate)
        {
            if (_running || _starting) return;
            _starting = true;
            generation = ++_generation;
            _error = null;
        }

        ITransport? transport = null;
        Iap2Link? link = null;
        LocationSession? location = null;
        MfiSigner? signer = null;
        try
        {
                signer = IdentitySource.Resolve(_request.IdentityDirectory, out var identitySource);

                if (signer is null)
                {
                    Log.Warn($"[{Label}] 未配置身份：链路与识别可用，认证不会通过");
                }
                else
                {
                    Log.Info($"[{Label}] 身份：{identitySource}，证书 {signer.Certificate.Length} 字节");
                }

                transport = _request.Transport.ToLowerInvariant() switch
                {
                    "bt" or "bluetooth" => OperatingSystem.IsMacOS()
                        ? MacBtRfcommTransport.Connect(_request.Mac ?? throw new ArgumentException("缺少蓝牙地址"))
                        : BtRfcommTransport.Connect(_request.Mac ?? throw new ArgumentException("缺少蓝牙地址")),
                    "tcp" or "wifi" => TcpTransport.Connect(
                        _request.Host ?? "127.0.0.1",
                        _request.Port > 0 ? _request.Port : throw new ArgumentException("缺少 TCP 端口")),
                    var other => throw new ArgumentException($"未知传输 '{other}'"),
                };

                var localAdapter = _request.Transport.StartsWith("bt", StringComparison.OrdinalIgnoreCase)
                    ? BluetoothDevices.TryGetLocalAdapterAddress()
                    : null;
                var reportedAdapter = _request.Profile.AdapterOverride();
                var adapter = reportedAdapter ?? localAdapter;
                var identity = _request.Profile.ToIdentity();

                if (reportedAdapter is not null)
                {
                    Log.Warn($"[{Label}] 蓝牙地址已改写为 " +
                             $"{string.Join(':', reportedAdapter.Select(b => b.ToString("X2")))}（实验项）");
                }

                link = new Iap2Link(transport, initiate: true, $"accessory-{Id}");
                location = new LocationSession(
                    link,
                    _target,
                    identity,
                    signer,
                    _request.Rate,
                    bluetoothAdapter: adapter);

                var currentLink = link;
                link.Failed += reason =>
                {
                    // Link callbacks run under the link lock. Never take the session lock here.
                    if (ReferenceEquals(_link, currentLink))
                    {
                        _error = reason;
                        _running = false;
                    }

                    Log.Error($"[{Label}] 链路中断：{reason}");
                };

                lock (_gate)
                {
                    if (generation != _generation) throw new OperationCanceledException("连接已取消");
                    _transport = transport; _link = link; _location = location; _signer = signer;
                    _running = true;
                    _starting = false;
                    link.Start();
                }
                Log.Ok($"[{Label}] 已启动：{transport.Describe}，配件身份 {identity.Serial}");
                transport = null; link = null; location = null; signer = null;
            }
            catch (Exception ex)
            {
                lock (_gate)
                {
                    if (generation == _generation)
                    {
                        _error = ex.Message;
                        _starting = false;
                        _running = false;
                        _transport = null; _link = null; _location = null; _signer = null;
                    }
                }
                if (ex is not OperationCanceledException) Log.Error($"[{Label}] 启动失败：{ex.Message}");
            }
        finally
        {
            location?.Dispose();
            if (link is not null) link.Dispose(); else transport?.Dispose();
            signer?.Dispose();
        }
    }

    public void SetInterval(int intervalMs)
    {
        lock (_gate)
        {
            _location?.SetInterval(intervalMs);
        }
    }

    public void Stop()
    {
        lock (_gate)
        {
            if (!_running && _link is null)
            {
                return;
            }

            _running = false;
        }

        Dispose();
        Log.Info($"[{Label}] 已停止");
    }

    public void Dispose()
    {
        LocationSession? location;
        Iap2Link? link;
        ITransport? transport;
        MfiSigner? signer;
        lock (_gate)
        {
            ++_generation;
            _starting = false;
            _running = false;
            location = _location; link = _link; transport = _transport; signer = _signer;
            _location = null;
            _link = null;
            _transport = null;
            _signer = null;
        }
        location?.Dispose();
        if (link is not null) link.Dispose(); else transport?.Dispose();
        signer?.Dispose();
    }
}

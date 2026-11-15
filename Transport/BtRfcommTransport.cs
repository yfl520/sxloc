using System.Runtime.InteropServices;

namespace Iap2Loc.Transport;

/// <summary>
/// Classic Bluetooth RFCOMM client for the iPhone iAP2 device service
/// (00000000-deca-fade-deca-deafdecacafe), implemented directly on Winsock AF_BTH.
///
/// The accessory is the RFCOMM client: Windows resolves the UUID through SDP, so no local
/// SDP record has to be registered. The device must already be paired in Windows Settings.
/// </summary>
internal sealed class BtRfcommTransport : ITransport
{
    private const int AfBth = 32;
    private const int SockStream = 1;
    private const int BthProtoRfcomm = 3;
    private static readonly Guid Iap2DeviceService = new("00000000-deca-fade-deca-deafdecacafe");

    private readonly IntPtr _socket;
    private readonly object _writeGate = new();
    private bool _closed;

    private BtRfcommTransport(IntPtr socket, string mac)
    {
        _socket = socket;
        Describe = $"RFCOMM {mac}";
    }

    public string Describe { get; }

    public static BtRfcommTransport Connect(string mac, int timeoutSeconds = 20)
    {
        if (!OperatingSystem.IsWindows())
            throw new PlatformNotSupportedException("当前 RFCOMM 实现依赖 Windows Winsock/Bluetooth API；macOS 版本仅支持 TCP 传输，蓝牙需要单独适配 IOBluetooth。");

        var normalized = Normalize(mac);
        if (Ws2_32.WSAStartup(0x0202, new byte[512]) != 0)
        {
            throw new InvalidOperationException("WSAStartup failed");
        }

        var socket = Ws2_32.socket(AfBth, SockStream, BthProtoRfcomm);
        if (socket == new IntPtr(-1))
        {
            Ws2_32.WSACleanup();
            throw new InvalidOperationException($"socket(AF_BTH) failed, WSA error {Ws2_32.WSAGetLastError()}");
        }

        var address = new SockAddrBth
        {
            AddressFamily = AfBth,
            BluetoothAddress = ulong.Parse(normalized.Replace(":", string.Empty), System.Globalization.NumberStyles.HexNumber),
            ServiceClassId = Iap2DeviceService,
            Port = 0,
        };

        try
        {
            uint nonBlocking = 1;
            if (Ws2_32.ioctlsocket(socket, 0x8004667E, ref nonBlocking) != 0)
                throw new IOException("无法配置蓝牙连接超时");
            if (Ws2_32.connect(socket, ref address, Marshal.SizeOf<SockAddrBth>()) != 0)
            {
                var error = Ws2_32.WSAGetLastError();
                if (error is not (10035 or 10036 or 10037)) throw ConnectError(error);
                var write = new FdSet { Count = 1, Socket = socket };
                var failed = new FdSet { Count = 1, Socket = socket };
                var timeout = new Timeval { Seconds = Math.Clamp(timeoutSeconds, 1, 120) };
                var selected = Ws2_32.select(0, IntPtr.Zero, ref write, ref failed, ref timeout);
                if (selected == 0) throw ConnectError(10060);
                if (selected < 0) throw ConnectError(Ws2_32.WSAGetLastError());
                var size = sizeof(int);
                if (Ws2_32.getsockopt(socket, 0xFFFF, 0x1007, out error, ref size) != 0)
                    throw ConnectError(Ws2_32.WSAGetLastError());
                if (error != 0) throw ConnectError(error);
            }
            nonBlocking = 0;
            if (Ws2_32.ioctlsocket(socket, 0x8004667E, ref nonBlocking) != 0)
                throw new IOException("无法恢复蓝牙阻塞读写模式");
        }
        catch
        {
            Ws2_32.closesocket(socket);
            Ws2_32.WSACleanup();
            throw;
        }

        return new BtRfcommTransport(socket, normalized);
    }

    private static Exception ConnectError(int error) => new IOException(error switch
    {
        10060 => "蓝牙连接超时：请确认 iPhone 已配对、屏幕已唤醒，并且提供 iAP2 服务",
        10049 => "无法访问该蓝牙地址，请重新选择设备",
        10051 => "蓝牙设备不可达，请检查本机适配器",
        10061 => "设备拒绝连接，请检查配对状态及 iAP2 服务",
        _ => $"蓝牙连接失败，系统错误码：{error}",
    });

    [StructLayout(LayoutKind.Sequential)]
    private struct FdSet { public uint Count; public IntPtr Socket; }

    [StructLayout(LayoutKind.Sequential)]
    private struct Timeval { public int Seconds; public int Microseconds; }

    public static string Normalize(string mac)
    {
        var hex = new string(mac.Where(Uri.IsHexDigit).ToArray()).ToUpperInvariant();
        if (hex.Length != 12)
        {
            throw new ArgumentException($"Bluetooth address must have 12 hex digits, got '{mac}'");
        }

        return string.Join(':', Enumerable.Range(0, 6).Select(i => hex.Substring(i * 2, 2)));
    }

    public int Read(byte[] buffer, int offset, int count)
    {
        if (offset != 0)
        {
            throw new NotSupportedException("offset must be 0");
        }

        while (true)
        {
            var read = Ws2_32.recv(_socket, buffer, count, 0);
            if (read > 0)
            {
                return read;
            }

            if (read == 0)
            {
                return 0;
            }

            var error = Ws2_32.WSAGetLastError();
            if (error == 10035)
            {
                Thread.Sleep(5);
                continue;
            }

            if (_closed)
            {
                return 0;
            }

            throw new IOException($"RFCOMM receive failed, WSA error {error}");
        }
    }

    public void Write(byte[] buffer, int offset, int count)
    {
        lock (_writeGate)
        {
            var sent = 0;
            while (sent < count)
            {
                var chunk = new byte[count - sent];
                Buffer.BlockCopy(buffer, offset + sent, chunk, 0, chunk.Length);
                var written = Ws2_32.send(_socket, chunk, chunk.Length, 0);
                if (written <= 0)
                {
                    throw new IOException($"RFCOMM send failed, WSA error {Ws2_32.WSAGetLastError()}");
                }

                sent += written;
            }
        }
    }

    public void Dispose()
    {
        if (_closed)
        {
            return;
        }

        _closed = true;
        Ws2_32.closesocket(_socket);
        Ws2_32.WSACleanup();
    }

    /// <summary>ws2bth.h declares SOCKADDR_BTH with 1-byte packing; the address must sit at offset 2.</summary>
    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct SockAddrBth
    {
        public ushort AddressFamily;
        public ulong BluetoothAddress;
        public Guid ServiceClassId;
        public uint Port;
    }

    private static class Ws2_32
    {
        [DllImport("ws2_32.dll")]
        public static extern int WSAStartup(ushort version, byte[] data);

        [DllImport("ws2_32.dll")]
        public static extern int WSACleanup();

        [DllImport("ws2_32.dll")]
        public static extern IntPtr socket(int family, int type, int protocol);

        [DllImport("ws2_32.dll")]
        public static extern int connect(IntPtr socket, ref SockAddrBth address, int length);

        [DllImport("ws2_32.dll")]
        public static extern int ioctlsocket(IntPtr socket, uint command, ref uint argument);

        [DllImport("ws2_32.dll")]
        public static extern int select(int ignored, IntPtr read, ref FdSet write, ref FdSet error, ref Timeval timeout);

        [DllImport("ws2_32.dll")]
        public static extern int getsockopt(IntPtr socket, int level, int option, out int value, ref int length);

        [DllImport("ws2_32.dll")]
        public static extern int recv(IntPtr socket, byte[] buffer, int count, int flags);

        [DllImport("ws2_32.dll")]
        public static extern int send(IntPtr socket, byte[] buffer, int count, int flags);

        [DllImport("ws2_32.dll")]
        public static extern int closesocket(IntPtr socket);

        [DllImport("ws2_32.dll")]
        public static extern int WSAGetLastError();
    }
}

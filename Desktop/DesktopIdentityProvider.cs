using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Security.Cryptography.X509Certificates;
using Iap2Loc.Protocol;

namespace Iap2Loc.Desktop;

internal sealed class DesktopIdentityProvider(DesktopSettings settings) : IIdentityProvider
{
    private readonly object _gate = new();
    private string ImportedPath => Path.Combine(DesktopSettings.DataDirectory, "identity.dpapi");
    public string Name => settings.UseImportedIdentity ? "导入身份" : "内置实验身份";
    public string? Warning { get; private set; }
    public string Detail { get; private set; } = "尚未检查身份材料";

    public MfiSigner? Resolve(string? directory, out string description)
    {
        if (!string.IsNullOrWhiteSpace(directory))
        {
            description = "指定目录";
            return MfiSigner.Load(directory);
        }
        lock (_gate)
        {
            var (key, certificate) = ReadMaterial();
            try
            {
                var signer = MfiSigner.FromMaterial(key, certificate);
                description = Name;
                return signer;
            }
            finally { CryptographicOperations.ZeroMemory(key); }
        }
    }

    public void Prime()
    {
        try
        {
            using var signer = Resolve(null, out var description);
            Warning = null;
            var certificates = new X509Certificate2Collection();
#pragma warning disable SYSLIB0057 // PKCS#7 certificate bundles are required by iAP2.
            certificates.Import(signer!.Certificate);
#pragma warning restore SYSLIB0057
            try
            {
                var expiry = certificates.Cast<X509Certificate2>().Min(cert => cert.NotAfter);
                Detail = $"{description} · 证书与私钥匹配 · 证书到期 {expiry:yyyy-MM-dd}";
                if (expiry < DateTime.Now) Detail += "（证书已过期，需连接设备确认是否接受）";
            }
            finally { foreach (var cert in certificates) cert.Dispose(); }
        }
        catch (Exception ex)
        {
            Warning = ChineseText.Error(ex);
            Detail = "身份材料不可用：" + Warning;
        }
    }

    public void Import(string file)
    {
        byte[] key;
        byte[] cert;
        if (Path.GetExtension(file).Equals(".apk", StringComparison.OrdinalIgnoreCase))
        {
            using var zip = ZipFile.OpenRead(file);
            key = ReadZip(zip, "assets/offline-mfi/identity.pk8");
            cert = ReadZip(zip, "assets/offline-mfi/certificate.p7b");
        }
        else
        {
            key = ReadBounded(file);
            cert = ReadBounded(Path.Combine(Path.GetDirectoryName(file)!, "certificate.p7b"));
        }
        try
        {
            using var signer = MfiSigner.FromMaterial(key, cert);
            using var buffer = new MemoryStream();
            using (var writer = new BinaryWriter(buffer, System.Text.Encoding.UTF8, true))
            {
                writer.Write(key.Length); writer.Write(key); writer.Write(cert.Length); writer.Write(cert);
            }
            var raw = buffer.ToArray();
            try
            {
                var protectedBytes = ProtectedData.Protect(raw, null, DataProtectionScope.CurrentUser);
                Directory.CreateDirectory(DesktopSettings.DataDirectory);
                var temporary = ImportedPath + ".tmp";
                File.WriteAllBytes(temporary, protectedBytes);
                File.Move(temporary, ImportedPath, true);
                settings.UseImportedIdentity = true;
                settings.Save();
            }
            finally { CryptographicOperations.ZeroMemory(raw); buffer.GetBuffer().AsSpan().Clear(); }
        }
        finally { CryptographicOperations.ZeroMemory(key); }
        Prime();
    }

    public void UseBuiltIn()
    {
        settings.UseImportedIdentity = false;
        settings.Save();
        Prime();
    }

    private (byte[] Key, byte[] Certificate) ReadMaterial()
    {
        if (settings.UseImportedIdentity)
        {
            var raw = ProtectedData.Unprotect(File.ReadAllBytes(ImportedPath), null, DataProtectionScope.CurrentUser);
            try
            {
                using var stream = new MemoryStream(raw);
                using var reader = new BinaryReader(stream);
                var key = ReadField(reader);
                try { return (key, ReadField(reader)); }
                catch { CryptographicOperations.ZeroMemory(key); throw; }
            }
            finally { CryptographicOperations.ZeroMemory(raw); }
        }
        return (ReadResource("identity.pk8"), ReadResource("certificate.p7b"));
    }

    private static byte[] ReadField(BinaryReader reader)
    {
        var size = reader.ReadInt32();
        if (size <= 0 || size > 65536) throw new InvalidDataException("身份材料格式错误");
        var bytes = reader.ReadBytes(size);
        if (bytes.Length != size) throw new InvalidDataException("身份材料不完整");
        return bytes;
    }

    private static byte[] ReadResource(string name)
    {
        using var stream = Assembly.GetExecutingAssembly().GetManifestResourceStream("Iap2Loc.Desktop.Private." + name)
            ?? throw new FileNotFoundException("此构建未包含内置身份，请导入 APK 或身份文件");
        using var memory = new MemoryStream(); stream.CopyTo(memory); return memory.ToArray();
    }

    private static byte[] ReadBounded(string file)
    {
        if (new FileInfo(file).Length > 65536) throw new InvalidDataException("身份文件过大");
        return File.ReadAllBytes(file);
    }

    private static byte[] ReadZip(ZipArchive zip, string name)
    {
        var entry = zip.GetEntry(name) ?? throw new InvalidDataException("该 APK 未包含可导入的本地身份材料");
        if (entry.Length > 65536) throw new InvalidDataException("APK 中的身份文件过大");
        using var stream = entry.Open(); using var memory = new MemoryStream(); stream.CopyTo(memory); return memory.ToArray();
    }
}

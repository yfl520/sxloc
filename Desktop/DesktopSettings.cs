using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Iap2Loc.Protocol;
using Iap2Loc.Engine;

namespace Iap2Loc.Desktop;

internal sealed class DesktopSettings
{
    public static string DataDirectory => Environment.GetEnvironmentVariable("SUIXING_DATA")
        ?? Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SuixingLoc");
    public static string SettingsPath => Path.Combine(DataDirectory, "desktop.json");
    public double Latitude { get; set; } = 31.2304;
    public double Longitude { get; set; } = 121.4737;
    public double Altitude { get; set; } = 10;
    public double Accuracy { get; set; } = 5;
    public double Speed { get; set; }
    public double Bearing { get; set; }
    public int Rate { get; set; } = 250;
    public int Quality { get; set; } = 1;
    public int Satellites { get; set; } = 8;
    public bool JitterPosition { get; set; }
    public bool JitterAccuracy { get; set; }
    public double JitterMeters { get; set; } = 10;
    public double AccuracyMin { get; set; } = 3;
    public double AccuracyMax { get; set; } = 12;
    public string Datum { get; set; } = "gcj";
    public string SearchProvider { get; set; } = "auto";
    public string SearchCity { get; set; } = "";
    public string PhotonEndpoint { get; set; } = "https://photon.komoot.io/api/";
    public string ProtectedAmapKey { get; set; } = "";
    public bool UseImportedIdentity { get; set; }
    public List<string> SearchHistory { get; set; } = new();

    [JsonIgnore]
    public string? LoadWarning { get; private set; }

    [JsonIgnore]
    public string AmapKey
    {
        get
        {
            try { return string.IsNullOrEmpty(ProtectedAmapKey) ? "" : Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(ProtectedAmapKey), null, DataProtectionScope.CurrentUser)); }
            catch { return ""; }
        }
        set => ProtectedAmapKey = string.IsNullOrWhiteSpace(value) ? "" : Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(value.Trim()), null, DataProtectionScope.CurrentUser));
    }

    public static DesktopSettings Load()
    {
        var adjusted = false;
        var settings = AtomicJsonFile.Read(SettingsPath, text =>
        {
            using var document = JsonDocument.Parse(text);
            if (document.RootElement.ValueKind != JsonValueKind.Object) throw new JsonException("配置格式无效");
            var value = new DesktopSettings();
            foreach (var property in typeof(DesktopSettings).GetProperties().Where(p => p.SetMethod?.IsPublic == true
                && p.GetCustomAttributes(typeof(JsonIgnoreAttribute), true).Length == 0))
            {
                if (!document.RootElement.TryGetProperty(property.Name, out var item)) continue;
                if (item.ValueKind == JsonValueKind.Null && property.PropertyType.IsValueType) { adjusted = true; continue; }
                try { property.SetValue(value, item.Deserialize(property.PropertyType)); }
                catch (JsonException) { adjusted = true; }
            }
            return value;
        }, out var warning) ?? new();
        var defaults = new DesktopSettings();
        void Check(string name, double min, double max)
        {
            var property = typeof(DesktopSettings).GetProperty(name)!;
            var value = Convert.ToDouble(property.GetValue(settings));
            if (double.IsFinite(value) && value >= min && value <= max) return;
            property.SetValue(settings, property.GetValue(defaults));
            adjusted = true;
        }
        Check(nameof(Latitude), -90, 90); Check(nameof(Longitude), -180, 180);
        Check(nameof(Altitude), -12000, 100000); Check(nameof(Accuracy), .1, 100000);
        Check(nameof(Speed), 0, 1000); Check(nameof(Bearing), 0, 359.999999);
        Check(nameof(Rate), 10, 60000); Check(nameof(Quality), 0, 8); Check(nameof(Satellites), 0, 99);
        Check(nameof(JitterMeters), 0, 10000); Check(nameof(AccuracyMin), .1, 100000); Check(nameof(AccuracyMax), .1, 100000);
        if (settings.AccuracyMin > settings.AccuracyMax)
        {
            settings.AccuracyMin = defaults.AccuracyMin; settings.AccuracyMax = defaults.AccuracyMax; adjusted = true;
        }
        settings.SearchHistory ??= new();
        settings.SearchHistory = settings.SearchHistory.Where(s => !string.IsNullOrWhiteSpace(s) && s.Length <= 200).Distinct().Take(15).ToList();
        settings.SearchCity ??= "";
        settings.PhotonEndpoint ??= defaults.PhotonEndpoint;
        settings.ProtectedAmapKey ??= "";
        if (settings.SearchProvider is not ("auto" or "amap" or "photon")) { settings.SearchProvider = "auto"; adjusted = true; }
        if (settings.Datum is not ("gcj" or "wgs")) { settings.Datum = "gcj"; adjusted = true; }
        if (adjusted)
        {
            AtomicJsonFile.Preserve(SettingsPath);
            warning = "部分本地设置无效，已保留原文件副本，仅重置异常字段。";
        }
        if (settings.ProtectedAmapKey.Length > 0 && settings.AmapKey.Length == 0)
            warning = string.Join(" ", new[] { warning, "高德 Key 无法解密，请在设置中重新填写；其余设置已保留。" }.Where(s => s is not null));
        settings.LoadWarning = warning;
        return settings;
    }

    public void Save()
    {
        AtomicJsonFile.Write(SettingsPath, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
    }

    public DesktopSettings Copy() => (DesktopSettings)MemberwiseClone();

    // Commit to disk before changing the shared instance used by search and identity services.
    public void Commit(DesktopSettings next)
    {
        next.Save();
        foreach (var property in typeof(DesktopSettings).GetProperties().Where(p => p.SetMethod?.IsPublic == true
            && p.GetCustomAttributes(typeof(JsonIgnoreAttribute), true).Length == 0))
            property.SetValue(this, property.GetValue(next));
    }

    public bool RememberSearch(string query)
    {
        var next = Copy();
        next.SearchHistory = new[] { query }.Concat(SearchHistory.Where(s => s != query)).Take(15).ToList();
        try { Commit(next); return true; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { return false; }
    }

    public TargetUpdate ToTargetUpdate() => new()
    {
        Latitude = Latitude, Longitude = Longitude, Altitude = Altitude, Accuracy = Accuracy,
        Speed = Speed, Bearing = Bearing, Quality = Quality, Satellites = Satellites,
        JitterPosition = JitterPosition, JitterAccuracy = JitterAccuracy, JitterMeters = JitterMeters,
        AccuracyMin = AccuracyMin, AccuracyMax = AccuracyMax,
    };
}

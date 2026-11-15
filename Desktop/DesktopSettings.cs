using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Iap2Loc.Protocol;

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
        try
        {
            var settings = JsonSerializer.Deserialize<DesktopSettings>(File.ReadAllText(SettingsPath)) ?? new();
            var target = new LocationTarget(settings.Latitude, settings.Longitude);
            target.Apply(settings.ToTargetUpdate());
            if (settings.Rate is < 10 or > 60000 || settings.Quality is < 0 or > 8 || settings.Satellites is < 0 or > 99
                || settings.Altitude is < -12000 or > 100000 || settings.Accuracy is < .1 or > 100000
                || settings.Speed is < 0 or > 1000 || settings.JitterMeters is < 0 or > 10000
                || settings.AccuracyMin is < .1 or > 100000 || settings.AccuracyMax is < .1 or > 100000)
                throw new ArgumentException("保存的定位参数超出范围");
            settings.SearchHistory ??= new();
            settings.SearchHistory = settings.SearchHistory.Where(s => !string.IsNullOrWhiteSpace(s) && s.Length <= 200).Distinct().Take(15).ToList();
            settings.SearchCity ??= "";
            settings.PhotonEndpoint ??= "https://photon.komoot.io/api/";
            if (settings.SearchProvider is not ("auto" or "amap" or "photon")) settings.SearchProvider = "auto";
            if (settings.Datum is not ("gcj" or "wgs")) settings.Datum = "gcj";
            return settings;
        }
        catch { return new(); }
    }

    public void Save()
    {
        Directory.CreateDirectory(DataDirectory);
        var temporary = SettingsPath + ".tmp";
        File.WriteAllText(temporary, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(temporary, SettingsPath, true);
    }

    public TargetUpdate ToTargetUpdate() => new()
    {
        Latitude = Latitude, Longitude = Longitude, Altitude = Altitude, Accuracy = Accuracy,
        Speed = Speed, Bearing = Bearing, Quality = Quality, Satellites = Satellites,
        JitterPosition = JitterPosition, JitterAccuracy = JitterAccuracy, JitterMeters = JitterMeters,
        AccuracyMin = AccuracyMin, AccuracyMax = AccuracyMax,
    };
}

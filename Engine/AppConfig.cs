using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;
using Iap2Loc.Protocol;

namespace Iap2Loc.Engine;

/// <summary>
/// The single file next to the executable: accessory identity and saved points.
///
/// The serial rotates on every start, because iOS keeps per-accessory location state and drops
/// fixes from an accessory whose last known position is far away. The Bluetooth address is
/// generated once and then reused, so the link still belongs to the same paired device.
/// </summary>
internal sealed class AppConfig
{
    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        WriteIndented = true,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    private readonly object _gate = new();

    public bool RandomizeIdentity { get; set; } = true;

    public bool RandomizeAdapter { get; set; } = true;

    public AccessoryProfile Accessory { get; set; } = AccessoryProfile.Default;

    public List<Favorite> Favorites { get; set; } = new();

    /// <summary>Runtime switch for --fixed-identity; never written to the file.</summary>
    [JsonIgnore]
    public bool RotateIdentityOnStart { get; set; } = true;

    /// <summary>Runtime switch for --fixed-adapter; never written to the file.</summary>
    [JsonIgnore]
    public bool UseAdapterOverride { get; set; } = true;

    [JsonIgnore]
    public AccessoryProfile EffectiveProfile =>
        RandomizeAdapter && UseAdapterOverride ? Accessory : Accessory with { AdapterAddress = null };

    [JsonIgnore]
    public string FilePath { get; private set; } = DefaultPath;

    [JsonIgnore]
    public string? LoadWarning { get; private set; }

    public static string DefaultPath => Path.Combine(AppContext.BaseDirectory, "iap2loc.json");

    public static AppConfig Load(string? path)
    {
        var config = new AppConfig
        {
            FilePath = string.IsNullOrWhiteSpace(path) ? DefaultPath : Path.GetFullPath(path),
        };

        var loaded = AtomicJsonFile.Read(config.FilePath, text =>
        {
            var value = JsonSerializer.Deserialize<AppConfig>(text, Json) ?? throw new JsonException("配置为空");
            return value;
        }, out var warning);
        if (loaded is not null)
        {
            loaded.FilePath = config.FilePath;
            loaded.Accessory = (loaded.Accessory ?? AccessoryProfile.Default).Sanitize();
            loaded.Favorites ??= new List<Favorite>();
            loaded.LoadWarning = warning;
            return loaded;
        }
        config.LoadWarning = warning;
        return config;
    }

    /// <summary>Rotates the identity and fills in the adapter address on first run, then persists both.</summary>
    public void PrepareForRun(byte[]? localAdapter)
    {
        lock (_gate)
        {
            var previous = Accessory;
            try
            {
                if (RandomizeIdentity && RotateIdentityOnStart)
                {
                    Accessory = Accessory.Rotate();
                }

                if (RandomizeAdapter && UseAdapterOverride && Accessory.AdapterOverride() is null)
                {
                    Accessory = Accessory with { AdapterAddress = AccessoryProfile.RandomAdapterAddress(localAdapter) };
                }

                SaveLocked();
                Log.Info($"配置 {FilePath}");
                Log.Info($"配件身份 {EffectiveProfile.Serial}，蓝牙地址 {EffectiveProfile.AdapterAddress ?? "本机"}");
            }
            catch { Accessory = previous; throw; }
        }
    }

    /// <summary>Rotates the identity and the reported adapter address together, then persists both.</summary>
    public AccessoryProfile RotateIdentity(byte[]? localAdapter)
    {
        lock (_gate)
        {
            var next = Accessory.Rotate();
            if (RandomizeAdapter && UseAdapterOverride)
            {
                next = next with { AdapterAddress = AccessoryProfile.RandomAdapterAddress(localAdapter) };
            }

            var previous = Accessory;
            Accessory = next;
            try { SaveLocked(); }
            catch { Accessory = previous; throw; }
            return EffectiveProfile;
        }
    }

    public void Save()
    {
        lock (_gate)
        {
            SaveLocked();
        }
    }

    public IReadOnlyList<Favorite> FavoritesSnapshot()
    {
        lock (_gate)
        {
            return Favorites.ToArray();
        }
    }

    public Favorite AddFavorite(string? name, double latitude, double longitude, double? altitude, double? accuracy)
    {
        _ = new LocationTarget(latitude, longitude);
        if (altitude is { } height && (!double.IsFinite(height) || height is < -12000 or > 100000)
            || accuracy is { } precision && (!double.IsFinite(precision) || precision is < .1 or > 100000))
            throw new ArgumentException("请检查高度和精度");
        var label = string.IsNullOrWhiteSpace(name) ? $"{latitude:F4}, {longitude:F4}" : name.Trim();
        var favorite = new Favorite(
            Guid.NewGuid().ToString("N")[..8], label, latitude, longitude, altitude, accuracy);

        lock (_gate)
        {
            var previous = Favorites.ToList();
            Favorites.Insert(0, favorite);
            if (Favorites.Count > 200)
            {
                Favorites.RemoveRange(200, Favorites.Count - 200);
            }

            try { SaveLocked(); }
            catch { Favorites = previous; throw; }
        }

        return favorite;
    }

    public bool RemoveFavorite(string id)
    {
        lock (_gate)
        {
            var previous = Favorites.ToList();
            var removed = Favorites.RemoveAll(item => item.Id == id) > 0;
            if (removed)
            {
                try { SaveLocked(); }
                catch { Favorites = previous; throw; }
            }

            return removed;
        }
    }

    private void SaveLocked()
    {
        AtomicJsonFile.Write(FilePath, JsonSerializer.Serialize(this, Json));
    }
}

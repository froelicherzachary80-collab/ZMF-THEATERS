using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ZMFTheaters.Jellyfin;

/// One connected Jellyfin account. The access token is encrypted with Windows
/// DPAPI (current user) before it is written to disk.
public sealed class ServerConfig
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N");
    public string Name { get; set; } = "";
    public string Url { get; set; } = "";
    public string Username { get; set; } = "";
    public string UserId { get; set; } = "";
    public string ProtectedToken { get; set; } = "";

    [JsonIgnore]
    public string? Token
    {
        get
        {
            if (string.IsNullOrEmpty(ProtectedToken)) return null;
            try
            {
                var raw = ProtectedData.Unprotect(Convert.FromBase64String(ProtectedToken), null, DataProtectionScope.CurrentUser);
                return Encoding.UTF8.GetString(raw);
            }
            catch { return null; }
        }
        set
        {
            ProtectedToken = value == null ? "" :
                Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser));
        }
    }

    [JsonIgnore] public bool IsHttps => Url.StartsWith("https://", StringComparison.OrdinalIgnoreCase);
    public override string ToString() => $"{Name}  ·  {Url}  ·  {Username}";
}

/// A YouTube link shown before the feature (official embedded player only).
/// Format: TwoD, ThreeD, FourDX or FourDX3D.
public sealed class YouTubePresentation
{
    public string VideoId { get; set; } = "";
    public string Title { get; set; } = "";
    public string Format { get; set; } = "TwoD";
    [JsonIgnore] public string FormatLabel => Format switch { "ThreeD" => "3D", "FourDX" => "4DX", "FourDX3D" => "4DX + 3D", _ => "2D" };
    public override string ToString() => $"{Title}  ·  {FormatLabel}  ·  youtu.be/{VideoId}";
}

public sealed class AppConfig
{
    public List<ServerConfig> Servers { get; set; } = new();
    public string DeviceId { get; set; } = Guid.NewGuid().ToString("N");
    public int Volume { get; set; } = 85;
    public bool Preshow { get; set; } = true;
    /// ZMF CASH (fictional) for the Windows box office.
    public int Balance { get; set; } = 5000;
    public int Popcorn { get; set; }
    /// Admin testing: allow 4DX outside the Oct 27–28 preview days.
    public bool Force4DX { get; set; }
    public bool AllDoorsUnlocked { get; set; }
    public List<YouTubePresentation> Presentations { get; set; } = new();
    /// Original ZMF roller-coaster intro before the feature, with announcer.
    public bool CoasterIntro { get; set; } = true;
    public bool CoasterVoice { get; set; } = true;
    /// 4DX water/mist/wind layer over your view; flashes are opt-in.
    public bool ScreenEffects { get; set; } = true;
    public bool ScreenFlashes { get; set; }

    static string Dir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ZMFTheaters");
    static string FilePath => Path.Combine(Dir, "config.json");

    public static AppConfig Load()
    {
        try
        {
            if (File.Exists(FilePath))
                return JsonSerializer.Deserialize<AppConfig>(File.ReadAllText(FilePath)) ?? new AppConfig();
        }
        catch { }
        return new AppConfig();
    }

    public void Save()
    {
        Directory.CreateDirectory(Dir);
        var tmp = FilePath + ".tmp";
        File.WriteAllText(tmp, JsonSerializer.Serialize(this, new JsonSerializerOptions { WriteIndented = true }));
        File.Move(tmp, FilePath, true);
    }
}

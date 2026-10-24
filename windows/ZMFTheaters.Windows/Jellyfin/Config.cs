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

public sealed class AppConfig
{
    public List<ServerConfig> Servers { get; set; } = new();
    public string DeviceId { get; set; } = Guid.NewGuid().ToString("N");
    public int Volume { get; set; } = 85;
    public bool Preshow { get; set; } = true;

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

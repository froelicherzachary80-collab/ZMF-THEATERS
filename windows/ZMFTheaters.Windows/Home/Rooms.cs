using System.IO;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace ZMFTheaters.Home;

public sealed class RoomMember
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N")[..10];
    public string Name { get; set; } = "";
    public string Kind { get; set; } = "Guest";     // Host, Guest, AI
    public string Seat { get; set; } = "";
    public DateTime JoinedAt { get; set; } = DateTime.UtcNow;
    public bool Present { get; set; } = true;
    [JsonIgnore] public DateTime LastSeen { get; set; } = DateTime.UtcNow;
}

public sealed class RoomItem
{
    public long Seq { get; set; }
    public DateTime At { get; set; } = DateTime.UtcNow;
    public string Kind { get; set; } = "chat";       // chat, join, leave, playback, effect, system
    public string From { get; set; } = "";
    public bool Ai { get; set; }
    public string Text { get; set; } = "";
}

public sealed class RoomPlayback
{
    public string Title { get; set; } = "";
    public string MediaId { get; set; } = "";
    public double Position { get; set; }
    public bool Playing { get; set; }
    public long UpdatedAtMs { get; set; }
    /// Position now, extrapolated from the last update (server clock).
    public double PositionAt(long nowMs) => Playing ? Position + (nowMs - UpdatedAtMs) / 1000.0 : Position;
}

public sealed class CinemaRoom
{
    public string Id { get; set; } = Guid.NewGuid().ToString("N")[..8];
    public string Name { get; set; } = "Private Cinema";
    public string InviteCode { get; set; } = NewCode(8);
    public string Genre { get; set; } = "";
    public DateTime CreatedAt { get; set; } = DateTime.UtcNow;
    public List<RoomMember> Members { get; set; } = new();
    public List<RoomItem> Items { get; set; } = new();
    public RoomPlayback Playback { get; set; } = new();
    public long NextSeq { get; set; } = 1;

    public static string NewCode(int n)
    {
        const string a = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
        return new string(Enumerable.Range(0, n).Select(_ => a[RandomNumberGenerator.GetInt32(a.Length)]).ToArray());
    }

    public RoomItem Add(string kind, string from, string text, bool ai = false)
    {
        var item = new RoomItem { Seq = NextSeq++, Kind = kind, From = from, Text = text.Length > 500 ? text[..500] : text, Ai = ai };
        Items.Add(item);
        if (Items.Count > 400) Items.RemoveRange(0, Items.Count - 400);
        return item;
    }

    public string FreeSeat()
    {
        var taken = Members.Where(m => m.Present).Select(m => m.Seat).ToHashSet();
        foreach (var row in "EFDGCHBA")
            for (int s = 1; s <= 8; s++) { var seat = $"{row}{s}"; if (!taken.Contains(seat)) return seat; }
        return "";
    }
}

/// Persistent private rooms (%APPDATA%\ZMFTheaters\rooms.json). Thread-safe.
public sealed class RoomStore
{
    readonly object gate = new();
    readonly string? file;
    public List<CinemaRoom> Rooms { get; } = new();
    public event Action<CinemaRoom, RoomItem>? ItemAdded;

    public RoomStore(string? file = null)
    {
        this.file = file;
        if (file != null && File.Exists(file))
            try { Rooms.AddRange(JsonSerializer.Deserialize<List<CinemaRoom>>(File.ReadAllText(file)) ?? new()); } catch { }
        foreach (var r in Rooms) foreach (var m in r.Members.Where(m => m.Kind != "AI")) m.Present = false;
    }

    public static string DefaultFile => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ZMFTheaters", "rooms.json");

    public T With<T>(Func<T> f) { lock (gate) { var r = f(); Save(); return r; } }

    public void Save()
    {
        if (file == null) return;
        lock (gate)
        {
            try { Directory.CreateDirectory(Path.GetDirectoryName(file)!); File.WriteAllText(file, JsonSerializer.Serialize(Rooms)); } catch { }
        }
    }

    public CinemaRoom? Find(string id) { lock (gate) return Rooms.FirstOrDefault(r => r.Id == id); }

    public RoomItem Post(CinemaRoom room, string kind, string from, string text, bool ai = false)
    {
        RoomItem item;
        lock (gate) { item = room.Add(kind, from, text, ai); }
        Save();
        ItemAdded?.Invoke(room, item);
        return item;
    }
}

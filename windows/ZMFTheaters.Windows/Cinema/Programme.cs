using ZMFTheaters.Jellyfin;

namespace ZMFTheaters.Cinema;

public sealed record Room(int Id, string Name, bool Is3D, int EraStart, int? EraEnd, string[] Primary, string[] Related, string Accent)
{
    public string Code => Id.ToString("00");
    public string Title => $"ROOM {Code} · {Name.ToUpperInvariant()}{(Is3D ? " · 3D" : "")}";

    public bool EraAllows(MediaEntry m) => m.Year is int y && y >= EraStart && (EraEnd is not int end || y <= end);

    bool Matches(MediaEntry m, string[] terms) { var hay = m.Terms.ToList(); return terms.Any(t => hay.Any(h => h.Contains(t))); }

    public bool PrimaryMatch(MediaEntry m) => Id switch { 12 => (m.CommunityRating ?? 0) >= 7.5, 1 => true, _ => Matches(m, Primary) };
    public bool RelatedMatch(MediaEntry m) => Id == 12 || Id == 1 || Matches(m, Related);
}

/// The same twelve auditoriums and programming rules as the iPhone app.
public static class Rooms
{
    public static readonly Room[] All =
    {
        new(1, "Classic Century", false, 1900, 1999, Array.Empty<string>(), Array.Empty<string>(), "#D9A640"),
        new(2, "Action Arena", false, 2000, null, new[] { "action", "war", "spy", "martial" }, new[] { "thriller", "crime", "adventure", "western" }, "#FF7314"),
        new(3, "Adventure Hall", false, 2000, null, new[] { "adventure" }, new[] { "action", "fantasy", "western", "family", "history" }, "#5A8C40"),
        new(4, "Romance Lounge", false, 2000, null, new[] { "romance" }, new[] { "drama", "music", "comedy" }, "#F2A69A"),
        new(5, "Horror Chamber", false, 2000, null, new[] { "horror" }, new[] { "thriller", "mystery", "supernatural", "paranormal" }, "#990D0D"),
        new(6, "Comedy Club", false, 2000, null, new[] { "comedy" }, new[] { "family", "animation", "music" }, "#FFD933"),
        new(7, "Superhero Universe", true, 2000, null, new[] { "superhero", "marvel", "dc comics", "dc films", "comic" }, new[] { "action", "science fiction", "sci-fi", "fantasy" }, "#E61F26"),
        new(8, "Fantasy Kingdom", true, 2000, null, new[] { "fantasy" }, new[] { "adventure", "family", "animation", "mythology" }, "#4DF2A6"),
        new(9, "Sci-Fi Galaxy", true, 2000, null, new[] { "science fiction", "sci-fi", "space" }, new[] { "action", "adventure", "thriller" }, "#1AE6FF"),
        new(10, "Animation World", true, 2000, null, new[] { "animation", "anime" }, new[] { "family", "kids", "comedy", "fantasy" }, "#FF9933"),
        new(11, "Mystery Vault", true, 2000, null, new[] { "mystery", "thriller", "crime" }, new[] { "drama", "horror", "suspense" }, "#CCB366"),
        new(12, "Premiere Palace", true, 2000, null, Array.Empty<string>(), Array.Empty<string>(), "#FFD159"),
    };

    public static Room Get(int id) => All[Math.Clamp(id - 1, 0, 11)];

    public static Room BestFor(MediaEntry m)
    {
        if (m.Year is int y && y < 2000) return Get(1);
        var ordered = All.Where(r => r.Id != 1 && r.Id != 12).ToList();
        return ordered.FirstOrDefault(r => r.PrimaryMatch(m)) ?? ordered.FirstOrDefault(r => r.RelatedMatch(m)) ?? Get(12);
    }
}

/// Port of the iPhone RotationDirector: 12 featured films every 3 days,
/// counted from 23 Oct 2026 00:00 America/New_York, seeded SplitMix64.
public static class RotationDirector
{
    public static readonly DateTime Anchor = new DateTimeOffset(2026, 10, 23, 0, 0, 0, TimeSpan.FromHours(-4)).UtcDateTime;
    public const int Days = 3;
    public const ulong Seed = 2026;
    static readonly int[] FillOrder = { 1, 7, 5, 4, 10, 8, 9, 11, 6, 2, 3, 12 };

    public static int PeriodIndex(DateTime utcNow) => (int)Math.Floor((utcNow - Anchor).TotalSeconds / (Days * 86400.0));
    public static (DateTime start, DateTime end) Bounds(int index) => (Anchor.AddDays(index * Days), Anchor.AddDays((index + 1) * Days));

    sealed class SplitMix64
    {
        ulong state;
        public SplitMix64(ulong seed) { state = seed; }
        public ulong Next()
        {
            unchecked
            {
                state += 0x9E3779B97F4A7C15UL;
                ulong z = state;
                z = (z ^ (z >> 30)) * 0xBF58476D1CE4E5B9UL;
                z = (z ^ (z >> 27)) * 0x94D049BB133111EBUL;
                return z ^ (z >> 31);
            }
        }
    }

    public static Dictionary<int, MediaEntry> Select(IEnumerable<MediaEntry> movies, int index)
    {
        var rng = new SplitMix64(unchecked(Seed ^ ((ulong)(long)index * 0x2545F4914F6CDD1DUL)));
        var pool = movies.Where(m => m.Type == "Movie")
            .OrderBy(m => m.Id, StringComparer.Ordinal).ThenBy(m => m.Server.Id, StringComparer.Ordinal).ToList();
        var used = new HashSet<string>();
        var result = new Dictionary<int, MediaEntry>();

        MediaEntry? Pick(List<MediaEntry> list) => list.Count == 0 ? null : list[(int)(rng.Next() % (ulong)list.Count)];

        foreach (var id in FillOrder)
        {
            var room = Rooms.Get(id);
            var era = pool.Where(room.EraAllows).ToList();
            var levels = new[]
            {
                era.Where(m => room.PrimaryMatch(m) && !used.Contains(m.Id)).ToList(),
                era.Where(m => room.RelatedMatch(m) && !used.Contains(m.Id)).ToList(),
                era.Where(m => !used.Contains(m.Id)).ToList(),
                era,
            };
            foreach (var level in levels)
            {
                var chosen = Pick(level);
                if (chosen == null) continue;
                result[id] = chosen;
                used.Add(chosen.Id);
                break;
            }
        }
        return result;
    }
}

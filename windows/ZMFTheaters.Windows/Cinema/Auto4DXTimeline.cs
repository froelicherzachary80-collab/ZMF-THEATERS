namespace ZMFTheaters.Cinema;

// AUTO4DX event model and playback-clock scheduler.
// The model uses plain value types (strings, doubles, flag enums) so it maps
// 1:1 onto a Swift struct + OptionSet for the iOS port.

public enum Auto4DXEventType { Rumble, Impact, Wind, Water, Flash, Smoke, SeatMotion }

[Flags]
public enum Auto4DXTargets { None = 0, Seat = 1, Haptics = 2, Light = 4, Smoke = 8, Wind = 16, Water = 32 }

public enum Auto4DXSafety { Gentle, Moderate, Strong, Photosensitive }

public enum Auto4DXCancel { Immediate, FadeOut }

/// Where the evidence for an event came from. Synthetic events exist only for
/// automated tests; nothing in the app currently produces Detector events.
public enum Auto4DXSource { SyntheticTest, Detector }

public readonly record struct Auto4DXDirection(double X, double Y, double Z)
{
    public static readonly Auto4DXDirection Center = new(0, 0, 0);
    public bool IsValid => double.IsFinite(X) && double.IsFinite(Y) && double.IsFinite(Z)
                           && Math.Abs(X) <= 1 && Math.Abs(Y) <= 1 && Math.Abs(Z) <= 1;
}

public sealed record Auto4DXEvent(
    string Id,
    Auto4DXEventType Type,
    double Timestamp,          // movie time, seconds
    double Confidence,         // 0–1
    double Intensity,          // 0–1
    double Duration,           // seconds, > 0
    Auto4DXDirection Direction,
    string Preset,
    Auto4DXTargets Targets,
    Auto4DXSafety Safety,
    Auto4DXCancel Cancel,
    double Decay,              // fade-out seconds
    Auto4DXSource Source,
    string DetectorId,
    int Priority = 0)
{
    public const double MaxDuration = 30, MaxDecay = 5;

    public string? Validate()
    {
        if (string.IsNullOrWhiteSpace(Id)) return "missing id";
        if (!Enum.IsDefined(Type)) return "unknown type";
        if (!double.IsFinite(Timestamp) || Timestamp < 0) return "invalid timestamp";
        if (!double.IsFinite(Confidence) || Confidence is < 0 or > 1) return "confidence outside 0–1";
        if (!double.IsFinite(Intensity) || Intensity is < 0 or > 1) return "intensity outside 0–1";
        if (!double.IsFinite(Duration) || Duration <= 0 || Duration > MaxDuration) return "invalid duration";
        if (!double.IsFinite(Decay) || Decay < 0 || Decay > MaxDecay) return "invalid decay";
        if (!Direction.IsValid) return "invalid direction";
        if (Targets == Auto4DXTargets.None || (Targets & ~(Auto4DXTargets)63) != 0) return "invalid targets";
        if (!Enum.IsDefined(Safety) || !Enum.IsDefined(Cancel) || !Enum.IsDefined(Source)) return "unknown enum value";
        if (string.IsNullOrWhiteSpace(Preset)) return "missing preset";
        if (string.IsNullOrWhiteSpace(DetectorId)) return "missing detector id";
        return null;
    }
}

/// Dispatches events from the media playback clock (never wall clock).
/// Call Update every rendered frame with the player's current position.
public sealed class Auto4DXScheduler
{
    sealed class Active { public required Auto4DXEvent E; public double Start; public double Fade = 1; public bool Releasing; }

    readonly List<Auto4DXEvent> events = new();
    readonly List<Active> active = new();
    readonly HashSet<string> fired = new();
    readonly Dictionary<Auto4DXEventType, double> lastFire = new();
    readonly Dictionary<Auto4DXTargets, double> levels = new();
    int cursor;
    double lastMedia = double.NaN;
    bool wasPlaying;

    public string? MovieId { get; private set; }
    /// Output latency compensation: events fire this early on the media clock.
    public double LatencySeconds { get; set; } = 0.08;
    /// Media-time jumps above this are treated as seeks, not playback.
    public double SeekThreshold { get; set; } = 0.75;
    public double MinConfidence { get; set; } = 0.5;
    /// Output smoothing time constant (seconds) and pause/stop fade length.
    public double Smoothing { get; set; } = 0.06;
    public double CancelFade { get; set; } = 0.25;
    public Dictionary<Auto4DXEventType, double> Cooldowns { get; } = new()
    {
        [Auto4DXEventType.Impact] = 0.5, [Auto4DXEventType.Flash] = 2.0, [Auto4DXEventType.Water] = 1.0,
    };

    public IReadOnlyList<string> Rejected => rejected;
    readonly List<string> rejected = new();
    public IReadOnlyList<string> Dispatched => dispatched;
    readonly List<string> dispatched = new();
    public int ActiveCount => active.Count;

    /// Loads a movie's event track. A different movie id resets all state.
    public void Load(string movieId, IEnumerable<Auto4DXEvent> track)
    {
        if (movieId != MovieId) { Stop(); fired.Clear(); }
        MovieId = movieId;
        events.Clear(); rejected.Clear(); dispatched.Clear();
        var ids = new HashSet<string>();
        foreach (var e in track)
        {
            var err = e.Validate() ?? (ids.Add(e.Id) ? null : "duplicate id");
            if (err != null) rejected.Add($"{e.Id}: {err}");
            else events.Add(e);
        }
        events.Sort((a, b) => a.Timestamp != b.Timestamp ? a.Timestamp.CompareTo(b.Timestamp)
                            : a.Priority != b.Priority ? b.Priority.CompareTo(a.Priority)
                            : string.CompareOrdinal(a.Id, b.Id));
        cursor = 0; lastMedia = double.NaN;
    }

    public IReadOnlyList<Auto4DXEvent> Events => events;

    public double Level(Auto4DXTargets target) => levels.TryGetValue(target, out var v) ? v : 0;
    public Auto4DXDirection Direction { get; private set; }

    /// mediaTime: player position (s). dt: render delta used only to ease output.
    public void Update(double mediaTime, bool playing, double dt)
    {
        dt = double.IsFinite(dt) ? Math.Clamp(dt, 0, 0.1) : 0;
        if (!double.IsFinite(mediaTime) || mediaTime < 0) { Cancel(); Ease(dt); return; }

        if (!playing)
        {
            if (wasPlaying) Cancel();
            wasPlaying = false;
            FadeReleasing(dt);
            Ease(dt);
            lastMedia = mediaTime;
            return;
        }
        if (double.IsFinite(lastMedia) && (mediaTime < lastMedia - 0.05 || mediaTime - lastMedia > SeekThreshold))
            Seek(mediaTime);
        else if (double.IsNaN(lastMedia)) Reposition(mediaTime);
        wasPlaying = true;
        lastMedia = mediaTime;

        var horizon = mediaTime + LatencySeconds;
        while (cursor < events.Count && events[cursor].Timestamp <= horizon)
        {
            var e = events[cursor++];
            if (!fired.Add(e.Id)) continue;                       // duplicate
            if (e.Confidence < MinConfidence) continue;
            if (Cooldowns.TryGetValue(e.Type, out var cd) && lastFire.TryGetValue(e.Type, out var lf) && e.Timestamp - lf < cd) continue;
            lastFire[e.Type] = e.Timestamp;
            active.Add(new Active { E = e, Start = e.Timestamp });
            dispatched.Add(e.Id);
        }

        foreach (var a in active)
        {
            if (!a.Releasing && horizon >= a.Start + a.E.Duration)
            {
                a.Releasing = true;
                if (a.E.Cancel == Auto4DXCancel.Immediate) a.Fade = 0;
            }
        }
        FadeReleasing(dt);
        Ease(dt);
    }

    /// Explicit seek notification (also detected automatically from the clock).
    public void Seek(double mediaTime)
    {
        active.Clear();
        Reposition(mediaTime);
        lastMedia = mediaTime;
    }

    void Reposition(double mediaTime)
    {
        // Events behind the new position are skipped, never replayed late; on a
        // backward seek, events ahead become eligible again.
        var horizon = mediaTime + LatencySeconds;
        cursor = 0;
        while (cursor < events.Count && events[cursor].Timestamp < horizon - 0.0001) cursor++;
        for (int i = cursor; i < events.Count; i++) fired.Remove(events[i].Id);
        foreach (var k in lastFire.Where(kv => kv.Value >= mediaTime).Select(kv => kv.Key).ToList()) lastFire.Remove(k);
    }

    /// Pause / interruption: active effects release smoothly.
    public void Cancel()
    {
        foreach (var a in active) { a.Releasing = true; }
    }

    /// Stop / end / movie change: everything returns to neutral immediately.
    public void Stop()
    {
        active.Clear(); levels.Clear(); lastFire.Clear();
        Direction = Auto4DXDirection.Center;
        cursor = 0; lastMedia = double.NaN; wasPlaying = false;
    }

    void FadeReleasing(double dt)
    {
        foreach (var a in active.Where(a => a.Releasing))
        {
            var len = a.E.Cancel == Auto4DXCancel.Immediate ? 0 : Math.Max(CancelFade, a.E.Decay);
            a.Fade = len <= 0 ? 0 : Math.Max(0, a.Fade - dt / len);
        }
        active.RemoveAll(a => a.Fade <= 0);
    }

    void Ease(double dt)
    {
        var k = Smoothing <= 0 ? 1 : 1 - Math.Exp(-dt / Smoothing);
        double bestW = 0; var dir = Auto4DXDirection.Center;
        for (int bit = 1; bit <= 32; bit <<= 1)
        {
            var t = (Auto4DXTargets)bit;
            // Priority arbitration per output: the highest-priority active event
            // owns the channel; overlapping peers of equal priority take the max.
            double target = 0; int top = int.MinValue;
            foreach (var a in active)
            {
                if ((a.E.Targets & t) == 0) continue;
                var v = a.E.Intensity * a.Fade;
                if (a.E.Priority > top) { top = a.E.Priority; target = v; }
                else if (a.E.Priority == top) target = Math.Max(target, v);
                if (v > bestW) { bestW = v; dir = a.E.Direction; }
            }
            var cur = Level(t);
            var next = cur + (target - cur) * k;
            if (next < 0.001 && target == 0) next = 0;
            levels[t] = next;
        }
        Direction = dir;
    }
}

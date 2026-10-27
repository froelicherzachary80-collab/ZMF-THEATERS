using System.IO;
using System.Text.Json;

namespace ZMFTheaters.Home;

/// Unified 4DX event shared by the cinema, home devices, the phone companion
/// and private rooms.
public sealed record FourDXEvent(
    string Type,                 // Wind, Lighting, Blast, Hit, Debris, Calm
    string MediaId,
    double Timestamp,            // media seconds
    double Duration,
    double Confidence,           // 0–1
    double Intensity,            // 0–1
    string Direction,            // "front", "all", …
    string[] VirtualOutputs,     // e.g. wind particles, smoke
    string[] PhysicalTargets,    // e.g. TAPO_01, GOVEE
    double Cooldown,
    string Safety,               // gentle, moderate, strong, photosensitive
    string Evidence,             // what the decision is based on
    bool Cancelled = false);

/// Where the analysis signals come from. Only Analysed and CachedTimeline
/// may drive physical devices automatically.
public enum AnalysisSource { None, Analysed, CachedTimeline, Ride, ExternalUnanalysable }

public readonly record struct SceneInputs(
    string MediaId, double MediaTime, bool Playing, AnalysisSource Source,
    double Wind, double CameraSpeed, double SustainedLow, double SpeechShare, double Shock, bool SoundAnalysis,
    double AvgR, double AvgG, double AvgB, double Brightness, double TopBlue, string? LastEventKind, double LastEventTime);

public readonly record struct LightTarget(byte R, byte G, byte B, double Brightness, string Palette);

/// Decides physical/virtual home effects from what the film actually shows
/// and sounds like. Labels are honest heuristics ("sustained motion with
/// engine-like rumble"), not object recognition — it cannot tell a
/// helicopter from a truck.
public sealed class SceneDirector
{
    public EffectLevel Level { get; set; } = EffectLevel.Standard;
    public FlashPolicy Flashes { get; set; } = FlashPolicy.Reduced;

    // Wind (fan) state with hysteresis.
    double windScore, windHighFor, windLowFor;
    public bool WantWind { get; private set; }
    public double WindConfidence { get; private set; }
    public string WindEvidence { get; private set; } = "";

    // Lighting state with palette stabilisation.
    string palette = "neutral", candidate = "neutral";
    double candidateFor;
    double r = 255, g = 170, b = 90, brightness = 0.35, pulse;
    public LightTarget Light => new((byte)r, (byte)g, (byte)b, Math.Clamp(brightness + pulse, 0.05, MaxBrightness), palette);
    public string Scene { get; private set; } = "Waiting for playback";
    public double SceneConfidence { get; private set; }
    public string State { get; private set; } = "Idle";

    readonly List<FourDXEvent> log = new();
    public IReadOnlyList<FourDXEvent> Log => log;
    public event Action<FourDXEvent>? Emitted;
    double windStart = -1;
    string mediaId = "";
    double lastTime = double.NaN;

    double OnThreshold => Level switch { EffectLevel.Gentle => 0.7, EffectLevel.Intense => 0.48, EffectLevel.Extreme => 0.4, _ => 0.56 };
    double SustainSeconds => Level switch { EffectLevel.Gentle => 4.5, EffectLevel.Intense => 2.5, EffectLevel.Extreme => 2.0, _ => 3.2 };
    double MaxBrightness => Level switch { EffectLevel.Gentle => 0.45, EffectLevel.Intense => 0.8, EffectLevel.Extreme => 0.9, _ => 0.65 };

    static readonly Dictionary<string, (byte r, byte g, byte b)> Palettes = new()
    {
        ["neutral"] = (255, 170, 90),      // warm indoor
        ["ocean"] = (0, 120, 160),         // dark turquoise / sea blue
        ["forest"] = (40, 160, 50),        // green and gold
        ["fire"] = (255, 90, 10),          // fire orange
        ["night"] = (40, 40, 140),         // space / indigo
        ["horror"] = (40, 60, 120),        // muted blue
        ["sunset"] = (255, 120, 40),       // amber
        ["scifi"] = (0, 200, 220),         // cyan
        ["fantasy"] = (130, 40, 200),      // purple
        ["romance"] = (255, 110, 120),     // rose / amber
    };
    public static IReadOnlyDictionary<string, (byte r, byte g, byte b)> PaletteColors => Palettes;

    public void Update(in SceneInputs x, double dt)
    {
        dt = Math.Clamp(double.IsFinite(dt) ? dt : 0, 0, 0.25);
        if (x.MediaId != mediaId) { Reset("new media"); mediaId = x.MediaId; }
        if (double.IsFinite(lastTime) && (x.MediaTime < lastTime - 0.5 || x.MediaTime - lastTime > 2.0)) Reset("seek");
        lastTime = x.MediaTime;
        if (!x.Playing) { Cancel("paused"); State = "Paused — all effects suspended"; return; }
        if (x.Source == AnalysisSource.ExternalUnanalysable)
        {
            Cancel("source not analysable");
            State = "This source exposes no frames/audio for analysis — automatic physical effects disabled";
            Scene = "Unknown (not analysable)"; SceneConfidence = 0;
            return;
        }
        if (x.Source == AnalysisSource.None) { Cancel("no source"); State = "Idle"; return; }
        State = x.Source switch { AnalysisSource.CachedTimeline => "Replaying this title's analysed timeline", AnalysisSource.Ride => "ZMF ride timeline", _ => x.SoundAnalysis ? "Analysing picture + sound" : "Analysing picture (no sound analysis)" };

        // --- Scene estimate (honest heuristic labels) ---
        bool dialogue = x.SoundAnalysis && x.SpeechShare > 0.62 && x.CameraSpeed < 0.25 && x.Shock < 0.05;
        bool engine = x.SustainedLow > 0.35;
        bool sustainedMotion = x.CameraSpeed > 0.35;
        string scene; double conf;
        if (x.Shock > 0.3) { scene = "Blast (sound-detected boom)"; conf = Math.Min(1, x.Shock); }
        else if (sustainedMotion && engine) { scene = "Sustained motion with engine-like rumble (flight/driving-like)"; conf = Math.Min(1, (x.CameraSpeed + x.SustainedLow) / 1.6); }
        else if (sustainedMotion) { scene = "Sustained camera motion (chase/flight/outdoor-like)"; conf = Math.Min(1, x.CameraSpeed); }
        else if (dialogue) { scene = "Dialogue-like (quiet, speech band, little motion)"; conf = Math.Min(1, x.SpeechShare); }
        else { scene = "Calm"; conf = 0.4; }
        Scene = scene; SceneConfidence = conf;

        // --- Wind: only for sustained air-movement-like scenes ---
        var outdoor = x.TopBlue > 0.12 ? 0.15 : 0;
        var target = dialogue ? 0 : Math.Clamp(x.Wind * 0.7 + x.SustainedLow * (sustainedMotion ? 0.5 : 0.15) + outdoor + (sustainedMotion ? 0.15 : 0), 0, 1);
        windScore += (target - windScore) * (1 - Math.Exp(-dt / 0.8));
        if (windScore > OnThreshold) { windHighFor += dt; windLowFor = 0; } else if (windScore < OnThreshold * 0.55) { windLowFor += dt; windHighFor = 0; }
        if (!WantWind && windHighFor >= SustainSeconds)
        {
            WantWind = true; windStart = x.MediaTime; WindConfidence = Math.Min(1, windScore);
            WindEvidence = $"{scene}; wind score {windScore:0.00} for {windHighFor:0.0}s";
            Emit(new FourDXEvent("Wind", mediaId, x.MediaTime, 0, WindConfidence, windScore, "front",
                new[] { "wind particles", "wind streaks" }, new[] { "MAIN_WIND" }, 12, "gentle", WindEvidence));
        }
        else if (WantWind && windLowFor >= 4)
        {
            WantWind = false;
            Emit(new FourDXEvent("Wind", mediaId, windStart, x.MediaTime - windStart, WindConfidence, 0, "front",
                Array.Empty<string>(), new[] { "MAIN_WIND" }, 12, "gentle", "wind scene ended", Cancelled: false));
        }

        // --- Lighting: stable cinematic palette from the picture's colour ---
        var want = dialogue ? "neutral" : ClassifyPalette(x);
        if (want == candidate) candidateFor += dt; else { candidate = want; candidateFor = 0; }
        if (candidate != palette && candidateFor > 2.5)
        {
            palette = candidate;
            Emit(new FourDXEvent("Lighting", mediaId, x.MediaTime, 0, 0.6, 0.5, "room", new[] { "room illumination" }, new[] { "GOVEE" }, 2.5, "gentle",
                $"palette {palette} held 2.5s (avg colour {x.AvgR:0},{x.AvgG:0},{x.AvgB:0})"));
        }
        var (pr, pg, pb) = Palettes[palette];
        var k = 1 - Math.Exp(-dt / 1.2);           // slow, smooth transitions
        r += (pr - r) * k; g += (pg - g) * k; b += (pb - b) * k;
        var targetBright = dialogue ? 0.2 : Math.Clamp(0.15 + x.Brightness * 0.6, 0.1, MaxBrightness);
        brightness += (targetBright - brightness) * k;
        // Blast: brief warm brightness swell, never a strobe.
        if (x.LastEventKind == "Boom" && Math.Abs(x.MediaTime - x.LastEventTime) < 0.3 && Flashes != FlashPolicy.NoFlashing && pulse < 0.05)
        {
            pulse = Flashes == FlashPolicy.Reduced ? 0.12 : 0.22;
            Emit(new FourDXEvent("Blast", mediaId, x.MediaTime, 1.5, Math.Min(1, x.Shock + 0.3), x.Shock, "front",
                new[] { "shockwave", "embers", "smoke" }, new[] { "GOVEE" }, 1.5, Flashes == FlashPolicy.Reduced ? "photosensitive-reduced" : "moderate", "sound-detected boom"));
        }
        pulse *= Math.Exp(-dt / 0.7);
    }

    static string ClassifyPalette(in SceneInputs x)
    {
        double r = x.AvgR, g = x.AvgG, b = x.AvgB, max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
        var sat = max < 1 ? 0 : (max - min) / max;
        if (x.Brightness < 0.12) return x.Shock > 0.2 ? "fire" : "night";
        if (sat < 0.18) return x.Brightness < 0.3 ? "horror" : "neutral";
        if (r > g * 1.25 && r > b * 1.5) return g > b * 1.4 && r < g * 1.8 ? "sunset" : "fire";
        if (g > r * 1.1 && g > b * 1.1) return "forest";
        if (b > r * 1.2 && g > r * 1.1) return "ocean";
        if (b > r * 1.2) return "night";
        if (r > g && b > g) return "fantasy";
        return "neutral";
    }

    /// Replays a previously analysed timeline (e.g. while the film plays on
    /// the iPhone). Nothing is invented for gaps in the timeline.
    public void ApplyTimeline(EffectTimeline tl, double mediaTime, bool playing, double dt)
    {
        if (tl.MediaId != mediaId) { Reset("new media"); mediaId = tl.MediaId; }
        lastTime = mediaTime;
        if (!playing) { Cancel("paused"); State = "Paused — all effects suspended"; return; }
        State = "Replaying this title's analysed timeline";
        var wind = tl.WindAt(mediaTime);
        if (wind != WantWind)
        {
            WantWind = wind; WindConfidence = wind ? 0.7 : 0;
            WindEvidence = wind ? "cached analysed wind segment" : "";
            Emit(new FourDXEvent("Wind", mediaId, mediaTime, 0, WindConfidence, wind ? 0.7 : 0, "front", wind ? new[] { "wind particles" } : Array.Empty<string>(),
                new[] { "MAIN_WIND" }, 12, "gentle", wind ? "timeline" : "timeline segment ended"));
        }
        if (tl.LightAt(mediaTime) is { } key)
        {
            palette = key.Palette;
            var k = 1 - Math.Exp(-Math.Clamp(dt, 0, 0.25) / 1.2);
            r += (key.R - r) * k; g += (key.G - g) * k; b += (key.B - b) * k; brightness += (key.Brightness - brightness) * k;
        }
        Scene = "From analysed timeline"; SceneConfidence = 0.7;
    }

    void Emit(FourDXEvent e) { log.Add(e); if (log.Count > 500) log.RemoveAt(0); Emitted?.Invoke(e); }

    /// Pause/stop/emergency: drop active requests immediately.
    public void Cancel(string reason)
    {
        if (WantWind) Emit(new FourDXEvent("Wind", mediaId, lastTime, 0, WindConfidence, 0, "front", Array.Empty<string>(), new[] { "MAIN_WIND" }, 12, "gentle", reason, Cancelled: true));
        WantWind = false; windScore = 0; windHighFor = 0; windLowFor = 0; pulse = 0;
    }

    /// Seek/new media: discard stale state.
    public void Reset(string reason)
    {
        Cancel(reason);
        candidate = palette; candidateFor = 0; lastTime = double.NaN;
    }
}

/// Per-title timeline of the director's decisions, recorded while the PC
/// analyses a film and replayed later (e.g. when the film plays on the
/// iPhone). No timeline → no automatic physical effects for that title.
public sealed class EffectTimeline
{
    public int Version { get; set; } = 1;
    public string MediaId { get; set; } = "";
    public List<Segment> Wind { get; set; } = new();
    public List<LightKey> Lights { get; set; } = new();
    public sealed record Segment(double Start, double End, double Confidence);
    public sealed record LightKey(double Time, byte R, byte G, byte B, double Brightness, string Palette);

    static string Dir => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ZMFTheaters", "timelines");
    static string FileFor(string mediaId) => Path.Combine(Dir, string.Concat(mediaId.Select(c => char.IsLetterOrDigit(c) ? c : '_')) + ".json");

    public bool WindAt(double t) => Wind.Any(s => t >= s.Start && t < s.End);
    public LightKey? LightAt(double t) => Lights.LastOrDefault(k => k.Time <= t);

    public static EffectTimeline? Load(string mediaId)
    {
        try { var f = FileFor(mediaId); return File.Exists(f) ? JsonSerializer.Deserialize<EffectTimeline>(File.ReadAllText(f)) : null; }
        catch { return null; }
    }

    public void Save()
    {
        try { Directory.CreateDirectory(Dir); File.WriteAllText(FileFor(MediaId), JsonSerializer.Serialize(this)); } catch { }
    }

    /// Records from director events (wind start/stop pairs and palette changes).
    public void Record(FourDXEvent e, LightTarget light)
    {
        if (e.Type == "Wind" && e.Duration > 0 && !e.Cancelled)
        {
            Wind.RemoveAll(s => s.Start < e.Timestamp + e.Duration && s.End > e.Timestamp);
            Wind.Add(new Segment(e.Timestamp, e.Timestamp + e.Duration, e.Confidence));
            Wind.Sort((a, b) => a.Start.CompareTo(b.Start));
        }
        else if (e.Type == "Lighting")
        {
            Lights.RemoveAll(k => Math.Abs(k.Time - e.Timestamp) < 1);
            Lights.Add(new LightKey(e.Timestamp, light.R, light.G, light.B, light.Brightness, light.Palette));
            Lights.Sort((a, b) => a.Time.CompareTo(b.Time));
        }
    }
}

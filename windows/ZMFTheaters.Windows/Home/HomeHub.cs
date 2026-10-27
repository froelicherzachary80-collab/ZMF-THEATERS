namespace ZMFTheaters.Home;

/// Current playback the Home 4DX brain is following.
public sealed record PlaybackState(string Source, string MediaId, string Title, double Position, bool Playing, long ServerTimeMs, AnalysisSource Analysis);

/// Shared state between the cinema window, the device controller, the scene
/// director, the private-room host and the phone companion.
public sealed class HomeHub : IAsyncDisposable
{
    public static HomeHub? Current { get; set; }
    public HomeConfig Config { get; }
    public HomeController Devices { get; }
    public SceneDirector Director { get; } = new();
    public RoomStore Rooms { get; }
    public AiGuestEngine Ai { get; } = new();
    public CinemaHost? Host { get; private set; }
    public Func<DateTime> Clock { get; set; } = () => DateTime.UtcNow;
    public long NowMs => new DateTimeOffset(Clock()).ToUnixTimeMilliseconds();

    /// Playback reported by the PC cinema (when it is screening).
    public PlaybackState? PcPlayback { get; private set; }
    /// Playback reported by the iPhone (native app or web companion).
    public PlaybackState? PhonePlayback { get; private set; }
    /// Raised when the companion asks the PC player to play/pause/seek.
    public event Action<string, double>? ControlRequested;
    public event Action? EmergencyStop;
    EffectTimeline? recording, replay;
    string? replayFor;

    public HomeHub(HomeConfig config, Action save, RoomStore? rooms = null)
    {
        Config = config;
        Devices = new HomeController(config, save);
        Rooms = rooms ?? new RoomStore(RoomStore.DefaultFile);
        Director.Emitted += OnDirectorEvent;
    }

    public void StartHost(int? port = null)
    {
        if (Host != null) return;
        Host = new CinemaHost(this);
        Host.Start(port ?? Config.HostPort);
    }

    public void ReportPc(string mediaId, string title, double position, bool playing, AnalysisSource source)
    {
        PcPlayback = new PlaybackState("pc", mediaId, title, position, playing, NowMs, source);
        if (source == AnalysisSource.Analysed && (recording == null || recording.MediaId != mediaId))
        {
            recording?.Save();
            recording = EffectTimeline.Load(mediaId) ?? new EffectTimeline { MediaId = mediaId };
        }
    }

    public void PcStopped()
    {
        recording?.Save();
        recording = null;
        PcPlayback = PcPlayback is { } p ? p with { Playing = false } : null;
        Director.Cancel("player stopped");
        _ = Devices.SuspendAsync("player stopped");
    }

    /// iPhone playback report. clientTimeMs lets us correct for network delay
    /// (position is extrapolated using the server clock offset).
    public void ReportPhone(string mediaId, string title, double position, bool playing, long clientTimeMs, long clockOffsetMs)
    {
        var age = clientTimeMs > 0 ? Math.Clamp(NowMs - (clientTimeMs + clockOffsetMs), 0, 5000) : 0;
        PhonePlayback = new PlaybackState("iphone", mediaId, title, position + (playing ? age / 1000.0 : 0), playing, NowMs, AnalysisSource.CachedTimeline);
    }

    public void RequestControl(string action, double position) => ControlRequested?.Invoke(action, position);

    public async Task EmergencyStopAsync(string source)
    {
        Director.Cancel("emergency stop");
        EmergencyStop?.Invoke();
        await Devices.StopAllEffectsAsync(source);
    }

    void OnDirectorEvent(FourDXEvent e)
    {
        recording?.Record(e, Director.Light);
        // Share effect moments with every room following this title + let AI guests react.
        foreach (var room in Rooms.Rooms.ToList())
        {
            if (room.Playback.MediaId.Length == 0 || room.Playback.MediaId != e.MediaId) continue;
            if (e.Type is "Blast" or "Wind" && !e.Cancelled && e.Intensity > 0)
            {
                Rooms.Post(room, "effect", "ZMF 4DX", $"{e.Type} · {e.Evidence}");
                var ai = room.Members.Where(m => m.Kind == "AI" && m.Present).Select(m => m.Name);
                if (Ai.React(ai, e.Type, Math.Max(e.Intensity, e.Confidence), Director.Scene.StartsWith("Dialogue")) is { } r)
                    Rooms.Post(room, "chat", r.guest, r.text, ai: true);
            }
        }
    }

    /// ~10 Hz from the UI thread. Follows the PC player when it is screening,
    /// otherwise the phone (replaying an analysed timeline if one exists).
    public void Tick(double dt)
    {
        var now = NowMs;
        if (PcPlayback is { } pc && now - pc.ServerTimeMs < 3000 && pc.Playing)
        {
            // Director already updated by the cinema render loop with live analysis.
            Devices.Apply(Director, pc.Position);
            SyncRooms(pc);
            wasActive = true;
            return;
        }
        if (PhonePlayback is { } ph && now - ph.ServerTimeMs < 4000)
        {
            if (replayFor != ph.MediaId) { replay = EffectTimeline.Load(ph.MediaId); replayFor = ph.MediaId; }
            var pos = ph.Playing ? ph.Position + (now - ph.ServerTimeMs) / 1000.0 : ph.Position;
            if (replay != null)
            {
                Director.ApplyTimeline(replay, pos, ph.Playing, dt);
                Devices.Apply(Director, pos);
            }
            else
            {
                Director.Cancel("no analysed timeline");
                PhoneNote = "No analysed 4DX timeline for this title yet — play it once in Auto 4DX on the PC. Physical effects stay off (nothing is scripted in its place).";
            }
            SyncRooms(ph with { Position = pos });
            wasActive = true;
            return;
        }
        PhoneNote = "";
        // Nothing is playing any more (ride ended, player closed, phone gone):
        // automated effects go off — nothing keeps running on its own.
        if (wasActive)
        {
            wasActive = false;
            Director.Cancel("no active playback");
            _ = Devices.SuspendAsync("no active playback");
        }
    }

    bool wasActive;

    public string PhoneNote { get; private set; } = "";

    void SyncRooms(PlaybackState p)
    {
        foreach (var room in Rooms.Rooms.Where(r => r.Members.Any(m => m.Kind == "Host" && m.Present) || r.Playback.MediaId == p.MediaId).ToList())
        {
            if (room.Playback.MediaId != p.MediaId && room.Playback.MediaId.Length > 0) continue;
            bool changed = room.Playback.Playing != p.Playing || Math.Abs(room.Playback.PositionAt(NowMs) - p.Position) > 2;
            room.Playback.MediaId = p.MediaId; room.Playback.Title = p.Title; room.Playback.Position = p.Position;
            room.Playback.Playing = p.Playing; room.Playback.UpdatedAtMs = NowMs;
            if (changed) Rooms.Post(room, "playback", "ZMF", $"{(p.Playing ? "▶" : "⏸")} {p.Title} @ {TimeSpan.FromSeconds(p.Position):h\\:mm\\:ss}");
        }
    }

    public async ValueTask DisposeAsync()
    {
        recording?.Save();
        if (Host != null) await Host.DisposeAsync();
        await Devices.DisposeAsync();
    }
}

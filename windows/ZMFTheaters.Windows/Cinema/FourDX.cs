using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace ZMFTheaters.Cinema;

/// ZMF 4DX preview (October 27–28, 2026, America/New_York).
public static class FourDXPreview
{
    static readonly TimeZoneInfo Ny = FindNy();
    static TimeZoneInfo FindNy()
    {
        try { return TimeZoneInfo.FindSystemTimeZoneById("Eastern Standard Time"); }
        catch { try { return TimeZoneInfo.FindSystemTimeZoneById("America/New_York"); } catch { return TimeZoneInfo.Utc; } }
    }
    public static DateTime StartUtc => TimeZoneInfo.ConvertTimeToUtc(new DateTime(2026, 10, 27, 0, 0, 0, DateTimeKind.Unspecified), Ny);
    public static DateTime EndUtc => TimeZoneInfo.ConvertTimeToUtc(new DateTime(2026, 10, 29, 0, 0, 0, DateTimeKind.Unspecified), Ny);

    public static bool Active(bool force) => true;

    public static string Teaser(bool force)
    {
        if (Active(force)) return "AUTO 4DX · Available at the Box Office";
        if (DateTime.UtcNow < StartUtc)
        {
            var days = (int)Math.Ceiling((StartUtc - DateTime.UtcNow).TotalDays);
            return $"4DX PREVIEW · OCT 27–28 · {(days == 1 ? "tomorrow" : $"in {days} days")}";
        }
        return "4DX PREVIEW ENDED · full 4DX coming in a future update";
    }
}

/// Real-time 4DX from the film: camera motion tracked on a 32×18 luminance
/// grid (pans bank, tilts pitch, push-ins surge, roll rolls, shake vibrates)
/// and soundtrack events (sharp hits, booms, debris) from the audio output.
/// Brightness alone never creates an effect; a flash only strengthens a boom
/// that the soundtrack already detected.
public sealed class FourDXEngine
{
    readonly MotionTracker tracker = new();
    readonly SoundClassifier classifier = new();
    readonly float[] grid = new float[MotionTracker.W * MotionTracker.H];
    readonly List<SoundEvent> events = new();
    double lastTimestamp = double.NaN, lastSample, cutHold;
    double t;
    double velX, velY, zoomRate, rollRate, shakeLevel, motionEnergy;
    double baseX, baseY, basePitch, baseYaw, baseRoll;
    // Spring jolts in seat space: x right, y up, z forward (metres) and pitch/roll (degrees).
    double jx, jy, jz, jvx, jvy, jvz, jp, jr, jvp, jvr;
    int eventSeed;

    public double Rumble { get; private set; }
    public double Strobe { get; private set; }
    /// Smoke haze left by detected booms (0–1).
    public double Smoke { get; private set; }
    /// Strike strength for haptics (booms and sharp hits), decays quickly.
    public double Impact { get; private set; }
    public double Shock { get; private set; }
    public double Embers { get; private set; }
    public double Debris { get; private set; }
    public double Hit { get; private set; }
    public double Wind { get; private set; }
    /// Degrees of camera roll from the seat (bank + detected roll).
    public double Roll { get; private set; }
    public (double x, double y, double pitch, double yaw) Seat { get; private set; }
    public SoundEvent? LastEvent { get; private set; }
    public int EventCount { get; private set; }
    public bool SoundAnalysis { get; private set; }
    /// Raised for each detected event (for TactSuit patterns).
    public event Action<SoundEvent>? Detected;

    public string Status => (SoundAnalysis ? "picture + sound analysis" : "picture motion analysis") +
        (EventCount > 0 ? $" · {EventCount} effects" : "") +
        (LastEvent is { } e ? " · last: " + (e.Kind == SoundEventKind.SharpHit ? "hit" : e.Kind.ToString().ToLowerInvariant()) : "");

    public void Analyse(byte[]? bgra, int w, int h, double dt, double intensity, double timestamp = double.NaN, IReadOnlyList<AudioChunk>? audio = null)
    {
        dt = double.IsFinite(dt) ? Math.Clamp(dt, 0, 0.1) : 0;
        intensity = double.IsFinite(intensity) ? Math.Clamp(intensity, 0, 1) : 0;
        if (double.IsFinite(timestamp))
        {
            if (double.IsFinite(lastTimestamp) && (timestamp < lastTimestamp || timestamp - lastTimestamp > 0.5)) Reset();
            lastTimestamp = timestamp;
            t = timestamp;
        }
        else t += dt;
        cutHold = Math.Max(0, cutHold - dt);
        var k = intensity;
        // At 100% the chair is very motion-sensitive: ≈3× the 50% response,
        // faster, with wider travel.
        var gain = 0.5 + 2.5 * k * k;
        var response = 1 - Math.Exp(-dt * (4 + 12 * k));
        double maxBank = 3 + 9 * k, maxPitch = 2.5 + 6.5 * k, maxTravel = 0.04 + 0.09 * k;

        double tvx = velX, tvy = velY;
        if (bgra != null && w > 8 && h > 8 && (long)w * h * 4 <= bgra.Length)
        {
            MotionTracker.Grid(bgra, w, h, grid);
            if (tracker.Analyse(grid) is { } m)
            {
                var dtv = Math.Clamp(t - lastSample, 1.0 / 60, 0.25);
                lastSample = t;
                if (m.Cut) { cutHold = 0.25; tvx = tvy = 0; zoomRate = rollRate = 0; }
                else
                {
                    tvx = m.Flow.X / dtv / 16; tvy = m.Flow.Y / dtv / 9;
                    zoomRate += (m.Zoom / dtv / 6 - zoomRate) * 0.5;
                    rollRate += (m.Roll / dtv / 6 - rollRate) * 0.5;
                    shakeLevel = Math.Max(shakeLevel * 0.6, Math.Min(1, m.Shake * 4));
                    motionEnergy = Math.Min(0.3, m.Energy * 2.5);
                }
                if (m.Flash) classifier.NoteFlash();
            }
        }
        if (cutHold > 0) { tvx = tvy = 0; motionEnergy = 0; }
        shakeLevel *= Math.Exp(-dt * 3);

        classifier.Sensitivity = (float)(0.6 + 1.4 * k);
        if (audio is { Count: > 0 })
        {
            SoundAnalysis = true;
            events.Clear();
            foreach (var c in audio) classifier.Feed(c, events);
            foreach (var e in events) React(e, k);
        }
        var audioRumble = SoundAnalysis ? classifier.Rumble : 0;

        velX += (tvx * k - velX) * response;
        velY += (tvy * k - velY) * response;
        var target = Math.Min(0.25, motionEnergy * 2) * k + audioRumble * 0.15 * k;
        Rumble += (Math.Min(0.4, target + shakeLevel * 0.1 * k) - Rumble) * (1 - Math.Exp(-dt * 5));
        double Clamp(double v, double m) => Math.Clamp(v, -m, m);
        var bank = Clamp(-velX * 6 * gain - rollRate * 3.5 * gain * k, maxBank);
        var pitchDeg = Clamp(-velY * 4 * gain - zoomRate * 1.7 * gain * k, maxPitch);
        var vib = (Math.Sin(t * 31) * shakeLevel * 0.012 + Math.Sin(t * 17.7) * Rumble * 0.03) * gain;
        baseX += (Clamp(velX * 0.05 * gain, maxTravel) - baseX) * response;
        baseY += (Clamp(velY * 0.04 * gain, maxTravel) + vib - baseY) * response;
        basePitch += (pitchDeg + Math.Sin(t * 7.3) * Rumble * 1.0 - basePitch) * response;
        baseYaw += (Clamp(velX * 1.5 * gain, maxBank) + Math.Sin(t * 5.1 + 1.3) * Rumble * 1.2 - baseYaw) * response;
        baseRoll += (bank - baseRoll) * response;
        StepJolts(dt);
        Seat = (baseX + jx, baseY + jy, basePitch + jp, baseYaw);
        Roll = baseRoll + jr;

        Shock *= Math.Exp(-dt / 0.35); Embers *= Math.Exp(-dt / 2.5); Smoke *= Math.Exp(-dt / 4.5);
        Debris *= Math.Exp(-dt / 0.7); Hit *= Math.Exp(-dt / 0.18); Impact *= Math.Exp(-dt / 0.15);
        Strobe = 0;   // never flashes from brightness
        var speed = Math.Sqrt(velX * velX + velY * velY) + Math.Abs(zoomRate) * 0.6;
        Wind = Math.Min(1, speed * 0.9 + Shock * 0.8) * k;
    }

    void React(SoundEvent e, double k)
    {
        LastEvent = e; EventCount++;
        eventSeed++;
        var jitter = Math.Sin(eventSeed * 12.9898);
        var g = e.Strength * (0.4 + 1.2 * k);
        switch (e.Kind)
        {
            case SoundEventKind.Boom:
                jvx += jitter * 0.3 * g; jvy += 1.1 * g; jvz -= 0.9 * g; jvp -= 80 * g; jvr += jitter * 70 * g;
                Shock = Math.Max(Shock, e.Strength); Embers = Math.Min(1, Embers + 0.7 * e.Strength); Smoke = Math.Min(1.2, Smoke + 0.6 * e.Strength);
                Impact = Math.Max(Impact, e.Strength);
                break;
            case SoundEventKind.SharpHit:
                jvx += jitter * 0.5 * g; jvy += 0.25 * g; jvz -= 0.35 * g; jvp -= 30 * g; jvr += jitter * 50 * g;
                Hit = Math.Max(Hit, e.Strength); Impact = Math.Max(Impact, e.Strength * 0.8);
                break;
            case SoundEventKind.Debris:
                jvx += jitter * 0.25 * g; jvy += 0.12 * Math.Abs(jitter) * g;
                Debris = Math.Min(1, Debris + 0.35 * e.Strength);
                break;
        }
        Detected?.Invoke(e);
    }

    void StepJolts(double dt)
    {
        const double w = 16, z = 0.45;
        int n = Math.Max(1, (int)(dt / 0.004));
        var h = dt / n;
        for (int i = 0; i < n; i++)
        {
            jvx += (-w * w * jx - 2 * z * w * jvx) * h; jx += jvx * h;
            jvy += (-w * w * jy - 2 * z * w * jvy) * h; jy += jvy * h;
            jvz += (-w * w * jz - 2 * z * w * jvz) * h; jz += jvz * h;
            jvp += (-w * w * jp - 2 * z * w * jvp) * h; jp += jvp * h;
            jvr += (-w * w * jr - 2 * z * w * jvr) * h; jr += jvr * h;
        }
        jx = Math.Clamp(jx, -0.08, 0.08); jy = Math.Clamp(jy, -0.08, 0.08); jz = Math.Clamp(jz, -0.08, 0.08);
        jp = Math.Clamp(jp, -7, 7); jr = Math.Clamp(jr, -7, 7);
    }

    /// Clock-synchronised virtual motion for YouTube presentations (the player
    /// exposes only time and play state, never pixels): a gentle scripted
    /// sway with wind, plus a water-mist passage every ~56 s. Seat tuple uses
    /// the same units as <see cref="Seat"/> (metres, degrees).
    public static (double x, double y, double pitch, double yaw, double wind, double water) PresentationMotion(double t)
    {
        if (!double.IsFinite(t) || t < 0) t = 0;
        var mistScene = (int)(t / 14) % 4 == 0;
        var pulse = 0.5 + 0.5 * Math.Sin(t * 1.5);
        return (0.03 * Math.Sin(t * 0.6), 0.025 * Math.Sin(t * 1.25), 2.6 * Math.Sin(t * 0.6), 3.7 * Math.Sin(t * 0.45),
                0.25 + 0.5 * Math.Abs(Math.Sin(t * 0.6)), mistScene ? 0.35 + 0.3 * pulse : 0);
    }

    public void Reset()
    {
        Rumble = Strobe = Smoke = Impact = Shock = Embers = Debris = Hit = Wind = Roll = 0;
        Seat = default; lastTimestamp = double.NaN; cutHold = 0.35; t = 0; lastSample = 0;
        velX = velY = zoomRate = rollRate = shakeLevel = motionEnergy = 0;
        baseX = baseY = basePitch = baseYaw = baseRoll = 0;
        jx = jy = jz = jvx = jvy = jvz = jp = jr = jvp = jvr = 0;
        tracker.Reset(); classifier.Reset(); SoundAnalysis = false;
    }
}

/// Minimal client for bHaptics Player's local WebSocket API (the tact-js
/// protocol on ws://127.0.0.1:15881/v2/feedbacks). bHaptics Player must be
/// running with the TactSuit Air paired over Bluetooth.
public sealed class BHapticsClient : IAsyncDisposable
{
    ClientWebSocket? ws;
    DateTime lastSend = DateTime.MinValue;
    public string Status { get; private set; } = "TactSuit Air: not connected";
    public bool Connected => ws?.State == WebSocketState.Open;
    public bool OutputEnabled { get; set; } = false; // opt-in until hardware protocol is validated
    readonly SemaphoreSlim sendGate = new(1, 1);

    public async Task ConnectAsync()
    {
        try
        {
            ws = new ClientWebSocket();
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            await ws.ConnectAsync(new Uri("ws://127.0.0.1:15881/v2/feedbacks?app_id=com.zmf.theaters&app_name=ZMF%20THEATERS%2B"), cts.Token);
            Status = "Player available · device connection unverified";
        }
        catch
        {
            ws = null;
            Status = "TactSuit Air: start bHaptics Player and pair the suit";
        }
    }

    /// Sends rumble (whole vest, front + back) plus an impact burst on the chest.
    public async Task SendAsync(double rumble, double impact)
    {
        if (!OutputEnabled || !Connected || (DateTime.UtcNow - lastSend).TotalMilliseconds < 90) return;
        lastSend = DateTime.UtcNow;
        int rumbleI = (int)Math.Clamp(rumble * 70, 0, 100);
        int hitI = (int)Math.Clamp(impact * 100, 0, 100);
        if (rumbleI < 3 && hitI < 3) return;
        object Dots(int center) => Enumerable.Range(0, 20).Select(i =>
        {
            int col = i % 4, row = i / 4;
            bool chest = (col == 1 || col == 2) && row <= 2;
            return new { Index = i, Intensity = Math.Max(rumbleI, chest ? center : 0) };
        }).ToArray();
        var msg = new
        {
            Register = Array.Empty<object>(),
            Submit = new object[]
            {
                new { Type = "frame", Key = "zmf_4dx_front", Frame = new { Position = "VestFront", PathPoints = Array.Empty<object>(), DotPoints = Dots(hitI), DurationMillis = 120 } },
                new { Type = "frame", Key = "zmf_4dx_back", Frame = new { Position = "VestBack", PathPoints = Array.Empty<object>(), DotPoints = Dots(hitI / 2), DurationMillis = 120 } },
            },
        };
        if (!await sendGate.WaitAsync(0)) return;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(250));
            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(msg));
            await ws!.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, timeout.Token);
        }
        catch { OutputEnabled = false; Status = "Player error · output stopped"; }
        finally { sendGate.Release(); }
    }

    /// Event pattern for the TactSuit Air: a boom hits the whole vest front
    /// and back, a sharp hit is a tight chest strike (stab/punch/shot),
    /// debris is a scatter of small dots.
    public async Task SendEventAsync(SoundEventKind kind, double strength)
    {
        if (!OutputEnabled || !Connected) return;
        int s = (int)Math.Clamp(strength * 100, 20, 100);
        var rng = new Random(Environment.TickCount);
        object[] Dots(Func<int, int> f) => Enumerable.Range(0, 20).Select(i => (object)new { Index = i, Intensity = f(i) }).ToArray();
        (object front, object back, int ms) = kind switch
        {
            SoundEventKind.Boom => (Dots(_ => s), Dots(_ => s * 4 / 5), 380),
            SoundEventKind.SharpHit => (Dots(i => i is 5 or 6 or 9 or 10 ? s : 0), Dots(i => i is 9 or 10 ? s / 3 : 0), 110),
            _ => (Dots(_ => rng.NextDouble() < 0.2 ? s / 2 : 0), Dots(_ => rng.NextDouble() < 0.15 ? s / 3 : 0), 70),
        };
        var msg = new
        {
            Register = Array.Empty<object>(),
            Submit = new object[]
            {
                new { Type = "frame", Key = "zmf_4dx_evt_front", Frame = new { Position = "VestFront", PathPoints = Array.Empty<object>(), DotPoints = front, DurationMillis = ms } },
                new { Type = "frame", Key = "zmf_4dx_evt_back", Frame = new { Position = "VestBack", PathPoints = Array.Empty<object>(), DotPoints = back, DurationMillis = ms } },
            },
        };
        await sendGate.WaitAsync();
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromMilliseconds(250));
            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(msg));
            await ws!.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, timeout.Token);
            lastSend = DateTime.UtcNow;
        }
        catch { OutputEnabled = false; Status = "Player error · output stopped"; }
        finally { sendGate.Release(); }
    }

    public async ValueTask DisposeAsync()
    {
        try { if (Connected) await ws!.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None); } catch { }
        ws?.Dispose();
    }
}


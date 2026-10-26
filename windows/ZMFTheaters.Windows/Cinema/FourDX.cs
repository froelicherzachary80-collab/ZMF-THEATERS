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

/// Conservative picture-motion fallback, not a semantic event detector.
/// No impact, smoke or flash is inferred from brightness alone.
public sealed class FourDXEngine
{
    readonly float[] prev = new float[64];
    double lastTimestamp = double.NaN;
    double cutHold;
    bool primed;
    double t;

    public double Rumble { get; private set; }
    public double Strobe { get; private set; }
    public double Smoke { get; private set; }
    public double Impact { get; private set; }
    public (double x, double y, double pitch, double yaw) Seat { get; private set; }

    public void Analyse(byte[]? bgra, int w, int h, double dt, double intensity, double timestamp = double.NaN)
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
        double motion = 0;
        if (bgra != null && w > 8 && h > 8 && (long)w * h * 4 <= bgra.Length)
        {
            for (int gy = 0; gy < 8; gy++)
                for (int gx = 0; gx < 8; gx++)
                {
                    int x = (gx * 2 + 1) * w / 16, y = (gy * 2 + 1) * h / 16;
                    int i = (y * w + x) * 4;
                    float lum = (0.0722f * bgra[i] + 0.7152f * bgra[i + 1] + 0.2126f * bgra[i + 2]) / 255f;
                    int k = gy * 8 + gx;
                    motion += Math.Abs(lum - prev[k]);
                    prev[k] = lum;
                }
            motion /= 64;
        }
        if (!primed) { primed = true; motion = 0; }
        // A brightness sample cannot distinguish lightning, edits or explosions.
        // Until event-specific evidence exists, never synthesize impacts from it.
        if (motion > 0.12) cutHold = 0.35;
        var target = cutHold > 0 ? 0 : Math.Min(0.25, motion * 2) * intensity;
        Rumble += (target - Rumble) * (1 - Math.Exp(-dt * 5));
        Impact = Strobe = Smoke = 0;
        var sway = Rumble * 0.6 + Strobe;
        Seat = (Math.Sin(t * 17.7) * 0.008 * Rumble, Math.Sin(t * 23) * 0.006 * Rumble - Strobe * 0.03,
                Math.Sin(t * 7.3) * 0.7 * sway, Math.Sin(t * 5.1 + 1.3) * 0.9 * sway);
    }

    public void Reset() { Rumble = Strobe = Smoke = Impact = 0; Seat = default; primed = false; lastTimestamp = double.NaN; cutHold = 0.35; t = 0; Array.Clear(prev); }
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

    public async ValueTask DisposeAsync()
    {
        try { if (Connected) await ws!.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None); } catch { }
        ws?.Dispose();
    }
}


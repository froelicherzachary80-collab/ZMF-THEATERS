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

    public static bool Active(bool force) => force || (DateTime.UtcNow >= StartUtc && DateTime.UtcNow < EndUtc);

    public static string Teaser(bool force)
    {
        if (Active(force)) return "4DX PREVIEW NOW PLAYING · choose 4DX at the Box Office";
        if (DateTime.UtcNow < StartUtc)
        {
            var days = (int)Math.Ceiling((StartUtc - DateTime.UtcNow).TotalDays);
            return $"4DX PREVIEW · OCT 27–28 · {(days == 1 ? "tomorrow" : $"in {days} days")}";
        }
        return "4DX PREVIEW ENDED · full 4DX coming in a future update";
    }
}

/// Derives 4DX cues from the picture (motion energy and sudden brightness over
/// an 8×8 grid) and drives the motion-seat camera, strobes, smoke and a
/// bHaptics TactSuit Air.
public sealed class FourDXEngine
{
    readonly float[] prev = new float[64];
    float emaBright;
    bool primed;
    double t;

    public double Rumble { get; private set; }
    public double Strobe { get; private set; }
    public double Smoke { get; private set; }
    public double Impact { get; private set; }
    public (double x, double y, double pitch, double yaw) Seat { get; private set; }

    public void Analyse(byte[]? bgra, int w, int h, double dt, double intensity)
    {
        t += dt;
        double motion = 0, bright = 0;
        if (bgra != null && w > 8 && h > 8)
        {
            for (int gy = 0; gy < 8; gy++)
                for (int gx = 0; gx < 8; gx++)
                {
                    int x = (gx * 2 + 1) * w / 16, y = (gy * 2 + 1) * h / 16;
                    int i = (y * w + x) * 4;
                    float lum = (0.0722f * bgra[i] + 0.7152f * bgra[i + 1] + 0.2126f * bgra[i + 2]) / 255f;
                    int k = gy * 8 + gx;
                    motion += Math.Abs(lum - prev[k]);
                    bright += lum;
                    prev[k] = lum;
                }
            motion /= 64; bright /= 64;
        }
        if (!primed) { emaBright = (float)bright; primed = true; motion = 0; }
        bool cut = motion > 0.16;
        var target = cut ? 0 : Math.Min(1, motion * 7) * intensity;
        Rumble += (target - Rumble) * Math.Min(1, dt * 5);
        Impact = 0;
        var jump = bright - emaBright;
        if (!cut && jump > 0.08)
        {
            Impact = Math.Min(1, jump * 5) * intensity;
            Strobe = Math.Max(Strobe, Impact);
            Smoke = Math.Min(1, Smoke + Impact * 0.6);
        }
        emaBright += (float)((bright - emaBright) * Math.Min(1, dt * 2));
        Strobe *= Math.Exp(-dt * 7);
        Smoke *= Math.Exp(-dt * 1.2);
        var sway = Rumble * 0.6 + Strobe;
        Seat = (Math.Sin(t * 17.7) * 0.008 * Rumble, Math.Sin(t * 23) * 0.006 * Rumble - Strobe * 0.03,
                Math.Sin(t * 7.3) * 0.7 * sway, Math.Sin(t * 5.1 + 1.3) * 0.9 * sway);
    }

    public void Reset() { Rumble = Strobe = Smoke = Impact = 0; Seat = default; primed = false; }
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

    public async Task ConnectAsync()
    {
        try
        {
            ws = new ClientWebSocket();
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(3));
            await ws.ConnectAsync(new Uri("ws://127.0.0.1:15881/v2/feedbacks?app_id=com.zmf.theaters&app_name=ZMF%20THEATERS%2B"), cts.Token);
            Status = "TactSuit Air: connected via bHaptics Player";
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
        if (!Connected || (DateTime.UtcNow - lastSend).TotalMilliseconds < 90) return;
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
        try
        {
            var bytes = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(msg));
            await ws!.SendAsync(new ArraySegment<byte>(bytes), WebSocketMessageType.Text, true, CancellationToken.None);
        }
        catch { Status = "TactSuit Air: connection lost"; }
    }

    public async ValueTask DisposeAsync()
    {
        try { if (Connected) await ws!.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None); } catch { }
        ws?.Dispose();
    }
}

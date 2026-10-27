using System.Numerics;

namespace ZMFTheaters.Cinema;

/// The ZMF THEATERS roller-coaster intro (same layout and physics as the iOS
/// app): lift hill, first drop, banked turns, splash tunnel and a final rise
/// onto the ZMF THEATERS marquee. Deterministic in ride time, so the virtual
/// 4DX seat never drifts from the picture.
public sealed class ZMFCoasterTrack
{
    public readonly record struct Pose(Vector3 Position, Vector3 Forward, Vector3 Up, Vector3 Right, float Speed, float Bank,
        float Slope, float VerticalG, float LateralG, float LongitudinalG, float Distance, bool InSplash, bool OnLift);

    public readonly record struct SeatCue(float Side, float Lift, float Surge, float Pitch, float Roll, float Rumble, float Wind, float Water, float Flash);

    public static readonly Vector3[] ControlPoints =
    {
        new(0, 2, -12), new(0, 2, 0), new(0, 2, 16),
        new(0, 7, 32), new(0, 15, 48), new(0, 23, 64), new(0, 27, 76), new(0, 27.5f, 84),
        new(0, 16, 98), new(0, 3.5f, 114),
        new(7, 4, 130), new(22, 7, 140), new(38, 10, 136), new(48, 9, 120),
        new(51, 12, 104), new(49, 5, 88),
        new(43, 1.4f, 72), new(35, 1.4f, 58),
        new(25, 6, 47), new(12, 9, 44), new(-2, 8, 52),
        new(-14, 4, 66), new(-24, 6, 84), new(-28, 9, 102), new(-28, 9.5f, 118),
        new(-28, 9.5f, 130), new(-28, 9.5f, 140),
    };

    public const float LiftStart = 0.11f, SplashFrom = 0.6f, SplashTo = 0.68f;
    public static readonly Vector3 LogoPosition = new(-28, 17, 168);
    public static readonly Vector3 PoolCenter = new(39, 0.05f, 65);
    // Declared after the layout statics above: static fields initialise in order.
    public static readonly ZMFCoasterTrack Shared = new();

    readonly List<Vector3> points = new();
    readonly List<float> cumulative = new();
    readonly List<(float t, float s, float v)> timeline = new();
    float[] bankByMeter = Array.Empty<float>();
    public float Length { get; private set; }
    public float LiftEnd { get; private set; } = 0.24f;
    public float RideDuration { get; private set; }
    /// Total intro length: ride plus a hold on the marquee.
    public double Duration => RideDuration + 4.5;

    ZMFCoasterTrack()
    {
        Build();
        Simulate();
        ComputeBanking();
    }

    static Vector3 Catmull(Vector3 p0, Vector3 p1, Vector3 p2, Vector3 p3, float t)
    {
        float t2 = t * t, t3 = t2 * t;
        return 0.5f * (2 * p1 + (p2 - p0) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (3 * p1 - p0 - 3 * p2 + p3) * t3);
    }

    void Build()
    {
        var cp = ControlPoints;
        int n = cp.Length;
        for (int i = 0; i < n - 1; i++)
            for (int k = 0; k < 80; k++)
                points.Add(Catmull(cp[Math.Max(0, i - 1)], cp[i], cp[i + 1], cp[Math.Min(n - 1, i + 2)], k / 80f));
        points.Add(cp[n - 1]);
        cumulative.Add(0);
        for (int i = 1; i < points.Count; i++) cumulative.Add(cumulative[i - 1] + Vector3.Distance(points[i], points[i - 1]));
        Length = cumulative[^1];
        int crest = 0;
        for (int i = 1; i < points.Count; i++) if (points[i].Y > points[crest].Y) crest = i;
        LiftEnd = cumulative[crest] / Length + 0.005f;
    }

    public Vector3 Point(float s)
    {
        var x = Math.Clamp(s, 0, Length);
        int lo = 0, hi = cumulative.Count - 1;
        while (hi - lo > 1) { int mid = (lo + hi) / 2; if (cumulative[mid] <= x) lo = mid; else hi = mid; }
        var span = Math.Max(1e-4f, cumulative[hi] - cumulative[lo]);
        return Vector3.Lerp(points[lo], points[hi], (x - cumulative[lo]) / span);
    }

    public Vector3 Tangent(float s)
    {
        var d = Point(s + 0.8f) - Point(s - 0.8f);
        return d.Length() > 1e-4f ? Vector3.Normalize(d) : Vector3.UnitZ;
    }

    void Simulate()
    {
        const float g = 9.81f, dt = 1f / 120;
        float s = 0, v = 3.5f, t = 0;
        float liftA = LiftStart * Length, liftB = LiftEnd * Length, brake = Length - 30;
        timeline.Add((0, 0, v));
        while (s < Length - 0.05f && t < 120)
        {
            if (s < liftA) v += (5.5f - v) * Math.Min(1, dt * 1.2f);
            else if (s < liftB) v += (7 - v) * Math.Min(1, dt * 2);
            else if (s > brake) v = Math.Max(1.2f, Math.Min(v, MathF.Sqrt(2 * 1.6f * (Length - s)) + 1.2f));
            else { v += (-g * Tangent(s).Y - 0.003f * v * v - 0.15f) * dt; v = Math.Max(5, v); }
            s += v * dt;
            t += dt;
            timeline.Add((t, Math.Min(s, Length), v));
        }
        RideDuration = t;
    }

    float SpeedAt(float s)
    {
        int lo = 0, hi = timeline.Count - 1;
        while (hi - lo > 1) { int mid = (lo + hi) / 2; if (timeline[mid].s <= s) lo = mid; else hi = mid; }
        return timeline[lo].v;
    }

    void ComputeBanking()
    {
        int meters = (int)Length + 2;
        var raw = new float[meters];
        for (int m = 0; m < meters; m++)
        {
            float s = m, v = SpeedAt(s), span = Math.Max(4, v);
            var turn = Vector3.Cross(Tangent(s - span * 0.5f), Tangent(s + span * 0.5f));
            raw[m] = Math.Clamp(MathF.Atan(v * v * (turn.Y / span) / 9.81f) * 0.9f, -0.95f, 0.95f);
        }
        bankByMeter = new float[meters];
        for (int m = 0; m < meters; m++)
        {
            int lo = Math.Max(0, m - 6), hi = Math.Min(meters - 1, m + 6);
            float sum = 0; for (int k = lo; k <= hi; k++) sum += raw[k];
            bankByMeter[m] = sum / (hi - lo + 1);
        }
    }

    public float BankAt(float s)
    {
        var x = Math.Clamp(s, 0, bankByMeter.Length - 1);
        int i = (int)x, j = Math.Min(bankByMeter.Length - 1, i + 1);
        return bankByMeter[i] + (bankByMeter[j] - bankByMeter[i]) * (x - i);
    }

    /// Track frame: forward, right and banked up.
    public (Vector3 forward, Vector3 right, Vector3 up) Frame(float s)
    {
        var fwd = Tangent(s);
        var flat = Vector3.Cross(fwd, Vector3.UnitY);
        var right0 = flat.Length() > 1e-4f ? Vector3.Normalize(flat) : Vector3.UnitX;
        var up0 = Vector3.Normalize(Vector3.Cross(right0, fwd));
        var b = BankAt(s);
        var up = Vector3.Normalize(up0 * MathF.Cos(b) - right0 * MathF.Sin(b));
        return (fwd, Vector3.Normalize(Vector3.Cross(fwd, up)), up);
    }

    public Pose PoseAt(double time)
    {
        var t = (float)Math.Clamp(double.IsFinite(time) ? time : 0, 0, RideDuration);
        int i = Math.Clamp((int)(t * 120), 0, timeline.Count - 1);
        float s = timeline[i].s, v = timeline[i].v, prevV = timeline[Math.Max(0, i - 12)].v;
        var f = Frame(s);
        var ahead = Tangent(s + Math.Max(2, v * 0.5f));
        var behind = Tangent(s - Math.Max(2, v * 0.5f));
        var ds = Math.Max(4, v);
        var horizontalK = Vector3.Cross(behind, ahead).Y / ds;
        var verticalK = (ahead.Y - behind.Y) / ds;
        var latA = v * v * horizontalK;
        var bank = BankAt(s);
        var frac = s / Math.Max(1, Length);
        var pos = Point(s);
        return new Pose(pos, f.forward, f.up, f.right, v, bank, f.forward.Y,
            Math.Clamp(v * v * verticalK / 9.81f, -1.2f, 2.5f),
            Math.Clamp(latA / 9.81f - MathF.Sin(bank), -1.5f, 1.5f),
            Math.Clamp((v - prevV) / 0.1f / 9.81f, -1, 1), s,
            frac >= SplashFrom && frac <= SplashTo && pos.Y < 3,
            frac > LiftStart && frac < LiftEnd);
    }

    public SeatCue CueAt(double time)
    {
        var p = PoseAt(time);
        var ft = (float)time;
        var chain = p.OnLift ? 0.12f + (MathF.Sin(ft * 38) > 0.6f ? 0.08f : 0) : 0;
        var finale = time > RideDuration - 1.5;
        return new SeatCue(-p.LateralG * 0.05f, p.VerticalG * 0.035f - 0.01f, p.LongitudinalG * 0.06f,
            p.Slope * 0.22f - p.LongitudinalG * 0.04f, -p.Bank * 0.14f + p.LateralG * 0.03f,
            Math.Min(0.4f, p.Speed / 30 * 0.3f + chain), Math.Min(1, p.Speed / 22), p.InSplash ? 1 : 0,
            finale && MathF.Sin(ft * 4.7f) > 0.93f ? 0.3f : 0);
    }

    /// Original announcer script (spoken with the Windows system voice).
    public (double at, string line)[] Script => new[]
    {
        (0.6, "Welcome to Z M F Theaters."),
        (4.5, "Please keep your hands and feet inside the ride, and hold on to your popcorn."),
        (RideDuration * 0.27, "Here we go!"),
        (RideDuration * 0.62, "Hope you don't mind getting a little wet."),
        (RideDuration - 0.5, "Z M F Theaters. Sit back, relax, and enjoy the show."),
    };
}

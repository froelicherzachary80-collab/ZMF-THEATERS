using System.IO;

namespace ZMFTheaters.Cinema;

public static class FourDXSelfTest
{
    public static int Run(string path)
    {
        var log = new List<string>();
        void Check(bool condition, string name)
        {
            log.Add($"{(condition ? "PASS" : "FAIL")} {name}");
        }
        var engine = new FourDXEngine();
        byte[] Frame(byte value) => Enumerable.Repeat(value, 32 * 32 * 4).ToArray();
        engine.Analyse(Frame(0), 32, 32, 1.0 / 24, 1, 0);
        for (int i = 1; i < 60; i++)
        {
            engine.Analyse(Frame((byte)(i % 2 == 0 ? 255 : 0)), 32, 32, 1.0 / 24, 1, i / 24.0);
            Check(engine.Impact == 0 && engine.Strobe == 0 && engine.Smoke == 0, $"cut/flash {i} has no unsupported semantic output");
        }
        engine.Reset();
        for (int i = 0; i < 60; i++) engine.Analyse(Frame(80), 32, 32, 1.0 / 24, 1, i / 24.0);
        Check(engine.Rumble == 0, "static dialogue frame stays quiet");
        for (int i = 0; i < 60; i++) engine.Analyse(Frame((byte)(80 + i % 4 * 4)), 32, 32, 1.0 / 24, 1, 3 + i / 24.0);
        Check(engine.Rumble > 0 && engine.Rumble <= 0.25, "gentle picture motion produces bounded output");
        engine.Analyse(Frame(90), 32, 32, 1.0 / 24, 1, 1);
        Check(engine.Rumble == 0, "backward seek clears prior motion");
        engine.Reset();
        Check(engine.Rumble == 0 && engine.Seat == default, "pause/stop reset returns neutral");
        engine.Analyse(new byte[1], 1920, 1080, double.NaN, double.PositiveInfinity, 0);
        Check(double.IsFinite(engine.Rumble), "invalid samples never produce nonfinite output");
        Check(Format.FourDX3D.Uses4DX() && Format.FourDX3D.UsesDepth(), "combined format enables both pipelines");
        Check(!Format.TwoD.Uses4DX() && !Format.TwoD.UsesDepth(), "2D enables neither pipeline");
        Check(FourDXPreview.Active(false), "4DX has no date expiration");
        Auto4DXSchedulerTests.Run(Check);
        RealtimeTests(Check);
        // ZMF roller-coaster intro: deterministic, finite, bounded seat cues.
        var ride = ZMFCoasterTrack.Shared;
        Check(ride.RideDuration > 30 && ride.RideDuration < 90, $"[coaster] ride lasts {ride.RideDuration:0.0}s");
        bool finite = true, bounded = true, splash = false, lift = false; float vmax = 0;
        for (double t = 0; t <= ride.RideDuration; t += 0.05)
        {
            var p = ride.PoseAt(t); var c = ride.CueAt(t);
            finite &= float.IsFinite(p.Position.X + p.Position.Y + p.Position.Z + p.Speed + c.Pitch + c.Roll + c.Side + c.Lift);
            bounded &= Math.Abs(c.Pitch) <= 0.4 && Math.Abs(c.Roll) <= 0.4 && Math.Abs(c.Side) <= 0.1 && Math.Abs(c.Lift) <= 0.1 && c.Wind <= 1 && c.Rumble <= 0.4;
            splash |= p.InSplash; lift |= p.OnLift; vmax = Math.Max(vmax, p.Speed);
        }
        Check(finite, "[coaster] poses and seat cues are finite");
        Check(bounded, "[coaster] seat cues stay within comfort limits");
        Check(splash && lift, "[coaster] ride passes the lift hill and splash tunnel");
        Check(vmax > 15 && vmax < 30, $"[coaster] top speed {vmax:0.0} m/s");
        Check(ride.PoseAt(12.3).Position == ride.PoseAt(12.3).Position, "[coaster] pose is deterministic for a given ride time");
        File.WriteAllLines(path, log);
        return log.Any(s => s.StartsWith("FAIL")) ? 1 : 0;
    
    // Real-time 4DX detector and tracker — SYNTHETIC SIGNALS ONLY.
    static void RealtimeTests(Action<bool, string> Check)
    {
        const int sr = 48000;
        var rng = new Random(7);
        float[] Gen(double secs, Func<double, float> f) { var a = new float[(int)(secs * sr)]; for (int i = 0; i < a.Length; i++) a[i] = f(i / (double)sr); return a; }
        float Dialog(double t) => (float)(0.08 * Math.Sin(2 * Math.PI * 220 * t) * (0.5 + 0.5 * Math.Sin(2 * Math.PI * 4 * t)) + 0.08 * Math.Sin(2 * Math.PI * 660 * t) * (0.5 + 0.5 * Math.Sin(2 * Math.PI * 3.3 * t)));
        List<SoundEvent> Detect(float[] pcm, float sens = 1)
        {
            var chunks = new List<AudioChunk>(); new BandSplitter(sr).Push(pcm, 1, chunks);
            var c = new SoundClassifier { Sensitivity = sens }; var ev = new List<SoundEvent>();
            foreach (var ch in chunks) c.Feed(ch, ev);
            return ev;
        }
        Check(Detect(Gen(6, Dialog), 2).Count == 0, "[realtime] dialogue creates no events");
        var music = Gen(6, t => Dialog(t) + (float)(0.25 * Math.Exp(-(t % 0.5) * 20) * Math.Sin(2 * Math.PI * 80 * t)));
        Check(!Detect(music, 2).Any(e => e.Kind == SoundEventKind.Boom), "[realtime] music kick drums are not explosions");
        var boom = Gen(6, t => Dialog(t) + (t > 3 ? (float)(0.6 * Math.Exp(-(t - 3) * 3) * Math.Sin(2 * Math.PI * 50 * (t - 3))) : 0));
        for (int k = 0; k < 8; k++) { int st = (int)((3.35 + k * 0.13) * sr); for (int i = 0; i < 96; i++) boom[st + i] += (float)(rng.NextDouble() - 0.5) * (1 - i / 96f); }
        var be = Detect(boom);
        var b = be.FirstOrDefault(e => e.Kind == SoundEventKind.Boom);
        Check(be.Count(e => e.Kind == SoundEventKind.Boom) == 1 && Math.Abs(b.Time - 3.15) < 0.1, "[realtime] explosion-like boom detected once, on time");
        Check(be.Count(e => e.Kind == SoundEventKind.Debris) >= 4 && !be.Any(e => e.Kind == SoundEventKind.SharpHit), "[realtime] crackle after a boom is debris");
        var hits = Gen(6, Dialog);
        foreach (var at in new[] { 2.0, 4.0 }) { int st = (int)(at * sr); for (int i = 0; i < 240; i++) hits[st + i] += (float)(rng.NextDouble() * 1.4 - 0.7) * (1 - i / 240f); }
        var he = Detect(hits);
        Check(he.Count == 2 && he.All(e => e.Kind == SoundEventKind.SharpHit), "[realtime] two sharp hits (stab/punch/shot-like)");
        Check(Detect(Gen(6, t => (float)(0.3 * Math.Sin(2 * Math.PI * 40 * t)) + Dialog(t))).Count == 0, "[realtime] steady engine rumble is not an event");

        float Pat(float x, float y) => 0.5f + 0.2f * MathF.Sin(x * 0.9f + 1.3f * MathF.Sin(y * 0.4f)) + 0.15f * MathF.Sin(y * 1.1f + x * 0.3f) + 0.1f * MathF.Sin(x * 2.3f - y * 1.7f);
        MotionSample? Track(Func<int, float, float, (float, float)> map)
        {
            var tr = new MotionTracker(); MotionSample? last = null;
            for (int f = 0; f < 6; f++)
            {
                var g = new float[MotionTracker.W * MotionTracker.H];
                for (int y = 0; y < MotionTracker.H; y++) for (int x = 0; x < MotionTracker.W; x++) { var (u, v) = map(f, x + 0.5f - 16, y + 0.5f - 9); g[y * MotionTracker.W + x] = Pat(u, v); }
                if (tr.Analyse(g) is { } s) last = s;
            }
            return last;
        }
        Check(Track((f, x, y) => (x + f * 0.6f, y))?.Flow.X > 0.4f, "[realtime] camera pan right is tracked");
        Check(Track((f, x, y) => (x, y + f * 0.4f))?.Flow.Y > 0.2f, "[realtime] camera tilt is tracked (sub-cell)");
        Check(Track((f, x, y) => (x / MathF.Pow(1.04f, f), y / MathF.Pow(1.04f, f)))?.Zoom > 0.08f, "[realtime] push-in reads as forward surge");
        Check(Track((f, x, y) => (x * MathF.Pow(1.04f, f), y * MathF.Pow(1.04f, f)))?.Zoom < -0.08f, "[realtime] pull-out reads as backward surge");
        Check(Track((f, x, y) => { var a = -f * 2 * MathF.PI / 180; return (x * MathF.Cos(a) - y * MathF.Sin(a), x * MathF.Sin(a) + y * MathF.Cos(a)); })?.Roll > 0.05f, "[realtime] camera roll is tracked");
        Check(Track((f, x, y) => (x, y)) == null, "[realtime] still picture produces no motion");

        // Sensitivity: 100% moves the chair much more than 30% for the same pan.
        double Bank(double intensity)
        {
            var eng = new FourDXEngine(); double peak = 0;
            for (int f = 0; f < 48; f++)
            {
                var frame = new byte[64 * 36 * 4];
                for (int y = 0; y < 36; y++) for (int x = 0; x < 64; x++) { var v = (byte)(Pat((x - 32) / 2f + f * 0.3f, (y - 18) / 2f) * 255); int i = (y * 64 + x) * 4; frame[i] = frame[i + 1] = frame[i + 2] = v; }
                eng.Analyse(frame, 64, 36, 1.0 / 24, intensity, f / 24.0);
                peak = Math.Max(peak, Math.Abs(eng.Roll));
            }
            return peak;
        }
        var hi = Bank(1); var lo = Bank(0.3);
        Check(hi > lo * 3 && hi > 2, $"[realtime] 100% intensity is very motion-sensitive (bank {hi:0.0}° vs {lo:0.0}° at 30%)");
        var calm = new FourDXEngine();
        for (int f = 0; f < 48; f++) calm.Analyse(new byte[64 * 36 * 4].Select((_, i) => (byte)(f % 2 == 0 ? 0 : 255)).ToArray(), 64, 36, 1.0 / 24, 1, f / 24.0);
        Check(calm.Smoke == 0 && calm.Shock == 0 && calm.EventCount == 0, "[realtime] flashing picture without sound creates no explosion");
    }
}
}

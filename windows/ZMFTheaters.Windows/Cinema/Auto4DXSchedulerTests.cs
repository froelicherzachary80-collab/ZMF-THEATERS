namespace ZMFTheaters.Cinema;

/// Deterministic scheduler regression tests (run by --selftest-4dx in CI).
/// SYNTHETIC TEST FIXTURES ONLY: every event here is Source = SyntheticTest
/// with a "test-" id. None of them are AI-detected movie events.
public static class Auto4DXSchedulerTests
{
    static Auto4DXEvent Ev(string id, double t, Auto4DXEventType type = Auto4DXEventType.Rumble, double intensity = 0.6,
                           double duration = 0.5, int priority = 0, Auto4DXTargets targets = Auto4DXTargets.Seat,
                           double confidence = 0.9, Auto4DXCancel cancel = Auto4DXCancel.FadeOut) =>
        new("test-" + id, type, t, confidence, intensity, duration, Auto4DXDirection.Center, "test.preset",
            targets, Auto4DXSafety.Gentle, cancel, 0.2, Auto4DXSource.SyntheticTest, "synthetic-fixture", priority);

    const double Dt = 1.0 / 60;

    static void Play(Auto4DXScheduler s, double from, double to)
    {
        for (int i = 0; from + i * Dt <= to + 1e-9; i++) s.Update(from + i * Dt, true, Dt);
    }

    public static void Run(Action<bool, string> Check)
    {
        // 1 ordering
        var s = new Auto4DXScheduler { LatencySeconds = 0 };
        s.Load("film-a", new[] { Ev("c", 3), Ev("a", 1), Ev("b", 2), Ev("b2", 2, priority: 5) });
        Check(string.Join(",", s.Events.Select(e => e.Id)) == "test-a,test-b2,test-b,test-c", "[scheduler] events sorted by timestamp then priority");
        Play(s, 0, 4);
        Check(string.Join(",", s.Dispatched) == "test-a,test-b2,test-b,test-c", "[scheduler] events dispatched in timestamp order");

        // 2 playback-time dispatch with latency compensation
        s = new Auto4DXScheduler { LatencySeconds = 0.1 };
        s.Load("film-a", new[] { Ev("x", 5) });
        Play(s, 4, 4.88);
        Check(s.Dispatched.Count == 0, "[scheduler] not dispatched before media time minus latency");
        Play(s, 4.89, 4.92);
        Check(s.Dispatched.Count == 1, "[scheduler] dispatched at media time minus latency");
        var frozen = new Auto4DXScheduler { LatencySeconds = 0 };
        frozen.Load("film-a", new[] { Ev("w", 1) });
        for (int i = 0; i < 600; i++) frozen.Update(0.5, true, Dt); // ten render-seconds, media clock stalled
        Check(frozen.Dispatched.Count == 0, "[scheduler] dispatch follows media clock, not elapsed frame time");

        // 3 pause, 4 resume
        s = new Auto4DXScheduler { LatencySeconds = 0 };
        s.Load("film-a", new[] { Ev("p", 1, duration: 3), Ev("q", 2) });
        Play(s, 0.9, 1.5);
        Check(s.Level(Auto4DXTargets.Seat) > 0.3, "[scheduler] effect active during playback");
        for (int i = 0; i < 60; i++) s.Update(1.5, false, Dt);
        Check(s.Level(Auto4DXTargets.Seat) == 0 && s.ActiveCount == 0, "[scheduler] pause suspends active effects");
        Check(!s.Dispatched.Contains("test-q"), "[scheduler] no dispatch while paused");
        Play(s, 1.5, 2.2);
        Check(s.Dispatched.Contains("test-q") && s.Dispatched.Count(d => d == "test-p") == 1, "[scheduler] resume dispatches upcoming events without replay");

        // 5 forward seek
        s = new Auto4DXScheduler { LatencySeconds = 0 };
        s.Load("film-a", new[] { Ev("f1", 2), Ev("f2", 10), Ev("f3", 11) });
        Play(s, 0, 1);
        Play(s, 9.5, 10.5);
        Check(!s.Dispatched.Contains("test-f1") && s.Dispatched.Contains("test-f2") && !s.Dispatched.Contains("test-f3"),
              "[scheduler] forward seek skips passed events, never fires them late");

        // 6 backward seek
        Play(s, 1, 2.2);
        Check(s.Dispatched.Contains("test-f1"), "[scheduler] backward seek re-arms earlier events");
        Check(s.Level(Auto4DXTargets.Seat) > 0, "[scheduler] rewound event plays");
        Play(s, 9.8, 10.2);
        Check(s.Dispatched.Count(d => d == "test-f2") == 2, "[scheduler] rewatching after rewind replays once");

        // 7 overlapping events
        s = new Auto4DXScheduler { LatencySeconds = 0 };
        s.Load("film-a", new[] { Ev("o1", 1, intensity: 0.4, duration: 2), Ev("o2", 1.5, intensity: 0.8, duration: 2),
                                 Ev("o3", 1.5, Auto4DXEventType.Wind, 0.5, 2, targets: Auto4DXTargets.Wind) });
        Play(s, 0.9, 2.2);
        Check(s.ActiveCount == 3 && s.Level(Auto4DXTargets.Seat) > 0.7 && s.Level(Auto4DXTargets.Wind) > 0.4,
              "[scheduler] overlapping events run together");

        // 8 priority
        s = new Auto4DXScheduler { LatencySeconds = 0 };
        s.Load("film-a", new[] { Ev("lo", 1, intensity: 0.9, duration: 2), Ev("hi", 1.2, intensity: 0.3, duration: 2, priority: 10) });
        Play(s, 0.9, 2);
        Check(Math.Abs(s.Level(Auto4DXTargets.Seat) - 0.3) < 0.02, "[scheduler] higher priority event owns the output");

        // 9 cooldown
        s = new Auto4DXScheduler { LatencySeconds = 0 };
        s.Load("film-a", new[] { Ev("i1", 1, Auto4DXEventType.Impact, duration: 0.1, targets: Auto4DXTargets.Haptics),
                                 Ev("i2", 1.2, Auto4DXEventType.Impact, duration: 0.1, targets: Auto4DXTargets.Haptics),
                                 Ev("i3", 1.8, Auto4DXEventType.Impact, duration: 0.1, targets: Auto4DXTargets.Haptics) });
        Play(s, 0.9, 2);
        Check(string.Join(",", s.Dispatched) == "test-i1,test-i3", "[scheduler] cooldown suppresses rapid repeats");

        // 10 duplicates
        s = new Auto4DXScheduler { LatencySeconds = 0 };
        s.Load("film-a", new[] { Ev("d", 1), Ev("d", 1) });
        Play(s, 0.9, 1.2);
        for (int i = 0; i < 30; i++) s.Update(1.2, true, Dt);
        Check(s.Dispatched.Count == 1 && s.Rejected.Count == 1, "[scheduler] duplicate ids rejected, event fires once");

        // 11 smooth cancellation, stop, movie change
        s = new Auto4DXScheduler { LatencySeconds = 0, CancelFade = 0.25 };
        s.Load("film-a", new[] { Ev("sm", 1, intensity: 1, duration: 5) });
        Play(s, 0.9, 1.6);
        var before = s.Level(Auto4DXTargets.Seat);
        s.Update(1.6, false, Dt);
        var first = s.Level(Auto4DXTargets.Seat);
        bool monotonic = true; double prev = first;
        for (int i = 0; i < 90; i++) { s.Update(1.6, false, Dt); var v = s.Level(Auto4DXTargets.Seat); monotonic &= v <= prev + 1e-9; prev = v; }
        Check(first > 0.5 && first <= before + 1e-9 && monotonic && prev == 0, "[scheduler] pause fades effect smoothly to zero");
        s.Load("film-a", new[] { Ev("sm", 1, intensity: 1, duration: 5) });
        Play(s, 0.9, 1.6);
        s.Stop();
        Check(s.Level(Auto4DXTargets.Seat) == 0 && s.ActiveCount == 0, "[scheduler] stop returns outputs to neutral");
        s.Load("film-b", new[] { Ev("sm", 1) });
        Play(s, 0.9, 1.2);
        Check(s.MovieId == "film-b" && s.Dispatched.SequenceEqual(new[] { "test-sm" }), "[scheduler] new movie resets state");

        // 12 invalid inputs
        var bad = new[]
        {
            Ev("nan", double.NaN), Ev("neg", -1), Ev("conf", 1, confidence: 1.5), Ev("int", 1, intensity: -0.1),
            Ev("dur", 1, duration: 0), Ev("inf", 1, duration: double.PositiveInfinity), Ev("tgt", 1, targets: Auto4DXTargets.None),
            Ev("dir", 1) with { Direction = new Auto4DXDirection(double.NaN, 0, 0) },
            Ev("det", 1) with { DetectorId = "" }, Ev("type", 1) with { Type = (Auto4DXEventType)99 },
        };
        s = new Auto4DXScheduler();
        s.Load("film-a", bad);
        Check(s.Events.Count == 0 && s.Rejected.Count == bad.Length, "[scheduler] invalid events rejected");
        s.Load("film-a", new[] { Ev("v", 1) });
        s.Update(double.NaN, true, double.NaN);
        s.Update(-5, true, double.PositiveInfinity);
        Check(double.IsFinite(s.Level(Auto4DXTargets.Seat)) && s.Dispatched.Count == 0, "[scheduler] invalid clock samples ignored");
        s = new Auto4DXScheduler();
        s.Load("film-a", new[] { Ev("lowconf", 1, confidence: 0.2) });
        Play(s, 0.5, 1.5);
        Check(s.Dispatched.Count == 0, "[scheduler] low-confidence events not dispatched");

        // 13 scene cuts: fallback analysis never creates impact events
        var engine = new FourDXEngine();
        s = new Auto4DXScheduler();
        s.Load("film-a", Array.Empty<Auto4DXEvent>());
        byte[] Frame(byte v) => Enumerable.Repeat(v, 32 * 32 * 4).ToArray();
        bool quiet = true;
        for (int i = 0; i < 120; i++)
        {
            engine.Analyse(Frame((byte)(i % 12 < 6 ? 10 : 245)), 32, 32, Dt, 1, i * Dt);
            s.Update(i * Dt, true, Dt);
            quiet &= engine.Impact == 0 && engine.Strobe == 0 && engine.Smoke == 0
                     && s.Level(Auto4DXTargets.Haptics) == 0 && s.Dispatched.Count == 0;
        }
        Check(quiet, "[scheduler] ordinary scene cuts produce no unsupported impacts");
    }
}

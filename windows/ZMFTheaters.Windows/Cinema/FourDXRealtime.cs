using System.Numerics;

namespace ZMFTheaters.Cinema;

/// One ~6 ms chunk of soundtrack energy in three bands (same as iOS).
public readonly record struct AudioChunk(float Low, float Mid, float High, float Duration);

/// Acoustic event classes. A sharp hit can be a stab, punch, gunshot or slam;
/// a boom is an explosion-like low-frequency blast (stronger with a picture
/// flash at the same moment); debris is the crackle that follows a boom.
/// Nothing is inferred from brightness alone.
public enum SoundEventKind { SharpHit, Boom, Debris }

public readonly record struct SoundEvent(SoundEventKind Kind, double Time, float Strength, bool WithFlash);

/// Splits mono/stereo float PCM into band-energy chunks (one-pole filters at
/// 150 Hz and 3 kHz, 256-sample chunks).
public sealed class BandSplitter
{
    float lp1, lp2, aLow, aMid, aHigh; int n;
    float a1, a2; int sampleRate;
    public BandSplitter(int sampleRate) { SetRate(sampleRate); }
    public void SetRate(int rate)
    {
        sampleRate = Math.Max(8000, rate);
        a1 = 1 - MathF.Exp(-2 * MathF.PI * 150 / sampleRate);
        a2 = 1 - MathF.Exp(-2 * MathF.PI * 3000 / sampleRate);
    }

    public void Push(ReadOnlySpan<float> interleaved, int channels, List<AudioChunk> output)
    {
        channels = Math.Max(1, channels);
        for (int i = 0; i + channels <= interleaved.Length; i += channels)
        {
            float m = 0;
            for (int c = 0; c < channels; c++) m += interleaved[i + c];
            m /= channels;
            if (!float.IsFinite(m)) m = 0;
            lp1 += a1 * (m - lp1);
            lp2 += a2 * (m - lp2);
            float low = lp1, mid = lp2 - lp1, high = m - lp2;
            aLow += low * low; aMid += mid * mid; aHigh += high * high; n++;
            if (n >= 256)
            {
                output.Add(new AudioChunk(MathF.Sqrt(aLow / n), MathF.Sqrt(aMid / n), MathF.Sqrt(aHigh / n), n / (float)sampleRate));
                aLow = aMid = aHigh = 0; n = 0;
            }
        }
    }
}

/// Deterministic onset classifier, identical in logic to the iOS version.
public sealed class SoundClassifier
{
    public double Time { get; private set; }
    float slowLow = 0.01f, slowMid = 0.01f, slowHigh = 0.005f, fastLow;
    double lastHit = -10, lastBoom = -10, lastDebris = -10, debrisUntil = -10, lastFlash = -10, warm, boomCandidate = -1;
    float boomPeak;
    double lastLowEdge = -10;
    bool lowWasHigh, candidateRhythmic;
    public float Rumble { get; private set; }
    /// 0.5 = conservative, 1 = default, 2 = very sensitive.
    public float Sensitivity { get; set; } = 1;

    public void NoteFlash() => lastFlash = Time;

    public void Reset()
    {
        Time = 0; slowLow = 0.01f; slowMid = 0.01f; slowHigh = 0.005f; fastLow = 0;
        lastHit = lastBoom = lastDebris = debrisUntil = lastFlash = -10; warm = 0; Rumble = 0; boomCandidate = -1; boomPeak = 0; lastLowEdge = -10; lowWasHigh = candidateRhythmic = false;
    }

    public void Feed(AudioChunk c, List<SoundEvent> output)
    {
        if (!float.IsFinite(c.Low) || !float.IsFinite(c.Mid) || !float.IsFinite(c.High) || !float.IsFinite(c.Duration) || c.Duration <= 0) return;
        double dt = Math.Min(0.1, c.Duration);
        Time += dt; warm += dt;
        float s = Math.Clamp(Sensitivity, 0.25f, 2.5f);
        float ratioBoom = 3.4f / MathF.Sqrt(s), ratioHit = 4.2f / MathF.Sqrt(s);
        fastLow += (c.Low - fastLow) * Math.Min(1, (float)dt / 0.03f);
        bool ready = warm > 0.4;
        // A boom must *sustain* ~0.1 s above threshold: explosions do, kick
        // drums and door thuds decay within ~50 ms and are ignored.
        bool lowHot = ready && fastLow > slowLow * ratioBoom && fastLow > 0.035f / s;
        // Rising edges of low energy (tracked even while warming up) reveal
        // rhythm: a thump 0.25–1.6 s after another is a beat, not a blast,
        // unless it is far louder than the soundtrack around it.
        bool lowEdge = fastLow > slowLow * 2.2f && fastLow > 0.025f && !lowWasHigh;
        lowWasHigh = fastLow > slowLow * 1.6f;
        bool rhythmic = false;
        if (lowEdge) { rhythmic = Time - lastLowEdge > 0.25 && Time - lastLowEdge < 1.6; lastLowEdge = Time; }
        if (lowHot && lowEdge && boomCandidate < 0 && Time - lastBoom > 1.1) { boomCandidate = Time; boomPeak = fastLow; candidateRhythmic = rhythmic; }
        if (boomCandidate >= 0)
        {
            boomPeak = Math.Max(boomPeak, fastLow);
            if (fastLow < slowLow * ratioBoom * 0.55f) boomCandidate = -1;
            else if (Time - boomCandidate >= 0.15)
            {
                if (candidateRhythmic && boomPeak < slowLow * ratioBoom * 2.2f) { boomCandidate = -1; goto Transients; }
                bool flash = Time - lastFlash < 0.4;
                float strength = Math.Min(1, 0.45f + (boomPeak / Math.Max(slowLow, 1e-4f) - ratioBoom) * 0.08f + (flash ? 0.25f : 0));
                output.Add(new SoundEvent(SoundEventKind.Boom, Time, strength, flash));
                lastBoom = Time; debrisUntil = Time + 1.8; boomCandidate = -1;
            }
        }
        Transients:
        bool inDebris = Time < debrisUntil && Time - lastBoom > 0.12;
        if (inDebris && c.High > slowHigh * 1.8f && c.High > 0.01f / s && Time - lastDebris > 0.07)
        {
            output.Add(new SoundEvent(SoundEventKind.Debris, Time, Math.Min(1, 0.25f + c.High * 4), false));
            lastDebris = Time;
        }
        else if (!inDebris && ready && boomCandidate < 0 && c.High > slowHigh * ratioHit && c.High > 0.02f / s && c.High > c.Low * 0.6f && Time - lastHit > 0.14 && Time - lastBoom > 0.25)
        {
            output.Add(new SoundEvent(SoundEventKind.SharpHit, Time, Math.Min(1, 0.4f + (c.High / Math.Max(slowHigh, 1e-4f) - ratioHit) * 0.05f), false));
            lastHit = Time;
        }
        float k = Math.Min(1, (float)dt / 1.2f);
        slowLow += (c.Low - slowLow) * k; slowMid += (c.Mid - slowMid) * k; slowHigh += (c.High - slowHigh) * k;
        slowLow = Math.Max(slowLow, 0.002f); slowHigh = Math.Max(slowHigh, 0.001f);
        Rumble = Math.Clamp((fastLow - 0.02f) * 4 * s, 0, 1);
    }
}

/// One analysed frame (same conventions as iOS): flow in grid cells per frame
/// (+x camera pans right), zoom + = push-in, roll + = picture rotates clockwise.
public readonly record struct MotionSample(Vector2 Flow, float Zoom, float Roll, float Shake, float Confidence, float Energy, bool Cut, bool Flash);

/// 32×18 luminance block-matching tracker with sub-cell refinement and
/// per-quadrant zoom/roll.
public sealed class MotionTracker
{
    public const int W = 32, H = 18;
    float[]? prev;
    float prevMean;
    Vector2 smoothFlow;
    readonly float[] cur = new float[W * H];

    public void Reset() { prev = null; prevMean = 0; smoothFlow = Vector2.Zero; }

    /// Builds the grid from a BGRA frame (2×2 taps per cell).
    public static void Grid(byte[] bgra, int w, int h, float[] dst)
    {
        for (int gy = 0; gy < H; gy++)
            for (int gx = 0; gx < W; gx++)
            {
                float l = 0;
                for (int j = 0; j < 2; j++)
                    for (int i = 0; i < 2; i++)
                    {
                        int x = Math.Min(w - 1, (int)((gx + (i + 0.5f) / 2) * w / W)), y = Math.Min(h - 1, (int)((gy + (j + 0.5f) / 2) * h / H));
                        int k = (y * w + x) * 4;
                        l += (0.0722f * bgra[k] + 0.7152f * bgra[k + 1] + 0.2126f * bgra[k + 2]) / 255f;
                    }
                dst[gy * W + gx] = l * 0.25f;
            }
    }

    public MotionSample? Analyse(float[] lum)
    {
        if (lum.Length < W * H) return null;
        float mean = 0;
        for (int i = 0; i < W * H; i++) { var v = float.IsFinite(lum[i]) ? Math.Clamp(lum[i], 0, 1) : 0; cur[i] = v; mean += v; }
        mean /= W * H;
        if (prev == null) { prev = (float[])cur.Clone(); prevMean = mean; return null; }
        float diff = 0;
        for (int i = 0; i < W * H; i++) diff += Math.Abs(cur[i] - prev[i]);
        diff /= W * H;
        if (diff < 0.0006f) return null;
        bool flash = mean - prevMean > 0.15f;
        try
        {
            if (diff > 0.12f) { smoothFlow = Vector2.Zero; return new MotionSample(Vector2.Zero, 0, 0, 0, 0, diff, true, flash); }
            var p = prev!;
            float Cost(int dx, int dy, int x0, int x1, int y0, int y1)
            {
                float s = 0;
                for (int y = y0; y < y1; y++) { int row = y * W, prow = (y + dy) * W; for (int x = x0; x < x1; x++) s += Math.Abs(cur[row + x] - p[prow + x + dx]); }
                return s / ((x1 - x0) * (y1 - y0));
            }
            // Integer search then parabolic sub-cell refinement; confidence is
            // how sharply the best match stands out from its neighbours.
            (Vector2 v, float conf) Search(int x0, int x1, int y0, int y1, int rx, int ry)
            {
                var costs = new float[2 * ry + 1, 2 * rx + 1];
                float best = float.MaxValue; int bx = 0, by = 0; float sum = 0;
                for (int dy = -ry; dy <= ry; dy++)
                    for (int dx = -rx; dx <= rx; dx++)
                    {
                        var c = Cost(dx, dy, x0, x1, y0, y1);
                        costs[dy + ry, dx + rx] = c; sum += c;
                        if (c < best) { best = c; bx = dx; by = dy; }
                    }
                static float Refine(float cm, float c0, float cp) { var den = cm - 2 * c0 + cp; return den > 1e-7f ? Math.Clamp((cm - cp) / (2 * den), -0.5f, 0.5f) : 0; }
                float fx = bx, fy = by;
                if (bx > -rx && bx < rx) fx += Refine(costs[by + ry, bx + rx - 1], best, costs[by + ry, bx + rx + 1]);
                if (by > -ry && by < ry) fy += Refine(costs[by + ry - 1, bx + rx], best, costs[by + ry + 1, bx + rx]);
                var avg = sum / ((2 * rx + 1) * (2 * ry + 1));
                var conf = avg > 0.002f ? Math.Clamp((avg - best) / avg * 1.6f, 0, 1) : 0;
                return (new Vector2(fx, fy), conf);
            }
            var (global, confidence) = Search(3, W - 3, 2, H - 2, 3, 2);
            var flow = confidence > 0.12f ? global : Vector2.Zero;
            var regions = new[] { (3, 16, 2, 9), (16, W - 3, 2, 9), (3, 16, 9, H - 2), (16, W - 3, 9, H - 2) };
            var dirs = new[] { new Vector2(-1, -1), new Vector2(1, -1), new Vector2(-1, 1), new Vector2(1, 1) }.Select(Vector2.Normalize).ToArray();
            float zoom = 0, roll = 0;
            for (int i = 0; i < 4; i++)
            {
                var r = regions[i];
                var (q, _) = Search(r.Item1, r.Item2, r.Item3, r.Item4, 2, 2);
                var content = -(q - global);
                zoom += Vector2.Dot(content, dirs[i]);
                roll += dirs[i].X * content.Y - dirs[i].Y * content.X;
            }
            zoom = confidence > 0.12f ? zoom / 4 : 0; roll = confidence > 0.12f ? roll / 4 : 0;
            var shake = (flow - smoothFlow).Length();
            smoothFlow += (flow - smoothFlow) * 0.3f;
            return new MotionSample(flow, zoom, roll, shake, confidence, diff, false, flash);
        }
        finally { Array.Copy(cur, prev, W * H); prevMean = mean; }
    }
}

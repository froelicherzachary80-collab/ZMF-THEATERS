using System.IO;
using System.Net.Http;
using Microsoft.ML.OnnxRuntime;
using Microsoft.ML.OnnxRuntime.Tensors;

namespace ZMFTheaters.Cinema;

/// ZMF DepthCinema AI for Windows: Depth Anything V2 (small, ONNX) on the GPU
/// through DirectML (falls back to CPU), temporal stabilisation, then CPU
/// depth-image-based rendering of left/right views into a red/cyan anaglyph.
public sealed class StereoConverter : IDisposable
{
    public const string ModelUrl = "https://huggingface.co/onnx-community/depth-anything-v2-small/resolve/main/onnx/model.onnx";
    const int InW = 518, InH = 294;   // multiples of 14 (the ViT patch size), ~16:9
    static readonly float[] Mean = { 0.485f, 0.456f, 0.406f };
    static readonly float[] Std = { 0.229f, 0.224f, 0.225f };

    InferenceSession? session;
    string inputName = "pixel_values";
    float[]? depth;            // stabilised, normalised (near = 1), InW x InH
    float lo, hi = 1;
    bool busy;
    DateTime lastRun = DateTime.MinValue;

    public string Status { get; private set; } = "3D: preparing depth model…";
    public bool Ready => session != null;
    public string Provider { get; private set; } = "";
    public double SeparationFraction { get; set; } = 0.012;
    public double Convergence { get; set; } = 0.45;
    public double Ghost { get; set; } = 0.6;
    public double Rate { get; set; } = 8;

    public static string ModelPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "ZMFTheaters", "models", "depth-anything-v2-small.onnx");

    /// Downloads the model once (~99 MB) into %APPDATA% and opens a session.
    public async Task InitAsync(IProgress<string>? progress = null)
    {
        try
        {
            if (!File.Exists(ModelPath))
            {
                Directory.CreateDirectory(Path.GetDirectoryName(ModelPath)!);
                using var http = new HttpClient { Timeout = TimeSpan.FromMinutes(20) };
                using var resp = await http.GetAsync(ModelUrl, HttpCompletionOption.ResponseHeadersRead);
                resp.EnsureSuccessStatusCode();
                var total = resp.Content.Headers.ContentLength ?? 0;
                var tmp = ModelPath + ".part";
                await using (var src = await resp.Content.ReadAsStreamAsync())
                await using (var dst = File.Create(tmp))
                {
                    var buf = new byte[1 << 20];
                    long done = 0; int n;
                    while ((n = await src.ReadAsync(buf)) > 0)
                    {
                        await dst.WriteAsync(buf.AsMemory(0, n));
                        done += n;
                        if (total > 0) progress?.Report($"3D: downloading depth model {done * 100 / total}% (one time)");
                    }
                }
                File.Move(tmp, ModelPath, true);
            }
            progress?.Report("3D: loading depth model…");
            session = await Task.Run(() =>
            {
                try
                {
                    var o = new SessionOptions();
                    o.AppendExecutionProvider_DML(0);
                    Provider = "DirectML GPU";
                    return new InferenceSession(ModelPath, o);
                }
                catch
                {
                    Provider = "CPU";
                    return new InferenceSession(ModelPath, new SessionOptions());
                }
            });
            inputName = session.InputMetadata.Keys.First();
            Status = $"3D · Depth Anything V2 on {Provider}";
        }
        catch (Exception ex)
        {
            Status = "3D unavailable: " + ex.Message + " · playing 2D";
        }
        progress?.Report(Status);
    }

    /// Kicks off a depth estimate for this frame if the model is idle and due.
    public void Submit(byte[] bgra, int w, int h)
    {
        if (session == null || busy || (DateTime.UtcNow - lastRun).TotalSeconds < 1 / Math.Max(1, Rate)) return;
        busy = true;
        lastRun = DateTime.UtcNow;
        var frame = (byte[])bgra.Clone();
        Task.Run(() =>
        {
            try { Estimate(frame, w, h); }
            catch (Exception ex) { Status = "3D depth error: " + ex.Message; }
            finally { busy = false; }
        });
    }

    void Estimate(byte[] bgra, int w, int h)
    {
        var input = new DenseTensor<float>(new[] { 1, 3, InH, InW });
        for (int y = 0; y < InH; y++)
        {
            int sy = y * h / InH;
            for (int x = 0; x < InW; x++)
            {
                int i = (sy * w + x * w / InW) * 4;
                input[0, 0, y, x] = (bgra[i + 2] / 255f - Mean[0]) / Std[0];
                input[0, 1, y, x] = (bgra[i + 1] / 255f - Mean[1]) / Std[1];
                input[0, 2, y, x] = (bgra[i] / 255f - Mean[2]) / Std[2];
            }
        }
        using var results = session!.Run(new[] { NamedOnnxValue.CreateFromTensor(inputName, input) });
        var raw = results.First().AsEnumerable<float>().ToArray();
        if (raw.Length != InW * InH) return;
        float mn = raw.Min(), mx = raw.Max();
        bool first = depth == null;
        lo = first ? mn : lo + (mn - lo) * 0.2f;
        hi = first ? mx : hi + (mx - hi) * 0.2f;
        var inv = 1f / Math.Max(1e-5f, hi - lo);
        var next = new float[raw.Length];
        var prev = depth;
        for (int i = 0; i < raw.Length; i++)
        {
            var n = Math.Clamp((raw[i] - lo) * inv, 0f, 1f);
            next[i] = prev == null ? n : prev[i] * 0.55f + n * 0.45f;   // temporal stabilisation
        }
        depth = next;
    }

    /// Writes the red/cyan anaglyph of `src` into `dst` (same size, BGRA).
    /// Returns false until the first depth map exists.
    public bool Compose(byte[] src, byte[] dst, int w, int h)
    {
        var d = depth;
        if (d == null) return false;
        double sep = SeparationFraction * w, conv = Convergence, ghost = Ghost;
        Parallel.For(0, h, y =>
        {
            int dy = Math.Min(InH - 1, y * InH / h);
            int row = y * w * 4;
            for (int x = 0; x < w; x++)
            {
                int dx = Math.Min(InW - 1, x * InW / w);
                // Edge-aware: dilate depth horizontally so foreground edges don't tear.
                float dv = d[dy * InW + dx];
                if (dx > 1) dv = Math.Max(dv, d[dy * InW + dx - 2]);
                if (dx < InW - 2) dv = Math.Max(dv, d[dy * InW + dx + 2]);
                int disp = (int)((dv - conv) * sep);
                int lx = Math.Clamp(x - disp, 0, w - 1), rx = Math.Clamp(x + disp, 0, w - 1);
                int li = row + lx * 4, ri = row + rx * 4, o = row + x * 4;
                double lr = src[li + 2], lg = src[li + 1], lb = src[li];
                double red = lr * (1 - ghost) + (0.7 * lg + 0.3 * lb) * ghost;
                dst[o + 2] = (byte)Math.Clamp(red, 0, 255);
                dst[o + 1] = src[ri + 1];
                dst[o] = src[ri];
                dst[o + 3] = 255;
            }
        });
        return true;
    }

    /// Headless check used by CI: downloads the model and runs one inference.
    public static async Task<int> SelfTestAsync(string logPath)
    {
        var c = new StereoConverter();
        await c.InitAsync();
        if (!c.Ready) { File.WriteAllText(logPath, c.Status); return 2; }
        int w = 640, h = 360;
        var frame = new byte[w * h * 4];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int i = (y * w + x) * 4;
                bool box = x > 220 && x < 420 && y > 100 && y < 260;
                frame[i] = (byte)(box ? 40 : y * 255 / h); frame[i + 1] = (byte)(box ? 200 : 90); frame[i + 2] = (byte)(box ? 240 : x * 255 / w); frame[i + 3] = 255;
            }
        c.Estimate(frame, w, h);
        var outFrame = new byte[frame.Length];
        var ok = c.Compose(frame, outFrame, w, h);
        File.WriteAllText(logPath, $"provider={c.Provider} depthReady={ok} min={c.depth?.Min():0.00} max={c.depth?.Max():0.00}");
        return ok ? 0 : 3;
    }

    public void Dispose() => session?.Dispose();
}

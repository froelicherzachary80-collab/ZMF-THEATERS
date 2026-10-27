using NAudio.Wave;

namespace ZMFTheaters.Cinema;

/// Listens to the PC's audio output (WASAPI loopback) and reduces it to
/// band-energy chunks for real-time 4DX sound events. LibVLC plays the film
/// to the default device, so this hears the soundtrack (plus any other
/// sounds the PC is playing). Nothing is recorded or stored.
public sealed class LoopbackSound : IDisposable
{
    WasapiLoopbackCapture? capture;
    BandSplitter? splitter;
    readonly List<AudioChunk> pending = new();
    readonly object gate = new();
    float[] scratch = Array.Empty<float>();
    public bool Running { get; private set; }
    public string? Error { get; private set; }

    public void Start()
    {
        if (Running) return;
        try
        {
            capture = new WasapiLoopbackCapture();
            var fmt = capture.WaveFormat;
            splitter = new BandSplitter(fmt.SampleRate);
            capture.DataAvailable += (_, e) => OnData(e.Buffer, e.BytesRecorded, fmt);
            capture.StartRecording();
            Running = true;
        }
        catch (Exception ex) { Error = ex.Message; capture?.Dispose(); capture = null; }
    }

    void OnData(byte[] buffer, int bytes, WaveFormat fmt)
    {
        if (splitter == null || bytes <= 0) return;
        int channels = Math.Max(1, fmt.Channels);
        int samples;
        if (fmt.Encoding == WaveFormatEncoding.IeeeFloat || (fmt.Encoding == WaveFormatEncoding.Extensible && fmt.BitsPerSample == 32))
        {
            samples = bytes / 4;
            if (scratch.Length < samples) scratch = new float[samples];
            Buffer.BlockCopy(buffer, 0, scratch, 0, samples * 4);
        }
        else if (fmt.BitsPerSample == 16)
        {
            samples = bytes / 2;
            if (scratch.Length < samples) scratch = new float[samples];
            for (int i = 0; i < samples; i++) scratch[i] = BitConverter.ToInt16(buffer, i * 2) / 32768f;
        }
        else return;
        var chunks = new List<AudioChunk>();
        splitter.Push(scratch.AsSpan(0, samples), channels, chunks);
        lock (gate) { if (pending.Count < 600) pending.AddRange(chunks); }
    }

    /// Chunks captured since the last call (oldest first).
    public List<AudioChunk> Drain()
    {
        lock (gate) { var copy = new List<AudioChunk>(pending); pending.Clear(); return copy; }
    }

    public void Stop()
    {
        Running = false;
        try { capture?.StopRecording(); } catch { }
        capture?.Dispose();
        capture = null;
        lock (gate) pending.Clear();
    }

    public void Dispose() => Stop();
}

using System.Runtime.InteropServices;
using System.Text;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using LibVLCSharp.Shared;
using MediaPlayer = LibVLCSharp.Shared.MediaPlayer;

namespace ZMFTheaters.Cinema;

/// Receives decoded frames from LibVLC (RV32/BGRA, via the video memory
/// callbacks) so the movie can be textured onto the 3D cinema screen,
/// converted to 3D, and analysed for 4DX. Audio keeps playing through LibVLC.
public sealed class VideoFrames : IDisposable
{
    readonly object gate = new();
    readonly int maxWidth;
    IntPtr buffer;
    int width, height;
    byte[]? latest;
    long frameNumber;
    long consumed;

    // Keep the delegates alive for as long as LibVLC can call them.
    readonly MediaPlayer.LibVLCVideoFormatCb formatCb;
    readonly MediaPlayer.LibVLCVideoCleanupCb cleanupCb;
    readonly MediaPlayer.LibVLCVideoLockCb lockCb;
    readonly MediaPlayer.LibVLCVideoDisplayCb displayCb;

    public WriteableBitmap? Bitmap { get; private set; }
    public int Width => width;
    public int Height => height;

    public VideoFrames(int maxWidth)
    {
        this.maxWidth = maxWidth;
        formatCb = Format;
        cleanupCb = Cleanup;
        lockCb = Lock;
        displayCb = Display;
    }

    public void Attach(MediaPlayer player)
    {
        player.SetVideoFormatCallbacks(formatCb, cleanupCb);
        player.SetVideoCallbacks(lockCb, null, displayCb);
    }

    uint Format(ref IntPtr opaque, IntPtr chroma, ref uint w, ref uint h, ref uint pitches, ref uint lines)
    {
        var scale = Math.Min(1.0, maxWidth / (double)Math.Max(1, w));
        var nw = Math.Max(2, (int)(w * scale) & ~1);
        var nh = Math.Max(2, (int)(h * scale) & ~1);
        Marshal.Copy(Encoding.ASCII.GetBytes("RV32"), 0, chroma, 4);
        w = (uint)nw; h = (uint)nh;
        pitches = (uint)(nw * 4);
        lines = (uint)nh;
        lock (gate)
        {
            if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            buffer = Marshal.AllocHGlobal(nw * nh * 4);
            width = nw; height = nh;
            latest = new byte[nw * nh * 4];
        }
        return 1;
    }

    void Cleanup(ref IntPtr opaque) { }

    IntPtr Lock(IntPtr opaque, IntPtr planes)
    {
        Marshal.WriteIntPtr(planes, buffer);
        return IntPtr.Zero;
    }

    void Display(IntPtr opaque, IntPtr picture)
    {
        lock (gate)
        {
            if (latest == null || buffer == IntPtr.Zero) return;
            Marshal.Copy(buffer, latest, 0, latest.Length);
            frameNumber++;
        }
    }

    /// Copies the newest decoded frame (BGRA) if there is one the caller hasn't seen.
    public bool TryTakeFrame(ref byte[]? dest, out int w, out int h)
    {
        lock (gate)
        {
            w = width; h = height;
            if (latest == null || frameNumber == consumed) return false;
            if (dest == null || dest.Length != latest.Length) dest = new byte[latest.Length];
            Buffer.BlockCopy(latest, 0, dest, 0, latest.Length);
            consumed = frameNumber;
            return true;
        }
    }

    /// Writes BGRA pixels into the screen bitmap (created on first use). UI thread only.
    public WriteableBitmap Present(byte[] pixels, int w, int h)
    {
        if (Bitmap == null || Bitmap.PixelWidth != w || Bitmap.PixelHeight != h)
            Bitmap = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgr32, null);
        Bitmap.WritePixels(new Int32Rect(0, 0, w, h), pixels, w * 4, 0);
        return Bitmap;
    }

    public void Dispose()
    {
        lock (gate)
        {
            if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
            buffer = IntPtr.Zero;
            latest = null;
        }
    }
}

using System.Windows;
using ZMFTheaters.Cinema;
using ZMFTheaters.Jellyfin;

namespace ZMFTheaters;

public partial class App : Application
{
    protected override async void OnStartup(StartupEventArgs e)
    {
        // Loads the bundled native LibVLC runtime (libvlc\win-x64 next to the exe).
        LibVLCSharp.Shared.Core.Initialize();
        base.OnStartup(e);
        var args = e.Args;

        if (args.Length >= 2 && args[0] == "--selftest-home")
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            Shutdown(await Task.Run(() => ZMFTheaters.Home.HomeSelfTest.Run(args[1])));
            return;
        }
        // CI: screenshot a Home 4DX control-centre page (simulated devices).
        if (args.Length >= 3 && args[0] == "--shot-home")
        {
            var hub = new ZMFTheaters.Home.HomeHub(new ZMFTheaters.Home.HomeConfig(), () => { }, new ZMFTheaters.Home.RoomStore(null));
            hub.Devices.UseMocks();
            ZMFTheaters.Home.HomeHub.Current = hub;
            var w = new ZMFTheaters.Home.HomeControlWindow(hub, () => { }, args[1]);
            w.Show();
            await Task.Delay(2500);
            try
            {
                var rtb = new System.Windows.Media.Imaging.RenderTargetBitmap((int)w.ActualWidth, (int)w.ActualHeight, 96, 96, System.Windows.Media.PixelFormats.Pbgra32);
                rtb.Render((System.Windows.Media.Visual)w.Content);
                var enc = new System.Windows.Media.Imaging.PngBitmapEncoder();
                enc.Frames.Add(System.Windows.Media.Imaging.BitmapFrame.Create(rtb));
                using var fs = System.IO.File.Create(args[2]);
                enc.Save(fs);
            }
            finally { Shutdown(0); }
            return;
        }
        if (args.Length >= 2 && args[0] == "--selftest-4dx")
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            Shutdown(FourDXSelfTest.Run(args[1]));
            return;
        }
        // CI: download the depth model and run one 2D→3D conversion headlessly.
        if (args.Length >= 2 && args[0] == "--selftest-3d")
        {
            ShutdownMode = ShutdownMode.OnExplicitShutdown;
            Shutdown(await StereoConverter.SelfTestAsync(args[1]));
            return;
        }
        // CI: render the 3D cinema from a preset camera to a PNG.
        if (args.Length >= 3 && args[0] == "--shot")
        {
            var cfg = new AppConfig();
            new CinemaWindow(cfg, s => new JellyfinClient(s.Url, s.Token, cfg.DeviceId), new List<MediaEntry>(), shotName: args[1], shotPath: args[2]).Show();
            return;
        }
        new MainWindow().Show();
    }
}


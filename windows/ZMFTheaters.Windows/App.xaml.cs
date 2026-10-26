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


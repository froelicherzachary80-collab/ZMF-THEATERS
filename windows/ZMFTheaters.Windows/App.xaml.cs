using System.Windows;

namespace ZMFTheaters;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        // Loads the bundled native LibVLC runtime (libvlc\win-x64 next to the exe).
        LibVLCSharp.Shared.Core.Initialize();
        base.OnStartup(e);
    }
}

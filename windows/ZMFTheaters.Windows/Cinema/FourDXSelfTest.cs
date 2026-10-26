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
        File.WriteAllLines(path, log);
        return log.Any(s => s.StartsWith("FAIL")) ? 1 : 0;
    }
}

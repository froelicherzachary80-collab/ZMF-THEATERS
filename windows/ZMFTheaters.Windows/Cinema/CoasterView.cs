using System.Numerics;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Media3D;

namespace ZMFTheaters.Cinema;

/// WPF scene for the ZMF roller-coaster intro. It lives in its own Viewport3D
/// that the auditorium screen shows through a VisualBrush, so the ride plays
/// on the in-world screen while you sit in your seat.
public sealed class CoasterView
{
    public Border Host { get; }
    readonly PerspectiveCamera cam = new() { FieldOfView = 70, NearPlaneDistance = 0.1, FarPlaneDistance = 420 };
    readonly ZMFCoasterTrack track = ZMFCoasterTrack.Shared;
    readonly Model3DGroup dynamic = new();
    readonly MatrixTransform3D carXf = new();
    readonly Model3DGroup spray = new();
    readonly Model3DGroup fireworks = new();
    readonly MeshGeometry3D cube = WorldBuilder.UnitBox();
    readonly List<TranslateTransform3D> sprayParts = new();
    readonly List<(TranslateTransform3D t, ScaleTransform3D s)> sparks = new();

    public CoasterView(int width = 960, int height = 408)
    {
        var view = new Viewport3D { Camera = cam, Width = width, Height = height, ClipToBounds = true };
        var root = new Model3DGroup();
        root.Children.Add(new AmbientLight(Mats.C(.22, .2, .28)));
        root.Children.Add(new DirectionalLight(Mats.C(.35, .35, .45), new Vector3D(-0.4, -1, 0.3)));
        root.Children.Add(new PointLight(Mats.C(1, .85, .55), P(ZMFCoasterTrack.LogoPosition + new Vector3(0, 0, -10))) { Range = 50, QuadraticAttenuation = 0.0015 });
        root.Children.Add(new PointLight(Mats.C(.4, .75, 1), P(ZMFCoasterTrack.PoolCenter + new Vector3(0, 6, 0))) { Range = 35, QuadraticAttenuation = 0.003 });
        root.Children.Add(new PointLight(Mats.C(1, .85, .6), new Point3D(0, 4, -3)) { Range = 24, QuadraticAttenuation = 0.005 });
        root.Children.Add(BuildWorld());
        var carGroup = BuildCar();
        carGroup.Transform = carXf;
        dynamic.Children.Add(carGroup);
        dynamic.Children.Add(spray);
        dynamic.Children.Add(fireworks);
        root.Children.Add(dynamic);
        var glowWater = Mats.Glow(Mats.C(.7, .88, 1));
        for (int i = 0; i < 40; i++)
        {
            var t = new TranslateTransform3D();
            var g = new Transform3DGroup();
            g.Children.Add(new ScaleTransform3D(0.08, 0.08, 0.08));
            g.Children.Add(t);
            sprayParts.Add(t);
            spray.Children.Add(new GeometryModel3D(cube, glowWater) { Transform = g });
        }
        var hues = new[] { Mats.C(1, .75, .3), Mats.C(1, .2, .25), Mats.C(.4, .8, 1), Mats.C(1, .95, .8), Mats.C(.8, .4, 1) };
        for (int b = 0; b < 5; b++)
            for (int k = 0; k < 24; k++)
            {
                var t = new TranslateTransform3D(); var s = new ScaleTransform3D(0, 0, 0);
                var g = new Transform3DGroup(); g.Children.Add(s); g.Children.Add(t);
                sparks.Add((t, s));
                fireworks.Children.Add(new GeometryModel3D(cube, Mats.Glow(hues[b])) { Transform = g });
            }
        view.Children.Add(new ModelVisual3D { Content = root });
        Host = new Border
        {
            Width = width, Height = height, Child = view,
            Background = new LinearGradientBrush(Mats.C(.01, .01, .04), Mats.C(.08, .03, .12), 90),
        };
        Host.Measure(new Size(width, height));
        Host.Arrange(new Rect(0, 0, width, height));
        Update(0);
    }

    static Point3D P(Vector3 v) => new(v.X, v.Y, v.Z);
    static Vector3D D(Vector3 v) => new(v.X, v.Y, v.Z);
    static float Hash(float n) { var v = MathF.Sin(n * 12.9898f) * 43758.545f; return v - MathF.Floor(v); }

    static Material Steel(Color c)
    {
        var g = new MaterialGroup();
        g.Children.Add(new DiffuseMaterial(new SolidColorBrush(c)));
        g.Children.Add(new SpecularMaterial(new SolidColorBrush(Colors.White), 40));
        g.Freeze();
        return g;
    }

    static void OrientedBox(MeshBuilder3D b, Vector3 c, Vector3 x, Vector3 y, Vector3 z, Vector3 h, Material m)
    {
        var ax = x * h.X; var ay = y * h.Y; var az = z * h.Z;
        Point3D Pt(int i, int j, int k) => P(c + ax * i + ay * j + az * k);
        b.Quad(Pt(-1, -1, 1), Pt(1, -1, 1), Pt(1, 1, 1), Pt(-1, 1, 1), D(z), m);
        b.Quad(Pt(1, -1, -1), Pt(-1, -1, -1), Pt(-1, 1, -1), Pt(1, 1, -1), D(-z), m);
        b.Quad(Pt(1, -1, 1), Pt(1, -1, -1), Pt(1, 1, -1), Pt(1, 1, 1), D(x), m);
        b.Quad(Pt(-1, -1, -1), Pt(-1, -1, 1), Pt(-1, 1, 1), Pt(-1, 1, -1), D(-x), m);
        b.Quad(Pt(-1, 1, 1), Pt(1, 1, 1), Pt(1, 1, -1), Pt(-1, 1, -1), D(y), m);
        b.Quad(Pt(-1, -1, -1), Pt(1, -1, -1), Pt(1, -1, 1), Pt(-1, -1, 1), D(-y), m);
    }

    Model3DGroup BuildWorld()
    {
        var b = new MeshBuilder3D();
        var rail = Steel(Mats.C(.72, .75, .8));
        var spine = Steel(Mats.C(.75, .04, .07));
        var tie = Mats.Lit(Mats.C(.2, .2, .22));
        var support = Steel(Mats.C(.18, .19, .22));
        var gold = Mats.Glow(Mats.C(1, .72, .25));
        var red = Mats.Glow(Mats.C(1, .12, .12));
        var grid = Mats.Glow(Mats.C(.3, .08, .5));
        b.Box(-140, -0.2, -80, 160, 0, 260, Mats.Lit(Mats.C(.03, .03, .05)));
        for (int i = -140; i <= 160; i += 20) b.BoxC(i, 0.01, 90, 0.1, 0.02, 340, grid);
        for (int k = -80; k <= 260; k += 20) b.BoxC(10, 0.01, k, 300, 0.02, 0.1, grid);

        int n = 0;
        for (float s = 0; s < track.Length; s += 2, n++)
        {
            var a = track.Point(s); var c = track.Point(Math.Min(track.Length, s + 2.04f));
            var mid = (a + c) * 0.5f;
            var f = track.Frame(s + 1);
            foreach (var side in new[] { -0.55f, 0.55f })
            {
                OrientedBox(b, mid + f.right * side, f.right, f.up, f.forward, new Vector3(0.05f, 0.05f, 1.04f), rail);
                OrientedBox(b, mid + f.right * (side * 1.16f) - f.up * 0.06f, f.right, f.up, f.forward, new Vector3(0.03f, 0.03f, 0.55f), n % 2 == 0 ? gold : red);
            }
            OrientedBox(b, mid - f.up * 0.38f, f.right, f.up, f.forward, new Vector3(0.13f, 0.13f, 1.03f), spine);
            OrientedBox(b, mid - f.up * 0.12f, f.right, f.up, f.forward, new Vector3(0.68f, 0.035f, 0.07f), tie);
            if (n % 4 == 0 && mid.Y > 1.6f)
            {
                var top = mid - f.up * 0.5f;
                b.Box(top.X - 0.18, 0, top.Z - 0.18, top.X + 0.18, top.Y, top.Z + 0.18, support);
            }
        }

        // Station, ADMIT ONE arch and film-reel rings.
        b.Box(-4, 0, -14, 4, 1.4, 8, Mats.Lit(Mats.C(.12, .1, .12)));
        b.Box(-5, 5.5, -14, 5, 5.8, 8, Steel(Mats.C(.75, .04, .07)));
        b.BoxC(0, 5.4, -3, 8, 0.05, 20, Mats.Glow(Mats.C(1, .85, .6)));
        var arch = track.Point(0.12f * track.Length);
        foreach (var x in new[] { -3.5, 3.5 }) b.BoxC(arch.X + x, arch.Y / 2 + 3, arch.Z, 0.5, arch.Y + 6, 0.5, Steel(Mats.C(.85, .7, .3)));
        b.Sign(arch.X, arch.Y + 5.2, arch.Z - 0.3, 0, 0, -1, 8, 1.15,
            Mats.Picture(Mats.Text("ADMIT ONE · ZMF EXPRESS", 1400, 200, Colors.White, Mats.C(.75, .05, .08), 110, Mats.C(1, .8, .35))));
        var ringGold = Steel(Mats.C(.9, .7, .25));
        foreach (var frac in new[] { 0.36f, 0.5f, 0.79f })
        {
            var s0 = frac * track.Length;
            var f = track.Frame(s0);
            var p = track.Point(s0) + f.up * 1.0f;
            for (int k = 0; k < 24; k++)
            {
                var a0 = k / 24f * MathF.PI * 2;
                var dir = f.right * MathF.Cos(a0) + f.up * MathF.Sin(a0);
                var tdir = f.right * -MathF.Sin(a0) + f.up * MathF.Cos(a0);
                OrientedBox(b, p + dir * 4.6f, dir, tdir, f.forward, new Vector3(0.22f, 0.62f, 0.3f), ringGold);
                if (k % 2 == 0) OrientedBox(b, p + dir * 4.3f, dir, tdir, f.forward, new Vector3(0.05f, 0.22f, 0.32f), gold);
            }
        }

        // Giant popcorn buckets.
        var buckets = new[] { new Vector3(-14, 0, 106), new Vector3(13, 0, 112), new Vector3(-12, 0, 128), new Vector3(30, 0, 118) };
        var stripeR = Mats.Lit(Mats.C(.85, .06, .08)); var stripeW = Mats.Lit(Mats.C(.95, .93, .9)); var corn = Mats.Lit(Mats.C(1, .88, .55));
        for (int i = 0; i < buckets.Length; i++)
        {
            var bs = buckets[i]; float r = 3.2f + (i % 2) * 0.8f, h = 9 + i * 1.5f;
            for (int k = 0; k < 16; k++)
            {
                var a0 = k / 16f * MathF.PI * 2;
                var dir = new Vector3(MathF.Cos(a0), 0, MathF.Sin(a0));
                OrientedBox(b, bs + dir * r + new Vector3(0, h / 2, 0), dir, Vector3.UnitY, Vector3.Cross(dir, Vector3.UnitY), new Vector3(0.15f, h / 2, r * 0.21f), k % 2 == 0 ? stripeR : stripeW);
            }
            for (int k = 0; k < 18; k++)
            {
                var a0 = Hash(i * 40 + k) * MathF.PI * 2; var rr = MathF.Sqrt(Hash(i * 40 + k + 3)) * r;
                var sz = 0.7 + Hash(k + 1) * 0.5;
                b.BoxC(bs.X + MathF.Cos(a0) * rr, h + 0.2 + Hash(k + 9) * 1.4, bs.Z + MathF.Sin(a0) * rr, sz, sz, sz, corn);
            }
        }

        // Splash pool and tunnel arches.
        var pool = ZMFCoasterTrack.PoolCenter;
        b.Box(pool.X - 16, 0, pool.Z - 18, pool.X + 16, 0.05, pool.Z + 18, Steel(Mats.C(.05, .25, .5)));
        var arcPost = Steel(Mats.C(.15, .6, .9)); var arcGlow = Mats.Glow(Mats.C(.3, .85, 1));
        for (var s = ZMFCoasterTrack.SplashFrom * track.Length; s < ZMFCoasterTrack.SplashTo * track.Length; s += 4)
        {
            var f = track.Frame(s); var p = track.Point(s);
            foreach (var side in new[] { -2.2f, 2.2f }) OrientedBox(b, p + f.right * side + f.up * 1.6f, f.right, f.up, f.forward, new Vector3(0.18f, 1.8f, 0.18f), arcPost);
            OrientedBox(b, p + f.up * 3.4f, f.right, f.up, f.forward, new Vector3(2.4f, 0.12f, 0.2f), arcGlow);
        }

        // Stars and skyline.
        var star = Mats.Glow(Mats.C(.9, .92, 1));
        for (int i = 0; i < 160; i++)
        {
            float a0 = Hash(i) * MathF.PI * 2, e = 0.12f + Hash(i + 7) * 1.3f;
            var p = new Vector3(MathF.Cos(a0) * MathF.Cos(e), MathF.Sin(e), MathF.Sin(a0) * MathF.Cos(e)) * 210 + new Vector3(10, 0, 90);
            var sz = 0.6 + Hash(i + 2);
            b.BoxC(p.X, p.Y, p.Z, sz, sz, sz, star);
        }
        var building = Mats.Lit(Mats.C(.05, .05, .07)); var window = Mats.Glow(Mats.C(1, .82, .5));
        for (int i = 0; i < 48; i++)
        {
            float a0 = i / 48f * MathF.PI * 2, rad = 150 + Hash(i + 11) * 25, w = 8 + Hash(i) * 10, h = 14 + Hash(i + 3) * 45;
            var c = new Vector3(10 + MathF.Cos(a0) * rad, h / 2, 90 + MathF.Sin(a0) * rad);
            b.BoxC(c.X, c.Y, c.Z, w, h, w, building);
            var outward = -Vector3.Normalize(new Vector3(MathF.Cos(a0), 0, MathF.Sin(a0)));
            for (int k = 0; k < 4; k++)
            {
                if (Hash(i * 10 + k) < 0.35f) continue;
                var wp = c + outward * (w / 2 + 0.05f) + new Vector3(0, 3 + Hash(i * 10 + k + 1) * (h - 5) - h / 2, 0) + Vector3.Cross(outward, Vector3.UnitY) * ((Hash(k) - 0.5f) * w * 0.7f);
                b.BoxC(wp.X, wp.Y, wp.Z, 1.2, 0.8, 1.2, window);
            }
        }

        // Marquee.
        var logo = ZMFCoasterTrack.LogoPosition;
        b.Sign(logo.X, logo.Y, logo.Z, 0, 0, -1, 34, 7,
            Mats.Picture(Mats.Text("ZMF THEATERS", 2048, 420, Mats.C(1, .8, .35), Mats.C(.07, .01, .03), 300, Mats.C(1, .8, .35))));
        b.Sign(logo.X, logo.Y - 6, logo.Z - 0.2, 0, 0, -1, 16, 2.3,
            Mats.Picture(Mats.Text("ENJOY THE SHOW", 1400, 200, Colors.White, Mats.C(.07, .01, .03), 120, Mats.C(1, .8, .35))));
        b.Box(logo.X - 18, logo.Y - 4.4, logo.Z + 0.1, logo.X + 18, logo.Y + 4.4, logo.Z + 1.2, Mats.Lit(Mats.C(.1, .02, .03)));
        var bulb = Mats.Glow(Mats.C(1, .9, .6));
        for (int k = 0; k < 36; k++) { b.BoxC(logo.X - 18 + k, logo.Y + 4.4, logo.Z - 0.1, .32, .32, .32, bulb); b.BoxC(logo.X - 18 + k, logo.Y - 4.4, logo.Z - 0.1, .32, .32, .32, bulb); }
        foreach (var x in new[] { -14.0, 14.0 }) b.Box(logo.X + x - 0.4, 0, logo.Z + 0.5, logo.X + x + 0.4, logo.Y - 4.4, logo.Z + 1.3, support);
        return b.Build();
    }

    static Model3DGroup BuildCar()
    {
        // Built in the car's local frame: x right, y up, z forward.
        var b = new MeshBuilder3D();
        b.BoxC(0, 0.45, 1.3, 1.5, 0.5, 1.2, Steel(Mats.C(.7, .03, .06)));
        b.BoxC(0, 0.65, 1.95, 1.55, 0.08, 0.1, Mats.Glow(Mats.C(1, .8, .35)));
        b.BoxC(0, 0.83, 0.55, 0.9, 0.12, 0.14, Mats.Lit(Mats.C(.08, .08, .09)));
        b.BoxC(-0.38, 0.63, 0.5, 0.06, 0.36, 0.06, Steel(Mats.C(.75, .76, .8)));
        b.BoxC(0.38, 0.63, 0.5, 0.06, 0.36, 0.06, Steel(Mats.C(.75, .76, .8)));
        return b.Build();
    }

    /// Positions the camera and animated parts for ride time t.
    public void Update(double t)
    {
        var p = track.PoseAt(t);
        var f = track.Frame(p.Distance);
        var look = track.Tangent(p.Distance + 3);
        var eye = p.Position + p.Up * 1.25f;
        var dir = Vector3.Normalize(f.forward * 0.6f + look * 0.4f);
        cam.Position = P(eye);
        cam.LookDirection = D(dir);
        cam.UpDirection = D(p.Up);
        // WPF's camera "right" is cross(look, up); the car mesh uses +x = that.
        var x = Vector3.Normalize(Vector3.Cross(p.Up, f.forward));   // right-handed basis keeps the car mesh unmirrored
        carXf.Matrix = new Matrix3D(x.X, x.Y, x.Z, 0, p.Up.X, p.Up.Y, p.Up.Z, 0, f.forward.X, f.forward.Y, f.forward.Z, 0, p.Position.X, p.Position.Y, p.Position.Z, 1);
        for (int i = 0; i < sprayParts.Count; i++)
        {
            var tp = sprayParts[i];
            if (!p.InSplash) { tp.OffsetY = -100; continue; }
            var life = (float)((t * 1.6 + Hash(i)) % 1);
            var pos = p.Position + f.forward * (2 + Hash(i + 1) * 6 - life * 3) + x * ((Hash(i + 3) - 0.5f) * 4) +
                      new Vector3(0, 0.3f + MathF.Sin(life * MathF.PI) * (1.5f + Hash(i + 5) * 2), 0);
            tp.OffsetX = pos.X; tp.OffsetY = pos.Y; tp.OffsetZ = pos.Z;
        }
        var finaleStart = track.RideDuration - 9;
        for (int burst = 0; burst < 5; burst++)
        {
            var age = (float)(t - (finaleStart + burst * 1.7));
            var centre = ZMFCoasterTrack.LogoPosition + new Vector3((Hash(burst) - 0.5f) * 40, 12 + Hash(burst + 4) * 10, 6 + Hash(burst + 8) * 8);
            for (int k = 0; k < 24; k++)
            {
                var (tt, ss) = sparks[burst * 24 + k];
                if (age <= 0 || age >= 2.6f) { ss.ScaleX = ss.ScaleY = ss.ScaleZ = 0; continue; }
                float a = Hash(burst * 50 + k) * MathF.PI * 2, e = (Hash(burst * 50 + k + 1) - 0.5f) * MathF.PI;
                var d = new Vector3(MathF.Cos(a) * MathF.Cos(e), MathF.Sin(e), MathF.Sin(a) * MathF.Cos(e));
                var pos = centre + d * age * 7 - new Vector3(0, age * age * 1.2f, 0);
                tt.OffsetX = pos.X; tt.OffsetY = pos.Y; tt.OffsetZ = pos.Z;
                ss.ScaleX = ss.ScaleY = ss.ScaleZ = 0.4 * Math.Max(0.2, 1 - age / 2.6);
            }
        }
    }
}

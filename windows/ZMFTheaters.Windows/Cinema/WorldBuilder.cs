using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Media.Media3D;

namespace ZMFTheaters.Cinema;

/// Shared, cached WPF 3D materials.
public static class Mats
{
    static readonly Dictionary<string, Material> Cache = new();

    public static Color C(double r, double g, double b) => Color.FromRgb((byte)Math.Clamp(r * 255, 0, 255), (byte)Math.Clamp(g * 255, 0, 255), (byte)Math.Clamp(b * 255, 0, 255));
    public static Color Scale(Color c, double k) => C(c.R / 255.0 * k, c.G / 255.0 * k, c.B / 255.0 * k);

    public static Material Lit(Color c)
    {
        var key = "L" + c;
        if (!Cache.TryGetValue(key, out var m))
        {
            var b = new SolidColorBrush(c); b.Freeze();
            m = new DiffuseMaterial(b); m.Freeze();
            Cache[key] = m;
        }
        return m;
    }

    public static Material Glow(Color c)
    {
        var key = "G" + c;
        if (!Cache.TryGetValue(key, out var m))
        {
            var b = new SolidColorBrush(c); b.Freeze();
            var g = new MaterialGroup();
            g.Children.Add(new DiffuseMaterial(Brushes.Black));
            g.Children.Add(new EmissiveMaterial(b));
            g.Freeze();
            m = g;
            Cache[key] = m;
        }
        return m;
    }

    /// Unlit textured material (signs, posters, screens).
    public static Material Picture(ImageSource src, bool freeze = true)
    {
        var brush = new ImageBrush(src) { ViewportUnits = BrushMappingMode.Absolute, Viewport = new Rect(0, 0, 1, 1), Stretch = Stretch.Fill };
        var g = new MaterialGroup();
        g.Children.Add(new DiffuseMaterial(Brushes.Black));
        g.Children.Add(new EmissiveMaterial(brush));
        if (freeze) { brush.Freeze(); g.Freeze(); }
        return g;
    }

    /// Renders text to a bitmap for use on in-world signage.
    public static ImageSource Text(string text, int w, int h, Color fg, Color bg, double fontSize, Color? border = null, string? sub = null)
    {
        var panel = new Grid { Width = w, Height = h, Background = new SolidColorBrush(bg) };
        if (border is Color bc) panel.Children.Add(new Border { BorderBrush = new SolidColorBrush(bc), BorderThickness = new Thickness(h * 0.05), Margin = new Thickness(h * 0.04) });
        var stack = new StackPanel { VerticalAlignment = VerticalAlignment.Center, HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(new TextBlock { Text = text, FontSize = fontSize, FontWeight = FontWeights.Black, Foreground = new SolidColorBrush(fg), TextAlignment = TextAlignment.Center, FontFamily = new FontFamily("Segoe UI") });
        if (sub != null) stack.Children.Add(new TextBlock { Text = sub, FontSize = fontSize * 0.42, FontWeight = FontWeights.SemiBold, Foreground = Brushes.White, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = w - 40 });
        panel.Children.Add(stack);
        panel.Measure(new Size(w, h));
        panel.Arrange(new Rect(0, 0, w, h));
        var rtb = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(panel);
        rtb.Freeze();
        return rtb;
    }
}

public sealed record RoomTheme(Color Wall, Color Accent, Color Carpet, Color Seat, Color Light);

/// Accumulates triangles per material and emits frozen GeometryModel3Ds.
public sealed class MeshBuilder3D
{
    readonly Dictionary<Material, MeshGeometry3D> parts = new();
    public World.RoomXf Xf { get; set; } = new(0, 1, 0);

    MeshGeometry3D Mesh(Material m)
    {
        if (!parts.TryGetValue(m, out var mesh)) { mesh = new MeshGeometry3D(); parts[m] = mesh; }
        return mesh;
    }

    void AddWorldQuad(Point3D a, Point3D b, Point3D c, Point3D d, Vector3D n, Material m, Point ta, Point tb, Point tc, Point td)
    {
        var mesh = Mesh(m);
        int i = mesh.Positions.Count;
        mesh.Positions.Add(a); mesh.Positions.Add(b); mesh.Positions.Add(c); mesh.Positions.Add(d);
        for (int k = 0; k < 4; k++) mesh.Normals.Add(n);
        mesh.TextureCoordinates.Add(ta); mesh.TextureCoordinates.Add(tb); mesh.TextureCoordinates.Add(tc); mesh.TextureCoordinates.Add(td);
        mesh.TriangleIndices.Add(i); mesh.TriangleIndices.Add(i + 1); mesh.TriangleIndices.Add(i + 2);
        mesh.TriangleIndices.Add(i); mesh.TriangleIndices.Add(i + 2); mesh.TriangleIndices.Add(i + 3);
    }

    public void Quad(Point3D a, Point3D b, Point3D c, Point3D d, Vector3D n, Material m) =>
        AddWorldQuad(Xf.P(a.X, a.Y, a.Z), Xf.P(b.X, b.Y, b.Z), Xf.P(c.X, c.Y, c.Z), Xf.P(d.X, d.Y, d.Z), Xf.N(n.X, n.Y, n.Z), m,
            new Point(0, 1), new Point(1, 1), new Point(1, 0), new Point(0, 0));

    public void Box(double x0, double y0, double z0, double x1, double y1, double z1, Material m)
    {
        Quad(new(x0, y0, z1), new(x1, y0, z1), new(x1, y1, z1), new(x0, y1, z1), new(0, 0, 1), m);
        Quad(new(x1, y0, z0), new(x0, y0, z0), new(x0, y1, z0), new(x1, y1, z0), new(0, 0, -1), m);
        Quad(new(x1, y0, z1), new(x1, y0, z0), new(x1, y1, z0), new(x1, y1, z1), new(1, 0, 0), m);
        Quad(new(x0, y0, z0), new(x0, y0, z1), new(x0, y1, z1), new(x0, y1, z0), new(-1, 0, 0), m);
        Quad(new(x0, y1, z1), new(x1, y1, z1), new(x1, y1, z0), new(x0, y1, z0), new(0, 1, 0), m);
    }

    /// Upholstered look: three overlapping boxes, each inset on one axis.
    public void Cushion(double x0, double y0, double z0, double x1, double y1, double z1, double r, Material m)
    {
        r = Math.Min(r, Math.Min((x1 - x0) * 0.45, Math.Min((y1 - y0) * 0.45, (z1 - z0) * 0.45)));
        Box(x0 + r, y0, z0 + r, x1 - r, y1, z1 - r, m);
        Box(x0, y0 + r, z0 + r, x1, y1 - r, z1 - r, m);
        Box(x0 + r, y0 + r, z0, x1 - r, y1 - r, z1, m);
    }

    public void BoxC(double cx, double cy, double cz, double sx, double sy, double sz, Material m) =>
        Box(cx - sx / 2, cy - sy / 2, cz - sz / 2, cx + sx / 2, cy + sy / 2, cz + sz / 2, m);

    public void Floor(double x0, double x1, double z0, double z1, double y, bool up, Material m) =>
        Quad(new(x0, y, z0), new(x1, y, z0), new(x1, y, z1), new(x0, y, z1), new(0, up ? 1 : -1, 0), m);

    public void WallX(double x, double z0, double z1, double y0, double y1, Material m) =>
        Quad(new(x, y0, z0), new(x, y0, z1), new(x, y1, z1), new(x, y1, z0), new(1, 0, 0), m);

    public void WallZ(double z, double x0, double x1, double y0, double y1, Material m) =>
        Quad(new(x0, y0, z), new(x1, y0, z), new(x1, y1, z), new(x0, y1, z), new(0, 0, 1), m);

    /// Readable rectangle (never mirrored): built in world space from the transformed centre and normal.
    public void Sign(double cx, double cy, double cz, double nx, double ny, double nz, double w, double h, Material m)
    {
        var c = Xf.P(cx, cy, cz);
        var n = Xf.N(nx, ny, nz); n.Normalize();
        var up = new Vector3D(0, 1, 0);
        var right = Vector3D.CrossProduct(-n, up); right.Normalize();
        var hw = right * (w / 2); var hh = up * (h / 2); var off = n * 0.012;
        AddWorldQuad(c - hw - hh + off, c + hw - hh + off, c + hw + hh + off, c - hw + hh + off, n, m,
            new Point(0, 1), new Point(1, 1), new Point(1, 0), new Point(0, 0));
    }

    public Model3DGroup Build()
    {
        var g = new Model3DGroup();
        foreach (var (mat, mesh) in parts)
        {
            mesh.Freeze();
            var model = new GeometryModel3D(mesh, mat) { BackMaterial = mat };
            if (mat.IsFrozen) model.Freeze();   // dynamic textures (posters, screens) stay editable
            g.Children.Add(model);
        }
        return g;
    }
}

/// Procedural construction of the Windows cinema (original geometry only).
public static class WorldBuilder
{
    public static readonly Dictionary<int, RoomTheme> Themes = new()
    {
        [1] = new(Mats.C(.32, .06, .07), Mats.C(.85, .65, .25), Mats.C(.35, .04, .05), Mats.C(.55, .06, .08), Mats.C(1, .78, .45)),
        [2] = new(Mats.C(.12, .12, .13), Mats.C(1, .45, .08), Mats.C(.08, .08, .09), Mats.C(.15, .15, .16), Mats.C(1, .55, .2)),
        [3] = new(Mats.C(.22, .15, .08), Mats.C(.35, .55, .25), Mats.C(.18, .12, .06), Mats.C(.4, .25, .12), Mats.C(1, .8, .5)),
        [4] = new(Mats.C(.35, .12, .18), Mats.C(.95, .65, .6), Mats.C(.3, .08, .14), Mats.C(.6, .2, .3), Mats.C(1, .6, .65)),
        [5] = new(Mats.C(.08, .06, .06), Mats.C(.6, .05, .05), Mats.C(.12, .02, .02), Mats.C(.18, .04, .04), Mats.C(1, .35, .2)),
        [6] = new(Mats.C(.1, .18, .35), Mats.C(1, .85, .2), Mats.C(.08, .1, .25), Mats.C(.85, .2, .2), Mats.C(1, .9, .6)),
        [7] = new(Mats.C(.06, .08, .2), Mats.C(.9, .12, .15), Mats.C(.05, .05, .15), Mats.C(.12, .15, .4), Mats.C(.35, .55, 1)),
        [8] = new(Mats.C(.15, .08, .25), Mats.C(.3, .95, .65), Mats.C(.1, .05, .18), Mats.C(.3, .12, .45), Mats.C(.7, .5, 1)),
        [9] = new(Mats.C(.04, .07, .1), Mats.C(.1, .9, 1), Mats.C(.03, .05, .08), Mats.C(.15, .2, .25), Mats.C(.4, .9, 1)),
        [10] = new(Mats.C(.35, .25, .45), Mats.C(1, .6, .2), Mats.C(.2, .3, .5), Mats.C(.2, .6, .9), Mats.C(1, .95, .85)),
        [11] = new(Mats.C(.05, .12, .12), Mats.C(.8, .7, .4), Mats.C(.04, .08, .08), Mats.C(.1, .22, .22), Mats.C(.9, .85, .6)),
        [12] = new(Mats.C(.2, .03, .04), Mats.C(1, .82, .35), Mats.C(.45, .03, .05), Mats.C(.12, .1, .1), Mats.C(1, .88, .6)),
    };

    public static Model3DGroup LobbyAndHall(Func<string, Material> tex)
    {
        var b = new MeshBuilder3D();
        var wall = Mats.Lit(Mats.C(.32, .2, .24));
        var gold = Mats.Glow(Mats.C(.95, .72, .3));
        b.Floor(-16, 16, 0, 20, 0, true, Mats.Lit(Mats.C(.32, .27, .3)));
        b.Floor(-2.5, 2.5, 0, 20, 0.01, true, Mats.Lit(Mats.C(.6, .06, .08)));
        b.Floor(-16, 16, 0, 20, World.LobbyCeiling, false, Mats.Lit(Mats.C(.12, .09, .12)));
        b.WallX(-16, 0, 20, 0, 9, wall); b.WallX(16, 0, 20, 0, 9, wall);
        b.WallZ(0, -16, -4, 0, 9, wall); b.WallZ(0, 4, 16, 0, 9, wall); b.WallZ(0, -4, 4, 4, 9, wall);
        b.Sign(0, 2, 0.02, 0, 0, 1, 8, 4, Mats.Glow(Mats.C(.25, .35, .6)));
        b.WallZ(20, -16, -4, 0, 9, wall); b.WallZ(20, 4, 16, 0, 9, wall); b.WallZ(20, -4, 4, World.HallCeiling, 9, wall);
        b.Box(-16, 7.6, 0, 16, 7.75, 0.1, gold); b.Box(-16, 7.6, 19.9, 16, 7.75, 20, gold);
        foreach (var x in new[] { -10.0, 0, 10 }) foreach (var z in new[] { 5.0, 14 }) b.BoxC(x, 8.95, z, 3, 0.08, 1.2, Mats.Glow(Mats.C(1, .9, .75)));
        foreach (var x in new[] { -8.0, 8 })
        {
            b.Box(x - .45, 0, 2.55, x + .45, 9, 3.45, Mats.Lit(Mats.C(.3, .18, .15)));
            b.Box(x - .5, 0, 2.5, x + .5, .3, 3.5, gold);
        }
        b.Sign(0, 6.4, 19.94, 0, 0, -1, 11, 2.4, tex("sign.marquee"));
        b.Sign(0, 3.9, 19.9, 0, 0, -1, 6, 0.7, tex("sign.hall"));
        for (int k = 0; k < 6; k++)
        {
            b.Sign(-14.2 + k * 1.75, 2.6, 19.9, 0, 0, -1, 1.4, 2.1, tex($"poster.{k + 1}"));
            b.Sign(5.45 + k * 1.75, 2.6, 19.9, 0, 0, -1, 1.4, 2.1, tex($"poster.{k + 7}"));
        }
        // Box office
        b.Box(-14.5, 0, 8.6, -7.5, 1.15, 10.4, Mats.Lit(Mats.C(.45, .1, .12)));
        b.Box(-14.6, 1.15, 8.5, -7.4, 1.22, 10.5, gold);
        b.Sign(-11, 4.4, 8.4, 0, 0, -1, 5.5, 1, tex("sign.boxoffice"));
        // Concessions with popcorn, soda, slushie and candy machines
        b.Box(7.5, 0, 8.6, 14.5, 1.15, 10.4, Mats.Lit(Mats.C(.3, .2, .12)));
        b.Box(7.4, 1.15, 8.5, 14.6, 1.22, 10.5, gold);
        b.Sign(11, 6.1, 8.4, 0, 0, -1, 5.5, 1, tex("sign.concessions"));
        b.Sign(11, 4.6, 11.9, 0, 0, -1, 6.5, 2.2, tex("sign.menu"));
        b.Box(8, 1.22, 9, 9.2, 2.6, 10, Mats.Glow(Mats.C(1, .82, .35)));
        b.Box(9.8, 1.22, 9.2, 11, 2.2, 10, Mats.Lit(Mats.C(.7, .7, .75)));
        b.Box(11.6, 1.22, 9.2, 12.6, 2.3, 10, Mats.Glow(Mats.C(.3, .2, 1)));
        b.Box(13, 1.22, 9, 14.3, 1.9, 10, Mats.Glow(Mats.C(1, .4, .8)));
        b.Box(7.5, 0, 12, 14.5, 3.3, 12.2, Mats.Lit(Mats.C(.2, .12, .08)));
        // 4DX teaser and ticket kiosks
        b.Box(-15.98, 1.8, 13.8, -15.9, 4.6, 19.4, Mats.Glow(Mats.C(.3, .9, 1)));
        b.Sign(-15.84, 3.2, 16.6, 1, 0, 0, 5, 2.4, tex("sign.4dx"));
        foreach (var x in new[] { -6.0, 6 })
        {
            b.Box(x - .4, 0, 13.6, x + .4, 1.7, 14.4, Mats.Lit(Mats.C(.15, .15, .18)));
            b.Sign(x, 1.3, 13.58, 0, 0, -1, .6, .45, tex("sign.kiosk"));
        }
        Hall(b, tex);
        return b.Build();
    }

    static void Hall(MeshBuilder3D b, Func<string, Material> tex)
    {
        var wall = Mats.Lit(Mats.C(.26, .18, .24));
        double z0 = World.HallZ0, z1 = World.HallZ1, hw = World.HallHalf, H = World.HallCeiling;
        b.Floor(-hw, hw, z0, z1, 0, true, Mats.Lit(Mats.C(.4, .08, .16)));
        b.Floor(-hw, hw, z0, z1, H, false, Mats.Lit(Mats.C(.1, .07, .1)));
        b.WallZ(z1, -hw, hw, 0, H, wall);
        foreach (var side in new[] { -1.0, 1 })
        {
            var x = side * hw;
            var cursor = z0;
            for (int i = 0; i < 6; i++)
            {
                int id = side < 0 ? i + 1 : i + 7;
                var bz = World.RoomBaseZ(id);
                double d0 = bz + World.DoorZ0, d1 = bz + World.DoorZ1;
                b.WallX(x, cursor, d0, 0, H, wall);
                b.WallX(x, d0, d1, World.DoorHeight, H, wall);
                cursor = d1;
                var accent = Mats.Glow(Themes[id].Accent);
                b.Box(x - .12, 0, d0 - .15, x + .12, World.DoorHeight + .15, d0, accent);
                b.Box(x - .12, 0, d1, x + .12, World.DoorHeight + .15, d1 + .15, accent);
                b.Box(x - .12, World.DoorHeight, d0 - .15, x + .12, World.DoorHeight + .15, d1 + .15, accent);
                var inner = side * (hw + .25);
                b.Box(Math.Min(x, inner), 0, d0 - .05, Math.Max(x, inner), World.DoorHeight, d0, wall);
                b.Box(Math.Min(x, inner), 0, d1, Math.Max(x, inner), World.DoorHeight, d1 + .05, wall);
                b.Sign(x - side * .03, 3.5, (d0 + d1) / 2, -side, 0, 0, 2.8, .95, tex($"door.{id}"));
                b.Sign(x - side * .03, 1.6, bz + 3.4, -side, 0, 0, 1.3, 1.95, tex($"poster.{id}"));
            }
            b.WallX(x, cursor, z1, 0, H, wall);
        }
        for (var z = z0 + 4; z < z1; z += 9) b.BoxC(0, H - .04, z, 2.2, .06, .8, Mats.Glow(Mats.C(1, .88, .7)));
        b.Box(-hw + .05, .02, z0, -hw + .12, .06, z1, Mats.Glow(Mats.C(1, .6, .2)));
        b.Box(hw - .12, .02, z0, hw - .05, .06, z1, Mats.Glow(Mats.C(1, .6, .2)));
    }

    public static Model3DGroup Room(int id)
    {
        var t = Themes[id];
        var b = new MeshBuilder3D { Xf = World.Xf(id) };
        double D = World.RoomDepth, W = World.RoomWidth, yMin = World.RoomFloorMin, yMax = World.RoomCeiling;
        var wall = Mats.Lit(Mats.Scale(t.Wall, 1.4));
        var carpet = Mats.Lit(Mats.Scale(t.Carpet, 1.3));
        b.Floor(0, 7.2, 0, W, yMin, true, carpet);
        double prev = yMin;
        for (int r = 0; r < 8; r++)
        {
            double x0 = 7.2 + r * 1.6, h = World.RowFloor(r);
            b.Floor(x0, x0 + 1.6, 0, W, h, true, carpet);
            b.WallX(x0, 0, W, prev, h, Mats.Lit(Mats.Scale(t.Carpet, .9)));
            b.Box(x0 - .02, h - .06, .3, x0 + .02, h - .02, 1.6, Mats.Glow(t.Light));
            b.Box(x0 - .02, h - .06, W - 1.6, x0 + .02, h - .02, W - .3, Mats.Glow(t.Light));
            prev = h;
        }
        b.Floor(20, D, 0, W, 0, true, carpet);
        b.WallZ(0, 0, D, yMin, yMax, wall);
        b.WallZ(W, 0, D, yMin, yMax, wall);
        b.WallX(0, 0, W, yMin, yMax, Mats.Lit(Mats.C(.03, .03, .03)));
        b.WallX(D, 0, World.DoorZ0, 0, yMax, wall);
        b.WallX(D, World.DoorZ1, W, 0, yMax, wall);
        b.WallX(D, World.DoorZ0, World.DoorZ1, World.DoorHeight, yMax, wall);
        b.Floor(0, D, 0, W, yMax, false, Mats.Lit(Mats.Scale(t.Wall, .7)));
        b.Box(0, yMin, 0, 1.2, yMin + .5, W, Mats.Lit(Mats.C(.06, .06, .06)));
        b.Box(.05, -1.75, .6, .3, 4.15, W - .6, Mats.Lit(Mats.C(.01, .01, .01)));
        b.Box(.3, yMin, .1, .8, 5, .95, Mats.Lit(Mats.Scale(t.Accent, .45)));
        b.Box(.3, yMin, W - .95, .8, 5, W - .1, Mats.Lit(Mats.Scale(t.Accent, .45)));
        for (int k = 0; k < 4; k++)
        {
            double lx = 6 + k * 5.5, y = World.LocalGround(lx) + 3.2;
            b.BoxC(lx, y, .12, .5, .7, .2, Mats.Glow(t.Light));
            b.BoxC(lx, y, W - .12, .5, .7, .2, Mats.Glow(t.Light));
        }
        b.Box(1, 1.0, .02, D - 1, 1.1, .08, Mats.Glow(t.Accent));
        b.Box(1, 1.0, W - .08, D - 1, 1.1, W - .02, Mats.Glow(t.Accent));
        b.BoxC(D - .1, 2.95, 7, .1, .3, .9, Mats.Glow(Mats.C(.1, 1, .3)));
        b.BoxC(D - .06, 5.4, 7, .12, .22, .22, Mats.Glow(Mats.C(.9, .95, 1)));
        var frame = Mats.Lit(Mats.C(.08, .08, .09));
        for (int r = 0; r < 8; r++)
        {
            double x = World.RowX(r), fl = World.RowFloor(r);
            bool vip = r is 4 or 5;
            var seat = Mats.Lit(Mats.Scale(t.Seat, vip ? 1.6 : 1.25));
            var shade = Mats.Lit(Mats.Scale(t.Seat, vip ? 1.3 : 1.0));
            var pad = Mats.Lit(Mats.C(.1, .09, .09));
            var chrome = Mats.Lit(Mats.C(.7, .72, .76));
            var jet = Mats.Glow(Mats.C(.55, .85, 1));
            var platform = Mats.Lit(Mats.C(.13, .17, .2));
            for (int s = 0; s < 8; s++)
            {
                // Premium 4DX recliner; local +x points away from the screen.
                // The backrest front stays at x + 0.30 so the seated eye
                // (x + 0.18…0.20) is never inside the upholstery.
                double z = World.SeatZ(s);
                b.Box(x - .4, fl, z - .4, x + .35, fl + .3, z + .4, frame);
                b.Box(x - .32, fl + .06, z - .3, x + .22, fl + .14, z + .3, platform);
                b.Cushion(x - .36, fl + .3, z - .36, x + .32, fl + .5, z + .36, .06, seat);
                b.Cushion(x - .44, fl + .26, z - .35, x - .3, fl + .48, z + .35, .06, shade);
                b.Cushion(x - .47, fl + .06, z - .33, x - .41, fl + .3, z + .33, .025, shade);
                b.Cushion(x + .3, fl + .42, z - .4, x + .56, fl + 1.16, z + .4, .07, seat);
                b.Cushion(x + .26, fl + .5, z - .3, x + .36, fl + .68, z + .3, .05, shade);
                for (int k = 0; k < 2; k++) b.Cushion(x + .29, fl + .7 + k * .22, z - .29, x + .34, fl + .9 + k * .22, z + .29, .03, seat);
                foreach (var side in new[] { -1.0, 1.0 })
                    b.Cushion(x + .24, fl + .6, z + side * .42 - .06, x + .52, fl + 1.1, z + side * .42 + .06, .04, shade);
                b.Cushion(x + .3, fl + 1.02, z - .26, x + .5, fl + 1.26, z + .26, .06, shade);
                b.Box(x + .56, fl + .36, z - .42, x + .6, fl + 1.2, z + .42, frame);
                b.BoxC(x + .605, fl + .94, z - .12, .012, .035, .035, jet);
                b.BoxC(x + .605, fl + .94, z + .12, .012, .035, .035, jet);
                b.Box(x - .35, fl + .3, z - .52, x + .45, fl + .7, z - .42, frame);
                b.Cushion(x - .38, fl + .7, z - .535, x + .46, fl + .78, z - .405, .03, pad);
                b.Box(x - .4, fl + .66, z - .54, x + .47, fl + .675, z - .4, chrome);
                b.BoxC(x - .22, fl + .785, z - .47, .1, .012, .1, Mats.Glow(t.Accent));
            }
        }
        return b.Build();
    }

    /// Flat movie screen quad for a room (texture u runs left→right as seen from the seats).
    public static MeshGeometry3D ScreenMesh(int id)
    {
        var b = new MeshBuilder3D { Xf = World.Xf(id) };
        var m = Mats.Lit(Colors.White);
        b.Sign(.36, 1.2, 7, 1, 0, 0, World.ScreenW, World.ScreenH, m);
        var g = b.Build();
        return (MeshGeometry3D)((GeometryModel3D)g.Children[0]).Geometry;
    }

    public static MeshGeometry3D UnitBox()
    {
        var b = new MeshBuilder3D();
        b.BoxC(0, 0, 0, 1, 1, 1, Mats.Lit(Colors.White));
        var g = b.Build();
        return (MeshGeometry3D)((GeometryModel3D)g.Children[0]).Geometry;
    }
}

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Shapes;

namespace ZMFTheaters.Cinema;

/// 4DX screen layer drawn over your view while seated: water droplets that
/// bead and drain, a fine mist haze, wind streaks and a bounded flash. These
/// are virtual visual effects only (no physical water/air hardware).
public sealed class ScreenFx
{
    public Canvas Layer { get; } = new() { IsHitTestVisible = false };
    readonly List<(Ellipse drop, Ellipse glint)> drops = new();
    readonly List<Line> streaks = new();
    readonly Rectangle haze = new() { Fill = Brushes.White, Opacity = 0 };
    readonly Rectangle flash = new() { Fill = Brushes.White, Opacity = 0 };
    // Event effects: shockwave ring, embers, flying debris, smoke, hit vignette.
    readonly Ellipse shockRing = new() { Stroke = new SolidColorBrush(Color.FromArgb(200, 255, 190, 120)), StrokeThickness = 18, Opacity = 0 };
    readonly List<Ellipse> embers = new();
    readonly List<Rectangle> debris = new();
    readonly Rectangle smoke = new() { Opacity = 0, Fill = new LinearGradientBrush(Color.FromArgb(0, 40, 38, 36), Color.FromArgb(220, 40, 38, 36), 90) };
    readonly Rectangle vignette = new() { Opacity = 0, Fill = new RadialGradientBrush(Color.FromArgb(0, 0, 0, 0), Color.FromArgb(230, 10, 0, 0)) };
    double shockAge = 10;
    public double Shock { get; private set; }
    public double Water { get; private set; }
    public double Wind { get; private set; }
    public double Flash { get; private set; }

    static double Hash(double n) { var v = Math.Sin(n * 12.9898) * 43758.5453; return v - Math.Floor(v); }

    public ScreenFx()
    {
        Layer.Children.Add(haze);
        var dropBrush = new RadialGradientBrush(new GradientStopCollection
        {
            new(Color.FromArgb(10, 255, 255, 255), 0), new(Color.FromArgb(60, 220, 235, 255), 0.75), new(Color.FromArgb(90, 0, 10, 20), 1),
        });
        dropBrush.Freeze();
        for (int i = 0; i < 70; i++)
        {
            var d = new Ellipse { Fill = dropBrush, Opacity = 0 };
            var g = new Ellipse { Fill = Brushes.White, Opacity = 0 };
            drops.Add((d, g));
            Layer.Children.Add(d);
            Layer.Children.Add(g);
        }
        for (int i = 0; i < 26; i++)
        {
            var l = new Line { Stroke = Brushes.White, StrokeThickness = 1.2, Opacity = 0 };
            streaks.Add(l);
            Layer.Children.Add(l);
        }
        Layer.Children.Add(smoke);
        shockRing.Effect = new System.Windows.Media.Effects.BlurEffect { Radius = 14 };
        Layer.Children.Add(shockRing);
        var emberBrush = new RadialGradientBrush(Color.FromArgb(255, 255, 200, 120), Color.FromArgb(0, 255, 90, 20)); emberBrush.Freeze();
        for (int i = 0; i < 40; i++) { var e = new Ellipse { Fill = emberBrush, Opacity = 0 }; embers.Add(e); Layer.Children.Add(e); }
        for (int i = 0; i < 24; i++)
        {
            var d = new Rectangle { Fill = i % 4 == 0 ? new SolidColorBrush(Color.FromRgb(255, 150, 60)) : new SolidColorBrush(Color.FromRgb(20, 16, 12)), Opacity = 0, RenderTransformOrigin = new Point(0.5, 0.5) };
            debris.Add(d); Layer.Children.Add(d);
        }
        Layer.Children.Add(vignette);
        Layer.Children.Add(flash);
    }

    /// Event-driven layer from the real-time detector (all 0–1).
    public void UpdateEvents(double dt, double time, double shock, double emberLevel, double smokeLevel, double debrisLevel, double hit, double width, double height)
    {
        double w = Math.Max(1, width), h = Math.Max(1, height);
        if (shock > Shock + 0.2) shockAge = 0;
        Shock = shock; shockAge += dt;
        var rad = shockAge * Math.Max(w, h) * 0.9;
        shockRing.Width = shockRing.Height = Math.Max(1, rad * 2);
        Canvas.SetLeft(shockRing, w / 2 - rad); Canvas.SetTop(shockRing, h / 2 - rad);
        shockRing.Opacity = shockAge < 1.2 ? Math.Clamp(shock, 0, 1) * (1 - shockAge / 1.2) : 0;
        smoke.Width = w; smoke.Height = h; smoke.Opacity = Math.Clamp(smokeLevel, 0, 1) * 0.45;
        vignette.Width = w; vignette.Height = h; vignette.Opacity = Math.Clamp(hit, 0, 1) * 0.6;
        int n = (int)(Math.Clamp(emberLevel, 0, 1) * embers.Count);
        for (int i = 0; i < embers.Count; i++)
        {
            var e = embers[i];
            if (i >= n) { e.Opacity = 0; continue; }
            double seed = i * 5.17 + 300, life = (time * (0.12 + Hash(seed) * 0.2) + Hash(seed + 1)) % 1;
            double x = Hash(seed + 2) * w + Math.Sin(time * 2 + seed) * 18, y = h * (1 - life);
            double r = 2 + Hash(seed + 3) * 4;
            e.Width = e.Height = r * 2; Canvas.SetLeft(e, x - r); Canvas.SetTop(e, y - r);
            e.Opacity = Math.Min(1, life * 6) * (1 - life) * (0.6 + 0.4 * Math.Sin(time * 9 + seed));
        }
        int m = (int)(Math.Clamp(debrisLevel, 0, 1) * debris.Count);
        for (int i = 0; i < debris.Count; i++)
        {
            var d = debris[i];
            if (i >= m) { d.Opacity = 0; continue; }
            double seed = i * 9.31 + 500, life = (time * (0.9 + Hash(seed) * 1.2) + Hash(seed + 1)) % 1;
            double ang = Hash(seed + 2) * Math.PI * 2, dist = life * Math.Max(w, h) * 0.7;
            double sz = 4 + Hash(seed + 3) * 12;
            d.Width = sz; d.Height = sz * (0.4 + Hash(seed + 4));
            Canvas.SetLeft(d, w / 2 + Math.Cos(ang) * dist - sz / 2); Canvas.SetTop(d, h / 2 + Math.Sin(ang) * dist - sz / 2);
            d.RenderTransform = new RotateTransform(time * 400 * (Hash(seed + 5) - 0.5) + seed);
            d.Opacity = (1 - life) * 0.9;
        }
    }

    /// Targets are 0–1. Water rises fast and drains slowly; flash ≤ 0.35.
    public void Update(double dt, double time, double water, double wind, double flashTarget, double width, double height)
    {
        water = Math.Clamp(double.IsFinite(water) ? water : 0, 0, 1);
        wind = Math.Clamp(double.IsFinite(wind) ? wind : 0, 0, 1);
        flashTarget = Math.Clamp(double.IsFinite(flashTarget) ? flashTarget : 0, 0, 0.35);
        Water += (water - Water) * (1 - Math.Exp(-dt * (water > Water ? 9 : 0.45)));
        Wind += (wind - Wind) * (1 - Math.Exp(-dt * 4));
        Flash += (flashTarget - Flash) * (1 - Math.Exp(-dt * (flashTarget > Flash ? 30 : 8)));
        double w = Math.Max(1, width), h = Math.Max(1, height);
        haze.Width = w; haze.Height = h; flash.Width = w; flash.Height = h;
        haze.Opacity = Math.Min(0.18, Water * 0.12);
        flash.Opacity = Flash;
        int count = (int)(Water * drops.Count);
        for (int i = 0; i < drops.Count; i++)
        {
            var (d, g) = drops[i];
            if (i >= count) { d.Opacity = g.Opacity = 0; continue; }
            double seed = i * 7.31, life = (time * (0.08 + Hash(seed + 3) * 0.16) + Hash(seed)) % 1;
            double fade = Math.Min(1, life / 0.05) * Math.Min(1, (1 - life) / 0.4);
            double r = (3 + Hash(seed + 1) * 9) * (w / 900 + 0.4);
            double x = Hash(seed + 2) * w, y = Hash(seed + 5) * h + life * h * 0.18 * Hash(seed + 9);
            d.Width = r * 2; d.Height = r * 2.3; Canvas.SetLeft(d, x - r); Canvas.SetTop(d, y - r * 1.15); d.Opacity = fade;
            g.Width = r * 0.4; g.Height = r * 0.32; Canvas.SetLeft(g, x - r * 0.45); Canvas.SetTop(g, y - r * 0.7); g.Opacity = 0.7 * fade;
        }
        int lines = (int)(Wind * streaks.Count);
        for (int i = 0; i < streaks.Count; i++)
        {
            var l = streaks[i];
            double seed = i * 3.7 + 100, y = Hash(seed) * h;
            bool edge = Math.Abs(y / h - 0.5) > 0.22 || Hash(seed + 6) > 0.7;
            if (i >= lines || !edge) { l.Opacity = 0; continue; }
            double len = (0.08 + Hash(seed + 1) * 0.18) * w;
            double x = ((time * (0.9 + Hash(seed + 2) * 1.6) + Hash(seed + 3)) % 1) * (w + len) - len;
            l.X1 = x; l.Y1 = y; l.X2 = x + len; l.Y2 = y + len * 0.02; l.Opacity = Wind * 0.25;
        }
    }

    public void Clear() { Water = Wind = Flash = 0; Update(0, 0, 0, 0, 0, Layer.ActualWidth, Layer.ActualHeight); UpdateEvents(0, 0, 0, 0, 0, 0, 0, Layer.ActualWidth, Layer.ActualHeight); }
}

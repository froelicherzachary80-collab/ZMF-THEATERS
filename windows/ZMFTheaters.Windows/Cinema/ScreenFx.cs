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
        Layer.Children.Add(flash);
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

    public void Clear() { Water = Wind = Flash = 0; Update(0, 0, 0, 0, 0, Layer.ActualWidth, Layer.ActualHeight); }
}

using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Animation;

namespace ZMFTheaters.Home;

/// Small styling kit so the Home 4DX centre matches the cinema's dark gold look.
static class Ui
{
    public static readonly SolidColorBrush Bg = Brush(0x0B, 0x07, 0x09), Panel = Brush(0x17, 0x0F, 0x12), Line = Brush(0x3A, 0x2A, 0x20),
        Gold = Brush(0xFF, 0xC8, 0x4B), Cyan = Brush(0x4D, 0xD0, 0xE1), Text = Brush(0xF3, 0xEC, 0xE6), Dim = Brush(0xA9, 0x9B, 0x90),
        Green = Brush(0x7E, 0xE7, 0x87), Amber = Brush(0xFF, 0xB7, 0x4D), Red = Brush(0xFF, 0x6B, 0x60), Danger = Brush(0xD3, 0x2F, 0x2F);

    static SolidColorBrush Brush(byte r, byte g, byte b) { var x = new SolidColorBrush(Color.FromRgb(r, g, b)); x.Freeze(); return x; }

    public static Brush For(DeviceState s) => s switch
    {
        DeviceState.ConnectedTested => Green,
        DeviceState.ConnectedUnverified => Amber,
        DeviceState.Simulated => Cyan,
        _ => Red,
    };

    public static TextBlock H(string text, double size = 20) => new() { Text = text, FontSize = size, FontWeight = FontWeights.Black, Foreground = Gold, Margin = new Thickness(0, 4, 0, 8) };
    public static TextBlock Sub(string text) => new() { Text = text.ToUpperInvariant(), FontSize = 11, FontWeight = FontWeights.Bold, Foreground = Dim, Margin = new Thickness(0, 12, 0, 4) };
    public static TextBlock P(string text, Brush? color = null, double size = 13) => new() { Text = text, Foreground = color ?? Text, FontSize = size, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 4) };

    public static Button Btn(string text, RoutedEventHandler click, bool primary = false, bool danger = false)
    {
        var b = new Button
        {
            Content = text, Padding = new Thickness(14, 7, 14, 7), Margin = new Thickness(0, 4, 8, 4), FontWeight = FontWeights.SemiBold,
            Background = danger ? Danger : primary ? Gold : Brush(0x2A, 0x1C, 0x21), Foreground = primary ? Brush(0x1A, 0x10, 0x00) : Text,
            BorderBrush = Line, Cursor = System.Windows.Input.Cursors.Hand,
        };
        b.Click += click;
        return b;
    }

    public static Border Card(params UIElement[] children)
    {
        var sp = new StackPanel();
        foreach (var c in children) sp.Children.Add(c);
        return new Border { Child = sp, Background = Panel, BorderBrush = Line, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(12), Padding = new Thickness(14), Margin = new Thickness(0, 6, 0, 6) };
    }

    public static Border Chip(string text, Brush color) => new()
    {
        Child = new TextBlock { Text = text, Foreground = color, FontSize = 11, FontWeight = FontWeights.Bold },
        BorderBrush = color, BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(10), Padding = new Thickness(8, 2, 8, 2), Margin = new Thickness(0, 0, 6, 0),
        VerticalAlignment = VerticalAlignment.Center,
    };

    public static StackPanel Row(params UIElement[] children)
    {
        var sp = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 2, 0, 2) };
        foreach (var c in children) sp.Children.Add(c);
        return sp;
    }

    public static TextBox Input(string text = "", double width = 260) => new() { Text = text, Width = width, Margin = new Thickness(0, 2, 8, 2), Padding = new Thickness(6, 4, 6, 4), Background = Brush(0x22, 0x17, 0x1B), Foreground = Text, BorderBrush = Line, CaretBrush = Text };

    public static CheckBox Check(string text, bool value, Action<bool> changed)
    {
        var c = new CheckBox { Content = text, IsChecked = value, Foreground = Text, Margin = new Thickness(0, 4, 0, 4) };
        c.Click += (_, _) => changed(c.IsChecked == true);
        return c;
    }

    public static void FadeIn(UIElement e)
    {
        e.Opacity = 0;
        e.BeginAnimation(UIElement.OpacityProperty, new DoubleAnimation(0, 1, TimeSpan.FromMilliseconds(220)));
    }

    /// Modal yes/no in the app's style.
    public static bool Ask(Window owner, string title, string text) =>
        MessageBox.Show(owner, text, title, MessageBoxButton.YesNo, MessageBoxImage.Question) == MessageBoxResult.Yes;

    public static void Tell(Window owner, string title, string text) =>
        MessageBox.Show(owner, text, title, MessageBoxButton.OK, MessageBoxImage.Information);
}

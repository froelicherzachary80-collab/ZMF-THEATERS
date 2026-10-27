using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Threading;

namespace ZMFTheaters.Home;

/// ADMIN → IMMERSIVE HOME 4DX. Native control centre for real devices,
/// automatic effects, private rooms, the phone companion, the hardware
/// testing laboratory, safety and diagnostics.
public sealed class HomeControlWindow : Window
{
    readonly HomeHub hub;
    readonly Action save;
    readonly ContentControl content = new();
    readonly StackPanel nav = new() { Margin = new Thickness(10) };
    readonly TextBlock statusLine = new() { Foreground = Ui.Dim, FontSize = 12, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis };
    readonly StackPanel chips = new() { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
    readonly DispatcherTimer timer = new() { Interval = TimeSpan.FromMilliseconds(500) };
    Action? refresh;
    string section = "Dashboard";
    readonly CancellationTokenSource life = new();
    List<TapoDiscovered> discovered = new();
    List<GoveeSeen> strips = new();

    static readonly string[] Sections =
    {
        "Dashboard", "Smart Device Discovery", "Automatic AI Effects", "Physical Effect Configuration", "Virtual Cinema Effects",
        "Lighting and Color Control", "Wind Controller", "Private Cinema Rooms", "PC + iPhone Companion", "Testing Laboratory",
        "Safety and Emergency Stop", "Diagnostics",
    };

    public HomeControlWindow(HomeHub hub, Action save, string? startSection = null)
    {
        this.hub = hub; this.save = save;
        Title = "ZMF THEATERS+ · Immersive Home 4DX";
        Width = 1240; Height = 800; MinWidth = 980; MinHeight = 620;
        Background = Ui.Bg; Foreground = Ui.Text;
        WindowStartupLocation = WindowStartupLocation.CenterScreen;

        var root = new Grid();
        root.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(250) });
        root.ColumnDefinitions.Add(new ColumnDefinition());
        root.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        root.RowDefinitions.Add(new RowDefinition());

        // Header with the always-visible emergency stop.
        var header = new DockPanel { Margin = new Thickness(16, 12, 16, 8) };
        var estop = Ui.Btn("■  EMERGENCY STOP", async (_, _) => await hub.EmergencyStopAsync("Home 4DX window"), danger: true);
        estop.FontSize = 15; estop.Padding = new Thickness(18, 10, 18, 10);
        DockPanel.SetDock(estop, Dock.Right);
        header.Children.Add(estop);
        var titleStack = new StackPanel();
        titleStack.Children.Add(new TextBlock { Text = "IMMERSIVE HOME 4DX", FontSize = 24, FontWeight = FontWeights.Black, Foreground = Ui.Gold });
        titleStack.Children.Add(Ui.Row(chips, statusLine));
        header.Children.Add(titleStack);
        Grid.SetColumnSpan(header, 2);
        root.Children.Add(header);

        var navScroll = new ScrollViewer { Content = nav, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Background = Ui.Panel };
        Grid.SetRow(navScroll, 1);
        root.Children.Add(navScroll);
        foreach (var s in Sections)
        {
            var b = new Button
            {
                Content = s, Tag = s, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(12, 9, 12, 9), Margin = new Thickness(0, 2, 0, 2),
                Background = Brushes.Transparent, Foreground = Ui.Text, BorderThickness = new Thickness(0), FontSize = 14, Cursor = System.Windows.Input.Cursors.Hand,
            };
            b.Click += (_, _) => Show(s);
            nav.Children.Add(b);
        }
        var scroll = new ScrollViewer { Content = content, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Padding = new Thickness(22, 8, 22, 24) };
        Grid.SetRow(scroll, 1); Grid.SetColumn(scroll, 1);
        root.Children.Add(scroll);
        Content = root;

        timer.Tick += (_, _) => { UpdateHeader(); refresh?.Invoke(); };
        timer.Start();
        Closed += (_, _) => { timer.Stop(); life.Cancel(); save(); };
        Show(startSection ?? "Dashboard");
    }

    void UpdateHeader()
    {
        chips.Children.Clear();
        var c = hub.Config;
        if (hub.Devices.EmergencyStopped) chips.Children.Add(Ui.Chip("EMERGENCY STOP ACTIVE", Ui.Red));
        chips.Children.Add(c.VirtualOnly ? Ui.Chip("VIRTUAL ONLY", Ui.Cyan) : c.PhysicalEnabled ? Ui.Chip("PHYSICAL EFFECTS ARMED", Ui.Green) : Ui.Chip("PHYSICAL EFFECTS OFF", Ui.Amber));
        if (hub.Devices.SimulationMode) chips.Children.Add(Ui.Chip("SIMULATION", Ui.Cyan));
        chips.Children.Add(hub.Host?.Running == true ? Ui.Chip($"HOST :{hub.Host.Port}", Ui.Green) : Ui.Chip("HOST OFF", Ui.Dim));
        var p = hub.PcPlayback is { Playing: true } pc ? pc : hub.PhonePlayback ?? hub.PcPlayback;
        statusLine.Text = $"  {hub.Director.State} · {(p == null ? "nothing playing" : $"{p.Title} {(p.Playing ? "▶" : "⏸")} {TimeSpan.FromSeconds(p.Position):h\\:mm\\:ss} ({p.Source})")}";
    }

    void Show(string s)
    {
        section = s;
        foreach (Button b in nav.Children) b.Background = (string)b.Tag == s ? new SolidColorBrush(Color.FromRgb(0x33, 0x22, 0x18)) : Brushes.Transparent;
        refresh = null;
        var panel = new StackPanel();
        switch (s)
        {
            case "Dashboard": Dashboard(panel); break;
            case "Smart Device Discovery": Discovery(panel); break;
            case "Automatic AI Effects": Automatic(panel); break;
            case "Physical Effect Configuration": PhysicalConfig(panel); break;
            case "Virtual Cinema Effects": Virtual(panel); break;
            case "Lighting and Color Control": Lighting(panel); break;
            case "Wind Controller": Wind(panel); break;
            case "Private Cinema Rooms": RoomsSection(panel); break;
            case "PC + iPhone Companion": Companion(panel); break;
            case "Testing Laboratory": Lab(panel); break;
            case "Safety and Emergency Stop": Safety(panel); break;
            default: Diagnostics(panel); break;
        }
        content.Content = panel;
        Ui.FadeIn(panel);
        UpdateHeader();
    }

    // MARK: 1 Dashboard

    void Dashboard(StackPanel p)
    {
        p.Children.Add(Ui.H("Home 4DX Dashboard"));
        var devices = new WrapPanel();
        var director = new StackPanel();
        var last = new StackPanel();
        p.Children.Add(Ui.Sub("Devices"));
        p.Children.Add(devices);
        p.Children.Add(Ui.Sub("AI scene director"));
        p.Children.Add(Ui.Card(director));
        p.Children.Add(Ui.Sub("Last commands (actual command → device acknowledgement)"));
        p.Children.Add(Ui.Card(last));
        refresh = () =>
        {
            devices.Children.Clear();
            foreach (var d in hub.Devices.Devices.Values)
            {
                var card = Ui.Card(
                    Ui.Row(new TextBlock { Text = d.Name, FontWeight = FontWeights.Bold, FontSize = 15, Foreground = Ui.Text, Margin = new Thickness(0, 0, 10, 0) }, Ui.Chip(d.StateLabel, Ui.For(d.State))),
                    Ui.P($"{d.Kind} · {d.Role} · {d.Detail}", Ui.Dim, 12),
                    Ui.P(d.LatencyMs >= 0 ? $"Response time: {d.LatencyMs:0} ms" : "Response time: —", Ui.Dim, 12),
                    Ui.P(d.LastCommand.Length > 0 ? $"Last: {d.LastCommand} → {(d.LastAck.Length > 0 ? d.LastAck : d.LastError)}" : "No command sent yet", Ui.Text, 12));
                card.Width = 300; card.Margin = new Thickness(0, 4, 10, 4);
                devices.Children.Add(card);
            }
            var dir = hub.Director;
            var pb = hub.PcPlayback is { Playing: true } pc ? pc : hub.PhonePlayback ?? hub.PcPlayback;
            director.Children.Clear();
            director.Children.Add(Ui.P($"Analysis: {dir.State}", Ui.Cyan));
            director.Children.Add(Ui.P($"Current scene: {dir.Scene}  ·  confidence {dir.SceneConfidence:P0}"));
            director.Children.Add(Ui.P($"Media time: {(pb == null ? "—" : TimeSpan.FromSeconds(pb.Position).ToString(@"h\:mm\:ss"))} ({pb?.Source ?? "no playback"})"));
            director.Children.Add(Ui.P($"Selected effects: wind {(dir.WantWind ? $"REQUESTED ({dir.WindConfidence:P0}) — {dir.WindEvidence}" : "off")} · light {dir.Light.Palette} #{dir.Light.R:X2}{dir.Light.G:X2}{dir.Light.B:X2} {dir.Light.Brightness:P0}"));
            if (hub.PhoneNote.Length > 0) director.Children.Add(Ui.P(hub.PhoneNote, Ui.Amber));
            if (!hub.Config.PhysicalEnabled || hub.Config.VirtualOnly) director.Children.Add(Ui.P("Physical outputs are not armed — the director's decisions are shown here but no device receives them.", Ui.Amber));
            last.Children.Clear();
            foreach (var t in hub.Devices.Telemetry.Take(8))
                last.Children.Add(Ui.P($"{t.At.ToLocalTime():HH:mm:ss}  {t.Device}  {t.Command}  →  {t.Ack}{(t.LatencyMs >= 0 ? $"  ({t.LatencyMs:0} ms)" : "")}", t.Ack.StartsWith("failed") || t.Ack.StartsWith("refused") ? Ui.Red : Ui.Text, 12));
            if (last.Children.Count == 0) last.Children.Add(Ui.P("No device commands yet.", Ui.Dim));
        };
        refresh();
    }

    // MARK: 2 Discovery

    void Discovery(StackPanel p)
    {
        p.Children.Add(Ui.H("Smart Device Discovery"));
        p.Children.Add(Ui.Sub("Tapo account (stored encrypted with Windows DPAPI on this PC only)"));
        var user = Ui.Input(hub.Config.TapoUser);
        var pass = new PasswordBox { Width = 260, Margin = new Thickness(0, 2, 8, 2), Padding = new Thickness(6, 4, 6, 4), Password = hub.Config.TapoPassword };
        p.Children.Add(Ui.Card(
            Ui.P("The P125M's local protocol (KLAP) authenticates with the e-mail and password of the Tapo app account that set the plug up. Set the plugs up in the Tapo app first (2.4 GHz Wi-Fi). Nothing is sent to TP-Link's cloud by ZMF.", Ui.Dim, 12),
            Ui.Row(new TextBlock { Text = "E-mail ", Foreground = Ui.Dim, Width = 70, VerticalAlignment = VerticalAlignment.Center }, user),
            Ui.Row(new TextBlock { Text = "Password ", Foreground = Ui.Dim, Width = 70, VerticalAlignment = VerticalAlignment.Center }, pass),
            Ui.Btn("Save credentials", (_, _) => { hub.Config.TapoUser = user.Text.Trim(); hub.Config.TapoPassword = pass.Password; save(); Ui.Tell(this, "Saved", "Credentials saved (encrypted)."); }, true)));

        p.Children.Add(Ui.Sub("Tapo plugs on this network"));
        var results = new StackPanel();
        var discoverStatus = Ui.P("", Ui.Dim, 12);
        p.Children.Add(Ui.Card(
            Ui.Row(Ui.Btn("Discover Tapo plugs", async (_, _) =>
            {
                discoverStatus.Text = "Searching (UDP 20002, 4 s)…";
                try { discovered = await HomeController.DiscoverTapoAsync(life.Token); discoverStatus.Text = $"Found {discovered.Count} TP-Link device(s)."; }
                catch (Exception ex) { discoverStatus.Text = "Discovery failed: " + ex.Message; }
                FillDiscovered(results);
            }, true), discoverStatus), results));
        FillDiscovered(results);

        p.Children.Add(Ui.Sub("Manual address (if discovery is blocked by your router)"));
        foreach (var plug in hub.Config.Plugs)
        {
            var ip = Ui.Input(plug.Ip, 160);
            var slot = plug.Slot;
            p.Children.Add(Ui.Row(new TextBlock { Text = $"{slot} ({plug.Role})", Foreground = Ui.Text, Width = 220, VerticalAlignment = VerticalAlignment.Center }, ip,
                Ui.Btn("Connect", async (_, _) => { await hub.Devices.ConnectPlugAsync(slot, ip.Text, life.Token); Show(section); })));
        }

        p.Children.Add(Ui.Sub("Govee strip (Bluetooth LE)"));
        var bleList = new StackPanel();
        var bleStatus = Ui.P("", Ui.Dim, 12);
        p.Children.Add(Ui.Card(
            Ui.P("Turn Bluetooth on, power the strip, and close the Govee Home app on your phone (a strip accepts one Bluetooth connection at a time).", Ui.Dim, 12),
            Ui.Row(Ui.Btn("Scan Bluetooth (8 s)", async (_, _) =>
            {
                bleStatus.Text = "Scanning…";
                try { strips = await GoveeBle.ScanAsync(TimeSpan.FromSeconds(8), life.Token); bleStatus.Text = $"Found {strips.Count} Govee-like device(s)."; }
                catch (Exception ex) { bleStatus.Text = "Bluetooth unavailable: " + ex.Message; }
                FillStrips(bleList);
            }, true), bleStatus), bleList));
        FillStrips(bleList);
    }

    void FillDiscovered(StackPanel results)
    {
        results.Children.Clear();
        foreach (var d in discovered)
        {
            var row = Ui.Row(new TextBlock { Text = $"{d.Model}  ·  {d.Ip}  ·  {d.Mac}  ·  {d.EncryptType}{(d.FactoryDefault ? " · NOT SET UP (use Tapo app first)" : "")}", Foreground = Ui.Text, Width = 520, VerticalAlignment = VerticalAlignment.Center });
            foreach (var plug in hub.Config.Plugs)
            {
                var slot = plug.Slot; var dev = d;
                row.Children.Add(Ui.Btn("→ " + slot, async (_, _) =>
                {
                    plug.HttpPort = dev.HttpPort; plug.DeviceId = dev.DeviceId;
                    await hub.Devices.ConnectPlugAsync(slot, dev.Ip, life.Token);
                    Show(section);
                }));
            }
            if (!d.Model.StartsWith("P125M", StringComparison.OrdinalIgnoreCase)) row.Children.Add(Ui.Chip("not a P125M — untested model", Ui.Amber));
            results.Children.Add(row);
        }
    }

    void FillStrips(StackPanel list)
    {
        list.Children.Clear();
        foreach (var s in strips)
        {
            var seen = s;
            list.Children.Add(Ui.Row(new TextBlock { Text = $"{s.Name}  ·  model {(s.Model ?? "unknown")}  ·  {s.Rssi} dBm", Foreground = Ui.Text, Width = 420, VerticalAlignment = VerticalAlignment.Center },
                Ui.Chip(GoveeProtocol.CommunityStatus(s.Model), Ui.Amber),
                Ui.Btn("Use this strip", (_, _) =>
                {
                    var l = hub.Config.Light;
                    l.Address = seen.Address; l.AdvertisedName = seen.Name; l.Model = seen.Model ?? ""; l.ModelConfirmed = false; l.ColorVerified = false;
                    save();
                    Show("Lighting and Color Control");
                })));
        }
    }

    // MARK: 3 Automatic effects

    void Automatic(StackPanel p)
    {
        var c = hub.Config;
        p.Children.Add(Ui.H("Automatic AI Effects"));
        p.Children.Add(Ui.Card(
            Ui.P("During Auto 4DX screenings the director reads what the film actually provides: decoded frames (camera motion on a 32×18 grid, colour, cuts), the soundtrack (booms, sharp hits, debris, sustained low rumble, speech-band share) and the playback clock. It labels scenes with honest heuristics such as \"sustained motion with engine-like rumble\" — it cannot recognise a helicopter specifically. YouTube and other sources that expose no frames or audio get no automatic physical effects."),
            Ui.P("Wind is requested only for sustained air-movement-like scenes (≥3 s, hysteresis, cooldowns). Lights follow a stabilised cinematic palette from the picture's colour; booms make a brief bounded warm swell, never a strobe.", Ui.Dim, 12)));
        p.Children.Add(Ui.Sub("Master switches"));
        p.Children.Add(Ui.Check("Arm physical effects (real devices may switch automatically)", c.PhysicalEnabled, v => { c.PhysicalEnabled = v; save(); }));
        p.Children.Add(Ui.Check("Virtual-only mode (never send physical commands)", c.VirtualOnly, v => { c.VirtualOnly = v; save(); }));
        p.Children.Add(Ui.Sub("Intensity"));
        var lv = Ui.Row();
        foreach (EffectLevel l in Enum.GetValues(typeof(EffectLevel)))
        {
            var r = new RadioButton { Content = l.ToString(), IsChecked = c.Level == l, Foreground = Ui.Text, Margin = new Thickness(0, 0, 16, 0), GroupName = "lvl" };
            var level = l;
            r.Checked += (_, _) => { c.Level = level; hub.Director.Level = level; save(); };
            lv.Children.Add(r);
        }
        p.Children.Add(lv);
        p.Children.Add(Ui.P("Extreme is still bounded: brightness ≤ 90%, the same plug switching limits and no strobing.", Ui.Dim, 12));
        p.Children.Add(Ui.Sub("Flashes"));
        var fl = Ui.Row();
        foreach (FlashPolicy f in Enum.GetValues(typeof(FlashPolicy)))
        {
            var r = new RadioButton { Content = f switch { FlashPolicy.Normal => "Normal (bounded swells)", FlashPolicy.Reduced => "Reduced flashes", _ => "No flashing" }, IsChecked = c.Flashes == f, Foreground = Ui.Text, Margin = new Thickness(0, 0, 16, 0), GroupName = "fl" };
            var pol = f;
            r.Checked += (_, _) => { c.Flashes = pol; hub.Director.Flashes = pol; save(); };
            fl.Children.Add(r);
        }
        p.Children.Add(fl);
        p.Children.Add(Ui.Sub("Output latency compensation"));
        var lat = new Slider { Minimum = 0, Maximum = 1500, Value = c.OutputLatencyMs, Width = 360, HorizontalAlignment = HorizontalAlignment.Left };
        var latText = Ui.P($"{c.OutputLatencyMs} ms early", Ui.Dim);
        lat.ValueChanged += (_, _) => { c.OutputLatencyMs = (int)lat.Value; latText.Text = $"{c.OutputLatencyMs} ms early"; save(); };
        p.Children.Add(lat); p.Children.Add(latText);
    }

    // MARK: 4 Physical config

    void PhysicalConfig(StackPanel p)
    {
        p.Children.Add(Ui.H("Physical Effect Configuration"));
        p.Children.Add(Ui.P("A smart plug only switches power on and off. It cannot change fan speed, colour or motor behaviour. Only plugs you authorize are ever automated.", Ui.Amber));
        foreach (var plug in hub.Config.Plugs)
        {
            var pl = plug;
            var attached = Ui.Input(pl.AttachedDevice, 320);
            attached.LostFocus += (_, _) => { pl.AttachedDevice = attached.Text.Trim(); save(); };
            var maxOn = Ui.Input(pl.MaxOnSeconds.ToString(), 60);
            maxOn.LostFocus += (_, _) => { if (int.TryParse(maxOn.Text, out var v)) { pl.MaxOnSeconds = Math.Clamp(v, 30, 3600); save(); } };
            p.Children.Add(Ui.Card(
                Ui.Row(new TextBlock { Text = $"{pl.Slot} · {pl.Role}", FontWeight = FontWeights.Bold, FontSize = 15, Foreground = Ui.Text, Margin = new Thickness(0, 0, 10, 0) },
                    Ui.Chip(hub.Devices.Devices[pl.Slot].StateLabel, Ui.For(hub.Devices.Devices[pl.Slot].State))),
                Ui.P(pl.Role == "MAIN_WIND" ? "Main wind: Sweetfull S36 on a suitable USB wall adapter. Automated only after the fan restart test passes." :
                     "Unassigned until compatible hardware is available — never automated by the director.", Ui.Dim, 12),
                Ui.Row(new TextBlock { Text = "Attached device ", Foreground = Ui.Dim, VerticalAlignment = VerticalAlignment.Center }, attached),
                Ui.Row(new TextBlock { Text = "Safety cutoff (max continuous on, s) ", Foreground = Ui.Dim, VerticalAlignment = VerticalAlignment.Center }, maxOn),
                Ui.Check("Authorize this plug for ZMF control", pl.Authorized, v => { pl.Authorized = v; save(); }),
                Ui.Check("This plug powers essential equipment (PC, router, heater, medical…) — never switch it", pl.Essential, v => { pl.Essential = v; if (v) pl.Authorized = false; save(); Show(section); }),
                Ui.P($"Plug control test: {(pl.PlugTestPassed ? "passed" : "not yet")} · Fan restart test: {(pl.FanRestartVerified switch { true => "PASSED", false => "FAILED (fan does not resume — automation disabled)", _ => "not tested" })}", Ui.Text, 12)));
        }
    }

    // MARK: 5 Virtual

    void Virtual(StackPanel p)
    {
        p.Children.Add(Ui.H("Virtual Cinema Effects"));
        p.Children.Add(Ui.P("These run inside the 3D cinema only. A moving virtual chair does not mean your real chair moves, and virtual rain/smoke/fire are drawn on screen — no liquid or smoke hardware is used.", Ui.Amber));
        p.Children.Add(Ui.P("Seat motion, rumble, wind particles and streaks, water droplets and mist, smoke haze, shockwaves, embers/sparks, debris, hit vignette and the roller-coaster ride are configured in Presentations → Real-time 4DX and are driven by the same director. Room illumination in the 3D auditorium mirrors the lighting director's palette even when no strip is connected.", Ui.Dim));
    }

    // MARK: 6 Lighting

    void Lighting(StackPanel p)
    {
        var l = hub.Config.Light;
        p.Children.Add(Ui.H("Lighting and Color Control"));
        p.Children.Add(Ui.Sub("Step 1 · Identify your exact model"));
        var model = Ui.Input(l.Model, 120);
        p.Children.Add(Ui.Card(
            Ui.P("Find the H-number (for example H6163, H619A, H6143):"),
            Ui.P("• on the label of the small controller box / power adapter on the strip's cable,\n• on the product box or the sticker on the reel,\n• in the Govee Home app: tap the strip → ⚙ settings → Device info (\"Model\").", Ui.Dim, 12),
            Ui.P(l.AdvertisedName.Length > 0 ? $"Bluetooth name of the selected strip: {l.AdvertisedName} (suggests {(GoveeProtocol.ModelFromName(l.AdvertisedName) ?? "no model")})" : "No strip selected yet — scan in Smart Device Discovery.", Ui.Text, 12),
            Ui.Row(new TextBlock { Text = "Model ", Foreground = Ui.Dim, VerticalAlignment = VerticalAlignment.Center }, model,
                Ui.Btn("Confirm model", (_, _) => { l.Model = model.Text.Trim().ToUpperInvariant(); l.ModelConfirmed = l.Model.StartsWith("H"); save(); Show(section); }, true)),
            Ui.P("Community status: " + GoveeProtocol.CommunityStatus(l.ModelConfirmed ? l.Model : null), Ui.Amber, 12)));

        p.Children.Add(Ui.Sub("Step 2 · Connect and find a working colour protocol"));
        var status = Ui.P(hub.Devices.Devices["GOVEE"].Detail, Ui.Dim, 12);
        var testRow = Ui.Row();
        foreach (var v in new[] { GoveeProtocol.ColorVariant.Manual02, GoveeProtocol.ColorVariant.Manual0D, GoveeProtocol.ColorVariant.Segments15 })
        {
            var variant = v;
            testRow.Children.Add(Ui.Btn("Test " + GoveeProtocol.Describe(v)[..1], async (_, _) => await ColorTest(variant, status)));
        }
        p.Children.Add(Ui.Card(
            Ui.P("Govee publishes no local Bluetooth API. ZMF uses community-documented packets, which differ between models. Each test turns the strip blue → green → red; you confirm what you saw. Automatic lighting stays off until a test is confirmed.", Ui.Dim, 12),
            Ui.Row(Ui.Btn("Connect via Bluetooth", async (_, _) =>
            {
                if (l.Address == 0) { Ui.Tell(this, "Govee", "Select a strip in Smart Device Discovery first."); return; }
                status.Text = "Connecting…";
                var ble = await hub.Devices.ConnectLightAsync(l.Address, life.Token);
                status.Text = hub.Devices.Devices["GOVEE"].Detail;
            }, true), Ui.Check("Authorize automatic lighting", l.Authorized, v => { l.Authorized = v; save(); })),
            testRow, status,
            Ui.P($"Confirmed protocol: {GoveeProtocol.Describe(l.Variant)} · colour verified: {(l.ColorVerified ? "yes" : "no")}", l.ColorVerified ? Ui.Green : Ui.Amber, 12)));

        p.Children.Add(Ui.Sub("Manual control"));
        var palettes = new WrapPanel();
        foreach (var (name, col) in SceneDirector.PaletteColors)
        {
            var c = col; var n = name;
            var b = Ui.Btn(n, async (_, _) =>
            {
                await hub.Devices.WriteLightAsync(GoveeProtocol.Color(c.r, c.g, c.b, l.Variant == GoveeProtocol.ColorVariant.Unknown ? GoveeProtocol.ColorVariant.Manual02 : l.Variant), "manual " + n, life.Token);
            });
            b.BorderBrush = new SolidColorBrush(Color.FromRgb(c.r, c.g, c.b)); b.BorderThickness = new Thickness(2);
            palettes.Children.Add(b);
        }
        var bright = new Slider { Minimum = 5, Maximum = 100, Value = 50, Width = 300, HorizontalAlignment = HorizontalAlignment.Left };
        bright.PreviewMouseUp += async (_, _) => await hub.Devices.WriteLightAsync(GoveeProtocol.Brightness(bright.Value / 100, l.Variant), $"brightness {bright.Value:0}%", life.Token);
        p.Children.Add(Ui.Card(palettes, Ui.Row(new TextBlock { Text = "Brightness ", Foreground = Ui.Dim, VerticalAlignment = VerticalAlignment.Center }, bright),
            Ui.Row(Ui.Btn("Power on", async (_, _) => await hub.Devices.WriteLightAsync(GoveeProtocol.Power(true), "power on", life.Token)),
                   Ui.Btn("Power off", async (_, _) => await hub.Devices.WriteLightAsync(GoveeProtocol.Power(false), "power off", life.Token)))));
    }

    async Task ColorTest(GoveeProtocol.ColorVariant v, TextBlock status)
    {
        var l = hub.Config.Light;
        foreach (var (r, g, b, n) in new[] { ((byte)0, (byte)0, (byte)255, "blue"), ((byte)0, (byte)255, (byte)0, "green"), ((byte)255, (byte)0, (byte)0, "red") })
        {
            var ms = await hub.Devices.WriteLightAsync(GoveeProtocol.Color(r, g, b, v), $"colour test {GoveeProtocol.Describe(v)[..1]} {n}", life.Token);
            status.Text = ms >= 0 ? $"Sent {n} ({ms:0} ms) — watch the strip" : "Bluetooth write failed: " + hub.Devices.Devices["GOVEE"].Detail;
            if (ms < 0) return;
            await Task.Delay(1500);
        }
        if (Ui.Ask(this, "Colour test", "Did your strip change BLUE → GREEN → RED?"))
        {
            l.Variant = v; l.ColorVerified = true; save();
            hub.Devices.AttachLightStateRefresh();
            hub.Config.TestResults["T5"] = $"PASS {DateTime.Now:g} · physically confirmed by you · protocol {GoveeProtocol.Describe(v)}";
        }
        else hub.Config.TestResults["T5"] = $"FAIL {DateTime.Now:g} · variant {GoveeProtocol.Describe(v)} did not change the strip";
        save();
        Show(section);
    }

    // MARK: 7 Wind

    void Wind(StackPanel p)
    {
        var plug = hub.Config.Plugs.First(x => x.Slot == "TAPO_01");
        var st = hub.Devices.Devices["TAPO_01"];
        p.Children.Add(Ui.H("Wind Controller"));
        p.Children.Add(Ui.Card(
            Ui.Row(new TextBlock { Text = "TAPO_01 · MAIN_WIND", FontWeight = FontWeights.Bold, Foreground = Ui.Text, Margin = new Thickness(0, 0, 10, 0) }, Ui.Chip(st.StateLabel, Ui.For(st.State))),
            Ui.P($"Fan restart verified: {plug.FanRestartVerified switch { true => "YES — automatic wind can be armed", false => "NO — this fan stays off when power returns, so a plug cannot start it", _ => "not tested yet" }}",
                plug.FanRestartVerified == true ? Ui.Green : Ui.Amber),
            Ui.P("Only ON/OFF. The Sweetfull S36 keeps the speed you choose with its button; a plug cannot change speed. Wind is used for longer scenes only (minimum 8 s on, 12 s cooldown, ≤30 switches per hour, continuous-on cutoff).", Ui.Dim, 12),
            Ui.Row(Ui.Btn("Run fan restart test", async (_, _) => await FanRestartTest(), true),
                Ui.Btn("Fan ON (manual)", async (_, _) => await hub.Devices.SetPlugAsync("TAPO_01", true, "manual", life.Token)),
                Ui.Btn("Fan OFF (manual)", async (_, _) => await hub.Devices.SetPlugAsync("TAPO_01", false, "manual", life.Token)))));
        if (plug.FanRestartVerified == false)
            p.Children.Add(Ui.Card(Ui.P("Limitation: automated wind is NOT available with this fan.", Ui.Red),
                Ui.P("Many single-button USB fans power up switched off. Alternatives that work with a smart plug: a USB fan with a mechanical slide/rocker switch left in the ON position, or a desk fan documented to resume after power loss. Do not open or modify the fan.", Ui.Dim, 12)));
    }

    async Task FanRestartTest()
    {
        var plug = hub.Config.Plugs.First(x => x.Slot == "TAPO_01");
        if (!plug.Authorized || plug.Essential) { Ui.Tell(this, "Fan test", "Authorize TAPO_01 in Physical Effect Configuration first (and make sure it only powers the fan's USB adapter)."); return; }
        if (!await hub.Devices.SetPlugAsync("TAPO_01", true, "fan test: power on", life.Token)) { Ui.Tell(this, "Fan test", "Couldn't switch TAPO_01 on: " + hub.Devices.Devices["TAPO_01"].LastError); return; }
        if (!Ui.Ask(this, "Fan restart test · step 1", "Start the Sweetfull fan normally with its button now and pick your speed.\n\nIs the fan spinning?")) return;
        if (!Ui.Ask(this, "Fan restart test · step 2", "ZMF will now switch TAPO_01 OFF for 5 seconds and then back ON.\n\nAllow this brief power cut?")) return;
        await hub.Devices.SetPlugAsync("TAPO_01", false, "fan test: power off", life.Token);
        await Task.Delay(5000);
        await hub.Devices.SetPlugAsync("TAPO_01", true, "fan test: power restored", life.Token);
        await Task.Delay(1500);
        var resumed = Ui.Ask(this, "Fan restart test · step 3", "Power has been restored.\n\nDid the fan START SPINNING AGAIN BY ITSELF (without pressing its button)?");
        plug.FanRestartVerified = resumed; plug.FanTestedAt = DateTime.Now;
        hub.Config.TestResults["T3"] = resumed ? $"PASS {DateTime.Now:g} · you confirmed the fan resumed after power restore" : $"FAIL {DateTime.Now:g} · fan did not resume — automated wind disabled";
        await hub.Devices.SetPlugAsync("TAPO_01", false, "fan test finished", life.Token);
        save();
        await hub.Devices.RefreshAsync("TAPO_01", life.Token);
        Show(section);
    }

    // MARK: 8 Rooms

    void RoomsSection(StackPanel p)
    {
        p.Children.Add(Ui.H("Private Cinema Rooms"));
        var host = hub.Host;
        p.Children.Add(Ui.P(host?.Running == true ? $"Host running on port {host.Port}. Friends on your network open the invite link; remote friends should use an encrypted overlay such as Tailscale (never forward the port)." :
            "Host not running" + (host?.Error is { } e ? ": " + e : ""), host?.Running == true ? Ui.Green : Ui.Red));
        var name = Ui.Input("ZMF Private Cinema", 260);
        p.Children.Add(Ui.Row(name, Ui.Btn("Create room", (_, _) =>
        {
            var room = hub.Rooms.With(() =>
            {
                var r = new CinemaRoom { Name = name.Text.Trim().Length > 0 ? name.Text.Trim() : "ZMF Private Cinema" };
                r.Members.Add(new RoomMember { Name = "Host (PC)", Kind = "Host", Seat = r.FreeSeat() });
                hub.Rooms.Rooms.Add(r);
                return r;
            });
            hub.Rooms.Post(room, "system", "ZMF", "Room created on the PC");
            Show(section);
        }, true)));
        var ip = LanAddresses().FirstOrDefault() ?? "YOUR-PC-IP";
        foreach (var room in hub.Rooms.Rooms.ToList())
        {
            var r = room;
            var link = $"http://{ip}:{host?.Port ?? hub.Config.HostPort}/companion?room={r.Id}&invite={r.InviteCode}";
            var chatList = new StackPanel();
            var msg = Ui.Input("", 420);
            var aiRow = Ui.Row();
            foreach (var persona in AiGuestEngine.Personas)
            {
                var pe = persona;
                var present = r.Members.Any(m => m.Kind == "AI" && m.Name == pe.Name && m.Present);
                aiRow.Children.Add(Ui.Btn((present ? "− " : "+ ") + pe.Name + " (AI)", (_, _) =>
                {
                    if (present) { hub.Rooms.With(() => r.Members.RemoveAll(m => m.Kind == "AI" && m.Name == pe.Name)); hub.Rooms.Post(r, "leave", pe.Name, $"{pe.Name} (AI) left", true); }
                    else
                    {
                        var m = hub.Rooms.With(() => { var mm = new RoomMember { Name = pe.Name, Kind = "AI", Seat = r.FreeSeat() }; r.Members.Add(mm); return mm; });
                        hub.Rooms.Post(r, "join", pe.Name, $"{pe.Name} (AI · {pe.Tagline}) took seat {m.Seat}", true);
                        hub.Rooms.Post(r, "chat", pe.Name, hub.Ai.Greeting(pe), true);
                    }
                    Show(section);
                }));
            }
            void Send()
            {
                var t = msg.Text.Trim(); if (t.Length == 0) return; msg.Text = "";
                hub.Rooms.Post(r, "chat", "Host (PC)", t);
                foreach (var (g, reply) in hub.Ai.Reply(r.Members.Where(m => m.Kind == "AI" && m.Present).Select(m => m.Name), "Host", t, r.Playback.Title, hub.Director.Scene.StartsWith("Dialogue")))
                    hub.Rooms.Post(r, "chat", g, reply, true);
            }
            msg.KeyDown += (_, e) => { if (e.Key == System.Windows.Input.Key.Enter) Send(); };
            p.Children.Add(Ui.Card(
                Ui.Row(new TextBlock { Text = r.Name, FontWeight = FontWeights.Bold, FontSize = 15, Foreground = Ui.Text, Margin = new Thickness(0, 0, 10, 0) },
                    Ui.Btn("Copy invite link", (_, _) => { try { Clipboard.SetText(link); } catch { } }),
                    Ui.Btn("Delete", (_, _) => { if (Ui.Ask(this, "Delete room", $"Delete {r.Name}?")) { hub.Rooms.With(() => hub.Rooms.Rooms.Remove(r)); Show(section); } })),
                Ui.P($"Invite link: {link}", Ui.Dim, 12),
                Ui.P("In the room: " + string.Join(", ", r.Members.Where(m => m.Present).Select(m => $"{m.Name}{(m.Kind == "AI" ? " [AI · scripted]" : "")} ({m.Seat})")), Ui.Text, 12),
                aiRow, chatList, Ui.Row(msg, Ui.Btn("Send", (_, _) => Send(), true))));
            var last = -1L;
            void FillChat()
            {
                var items = r.Items.TakeLast(10).ToList();
                if (items.Count > 0 && items[^1].Seq == last) return;
                last = items.Count > 0 ? items[^1].Seq : -1;
                chatList.Children.Clear();
                foreach (var i in items)
                    chatList.Children.Add(Ui.P(i.Kind == "chat" ? $"{i.From}{(i.Ai ? " [AI · scripted]" : "")}: {i.Text}" : i.Text, i.Ai ? Ui.Cyan : i.Kind == "chat" ? Ui.Text : Ui.Dim, 12));
            }
            FillChat();
            var prev = refresh;
            refresh = () => { prev?.Invoke(); FillChat(); };
        }
    }

    // MARK: 9 Companion

    static List<string> LanAddresses() =>
        NetworkInterface.GetAllNetworkInterfaces().Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses).Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork)
            .Select(a => a.Address.ToString()).Where(a => !a.StartsWith("169.254")).ToList();

    void Companion(StackPanel p)
    {
        p.Children.Add(Ui.H("PC + iPhone Companion"));
        var code = hub.Config.AccessCode(); save();
        var codeText = new TextBlock { Text = code, FontSize = 30, FontWeight = FontWeights.Black, Foreground = Ui.Gold, FontFamily = new FontFamily("Consolas") };
        var port = hub.Host?.Port ?? hub.Config.HostPort;
        var urls = string.Join("\n", LanAddresses().Select(a => $"http://{a}:{port}/companion"));
        p.Children.Add(Ui.Card(Ui.P("Access code (keep it private):"), codeText,
            Ui.Btn("Generate a new code", (_, _) => { if (Ui.Ask(this, "New code", "Signed-in phones will need the new code. Continue?")) { hub.Config.AccessCodeProtected = ""; save(); Show(section); } })));
        p.Children.Add(Ui.Card(
            Ui.P("On your iPhone 16 Pro (same Wi-Fi as this PC):"),
            Ui.P("1. Safari → open one of these addresses → sign in with the code (Share → Add to Home Screen for an app icon):", Ui.Dim, 12),
            Ui.P(urls.Length > 0 ? urls : "No network address found.", Ui.Cyan, 14),
            Ui.P("2. In the ZMF THEATERS+ iPhone app: Admin → Server Manager → Home 4DX (Windows PC) → enter the address (e.g. 192.168.1.20:8977) and the code. While a film plays on the phone, the PC replays the 4DX timeline it analysed for that title and drives the fan and lights.", Ui.Dim, 12),
            Ui.P("Windows will ask once whether ZMF THEATERS+ may accept connections on private networks — allow it for private networks only.", Ui.Amber, 12)));
        var sync = Ui.P("", Ui.Text, 12);
        p.Children.Add(Ui.Sub("Phone sync status"));
        p.Children.Add(Ui.Card(sync));
        refresh = () =>
        {
            var ph = hub.PhonePlayback;
            sync.Text = ph == null ? "No phone report yet." : $"{ph.Title} ({ph.MediaId}) · {(ph.Playing ? "playing" : "paused")} @ {TimeSpan.FromSeconds(ph.Position):h\\:mm\\:ss} · last report {(hub.NowMs - ph.ServerTimeMs) / 1000.0:0.0}s ago\n{hub.PhoneNote}";
        };
        refresh();
    }

    // MARK: 10 Testing lab

    void Lab(StackPanel p)
    {
        p.Children.Add(Ui.H("Testing Laboratory"));
        p.Children.Add(Ui.P("Physical tests need your real devices and your confirmation. Results from the mock self-test are labelled MOCK and never count as physical verification.", Ui.Amber));
        var tests = new (string id, string name, Func<Task<string>> run)[]
        {
            ("T1", "Tapo discovery — detect the three P125M plugs", async () => { var d = await HomeController.DiscoverTapoAsync(life.Token); var n = d.Count(x => x.Model.StartsWith("P125M", StringComparison.OrdinalIgnoreCase)); return n >= 3 ? $"PASS found {n} P125M plugs" : n > 0 ? $"PARTIAL found {n} of 3 P125M plugs ({d.Count} TP-Link devices total)" : $"FAIL no P125M answered ({d.Count} TP-Link devices)"; }),
            ("T2", "Plug control — on/off confirmed by each plug's reported state", PlugControlTest),
            ("T3", "Fan restart — does the Sweetfull resume after power returns?", async () => { await FanRestartTest(); return hub.Config.TestResults.GetValueOrDefault("T3", "AWAITING HARDWARE"); }),
            ("T4", "Govee discovery — find the strip and its model", async () => { var s = await GoveeBle.ScanAsync(TimeSpan.FromSeconds(8), life.Token); strips = s; return s.Count > 0 ? $"PASS {string.Join(", ", s.Select(x => $"{x.Name} ({x.Model ?? "model unknown"})"))}" : "FAIL no Govee-like Bluetooth device seen"; }),
            ("T5", "Govee colour — blue / green / red on the physical strip", async () => { Show("Lighting and Color Control"); return "AWAITING HARDWARE — use the Test buttons on the Lighting page"; }),
            ("T6", "Movie wind — play an Auto 4DX film with a sustained wind scene", async () => await WatchFor("wind ON acknowledged during playback", () => hub.Devices.Telemetry.Any(t => t.Device == "TAPO_01" && t.Command == "ON" && t.Ack.Contains("plug reports ON") && !t.Ack.StartsWith("[SIMULATED]")), 300, "Did you feel the fan blowing during the scene?")),
            ("T7", "Lightning — safe brightness transition (no rapid flashing)", LightningTest),
            ("T8", "Pause — pausing during wind stops all scheduled effects", async () => await WatchFor("fan OFF within 1 s of pausing", () => hub.Devices.Telemetry.Any(t => t.Device == "TAPO_01" && t.Command == "OFF" && t.Reason is "paused" or "player stopped" && t.Ack.Contains("OFF")), 300, null)),
            ("T9", "Phone sync — control playback from the iPhone while the PC keeps the timeline", async () => await WatchFor("phone playback report received", () => hub.PhonePlayback is { } ph && hub.NowMs - ph.ServerTimeMs < 3000, 180, null)),
            ("T10", "Private cinema — an authenticated guest joins a room", async () => await WatchFor("a real guest is present", () => hub.Rooms.Rooms.Any(r => r.Members.Any(m => m.Kind == "Guest" && m.Present)), 300, null)),
            ("T11", "AI guest — joins and replies to a message", AiGuestTest),
            ("T12", "Emergency stop — everything off, automation disabled", EStopTest),
        };
        foreach (var (id, name, run) in tests)
        {
            var result = Ui.P(hub.Config.TestResults.GetValueOrDefault(id, "not run"), Ui.Dim, 12);
            var tid = id;
            p.Children.Add(Ui.Card(Ui.Row(new TextBlock { Text = $"{id}  {name}", Foreground = Ui.Text, FontWeight = FontWeights.SemiBold, Width = 640, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center },
                Ui.Btn("Run", async (_, _) =>
                {
                    result.Text = "running…";
                    string r;
                    try { r = await run(); } catch (Exception ex) { r = "FAIL " + ex.Message; }
                    // T3/T5 record their own (physically confirmed) result.
                    if (tid is not ("T3" or "T5")) hub.Config.TestResults[tid] = $"{r} · {DateTime.Now:g}";
                    else if (!hub.Config.TestResults.ContainsKey(tid)) hub.Config.TestResults[tid] = r;
                    save();
                    result.Text = hub.Config.TestResults[tid];
                    result.Foreground = hub.Config.TestResults[tid].StartsWith("PASS") ? Ui.Green : hub.Config.TestResults[tid].StartsWith("FAIL") ? Ui.Red : Ui.Amber;
                }, true)), result));
        }
        var mock = Ui.P("", Ui.Cyan, 12);
        p.Children.Add(Ui.Sub("Software self-test (MOCK devices — not physical verification)"));
        p.Children.Add(Ui.Card(Ui.Btn("Run mock self-test", async (_, _) =>
        {
            mock.Text = "running…";
            var file = Path.Combine(Path.GetTempPath(), "zmf-home-selftest.txt");
            var rc = await Task.Run(() => HomeSelfTest.Run(file));
            var lines = File.ReadAllLines(file);
            mock.Text = $"{(rc == 0 ? "ALL PASSED" : "FAILURES")} · {lines.Count(l => l.StartsWith("PASS"))} passed, {lines.Count(l => l.StartsWith("FAIL"))} failed (MOCK)\n" + string.Join("\n", lines.Where(l => l.StartsWith("FAIL")).Take(10));
        }), mock));
    }

    async Task<string> PlugControlTest()
    {
        var results = new List<string>();
        foreach (var plug in hub.Config.Plugs.Where(p => p.Ip.Length > 0))
        {
            if (!plug.Authorized || plug.Essential) { results.Add($"{plug.Slot} skipped (not authorized)"); continue; }
            if (!Ui.Ask(this, "Plug control test", $"Switch {plug.Slot} ({plug.Nickname}) ON for 3 seconds and then OFF?\nOnly continue if whatever it powers is safe to switch.")) { results.Add($"{plug.Slot} skipped"); continue; }
            var on = await hub.Devices.SetPlugAsync(plug.Slot, true, "plug test on", life.Token);
            await Task.Delay(3000);
            var off = await hub.Devices.SetPlugAsync(plug.Slot, false, "plug test off", life.Token);
            plug.PlugTestPassed = on && off;
            results.Add($"{plug.Slot} {(on && off ? "OK (reported ON then OFF)" : "FAILED: " + hub.Devices.Devices[plug.Slot].LastError)}");
            await hub.Devices.RefreshAsync(plug.Slot, life.Token);
        }
        save();
        return results.Count == 0 ? "AWAITING HARDWARE — no plug has an address yet" : (results.All(r => r.Contains("OK")) ? "PASS " : "PARTIAL ") + string.Join("; ", results);
    }

    async Task<string> LightningTest()
    {
        var v = hub.Config.Light.Variant == GoveeProtocol.ColorVariant.Unknown ? GoveeProtocol.ColorVariant.Manual02 : hub.Config.Light.Variant;
        await hub.Devices.WriteLightAsync(GoveeProtocol.Color(170, 190, 255, v), "lightning test colour", life.Token);
        foreach (var b in new[] { 0.3, 0.45, 0.6, 0.7, 0.6, 0.45, 0.3 })   // smooth swell over ~2 s, no strobe
        {
            if (await hub.Devices.WriteLightAsync(GoveeProtocol.Brightness(b, v), $"lightning swell {b:P0}", life.Token) < 0) return "FAIL strip not reachable";
            await Task.Delay(300);
        }
        return Ui.Ask(this, "Lightning test", "Did the strip brighten smoothly and dim again, without rapid flashing?") ? "PASS confirmed by you" : "FAIL not confirmed";
    }

    async Task<string> AiGuestTest()
    {
        var room = hub.Rooms.Rooms.FirstOrDefault() ?? hub.Rooms.With(() => { var r = new CinemaRoom { Name = "AI test room" }; hub.Rooms.Rooms.Add(r); return r; });
        if (!room.Members.Any(m => m.Kind == "AI" && m.Name == "Nova" && m.Present))
        {
            var m = hub.Rooms.With(() => { var mm = new RoomMember { Name = "Nova", Kind = "AI", Seat = room.FreeSeat() }; room.Members.Add(mm); return mm; });
            hub.Rooms.Post(room, "join", "Nova", $"Nova (AI) took seat {m.Seat}", true);
        }
        var before = room.Items.Count(i => i.Ai);
        hub.Rooms.Post(room, "chat", "Host (PC)", "Hi Nova, what do you think so far?");
        foreach (var (g, reply) in hub.Ai.Reply(new[] { "Nova" }, "Host", "Hi Nova, what do you think so far?", room.Playback.Title, false)) hub.Rooms.Post(room, "chat", g, reply, true);
        await Task.Delay(100);
        var after = room.Items.Where(i => i.Ai).ToList();
        return after.Count > before ? $"PASS Nova replied: \"{after[^1].Text}\" (scripted AI, labelled)" : "FAIL no reply";
    }

    async Task<string> EStopTest()
    {
        if (!Ui.Ask(this, "Emergency stop test", "This switches every authorized plug OFF and disables automation until you re-arm. Continue?")) return "skipped";
        var sw = Stopwatch.StartNew();
        await hub.EmergencyStopAsync("testing laboratory");
        var authorized = hub.Config.Plugs.Where(p => p.Authorized && !p.Essential && p.Ip.Length > 0).ToList();
        foreach (var pl in authorized) await hub.Devices.RefreshAsync(pl.Slot, life.Token);
        var allOff = authorized.All(pl => hub.Devices.Devices[pl.Slot].ReportedOn == false);
        var physical = authorized.Count > 0 && !hub.Devices.SimulationMode;
        return (allOff && hub.Devices.EmergencyStopped ? (physical ? "PASS " : "PASS (no physical plug authorized — software only) ") : "FAIL ") +
               $"in {sw.ElapsedMilliseconds} ms · plugs reporting OFF: {string.Join(", ", authorized.Select(a => $"{a.Slot}={(hub.Devices.Devices[a.Slot].ReportedOn == false ? "OFF" : "?")}"))} · re-arm on the Safety page";
    }

    /// Waits for a condition observed in real telemetry, then optionally asks the user.
    async Task<string> WatchFor(string what, Func<bool> cond, int seconds, string? question)
    {
        Ui.Tell(this, "Testing Laboratory", $"Waiting up to {seconds / 60} min for: {what}.\nStart the scenario now (play / pause / join from the phone) — this window keeps watching.");
        var until = DateTime.UtcNow.AddSeconds(seconds);
        while (DateTime.UtcNow < until && !life.IsCancellationRequested)
        {
            if (cond())
                return question == null || Ui.Ask(this, "Testing Laboratory", question) ? $"PASS {what}" : $"FAIL {what}, but you did not notice the effect";
            await Task.Delay(500);
        }
        return $"FAIL timed out waiting for: {what}";
    }

    // MARK: 11 Safety

    void Safety(StackPanel p)
    {
        p.Children.Add(Ui.H("Safety and Emergency Stop"));
        var big = Ui.Btn("■  EMERGENCY STOP — ALL EFFECTS OFF", async (_, _) => await hub.EmergencyStopAsync("Safety page"), danger: true);
        big.FontSize = 20; big.Padding = new Thickness(30, 18, 30, 18);
        p.Children.Add(big);
        p.Children.Add(Ui.Row(Ui.Btn("Re-arm automation", (_, _) => { hub.Devices.Rearm(); Show(section); }, true), Ui.P(hub.Devices.EmergencyStopped ? "Emergency stop is ACTIVE." : "Automation is armed according to your settings.", hub.Devices.EmergencyStopped ? Ui.Red : Ui.Green)));
        p.Children.Add(Ui.Card(
            Ui.P("Built-in protections", Ui.Gold),
            Ui.P("• Emergency stop: here, F12 in the cinema, the phone companion and the iPhone app. Cancels scheduled commands, switches authorized plugs off, sets lights to dim warm white and blocks automation until re-armed.\n• Only plugs you authorize are switched; plugs marked as essential equipment are never switched.\n• Wind requires a passed fan restart test. Minimum 8 s on / 12 s off, ≤30 switches per hour, continuous-on cutoff, duplicate commands suppressed, 4 s command timeout, automatic reconnect.\n• Pause, stop, seek and end of film turn the fan off immediately.\n• Lights: bounded brightness, smooth transitions, reduced/no-flash modes, no strobing.\n• Companion and rooms require an access code or invite; guests can never control devices.", Ui.Text, 12)));
        p.Children.Add(Ui.Card(
            Ui.P("Always", Ui.Red),
            Ui.P("• If ZMF crashes or the PC is off, switch devices with the Tapo app, Apple Home, or the plug's own button, and the Govee app or strip controller.\n• Never put the PC, router, heaters, medical or other essential equipment on an automated plug.\n• Respect each device's load limits (motor loads are lower than the plug's 15 A general rating).\n• No mains wiring changes, no opening the fan, no liquid/mist effects near electronics, no improvised motion chairs.", Ui.Text, 12)));
    }

    // MARK: 12 Diagnostics

    void Diagnostics(StackPanel p)
    {
        p.Children.Add(Ui.H("Diagnostics"));
        var tele = new StackPanel();
        var events = new StackPanel();
        p.Children.Add(Ui.Row(Ui.Btn("Export diagnostics (no passwords)", (_, _) =>
        {
            var file = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Desktop), $"ZMF-Home4DX-diagnostics-{DateTime.Now:yyyyMMdd-HHmmss}.txt");
            var lines = new List<string> { $"ZMF THEATERS+ Home 4DX diagnostics {DateTime.Now:u}", $"Host: {(hub.Host?.Running == true ? "running :" + hub.Host.Port : "off " + hub.Host?.Error)}" };
            lines.AddRange(hub.Devices.Devices.Values.Select(d => $"{d.Id} {d.Kind} '{d.Name}' {d.StateLabel} {d.Detail} latency={d.LatencyMs:0} last='{d.LastCommand}' ack='{d.LastAck}' err='{d.LastError}'"));
            lines.AddRange(hub.Config.TestResults.Select(kv => $"{kv.Key}: {kv.Value}"));
            lines.AddRange(hub.Devices.Telemetry.Select(t => $"{t.At:u} {t.Device} {t.Command} -> {t.Ack} {t.LatencyMs:0}ms media={t.MediaTime:0.0} conf={t.Confidence:0.00} scene='{t.Scene}' reason='{t.Reason}'"));
            lines.AddRange(hub.Director.Log.Select(e => $"event {e.Type} t={e.Timestamp:0.0} dur={e.Duration:0.0} conf={e.Confidence:0.00} cancelled={e.Cancelled} '{e.Evidence}'"));
            File.WriteAllLines(file, lines);
            Ui.Tell(this, "Diagnostics", "Saved to " + file);
        }, true), Ui.Btn("Simulation mode (mock devices)", (_, _) => { if (Ui.Ask(this, "Simulation", "Replace all devices with SIMULATED mocks until restart? (For demos only — nothing physical will switch.)")) { hub.Devices.UseMocks(); Show(section); } })));
        p.Children.Add(Ui.Sub("Command telemetry"));
        p.Children.Add(Ui.Card(tele));
        p.Children.Add(Ui.Sub("Director events (unified FourDXEvent log)"));
        p.Children.Add(Ui.Card(events));
        refresh = () =>
        {
            tele.Children.Clear();
            foreach (var t in hub.Devices.Telemetry.Take(40))
                tele.Children.Add(Ui.P($"{t.At.ToLocalTime():HH:mm:ss.fff}  {t.Device,-7} {t.Command,-22} → {t.Ack}  {(t.LatencyMs >= 0 ? $"{t.LatencyMs:0} ms" : "")}  {(double.IsFinite(t.MediaTime) ? $"media {t.MediaTime:0.0}s" : "")}  {(t.Confidence > 0 ? $"conf {t.Confidence:P0}" : "")}  {t.Reason}", Ui.Text, 11));
            events.Children.Clear();
            foreach (var e in hub.Director.Log.TakeLast(30).Reverse())
                events.Children.Add(Ui.P($"{e.Type,-9} @ {e.Timestamp:0.0}s  dur {e.Duration:0.0}s  conf {e.Confidence:P0}  int {e.Intensity:0.00}  → {string.Join("+", e.PhysicalTargets)} / {string.Join(", ", e.VirtualOutputs)}  {(e.Cancelled ? "CANCELLED " : "")}{e.Evidence}", e.Cancelled ? Ui.Amber : Ui.Text, 11));
        };
        refresh();
    }
}

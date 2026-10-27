using System.IO;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Media.Media3D;
using LibVLCSharp.Shared;
using ZMFTheaters.Cinema;
using ZMFTheaters.Jellyfin;
using MediaPlayer = LibVLCSharp.Shared.MediaPlayer;

namespace ZMFTheaters;

public enum Format { TwoD, ThreeD, FourDX, FourDX3D }
public static class FormatFeatures
{
    public static bool UsesDepth(this Format f) => f is Format.ThreeD or Format.FourDX3D;
    public static bool Uses4DX(this Format f) => f is Format.FourDX or Format.FourDX3D;
}

public sealed record CinemaTicket(MediaEntry Film, int Room, int Row, int Seat, Format Format, int Price)
{
    public string SeatLabel => $"{(char)('A' + Row)}{Seat + 1}";
    public string FormatLabel => Format switch { Format.ThreeD => "Auto 3D", Format.FourDX => "Auto 4DX", Format.FourDX3D => "Auto 4DX 3D", _ => "2D" };
}

public sealed class FilmChoice
{
    public required MediaEntry Film { get; init; }
    public required Room Room { get; init; }
    public bool Featured { get; init; }
    public string Label => $"{(Featured ? "★ " : "")}{Film.Title}  ({Film.YearText})  ·  Room {Room.Code} {Room.Name}";
}

/// Material whose picture can be swapped later (posters loading, screens playing).
sealed class DynamicTexture
{
    public MaterialGroup Material { get; } = new();
    readonly EmissiveMaterial emissive = new();
    public DynamicTexture(ImageSource initial)
    {
        Material.Children.Add(new DiffuseMaterial(Brushes.Black));
        Material.Children.Add(emissive);
        Set(initial);
    }
    public void Set(ImageSource src) =>
        emissive.Brush = new ImageBrush(src) { ViewportUnits = BrushMappingMode.Absolute, Viewport = new Rect(0, 0, 1, 1), Stretch = Stretch.Fill };
    /// Live content (the roller-coaster scene) shown through a brush.
    public void SetBrush(Brush brush) => emissive.Brush = brush;
}

/// The walkable 3D ZMF cinema for Windows: lobby, box office, concessions,
/// auditorium hall with twelve doors, and twelve auditoriums with stadium
/// seating. Buy a ticket, walk to your room, sit, and the film plays on the
/// in-world screen — in 2D, converted red/cyan 3D, or the 4DX preview.
public partial class CinemaWindow : Window
{
    readonly AppConfig config;
    readonly Func<ServerConfig, JellyfinClient> clientFor;
    readonly List<MediaEntry> catalog;
    readonly Dictionary<int, MediaEntry> featured;
    readonly SyncPlayClient? party;
    readonly string? shotName;
    readonly string? shotPath;

    // World
    readonly Model3DGroup scene = new();
    readonly Model3DGroup visibleRooms = new();
    readonly Dictionary<int, Model3DGroup> rooms = new();
    readonly Dictionary<string, DynamicTexture> textures = new();
    readonly Dictionary<int, DynamicTexture> screens = new();
    readonly Dictionary<int, (TranslateTransform3D a, TranslateTransform3D b)> doors = new();
    readonly double[] doorOpen = new double[13];
    readonly AmbientLight ambient = new(Mats.C(.55, .5, .52));
    readonly PointLight screenLight = new(Colors.Black, new Point3D(0, 0, 0)) { Range = 32, ConstantAttenuation = 1, LinearAttenuation = 0.05, QuadraticAttenuation = 0.004 };
    readonly TranslateTransform3D markerT = new();
    GeometryModel3D? marker;
    HashSet<int> shownRooms = new();

    // Player
    double px = 0, py = 0, pz = 3, yaw, pitch;
    (int room, int row, int seat)? seated;
    readonly HashSet<Key> keys = new();
    Point? lastMouse;
    DateTime lastRender = DateTime.UtcNow;
    DateTime lastMouseMove = DateTime.UtcNow;
    double time;
    double houseTarget = 1, house = 1;

    // Tickets & screening
    CinemaTicket? ticket;
    MediaEntry? selectedFilm;
    Room? selectedRoom;
    (int row, int seat)? selectedSeat;
    LibVLC? libVLC;
    MediaPlayer? player;
    VideoFrames? frames;
    byte[]? frameBuf, stereoBuf;
    WriteableBitmap? stereoBitmap;
    StereoConverter? stereo;
    readonly FourDXEngine fourDX = new();
    // Playback-clock event timeline. No semantic detector feeds it yet, so real
    // films load an empty track and only the conservative motion fallback runs.
    readonly Auto4DXScheduler timeline = new();
    BHapticsClient? tactsuit;
    // ZMF roller-coaster intro, YouTube presentations and the 4DX screen layer.
    CoasterView? coaster;
    double coasterTime;
    bool coasterRunning;
    readonly HashSet<int> spokenLines = new();
    System.Speech.Synthesis.SpeechSynthesizer? voice;
    YouTubePresenter? presenter;
    Format presentationFormat = Format.TwoD;
    double lastFxSend;
    readonly ScreenFx screenFx = new();
    (double x, double y, double pitch, double yaw)? rideSeat;
    double rideRoll;
    LoopbackSound? loopback;
    double fxWater, fxWind, fxFlash;
    bool reclined;
    double reclineBlend;
    JellyfinClient? api;
    string mediaSourceId = "";
    string? playSessionId;
    bool reportedStart, ended, loadedOnce, fullscreen;
    double partyStart;
    (DateTime when, double seconds)? anchor;
    DateTime lastReport = DateTime.MinValue;
    CancellationTokenSource? preshowCts;

    public string? ItemId => ticket?.Film.Id;

    public CinemaWindow(AppConfig config, Func<ServerConfig, JellyfinClient> clientFor, List<MediaEntry> catalog,
                        MediaEntry? preselect = null, SyncPlayClient? party = null, MediaEntry? partyFilm = null, double partyStart = 0,
                        string? shotName = null, string? shotPath = null)
    {
        InitializeComponent();
        this.config = config;
        this.clientFor = clientFor;
        this.catalog = catalog;
        this.party = party;
        this.partyStart = partyStart;
        this.shotName = shotName;
        this.shotPath = shotPath;
        featured = RotationDirector.Select(catalog, RotationDirector.PeriodIndex(DateTime.UtcNow));
        fourDX.Detected += e => _ = tactsuit?.SendEventAsync(e.Kind, e.Strength);
        BuildScene();
        UpdateWallet();
        if (partyFilm != null)
        {
            var room = Rooms.BestFor(partyFilm);
            ticket = new CinemaTicket(partyFilm, room.Id, 4, 3, Format.TwoD, 0);
        }
        else if (preselect != null)
        {
            Loaded += (_, _) => OpenBoxOffice(preselect);
        }
    }

    // MARK: Scene

    Material Tex(string key)
    {
        if (!textures.TryGetValue(key, out var t))
        {
            t = new DynamicTexture(InitialTexture(key));
            textures[key] = t;
        }
        return t.Material;
    }

    ImageSource InitialTexture(string key)
    {
        var gold = Mats.C(1, .8, .35); var dark = Mats.C(.08, .02, .04);
        if (key == "sign.marquee") return Mats.Text("ZMF THEATERS+", 1100, 240, gold, Mats.C(.12, .02, .05), 110, gold);
        if (key == "sign.hall") return Mats.Text("AUDITORIUMS 01–12  →", 900, 110, Colors.White, dark, 66);
        if (key == "sign.boxoffice") return Mats.Text("BOX OFFICE", 900, 160, gold, dark, 104, gold);
        if (key == "sign.concessions") return Mats.Text("CONCESSIONS", 900, 160, gold, dark, 96, gold);
        if (key == "sign.menu") return Mats.Text("POPCORN Z$35 · SODA Z$25 · CANDY Z$20", 1040, 360, Colors.White, Mats.C(.05, .05, .05), 48, sub: "Slushies · Nachos · Hot food · Ice cream");
        if (key == "sign.kiosk") return Mats.Text("TICKETS", 256, 190, Colors.White, Mats.C(.1, .3, .8), 52);
        if (key == "sign.4dx")
            return Mats.Text("ZMF 4DX", 1000, 480, Mats.C(.3, .95, 1), Mats.C(.02, .08, .15), 150, Mats.C(.3, .9, 1),
                "MOTION · RUMBLE · STROBE · SMOKE · TACTSUIT AIR\n" + FourDXPreview.Teaser(config.Force4DX));
        if (key.StartsWith("door."))
        {
            var id = int.Parse(key[5..]);
            var r = Rooms.Get(id);
            return Mats.Text($"{r.Code}  {r.Name.ToUpperInvariant()}{(r.Is3D ? "  3D" : "")}", 768, 260, WorldBuilder.Themes[id].Accent,
                Mats.Scale(WorldBuilder.Themes[id].Wall, .6), 52, WorldBuilder.Themes[id].Accent, featured.TryGetValue(id, out var f) ? f.Title : "Private screenings");
        }
        if (key.StartsWith("poster."))
        {
            var id = int.Parse(key[7..]);
            var title = featured.TryGetValue(id, out var f) ? f.Title : Rooms.Get(id).Name;
            return Mats.Text(title.ToUpperInvariant(), 400, 600, Colors.White, Mats.Scale(WorldBuilder.Themes[id].Accent, .55), 40);
        }
        return Mats.Text(key, 256, 128, Colors.White, Colors.Black, 24);
    }

    ImageSource IdleScreen(int id)
    {
        var r = Rooms.Get(id);
        var film = featured.TryGetValue(id, out var f) ? f.Title : "Choose any film for a private screening";
        return Mats.Text($"ROOM {r.Code} · {r.Name.ToUpperInvariant()}", 1200, 520, WorldBuilder.Themes[id].Accent, Colors.Black, 60, sub: film);
    }

    void BuildScene()
    {
        scene.Children.Add(ambient);
        scene.Children.Add(new DirectionalLight(Mats.C(.35, .32, .3), new Vector3D(-0.3, -1, 0.4)));
        scene.Children.Add(screenLight);
        scene.Children.Add(WorldBuilder.LobbyAndHall(Tex));
        scene.Children.Add(visibleRooms);
        var cube = WorldBuilder.UnitBox();
        for (int id = 1; id <= 12; id++)
        {
            var g = WorldBuilder.Room(id);
            var screenTex = new DynamicTexture(IdleScreen(id));
            screens[id] = screenTex;
            g.Children.Add(new GeometryModel3D(WorldBuilder.ScreenMesh(id), screenTex.Material) { BackMaterial = screenTex.Material });
            rooms[id] = g;
            // Sliding door panels in the hall.
            var side = id <= 6 ? -1 : 1;
            var x = side * (World.HallHalf + 0.12);
            var mid = World.RoomBaseZ(id) + (World.DoorZ0 + World.DoorZ1) / 2;
            var mat = Mats.Lit(Mats.Scale(WorldBuilder.Themes[id].Wall, 2.2));
            TranslateTransform3D Panel(double dz)
            {
                var t = new TranslateTransform3D(x, World.DoorHeight / 2, mid + dz);
                var tg = new Transform3DGroup();
                tg.Children.Add(new ScaleTransform3D(0.08, World.DoorHeight, 1.0));
                tg.Children.Add(t);
                scene.Children.Add(new GeometryModel3D(cube, mat) { BackMaterial = mat, Transform = tg });
                return t;
            }
            doors[id] = (Panel(-0.5), Panel(0.5));
        }
        var mgroup = new Transform3DGroup();
        mgroup.Children.Add(new ScaleTransform3D(0.28, 0.28, 0.28));
        mgroup.Children.Add(markerT);
        marker = new GeometryModel3D(cube, Mats.Glow(Mats.C(1, .8, .3))) { Transform = mgroup };
        SceneVisual.Content = scene;
        _ = LoadPostersAsync();
    }

    async Task LoadPostersAsync()
    {
        foreach (var (id, film) in featured)
        {
            if (!film.HasPrimary || string.IsNullOrEmpty(film.PosterUrl)) continue;
            try
            {
                using var http = new System.Net.Http.HttpClient();
                var bytes = await http.GetByteArrayAsync(film.PosterUrl);
                var img = new BitmapImage();
                img.BeginInit();
                img.StreamSource = new MemoryStream(bytes);
                img.DecodePixelWidth = 400;
                img.CacheOption = BitmapCacheOption.OnLoad;
                img.EndInit();
                img.Freeze();
                if (textures.TryGetValue($"poster.{id}", out var t)) t.Set(img);
            }
            catch { }
        }
    }

    void UpdateVisibleRooms()
    {
        var want = new HashSet<int>();
        var zone = World.Zone(px, pz);
        if (zone > 0) want.Add(zone);
        for (int id = 1; id <= 12; id++)
        {
            var (dx, dz) = World.DoorFront(id);
            if (doorOpen[id] > 0.02 && Math.Sqrt((px - dx) * (px - dx) + (pz - dz) * (pz - dz)) < 14) want.Add(id);
        }
        if (want.SetEquals(shownRooms)) return;
        visibleRooms.Children.Clear();
        foreach (var id in want) visibleRooms.Children.Add(rooms[id]);
        if (marker != null && ticket != null && want.Contains(ticket.Room) && seated == null) visibleRooms.Children.Add(marker);
        shownRooms = want;
    }

    // MARK: Lifecycle

    async void OnLoaded(object sender, RoutedEventArgs e)
    {
        VolumeBar.Value = config.Volume;
        FxHost.Content = screenFx.Layer;
        CompositionTarget.Rendering += OnFrame;
        BuildSeatGrid();
        if (shotName != null) { await RunShotAsync(); return; }
        tactsuit = new BHapticsClient();
        if (ticket != null && party != null)
        {
            // Joined a friend's party: take the party seat and wait for SyncPlay.
            var s = World.SeatPosition(ticket.Room, ticket.Row, ticket.Seat);
            px = s.X; pz = s.Z; py = s.Y;
            await SitAsync(ticket.Room, ticket.Row, ticket.Seat);
        }
        else Toast("Welcome to ZMF THEATERS+ · walk to the BOX OFFICE (left) and press E");
    }

    void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        CompositionTarget.Rendering -= OnFrame;
        preshowCts?.Cancel();
        StopPlayback();
        config.Save();
        _ = tactsuit?.DisposeAsync();
        stereo?.Dispose();
        try { voice?.Dispose(); } catch { }
        loopback?.Dispose();
    }

    // MARK: Frame loop

    void OnFrame(object? sender, EventArgs e)
    {
        var now = DateTime.UtcNow;
        var dt = Math.Min(0.1, (now - lastRender).TotalSeconds);
        lastRender = now;
        time += dt;

        if (seated == null) Move(dt);
        UpdateDoors(dt);
        UpdateVisibleRooms();
        UpdateVideo(dt);
        UpdateRideAndPresentation(dt);
        house += (houseTarget - house) * Math.Min(1, dt * 0.45);

        // Lighting: house lights, 4DX strobe, screen spill.
        var zone = World.Zone(px, pz);
        double level = zone > 0 && ticket?.Room == zone ? house : 1;
        var strobe = fourDX.Strobe;
        double amb = 0.18 + 0.42 * level;
        ambient.Color = Mats.C(amb + strobe * .8, amb * .93 + strobe * .78, amb * .95 + strobe * .75);
        Smoke.Opacity = Math.Min(0.35, fourDX.Smoke * 0.3);

        // Camera (with 4DX motion seat when seated). The ride/presentation
        // motion overrides the picture-motion fallback while it runs.
        var seatMotion = rideSeat ?? fourDX.Seat;
        reclineBlend += ((seated != null && reclined ? 1 : 0) - reclineBlend) * Math.Min(1, dt * 1.8);
        double ey = py + (seated != null ? 1.12 : World.EyeHeight);
        double cx = px, cz = pz;
        if (seated is { } s)
        {
            // Recline tilts your head back and lowers it; the eye stays in
            // front of the backrest (x + 0.30) so the view never clips into it.
            var sp = World.SeatPosition(s.room, s.row, s.seat);
            var back = 0.18 + 0.02 * reclineBlend;
            cx = sp.X - Math.Sin(World.ScreenYaw(s.room)) * back + seatMotion.x;
            cz = sp.Z - Math.Cos(World.ScreenYaw(s.room)) * back;
            ey = sp.Y + 1.12 - 0.1 * reclineBlend + seatMotion.y + Math.Sin(time * 1.35) * 0.006;
        }
        double cyaw = yaw + seatMotion.yaw * Math.PI / 180, cpitch = pitch + seatMotion.pitch * Math.PI / 180 + 0.16 * reclineBlend;
        Cam.Position = new Point3D(cx, ey, cz);
        var look = new Vector3D(Math.Sin(cyaw) * Math.Cos(cpitch), Math.Sin(cpitch), Math.Cos(cyaw) * Math.Cos(cpitch));
        Cam.LookDirection = look;
        // The motion seat rolls the view (banking, explosions, coaster turns).
        var rollDeg = seated != null ? (rideSeat != null ? rideRoll : fourDX.Roll) : 0;
        var rightV = Vector3D.CrossProduct(look, new Vector3D(0, 1, 0));
        if (rightV.LengthSquared > 1e-6) rightV.Normalize();
        var upV = Vector3D.CrossProduct(rightV, look);
        var rr = rollDeg * Math.PI / 180;
        Cam.UpDirection = upV * Math.Cos(rr) + rightV * Math.Sin(rr);
        Cam.FieldOfView = seated != null ? 62 : 75;

        markerT.OffsetX = 0; // updated below
        if (ticket != null)
        {
            var sp = World.SeatPosition(ticket.Room, ticket.Row, ticket.Seat);
            markerT.OffsetX = sp.X; markerT.OffsetY = sp.Y + 1.75 + Math.Sin(time * 4) * 0.08; markerT.OffsetZ = sp.Z;
        }
        UpdateHud(zone);

        // Controls fade out while watching; move the mouse to bring them back.
        if (seated != null)
        {
            var idle = (now - lastMouseMove).TotalSeconds > 3 && player?.IsPlaying == true && !Controls.IsMouseOver;
            Controls.Visibility = Visibility.Visible;
            Controls.Opacity += ((idle ? 0 : 1) - Controls.Opacity) * Math.Min(1, dt * 6);
            Controls.IsHitTestVisible = !idle;
            HelpText.Opacity = Controls.Opacity;
            Cursor = idle ? Cursors.None : null;
        }
        else { Controls.Visibility = Visibility.Collapsed; HelpText.Opacity = 1; Cursor = null; }
    }

    void Move(double dt)
    {
        double f = 0, r = 0;
        if (keys.Contains(Key.W) || keys.Contains(Key.Up)) f += 1;
        if (keys.Contains(Key.S) || keys.Contains(Key.Down)) f -= 1;
        if (keys.Contains(Key.D) || keys.Contains(Key.Right)) r += 1;
        if (keys.Contains(Key.A) || keys.Contains(Key.Left)) r -= 1;
        if (f == 0 && r == 0) return;
        var speed = (keys.Contains(Key.LeftShift) ? 5.5 : 3.4) * dt;
        double fx = Math.Sin(yaw), fz = Math.Cos(yaw);
        double rx = -fz, rz = fx;   // screen-right = cross(forward, up)
        double nx = px + (fx * f + rx * r) * speed, nz = pz + (fz * f + rz * r) * speed;
        bool Open(int id) => doorOpen[id] > 0.6;
        if (!World.Walkable(nx, nz, Open))
        {
            if (World.Walkable(nx, pz, Open)) nz = pz;
            else if (World.Walkable(px, nz, Open)) nx = px;
            else return;
        }
        px = nx; pz = nz;
        py += (World.GroundHeight(px, pz) - py) * Math.Min(1, dt * 10);
    }

    void UpdateDoors(double dt)
    {
        var zone = World.Zone(px, pz);
        for (int id = 1; id <= 12; id++)
        {
            var (dx, dz) = World.DoorFront(id);
            var d = Math.Sqrt((px - dx) * (px - dx) + (pz - dz) * (pz - dz));
            var bz = World.RoomBaseZ(id);
            bool doorway = Math.Abs(px) > 3.8 && Math.Abs(px) < 5.3 && (id <= 6) == (px < 0) && pz > bz + World.DoorZ0 && pz < bz + World.DoorZ1;
            bool allowed = config.AllDoorsUnlocked || ticket?.Room == id || zone == id || doorway;
            var target = allowed && d < 5 ? 1.0 : 0.0;
            doorOpen[id] += (target - doorOpen[id]) * Math.Min(1, dt * 4);
            var mid = World.RoomBaseZ(id) + (World.DoorZ0 + World.DoorZ1) / 2;
            doors[id].a.OffsetZ = mid - (0.5 + doorOpen[id] * 0.95);
            doors[id].b.OffsetZ = mid + (0.5 + doorOpen[id] * 0.95);
        }
    }

    string? Interactable(int zone)
    {
        double Dist(double x, double z) => Math.Sqrt((px - x) * (px - x) + (pz - z) * (pz - z));
        if (zone == 0)
        {
            if (Dist(-11, 11) < 2.4 || Dist(-6, 15) < 1.6 || Dist(6, 15) < 1.6) return "boxoffice";
            if (Dist(11, 11) < 2.4) return "concessions";
            if (Dist(-15, 16.6) < 3) return "4dx";
        }
        if (zone > 0 && ticket?.Room == zone && seated == null)
        {
            var s = World.SeatPosition(ticket.Room, ticket.Row, ticket.Seat);
            if (Dist(s.X, s.Z) < 1.8) return "seat";
        }
        return null;
    }

    void UpdateHud(int zone)
    {
        ZoneText.Text = zone switch { 0 => "Lobby", -1 => "Auditorium Hall", _ => $"Room {Rooms.Get(zone).Code} · {Rooms.Get(zone).Name}" };
        var it = seated == null ? Interactable(zone) : null;
        PromptChip.Visibility = it == null ? Visibility.Collapsed : Visibility.Visible;
        PromptText.Text = it switch
        {
            "boxoffice" => "E · Box Office — buy a ticket",
            "concessions" => "E · Concessions — popcorn Z$35",
            "4dx" => "ZMF 4DX · " + FourDXPreview.Teaser(config.Force4DX),
            "seat" => $"E · Sit in your seat {ticket!.SeatLabel}",
            _ => "",
        };
        if (ticket != null)
        {
            TicketChip.Visibility = Visibility.Visible;
            TicketText.Text = $"{ticket.Film.Title} · {ticket.FormatLabel} · Room {Rooms.Get(ticket.Room).Code} · {ticket.SeatLabel}";
        }
        // Guidance arrow toward the ticketed seat.
        if (ticket != null && seated == null)
        {
            double gx, gz; string label;
            if (zone == ticket.Room) { var s = World.SeatPosition(ticket.Room, ticket.Row, ticket.Seat); gx = s.X; gz = s.Z; label = $"Seat {ticket.SeatLabel}"; }
            else if (zone > 0) { var rr = World.RoomRect(zone); gx = zone <= 6 ? rr.x1 : rr.x0; gz = rr.z0 + 7; label = "Exit to the hall"; }
            else if (zone == -1) { (gx, gz) = World.DoorFront(ticket.Room); label = $"Room {Rooms.Get(ticket.Room).Code}"; }
            else { gx = 0; gz = 20; label = $"Auditorium Hall → Room {Rooms.Get(ticket.Room).Code}"; }
            var angTarget = Math.Atan2(gx - px, gz - pz);
            var rel = angTarget - yaw;
            while (rel > Math.PI) rel -= 2 * Math.PI;
            while (rel < -Math.PI) rel += 2 * Math.PI;
            GuideRotate.Angle = -rel * 180 / Math.PI;
            GuideText.Text = $"{label} · {Math.Sqrt((gx - px) * (gx - px) + (gz - pz) * (gz - pz)):0} m";
            GuideChip.Visibility = Visibility.Visible;
        }
        else GuideChip.Visibility = Visibility.Collapsed;
        if (seated != null)
        {
            var status = ticket?.Format switch
            {
                Format.ThreeD => stereo?.Status ?? "3D",
                Format.FourDX => "Auto 4DX · " + fourDX.Status,
                Format.FourDX3D => (stereo?.Status ?? "3D preparing") + " · Auto 4DX · " + fourDX.Status,
                _ => "",
            };
            StatusLine.Text = status;
        }
        else StatusLine.Text = "";
    }

    void UpdateWallet() => WalletText.Text = $"Z${config.Balance:N0}  ·  ZMF CASH";

    async void Toast(string text)
    {
        ToastText.Text = text;
        ToastChip.Visibility = Visibility.Visible;
        await Task.Delay(3500);
        if (ToastText.Text == text) ToastChip.Visibility = Visibility.Collapsed;
    }

    // MARK: Input

    void OnKeyDown(object sender, KeyEventArgs e)
    {
        if (BoxOffice.Visibility == Visibility.Visible) { if (e.Key == Key.Escape) OnCloseBoxOffice(this, new RoutedEventArgs()); return; }
        keys.Add(e.Key);
        lastMouseMove = DateTime.UtcNow;
        switch (e.Key)
        {
            case Key.E: _ = Interact(); break;
            case Key.Q: if (seated != null) Stand(); break;
            case Key.R: ToggleRecline(); break;
            case Key.F: ToggleFullscreen(); break;
            case Key.Space: if (seated != null) TogglePlay(); break;
            case Key.Enter: preshowCts?.Cancel(); break;
            case Key.Escape: if (fullscreen) ToggleFullscreen(); else if (seated != null) Stand(); else Close(); break;
            case Key.OemComma: if (seated != null) SeekTo(CurrentSeconds - 10); break;
            case Key.OemPeriod: if (seated != null) SeekTo(CurrentSeconds + 30); break;
        }
    }

    void OnKeyUp(object sender, KeyEventArgs e) => keys.Remove(e.Key);

    void OnMouseDown(object sender, MouseButtonEventArgs e)
    {
        if (BoxOffice.Visibility == Visibility.Visible || e.OriginalSource is not (Window or Grid or Viewport3D or Image or System.Windows.Shapes.Rectangle)) return;
        lastMouse = e.GetPosition(this);
        // Looking around never skips the ride or a presentation (Enter does).
        if (!coasterRunning && presenter?.Active != true) preshowCts?.Cancel();
        CaptureMouse();
    }

    void OnMouseUp(object sender, MouseButtonEventArgs e)
    {
        lastMouse = null;
        ReleaseMouseCapture();
    }

    void OnMouseMove(object sender, MouseEventArgs e)
    {
        lastMouseMove = DateTime.UtcNow;
        if (lastMouse is not Point last) return;
        var p = e.GetPosition(this);
        yaw -= (p.X - last.X) * 0.005;
        pitch = Math.Clamp(pitch - (p.Y - last.Y) * 0.005, -1.1, 1.1);
        if (seated is { } s)
        {
            var baseYaw = World.ScreenYaw(s.room);
            yaw = baseYaw + Math.Clamp(yaw - baseYaw, -1.3, 1.3);
        }
        lastMouse = p;
    }

    async Task Interact()
    {
        switch (Interactable(World.Zone(px, pz)))
        {
            case "boxoffice": OpenBoxOffice(null); break;
            case "concessions":
                if (config.Balance >= 35) { config.Balance -= 35; config.Popcorn++; UpdateWallet(); Toast("Popcorn purchased! Enjoy it in your seat."); }
                else Toast("Not enough ZMF CASH.");
                break;
            case "seat": await SitAsync(ticket!.Room, ticket.Row, ticket.Seat); break;
        }
    }

    // MARK: Box office

    void OpenBoxOffice(MediaEntry? preselect)
    {
        var choices = featured.OrderBy(k => k.Key).Select(k => new FilmChoice { Film = k.Value, Room = Rooms.Get(k.Key), Featured = true }).ToList();
        choices.AddRange(catalog.Where(m => m.Type == "Movie" && !featured.Values.Contains(m)).Select(m => new FilmChoice { Film = m, Room = Rooms.BestFor(m) }));
        FilmList.Tag = choices;
        FilmList.ItemsSource = choices;
        Fmt4DX.IsEnabled = FourDXPreview.Active(config.Force4DX);
        Fmt4DX.Content = Fmt4DX.IsEnabled ? "4DX  Z$400" : "4DX  (Oct 27–28)";
        if (preselect != null) FilmList.SelectedItem = choices.FirstOrDefault(c => c.Film.Id == preselect.Id && c.Film.Server.Id == preselect.Server.Id);
        if (catalog.Count == 0) SelTitle.Text = "No films yet — add your Jellyfin server in the main window.";
        BoxOffice.Visibility = Visibility.Visible;
        keys.Clear();
    }

    void OnCloseBoxOffice(object sender, RoutedEventArgs e) => BoxOffice.Visibility = Visibility.Collapsed;

    void OnFilmSearch(object sender, TextChangedEventArgs e)
    {
        if (FilmList.Tag is not List<FilmChoice> all) return;
        var q = FilmSearch.Text.Trim();
        FilmList.ItemsSource = q.Length == 0 ? all : all.Where(c => c.Film.Title.Contains(q, StringComparison.OrdinalIgnoreCase)).ToList();
    }

    void OnFilmSelected(object sender, SelectionChangedEventArgs e)
    {
        if (FilmList.SelectedItem is not FilmChoice c) return;
        selectedFilm = c.Film;
        selectedRoom = c.Room;
        SelTitle.Text = c.Film.Title;
        SelRoom.Text = c.Room.Title;
        if (c.Room.Is3D && !Fmt3D.IsChecked.GetValueOrDefault()) Fmt3D.IsChecked = true;
        UpdatePrice();
    }

    void OnFormatChanged(object sender, RoutedEventArgs e)
    {
        if (FormatNote == null) return;
        FormatNote.Text = ChosenFormat switch
        {
            Format.ThreeD => "ZMF DepthCinema AI converts the film to red/cyan 3D live (Depth Anything V2 on your GPU). Wear red-left / cyan-right glasses. Converted 3D approximates depth.",
            Format.FourDX => "Real-time 4DX: the chair follows the film's camera motion, and the soundtrack triggers hits, booms and debris with jolts, smoke, embers and TactSuit patterns.",
            Format.FourDX3D => "AI red/cyan depth conversion plus real-time 4DX from the film's motion and soundtrack.",
            _ => "Plays exactly as mastered.",
        };
        UpdatePrice();
    }

    Format ChosenFormat => Fmt4DX3D.IsChecked == true ? Format.FourDX3D : Fmt3D.IsChecked == true ? Format.ThreeD : Fmt4DX.IsChecked == true ? Format.FourDX : Format.TwoD;

    int PriceFor(Format f, int row) =>
        (f switch { Format.ThreeD => 225, Format.FourDX or Format.FourDX3D => 400, _ => 150 }) + (row is 4 or 5 ? 200 : 0);

    void BuildSeatGrid()
    {
        SeatGrid.Children.Clear();
        for (int r = 0; r < 8; r++)
            for (int s = 0; s < 8; s++)
            {
                var row = r; var seat = s;
                var b = new ToggleButton
                {
                    Content = $"{(char)('A' + r)}{s + 1}", Margin = new Thickness(2), FontSize = 10,
                    Background = r is 4 or 5 ? new SolidColorBrush(Color.FromRgb(0x8A, 0x6A, 0x20)) : new SolidColorBrush(Color.FromRgb(0x3A, 0x22, 0x2A)),
                    Foreground = Brushes.White,
                };
                b.Checked += (_, _) =>
                {
                    foreach (var other in SeatGrid.Children.OfType<ToggleButton>()) if (other != b) other.IsChecked = false;
                    selectedSeat = (row, seat);
                    UpdatePrice();
                };
                SeatGrid.Children.Add(b);
            }
    }

    void UpdatePrice()
    {
        if (PriceText == null) return;
        if (selectedSeat is { } s && selectedFilm != null)
        {
            var price = PriceFor(ChosenFormat, s.row);
            PriceText.Text = $"Seat {(char)('A' + s.row)}{s.seat + 1} · {ChosenFormat switch { Format.ThreeD => "Auto 3D", Format.FourDX => "Auto 4DX", Format.FourDX3D => "Auto 4DX 3D", _ => "2D" }}{(s.row is 4 or 5 ? " · VIP" : "")} · Z${price}  (balance Z${config.Balance:N0})";
            BuyButton.IsEnabled = config.Balance >= price;
        }
        else { PriceText.Text = "Choose a film and a seat"; BuyButton.IsEnabled = false; }
    }

    void OnBuy(object sender, RoutedEventArgs e)
    {
        if (selectedFilm == null || selectedRoom == null || selectedSeat is not { } s) return;
        var fmt = ChosenFormat;
        if (fmt.Uses4DX() && !FourDXPreview.Active(config.Force4DX)) fmt = Format.TwoD;
        var price = PriceFor(fmt, s.row);
        if (config.Balance < price) return;
        config.Balance -= price;
        config.Save();
        ticket = new CinemaTicket(selectedFilm, selectedRoom.Id, s.row, s.seat, fmt, price);
        shownRooms.Clear();
        UpdateWallet();
        BoxOffice.Visibility = Visibility.Collapsed;
        Toast($"{ticket.FormatLabel} ticket · Room {selectedRoom.Code} · Seat {ticket.SeatLabel}" + (fmt.UsesDepth() ? " · grab your red/cyan glasses" : ""));
    }

    // MARK: Seating & screening

    async Task SitAsync(int room, int row, int seat)
    {
        seated = (room, row, seat);
        yaw = World.ScreenYaw(room);
        pitch = 0;
        shownRooms.Clear();
        if (ticket == null) return;
        api = clientFor(ticket.Film.Server);
        if (ticket.Format.UsesDepth() && stereo == null)
        {
            stereo = new StereoConverter();
            _ = stereo.InitAsync(new Progress<string>(m => Toast(m)));
        }
        if (ticket.Format.Uses4DX() && tactsuit != null) await tactsuit.ConnectAsync();
        if (player != null) return; // already screening; just sat back down
        if (party == null && config.Preshow) await PreshowAsync();
        await StartPlaybackAsync();
    }

    void Stand()
    {
        if (seated is not { } s) return;
        var sp = World.SeatPosition(s.room, s.row, s.seat);
        px = sp.X - Math.Sin(World.ScreenYaw(s.room)) * 0.9;
        pz = sp.Z;
        py = sp.Y;
        seated = null;
        reclined = false;
        shownRooms.Clear();
    }

    void ToggleRecline()
    {
        if (seated == null) return;
        reclined = !reclined;
        ReclineButton.Content = reclined ? "Sit up" : "Recline";
    }

    void OnRecline(object sender, RoutedEventArgs e) => ToggleRecline();

    void OnStand(object sender, RoutedEventArgs e) => Stand();

    void Slide(int room, string top, string big, string bottom) =>
        screens[room].Set(Mats.Text(big, 1200, 520, Mats.C(1, .8, .3), Mats.C(.02, .02, .03), 96, sub: top + "\n" + bottom));

    async Task PreshowAsync()
    {
        if (ticket == null) return;
        preshowCts = new CancellationTokenSource();
        var ct = preshowCts.Token;
        var r = Rooms.Get(ticket.Room);
        try
        {
            houseTarget = 0.7;
            Slide(ticket.Room, "WELCOME TO ZMF THEATERS+", r.Name.ToUpperInvariant(), $"Now presenting: {ticket.Film.Title} · Seat {ticket.SeatLabel}");
            await Task.Delay(6000, ct);
            await PlayPresentationsAsync(ct);
            houseTarget = 0.35;
            Slide(ticket.Room, "A FRIENDLY REMINDER", "Please silence your phone", ticket.Format.UsesDepth() ? "Put on your red/cyan glasses" : "Sit back, relax and enjoy the show");
            await Task.Delay(4000, ct);
            if (config.CoasterIntro) await RunCoasterAsync(ct);
            houseTarget = 0.1;
            for (int n = config.CoasterIntro ? 3 : 10; n >= 1; n--)
            {
                Slide(ticket.Room, "FEATURE PRESENTATION", n.ToString(), ticket.Film.Title);
                await Task.Delay(1000, ct);
            }
        }
        catch (TaskCanceledException) { }
        coasterRunning = false;
        rideSeat = null;
        try { voice?.SpeakAsyncCancelAll(); } catch { }
        preshowCts = null;
    }

    /// Owner-added YouTube presentations, each in its own 2D/3D/4DX/4DX 3D format.
    async Task PlayPresentationsAsync(CancellationToken ct)
    {
        if (ticket == null || config.Presentations.Count == 0) return;
        presenter ??= new YouTubePresenter();
        PresenterHost.Content = presenter.Panel;
        var skipAll = false;
        void OnSkip() => skipAll = true;
        presenter.SkipAllRequested += OnSkip;
        try
        {
            foreach (var p in config.Presentations.ToList())
            {
                if (skipAll || ct.IsCancellationRequested) break;
                presentationFormat = Enum.TryParse<Format>(p.Format, out var f) ? f : Format.TwoD;
                houseTarget = 0.12;
                Slide(ticket.Room, "ZMF PRESENTS", p.Title, presentationFormat switch { Format.FourDX => "4DX presentation", Format.FourDX3D => "4DX 3D presentation", Format.ThreeD => "3D presentation · glasses on", _ => "Presentation" });
                await presenter.PlayAsync(p.VideoId, p.Title, presentationFormat.UsesDepth(), presentationFormat.Uses4DX(), ct);
            }
        }
        finally
        {
            presenter.SkipAllRequested -= OnSkip;
            rideSeat = null;
            presentationFormat = Format.TwoD;
        }
    }

    /// The original ZMF THEATERS roller-coaster ride on the auditorium screen.
    async Task RunCoasterAsync(CancellationToken ct)
    {
        if (ticket == null) return;
        if (coaster == null)
        {
            coaster = new CoasterView();
            Canvas.SetLeft(coaster.Host, -20000);
            Offscreen.Children.Add(coaster.Host);
        }
        screens[ticket.Room].SetBrush(new VisualBrush(coaster.Host) { Stretch = Stretch.Fill });
        houseTarget = 0.06;
        coasterTime = 0;
        spokenLines.Clear();
        coasterRunning = true;
        try { await Task.Delay(TimeSpan.FromSeconds(ZMFCoasterTrack.Shared.Duration), ct); }
        finally { coasterRunning = false; rideSeat = null; }
    }

    void Speak(string line)
    {
        if (!config.CoasterVoice) return;
        try
        {
            voice ??= new System.Speech.Synthesis.SpeechSynthesizer { Rate = -1, Volume = 90 };
            voice.SpeakAsync(line);
        }
        catch { config.CoasterVoice = false; }   // no speech engine available
    }

    /// Advances the coaster, drives 4DX for rides/presentations and the screen layer.
    void UpdateRideAndPresentation(double dt)
    {
        double water = 0, wind = 0, flash = 0;
        rideSeat = null;
        bool fourDXTicket = ticket?.Format.Uses4DX() == true;
        if (coasterRunning && coaster != null)
        {
            coasterTime += dt;
            coaster.Update(coasterTime);
            var script = ZMFCoasterTrack.Shared.Script;
            for (int i = 0; i < script.Length; i++)
                if (coasterTime >= script[i].at && spokenLines.Add(i)) Speak(script[i].line);
            if (fourDXTicket)
            {
                var c = ZMFCoasterTrack.Shared.CueAt(coasterTime);
                rideSeat = (c.Side, c.Lift, c.Pitch * 180 / Math.PI * 0.6, 0);
                rideRoll = c.Roll * 180 / Math.PI * 0.6;
                water = c.Water; wind = c.Wind; flash = c.Flash;
                _ = tactsuit?.SendAsync(c.Rumble, 0);
            }
        }
        else if (presenter?.Active == true && presentationFormat.Uses4DX())
        {
            if (presenter.Playing)
            {
                var m = FourDXEngine.PresentationMotion(presenter.Time);
                rideSeat = (m.x, m.y, m.pitch, m.yaw);
                rideRoll = m.yaw * 0.4;
                wind = m.wind; water = m.water;
            }
            if (time - lastFxSend > 0.05)
            {
                lastFxSend = time;
                var s = rideSeat ?? default;
                presenter.SendFx(water, wind, 0, -s.x * 2, s.y * 2, -s.yaw / 57.3 * 0.3);
            }
        }
        else if (fourDXTicket && player?.IsPlaying == true)
        {
            wind = fourDX.Wind;   // wind follows tracked camera speed and blasts
            if (fourDX.LastEvent is { Kind: SoundEventKind.Boom, WithFlash: true } && fourDX.Shock > 0.6) flash = 0.25 * fourDX.Shock;
        }
        if (!config.ScreenEffects || seated == null) water = wind = flash = 0;
        if (!config.ScreenFlashes) flash = 0;
        fxWater = water; fxWind = wind; fxFlash = flash;
        screenFx.Update(dt, time, water, wind, flash, Root.ActualWidth, Root.ActualHeight);
        bool eventsOn = config.ScreenEffects && seated != null && fourDXTicket && player != null;
        screenFx.UpdateEvents(dt, time, eventsOn ? fourDX.Shock : 0, eventsOn ? fourDX.Embers : 0, eventsOn ? fourDX.Smoke : 0,
            eventsOn ? fourDX.Debris : 0, eventsOn ? fourDX.Hit : 0, Root.ActualWidth, Root.ActualHeight);
    }

    async Task StartPlaybackAsync()
    {
        if (ticket == null || api == null) return;
        Slide(ticket.Room, "FEATURE PRESENTATION", "Connecting…", ticket.Film.Title);
        try
        {
            var (url, sourceId, session) = await api.PlaybackAsync(ticket.Film.Server, ticket.Film.Id);
            mediaSourceId = sourceId;
            playSessionId = session;
            libVLC ??= new LibVLC("--no-video-title-show");
            player = new MediaPlayer(libVLC) { EnableHardwareDecoding = true };
            frames = new VideoFrames(ticket.Format.UsesDepth() ? 1280 : 1920);
            frames.Attach(player);
            player.Playing += (_, _) => Dispatcher.BeginInvoke(OnVlcPlaying);
            player.EndReached += (_, _) => Dispatcher.BeginInvoke(OnVlcEnded);
            player.EncounteredError += (_, _) => Dispatcher.BeginInvoke(() => Slide(ticket.Room, "PLAYBACK PROBLEM", "Couldn't open the stream", "Check that your Jellyfin server is reachable"));
            timeline.Load(ticket.Film.Id, Array.Empty<Auto4DXEvent>());
            using var media = new Media(libVLC, new Uri(url), ":network-caching=2000");
            var start = party != null ? partyStart : (ticket.Film.ResumeTicks > 600_000_000 ? ticket.Film.ResumeTicks / 10_000_000.0 : 0);
            if (start > 1) media.AddOption($":start-time={start.ToString(System.Globalization.CultureInfo.InvariantCulture)}");
            player.Volume = config.Volume;
            player.Play(media);
            houseTarget = 0.04;
        }
        catch (Exception ex)
        {
            Slide(ticket.Room, "PLAYBACK PROBLEM", "Couldn't start the stream", ex.Message);
            houseTarget = 0.6;
        }
    }

    void OnVlcPlaying()
    {
        if (!loadedOnce)
        {
            loadedOnce = true;
            LoadTracks();
            if (party != null) { player!.SetPause(true); _ = party.ReadyAsync(CurrentSeconds); }
        }
        if (!reportedStart && ticket != null && api != null)
        {
            reportedStart = true;
            _ = api.ReportAsync("/Sessions/Playing", ticket.Film.Id, mediaSourceId, playSessionId, CurrentSeconds, false);
        }
        PlayButton.Content = "⏸";
    }

    void OnVlcEnded()
    {
        ended = true;
        if (ticket != null && api != null)
            _ = api.ReportAsync("/Sessions/Playing/Stopped", ticket.Film.Id, mediaSourceId, playSessionId, (player?.Length ?? 0) / 1000.0, false);
        if (ticket != null) Slide(ticket.Room, "THANK YOU FOR VISITING", "ZMF THEATERS+", "House lights up · please exit safely");
        houseTarget = 1;
        fourDX.Reset();
        timeline.Stop();
        lastMouseMove = DateTime.UtcNow;
    }

    double CurrentSeconds => (player?.Time ?? 0) / 1000.0;

    void UpdateVideo(double dt)
    {
        if (player == null || frames == null || ticket == null || ended) return;
        bool got = frames.TryTakeFrame(ref frameBuf, out var w, out var h);
        if (got && frameBuf != null)
        {
            ImageSource shown;
            if (ticket.Format.UsesDepth() && stereo?.Ready == true)
            {
                stereo.Submit(frameBuf, w, h);
                if (stereoBuf == null || stereoBuf.Length != frameBuf.Length) stereoBuf = new byte[frameBuf.Length];
                if (stereo.Compose(frameBuf, stereoBuf, w, h))
                {
                    if (stereoBitmap == null || stereoBitmap.PixelWidth != w || stereoBitmap.PixelHeight != h)
                        stereoBitmap = new WriteableBitmap(w, h, 96, 96, PixelFormats.Bgr32, null);
                    stereoBitmap.WritePixels(new Int32Rect(0, 0, w, h), stereoBuf, w * 4, 0);
                    shown = stereoBitmap;
                }
                else shown = frames.Present(frameBuf, w, h);
            }
            else shown = frames.Present(frameBuf, w, h);
            var tex = screens[ticket.Room];
            if (Fullscreen.Source != shown) Fullscreen.Source = shown;
            if (!ReferenceEquals(lastShown, shown)) { tex.Set(shown); lastShown = shown; }

            // Screen light spills onto the seats with the picture's average colour.
            long r = 0, g = 0, b = 0; int n = 0;
            for (int y = h / 16; y < h; y += h / 8) for (int x = w / 16; x < w; x += w / 8) { int i = (y * w + x) * 4; b += frameBuf[i]; g += frameBuf[i + 1]; r += frameBuf[i + 2]; n++; }
            if (n > 0)
            {
                var c = World.Xf(ticket.Room).P(3.5, 1.2, 7);
                screenLight.Position = c;
                screenLight.Color = Color.FromRgb((byte)(r / n), (byte)(g / n), (byte)(b / n));
            }
        }
        if (ticket.Format.Uses4DX() && FourDXPreview.Active(config.Force4DX) && player.IsPlaying)
        {
            if (config.SoundEvents && loopback == null) { loopback = new LoopbackSound(); loopback.Start(); }
            fourDX.Analyse(got ? frameBuf : null, w, h, dt, config.FourDXIntensity, CurrentSeconds, loopback?.Running == true ? loopback.Drain() : null);
            timeline.Update(CurrentSeconds, true, dt);
            _ = tactsuit?.SendAsync(Math.Max(fourDX.Rumble, timeline.Level(Auto4DXTargets.Seat)), Math.Max(fourDX.Impact, timeline.Level(Auto4DXTargets.Haptics)));
        }
        else if (!player.IsPlaying) { fourDX.Reset(); timeline.Update(CurrentSeconds, false, dt); loopback?.Drain(); }

        var len = Math.Max(1, player.Length / 1000.0);
        TimeText.Text = $"{Fmt(CurrentSeconds)} / {Fmt(len)}";
        if (!SeekBar.IsMouseCaptureWithin) { SeekBar.Maximum = len; SeekBar.Value = CurrentSeconds; }
        if (reportedStart && api != null && (DateTime.UtcNow - lastReport).TotalSeconds > 10)
        {
            lastReport = DateTime.UtcNow;
            _ = api.ReportAsync("/Sessions/Playing/Progress", ticket.Film.Id, mediaSourceId, playSessionId, CurrentSeconds, !player.IsPlaying);
        }
        if (party != null) CorrectDrift();
    }

    ImageSource? lastShown;

    static string Fmt(double s)
    {
        var ts = TimeSpan.FromSeconds(s);
        return ts.TotalHours >= 1 ? ts.ToString(@"h\:mm\:ss") : ts.ToString(@"m\:ss");
    }

    void StopPlayback()
    {
        if (reportedStart && !ended && ticket != null && api != null)
            _ = api.ReportAsync("/Sessions/Playing/Stopped", ticket.Film.Id, mediaSourceId, playSessionId, CurrentSeconds, true);
        var p = player; var f = frames; var lib = libVLC;
        player = null; frames = null; libVLC = null;
        timeline.Stop();
        loopback?.Dispose(); loopback = null;
        if (p == null) return;
        ThreadPool.QueueUserWorkItem(_ =>
        {
            p.Stop();
            p.Dispose();
            f?.Dispose();
            lib?.Dispose();
        });
    }

    void LoadTracks()
    {
        if (player == null) return;
        AudioBox.ItemsSource = player.AudioTrackDescription;
        AudioBox.SelectedValuePath = "Id";
        AudioBox.SelectedValue = player.AudioTrack;
        SubBox.ItemsSource = player.SpuDescription;
        SubBox.SelectedValuePath = "Id";
        SubBox.SelectedValue = player.Spu;
    }

    void OnAudioChanged(object sender, SelectionChangedEventArgs e) { if (AudioBox.SelectedValue is int id) player?.SetAudioTrack(id); }
    void OnSubChanged(object sender, SelectionChangedEventArgs e) { if (SubBox.SelectedValue is int id) player?.SetSpu(id); }

    void OnVolume(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        config.Volume = (int)VolumeBar.Value;
        if (player != null) player.Volume = config.Volume;
    }

    void OnPlayPause(object sender, RoutedEventArgs e) => TogglePlay();
    void OnBack(object sender, RoutedEventArgs e) => SeekTo(CurrentSeconds - 10);
    void OnForward(object sender, RoutedEventArgs e) => SeekTo(CurrentSeconds + 30);
    void OnSeekRelease(object sender, MouseButtonEventArgs e) => SeekTo(SeekBar.Value);
    void OnFullscreen(object sender, RoutedEventArgs e) => ToggleFullscreen();

    void ToggleFullscreen()
    {
        if (player == null) return;
        fullscreen = !fullscreen;
        Fullscreen.Visibility = fullscreen ? Visibility.Visible : Visibility.Collapsed;
        View.Visibility = fullscreen ? Visibility.Hidden : Visibility.Visible;
    }

    void TogglePlay()
    {
        if (player == null) return;
        if (party?.InGroup == true) { _ = player.IsPlaying ? party.PauseAsync() : party.UnpauseAsync(); return; }
        player.Pause();
        houseTarget = player.IsPlaying ? 0.45 : 0.04;
        PlayButton.Content = player.IsPlaying ? "▶" : "⏸";
    }

    void SeekTo(double seconds)
    {
        if (player == null) return;
        fourDX.Reset();
        seconds = Math.Clamp(seconds, 0, Math.Max(0, player.Length / 1000.0 - 1));
        if (party?.InGroup == true) { _ = party.SeekAsync(seconds); return; }
        player.Time = (long)(seconds * 1000);
        timeline.Seek(seconds);
    }

    // MARK: Watch party

    public void SetPartyMembers(IEnumerable<string> members)
    {
        var others = members.Where(m => ticket == null || m != ticket.Film.Server.Username).ToList();
        Toast(others.Count == 0 ? "Watch party · waiting for friends" : "Watching with " + string.Join(", ", others));
    }

    public void PartyAlign(double seconds)
    {
        if (player == null || !loadedOnce) { partyStart = seconds; return; }
        player.SetPause(true);
        player.Time = (long)(seconds * 1000);
        _ = party?.ReadyAsync(seconds);
    }

    public void PartyCommand(string command, DateTime whenServer, double position)
    {
        if (party == null || player == null) return;
        switch (command)
        {
            case "Unpause":
                var delay = (whenServer - party.ServerNow).TotalSeconds;
                anchor = (whenServer, position);
                player.Time = (long)((delay > 0 ? position : position - delay) * 1000);
                if (delay > 0) _ = Task.Delay(TimeSpan.FromSeconds(delay)).ContinueWith(_ => Dispatcher.BeginInvoke(() => player?.SetPause(false)));
                else player.SetPause(false);
                houseTarget = 0.04;
                break;
            case "Pause":
                anchor = null; player.SetRate(1); player.SetPause(true); player.Time = (long)(position * 1000); houseTarget = 0.45;
                break;
            case "Seek":
                anchor = null; player.SetPause(true); player.Time = (long)(position * 1000);
                _ = Task.Delay(800).ContinueWith(_ => party.ReadyAsync(position));
                break;
            case "Stop":
                anchor = null; player.SetPause(true);
                break;
        }
    }

    void CorrectDrift()
    {
        if (party == null || player == null || anchor is not { } a || !player.IsPlaying) return;
        var expected = a.seconds + (party.ServerNow - a.when).TotalSeconds;
        var drift = CurrentSeconds - expected;
        if (Math.Abs(drift) > 1.5) { player.Time = (long)(expected * 1000); player.SetRate(1); }
        else if (Math.Abs(drift) > 0.15) player.SetRate(drift > 0 ? 0.95f : 1.05f);
        else player.SetRate(1);
    }

    // MARK: CI screenshots

    async Task RunShotAsync()
    {
        switch (shotName)
        {
            case "lobby": px = 0; pz = 1.5; yaw = 0; pitch = 0.1; break;
            case "hall": px = 1.5; pz = 22; yaw = -0.15; break;
            case "room":
                var p = World.Xf(5).P(23, 0, 7); px = p.X; pz = p.Z; yaw = World.ScreenYaw(5); pitch = -0.12; break;
            case "seat":
                ticket = new CinemaTicket(new MediaEntry { Server = new ServerConfig(), Id = "demo", Title = "Preshow Demo" }, 9, 4, 3, Format.TwoD, 0);
                seated = (9, 4, 3); yaw = World.ScreenYaw(9); houseTarget = house = 0.35;
                var seatPos = World.SeatPosition(9, 4, 3); px = seatPos.X; pz = seatPos.Z;
                Slide(9, "WELCOME TO ZMF THEATERS+", "SCI-FI GALAXY", "Now presenting: Preshow Demo · Seat E4");
                break;
            case "recline":
                ticket = new CinemaTicket(new MediaEntry { Server = new ServerConfig(), Id = "demo", Title = "Preshow Demo" }, 9, 4, 3, Format.TwoD, 0);
                seated = (9, 4, 3); yaw = World.ScreenYaw(9); houseTarget = house = 0.35; reclined = true;
                var rp = World.SeatPosition(9, 4, 3); px = rp.X; pz = rp.Z;
                Slide(9, "RECLINED", "SCI-FI GALAXY", "Seat E4 · press R to sit up");
                break;
            case "coaster" or "coasterride" or "coastersplash":
                // 4DX ticket in Room 09 with the ZMF roller coaster on screen.
                config.CoasterVoice = false;
                ticket = new CinemaTicket(new MediaEntry { Server = new ServerConfig(), Id = "demo", Title = "Coaster Demo" }, 9, 4, 3, Format.FourDX, 0);
                seated = (9, 4, 3); yaw = World.ScreenYaw(9); houseTarget = house = 0.06;
                var cp = World.SeatPosition(9, 4, 3); px = cp.X; pz = cp.Z;
                coaster = new CoasterView();
                Canvas.SetLeft(coaster.Host, -20000);
                Offscreen.Children.Add(coaster.Host);
                screens[9].SetBrush(new VisualBrush(coaster.Host) { Stretch = Stretch.Fill });
                coasterTime = shotName == "coasterride" ? 30 : 19;
                if (shotName == "coastersplash")
                    for (double t = 20; t < ZMFCoasterTrack.Shared.RideDuration; t += 0.25)
                        if (ZMFCoasterTrack.Shared.PoseAt(t).InSplash) { coasterTime = t - 1.5; break; }
                coasterRunning = true;
                break;
        }
        py = World.GroundHeight(px, pz);
        shownRooms.Clear();
        await Task.Delay(2500);
        try
        {
            FrameworkElement target = shotName == "coasterride" && coaster != null ? coaster.Host : Root;
            var w = (int)Math.Max(1, target.ActualWidth); var h = (int)Math.Max(1, target.ActualHeight);
            var rtb = new RenderTargetBitmap(w, h, 96, 96, PixelFormats.Pbgra32);
            rtb.Render(target);
            var enc = new PngBitmapEncoder();
            enc.Frames.Add(BitmapFrame.Create(rtb));
            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(shotPath!))!);
            using var fs = File.Create(shotPath!);
            enc.Save(fs);
        }
        finally { Application.Current.Shutdown(0); }
    }
}


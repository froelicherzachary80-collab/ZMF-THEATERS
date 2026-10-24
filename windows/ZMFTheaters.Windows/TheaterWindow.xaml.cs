using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Media.Animation;
using System.Windows.Threading;
using LibVLCSharp.Shared;
using ZMFTheaters.Cinema;
using ZMFTheaters.Jellyfin;
using MediaPlayer = LibVLCSharp.Shared.MediaPlayer;

namespace ZMFTheaters;

/// A 2D cinema auditorium for Windows: curtains, a glowing screen, rows of
/// seats and house lights that dim for the feature. Playback is LibVLC, which
/// streams the original file from Jellyfin without transcoding. In a watch
/// party, Jellyfin SyncPlay drives play/pause/seek for everyone.
public partial class TheaterWindow : Window
{
    readonly JellyfinClient api;
    readonly MediaEntry item;
    readonly SyncPlayClient? party;
    readonly bool preshow;
    readonly AppConfig config;
    readonly Room room;
    readonly LibVLC libVLC;
    readonly MediaPlayer player;

    double startSeconds;
    string mediaSourceId = "";
    string? playSessionId;
    bool loadedOnce;
    bool reportedStart;
    bool ended;
    bool immersive;
    bool updatingTracks;
    (DateTime when, double seconds)? anchor;
    readonly DispatcherTimer uiTimer = new() { Interval = TimeSpan.FromMilliseconds(250) };
    readonly DispatcherTimer reportTimer = new() { Interval = TimeSpan.FromSeconds(10) };
    readonly DispatcherTimer driftTimer = new() { Interval = TimeSpan.FromSeconds(2) };
    DateTime lastMouse = DateTime.UtcNow;
    CancellationTokenSource? preshowCts;

    public string ItemId => item.Id;

    public TheaterWindow(JellyfinClient api, MediaEntry item, double startSeconds, SyncPlayClient? party, bool preshow, AppConfig config)
    {
        InitializeComponent();
        this.api = api;
        this.item = item;
        this.startSeconds = startSeconds;
        this.party = party;
        this.preshow = preshow;
        this.config = config;
        room = Rooms.BestFor(item);
        libVLC = new LibVLC("--no-video-title-show");
        player = new MediaPlayer(libVLC) { EnableMouseInput = false, EnableKeyInput = false };
        RoomTitle.Text = $"{room.Title}  ·  {item.DisplayTitle}";
        BuildSeats();

        player.Playing += (_, _) => Dispatcher.BeginInvoke(OnVlcPlaying);
        player.EndReached += (_, _) => Dispatcher.BeginInvoke(OnVlcEnded);
        player.EncounteredError += (_, _) => Dispatcher.BeginInvoke(() => ShowSlide("PLAYBACK PROBLEM", "The stream couldn't be opened", "Check that your Jellyfin server is reachable, then close and try again."));
        uiTimer.Tick += (_, _) => Tick();
        reportTimer.Tick += (_, _) => Report("/Sessions/Playing/Progress");
        driftTimer.Tick += (_, _) => CorrectDrift();
    }

    void BuildSeats()
    {
        for (int i = 0; i < 14; i++) SeatsBack.Children.Add(Seat(0.75));
        for (int i = 0; i < 11; i++) SeatsFront.Children.Add(Seat(1.0));
    }

    static Border Seat(double scale) => new()
    {
        Margin = new Thickness(6 * scale, 0, 6 * scale, 0),
        CornerRadius = new CornerRadius(18 * scale, 18 * scale, 4, 4),
        Background = new LinearGradientBrush(Color.FromRgb(0x3A, 0x10, 0x18), Color.FromRgb(0x12, 0x04, 0x08), 90),
        BorderBrush = new SolidColorBrush(Color.FromArgb(0x50, 0xFF, 0xC8, 0x4B)),
        BorderThickness = new Thickness(0, 1, 0, 0),
    };

    async void OnLoaded(object sender, RoutedEventArgs e)
    {
        Video.MediaPlayer = player;
        VolumeBar.Value = config.Volume;
        uiTimer.Start();
        if (party != null)
        {
            PartyBadge.Visibility = Visibility.Visible;
            PartyText.Text = "👥 Watch party · syncing…";
            SetPartyMembers(party.Members);
        }
        if (preshow) await RunPreshowAsync();
        await StartAsync();
    }

    // MARK: Preshow & lights

    void ShowSlide(string top, string big, string bottom)
    {
        SlidePanel.Visibility = Visibility.Visible;
        SlideTop.Text = top;
        SlideBig.Text = big;
        SlideBottom.Text = bottom;
    }

    void HideSlide() => SlidePanel.Visibility = Visibility.Collapsed;

    void Lights(double dim, double seconds)
    {
        Dimmer.BeginAnimation(OpacityProperty, new DoubleAnimation(dim, TimeSpan.FromSeconds(seconds)) { EasingFunction = new SineEase() });
        Glow.BeginAnimation(OpacityProperty, new DoubleAnimation(0.12 + dim * 0.3, TimeSpan.FromSeconds(seconds)));
    }

    async Task RunPreshowAsync()
    {
        preshowCts = new CancellationTokenSource();
        var ct = preshowCts.Token;
        try
        {
            Lights(0.25, 2);
            ShowSlide("WELCOME TO ZMF THEATERS+", room.Name.ToUpperInvariant(), $"Now presenting: {item.DisplayTitle}");
            await Task.Delay(6000, ct);
            ShowSlide("A FRIENDLY REMINDER", "Please silence your phone", "Sit back, relax and enjoy the show");
            Lights(0.55, 4);
            await Task.Delay(4500, ct);
            Lights(0.85, 8);
            for (int n = 10; n >= 1; n--)
            {
                ShowSlide("FEATURE PRESENTATION", n.ToString(), item.DisplayTitle);
                await Task.Delay(1000, ct);
            }
        }
        catch (TaskCanceledException) { }
        preshowCts = null;
    }

    void OnOverlayClick(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2) { ToggleImmersive(); return; }
        preshowCts?.Cancel();   // click skips the preshow
        ShowControls();
    }

    // MARK: Playback

    async Task StartAsync()
    {
        ShowSlide("FEATURE PRESENTATION", "Connecting…", item.DisplayTitle);
        try
        {
            var (url, sourceId, session) = await api.PlaybackAsync(item.Server, item.Id);
            mediaSourceId = sourceId;
            playSessionId = session;
            using var media = new Media(libVLC, new Uri(url), ":network-caching=2000");
            if (startSeconds > 1) media.AddOption($":start-time={startSeconds.ToString(System.Globalization.CultureInfo.InvariantCulture)}");
            player.Play(media);
            Lights(0.9, 3);
        }
        catch (Exception ex)
        {
            ShowSlide("PLAYBACK PROBLEM", "Couldn't start the stream", ex.Message);
            Lights(0.2, 2);
        }
    }

    void OnVlcPlaying()
    {
        HideSlide();
        if (!loadedOnce)
        {
            loadedOnce = true;
            LoadTracks();
            if (party != null)
            {
                // Hold at the agreed position until the group says go.
                player.SetPause(true);
                _ = party.ReadyAsync(player.Time / 1000.0);
            }
        }
        if (!reportedStart)
        {
            reportedStart = true;
            Report("/Sessions/Playing");
            reportTimer.Start();
        }
        PlayButton.Content = "⏸";
    }

    void OnVlcEnded()
    {
        ended = true;
        reportTimer.Stop();
        driftTimer.Stop();
        _ = api.ReportAsync("/Sessions/Playing/Stopped", item.Id, mediaSourceId, playSessionId, player.Length / 1000.0, false);
        ShowSlide("THANK YOU FOR VISITING", "ZMF THEATERS+", "House lights up · please exit safely");
        Lights(0.05, 6);
        ShowControls();
    }

    void Report(string endpoint)
    {
        if (ended || !reportedStart) return;
        _ = api.ReportAsync(endpoint, item.Id, mediaSourceId, playSessionId, player.Time / 1000.0, !player.IsPlaying);
    }

    void LoadTracks()
    {
        updatingTracks = true;
        AudioBox.ItemsSource = player.AudioTrackDescription;
        AudioBox.SelectedValuePath = "Id";
        AudioBox.SelectedValue = player.AudioTrack;
        SubBox.ItemsSource = player.SpuDescription;
        SubBox.SelectedValuePath = "Id";
        SubBox.SelectedValue = player.Spu;
        updatingTracks = false;
    }

    void OnAudioChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!updatingTracks && AudioBox.SelectedValue is int id) player.SetAudioTrack(id);
    }

    void OnSubChanged(object sender, SelectionChangedEventArgs e)
    {
        if (!updatingTracks && SubBox.SelectedValue is int id) player.SetSpu(id);
    }

    void Tick()
    {
        var len = Math.Max(1, player.Length / 1000.0);
        var t = Math.Max(0, player.Time / 1000.0);
        TimeText.Text = $"{Fmt(t)} / {Fmt(len)}";
        if (!SeekBar.IsMouseCaptureWithin)
        {
            SeekBar.Maximum = len;
            SeekBar.Value = t;
        }
        // Controls fade out after 3 s without mouse movement while the film plays.
        var idle = (DateTime.UtcNow - lastMouse).TotalSeconds > 3;
        var hide = idle && player.IsPlaying && !ended && !Controls.IsMouseOver;
        var target = hide ? 0.0 : 1.0;
        if (Math.Abs(Controls.Opacity - target) > 0.01 && Controls.Tag as string != (hide ? "hiding" : "showing"))
        {
            Controls.Tag = hide ? "hiding" : "showing";
            Controls.BeginAnimation(OpacityProperty, new DoubleAnimation(target, TimeSpan.FromMilliseconds(hide ? 700 : 150)));
            Controls.IsHitTestVisible = !hide;
            Cursor = hide ? Cursors.None : null;
        }
    }

    static string Fmt(double s)
    {
        var ts = TimeSpan.FromSeconds(s);
        return ts.TotalHours >= 1 ? ts.ToString(@"h\:mm\:ss") : ts.ToString(@"m\:ss");
    }

    void ShowControls() => lastMouse = DateTime.UtcNow;

    void OnMouseMove(object sender, MouseEventArgs e) => ShowControls();

    // MARK: Transport (routed through SyncPlay in a party)

    void OnPlayPause(object sender, RoutedEventArgs e) => TogglePlay();

    void TogglePlay()
    {
        if (party?.InGroup == true)
        {
            _ = player.IsPlaying ? party.PauseAsync() : party.UnpauseAsync();
            return;
        }
        player.Pause();
        PlayButton.Content = player.IsPlaying ? "▶" : "⏸";
        Lights(player.IsPlaying ? 0.45 : 0.9, 1.5);
    }

    void SeekTo(double seconds)
    {
        seconds = Math.Clamp(seconds, 0, Math.Max(0, player.Length / 1000.0 - 1));
        if (party?.InGroup == true) { _ = party.SeekAsync(seconds); return; }
        player.Time = (long)(seconds * 1000);
    }

    void OnBack(object sender, RoutedEventArgs e) => SeekTo(player.Time / 1000.0 - 10);
    void OnForward(object sender, RoutedEventArgs e) => SeekTo(player.Time / 1000.0 + 30);
    void OnSeekRelease(object sender, MouseButtonEventArgs e) => SeekTo(SeekBar.Value);

    void OnVolume(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        player.Volume = (int)VolumeBar.Value;
        config.Volume = (int)VolumeBar.Value;
    }

    void OnFullscreen(object sender, RoutedEventArgs e) => ToggleImmersive();

    /// Removes the curtains and seats so the picture fills the monitor; playback continues.
    void ToggleImmersive()
    {
        immersive = !immersive;
        Root.RowDefinitions[0].Height = immersive ? new GridLength(0) : new GridLength(0.07, GridUnitType.Star);
        Root.RowDefinitions[2].Height = immersive ? new GridLength(0) : new GridLength(0.2, GridUnitType.Star);
        var inner = (Grid)Root.Children.OfType<Grid>().First(g => Grid.GetRow(g) == 1);
        inner.ColumnDefinitions[0].Width = immersive ? new GridLength(0) : new GridLength(0.08, GridUnitType.Star);
        inner.ColumnDefinitions[2].Width = immersive ? new GridLength(0) : new GridLength(0.08, GridUnitType.Star);
        var screen = inner.Children.OfType<Border>().Last();
        screen.Margin = immersive ? new Thickness(0) : new Thickness(26, 18, 26, 18);
        screen.BorderThickness = new Thickness(immersive ? 0 : 8);
        Grid.SetRow(Controls, immersive ? 1 : 2);
    }

    void OnKeyDown(object sender, KeyEventArgs e)
    {
        switch (e.Key)
        {
            case Key.Space: TogglePlay(); break;
            case Key.Left: SeekTo(player.Time / 1000.0 - 10); break;
            case Key.Right: SeekTo(player.Time / 1000.0 + 30); break;
            case Key.F: case Key.F11: ToggleImmersive(); break;
            case Key.Escape: if (immersive) ToggleImmersive(); else Close(); break;
            case Key.Enter: preshowCts?.Cancel(); break;
            default: return;
        }
        ShowControls();
        e.Handled = true;
    }

    void OnClose(object sender, RoutedEventArgs e) => Close();

    // MARK: Watch party

    public void SetPartyMembers(IEnumerable<string> members)
    {
        var others = members.Where(m => m != item.Server.Username).ToList();
        PartyBadge.Visibility = Visibility.Visible;
        PartyText.Text = others.Count == 0 ? "👥 Watch party · waiting for friends" : "👥 Watching with " + string.Join(", ", others);
    }

    /// The group's queue points at this film: line up at the agreed spot and report ready.
    public void PartyAlign(double seconds)
    {
        if (!loadedOnce) { startSeconds = seconds; return; }
        player.SetPause(true);
        player.Time = (long)(seconds * 1000);
        _ = party?.ReadyAsync(seconds);
    }

    public void PartyCommand(string command, DateTime whenServer, double position)
    {
        if (party == null) return;
        switch (command)
        {
            case "Unpause":
                var delay = (whenServer - party.ServerNow).TotalSeconds;
                anchor = (whenServer, position);
                player.Time = (long)((delay > 0 ? position : position - delay) * 1000);
                if (delay > 0)
                    _ = Task.Delay(TimeSpan.FromSeconds(delay)).ContinueWith(_ => Dispatcher.BeginInvoke(() => player.SetPause(false)));
                else
                    player.SetPause(false);
                HideSlide();
                Lights(0.9, 2);
                driftTimer.Start();
                PlayButton.Content = "⏸";
                break;
            case "Pause":
                anchor = null;
                driftTimer.Stop();
                player.SetRate(1);
                player.SetPause(true);
                player.Time = (long)(position * 1000);
                PlayButton.Content = "▶";
                Lights(0.45, 1.5);
                break;
            case "Seek":
                anchor = null;
                player.SetPause(true);
                player.Time = (long)(position * 1000);
                _ = Task.Delay(800).ContinueWith(_ => party.ReadyAsync(position));
                break;
            case "Stop":
                anchor = null;
                driftTimer.Stop();
                player.SetPause(true);
                break;
        }
        ShowControls();
    }

    /// Small drift is absorbed by nudging the rate; large drift by seeking.
    void CorrectDrift()
    {
        if (party == null || anchor is not { } a || !player.IsPlaying) return;
        var expected = a.seconds + (party.ServerNow - a.when).TotalSeconds;
        var drift = player.Time / 1000.0 - expected;
        if (Math.Abs(drift) > 1.5) { player.Time = (long)(expected * 1000); player.SetRate(1); }
        else if (Math.Abs(drift) > 0.15) player.SetRate(drift > 0 ? 0.95f : 1.05f);
        else player.SetRate(1);
    }

    void OnClosing(object? sender, System.ComponentModel.CancelEventArgs e)
    {
        preshowCts?.Cancel();
        uiTimer.Stop();
        reportTimer.Stop();
        driftTimer.Stop();
        config.Save();
        if (reportedStart && !ended)
            _ = api.ReportAsync("/Sessions/Playing/Stopped", item.Id, mediaSourceId, playSessionId, player.Time / 1000.0, true);
        var p = player;
        var lib = libVLC;
        Video.MediaPlayer = null;
        // Stopping LibVLC on the UI thread can deadlock; do it on the thread pool.
        ThreadPool.QueueUserWorkItem(_ =>
        {
            p.Stop();
            p.Dispose();
            lib.Dispose();
        });
    }
}

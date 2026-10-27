using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using ZMFTheaters.Cinema;
using ZMFTheaters.Jellyfin;

namespace ZMFTheaters;

public sealed class RoomCard
{
    public required Room Room { get; init; }
    public required MediaEntry Film { get; init; }
    public string RoomTitle => Room.Title;
    public string FilmTitle => Film.Title;
    public string PosterUrl => Film.PosterUrl;
    public string Meta => Film.Meta;
    public Brush Accent => new SolidColorBrush((Color)ColorConverter.ConvertFromString(Room.Accent));
}

public partial class MainWindow : Window
{
    readonly AppConfig config = AppConfig.Load();
    readonly Dictionary<string, JellyfinClient> clients = new();
    List<MediaEntry> catalog = new();
    MediaEntry? selected;
    string libraryMode = "Movies";

    SyncPlayClient? party;
    CinemaWindow? cinema;

    public MainWindow() => InitializeComponent();

    JellyfinClient Client(ServerConfig s)
    {
        if (!clients.TryGetValue(s.Id, out var c))
        {
            c = new JellyfinClient(s.Url, s.Token, config.DeviceId);
            clients[s.Id] = c;
        }
        return c;
    }

    void Status(string text) => StatusText.Text = text;

    async void OnLoaded(object sender, RoutedEventArgs e)
    {
        Force4DXBox.IsChecked = config.Force4DX;
        TeaserText.Text = FourDXPreview.Teaser(config.Force4DX);
        RefreshServerList();
        if (config.Servers.Count == 0) { Show("Servers"); Status("Add your Jellyfin server to get started."); return; }
        await SyncAsync();
    }

    // MARK: Navigation

    void OnNav(object sender, RoutedEventArgs e) => Show((string)((Button)sender).Tag);

    void Show(string panel)
    {
        NowPanel.Visibility = panel == "Now" ? Visibility.Visible : Visibility.Collapsed;
        LibraryPanel.Visibility = panel is "Movies" or "Shows" ? Visibility.Visible : Visibility.Collapsed;
        PartyPanel.Visibility = panel == "Parties" ? Visibility.Visible : Visibility.Collapsed;
        ServersPanel.Visibility = panel == "Servers" ? Visibility.Visible : Visibility.Collapsed;
        PresentationsPanel.Visibility = panel == "Presentations" ? Visibility.Visible : Visibility.Collapsed;
        if (panel == "Presentations") RefreshPresentations();
        DetailOverlay.Visibility = Visibility.Collapsed;
        if (panel is "Movies" or "Shows")
        {
            libraryMode = panel;
            LibraryTitle.Text = panel == "Movies" ? "MOVIES" : "TV SHOWS";
            ApplySearch();
        }
        if (panel == "Parties") _ = RefreshPartiesAsync();
    }

    // MARK: Catalog

    async Task SyncAsync()
    {
        var all = new List<MediaEntry>();
        foreach (var s in config.Servers)
        {
            try
            {
                Status($"Syncing {s.Name}…");
                all.AddRange(await Client(s).ItemsAsync(s, "Movie,Series"));
            }
            catch (Exception ex) { Status($"{s.Name}: {ex.Message}"); }
        }
        catalog = all;
        BuildNowShowing();
        ApplySearch();
        Status($"{catalog.Count(m => m.Type == "Movie")} movies · {catalog.Count(m => m.Type == "Series")} shows from {config.Servers.Count} server(s)");
    }

    void BuildNowShowing()
    {
        var index = RotationDirector.PeriodIndex(DateTime.UtcNow);
        var (start, end) = RotationDirector.Bounds(index);
        var picks = RotationDirector.Select(catalog, index);
        NowList.ItemsSource = Rooms.All.Where(r => picks.ContainsKey(r.Id)).Select(r => new RoomCard { Room = r, Film = picks[r.Id] }).ToList();
        ProgrammeText.Text = $"Programme {start.ToLocalTime():MMM d} – {end.AddSeconds(-1).ToLocalTime():MMM d} · twelve films, one per auditorium, new every {RotationDirector.Days} days";
    }

    void OnSearch(object sender, TextChangedEventArgs e) => ApplySearch();

    void ApplySearch()
    {
        var type = libraryMode == "Movies" ? "Movie" : "Series";
        var q = SearchBox.Text.Trim();
        LibraryList.ItemsSource = catalog.Where(m => m.Type == type && (q.Length == 0 || m.Title.Contains(q, StringComparison.OrdinalIgnoreCase))).ToList();
    }

    // MARK: Detail

    async void OnEntryClick(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is not MediaEntry m) return;
        selected = m;
        DetailTitle.Text = m.Title;
        DetailMeta.Text = $"{m.Meta}  ·  {m.Server.Name}";
        DetailOverview.Text = m.Overview ?? "";
        DetailRoom.Text = Rooms.BestFor(m).Title;
        try { DetailPoster.Source = string.IsNullOrEmpty(m.PosterUrl) ? null : new BitmapImage(new Uri(m.PosterUrl)); } catch { DetailPoster.Source = null; }
        EpisodeList.Visibility = m.Type == "Series" ? Visibility.Visible : Visibility.Collapsed;
        EpisodeList.ItemsSource = null;
        DetailOverlay.Visibility = Visibility.Visible;
        if (m.Type == "Series")
        {
            try
            {
                var eps = await Client(m.Server).EpisodesAsync(m.Server, m.Id);
                EpisodeList.ItemsSource = eps;
                if (eps.Count > 0) EpisodeList.SelectedIndex = 0;
            }
            catch (Exception ex) { Status(ex.Message); }
        }
    }

    void OnCloseDetail(object sender, RoutedEventArgs e) => DetailOverlay.Visibility = Visibility.Collapsed;

    MediaEntry? ChosenPlayable() => selected?.Type == "Series" ? EpisodeList.SelectedItem as MediaEntry : selected;

    void OnWatch(object sender, RoutedEventArgs e)
    {
        if (ChosenPlayable() is not MediaEntry m) return;
        DetailOverlay.Visibility = Visibility.Collapsed;
        OpenCinema(preselect: m);
    }

    void OnEnterCinema(object sender, RoutedEventArgs e) => OpenCinema();

    async void OnHost(object sender, RoutedEventArgs e)
    {
        if (ChosenPlayable() is not MediaEntry m) return;
        DetailOverlay.Visibility = Visibility.Collapsed;
        try
        {
            await EnsurePartyAsync(m.Server);
            OpenCinema(partyFilm: m, partyStart: 0);
            await party!.HostAsync(m.Id, m.DisplayTitle, 0);
            Status("Watch party started — friends can join from Watch Parties.");
        }
        catch (Exception ex) { Status("Couldn't start the party: " + ex.Message); }
    }

    // MARK: Cinema

    /// Opens the walkable 3D cinema (lobby → box office → hall → auditorium).
    void OpenCinema(MediaEntry? preselect = null, MediaEntry? partyFilm = null, double partyStart = 0)
    {
        cinema?.Close();
        var w = new CinemaWindow(config, Client, catalog, preselect, partyFilm != null ? party : null, partyFilm, partyStart);
        w.Closed += (_, _) => { if (cinema == w) cinema = null; };
        cinema = w;
        w.Show();
    }

    // MARK: Presentations

    void RefreshPresentations()
    {
        PresentationList.ItemsSource = null;
        PresentationList.ItemsSource = config.Presentations;
        CoasterBox.IsChecked = config.CoasterIntro;
        VoiceBox.IsChecked = config.CoasterVoice;
        FxBox.IsChecked = config.ScreenEffects;
        FlashBox.IsChecked = config.ScreenFlashes;
    }

    void OnAddPresentation(object sender, RoutedEventArgs e)
    {
        var id = YouTubePresenter.VideoId(YtUrlBox.Text);
        if (id == null) { YtStatus.Text = "Paste a public YouTube https link (youtube.com/watch?v=…, youtu.be/…, or Shorts)."; return; }
        if (config.Presentations.Any(p => p.VideoId == id)) { YtStatus.Text = "That video is already in your presentations."; return; }
        var title = YtTitleBox.Text.Trim();
        config.Presentations.Add(new YouTubePresentation
        {
            VideoId = id, Title = title.Length == 0 ? "YouTube Presentation" : title[..Math.Min(100, title.Length)],
            Format = (YtFormatBox.SelectedItem as ComboBoxItem)?.Tag as string ?? "TwoD",
        });
        config.Save();
        YtUrlBox.Text = ""; YtTitleBox.Text = ""; YtStatus.Text = "Added. It plays before your next screening.";
        RefreshPresentations();
    }

    void OnRemovePresentation(object sender, RoutedEventArgs e)
    {
        if (PresentationList.SelectedItem is not YouTubePresentation p) return;
        config.Presentations.Remove(p);
        config.Save();
        RefreshPresentations();
    }

    void OnPresentationUp(object sender, RoutedEventArgs e)
    {
        if (PresentationList.SelectedItem is not YouTubePresentation p) return;
        var i = config.Presentations.IndexOf(p);
        if (i <= 0) return;
        config.Presentations.RemoveAt(i);
        config.Presentations.Insert(i - 1, p);
        config.Save();
        RefreshPresentations();
        PresentationList.SelectedItem = p;
    }

    void OnPreshowOption(object sender, RoutedEventArgs e)
    {
        config.CoasterIntro = CoasterBox.IsChecked == true;
        config.CoasterVoice = VoiceBox.IsChecked == true;
        config.ScreenEffects = FxBox.IsChecked == true;
        config.ScreenFlashes = FlashBox.IsChecked == true;
        config.Save();
    }

    void On4DXToggle(object sender, RoutedEventArgs e)
    {
        config.Force4DX = Force4DXBox.IsChecked == true;
        config.Save();
        TeaserText.Text = FourDXPreview.Teaser(config.Force4DX);
    }

    // MARK: Watch parties

    async Task EnsurePartyAsync(ServerConfig s)
    {
        if (party != null && party.Server.Id == s.Id) return;
        if (party != null) await party.DisposeAsync();
        var p = new SyncPlayClient(Client(s), s);
        p.Status += text => Dispatcher.BeginInvoke(() => { PartyStatus.Text = text; Status(text); });
        p.MembersChanged += () => Dispatcher.BeginInvoke(() =>
        {
            LeaveButton.IsEnabled = p.InGroup;
            cinema?.SetPartyMembers(p.Members);
        });
        p.PlayQueue += (itemId, start) => Dispatcher.BeginInvoke(async () =>
        {
            if (cinema != null && cinema.ItemId == itemId)
            {
                cinema.PartyAlign(start);
                return;
            }
            var entry = catalog.FirstOrDefault(c => c.Id == itemId && c.Server.Id == s.Id) ?? await Client(s).ItemAsync(s, itemId);
            if (entry != null) OpenCinema(partyFilm: entry, partyStart: start);
            else Status("The party's film isn't available to your account.");
        });
        p.Command += (cmd, when, pos) => Dispatcher.BeginInvoke(() => cinema?.PartyCommand(cmd, when, pos));
        await p.ConnectAsync();
        party = p;
    }

    async Task RefreshPartiesAsync()
    {
        var groups = new List<PartyGroup>();
        foreach (var s in config.Servers)
        {
            try { groups.AddRange(await SyncPlayClient.ListAsync(Client(s), s)); }
            catch (Exception ex) { Status($"{s.Name}: {ex.Message}"); }
        }
        PartyList.ItemsSource = groups;
        if (groups.Count == 0) PartyStatus.Text = party?.InGroup == true ? PartyStatus.Text : "No parties right now on your servers.";
    }

    async void OnRefreshParties(object sender, RoutedEventArgs e) => await RefreshPartiesAsync();

    async void OnJoinParty(object sender, RoutedEventArgs e)
    {
        if ((sender as Button)?.Tag is not PartyGroup g) return;
        try
        {
            await EnsurePartyAsync(g.Server);
            await party!.JoinAsync(g.Id);
            PartyStatus.Text = $"Joining {g.Name}…";
        }
        catch (Exception ex) { PartyStatus.Text = "Couldn't join: " + ex.Message; }
    }

    async void OnLeaveParty(object sender, RoutedEventArgs e)
    {
        if (party != null) await party.LeaveAsync();
        LeaveButton.IsEnabled = false;
        PartyStatus.Text = "Left the watch party";
    }

    // MARK: Servers

    void RefreshServerList()
    {
        ServerList.ItemsSource = null;
        ServerList.ItemsSource = config.Servers;
    }

    async void OnConnect(object sender, RoutedEventArgs e)
    {
        var url = JellyfinClient.Normalize(UrlBox.Text);
        if (!Uri.TryCreate(url, UriKind.Absolute, out _) || UserBox.Text.Trim().Length == 0)
        {
            ConnectStatus.Text = "Enter a valid server URL and username.";
            return;
        }
        ConnectButton.IsEnabled = false;
        ConnectStatus.Text = "Connecting…";
        try
        {
            var probe = new JellyfinClient(url, null, config.DeviceId);
            var (serverName, version) = await probe.PublicInfoAsync();
            var (token, userId) = await probe.AuthenticateAsync(UserBox.Text.Trim(), PassBox.Password);
            var s = new ServerConfig
            {
                Name = NameBox.Text.Trim().Length > 0 ? NameBox.Text.Trim() : serverName,
                Url = url,
                Username = UserBox.Text.Trim(),
                UserId = userId,
            };
            s.Token = token;
            config.Servers.Add(s);
            config.Save();
            clients[s.Id] = probe;
            PassBox.Clear();
            ConnectStatus.Text = $"✓ Connected to {serverName} {version}" + (s.IsHttps ? "" : "  (warning: not HTTPS — use only on a trusted LAN/VPN)");
            RefreshServerList();
            await SyncAsync();
        }
        catch (Exception ex) { ConnectStatus.Text = ex.Message; }
        finally { ConnectButton.IsEnabled = true; }
    }

    async void OnSync(object sender, RoutedEventArgs e) => await SyncAsync();

    void OnRemoveServer(object sender, RoutedEventArgs e)
    {
        if (ServerList.SelectedItem is not ServerConfig s) return;
        if (MessageBox.Show(this, $"Remove {s.Name}? Nothing on the server is changed.", "ZMF THEATERS+", MessageBoxButton.YesNo) != MessageBoxResult.Yes) return;
        config.Servers.Remove(s);
        clients.Remove(s.Id);
        config.Save();
        catalog.RemoveAll(m => m.Server.Id == s.Id);
        RefreshServerList();
        BuildNowShowing();
        ApplySearch();
    }

    protected override async void OnClosed(EventArgs e)
    {
        cinema?.Close();
        if (party != null) await party.DisposeAsync();
        base.OnClosed(e);
        Application.Current.Shutdown();
    }
}

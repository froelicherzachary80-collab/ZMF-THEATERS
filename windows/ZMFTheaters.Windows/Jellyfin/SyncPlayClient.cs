using System.Globalization;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;

namespace ZMFTheaters.Jellyfin;

public sealed record PartyGroup(string Id, string Name, string State, List<string> Participants, ServerConfig Server)
{
    public string Summary => $"{string.Join(", ", Participants)} · {State} · {Server.Name}";
}

/// Jellyfin SyncPlay client (same protocol as the iPhone app and official
/// Jellyfin clients). The server keeps everyone's play/pause/seek in step.
/// Events are raised on background threads.
public sealed class SyncPlayClient : IAsyncDisposable
{
    readonly JellyfinClient api;
    public ServerConfig Server { get; }
    ClientWebSocket? ws;
    readonly CancellationTokenSource cts = new();
    double offsetSeconds;

    public string? GroupId { get; private set; }
    public string? GroupName { get; private set; }
    public string? PlaylistItemId { get; private set; }
    public List<string> Members { get; } = new();
    public bool IsHost { get; private set; }
    string? pendingHostItem;
    double pendingHostSeconds;

    public event Action<string, double>? PlayQueue;            // itemId, start seconds
    public event Action<string, DateTime, double>? Command;    // command, when (UTC, server clock), position seconds
    public event Action<string>? Status;
    public event Action? MembersChanged;

    public SyncPlayClient(JellyfinClient api, ServerConfig server)
    {
        this.api = api;
        Server = server;
    }

    public DateTime ServerNow => DateTime.UtcNow.AddSeconds(offsetSeconds);
    public bool InGroup => GroupId != null;

    public static async Task<List<PartyGroup>> ListAsync(JellyfinClient api, ServerConfig server)
    {
        var n = await api.GetAsync("/SyncPlay/List");
        var list = new List<PartyGroup>();
        if (n is JsonArray a)
            foreach (var g in a)
            {
                if (g?["GroupId"]?.GetValue<string>() is not string id) continue;
                var people = (g["Participants"] as JsonArray)?.Select(x => x?.GetValue<string>() ?? "").ToList() ?? new();
                list.Add(new PartyGroup(id, g["GroupName"]?.GetValue<string>() ?? "Watch party", g["State"]?.GetValue<string>() ?? "", people, server));
            }
        return list;
    }

    public async Task ConnectAsync()
    {
        try
        {
            await api.PostAsync("/Sessions/Capabilities/Full", new Dictionary<string, object?>
            {
                ["PlayableMediaTypes"] = new[] { "Video" },
                ["SupportedCommands"] = Array.Empty<string>(),
                ["SupportsMediaControl"] = true,
                ["SupportsPersistentIdentifier"] = true,
            });
        }
        catch { }
        await SyncClockAsync();
        var uri = new UriBuilder(api.BaseUrl);
        uri.Scheme = uri.Scheme == "https" ? "wss" : "ws";
        uri.Path = uri.Path.TrimEnd('/') + "/socket";
        uri.Query = $"api_key={Uri.EscapeDataString(api.Token ?? "")}&deviceId={Uri.EscapeDataString(api.DeviceId)}";
        ws = new ClientWebSocket();
        await ws.ConnectAsync(uri.Uri, cts.Token);
        _ = Task.Run(ReceiveLoop);
        _ = Task.Run(KeepAliveLoop);
        Status?.Invoke($"Connected to {Server.Name}");
    }

    public async Task HostAsync(string itemId, string title, double startSeconds)
    {
        IsHost = true;
        pendingHostItem = itemId;
        pendingHostSeconds = startSeconds;
        await api.PostAsync("/SyncPlay/New", new { GroupName = "ZMF · " + title });
    }

    public Task JoinAsync(string groupId) => api.PostAsync("/SyncPlay/Join", new { GroupId = groupId });
    public Task PauseAsync() => api.PostAsync("/SyncPlay/Pause");
    public Task UnpauseAsync() => api.PostAsync("/SyncPlay/Unpause");
    public Task SeekAsync(double seconds) => api.PostAsync("/SyncPlay/Seek", new { PositionTicks = Ticks(seconds) });

    public async Task ReadyAsync(double positionSeconds)
    {
        var body = new Dictionary<string, object?>
        {
            ["When"] = ServerNow.ToString("o", CultureInfo.InvariantCulture),
            ["PositionTicks"] = Ticks(positionSeconds),
            ["IsPlaying"] = false,
        };
        if (PlaylistItemId != null) body["PlaylistItemId"] = PlaylistItemId;
        try { await api.PostAsync("/SyncPlay/Ready", body); } catch { }
        if (IsHost)
        {
            await Task.Delay(1000);
            try { await UnpauseAsync(); } catch { }
        }
    }

    public async Task LeaveAsync()
    {
        try { if (InGroup) await api.PostAsync("/SyncPlay/Leave"); } catch { }
        GroupId = null;
        Members.Clear();
        MembersChanged?.Invoke();
    }

    static long Ticks(double seconds) => (long)(Math.Max(0, seconds) * 10_000_000);

    static DateTime? ParseDate(string? s) =>
        s != null && DateTimeOffset.TryParse(s, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var d) ? d.UtcDateTime : null;

    /// NTP-style estimate of the server clock via /GetUtcTime (best of three).
    async Task SyncClockAsync()
    {
        double bestRtt = double.MaxValue;
        for (int i = 0; i < 3; i++)
        {
            try
            {
                var sent = DateTime.UtcNow;
                var n = await api.GetAsync("/GetUtcTime");
                var got = DateTime.UtcNow;
                var recv = ParseDate(n?["RequestReceptionTime"]?.GetValue<string>());
                var send = ParseDate(n?["ResponseTransmissionTime"]?.GetValue<string>());
                if (recv == null || send == null) continue;
                var rtt = (got - sent).TotalSeconds - (send.Value - recv.Value).TotalSeconds;
                if (rtt < bestRtt)
                {
                    bestRtt = rtt;
                    offsetSeconds = ((recv.Value - sent).TotalSeconds + (send.Value - got).TotalSeconds) / 2;
                }
            }
            catch { }
        }
    }

    async Task KeepAliveLoop()
    {
        while (!cts.IsCancellationRequested)
        {
            try
            {
                await Task.Delay(25_000, cts.Token);
                await SendText("{\"MessageType\":\"KeepAlive\"}");
                await SyncClockAsync();
            }
            catch { }
        }
    }

    async Task SendText(string text)
    {
        if (ws?.State != WebSocketState.Open) return;
        await ws.SendAsync(new ArraySegment<byte>(Encoding.UTF8.GetBytes(text)), WebSocketMessageType.Text, true, cts.Token);
    }

    async Task ReceiveLoop()
    {
        var buffer = new byte[64 * 1024];
        var sb = new StringBuilder();
        while (ws != null && ws.State == WebSocketState.Open && !cts.IsCancellationRequested)
        {
            WebSocketReceiveResult r;
            try { r = await ws.ReceiveAsync(new ArraySegment<byte>(buffer), cts.Token); }
            catch
            {
                if (!cts.IsCancellationRequested) Status?.Invoke("Connection to the server dropped — rejoin the party");
                return;
            }
            if (r.MessageType == WebSocketMessageType.Close) { Status?.Invoke("Server closed the connection"); return; }
            sb.Append(Encoding.UTF8.GetString(buffer, 0, r.Count));
            if (!r.EndOfMessage) continue;
            var text = sb.ToString();
            sb.Clear();
            try { Handle(JsonNode.Parse(text)); } catch { }
        }
    }

    void Handle(JsonNode? msg)
    {
        switch (msg?["MessageType"]?.GetValue<string>())
        {
            case "ForceKeepAlive":
                _ = SendText("{\"MessageType\":\"KeepAlive\"}");
                break;
            case "SyncPlayGroupUpdate":
                GroupUpdate(msg["Data"]);
                break;
            case "SyncPlayCommand":
                var d = msg["Data"];
                var cmd = d?["Command"]?.GetValue<string>() ?? "";
                var when = ParseDate(d?["When"]?.GetValue<string>()) ?? ServerNow;
                var pos = (d?["PositionTicks"]?.GetValue<long>() ?? 0) / 10_000_000.0;
                Command?.Invoke(cmd, when, pos);
                break;
        }
    }

    void GroupUpdate(JsonNode? d)
    {
        var type = d?["Type"]?.GetValue<string>();
        var data = d?["Data"];
        switch (type)
        {
            case "GroupJoined":
                GroupId = data?["GroupId"]?.GetValue<string>();
                GroupName = data?["GroupName"]?.GetValue<string>();
                Members.Clear();
                if (data?["Participants"] is JsonArray ps) Members.AddRange(ps.Select(x => x?.GetValue<string>() ?? ""));
                MembersChanged?.Invoke();
                Status?.Invoke($"In “{GroupName}”");
                if (pendingHostItem != null)
                {
                    var item = pendingHostItem;
                    pendingHostItem = null;
                    _ = api.PostAsync("/SyncPlay/SetNewQueue", new Dictionary<string, object?>
                    {
                        ["PlayingQueue"] = new[] { item },
                        ["PlayingItemPosition"] = 0,
                        ["StartPositionTicks"] = Ticks(pendingHostSeconds),
                    });
                }
                break;
            case "UserJoined":
                if (data?.GetValue<string>() is string joined) { if (!Members.Contains(joined)) Members.Add(joined); MembersChanged?.Invoke(); Status?.Invoke($"{joined} joined the party"); }
                break;
            case "UserLeft":
                if (data?.GetValue<string>() is string left) { Members.Remove(left); MembersChanged?.Invoke(); Status?.Invoke($"{left} left the party"); }
                break;
            case "GroupLeft":
            case "NotInGroup":
            case "GroupDoesNotExist":
                GroupId = null;
                Members.Clear();
                MembersChanged?.Invoke();
                Status?.Invoke("Not in a watch party");
                break;
            case "LibraryAccessDenied":
                Status?.Invoke("Your Jellyfin account can't access this title");
                break;
            case "StateUpdate":
                var state = data?["State"]?.GetValue<string>();
                Status?.Invoke(state == "Waiting" ? "Waiting for everyone to buffer…" : $"In “{GroupName}” · {state}");
                break;
            case "PlayQueue":
                if (data?["Playlist"] is JsonArray list && list.Count > 0)
                {
                    var idx = Math.Clamp(data["PlayingItemIndex"]?.GetValue<int>() ?? 0, 0, list.Count - 1);
                    PlaylistItemId = list[idx]?["PlaylistItemId"]?.GetValue<string>();
                    var itemId = list[idx]?["ItemId"]?.GetValue<string>();
                    var start = (data["StartPositionTicks"]?.GetValue<long>() ?? 0) / 10_000_000.0;
                    if (itemId != null) PlayQueue?.Invoke(itemId, start);
                }
                break;
        }
    }

    public async ValueTask DisposeAsync()
    {
        await LeaveAsync();
        cts.Cancel();
        try { if (ws?.State == WebSocketState.Open) await ws.CloseAsync(WebSocketCloseStatus.NormalClosure, "bye", CancellationToken.None); } catch { }
        ws?.Dispose();
    }
}

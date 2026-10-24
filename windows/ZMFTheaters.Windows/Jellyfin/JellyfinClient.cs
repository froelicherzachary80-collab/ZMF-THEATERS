using System.Globalization;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace ZMFTheaters.Jellyfin;

public sealed class JellyfinException : Exception
{
    public int? Status { get; }
    public JellyfinException(string message, int? status) : base(message) { Status = status; }
}

/// A movie, series or episode from one specific server.
public sealed class MediaEntry
{
    public required ServerConfig Server { get; init; }
    public required string Id { get; init; }
    public string Type { get; init; } = "Movie";
    public string Title { get; init; } = "Untitled";
    public int? Year { get; init; }
    public long? RunTimeTicks { get; init; }
    public List<string> Genres { get; init; } = new();
    public List<string> Tags { get; init; } = new();
    public List<string> Studios { get; init; } = new();
    public string? Overview { get; init; }
    public double? CommunityRating { get; init; }
    public long ResumeTicks { get; init; }
    public bool HasPrimary { get; init; }
    public string? SeriesName { get; init; }
    public int? Season { get; init; }
    public int? Episode { get; init; }
    public string PosterUrl { get; set; } = "";

    public string YearText => Year?.ToString(CultureInfo.InvariantCulture) ?? "";
    public string RuntimeText => RunTimeTicks is long t && t > 0 ? $"{t / 600_000_000} min" : "";
    public string DisplayTitle => Type == "Episode" && Season is int s && Episode is int e ? $"{SeriesName} S{s}E{e} · {Title}" : Title;
    public string Meta => string.Join(" · ", new[] { YearText, RuntimeText, string.Join(", ", Genres.Take(2)) }.Where(x => x.Length > 0));
    public IEnumerable<string> Terms => Genres.Concat(Tags).Concat(Studios).Append(Title).Select(x => x.ToLowerInvariant());

    static List<string> Strings(JsonNode? n) => n is JsonArray a ? a.Select(x => x?.GetValue<string>() ?? "").Where(x => x.Length > 0).ToList() : new();

    public static MediaEntry From(JsonNode n, ServerConfig server, JellyfinClient api)
    {
        var tags = n["ImageTags"] as JsonObject;
        var e = new MediaEntry
        {
            Server = server,
            Id = n["Id"]!.GetValue<string>(),
            Type = n["Type"]?.GetValue<string>() ?? "Movie",
            Title = n["Name"]?.GetValue<string>() ?? "Untitled",
            Year = n["ProductionYear"]?.GetValue<int>(),
            RunTimeTicks = n["RunTimeTicks"]?.GetValue<long>(),
            Genres = Strings(n["Genres"]),
            Tags = Strings(n["Tags"]),
            Studios = n["Studios"] is JsonArray st ? st.Select(x => x?["Name"]?.GetValue<string>() ?? "").Where(x => x.Length > 0).ToList() : new(),
            Overview = n["Overview"]?.GetValue<string>(),
            CommunityRating = n["CommunityRating"]?.GetValue<double>(),
            ResumeTicks = n["UserData"]?["PlaybackPositionTicks"]?.GetValue<long>() ?? 0,
            HasPrimary = tags != null && tags.ContainsKey("Primary"),
            SeriesName = n["SeriesName"]?.GetValue<string>(),
            Season = n["ParentIndexNumber"]?.GetValue<int>(),
            Episode = n["IndexNumber"]?.GetValue<int>(),
        };
        e.PosterUrl = api.ImageUrl(e.Id);
        return e;
    }
}

/// Talks to one Jellyfin server via its documented REST API. Each instance only
/// ever holds the token that server issued.
public sealed class JellyfinClient
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };
    public const string ClientName = "ZMF Theaters Windows";
    public const string ClientVersion = "0.2.0";

    public string BaseUrl { get; }
    public string? Token { get; set; }
    public string DeviceId { get; }

    public JellyfinClient(string baseUrl, string? token, string deviceId)
    {
        BaseUrl = baseUrl.TrimEnd('/');
        Token = token;
        DeviceId = deviceId;
    }

    public static string Normalize(string raw)
    {
        var s = raw.Trim();
        if (!s.StartsWith("http://", StringComparison.OrdinalIgnoreCase) && !s.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
            s = "https://" + s;
        return s.TrimEnd('/');
    }

    public string AuthHeader =>
        $"MediaBrowser Client=\"{ClientName}\", Device=\"Windows PC\", DeviceId=\"{DeviceId}\", Version=\"{ClientVersion}\"" +
        (Token != null ? $", Token=\"{Token}\"" : "");

    public async Task<JsonNode?> SendAsync(HttpMethod method, string pathAndQuery, object? body = null)
    {
        using var req = new HttpRequestMessage(method, BaseUrl + pathAndQuery);
        req.Headers.TryAddWithoutValidation("Authorization", AuthHeader);
        req.Headers.Accept.Add(new MediaTypeWithQualityHeaderValue("application/json"));
        if (body != null) req.Content = new StringContent(JsonSerializer.Serialize(body), Encoding.UTF8, "application/json");
        HttpResponseMessage resp;
        try { resp = await Http.SendAsync(req); }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            throw new JellyfinException("Network error: " + e.Message, null);
        }
        using (resp)
        {
            var text = await resp.Content.ReadAsStringAsync();
            if (!resp.IsSuccessStatusCode)
            {
                var code = (int)resp.StatusCode;
                var hint = code switch
                {
                    401 => "Unauthorized — wrong password or the session expired.",
                    403 => "Forbidden — this Jellyfin user isn't allowed to do that.",
                    404 => "Not found on this server.",
                    _ => "The server reported an error.",
                };
                throw new JellyfinException($"HTTP {code}: {hint}", code);
            }
            return string.IsNullOrWhiteSpace(text) ? null : JsonNode.Parse(text);
        }
    }

    public Task<JsonNode?> GetAsync(string path) => SendAsync(HttpMethod.Get, path);
    public Task<JsonNode?> PostAsync(string path, object? body = null) => SendAsync(HttpMethod.Post, path, body ?? new { });

    static string Q(string s) => Uri.EscapeDataString(s);

    public async Task<(string serverName, string version)> PublicInfoAsync()
    {
        var n = await GetAsync("/System/Info/Public");
        return (n?["ServerName"]?.GetValue<string>() ?? "Jellyfin", n?["Version"]?.GetValue<string>() ?? "");
    }

    public async Task<(string token, string userId)> AuthenticateAsync(string username, string password)
    {
        var n = await PostAsync("/Users/AuthenticateByName", new { Username = username, Pw = password });
        var token = n?["AccessToken"]?.GetValue<string>() ?? throw new JellyfinException("No access token returned.", null);
        Token = token;
        return (token, n?["User"]?["Id"]?.GetValue<string>() ?? "");
    }

    public async Task<List<JsonNode>> ViewsAsync(string userId)
    {
        JsonNode? n;
        try { n = await GetAsync($"/UserViews?userId={Q(userId)}"); }
        catch (JellyfinException e) when (e.Status == 404) { n = await GetAsync($"/Users/{Q(userId)}/Views"); }
        return (n?["Items"] as JsonArray)?.Where(x => x != null).Select(x => x!).ToList() ?? new();
    }

    const string Fields = "Genres,Overview,ProductionYear,Tags,Studios,ProviderIds,CommunityRating";

    public async Task<List<MediaEntry>> ItemsAsync(ServerConfig server, string types, string? parentId = null)
    {
        var all = new List<MediaEntry>();
        int start = 0;
        const int page = 300;
        while (true)
        {
            var q = $"userId={Q(server.UserId)}&IncludeItemTypes={types}&Recursive=true&Fields={Fields}&SortBy=SortName&StartIndex={start}&Limit={page}&EnableImageTypes=Primary&ImageTypeLimit=1";
            if (parentId != null) q += $"&ParentId={Q(parentId)}";
            JsonNode? n;
            try { n = await GetAsync("/Items?" + q); }
            catch (JellyfinException e) when (e.Status == 404) { n = await GetAsync($"/Users/{Q(server.UserId)}/Items?" + q); }
            var items = (n?["Items"] as JsonArray)?.Where(x => x != null).Select(x => MediaEntry.From(x!, server, this)).ToList() ?? new();
            all.AddRange(items);
            start += items.Count;
            var total = n?["TotalRecordCount"]?.GetValue<int>() ?? 0;
            if (items.Count < page || start >= total) break;
        }
        return all;
    }

    public async Task<MediaEntry?> ItemAsync(ServerConfig server, string itemId)
    {
        var n = await GetAsync($"/Items?userId={Q(server.UserId)}&Ids={Q(itemId)}&Fields={Fields}");
        var first = (n?["Items"] as JsonArray)?.FirstOrDefault();
        return first == null ? null : MediaEntry.From(first, server, this);
    }

    public async Task<List<MediaEntry>> EpisodesAsync(ServerConfig server, string seriesId)
    {
        var n = await GetAsync($"/Shows/{Q(seriesId)}/Episodes?userId={Q(server.UserId)}&Fields={Fields}");
        return (n?["Items"] as JsonArray)?.Where(x => x != null).Select(x => MediaEntry.From(x!, server, this)).ToList() ?? new();
    }

    public string ImageUrl(string itemId, string type = "Primary", int maxWidth = 300) =>
        $"{BaseUrl}/Items/{itemId}/Images/{type}?maxWidth={maxWidth}&quality=85" + (Token != null ? $"&api_key={Q(Token)}" : "");

    /// Asks the server for a playback session. LibVLC decodes virtually every
    /// container and codec, so the original file is always streamed untouched.
    public async Task<(string url, string mediaSourceId, string? playSessionId)> PlaybackAsync(ServerConfig server, string itemId)
    {
        var body = new Dictionary<string, object?>
        {
            ["UserId"] = server.UserId,
            ["EnableDirectPlay"] = true,
            ["EnableDirectStream"] = true,
            ["EnableTranscoding"] = false,
            ["DeviceProfile"] = new Dictionary<string, object?>
            {
                ["Name"] = "ZMF Theaters Windows (LibVLC)",
                ["MaxStreamingBitrate"] = 400_000_000,
                ["MaxStaticBitrate"] = 400_000_000,
                ["DirectPlayProfiles"] = new[] { new Dictionary<string, object?> { ["Type"] = "Video" } },
                ["TranscodingProfiles"] = Array.Empty<object>(),
                ["SubtitleProfiles"] = new[] { new Dictionary<string, object?> { ["Format"] = "srt", ["Method"] = "Embed" } },
            },
        };
        var n = await PostAsync($"/Items/{Q(itemId)}/PlaybackInfo?userId={Q(server.UserId)}", body);
        var source = (n?["MediaSources"] as JsonArray)?.FirstOrDefault();
        var sourceId = source?["Id"]?.GetValue<string>() ?? itemId;
        var session = n?["PlaySessionId"]?.GetValue<string>();
        var url = $"{BaseUrl}/Videos/{Q(itemId)}/stream?static=true&MediaSourceId={Q(sourceId)}&DeviceId={Q(DeviceId)}&api_key={Q(Token ?? "")}";
        if (session != null) url += $"&PlaySessionId={Q(session)}";
        return (url, sourceId, session);
    }

    public Task ReportAsync(string endpoint, string itemId, string mediaSourceId, string? playSessionId, double seconds, bool paused)
    {
        var body = new Dictionary<string, object?>
        {
            ["ItemId"] = itemId,
            ["MediaSourceId"] = mediaSourceId,
            ["PositionTicks"] = (long)(Math.Max(0, seconds) * 10_000_000),
            ["IsPaused"] = paused,
            ["CanSeek"] = true,
            ["PlayMethod"] = "DirectPlay",
        };
        if (playSessionId != null) body["PlaySessionId"] = playSessionId;
        return SafePost(endpoint, body);
    }

    async Task SafePost(string path, object body)
    {
        try { await PostAsync(path, body); } catch { /* reporting is best-effort */ }
    }
}

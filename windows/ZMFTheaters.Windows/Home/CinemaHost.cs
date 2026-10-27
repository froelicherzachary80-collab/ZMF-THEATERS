using System.Collections.Concurrent;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;

namespace ZMFTheaters.Home;

/// Local private-cinema and companion host (ASP.NET Core / Kestrel inside the
/// app). Listens on the LAN only; every API call needs a bearer token from
/// /api/login (host access code) or /api/rooms/{id}/join (room invite code).
/// For guests outside the home network use an encrypted overlay such as
/// Tailscale — never forward this port to the internet.
public sealed class CinemaHost : IAsyncDisposable
{
    readonly HomeHub hub;
    WebApplication? app;
    public int Port { get; private set; }
    public string? Error { get; private set; }
    readonly ConcurrentDictionary<string, Session> sessions = new();
    readonly ConcurrentDictionary<string, (int count, DateTime window)> attempts = new();

    public sealed record Session(string Token, string Role, string Name, string? RoomId, string? MemberId, long ClockOffsetMs);

    public CinemaHost(HomeHub hub) { this.hub = hub; }

    public void Start(int port, bool loopbackOnly = false)
    {
        try
        {
            var builder = WebApplication.CreateSlimBuilder();
            builder.Logging.ClearProviders();
            builder.WebHost.ConfigureKestrel(k =>
            {
                if (loopbackOnly) k.Listen(IPAddress.Loopback, port); else k.Listen(IPAddress.Any, port);
            });
            builder.Services.ConfigureHttpJsonOptions(o => o.SerializerOptions.PropertyNamingPolicy = JsonNamingPolicy.CamelCase);
            app = builder.Build();
            Map(app);
            app.StartAsync().GetAwaiter().GetResult();
            Port = port;
        }
        catch (Exception ex) { Error = ex.Message; app = null; }
    }

    public bool Running => app != null;

    // MARK: Auth

    string NewToken() => Convert.ToBase64String(RandomNumberGenerator.GetBytes(24)).Replace('+', '-').Replace('/', '_').TrimEnd('=');

    bool Throttled(HttpContext ctx)
    {
        var ip = ctx.Connection.RemoteIpAddress?.ToString() ?? "?";
        var now = DateTime.UtcNow;
        var a = attempts.AddOrUpdate(ip, (1, now), (_, v) => (now - v.window).TotalMinutes > 1 ? (1, now) : (v.count + 1, v.window));
        return a.count > 8;   // brute-force protection for the short codes
    }

    Session? Auth(HttpContext ctx, string? role = null)
    {
        var h = ctx.Request.Headers.Authorization.ToString();
        if (!h.StartsWith("Bearer ")) return null;
        if (!sessions.TryGetValue(h[7..].Trim(), out var s)) return null;
        if (role != null && s.Role != role) return null;
        return s;
    }

    static bool CodeEquals(string a, string b) =>
        CryptographicOperations.FixedTimeEquals(System.Text.Encoding.UTF8.GetBytes(a.Trim().ToUpperInvariant()), System.Text.Encoding.UTF8.GetBytes(b.Trim().ToUpperInvariant()));

    public sealed record LoginBody(string Code, string? Name, long? ClientTimeMs);
    public sealed record JoinBody(string Invite, string Name);
    public sealed record ChatBody(string Text);
    public sealed record RoomBody(string Name, string? Genre);
    public sealed record AiBody(string Name, bool? Remove);
    public sealed record ControlBody(string Action, double? Position);
    public sealed record ReportBody(string MediaId, string? Title, double Position, bool Playing, long? ClientTimeMs);
    public sealed record SeatBody(string Seat);

    void Map(WebApplication a)
    {
        a.MapGet("/", () => Results.Redirect("/companion"));
        a.MapGet("/companion", () => Results.Content(CompanionPage.Html, "text/html; charset=utf-8"));
        a.MapGet("/api/time", (long? client) => Results.Json(new { serverMs = hub.NowMs, client }));

        a.MapPost("/api/login", (HttpContext ctx, LoginBody b) =>
        {
            if (Throttled(ctx)) return Results.StatusCode(429);
            if (!CodeEquals(b.Code ?? "", hub.Config.AccessCode())) return Results.Unauthorized();
            var offset = b.ClientTimeMs is long c and > 0 ? hub.NowMs - c : 0;
            var s = new Session(NewToken(), "host", string.IsNullOrWhiteSpace(b.Name) ? "Host" : b.Name!.Trim()[..Math.Min(32, b.Name!.Trim().Length)], null, null, offset);
            sessions[s.Token] = s;
            return Results.Json(new { token = s.Token, role = s.Role, name = s.Name });
        });

        // --- Host: status, devices, emergency stop, playback ---
        a.MapGet("/api/status", (HttpContext ctx) =>
        {
            if (Auth(ctx, "host") == null) return Results.Unauthorized();
            var d = hub.Director;
            return Results.Json(new
            {
                emergencyStopped = hub.Devices.EmergencyStopped,
                simulation = hub.Devices.SimulationMode,
                physicalEnabled = hub.Config.PhysicalEnabled && !hub.Config.VirtualOnly,
                devices = hub.Devices.Devices.Values.Select(v => new { v.Id, v.Kind, v.Name, v.Role, state = v.StateLabel, v.Detail, v.LatencyMs, v.ReportedOn, v.LastCommand, v.LastAck, v.LastError }),
                director = new { d.Scene, d.SceneConfidence, d.State, wind = d.WantWind, d.WindConfidence, light = d.Light },
                pc = hub.PcPlayback, phone = hub.PhonePlayback, phoneNote = hub.PhoneNote,
                telemetry = hub.Devices.Telemetry.Take(25),
                events = d.Log.TakeLast(15).Reverse(),
            });
        });
        a.MapPost("/api/estop", async (HttpContext ctx) =>
        {
            var s = Auth(ctx, "host");
            if (s == null) return Results.Unauthorized();
            await hub.EmergencyStopAsync("companion (" + s.Name + ")");
            return Results.Json(new { ok = true });
        });
        a.MapPost("/api/rearm", (HttpContext ctx) =>
        {
            if (Auth(ctx, "host") == null) return Results.Unauthorized();
            hub.Devices.Rearm();
            return Results.Json(new { ok = true });
        });
        a.MapPost("/api/playback/control", (HttpContext ctx, ControlBody b) =>
        {
            if (Auth(ctx, "host") == null) return Results.Unauthorized();
            if (b.Action is not ("play" or "pause" or "seek" or "back" or "forward")) return Results.BadRequest();
            hub.RequestControl(b.Action, b.Position ?? 0);
            return Results.Json(new { ok = true });
        });
        a.MapPost("/api/playback/report", (HttpContext ctx, ReportBody b) =>
        {
            var s = Auth(ctx, "host");
            if (s == null) return Results.Unauthorized();
            if (string.IsNullOrWhiteSpace(b.MediaId) || !double.IsFinite(b.Position)) return Results.BadRequest();
            hub.ReportPhone(b.MediaId, b.Title ?? "", b.Position, b.Playing, b.ClientTimeMs ?? 0, s.ClockOffsetMs);
            return Results.Json(new { ok = true, note = hub.PhoneNote, serverMs = hub.NowMs });
        });

        // --- Rooms ---
        a.MapGet("/api/rooms", (HttpContext ctx) =>
        {
            var s = Auth(ctx);
            if (s == null) return Results.Unauthorized();
            var rooms = hub.Rooms.Rooms.Where(r => s.Role == "host" || r.Id == s.RoomId)
                .Select(r => new { r.Id, r.Name, r.Genre, invite = s.Role == "host" ? r.InviteCode : null, members = r.Members.Where(m => m.Present).Select(m => new { m.Name, m.Kind, m.Seat, label = m.Kind == "AI" ? AiGuestEngine.EngineLabel : m.Kind }), playback = r.Playback });
            return Results.Json(rooms);
        });
        a.MapPost("/api/rooms", (HttpContext ctx, RoomBody b) =>
        {
            var s = Auth(ctx, "host");
            if (s == null) return Results.Unauthorized();
            var room = hub.Rooms.With(() =>
            {
                var r = new CinemaRoom { Name = string.IsNullOrWhiteSpace(b.Name) ? "Private Cinema" : b.Name.Trim()[..Math.Min(48, b.Name.Trim().Length)], Genre = b.Genre ?? "" };
                r.Members.Add(new RoomMember { Name = s.Name, Kind = "Host", Seat = r.FreeSeat() });
                hub.Rooms.Rooms.Add(r);
                return r;
            });
            hub.Rooms.Post(room, "system", "ZMF", $"Room created by {s.Name}");
            return Results.Json(new { room.Id, room.Name, invite = room.InviteCode });
        });
        a.MapDelete("/api/rooms/{id}", (HttpContext ctx, string id) =>
        {
            if (Auth(ctx, "host") == null) return Results.Unauthorized();
            var removed = hub.Rooms.With(() => hub.Rooms.Rooms.RemoveAll(r => r.Id == id));
            foreach (var kv in sessions.Where(kv => kv.Value.RoomId == id).ToList()) sessions.TryRemove(kv.Key, out _);
            return removed > 0 ? Results.Json(new { ok = true }) : Results.NotFound();
        });
        a.MapPost("/api/rooms/{id}/join", (HttpContext ctx, string id, JoinBody b) =>
        {
            if (Throttled(ctx)) return Results.StatusCode(429);
            var room = hub.Rooms.Find(id);
            if (room == null || !CodeEquals(b.Invite ?? "", room.InviteCode)) return Results.Unauthorized();
            var name = (b.Name ?? "").Trim();
            if (name.Length == 0) name = "Guest";
            name = name[..Math.Min(32, name.Length)];
            if (AiGuestEngine.Persona(name) != null) name += " (guest)";   // a real person can't pose as an AI guest
            var member = hub.Rooms.With(() =>
            {
                var m = new RoomMember { Name = name, Kind = "Guest", Seat = room.FreeSeat() };
                room.Members.Add(m);
                return m;
            });
            var s = new Session(NewToken(), "guest", name, room.Id, member.Id, 0);
            sessions[s.Token] = s;
            hub.Rooms.Post(room, "join", name, $"{name} joined and sat in {member.Seat}");
            return Results.Json(new { token = s.Token, role = "guest", room = room.Id, seat = member.Seat });
        });
        a.MapPost("/api/rooms/{id}/leave", (HttpContext ctx, string id) =>
        {
            var s = Auth(ctx);
            var room = hub.Rooms.Find(id);
            if (s == null || room == null || (s.Role != "host" && s.RoomId != id)) return Results.Unauthorized();
            hub.Rooms.With(() => { foreach (var m in room.Members.Where(m => m.Id == s.MemberId || (s.Role == "host" && m.Kind == "Host"))) m.Present = false; return 0; });
            hub.Rooms.Post(room, "leave", s.Name, $"{s.Name} left");
            if (s.Role == "guest") sessions.TryRemove(s.Token, out _);
            return Results.Json(new { ok = true });
        });
        a.MapGet("/api/rooms/{id}/events", (HttpContext ctx, string id, long? since) =>
        {
            var s = Auth(ctx);
            var room = hub.Rooms.Find(id);
            if (s == null || room == null || (s.Role != "host" && s.RoomId != id)) return Results.Unauthorized();
            var after = since ?? 0;
            return Results.Json(new
            {
                items = room.Items.Where(i => i.Seq > after).TakeLast(100),
                members = room.Members.Where(m => m.Present).Select(m => new { m.Name, m.Kind, m.Seat, label = m.Kind == "AI" ? AiGuestEngine.EngineLabel : m.Kind }),
                playback = new { room.Playback.Title, room.Playback.MediaId, position = room.Playback.PositionAt(hub.NowMs), room.Playback.Playing },
                serverMs = hub.NowMs,
            });
        });
        a.MapPost("/api/rooms/{id}/chat", (HttpContext ctx, string id, ChatBody b) =>
        {
            var s = Auth(ctx);
            var room = hub.Rooms.Find(id);
            if (s == null || room == null || (s.Role != "host" && s.RoomId != id)) return Results.Unauthorized();
            var text = (b.Text ?? "").Trim();
            if (text.Length == 0) return Results.BadRequest();
            hub.Rooms.Post(room, "chat", s.Name, text);
            var ai = room.Members.Where(m => m.Kind == "AI" && m.Present).Select(m => m.Name).ToList();
            foreach (var (guest, reply) in hub.Ai.Reply(ai, s.Name, text, room.Playback.Title, hub.Director.Scene.StartsWith("Dialogue")))
                hub.Rooms.Post(room, "chat", guest, reply, ai: true);
            return Results.Json(new { ok = true });
        });
        a.MapPost("/api/rooms/{id}/ai", (HttpContext ctx, string id, AiBody b) =>
        {
            if (Auth(ctx, "host") == null) return Results.Unauthorized();
            var room = hub.Rooms.Find(id);
            var persona = AiGuestEngine.Persona(b.Name ?? "");
            if (room == null || persona == null) return Results.NotFound();
            if (b.Remove == true)
            {
                hub.Rooms.With(() => room.Members.RemoveAll(m => m.Kind == "AI" && m.Name == persona.Name));
                hub.Rooms.Post(room, "leave", persona.Name, $"{persona.Name} (AI) left", ai: true);
                return Results.Json(new { ok = true });
            }
            if (room.Members.Any(m => m.Kind == "AI" && m.Name == persona.Name && m.Present)) return Results.Json(new { ok = true });
            var member = hub.Rooms.With(() => { var m = new RoomMember { Name = persona.Name, Kind = "AI", Seat = room.FreeSeat() }; room.Members.Add(m); return m; });
            hub.Rooms.Post(room, "join", persona.Name, $"{persona.Name} (AI · {persona.Tagline}) took seat {member.Seat}", ai: true);
            hub.Rooms.Post(room, "chat", persona.Name, hub.Ai.Greeting(persona), ai: true);
            return Results.Json(new { ok = true, seat = member.Seat });
        });
        a.MapPost("/api/rooms/{id}/seat", (HttpContext ctx, string id, SeatBody b) =>
        {
            var s = Auth(ctx);
            var room = hub.Rooms.Find(id);
            if (s == null || room == null || (s.Role != "host" && s.RoomId != id)) return Results.Unauthorized();
            var seat = (b.Seat ?? "").Trim().ToUpperInvariant();
            if (!System.Text.RegularExpressions.Regex.IsMatch(seat, "^[A-H][1-8]$") || room.Members.Any(m => m.Present && m.Seat == seat)) return Results.Conflict();
            hub.Rooms.With(() => { foreach (var m in room.Members.Where(m => m.Id == s.MemberId || (s.Role == "host" && m.Kind == "Host"))) m.Seat = seat; return 0; });
            hub.Rooms.Post(room, "system", s.Name, $"{s.Name} moved to {seat}");
            return Results.Json(new { ok = true });
        });
    }

    public async ValueTask DisposeAsync()
    {
        if (app != null) { try { await app.StopAsync(); } catch { } await app.DisposeAsync(); }
    }
}

using System.IO;
using System.Net;
using System.Net.Http;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace ZMFTheaters.Home;

/// Home 4DX regression tests (run by `--selftest-home <log>` in CI).
/// Everything here uses MOCK devices on localhost. No physical Tapo plug,
/// fan or Govee strip is available in CI, and nothing here verifies one.
public static class HomeSelfTest
{
    public static int Run(string path) => RunAsync(path).GetAwaiter().GetResult();

    static async Task<int> RunAsync(string path)
    {
        var log = new List<string> { "# ZMF Home 4DX self-test — MOCK DEVICES ONLY (no physical hardware available here)" };
        void Check(bool ok, string name) => log.Add($"{(ok ? "PASS" : "FAIL")} {name}");
        try
        {
            KlapVectors(Check);
            DiscoveryAndGovee(Check);
            Gate(Check);
            Director(Check);
            Timeline(Check);
            await MockPlugEndToEnd(Check);
            await PowerChain(Check);
            await HostEndToEnd(Check);
            await IdleSafety(Check);
        }
        catch (Exception ex) { log.Add("FAIL unexpected exception: " + ex); }
        log.Add("PHYSICAL HARDWARE: not available in this environment — no device was physically verified.");
        File.WriteAllLines(path, log);
        return log.Any(l => l.StartsWith("FAIL")) ? 1 : 0;
    }

    static byte[] Hex(string h) => Convert.FromHexString(h);

    // Reference values produced by python-kasa 0.12.0 (KlapTransportV2 / KlapEncryptionSession).
    static void KlapVectors(Action<bool, string> Check)
    {
        var ls = Enumerable.Range(0, 16).Select(i => (byte)i).ToArray();
        var rs = Enumerable.Range(100, 16).Select(i => (byte)i).ToArray();
        var auth = Klap.AuthHashV2("user@example.com", "S3cret!");
        Check(Convert.ToHexString(auth).ToLowerInvariant() == "96d5f1e307a37dba7126963ca2029965daa7b753889811d0ff378d3dd4a40343", "[tapo] KLAP v2 auth hash matches python-kasa");
        Check(Convert.ToHexString(Klap.AuthHashV1("user@example.com", "S3cret!")).ToLowerInvariant() == "7d6acc6da3208799805abd7b6e416432", "[tapo] KLAP v1 auth hash matches python-kasa");
        Check(Convert.ToHexString(Klap.Handshake1V2(ls, rs, auth)).ToLowerInvariant() == "94389e7b328a28ac2a7ed9988377f5469ad1c33c4c8530d4fc1d056e0efdc544", "[tapo] handshake1 hash matches python-kasa");
        Check(Convert.ToHexString(Klap.Handshake2V2(ls, rs, auth)).ToLowerInvariant() == "33cbfd8abc539730ced515cdd80bfd1cdb308a2317e1e12c249a5bf6ec090481", "[tapo] handshake2 hash matches python-kasa");
        var s = new KlapSession(ls, rs, auth);
        var (payload, seq) = s.Encrypt("{\"method\":\"get_device_info\"}");
        Check(seq == -411554946 && Convert.ToHexString(payload).ToLowerInvariant() ==
            "1c829b5f8e3b29dd15b48226635702afbb6269d392b137b9d037a50b1fd4c69798e07ee429e7896897700659ce956b372cc175df0765fa079c7e56c5bca985da",
            "[tapo] encrypted request (signature + AES-CBC) is byte-identical to python-kasa");
        Check(s.Decrypt(payload) == "{\"method\":\"get_device_info\"}", "[tapo] request decrypts");
    }

    static void DiscoveryAndGovee(Action<bool, string> Check)
    {
        using var rsa = RSA.Create(2048);
        var q = TapoDiscovery.BuildQuery(rsa, 0x01020304);
        var copy = (byte[])q.Clone();
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32BigEndian(copy.AsSpan(12), 0x5A6B7C8D);
        Check(q[0] == 2 && q[3] == 1 && q[6] == 17 && System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(q.AsSpan(12)) == TapoDiscovery.Crc32(copy),
            "[tapo] discovery probe header and CRC are well-formed");
        Check(TapoDiscovery.Crc32(Encoding.ASCII.GetBytes("123456789")) == 0xCBF43926, "[tapo] CRC-32 reference value");
        var reply = Encoding.UTF8.GetBytes("0123456789abcdef" + """{"error_code":0,"result":{"device_id":"abc","device_type":"SMART.TAPOPLUG","device_model":"P125M(US)","ip":"192.168.1.40","mac":"AA-BB-CC-DD-EE-FF","factory_default":false,"mgt_encrypt_schm":{"is_support_https":false,"encrypt_type":"KLAP","http_port":80,"lv":2}}}""");
        var d = TapoDiscovery.Parse(reply, "192.168.1.40");
        Check(d is { Model: "P125M(US)", EncryptType: "KLAP", HttpPort: 80, Ip: "192.168.1.40" }, "[tapo] P125M discovery reply parsed (sample reply, not a live device)");

        Check(Convert.ToHexString(GoveeProtocol.Power(true)).ToLowerInvariant() == "3301010000000000000000000000000000000033", "[govee] power-on packet matches community capture");
        Check(Convert.ToHexString(GoveeProtocol.Power(false)).ToLowerInvariant() == "3301000000000000000000000000000000000032", "[govee] power-off packet matches community capture");
        Check(Convert.ToHexString(GoveeProtocol.KeepAlive()).ToLowerInvariant() == "aa010000000000000000000000000000000000ab", "[govee] keep-alive packet matches community capture");
        var c = GoveeProtocol.Color(0, 0, 255, GoveeProtocol.ColorVariant.Manual02);
        Check(c[0] == 0x33 && c[1] == 0x05 && c[2] == 0x02 && c[5] == 255 && c[19] == (byte)(0x33 ^ 0x05 ^ 0x02 ^ 255), "[govee] colour packet + XOR checksum");
        Check(GoveeProtocol.ModelFromName("ihoment_H6163_A1B2") == "H6163" && GoveeProtocol.ModelFromName("Govee_H6199_1234") == "H6199" && GoveeProtocol.ModelFromName("JBL Flip") == null,
            "[govee] model number read from the Bluetooth name");
    }

    static void Gate(Action<bool, string> Check)
    {
        var g = new PowerGate { MinOnSeconds = 8, MinOffSeconds = 12, MaxSwitchesPerHour = 4 };
        var t = new DateTime(2026, 10, 27, 20, 0, 0, DateTimeKind.Utc);
        Check(g.Evaluate(true, t).verdict == PowerGate.Verdict.Switch, "[gate] first ON allowed");
        g.Commit(true, t);
        Check(g.Evaluate(true, t.AddSeconds(1)).verdict == PowerGate.Verdict.Duplicate, "[gate] duplicate ON suppressed");
        Check(g.Evaluate(false, t.AddSeconds(3)).verdict == PowerGate.Verdict.Hold, "[gate] scene OFF waits for minimum on-time");
        Check(g.Evaluate(false, t.AddSeconds(3), safetyOff: true).verdict == PowerGate.Verdict.Switch, "[gate] pause/stop OFF is immediate");
        g.Commit(false, t.AddSeconds(3));
        Check(g.Evaluate(true, t.AddSeconds(6)).verdict == PowerGate.Verdict.Hold, "[gate] cooldown blocks rapid re-switching");
        var now = t.AddSeconds(20);
        for (int i = 0; i < 3; i++) { g.Commit(true, now); now = now.AddSeconds(15); g.Commit(false, now); now = now.AddSeconds(15); }
        Check(g.Evaluate(true, now).verdict == PowerGate.Verdict.Blocked, "[gate] hourly switch budget enforced");
        var g2 = new PowerGate { MaxOnSeconds = 60 };
        g2.Commit(true, t);
        Check(g2.CutoffDue(t.AddSeconds(61)), "[gate] continuous-on safety cutoff");
        g2.EmergencyStop();
        Check(g2.Evaluate(false, t.AddSeconds(30)).verdict != PowerGate.Verdict.Blocked && new PowerGate().Evaluate(true, t).verdict == PowerGate.Verdict.Switch, "[gate] OFF is never blocked");
        var g3 = new PowerGate(); g3.EmergencyStop();
        Check(g3.Evaluate(true, t).verdict == PowerGate.Verdict.Blocked, "[gate] emergency stop blocks ON");
    }

    static SceneInputs In(double t, double wind = 0, double speed = 0, double low = 0, double speech = 0, double shock = 0, bool playing = true,
        double r = 90, double g = 90, double b = 90, double bright = 0.4, string? ev = null, double evT = -10, AnalysisSource src = AnalysisSource.Analysed) =>
        new("test-movie", t, playing, src, wind, speed, low, speech, shock, true, r, g, b, bright, 0, ev, evT);

    static void Director(Action<bool, string> Check)
    {
        var d = new SceneDirector();
        double t = 0;
        for (; t < 2; t += 0.1) d.Update(In(t, wind: 0.8, speed: 0.6, low: 0.5), 0.1);
        Check(!d.WantWind, "[director] wind is not requested for a short burst (<3 s)");
        for (; t < 6; t += 0.1) d.Update(In(t, wind: 0.8, speed: 0.6, low: 0.5), 0.1);
        Check(d.WantWind && d.Scene.Contains("engine-like"), "[director] sustained motion + engine-like rumble requests wind");
        d.Update(In(t, wind: 0.8, speed: 0.6, low: 0.5, playing: false), 0.1);
        Check(!d.WantWind && d.State.StartsWith("Paused"), "[director] pause cancels wind immediately");
        for (t += 0.1; t < 12; t += 0.1) d.Update(In(t, wind: 0.8, speed: 0.6, low: 0.5), 0.1);
        d.Update(In(t + 30, wind: 0.8, speed: 0.6, low: 0.5), 0.1);
        Check(!d.WantWind, "[director] forward seek discards the active wind state");

        var music = new SceneDirector();
        for (double m = 0; m < 30; m += 0.1) music.Update(In(m, wind: 0.05, speed: 0.05, low: 0.9, speech: 0.3), 0.1);
        Check(!music.WantWind, "[director] loud background music alone never starts the fan");
        var dialogue = new SceneDirector();
        for (double m = 0; m < 20; m += 0.1) dialogue.Update(In(m, wind: 0.4, speed: 0.1, low: 0.1, speech: 0.8), 0.1);
        Check(!dialogue.WantWind && dialogue.Scene.StartsWith("Dialogue") && dialogue.Light.Brightness < 0.3, "[director] dialogue scenes stay calm (no wind, dim warm light)");

        var flicker = new SceneDirector();
        var palettes = new HashSet<string>();
        for (double m = 0; m < 20; m += 0.1) { var blue = ((int)m) % 2 == 0; flicker.Update(In(m, r: blue ? 20 : 200, g: blue ? 60 : 60, b: blue ? 200 : 20), 0.1); palettes.Add(flicker.Light.Palette); }
        Check(palettes.Count <= 1, "[director] colour changes every second do not make the room flicker (palette stabilisation)");
        var ocean = new SceneDirector();
        for (double m = 0; m < 8; m += 0.1) ocean.Update(In(m, r: 10, g: 110, b: 170), 0.1);
        Check(ocean.Light.Palette == "ocean", "[director] sustained sea-blue picture selects the ocean palette");

        var boom = new SceneDirector { Flashes = FlashPolicy.Reduced };
        for (double m = 0; m < 3; m += 0.1) boom.Update(In(m, bright: 0.3), 0.1);
        var before = boom.Light.Brightness;
        boom.Update(In(3, shock: 0.8, bright: 0.3, ev: "Boom", evT: 3), 0.1);
        var peak = boom.Light.Brightness;
        Check(peak > before && peak - before <= 0.15, "[director] boom = brief bounded warm swell (reduced-flash policy)");
        var noFlash = new SceneDirector { Flashes = FlashPolicy.NoFlashing };
        for (double m = 0; m < 3; m += 0.1) noFlash.Update(In(m, bright: 0.3), 0.1);
        var b0 = noFlash.Light.Brightness;
        noFlash.Update(In(3, shock: 0.8, bright: 0.3, ev: "Boom", evT: 3), 0.1);
        Check(noFlash.Light.Brightness <= b0 + 0.01, "[director] no-flashing policy suppresses the swell");
        var cut = new SceneDirector();
        var cutEvents = 0;
        cut.Emitted += e => { if (e.Type == "Blast") cutEvents++; };
        for (double m = 0; m < 10; m += 0.1) cut.Update(In(m, bright: ((int)(m * 10)) % 2 == 0 ? 0.05 : 0.95), 0.1);
        Check(cutEvents == 0, "[director] scene cuts / brightness changes alone create no blast");
        var yt = new SceneDirector();
        for (double m = 0; m < 10; m += 0.1) yt.Update(In(m, wind: 1, speed: 1, low: 1, src: AnalysisSource.ExternalUnanalysable), 0.1);
        Check(!yt.WantWind && yt.State.Contains("disabled"), "[director] unanalysable sources (YouTube) disable automatic physical effects");
    }

    static void Timeline(Action<bool, string> Check)
    {
        var d = new SceneDirector();
        var tl = new EffectTimeline { MediaId = "test-movie" };
        d.Emitted += e => tl.Record(e, d.Light);
        double t = 0;
        for (; t < 10; t += 0.1) d.Update(In(t, wind: 0.9, speed: 0.7, low: 0.6), 0.1);
        for (; t < 20; t += 0.1) d.Update(In(t, wind: 0, speed: 0, low: 0), 0.1);
        Check(tl.Wind.Count == 1 && tl.WindAt(6) && !tl.WindAt(19), "[timeline] analysed wind segment recorded");
        var replay = new SceneDirector();
        replay.ApplyTimeline(tl, 6, true, 0.1);
        var on = replay.WantWind;
        replay.ApplyTimeline(tl, 6.1, false, 0.1);
        Check(on && !replay.WantWind, "[timeline] phone-position replay drives wind and pause cancels it");
    }

    // MARK: Mock Tapo plug speaking real KLAP over HTTP on localhost

    sealed class MockKlapDevice : IAsyncDisposable
    {
        readonly WebApplication app;
        readonly byte[] auth;
        byte[]? local, remote;
        KlapSession? session;
        public bool On;
        public int Requests;
        public int Port { get; }

        public MockKlapDevice(string user, string password, int port)
        {
            Port = port;
            auth = Klap.AuthHashV2(user, password);
            var b = WebApplication.CreateSlimBuilder();
            b.Logging.ClearProviders();
            b.WebHost.ConfigureKestrel(k => k.Listen(IPAddress.Loopback, port));
            app = b.Build();
            app.MapPost("/app/handshake1", async (HttpContext ctx) =>
            {
                local = await ReadAll(ctx);
                remote = RandomNumberGenerator.GetBytes(16);
                ctx.Response.Headers.SetCookie = "TP_SESSIONID=MOCKSESSION;TIMEOUT=86400";
                await ctx.Response.Body.WriteAsync(Klap.Concat(remote, Klap.Handshake1V2(local, remote, auth)));
            });
            app.MapPost("/app/handshake2", async (HttpContext ctx) =>
            {
                var h = await ReadAll(ctx);
                if (local == null || remote == null || !h.AsSpan().SequenceEqual(Klap.Handshake2V2(local, remote, auth))) { ctx.Response.StatusCode = 403; return; }
                session = new KlapSession(local, remote, auth);
            });
            app.MapPost("/app/request", async (HttpContext ctx) =>
            {
                if (session == null || !ctx.Request.Headers.Cookie.ToString().Contains("TP_SESSIONID=MOCKSESSION")) { ctx.Response.StatusCode = 403; return; }
                var seq = int.Parse(ctx.Request.Query["seq"]!);
                var body = await ReadAll(ctx);
                session.UseSeq(seq);
                using var doc = JsonDocument.Parse(session.Decrypt(body));
                Requests++;
                var method = doc.RootElement.GetProperty("method").GetString();
                if (method == "set_device_info") On = doc.RootElement.GetProperty("params").GetProperty("device_on").GetBoolean();
                var result = method == "get_device_info"
                    ? JsonSerializer.Serialize(new { error_code = 0, result = new { device_on = On, model = "P125M", nickname = Convert.ToBase64String(Encoding.UTF8.GetBytes("Mock Fan Plug")), mac = "AA-BB-CC-DD-EE-FF", device_id = "mock", fw_ver = "mock", rssi = -45 } })
                    : "{\"error_code\":0}";
                await ctx.Response.Body.WriteAsync(session.EncryptResponse(result));
            });
            app.StartAsync().GetAwaiter().GetResult();
        }

        static async Task<byte[]> ReadAll(HttpContext ctx) { using var ms = new MemoryStream(); await ctx.Request.Body.CopyToAsync(ms); return ms.ToArray(); }
        public async ValueTask DisposeAsync() { await app.StopAsync(); await app.DisposeAsync(); }
    }

    static int FreePort() { var l = new System.Net.Sockets.TcpListener(IPAddress.Loopback, 0); l.Start(); var p = ((IPEndPoint)l.LocalEndpoint).Port; l.Stop(); return p; }

    static async Task MockPlugEndToEnd(Action<bool, string> Check)
    {
        await using var dev = new MockKlapDevice("me@example.com", "Pa55word!", FreePort());
        using (var bad = new TapoClient("127.0.0.1", "me@example.com", "wrong", dev.Port))
        {
            var rejected = false;
            try { await bad.GetInfoAsync(CancellationToken.None); } catch (TapoException) { rejected = true; }
            Check(rejected, "[tapo/mock] wrong password is rejected by the KLAP handshake");
        }
        using var client = new TapoClient("127.0.0.1", "me@example.com", "Pa55word!", dev.Port);
        await client.SetOnAsync(true, CancellationToken.None);
        var info = await client.GetInfoAsync(CancellationToken.None);
        Check(info.On && dev.On && info.Model == "P125M" && info.Nickname == "Mock Fan Plug", "[tapo/mock] authenticated ON + status round trip over KLAP");
        await client.SetOnAsync(false, CancellationToken.None);
        Check(!(await client.GetInfoAsync(CancellationToken.None)).On, "[tapo/mock] OFF confirmed by reported state");

        // Full automation path: director → controller → KLAP → (mock) plug.
        var cfg = new HomeConfig { PhysicalEnabled = true };
        cfg.TapoUser = "me@example.com"; cfg.TapoPassword = "Pa55word!";
        var plug = cfg.Plugs.First(p => p.Slot == "TAPO_01");
        plug.Ip = "127.0.0.1"; plug.HttpPort = dev.Port; plug.Authorized = true;
        await using var ctl = new HomeController(cfg, () => { });
        var clock = new DateTime(2026, 10, 27, 21, 0, 0, DateTimeKind.Utc);
        ctl.Clock = () => clock;
        await ctl.ReconnectAsync("TAPO_01", CancellationToken.None);
        Check(ctl.Devices["TAPO_01"].State == DeviceState.ConnectedUnverified, "[controller] reachable but untested plug shows CONNECTED — UNVERIFIED OUTPUT");

        var d = new SceneDirector();
        for (double t = 0; t < 6; t += 0.1) d.Update(In(t, wind: 0.9, speed: 0.7, low: 0.6), 0.1);
        ctl.Apply(d, 6);
        await Task.Delay(300);
        Check(!dev.On, "[controller] wind automation refused until the fan restart test passes");
        plug.PlugTestPassed = true; plug.FanRestartVerified = true;
        ctl.Apply(d, 6);
        await WaitFor(() => ctl.Devices["TAPO_01"].LastAck.Contains("ON"));
        Check(dev.On && ctl.Devices["TAPO_01"].LastAck.Contains("ON"), "[controller] verified fan: scene wind turns the plug ON with acknowledgement");
        clock = clock.AddSeconds(2);
        await ctl.SuspendAsync("paused");
        Check(!dev.On, "[controller] pause turns the fan off immediately");
        clock = clock.AddSeconds(3);
        ctl.Apply(d, 9);
        await Task.Delay(300);
        Check(!dev.On, "[controller] cooldown prevents rapid re-switching after pause");
        await ctl.StopAllEffectsAsync("self-test");
        clock = clock.AddSeconds(60);
        ctl.Apply(d, 70);
        await Task.Delay(300);
        Check(!dev.On && ctl.EmergencyStopped, "[controller] emergency stop keeps everything off");
        ctl.Rearm();
        plug.Essential = true;
        var refused = !await ctl.SetPlugAsync("TAPO_01", true, "manual test", CancellationToken.None);
        Check(refused && !dev.On, "[controller] a plug marked as essential equipment is never switched");
    }

    static async Task WaitFor(Func<bool> cond, int ms = 3000)
    {
        var until = DateTime.UtcNow.AddMilliseconds(ms);
        while (!cond() && DateTime.UtcNow < until) await Task.Delay(25);
    }

    static async Task IdleSafety(Action<bool, string> Check)
    {
        var cfg = new HomeConfig { PhysicalEnabled = true };
        await using var hub = new HomeHub(cfg, () => { }, new RoomStore(null));
        var plug = new MockPlug();
        hub.Devices.UseMocks(plug);
        var now = new DateTime(2026, 10, 27, 22, 0, 0, DateTimeKind.Utc);
        hub.Clock = () => now; hub.Devices.Clock = () => now;
        for (double t = 0; t < 6; t += 0.1)
        {
            now = now.AddMilliseconds(100);
            hub.ReportPc("film", "Film", t, true, AnalysisSource.Analysed);
            hub.Director.Update(In(t, wind: 0.9, speed: 0.7, low: 0.6), 0.1);
            hub.Tick(0.1);
        }
        await WaitFor(() => plug.On);
        Check(plug.On, "[safety] simulated wind ON during playback (SIMULATED device)");
        now = now.AddSeconds(30);
        hub.Tick(0.1);
        await WaitFor(() => !plug.On);
        Check(!plug.On, "[safety] when playback goes silent the automated fan turns off by itself");
    }

    // MARK: TAPO_02 -> Govee power-chain, all simulated

    static async Task PowerChain(Action<bool, string> Check)
    {
        var cfg = new HomeConfig { PhysicalEnabled = true };
        cfg.Migrate();
        var supply = cfg.Plugs.First(p => p.Slot == "TAPO_02");
        Check(supply.IsLightPower && supply.Role == "GOVEE_POWER" &&
            !supply.LightPowerAutomationAllowed, "[power chain] TAPO_02 defaults to Govee power, DISARMED");
        supply.Authorized = true; supply.PlugTestPassed = true;
        cfg.Light.Authorized = true; cfg.Light.ColorVerified = true;
        Check(!supply.LightPowerAutomationAllowed, "[power chain] unverified Govee power restore blocks real automation");
        supply.LightPowerRestoreVerified = true;
        Check(supply.LightPowerAutomationAllowed, "[power chain] confirmed strip power restart arms its source");
        supply.Essential = true;
        Check(!supply.LightPowerAutomationAllowed, "[power chain] essential-device override always blocks source");
        supply.Essential = false;

        await using var ctl = new HomeController(cfg, () => { });
        var fakeLight = new MockLight();
        ctl.UseMocks(null, fakeLight);
        var clock = new DateTime(2026, 10, 27, 20, 0, 0, DateTimeKind.Utc);
        ctl.Clock = () => clock;
        var director = new SceneDirector();
        for (double x = 0; x < 7; x += 0.1)
            director.Update(In(x, wind: 0.05, speed: 0.05, low: 0.05, r: 20, g: 70, b: 180), 0.1);
        ctl.Apply(director, 7);
        await WaitFor(() => ctl.Devices["TAPO_02"].ReportedOn == true);
        Check(ctl.Devices["TAPO_02"].ReportedOn == true, "[power chain/mock] analysed playback switches Govee source ON");
        ctl.Apply(director, 7.1);
        await WaitFor(() => fakeLight.Packets.Count >= 2);
        Check(fakeLight.Packets.Count >= 2, "[power chain/mock] BLE colour and brightness follow confirmed source power");
        await ctl.SuspendAsync("paused");
        Check(ctl.Devices["TAPO_02"].ReportedOn == false, "[power chain/mock] pause switches source OFF");
        ctl.Apply(director, 7.2);
        await Task.Delay(150);
        Check(ctl.Devices["TAPO_02"].ReportedOn == false, "[power chain/mock] 60s off cooldown prevents rapid LED cycling");
        clock = clock.AddSeconds(65);
        ctl.Apply(director, 70);
        await WaitFor(() => ctl.Devices["TAPO_02"].ReportedOn == true);
        await ctl.StopAllEffectsAsync("test");
        Check(ctl.Devices["TAPO_02"].ReportedOn == false && ctl.EmergencyStopped,
            "[power chain/mock] emergency stop drops LED power");
        var unauthorized = new HomePlug { Slot = "TAPO_02", Role = "GOVEE_POWER", PlugTestPassed = true, LightPowerRestoreVerified = true };
        Check(!unauthorized.LightPowerAutomationAllowed, "[power chain] never authorize a plug just because it passed tests");
    }

    // MARK: Private cinema host

    static async Task HostEndToEnd(Action<bool, string> Check)
    {
        var dir = Path.Combine(Path.GetTempPath(), "zmf-selftest-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(dir);
        var cfg = new HomeConfig();
        await using var hub = new HomeHub(cfg, () => { }, new RoomStore(Path.Combine(dir, "rooms.json")));
        hub.Devices.UseMocks();
        var port = FreePort();
        var host = new CinemaHost(hub);
        host.Start(port, loopbackOnly: true);
        await using var _h = host;
        Check(host.Running, "[host] private cinema host starts on localhost");
        using var http = new HttpClient { BaseAddress = new Uri($"http://127.0.0.1:{port}") };
        Check((await http.GetAsync("/api/status")).StatusCode == HttpStatusCode.Unauthorized, "[host] API rejects requests without a token");
        Check((await http.PostAsJsonAsync("/api/login", new { code = "WRONGCODE" })).StatusCode == HttpStatusCode.Unauthorized, "[host] wrong access code rejected");
        var login = await (await http.PostAsJsonAsync("/api/login", new { code = cfg.AccessCode(), name = "Zach", clientTimeMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() })).Content.ReadFromJsonAsync<JsonElement>();
        var hostToken = login.GetProperty("token").GetString()!;
        HttpRequestMessage Req(HttpMethod m, string url, string token, object? body = null)
        {
            var r = new HttpRequestMessage(m, url);
            r.Headers.Authorization = new System.Net.Http.Headers.AuthenticationHeaderValue("Bearer", token);
            if (body != null) r.Content = JsonContent.Create(body);
            return r;
        }
        Check((await http.SendAsync(Req(HttpMethod.Get, "/api/status", hostToken))).IsSuccessStatusCode, "[host] host token can read 4DX status");
        var room = await (await http.SendAsync(Req(HttpMethod.Post, "/api/rooms", hostToken, new { name = "Zach's Private Cinema" }))).Content.ReadFromJsonAsync<JsonElement>();
        var roomId = room.GetProperty("id").GetString()!;
        var invite = room.GetProperty("invite").GetString()!;
        Check(roomId.Length > 0 && invite.Length == 8, "[host] room created with an invite code");
        Check((await http.PostAsJsonAsync($"/api/rooms/{roomId}/join", new { invite = "BADCODE1", name = "Eve" })).StatusCode == HttpStatusCode.Unauthorized, "[host] wrong invite code rejected");
        var join = await (await http.PostAsJsonAsync($"/api/rooms/{roomId}/join", new { invite, name = "Sam" })).Content.ReadFromJsonAsync<JsonElement>();
        var guest = join.GetProperty("token").GetString()!;
        Check(join.GetProperty("seat").GetString()!.Length == 2, "[host] authenticated test guest joined and got a seat");
        Check((await http.SendAsync(Req(HttpMethod.Get, "/api/status", guest))).StatusCode == HttpStatusCode.Unauthorized, "[host] guests cannot see or control home devices");
        Check((await http.SendAsync(Req(HttpMethod.Post, "/api/estop", guest))).StatusCode == HttpStatusCode.Unauthorized, "[host] guests cannot trigger device commands");
        await http.SendAsync(Req(HttpMethod.Post, $"/api/rooms/{roomId}/ai", hostToken, new { name = "Nova" }));
        await http.SendAsync(Req(HttpMethod.Post, $"/api/rooms/{roomId}/chat", guest, new { text = "Hi Nova, what do you think so far?" }));
        var ev = await (await http.SendAsync(Req(HttpMethod.Get, $"/api/rooms/{roomId}/events?since=0", guest))).Content.ReadFromJsonAsync<JsonElement>();
        var items = ev.GetProperty("items").EnumerateArray().ToList();
        Check(items.Any(i => i.GetProperty("kind").GetString() == "chat" && i.GetProperty("from").GetString() == "Sam"), "[host] guest chat message delivered");
        Check(items.Count(i => i.GetProperty("ai").GetBoolean() && i.GetProperty("from").GetString() == "Nova") >= 2, "[ai] AI guest joined, greeted and replied (labelled AI)");
        Check(ev.GetProperty("members").EnumerateArray().Any(m => m.GetProperty("label").GetString()!.Contains("scripted")), "[ai] AI guest is labelled as a scripted AI, not a person");
        var pos = await (await http.SendAsync(Req(HttpMethod.Post, "/api/playback/report", hostToken, new { mediaId = "test-movie", title = "Test Film", position = 120.0, playing = true, clientTimeMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() }))).Content.ReadFromJsonAsync<JsonElement>();
        Check(hub.PhonePlayback is { MediaId: "test-movie", Playing: true } p && Math.Abs(p.Position - 120) < 2, "[sync] phone playback report received with clock-offset correction");
        hub.Tick(0.1);
        Check(hub.PhoneNote.Contains("No analysed"), "[sync] without an analysed timeline the phone gets no invented physical effects");
        string? control = null;
        hub.ControlRequested += (a, _) => control = a;
        await http.SendAsync(Req(HttpMethod.Post, "/api/playback/control", hostToken, new { action = "pause" }));
        Check(control == "pause", "[sync] companion pause reaches the PC player");
        await http.SendAsync(Req(HttpMethod.Post, "/api/estop", hostToken));
        Check(hub.Devices.EmergencyStopped, "[safety] emergency stop from the phone companion");
        var page = await http.GetStringAsync("/companion");
        Check(page.Contains("EMERGENCY STOP") && page.Contains("AI · scripted"), "[companion] web companion page served");
        for (int i = 0; i < 9; i++) await http.PostAsJsonAsync("/api/login", new { code = "X" });
        Check((await http.PostAsJsonAsync("/api/login", new { code = "X" })).StatusCode == (HttpStatusCode)429, "[host] repeated wrong codes are throttled");
        var reloaded = new RoomStore(Path.Combine(dir, "rooms.json"));
        Check(reloaded.Find(roomId) is { } r2 && r2.Items.Count > 3, "[host] rooms and chat persist across restarts");
        try { Directory.Delete(dir, true); } catch { }
    }
}

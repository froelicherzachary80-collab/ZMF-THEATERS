using System.Collections.Concurrent;
using System.Diagnostics;

namespace ZMFTheaters.Home;

public interface IPlugTransport : IDisposable
{
    Task<TapoInfo> GetInfoAsync(CancellationToken ct);
    Task SetOnAsync(bool on, CancellationToken ct);
    bool IsMock { get; }
}

public interface ILightTransport : IAsyncDisposable
{
    Task<double> WriteAsync(byte[] packet, CancellationToken ct);
    bool Connected { get; }
    bool IsMock { get; }
}

sealed class TapoTransport(TapoClient client) : IPlugTransport
{
    public Task<TapoInfo> GetInfoAsync(CancellationToken ct) => client.GetInfoAsync(ct);
    public Task SetOnAsync(bool on, CancellationToken ct) => client.SetOnAsync(on, ct);
    public bool IsMock => false;
    public void Dispose() => client.Dispose();
}

sealed class GoveeTransport(GoveeBle ble) : ILightTransport
{
    public Task<double> WriteAsync(byte[] packet, CancellationToken ct) => ble.WriteAsync(packet, ct);
    public bool Connected => ble.Connected;
    public bool IsMock => false;
    public ValueTask DisposeAsync() => ble.DisposeAsync();
}

/// In-memory plug for tests and the "simulation" mode. Always SIMULATED.
public sealed class MockPlug : IPlugTransport
{
    public bool On { get; private set; }
    public int Commands { get; private set; }
    public bool Fail { get; set; }
    public Task<TapoInfo> GetInfoAsync(CancellationToken ct) => Fail ? throw new TapoException("mock unreachable") : Task.FromResult(new TapoInfo(On, "MOCK-P125M", "Mock plug", "00:00:00:00:00:00", "mock", "mock", -40));
    public Task SetOnAsync(bool on, CancellationToken ct) { if (Fail) throw new TapoException("mock unreachable"); On = on; Commands++; return Task.CompletedTask; }
    public bool IsMock => true;
    public void Dispose() { }
}

public sealed class MockLight : ILightTransport
{
    public List<byte[]> Packets { get; } = new();
    public Task<double> WriteAsync(byte[] packet, CancellationToken ct) { lock (Packets) Packets.Add(packet); return Task.FromResult(1.0); }
    public bool Connected => true;
    public bool IsMock => true;
    public ValueTask DisposeAsync() => ValueTask.CompletedTask;
}

public sealed class DeviceStatus
{
    public required string Id { get; init; }
    public required string Kind { get; init; }           // "Tapo plug", "Govee strip"
    public string Name { get; set; } = "";
    public string Role { get; set; } = "";
    public DeviceState State { get; set; } = DeviceState.Disconnected;
    public string Detail { get; set; } = "";
    public double LatencyMs { get; set; } = -1;
    public bool? ReportedOn { get; set; }
    public string LastCommand { get; set; } = "";
    public string LastAck { get; set; } = "";
    public string LastError { get; set; } = "";
    public DateTime LastSeen { get; set; }
    public string StateLabel => DeviceStateText.Label(State);
}

public sealed record TelemetryEntry(DateTime At, string Device, string Command, string Ack, double LatencyMs, double MediaTime, double Confidence, string Scene, string Reason);

/// Owns all physical home devices. Commands run on background tasks with
/// timeouts (never on the render thread), every switch passes the PowerGate,
/// and the emergency stop overrides everything.
public sealed class HomeController : IAsyncDisposable
{
    readonly HomeConfig cfg;
    readonly Action save;
    readonly ConcurrentDictionary<string, IPlugTransport> plugs = new();
    readonly ConcurrentDictionary<string, PowerGate> gates = new();
    readonly ConcurrentDictionary<string, SemaphoreSlim> locks = new();
    readonly ConcurrentDictionary<string, bool> inflight = new();
    ILightTransport? light;
    readonly ConcurrentQueue<TelemetryEntry> telemetry = new();
    public Dictionary<string, DeviceStatus> Devices { get; } = new();
    public bool EmergencyStopped { get; private set; }
    public bool SimulationMode { get; private set; }
    public Func<DateTime> Clock { get; set; } = () => DateTime.UtcNow;
    public event Action? Changed;
    public static readonly TimeSpan CommandTimeout = TimeSpan.FromSeconds(4);
    (byte r, byte g, byte b, double bright)? lastLight;
    DateTime lastLightWrite = DateTime.MinValue;
    DateTime lightPowerReadyAt = DateTime.MinValue;
    bool lightWriteBusy;
    int lightReconnectBusy;
    DateTime nextLightReconnect = DateTime.MinValue;

    public HomeController(HomeConfig cfg, Action save)
    {
        this.cfg = cfg; this.save = save;
        cfg.Migrate();
        foreach (var p in cfg.Plugs)
            Devices[p.Slot] = new DeviceStatus { Id = p.Slot, Kind = "Tapo plug", Name = p.Nickname.Length > 0 ? p.Nickname : p.Slot, Role = p.Role, Detail = p.Ip.Length > 0 ? p.Ip : "not set up" };
        Devices["GOVEE"] = new DeviceStatus { Id = "GOVEE", Kind = "Govee strip", Name = cfg.Light.Model.Length > 0 ? "Govee " + cfg.Light.Model : "Govee RGBIC strip", Role = "LIGHTING",
            Detail = cfg.Light.Address == 0 ? "not set up" : GoveeProtocol.Describe(cfg.Light.Variant) };
    }

    public HomePlug Plug(string slot) => cfg.Plugs.First(p => p.Slot == slot);
    public IEnumerable<TelemetryEntry> Telemetry => telemetry.ToArray().Reverse();

    void Log(string device, string command, string ack, double latency, double mediaTime = double.NaN, double confidence = 0, string scene = "", string reason = "")
    {
        telemetry.Enqueue(new TelemetryEntry(Clock(), device, command, ack, latency, mediaTime, confidence, scene, reason));
        while (telemetry.Count > 400) telemetry.TryDequeue(out _);
        Changed?.Invoke();
    }

    PowerGate Gate(string slot) => gates.GetOrAdd(slot, _ =>
    {
        var p = Plug(slot);
        return new PowerGate
        {
            MaxOnSeconds = p.MaxOnSeconds,
            MinOnSeconds = p.IsLightPower ? 30 : 8,
            MinOffSeconds = p.IsLightPower ? 60 : 12,
            MaxSwitchesPerHour = p.IsLightPower ? 10 : 30,
        };
    });

    /// Simulation (tests / no hardware): every device is a mock and shows SIMULATED.
    public void UseMocks(MockPlug? plug = null, MockLight? strip = null)
    {
        SimulationMode = true;
        foreach (var p in cfg.Plugs) { plugs[p.Slot] = p.Slot == "TAPO_01" && plug != null ? plug : new MockPlug(); Devices[p.Slot].State = DeviceState.Simulated; Devices[p.Slot].Detail = "mock — not physical"; }
        light = strip ?? new MockLight();
        Devices["GOVEE"].State = DeviceState.Simulated; Devices["GOVEE"].Detail = "mock — not physical";
    }

    public static Task<List<TapoDiscovered>> DiscoverTapoAsync(CancellationToken ct) => TapoDiscovery.DiscoverAsync(TimeSpan.FromSeconds(4), ct);

    /// Assigns a discovered or manually entered IP to a slot and connects.
    public async Task<bool> ConnectPlugAsync(string slot, string ip, CancellationToken ct)
    {
        var p = Plug(slot);
        p.Ip = ip.Trim();
        save();
        if (plugs.TryRemove(slot, out var old)) old.Dispose();
        return await ReconnectAsync(slot, ct);
    }

    public async Task<bool> ReconnectAsync(string slot, CancellationToken ct)
    {
        var p = Plug(slot);
        var st = Devices[slot];
        if (SimulationMode) return true;
        if (p.Ip.Length == 0) { st.State = DeviceState.Disconnected; st.Detail = "no IP address yet — run discovery"; Changed?.Invoke(); return false; }
        if (cfg.TapoUser.Length == 0) { st.State = DeviceState.Disconnected; st.Detail = "enter your Tapo account e-mail and password"; Changed?.Invoke(); return false; }
        if (!plugs.ContainsKey(slot)) plugs[slot] = new TapoTransport(new TapoClient(p.Ip, cfg.TapoUser, cfg.TapoPassword, p.HttpPort));
        return await RefreshAsync(slot, ct);
    }

    /// GetStatus + latency (one authenticated round trip).
    public async Task<bool> RefreshAsync(string slot, CancellationToken ct)
    {
        var st = Devices[slot];
        if (!plugs.TryGetValue(slot, out var t)) { st.State = DeviceState.Disconnected; Changed?.Invoke(); return false; }
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(CommandTimeout);
        var sw = Stopwatch.StartNew();
        try
        {
            var info = await t.GetInfoAsync(timeout.Token);
            st.LatencyMs = sw.Elapsed.TotalMilliseconds;
            st.ReportedOn = info.On;
            st.LastSeen = Clock();
            st.LastError = "";
            var p = Plug(slot);
            if (info.Model.Length > 0) p.Model = info.Model;
            if (info.Nickname.Length > 0) { p.Nickname = info.Nickname; st.Name = info.Nickname; }
            if (info.Mac.Length > 0) p.Mac = info.Mac;
            st.State = t.IsMock ? DeviceState.Simulated : (p.PlugTestPassed && (!p.IsWind || p.FanRestartVerified == true) ? DeviceState.ConnectedTested : DeviceState.ConnectedUnverified);
            st.Detail = $"{p.Model} · {p.Ip} · {(info.On ? "ON" : "OFF")}";
            Gate(slot).Commit(info.On, Clock());
            return true;
        }
        catch (Exception ex)
        {
            st.State = t.IsMock ? DeviceState.Simulated : DeviceState.Disconnected;
            st.LastError = ex is OperationCanceledException ? "timed out" : ex.Message;
            st.Detail = "unreachable: " + st.LastError;
            return false;
        }
        finally { Changed?.Invoke(); }
    }

    /// Manual command (testing lab / dashboard). Still respects e-stop and essential flags.
    public Task<bool> SetPlugAsync(string slot, bool on, string reason, CancellationToken ct, bool manual = true, double mediaTime = double.NaN, double confidence = 0, string scene = "")
        => SendPlugAsync(slot, on, reason, ct, manual, safetyOff: !on && manual, mediaTime, confidence, scene);

    async Task<bool> SendPlugAsync(string slot, bool on, string reason, CancellationToken ct, bool manual, bool safetyOff, double mediaTime, double confidence, string scene)
    {
        var p = Plug(slot);
        var st = Devices[slot];
        if (p.Essential) { Log(slot, on ? "ON" : "OFF", "refused: marked essential equipment", -1); return false; }
        if (!p.Authorized && !SimulationMode) { Log(slot, on ? "ON" : "OFF", "refused: plug not authorized", -1); return false; }
        if (on && EmergencyStopped) { Log(slot, "ON", "refused: emergency stop active", -1); return false; }
        if (!manual)
        {
            if (!inflight.TryAdd(slot, true)) return false;   // one automatic command at a time
            var (v, why) = Gate(slot).Evaluate(on, Clock(), safetyOff);
            if (v != PowerGate.Verdict.Switch) inflight.TryRemove(slot, out _);
            if (v != PowerGate.Verdict.Switch) { if (v != PowerGate.Verdict.Duplicate) Log(slot, on ? "ON" : "OFF", "held: " + why, -1, mediaTime, confidence, scene, reason); return false; }
        }
        if (!plugs.TryGetValue(slot, out var t)) { inflight.TryRemove(slot, out _); st.LastError = "not connected"; Log(slot, on ? "ON" : "OFF", "failed: not connected", -1, mediaTime, confidence, scene, reason); return false; }
        var lk = locks.GetOrAdd(slot, _ => new SemaphoreSlim(1, 1));
        await lk.WaitAsync(ct);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(CommandTimeout);
        var sw = Stopwatch.StartNew();
        st.LastCommand = $"{(on ? "ON" : "OFF")} · {reason}";
        try
        {
            await t.SetOnAsync(on, timeout.Token);
            // Acknowledgement = the plug's own reported state afterwards.
            var info = await t.GetInfoAsync(timeout.Token);
            var ms = sw.Elapsed.TotalMilliseconds;
            st.LatencyMs = ms; st.ReportedOn = info.On; st.LastSeen = Clock(); st.LastError = "";
            var ok = info.On == on;
            st.LastAck = ok ? $"plug reports {(info.On ? "ON" : "OFF")}" : $"plug reports {(info.On ? "ON" : "OFF")} (mismatch)";
            if (ok)
            {
                Gate(slot).Commit(on, Clock());
                if (p.IsLightPower)
                {
                    // After a mains interruption the strip must reboot and BLE
                    // needs time to reconnect. Always resend its current colour.
                    lastLight = null;
                    lightPowerReadyAt = on ? Clock().AddSeconds(3) : DateTime.MaxValue;
                }
            }
            Log(slot, on ? "ON" : "OFF", (t.IsMock ? "[SIMULATED] " : "") + st.LastAck, ms, mediaTime, confidence, scene, reason);
            return ok;
        }
        catch (Exception ex)
        {
            st.LastError = ex is OperationCanceledException ? "timed out" : ex.Message;
            if (!t.IsMock) st.State = DeviceState.Disconnected;
            Log(slot, on ? "ON" : "OFF", "failed: " + st.LastError, sw.Elapsed.TotalMilliseconds, mediaTime, confidence, scene, reason);
            _ = Task.Run(() => ReconnectAsync(slot, CancellationToken.None));
            return false;
        }
        finally { lk.Release(); inflight.TryRemove(slot, out _); Changed?.Invoke(); }
    }

    // MARK: Lighting

    public void AttachLight(ILightTransport transport)
    {
        light = transport;
        var st = Devices["GOVEE"];
        st.State = transport.IsMock ? DeviceState.Simulated : cfg.Light.ColorVerified ? DeviceState.ConnectedTested : DeviceState.ConnectedUnverified;
        Changed?.Invoke();
    }

    /// Re-evaluates the strip's state after the colour test.
    public void AttachLightStateRefresh()
    {
        if (light == null) return;
        Devices["GOVEE"].State = light.IsMock ? DeviceState.Simulated : cfg.Light.ColorVerified ? DeviceState.ConnectedTested : DeviceState.ConnectedUnverified;
        Devices["GOVEE"].Name = cfg.Light.Model.Length > 0 ? "Govee " + cfg.Light.Model : "Govee RGBIC strip";
        Devices["GOVEE"].Detail = GoveeProtocol.Describe(cfg.Light.Variant);
        Changed?.Invoke();
    }

    public async Task<GoveeBle?> ConnectLightAsync(ulong address, CancellationToken ct)
    {
        var ble = new GoveeBle(address);
        var ok = await ble.ConnectAsync(ct);
        Devices["GOVEE"].Detail = ble.Status;
        if (!ok) { Devices["GOVEE"].State = DeviceState.Disconnected; Changed?.Invoke(); await ble.DisposeAsync(); return null; }
        AttachLight(new GoveeTransport(ble));
        return ble;
    }

    /// Raw test write (colour wizard). Returns latency or -1.
    public async Task<double> WriteLightAsync(byte[] packet, string what, CancellationToken ct)
    {
        var st = Devices["GOVEE"];
        if (light == null) { Log("GOVEE", what, "failed: not connected", -1); return -1; }
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(ct);
        timeout.CancelAfter(CommandTimeout);
        var ms = await light.WriteAsync(packet, timeout.Token);
        st.LatencyMs = ms; st.LastCommand = what;
        st.LastAck = ms >= 0 ? "BLE write accepted (visual result needs your confirmation)" : "BLE write failed";
        Log("GOVEE", what, (light.IsMock ? "[SIMULATED] " : "") + st.LastAck, ms);
        return ms;
    }

    /// Automatic lighting: rate-limited (≤4 writes/s), deduplicated, only
    /// after the colour test succeeded on this strip.
    public void RequestLight(LightTarget t, double mediaTime, string scene)
    {
        if (EmergencyStopped || !cfg.PhysicalEnabled || cfg.VirtualOnly) return;
        if (cfg.Light.PowerOnly) return; // Tapo source ON/OFF only, no colour claims.
        // Power is sourced through TAPO_02. Never claim colour automation is
        // active while that plug is off, unverified, or not assigned.
        var source = cfg.Plugs.FirstOrDefault(p => p.IsLightPower);
        if (source == null || !Gate(source.Slot).IsOn || Clock() < lightPowerReadyAt) return;
        if (!SimulationMode && !source.LightPowerAutomationAllowed) return;
        if (!SimulationMode && (!cfg.Light.Authorized || !cfg.Light.ColorVerified)) return;
        // Power cycling a light often drops Bluetooth pairing. If the exact
        // strip was previously paired and verified, retry safely in the
        // background after the source has finished rebooting.
        if (light == null)
        {
            if (!SimulationMode && cfg.Light.Address != 0 &&
                Clock() >= nextLightReconnect &&
                Interlocked.CompareExchange(ref lightReconnectBusy, 1, 0) == 0)
            {
                nextLightReconnect = Clock().AddSeconds(15);
                _ = Task.Run(async () =>
                {
                    try
                    {
                        var attached = await ConnectLightAsync(cfg.Light.Address, CancellationToken.None);
                        if (attached != null) lastLight = null;
                    }
                    catch { /* status is surfaced in diagnostics; retry later */ }
                    finally { Interlocked.Exchange(ref lightReconnectBusy, 0); }
                });
            }
            return;
        }
        var now = Clock();
        if (lightWriteBusy || (now - lastLightWrite).TotalMilliseconds < 250) return;
        var bright = Math.Round(t.Brightness, 2);
        if (lastLight is { } l && Math.Abs(l.r - t.R) < 6 && Math.Abs(l.g - t.G) < 6 && Math.Abs(l.b - t.B) < 6 && Math.Abs(l.bright - bright) < 0.03) return;
        lastLight = (t.R, t.G, t.B, bright);
        lastLightWrite = now;
        lightWriteBusy = true;
        var v = SimulationMode && cfg.Light.Variant == GoveeProtocol.ColorVariant.Unknown ? GoveeProtocol.ColorVariant.Manual02 : cfg.Light.Variant;
        _ = Task.Run(async () =>
        {
            try
            {
                // A BLE write can fail while the strip reboots after a Tapo
                // power-on. Retry the same target next tick, not a false success.
                if (EmergencyStopped || !Gate(source.Slot).IsOn) return;
                var colourAck = await WriteLightAsync(GoveeProtocol.Color(t.R, t.G, t.B, v), $"colour {t.Palette} #{t.R:X2}{t.G:X2}{t.B:X2} @ {mediaTime:0.0}s", CancellationToken.None);
                if (colourAck < 0) { lastLight = null; return; }
                if (EmergencyStopped || !Gate(source.Slot).IsOn) return;
                var brightnessAck = await WriteLightAsync(GoveeProtocol.Brightness(bright, v), $"brightness {bright:P0}", CancellationToken.None);
                if (brightnessAck < 0) lastLight = null;
            }
            finally { lightWriteBusy = false; }
        });
    }

    // MARK: Automation from the scene director

    /// Called ~10×/s from the UI thread with the director's current wishes.
    public void Apply(SceneDirector d, double mediaTime)
    {
        var now = Clock();
        foreach (var p in cfg.Plugs)
        {
            if (Gate(p.Slot).CutoffDue(now)) _ = SendPlugAsync(p.Slot, false, "safety cutoff (max on-time)", CancellationToken.None, false, true, mediaTime, 0, d.Scene);
        }
        var wind = cfg.Plugs.First(p => p.Slot == "TAPO_01");
        var allowed = !EmergencyStopped && cfg.PhysicalEnabled && !cfg.VirtualOnly && (SimulationMode || wind.WindAutomationAllowed);
        var gate = Gate(wind.Slot);
        if (d.WantWind && allowed && !gate.IsOn)
            _ = SendPlugAsync(wind.Slot, true, d.WindEvidence, CancellationToken.None, false, false, mediaTime, d.WindConfidence, d.Scene);
        else if (!d.WantWind && gate.IsOn && (allowed || SimulationMode || wind.Authorized))
            _ = SendPlugAsync(wind.Slot, false, "wind scene ended", CancellationToken.None, false, false, mediaTime, 0, d.Scene);
        // TAPO_02 is the master power source for the Govee strip; BLE only
        // supplies colour and brightness *after* confirmed source power.
        var stripSource = cfg.Plugs.FirstOrDefault(p => p.IsLightPower);
        if (stripSource != null)
        {
            var sourceGate = Gate(stripSource.Slot);
            bool playing = d.State.StartsWith("Analysing ", StringComparison.Ordinal) ||
                           d.State.StartsWith("Replaying ", StringComparison.Ordinal) ||
                           d.State == "ZMF ride timeline";
            bool allowedLight = !EmergencyStopped && cfg.PhysicalEnabled && !cfg.VirtualOnly &&
                                (SimulationMode || (stripSource.LightPowerAutomationAllowed &&
                                    (cfg.Light.PowerOnly || (cfg.Light.Authorized && cfg.Light.ColorVerified))));
            if (playing && allowedLight && !sourceGate.IsOn && plugs.ContainsKey(stripSource.Slot))
                _ = SendPlugAsync(stripSource.Slot, true, "analysed film: Govee power", CancellationToken.None,
                    false, false, mediaTime, d.SceneConfidence, d.Scene);
            else if ((!playing || !allowedLight) && sourceGate.IsOn && (stripSource.Authorized || SimulationMode))
                _ = SendPlugAsync(stripSource.Slot, false, "film paused / stopped: Govee power off",
                    CancellationToken.None, false, true, mediaTime, 0, d.Scene);
        }
        RequestLight(d.Light, mediaTime, d.Scene);
    }

    /// Pause/stop: turn the automated fan off right away (bypasses min on-time).
    public Task SuspendAsync(string reason)
    {
        // Pause/stop/connection loss must remove both fan and lighting power.
        var active = cfg.Plugs.Where(p => (p.IsWind || p.IsLightPower) &&
            Gate(p.Slot).IsOn && (p.Authorized || SimulationMode))
            .Select(p => SendPlugAsync(p.Slot, false, reason, CancellationToken.None,
                false, true, double.NaN, 0, ""));
        return Task.WhenAll(active);
    }

    /// Emergency stop: automation off, scheduled commands dropped, every
    /// authorized non-essential plug switched off, lights to dim warm white.
    public async Task StopAllEffectsAsync(string source)
    {
        EmergencyStopped = true;
        foreach (var g in gates.Values) g.EmergencyStop();
        Log("ALL", "EMERGENCY STOP", "requested from " + source, 0);
        // Warm the light before removing its Tapo power source. If BLE is
        // unavailable the emergency OFF still proceeds.
        if (light != null)
        {
            try { await WriteLightAsync(GoveeProtocol.Color(255, 160, 80, cfg.Light.Variant),
                "emergency: warm white before power cutoff", CancellationToken.None); }
            catch { /* Physical plug OFF must never depend on BLE. */ }
        }
        var tasks = cfg.Plugs.Where(p => (p.Authorized || SimulationMode) && !p.Essential && plugs.ContainsKey(p.Slot))
            .Select(p => SendPlugAsync(p.Slot, false, "emergency stop", CancellationToken.None, true, true, double.NaN, 0, ""));
        await Task.WhenAll(tasks);
    }

    public void Rearm()
    {
        EmergencyStopped = false;
        foreach (var g in gates.Values) g.Rearm();
        Log("ALL", "RE-ARM", "automation allowed again", 0);
    }

    public async ValueTask DisposeAsync()
    {
        foreach (var p in plugs.Values) p.Dispose();
        if (light != null) await light.DisposeAsync();
    }
}

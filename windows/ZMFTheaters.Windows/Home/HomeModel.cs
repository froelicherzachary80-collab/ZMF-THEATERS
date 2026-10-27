using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Serialization;

namespace ZMFTheaters.Home;

/// What the app actually knows about a physical output. A device is never
/// shown as working just because the app generated an event.
public enum DeviceState
{
    /// Reachable, and the user confirmed the physical effect in a hardware test.
    ConnectedTested,
    /// Reachable and accepting commands, but the physical result is unconfirmed.
    ConnectedUnverified,
    Disconnected,
    /// Mock device (tests/CI). Never counted as physical.
    Simulated,
    Unsupported,
}

public static class DeviceStateText
{
    public static string Label(DeviceState s) => s switch
    {
        DeviceState.ConnectedTested => "CONNECTED — TESTED",
        DeviceState.ConnectedUnverified => "CONNECTED — UNVERIFIED OUTPUT",
        DeviceState.Disconnected => "DISCONNECTED",
        DeviceState.Simulated => "SIMULATED",
        _ => "UNSUPPORTED",
    };
}

/// One Tapo plug slot. TAPO_01 drives the main wind fan; TAPO_02/03 stay
/// unassigned (never automated) until suitable hardware is attached.
public sealed class HomePlug
{
    public string Slot { get; set; } = "TAPO_01";
    public string Role { get; set; } = "MAIN_WIND";
    public string Ip { get; set; } = "";
    public string Mac { get; set; } = "";
    public string Model { get; set; } = "";
    public string Nickname { get; set; } = "";
    public string DeviceId { get; set; } = "";
    /// The user explicitly allowed automation of this plug.
    public bool Authorized { get; set; }
    /// The user declared that this plug powers essential equipment (PC,
    /// router, medical, heating…). Such a plug is never switched by the app.
    public bool Essential { get; set; }
    public string AttachedDevice { get; set; } = "";
    /// Plug control test: on/off commands were confirmed by the plug's reported state.
    public bool PlugTestPassed { get; set; }
    /// Fan restart test result: null = not tested, true = fan resumed after
    /// power was restored, false = it did not (automation stays disabled).
    public bool? FanRestartVerified { get; set; }
    public DateTime? FanTestedAt { get; set; }
    /// Safety cutoff for continuous on-time.
    public int MaxOnSeconds { get; set; } = 900;

    [JsonIgnore] public bool IsWind => Role == "MAIN_WIND";
    /// Automatic wind runs only after a successful restart test on an authorized, non-essential plug.
    [JsonIgnore] public bool WindAutomationAllowed => IsWind && Authorized && !Essential && PlugTestPassed && FanRestartVerified == true;
}

public sealed class HomeLight
{
    public ulong Address { get; set; }
    public string AdvertisedName { get; set; } = "";
    public string Model { get; set; } = "";
    /// The user typed/confirmed the H-number from the controller label or Govee Home app.
    public bool ModelConfirmed { get; set; }
    public GoveeProtocol.ColorVariant Variant { get; set; }
    /// The user saw the strip change blue → green → red in the colour test.
    public bool ColorVerified { get; set; }
    public bool Authorized { get; set; }
}

public enum EffectLevel { Gentle, Standard, Intense, Extreme }
public enum FlashPolicy { Normal, Reduced, NoFlashing }

/// Home 4DX settings (persisted in config.json; secrets are DPAPI-protected).
public sealed class HomeConfig
{
    public string TapoUserProtected { get; set; } = "";
    public string TapoPasswordProtected { get; set; } = "";
    public List<HomePlug> Plugs { get; set; } = new()
    {
        new HomePlug { Slot = "TAPO_01", Role = "MAIN_WIND" },
        new HomePlug { Slot = "TAPO_02", Role = "AUXILIARY_EFFECT" },
        new HomePlug { Slot = "TAPO_03", Role = "FUTURE_EFFECT" },
    };
    public HomeLight Light { get; set; } = new();
    public EffectLevel Level { get; set; } = EffectLevel.Standard;
    public FlashPolicy Flashes { get; set; } = FlashPolicy.Reduced;
    /// Master switch for physical outputs. Off until the user arms it.
    public bool PhysicalEnabled { get; set; }
    /// Virtual cinema effects only (no physical commands at all).
    public bool VirtualOnly { get; set; }
    public bool HostEnabled { get; set; } = true;
    public int HostPort { get; set; } = 8977;
    public string AccessCodeProtected { get; set; } = "";
    /// Commands are sent this early so the fan/light lands on time.
    public int OutputLatencyMs { get; set; } = 250;

    [JsonIgnore] public string TapoUser { get => Secret.Unprotect(TapoUserProtected); set => TapoUserProtected = Secret.Protect(value); }
    [JsonIgnore] public string TapoPassword { get => Secret.Unprotect(TapoPasswordProtected); set => TapoPasswordProtected = Secret.Protect(value); }

    /// Host access code for the companion and room hosts (created on first use).
    public string AccessCode()
    {
        var code = Secret.Unprotect(AccessCodeProtected);
        if (code.Length < 8)
        {
            const string alphabet = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
            code = new string(Enumerable.Range(0, 10).Select(_ => alphabet[RandomNumberGenerator.GetInt32(alphabet.Length)]).ToArray());
            AccessCodeProtected = Secret.Protect(code);
        }
        return code;
    }

    public void Migrate()
    {
        foreach (var slot in new[] { ("TAPO_01", "MAIN_WIND"), ("TAPO_02", "AUXILIARY_EFFECT"), ("TAPO_03", "FUTURE_EFFECT") })
            if (!Plugs.Any(p => p.Slot == slot.Item1)) Plugs.Add(new HomePlug { Slot = slot.Item1, Role = slot.Item2 });
        Plugs = Plugs.OrderBy(p => p.Slot).ToList();
        Light ??= new HomeLight();
    }
}

/// Windows DPAPI (current user). Falls back to an in-memory value on non-Windows (tests).
public static class Secret
{
    public static string Protect(string value)
    {
        if (string.IsNullOrEmpty(value)) return "";
        try { return Convert.ToBase64String(ProtectedData.Protect(Encoding.UTF8.GetBytes(value), null, DataProtectionScope.CurrentUser)); }
        catch (PlatformNotSupportedException) { return "plain:" + Convert.ToBase64String(Encoding.UTF8.GetBytes(value)); }
    }

    public static string Unprotect(string stored)
    {
        if (string.IsNullOrEmpty(stored)) return "";
        try
        {
            if (stored.StartsWith("plain:")) return Encoding.UTF8.GetString(Convert.FromBase64String(stored[6..]));
            return Encoding.UTF8.GetString(ProtectedData.Unprotect(Convert.FromBase64String(stored), null, DataProtectionScope.CurrentUser));
        }
        catch { return ""; }
    }
}

/// Switching protection for a mains smart plug: minimum on/off times, an
/// hourly switch budget, deduplication, a continuous-on cutoff and a hard
/// emergency stop. Deterministic: time is passed in.
public sealed class PowerGate
{
    public double MinOnSeconds { get; init; } = 8;
    public double MinOffSeconds { get; init; } = 12;
    public int MaxSwitchesPerHour { get; init; } = 30;
    public double MaxOnSeconds { get; init; } = 900;
    public bool IsOn { get; private set; }
    public DateTime LastChange { get; private set; } = DateTime.MinValue;
    readonly Queue<DateTime> switches = new();
    public bool EmergencyStopped { get; private set; }

    public enum Verdict { Switch, Hold, Duplicate, Blocked }

    public (Verdict verdict, string reason) Evaluate(bool want, DateTime now, bool safetyOff = false)
    {
        while (switches.Count > 0 && (now - switches.Peek()).TotalHours >= 1) switches.Dequeue();
        if (want && EmergencyStopped) return (Verdict.Blocked, "emergency stop active");
        if (want == IsOn) return (Verdict.Duplicate, "already " + (IsOn ? "on" : "off"));
        var since = (now - LastChange).TotalSeconds;
        if (!want)
        {
            // Turning off is always allowed for safety (pause, stop, cutoff, e-stop).
            if (safetyOff) return (Verdict.Switch, "safety off");
            if (since < MinOnSeconds) return (Verdict.Hold, $"minimum on-time ({MinOnSeconds:0}s)");
            return (Verdict.Switch, "scene ended");
        }
        if (since < MinOffSeconds) return (Verdict.Hold, $"cooldown ({MinOffSeconds - since:0}s left)");
        if (switches.Count >= MaxSwitchesPerHour) return (Verdict.Blocked, "hourly switch budget used");
        return (Verdict.Switch, "scene wants it");
    }

    /// Record that a command actually succeeded.
    public void Commit(bool on, DateTime now)
    {
        if (on != IsOn) { switches.Enqueue(now); LastChange = now; }
        IsOn = on;
    }

    public bool CutoffDue(DateTime now) => IsOn && (now - LastChange).TotalSeconds > MaxOnSeconds;
    public void EmergencyStop() => EmergencyStopped = true;
    public void Rearm() => EmergencyStopped = false;
}

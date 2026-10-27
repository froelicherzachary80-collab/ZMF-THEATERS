using System.Diagnostics;
using Windows.Devices.Bluetooth;
using Windows.Devices.Bluetooth.Advertisement;
using Windows.Devices.Bluetooth.GenericAttributeProfile;
using Windows.Storage.Streams;

namespace ZMFTheaters.Home;

public sealed record GoveeSeen(ulong Address, string Name, string? Model, short Rssi);

/// Windows Bluetooth LE (WinRT GATT) transport for Govee strips. Writes are
/// "acknowledged" only in the BLE sense (the radio accepted the write);
/// whether the light actually changed must be confirmed by the user.
public sealed class GoveeBle : IAsyncDisposable
{
    BluetoothLEDevice? device;
    GattCharacteristic? control;
    CancellationTokenSource? keepAlive;
    readonly SemaphoreSlim gate = new(1, 1);
    public ulong Address { get; }
    public bool Connected => control != null && device?.ConnectionStatus == BluetoothConnectionStatus.Connected;
    public string Status { get; private set; } = "Not connected";
    public event Action? Changed;

    public GoveeBle(ulong address) { Address = address; }

    public static async Task<List<GoveeSeen>> ScanAsync(TimeSpan duration, CancellationToken ct)
    {
        var seen = new Dictionary<ulong, GoveeSeen>();
        var watcher = new BluetoothLEAdvertisementWatcher { ScanningMode = BluetoothLEScanningMode.Active };
        watcher.Received += (_, e) =>
        {
            var name = e.Advertisement.LocalName;
            if (!GoveeProtocol.LooksLikeGovee(name)) return;
            lock (seen) seen[e.BluetoothAddress] = new GoveeSeen(e.BluetoothAddress, name, GoveeProtocol.ModelFromName(name), e.RawSignalStrengthInDBm);
        };
        watcher.Start();
        try { await Task.Delay(duration, ct); } catch (TaskCanceledException) { }
        watcher.Stop();
        lock (seen) return seen.Values.OrderByDescending(s => s.Rssi).ToList();
    }

    public async Task<bool> ConnectAsync(CancellationToken ct)
    {
        await gate.WaitAsync(ct);
        try
        {
            if (Connected) return true;
            device?.Dispose();
            device = await BluetoothLEDevice.FromBluetoothAddressAsync(Address);
            if (device == null) { Status = "Strip not found (is it powered and in range?)"; return false; }
            device.ConnectionStatusChanged += (_, _) =>
            {
                if (device?.ConnectionStatus == BluetoothConnectionStatus.Disconnected) { control = null; Status = "Bluetooth link lost — will reconnect"; Changed?.Invoke(); }
            };
            var services = await device.GetGattServicesForUuidAsync(GoveeProtocol.Service, BluetoothCacheMode.Uncached);
            if (services.Status != GattCommunicationStatus.Success || services.Services.Count == 0)
            { Status = "Govee control service not found — this model may use an unsupported (encrypted) protocol"; return false; }
            var chars = await services.Services[0].GetCharacteristicsForUuidAsync(GoveeProtocol.Control, BluetoothCacheMode.Uncached);
            if (chars.Status != GattCommunicationStatus.Success || chars.Characteristics.Count == 0)
            { Status = "Govee control characteristic not found"; return false; }
            control = chars.Characteristics[0];
            Status = "Connected (output unverified until you confirm the colour test)";
            keepAlive?.Cancel();
            keepAlive = new CancellationTokenSource();
            _ = KeepAliveLoop(keepAlive.Token);
            Changed?.Invoke();
            return true;
        }
        catch (Exception ex) { Status = "Bluetooth error: " + ex.Message; control = null; return false; }
        finally { gate.Release(); }
    }

    async Task KeepAliveLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try { await Task.Delay(2000, ct); } catch { return; }
            if (Connected) await WriteAsync(GoveeProtocol.KeepAlive(), ct);
            else await ConnectAsync(ct);   // reconnect after a temporary loss
        }
    }

    /// Returns round-trip milliseconds when the radio accepted the write, or -1.
    public async Task<double> WriteAsync(byte[] packet, CancellationToken ct)
    {
        if (!Connected && !await ConnectAsync(ct)) return -1;
        var sw = Stopwatch.StartNew();
        try
        {
            var w = new DataWriter();
            w.WriteBytes(packet);
            var r = await control!.WriteValueWithResultAsync(w.DetachBuffer(), GattWriteOption.WriteWithResponse);
            if (r.Status != GattCommunicationStatus.Success) { Status = $"Write failed: {r.Status}"; return -1; }
            return sw.Elapsed.TotalMilliseconds;
        }
        catch (Exception ex) { Status = "Write error: " + ex.Message; control = null; return -1; }
    }

    public async ValueTask DisposeAsync()
    {
        keepAlive?.Cancel();
        await gate.WaitAsync();
        try { control = null; device?.Dispose(); device = null; }
        finally { gate.Release(); }
    }
}

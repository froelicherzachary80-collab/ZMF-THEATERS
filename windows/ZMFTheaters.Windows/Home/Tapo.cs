using System.IO;
using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace ZMFTheaters.Home;

/// TP-Link "KLAP" local protocol used by Tapo smart plugs such as the P125M
/// (the same protocol python-kasa implements). Everything here is local
/// network traffic between this PC and the plug; no cloud call is made.
/// Credentials are the Tapo app account e-mail and password (case-sensitive).
public static class Klap
{
    public static byte[] AuthHashV2(string user, string password) =>
        SHA256.HashData(Concat(SHA1.HashData(Encoding.UTF8.GetBytes(user)), SHA1.HashData(Encoding.UTF8.GetBytes(password))));

    public static byte[] AuthHashV1(string user, string password) =>
        MD5.HashData(Concat(MD5.HashData(Encoding.UTF8.GetBytes(user)), MD5.HashData(Encoding.UTF8.GetBytes(password))));

    public static byte[] Handshake1V2(byte[] local, byte[] remote, byte[] auth) => SHA256.HashData(Concat(local, remote, auth));
    public static byte[] Handshake2V2(byte[] local, byte[] remote, byte[] auth) => SHA256.HashData(Concat(remote, local, auth));
    public static byte[] Handshake1V1(byte[] local, byte[] remote, byte[] auth) => SHA256.HashData(Concat(local, auth));
    public static byte[] Handshake2V1(byte[] local, byte[] remote, byte[] auth) => SHA256.HashData(Concat(remote, auth));

    public static byte[] Concat(params byte[][] parts)
    {
        var o = new byte[parts.Sum(p => p.Length)];
        int i = 0;
        foreach (var p in parts) { Buffer.BlockCopy(p, 0, o, i, p.Length); i += p.Length; }
        return o;
    }
}

/// AES-128-CBC session with a signed, incrementing sequence number.
public sealed class KlapSession
{
    readonly byte[] key, ivPrefix, sig;
    public int Seq { get; private set; }

    public KlapSession(byte[] local, byte[] remote, byte[] auth)
    {
        key = SHA256.HashData(Klap.Concat("lsk"u8.ToArray(), local, remote, auth))[..16];
        var iv = SHA256.HashData(Klap.Concat("iv"u8.ToArray(), local, remote, auth));
        ivPrefix = iv[..12];
        Seq = BinaryPrimitives.ReadInt32BigEndian(iv.AsSpan(28, 4));
        sig = SHA256.HashData(Klap.Concat("ldk"u8.ToArray(), local, remote, auth))[..28];
    }

    byte[] Iv()
    {
        var iv = new byte[16];
        Buffer.BlockCopy(ivPrefix, 0, iv, 0, 12);
        BinaryPrimitives.WriteInt32BigEndian(iv.AsSpan(12), Seq);
        return iv;
    }

    public (byte[] payload, int seq) Encrypt(string message)
    {
        Seq = unchecked(Seq + 1);
        using var aes = Aes.Create();
        aes.Key = key;
        var cipher = aes.EncryptCbc(Encoding.UTF8.GetBytes(message), Iv(), PaddingMode.PKCS7);
        var seqBytes = new byte[4];
        BinaryPrimitives.WriteInt32BigEndian(seqBytes, Seq);
        var signature = SHA256.HashData(Klap.Concat(sig, seqBytes, cipher));
        return (Klap.Concat(signature, cipher), Seq);
    }

    /// Decrypts a response to the most recent request (same sequence number).
    public string Decrypt(byte[] payload)
    {
        if (payload.Length < 48) throw new InvalidDataException("KLAP response too short");
        using var aes = Aes.Create();
        aes.Key = key;
        return Encoding.UTF8.GetString(aes.DecryptCbc(payload.AsSpan(32), Iv(), PaddingMode.PKCS7));
    }
}

public sealed record TapoInfo(bool On, string Model, string Nickname, string Mac, string DeviceId, string FirmwareVersion, int Rssi);

/// One authenticated plug. Thread-safe: requests are serialised.
public sealed class TapoClient : IDisposable
{
    readonly HttpClient http;
    readonly string baseUrl;
    readonly string user, password;
    readonly SemaphoreSlim gate = new(1, 1);
    readonly string terminal = Convert.ToBase64String(MD5.HashData(Guid.NewGuid().ToByteArray()));
    KlapSession? session;
    string? cookie;
    DateTime sessionExpires;
    public string Host { get; }
    public string? AuthMode { get; private set; }

    public TapoClient(string host, string user, string password, int port = 80, HttpMessageHandler? handler = null)
    {
        Host = host;
        this.user = user; this.password = password;
        baseUrl = $"http://{host}:{port}/app";
        http = handler == null ? new HttpClient() : new HttpClient(handler);
        http.Timeout = TimeSpan.FromSeconds(5);
    }

    async Task HandshakeAsync(CancellationToken ct)
    {
        session = null; cookie = null;
        var local = RandomNumberGenerator.GetBytes(16);
        using var r1 = await http.PostAsync(baseUrl + "/handshake1", new ByteArrayContent(local), ct);
        if (r1.StatusCode != HttpStatusCode.OK) throw new TapoException($"handshake1 returned HTTP {(int)r1.StatusCode}");
        var body = await r1.Content.ReadAsByteArrayAsync(ct);
        if (body.Length < 48) throw new TapoException("handshake1 response too short");
        var remote = body[..16];
        var server = body[16..48];
        if (r1.Headers.TryGetValues("Set-Cookie", out var cookies))
            foreach (var c in cookies)
                foreach (var part in c.Split(';'))
                    if (part.Trim().StartsWith("TP_SESSIONID=")) cookie = part.Trim();

        // Same order python-kasa uses: account (v2, then v1), then Tapo's
        // documented setup defaults, then blank — never logged.
        var candidates = new List<(string mode, byte[] auth, bool v2)>
        {
            ("account", Klap.AuthHashV2(user, password), true),
            ("account (v1)", Klap.AuthHashV1(user, password), false),
            ("setup default", Klap.AuthHashV2(Encoding.UTF8.GetString(Convert.FromBase64String("dGVzdEB0cC1saW5rLm5ldA==")), "test"), true),
            ("blank", Klap.AuthHashV2("", ""), true),
        };
        foreach (var (mode, auth, v2) in candidates)
        {
            var expect = v2 ? Klap.Handshake1V2(local, remote, auth) : Klap.Handshake1V1(local, remote, auth);
            if (!expect.AsSpan().SequenceEqual(server)) continue;
            var h2 = v2 ? Klap.Handshake2V2(local, remote, auth) : Klap.Handshake2V1(local, remote, auth);
            using var req = new HttpRequestMessage(HttpMethod.Post, baseUrl + "/handshake2") { Content = new ByteArrayContent(h2) };
            if (cookie != null) req.Headers.Add("Cookie", cookie);
            using var r2 = await http.SendAsync(req, ct);
            if (r2.StatusCode != HttpStatusCode.OK) throw new TapoException($"handshake2 returned HTTP {(int)r2.StatusCode}");
            session = new KlapSession(local, remote, auth);
            sessionExpires = DateTime.UtcNow.AddHours(23);
            AuthMode = mode;
            return;
        }
        throw new TapoException("The plug rejected these Tapo account credentials (e-mail and password are case-sensitive).");
    }

    public async Task<JsonElement> RequestAsync(string method, object? parameters, CancellationToken ct)
    {
        await gate.WaitAsync(ct);
        try
        {
            for (int attempt = 0; ; attempt++)
            {
                if (session == null || DateTime.UtcNow > sessionExpires) await HandshakeAsync(ct);
                var msg = new Dictionary<string, object?> { ["method"] = method, ["request_time_milis"] = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), ["terminal_uuid"] = terminal };
                if (parameters != null) msg["params"] = parameters;
                var (payload, seq) = session!.Encrypt(JsonSerializer.Serialize(msg));
                using var req = new HttpRequestMessage(HttpMethod.Post, $"{baseUrl}/request?seq={seq}") { Content = new ByteArrayContent(payload) };
                if (cookie != null) req.Headers.Add("Cookie", cookie);
                using var resp = await http.SendAsync(req, ct);
                if (resp.StatusCode == HttpStatusCode.Forbidden && attempt == 0) { session = null; continue; }
                if (resp.StatusCode != HttpStatusCode.OK) throw new TapoException($"request returned HTTP {(int)resp.StatusCode}");
                var json = JsonDocument.Parse(session.Decrypt(await resp.Content.ReadAsByteArrayAsync(ct))).RootElement.Clone();
                var code = json.TryGetProperty("error_code", out var e) ? e.GetInt32() : 0;
                if (code != 0)
                {
                    if (attempt == 0 && code is -1012 or 9999 or -1501) { session = null; continue; }   // session/auth errors → re-handshake once
                    throw new TapoException($"plug error {code} for {method}");
                }
                return json.TryGetProperty("result", out var result) ? result : json;
            }
        }
        finally { gate.Release(); }
    }

    public async Task<TapoInfo> GetInfoAsync(CancellationToken ct)
    {
        var r = await RequestAsync("get_device_info", null, ct);
        string S(string k) => r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
        string nick = S("nickname");
        try { nick = Encoding.UTF8.GetString(Convert.FromBase64String(nick)); } catch { }
        return new TapoInfo(r.TryGetProperty("device_on", out var on) && on.ValueKind == JsonValueKind.True,
            S("model"), nick, S("mac"), S("device_id"), S("fw_ver"), r.TryGetProperty("rssi", out var rssi) && rssi.TryGetInt32(out var rv) ? rv : 0);
    }

    public Task SetOnAsync(bool on, CancellationToken ct) => RequestAsync("set_device_info", new Dictionary<string, object> { ["device_on"] = on }, ct);

    public void Dispose() { http.Dispose(); gate.Dispose(); }
}

public sealed class TapoException(string message) : Exception(message);

public sealed record TapoDiscovered(string Ip, string Model, string Mac, string DeviceId, string DeviceType, string EncryptType, int HttpPort, bool FactoryDefault);

/// UDP discovery on port 20002 (the probe python-kasa sends to newer Tapo
/// devices). Devices answer with plaintext JSON after a 16-byte header.
public static class TapoDiscovery
{
    public static byte[] BuildQuery(RSA rsa, uint serial)
    {
        var pem = rsa.ExportSubjectPublicKeyInfoPem() + "\n";
        var json = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new { @params = new { rsa_key = pem } }));
        var q = new byte[16 + json.Length];
        q[0] = 2; q[1] = 0;
        BinaryPrimitives.WriteUInt16BigEndian(q.AsSpan(2), 1);
        BinaryPrimitives.WriteUInt16BigEndian(q.AsSpan(4), (ushort)json.Length);
        q[6] = 17; q[7] = 0;
        BinaryPrimitives.WriteUInt32BigEndian(q.AsSpan(8), serial);
        BinaryPrimitives.WriteUInt32BigEndian(q.AsSpan(12), 0x5A6B7C8D);
        Buffer.BlockCopy(json, 0, q, 16, json.Length);
        BinaryPrimitives.WriteUInt32BigEndian(q.AsSpan(12), Crc32(q));
        return q;
    }

    public static uint Crc32(ReadOnlySpan<byte> data)
    {
        uint crc = 0xFFFFFFFF;
        foreach (var b in data)
        {
            crc ^= b;
            for (int k = 0; k < 8; k++) crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320u : crc >> 1;
        }
        return ~crc;
    }

    public static TapoDiscovered? Parse(byte[] data, string ip)
    {
        if (data.Length <= 16) return null;
        try
        {
            var root = JsonDocument.Parse(data.AsMemory(16)).RootElement;
            var r = root.TryGetProperty("result", out var res) ? res : root;
            string S(JsonElement e, string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
            var enc = r.TryGetProperty("mgt_encrypt_schm", out var m) ? m : default;
            return new TapoDiscovered(S(r, "ip") is { Length: > 0 } rip ? rip : ip, S(r, "device_model"), S(r, "mac"), S(r, "device_id"), S(r, "device_type"),
                enc.ValueKind == JsonValueKind.Object ? S(enc, "encrypt_type") : "",
                enc.ValueKind == JsonValueKind.Object && enc.TryGetProperty("http_port", out var p) && p.TryGetInt32(out var port) ? port : 80,
                r.TryGetProperty("factory_default", out var fd) && fd.ValueKind == JsonValueKind.True);
        }
        catch { return null; }
    }

    public static async Task<List<TapoDiscovered>> DiscoverAsync(TimeSpan timeout, CancellationToken ct)
    {
        var found = new Dictionary<string, TapoDiscovered>();
        using var rsa = RSA.Create(2048);
        var query = BuildQuery(rsa, (uint)RandomNumberGenerator.GetInt32(int.MaxValue));
        using var udp = new UdpClient(0) { EnableBroadcast = true };
        var targets = new List<IPAddress> { IPAddress.Broadcast };
        foreach (var ni in NetworkInterface.GetAllNetworkInterfaces().Where(n => n.OperationalStatus == OperationalStatus.Up))
            foreach (var ua in ni.GetIPProperties().UnicastAddresses.Where(a => a.Address.AddressFamily == AddressFamily.InterNetwork && a.IPv4Mask != null))
            {
                var ip = ua.Address.GetAddressBytes(); var mask = ua.IPv4Mask.GetAddressBytes();
                if (ip[0] == 127) continue;
                targets.Add(new IPAddress(ip.Select((b, i) => (byte)(b | ~mask[i])).ToArray()));
            }
        var sw = Stopwatch.StartNew();
        for (int round = 0; round < 3; round++)
            foreach (var t in targets.Distinct())
                try { await udp.SendAsync(query, query.Length, new IPEndPoint(t, 20002)); } catch { }
        while (sw.Elapsed < timeout && !ct.IsCancellationRequested)
        {
            var wait = udp.ReceiveAsync(ct).AsTask();
            var done = await Task.WhenAny(wait, Task.Delay(timeout - sw.Elapsed, ct));
            if (done != wait) break;
            var res = await wait;
            if (Parse(res.Buffer, res.RemoteEndPoint.Address.ToString()) is { } d) found[d.Ip] = d;
        }
        return found.Values.ToList();
    }
}

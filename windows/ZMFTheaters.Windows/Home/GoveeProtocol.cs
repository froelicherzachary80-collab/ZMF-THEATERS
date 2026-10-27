namespace ZMFTheaters.Home;

/// Govee Bluetooth LE packets as documented by the community reverse-
/// engineering projects (BeauJBurroughs/Govee-H6127-Reverse-Engineering,
/// kollier-p/LightstripSyncClient). Govee publishes no local BLE API, so
/// colour commands come in model-dependent variants; the setup wizard has the
/// user confirm which variant visibly changes *their* strip before any
/// automatic lighting is enabled.
public static class GoveeProtocol
{
    public static readonly Guid Service = Guid.Parse("00010203-0405-0607-0809-0a0b0c0d1910");
    public static readonly Guid Control = Guid.Parse("00010203-0405-0607-0809-0a0b0c0d2b11");

    /// Colour command variants seen across Govee models.
    public enum ColorVariant { Unknown = 0, Manual02 = 1, Manual0D = 2, Segments15 = 3 }

    public static string Describe(ColorVariant v) => v switch
    {
        ColorVariant.Manual02 => "A · 0x05 0x02 (H6127/H6113 family)",
        ColorVariant.Manual0D => "B · 0x05 0x0D (many newer strips)",
        ColorVariant.Segments15 => "C · 0x05 0x15 all segments (RGBIC)",
        _ => "not yet confirmed",
    };

    public static byte[] Packet(params byte[] body)
    {
        var p = new byte[20];
        Buffer.BlockCopy(body, 0, p, 0, Math.Min(19, body.Length));
        byte x = 0;
        for (int i = 0; i < 19; i++) x ^= p[i];
        p[19] = x;
        return p;
    }

    public static byte[] KeepAlive() => Packet(0xAA, 0x01);
    public static byte[] Power(bool on) => Packet(0x33, 0x01, (byte)(on ? 1 : 0));

    /// Brightness 0–1. Classic models take 0x14–0xFE; newer ones take 1–100.
    public static byte[] Brightness(double level, ColorVariant v)
    {
        level = Math.Clamp(double.IsFinite(level) ? level : 0, 0, 1);
        byte b = v == ColorVariant.Manual02 ? (byte)(level <= 0 ? 0 : 0x14 + (int)Math.Round(level * (0xFE - 0x14)))
                                            : (byte)(level <= 0 ? 0 : Math.Max(1, (int)Math.Round(level * 100)));
        return Packet(0x33, 0x04, b);
    }

    public static byte[] Color(byte r, byte g, byte b, ColorVariant v) => v switch
    {
        ColorVariant.Manual0D => Packet(0x33, 0x05, 0x0D, r, g, b),
        ColorVariant.Segments15 => Packet(0x33, 0x05, 0x15, 0x01, r, g, b, 0, 0, 0, 0, 0, 0xFF, 0xFF),
        _ => Packet(0x33, 0x05, 0x02, r, g, b),
    };

    /// "ihoment_H6163_A1B2", "Govee_H6199_1234", "GBK_H6110_…" → "H6163".
    public static string? ModelFromName(string? name)
    {
        if (string.IsNullOrWhiteSpace(name)) return null;
        var m = System.Text.RegularExpressions.Regex.Match(name, @"\b(?:ihoment|Govee|GBK|Minger|GVH)[_ -]?(H[0-9A-Z]{4,5})", System.Text.RegularExpressions.RegexOptions.IgnoreCase);
        return m.Success ? m.Groups[1].Value.ToUpperInvariant() : null;
    }

    public static bool LooksLikeGovee(string? name) =>
        name != null && System.Text.RegularExpressions.Regex.IsMatch(name, @"^(ihoment|Govee|GBK|Minger|GVH)", System.Text.RegularExpressions.RegexOptions.IgnoreCase);

    /// Community-reported status by model. "Reported" is not "verified on your strip".
    public static string CommunityStatus(string? model) => model switch
    {
        "H6127" or "H6113" => "Community-reported working (variant A)",
        "H6141" or "H6181" or "H6143" => "Community-reported working (LightstripSyncClient)",
        null => "Model not yet identified",
        _ => "Not in community reports — run the colour test to find out",
    };
}

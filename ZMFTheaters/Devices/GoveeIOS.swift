import Foundation
import CoreBluetooth
import Combine
import CoreVideo

/// Locally sent 24-bit RGB. No internet account, Windows host or cloud API.
struct CinemaRGB: Equatable {
    var r: UInt8
    var g: UInt8
    var b: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8) {
        self.r = r; self.g = g; self.b = b
    }
    func blended(with next: CinemaRGB, fraction: Double) -> CinemaRGB {
        let t = max(0, min(1, fraction.isFinite ? fraction : 0))
        func mix(_ a: UInt8, _ b: UInt8) -> UInt8 {
            UInt8(max(0, min(255, Int((Double(a) * (1 - t) + Double(b) * t).rounded()))))
        }
        return CinemaRGB(mix(r, next.r), mix(g, next.g), mix(b, next.b))
    }
    var hex: String { String(format: "#%02X%02X%02X", r, g, b) }
}

/// Three community-observed command encodings. Not every Govee strip uses
/// this GATT service or these packet variants: user confirmation is essential.
enum GoveeColorVariant: String, CaseIterable, Identifiable, Codable {
    case manual02, manual0D, segments15
    var id: String { rawValue }
    var label: String {
        switch self {
        case .manual02: "A · Standard RGB"
        case .manual0D: "B · Alternative RGB"
        case .segments15: "C · RGBIC segments"
        }
    }
}

enum GoveeBLEPackets {
    static let control = CBUUID(string: "00010203-0405-0607-0809-0a0b0c0d2b11")
    static func packet(_ bytes: [UInt8]) -> Data {
        var raw = [UInt8](repeating: 0, count: 20)
        for (index, byte) in bytes.prefix(19).enumerated() { raw[index] = byte }
        raw[19] = raw.prefix(19).reduce(UInt8(0)) { $0 ^ $1 }
        return Data(raw)
    }
    static func power(_ on: Bool) -> Data { packet([0x33, 0x01, on ? 1 : 0]) }
    static func brightness(_ level: Double, variant: GoveeColorVariant) -> Data {
        let b = max(0, min(1, level.isFinite ? level : 0))
        let value: Int = variant == .manual02
            ? (b <= 0 ? 0 : Int((20 + b * 234).rounded()))
            : (b <= 0 ? 0 : max(1, Int((100 * b).rounded())))
        return packet([0x33, 0x04, UInt8(value)])
    }
    static func color(_ rgb: CinemaRGB, variant: GoveeColorVariant) -> Data {
        switch variant {
        case .manual02: return packet([0x33, 0x05, 0x02, rgb.r, rgb.g, rgb.b])
        case .manual0D: return packet([0x33, 0x05, 0x0D, rgb.r, rgb.g, rgb.b])
        case .segments15:
            return packet([0x33, 0x05, 0x15, 0x01, rgb.r, rgb.g, rgb.b,
                           0, 0, 0, 0, 0, 0xFF, 0xFF])
        }
    }
    static func looksLikeGovee(_ name: String) -> Bool {
        let n = name.lowercased()
        return ["govee", "ihoment", "gbk", "minger", "gvh"].contains { n.hasPrefix($0) }
    }
}

/// Simple, explainable RGB ambience, not semantic object recognition.
/// Native, decoded AVPlayer frames supply real colors. Bright blue-white
/// scenes produce cool ice-like highlights; warm scenes produce amber, etc.
enum CinemaLightPalette {
    static func fromVideoAverage(_ source: CinemaRGB) -> CinemaRGB {
        let r = Double(source.r) / 255
        let g = Double(source.g) / 255
        let b = Double(source.b) / 255
        let maxV = max(r, max(g, b)), minV = min(r, min(g, b))
        let saturation = maxV - minV
        // Bright, neutral or blue-biased scenes (snow, ice, light studios)
        // are given a gentle cool-white hue; no claim of knowing the location.
        if maxV > 0.58 && saturation < 0.19 && b >= r * 0.93 {
            return CinemaRGB(183, 223, 255)
        }
        if maxV < 0.12 { return CinemaRGB(18, 26, 53) }
        // Preserve arbitrary hue while slightly lifting low-saturation scenes.
        let scale = maxV > 0 ? min(1.5, 0.75 / maxV) : 1.0
        func channel(_ c: Double) -> UInt8 {
            UInt8(max(0, min(255, Int(((0.07 + c * scale * 0.93) * 255).rounded()))))
        }
        return CinemaRGB(channel(r), channel(g), channel(b))
    }

    /// YouTube does not expose protected video pixels to the app. For these
    /// videos, use a clearly labelled *rhythmic fallback*, not fake scene AI.
    /// Sample a small central grid from a decoded, unprotected BGRA movie.
    /// Ignores black letterboxing and avoids per-frame image allocations.
    static func nativeMovieFrame(_ pixelBuffer: CVPixelBuffer) -> CinemaRGB? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else { return nil }
        let w = CVPixelBufferGetWidth(pixelBuffer)
        let h = CVPixelBufferGetHeight(pixelBuffer)
        guard w >= 24, h >= 24 else { return nil }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        var r = 0, g = 0, b = 0, count = 0
        for iy in 0..<12 {
            let y = (h * (3 + iy * 2)) / 30
            for ix in 0..<20 {
                let x = (w * (3 + ix * 2)) / 46
                let at = y * stride + x * 4
                let blue = Int(bytes[at]), green = Int(bytes[at + 1]), red = Int(bytes[at + 2])
                if max(red, max(green, blue)) < 9 { continue }
                r += red; g += green; b += blue; count += 1
            }
        }
        guard count > 8 else { return nil }
        return fromVideoAverage(CinemaRGB(UInt8(r/count), UInt8(g/count), UInt8(b/count)))
    }

    static func youtubeRhythm(seconds: Double, preset: YouTubeMotionPreset) -> CinemaRGB {
        let t = seconds.isFinite ? max(0, seconds) : 0
        let cycle = (sin(t * 0.17) + 1) * 0.5
        let a: CinemaRGB
        let b: CinemaRGB
        switch preset {
        case .concert, .edits:
            a = CinemaRGB(32, 60, 240); b = CinemaRGB(216, 34, 182)
        case .minecraft:
            a = CinemaRGB(30, 190, 95); b = CinemaRGB(38, 130, 244)
        case .cinematic, .off:
            a = CinemaRGB(50, 98, 172); b = CinemaRGB(190, 152, 102)
        }
        return a.blended(with: b, fraction: cycle)
    }
}

struct GoveeFoundDevice: Identifiable, Equatable {
    let id: UUID
    let name: String
    let signal: Int
}

/// This CoreBluetooth central runs ENTIRELY on the iPhone. Pair once in
/// Admin -> iPhone Govee Lighting, verify the strip visually, and after that
/// the room automatically reconnects on launch and matches scene RGB.
/// The user must leave the Govee adapter powered and in Bluetooth range.
@MainActor
final class GoveeIOSController: NSObject, ObservableObject {
    @Published private(set) var bluetoothStatus = "Not started"
    @Published private(set) var devices: [GoveeFoundDevice] = []
    @Published private(set) var connected = false
    @Published private(set) var deviceName = ""
    @Published private(set) var currentColor = CinemaRGB(0, 0, 0)
    @Published private(set) var moodSource = "Not playing"

    private var manager: CBCentralManager?
    private var peripheral: CBPeripheral?
    private var control: CBCharacteristic?
    private var scanRequested = false
    private var selectedID: UUID?
    private var automationEnabled = false
    private var colorVerified = false
    private var variant: GoveeColorVariant = .manual02
    private var brightness = 0.65
    private var lastPacketTime: TimeInterval = 0
    private var lastSent: CinemaRGB?
    private var powerCommandSent = false
    private var lastBrightness: Double?
    private var transitionColor: CinemaRGB?
    private var lastConnectTry: Date = .distantPast

    func configure(deviceID: String, autoEnabled: Bool, verified: Bool,
                   variant: GoveeColorVariant, brightness: Double) {
        let nextID = UUID(uuidString: deviceID)
        if nextID != selectedID {
            selectedID = nextID
            control = nil
            if peripheral?.identifier != nextID { connected = false }
        }
        automationEnabled = autoEnabled
        colorVerified = verified
        self.variant = variant
        self.brightness = max(0.15, min(1, brightness.isFinite ? brightness : 0.65))
        if automationEnabled && selectedID != nil && manager == nil { beginBluetooth() }
    }

    func beginBluetooth() {
        if manager == nil {
            bluetoothStatus = "Requesting iPhone Bluetooth access"
            manager = CBCentralManager(delegate: self, queue: nil)
        } else if manager?.state == .poweredOn { startScanAndRestore() }
    }

    func scan() {
        scanRequested = true
        devices = []
        beginBluetooth()
    }

    func connect(to id: UUID) {
        selectedID = id
        scanRequested = false
        beginBluetooth()
        guard let manager, manager.state == .poweredOn else { return }
        if let d = manager.retrievePeripherals(withIdentifiers: [id]).first {
            connectPeripheral(d)
        } else {
            startScanAndRestore()
        }
    }

    func disconnect() {
        automationEnabled = false
        if let peripheral { manager?.cancelPeripheralConnection(peripheral) }
        self.peripheral = nil
        control = nil
        connected = false
        powerCommandSent = false
        lastBrightness = nil
        bluetoothStatus = "Disconnected"
    }

    func sendTest(_ color: CinemaRGB) {
        guard send(color: color, force: true) else {
            bluetoothStatus = "Bluetooth not connected, or unsupported Govee characteristic"
            return
        }
        moodSource = "Visual color test — please confirm on the real strip"
    }

    func sceneColor(_ rgb: CinemaRGB, source: String) {
        guard automationEnabled, colorVerified else { return }
        moodSource = source
        let target = rgb
        let eased = transitionColor?.blended(with: target, fraction: 0.32) ?? target
        transitionColor = eased
        _ = send(color: eased, force: false)
    }

    func playbackStopped() {
        transitionColor = nil
        lastSent = nil
        moodSource = "Paused / idle — no automatic commands"
    }

    @discardableResult
    private func send(color: CinemaRGB, force: Bool) -> Bool {
        guard connected, let p = peripheral, let ch = control else { return false }
        if !force {
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastPacketTime >= 0.17 else { return false } // max ~6 RGB changes/sec
            if let lastSent, lastSent == color { return false }
        }
        let type: CBCharacteristicWriteType = ch.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        if type == .withoutResponse && !p.canSendWriteWithoutResponse { return false }
        // Do NOT spam power commands every ~170ms. Send once per connection
        // and only update colour and changed brightness thereafter.
        if !powerCommandSent {
            p.writeValue(GoveeBLEPackets.power(true), for: ch, type: type)
            powerCommandSent = true
        }
        p.writeValue(GoveeBLEPackets.color(color, variant: variant), for: ch, type: type)
        if lastBrightness == nil || abs((lastBrightness ?? 0) - brightness) > 0.015 {
            p.writeValue(GoveeBLEPackets.brightness(brightness, variant: variant), for: ch, type: type)
            lastBrightness = brightness
        }
        currentColor = color
        lastSent = color
        lastPacketTime = ProcessInfo.processInfo.systemUptime
        return true
    }

    private func startScanAndRestore() {
        guard let manager, manager.state == .poweredOn else { return }
        if !scanRequested, let id = selectedID, let known = manager.retrievePeripherals(withIdentifiers: [id]).first {
            connectPeripheral(known)
            return
        }
        bluetoothStatus = "Scanning for Govee Bluetooth lights"
        manager.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    private func connectPeripheral(_ p: CBPeripheral) {
        guard let manager, manager.state == .poweredOn else { return }
        if p.state == .connected {
            peripheral = p
            p.delegate = self
            p.discoverServices(nil)
            return
        }
        guard Date().timeIntervalSince(lastConnectTry) > 1 else { return }
        lastConnectTry = Date()
        manager.stopScan()
        peripheral = p
        control = nil
        connected = false
        p.delegate = self
        bluetoothStatus = "Connecting to " + (p.name ?? "Govee strip")
        manager.connect(p, options: nil)
    }
}

extension GoveeIOSController: CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: startScanAndRestore()
        case .poweredOff: connected = false; bluetoothStatus = "Turn on iPhone Bluetooth"
        case .unauthorized: connected = false; bluetoothStatus = "Allow Bluetooth access in iPhone Settings"
        case .unsupported: connected = false; bluetoothStatus = "Bluetooth LE is unsupported"
        default: connected = false; bluetoothStatus = "Bluetooth is unavailable"
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? p.name ?? ""
        if GoveeBLEPackets.looksLikeGovee(name) || p.identifier == selectedID {
            if !devices.contains(where: { $0.id == p.identifier }) {
                devices.append(GoveeFoundDevice(id: p.identifier, name: name.isEmpty ? "Govee device" : name, signal: RSSI.intValue))
            }
            if p.identifier == selectedID { connectPeripheral(p) }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        p.delegate = self
        deviceName = p.name ?? "Govee"
        bluetoothStatus = "Discovering Govee light characteristics"
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        connected = false
        bluetoothStatus = "Could not connect: " + (error?.localizedDescription ?? "unknown error")
        if automationEnabled { startScanAndRestore() }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connected = false
        control = nil
        transitionColor = nil
        lastSent = nil
        powerCommandSent = false
        lastBrightness = nil
        bluetoothStatus = "Disconnected — " + (error?.localizedDescription ?? "light unavailable")
        if automationEnabled, p.identifier == selectedID {
            // Reconnect after the user manually re-powers the light.
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self, self.automationEnabled else { return }
                self.startScanAndRestore()
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let services = p.services else {
            bluetoothStatus = "Cannot discover services on this Govee model"
            return
        }
        for s in services { p.discoverCharacteristics(nil, for: s) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil else { return }
        guard let ch = service.characteristics?.first(where: {
            $0.uuid == GoveeBLEPackets.control &&
            ($0.properties.contains(.writeWithoutResponse) || $0.properties.contains(.write))
        }) else { return }
        control = ch
        powerCommandSent = false
        lastBrightness = nil
        peripheral = p
        deviceName = p.name ?? "Govee light"
        connected = true
        bluetoothStatus = "Connected: " + deviceName
        lastSent = nil
        transitionColor = nil
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { bluetoothStatus = "BLE write failed: " + error.localizedDescription }
    }
}

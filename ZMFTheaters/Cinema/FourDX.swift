import Foundation
import CoreHaptics
import simd

/// The ZMF 4DX teaser: a two-day preview on October 27–28, 2026 (America/New_York).
enum FourDX {
    static var previewStart: Date { date(2026, 10, 27) }
    static var previewEnd: Date { date(2026, 10, 29) }

    private static func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var c = DateComponents()
        c.year = y; c.month = m; c.day = d
        c.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: c) ?? Date.distantFuture
    }

    static func isPreviewActive(now: Date = Date(), settings: AppSettings) -> Bool {
        true
    }

    /// Short line for signage and the title screen.
    static func teaser(now: Date = Date(), settings: AppSettings) -> String {
        if isPreviewActive(now: now, settings: settings) { return "AUTO 4DX · Available at the Box Office" }
        if now < previewStart {
            let days = Int(ceil(previewStart.timeIntervalSince(now) / 86_400))
            return "4DX PREVIEW · OCT 27–28 · \(days == 1 ? "tomorrow" : "in \(days) days")"
        }
        return "4DX PREVIEW ENDED · Full 4DX coming in a future update"
    }
}

/// A compact on-device 4DX cue. The signal is picture motion, NOT a semantic
/// claim about explosions, vehicles, weather, or dialogue. All values bounded.
struct FourDXMotionCue: Codable, Equatable, Sendable {
    var timestamp: Double
    var energy: Float
    var flowX: Float
    var flowY: Float
}

struct FourDXMotionTimeline: Codable, Sendable {
    var version: Int = 1
    var duration: Double
    var cues: [FourDXMotionCue]
}

/// Cache of evidence-based motion cues for repeat screenings.
/// Only small, derived metadata is stored; video frames never leave the device.
actor FourDXCueCache {
    private let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ZMF4DXMotion", isDirectory: true)
    }

    private func url(for mediaID: String) -> URL {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for c in mediaID.utf8 { hash = (hash ^ UInt64(c)) &* 1_099_511_628_211 }
        return directory.appendingPathComponent(String(hash, radix: 16) + ".json")
    }

    func load(mediaID: String, duration: Double) -> [FourDXMotionCue] {
        guard duration.isFinite, duration > 0,
              let data = try? Data(contentsOf: url(for: mediaID)),
              let result = try? JSONDecoder().decode(FourDXMotionTimeline.self, from: data),
              result.version == 1, abs(result.duration - duration) < 1,
              result.cues.count <= 60_000 else { return [] }
        return result.cues.filter { $0.timestamp.isFinite && $0.timestamp >= 0 &&
            $0.timestamp <= duration && $0.energy.isFinite && $0.flowX.isFinite && $0.flowY.isFinite }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func save(mediaID: String, duration: Double, cues: [FourDXMotionCue]) {
        guard duration.isFinite, duration > 0, !cues.isEmpty else { return }
        let unique = cues.filter { $0.timestamp.isFinite && $0.timestamp >= 0 &&
            $0.timestamp <= duration && $0.energy.isFinite && $0.flowX.isFinite && $0.flowY.isFinite }
            .sorted { $0.timestamp < $1.timestamp }
        guard !unique.isEmpty else { return }
        var reduced: [FourDXMotionCue] = []
        for cue in unique {
            if let last = reduced.last, abs(last.timestamp - cue.timestamp) < 0.22 {
                reduced[reduced.count - 1] = cue
            } else { reduced.append(cue) }
        }
        if reduced.count > 60_000 { reduced.removeFirst(reduced.count - 60_000) }
        guard let encoded = try? JSONEncoder().encode(FourDXMotionTimeline(duration: duration, cues: reduced)) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? encoded.write(to: url(for: mediaID), options: .atomic)
    }
}

/// The iPhone pilot uses an 8x8 picture-motion grid and inexpensive block-shift
/// matching. It does not infer semantic events or listen to the movie's audio.
/// A future multimodal classifier can feed richer events to the same seat rig.
enum FourDXMotionKind: String, CaseIterable {
    case acceleration, braking, bankLeft, bankRight, lift, drop, pitchForward, pitchBackward, turbulence, engineRumble
}

@MainActor
final class FourDXEngine {
    private(set) var rumble: Float = 0
    private(set) var strobe: Float = 0
    private(set) var fogBoost: Float = 0
    private(set) var seatOffset = Vec3.zero
    private(set) var seatTilt = Vec2.zero
    private(set) var motionKind: FourDXMotionKind = .engineRumble
    private(set) var cueSource = "Live picture motion"

    private let cache = FourDXCueCache()
    private var mediaID: String?
    private var mediaDuration: Double = 0
    private var stored: [FourDXMotionCue] = []
    private var replay: [FourDXMotionCue] = []
    private var lastRecorded: Double = -1
    private var lastSaved: Double = -1
    private var previousGrid = [Float](repeating: 0, count: 64)
    private var primed = false
    private var cutHold: Float = 0.35
    private var lastTimestamp: Double?
    private var velocity = Vec2.zero
    private var engine: CHHapticEngine?
    private var rumblePlayer: CHHapticAdvancedPatternPlayer?
    private var lastHapticUpdate: Double = -1
    private(set) var running = false

    func beginMedia(id: String, duration: Double) {
        guard !id.isEmpty, duration.isFinite, duration > 0 else { return }
        guard mediaID != id || abs(mediaDuration - duration) > 1 else { return }
        flushCache()
        mediaID = id
        mediaDuration = duration
        stored = []
        replay = []
        lastRecorded = -1
        lastSaved = -1
        primed = false
        cueSource = "Live picture motion"
        Task { [weak self, cache] in
            let cues = await cache.load(mediaID: id, duration: duration)
            guard let self, self.mediaID == id else { return }
            self.replay = cues
            if !cues.isEmpty { self.cueSource = "Cached picture motion" }
        }
    }

    private func flushCache() {
        guard let id = mediaID, mediaDuration > 0, !stored.isEmpty else { return }
        let snapshot = stored
        let duration = mediaDuration
        Task { [cache] in
            let previous = await cache.load(mediaID: id, duration: duration)
            await cache.save(mediaID: id, duration: duration, cues: previous + snapshot)
        }
    }

    func start(haptics: Bool) {
        guard !running else { return }
        running = true
        resetMotion()
        guard haptics, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let e = try CHHapticEngine()
            e.isAutoShutdownEnabled = false
            e.resetHandler = { [weak e] in try? e?.start() }
            try e.start()
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.1)
            ], relativeTime: 0, duration: 3600)
            let player = try e.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)], atTime: CHHapticTimeImmediate)
            engine = e
            rumblePlayer = player
        } catch { engine = nil }
    }

    private func resetMotion() {
        primed = false
        cutHold = 0.35
        lastTimestamp = nil
        previousGrid = [Float](repeating: 0, count: 64)
        velocity = .zero
        rumble = 0
        strobe = 0
        fogBoost = 0
        seatOffset = .zero
        seatTilt = .zero
    }

    func stop() {
        guard running else { return }
        flushCache()
        stored.removeAll(keepingCapacity: true)
        running = false
        try? rumblePlayer?.stop(atTime: CHHapticTimeImmediate)
        rumblePlayer = nil
        engine?.stop(completionHandler: nil)
        engine = nil
        resetMotion()
    }

    /// Measures coarse apparent visual pan, with a holdoff on cuts and flashes.
    /// Missing frames never trigger new motion patterns.
    private func analyse(_ grid: UnsafePointer<Vec4>?) -> FourDXMotionCue? {
        guard let grid else { return nil }
        var current = [Float](repeating: 0, count: 64)
        var total: Float = 0
        for i in 0..<64 {
            let c = grid[i]
            let lum = max(0, min(1, c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722))
            current[i] = lum
            total += abs(lum - previousGrid[i])
        }
        defer { previousGrid = current; primed = true }
        guard primed else { return nil }
        let mean = total / 64
        if mean > 0.13 { cutHold = 0.4; return nil }
        func mismatch(dx: Int, dy: Int) -> Float {
            var score: Float = 0
            var count: Float = 0
            for y in 1..<7 {
                for x in 1..<7 {
                    let ix = x + dx, iy = y + dy
                    score += abs(current[y * 8 + x] - previousGrid[iy * 8 + ix])
                    count += 1
                }
            }
            return score / max(1, count)
        }
        let stationary = mismatch(dx: 0, dy: 0)
        let candidates: [(Int, Int)] = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        var best = stationary
        var selected = (0, 0)
        for (x, y) in candidates {
            let m = mismatch(dx: x, dy: y)
            if m < best { best = m; selected = (x, y) }
        }
        let confidence = best < stationary * 0.78 && stationary > 0.007
        return FourDXMotionCue(timestamp: 0,
            energy: min(0.3, mean * 2.5),
            flowX: confidence ? Float(selected.0) * min(0.24, stationary * 1.7) : 0,
            flowY: confidence ? Float(selected.1) * min(0.24, stationary * 1.7) : 0)
    }

    func update(grid: UnsafePointer<Vec4>?, dt: Float, intensity: Float, seatForward: Vec3, timestamp: Double = 0) {
        guard running else { return }
        let seconds = timestamp.isFinite ? max(0, timestamp) : 0
        let step = dt.isFinite ? max(0, min(0.1, dt)) : 0
        let strength = intensity.isFinite ? max(0, min(1, intensity)) : 0
        if let prev = lastTimestamp, seconds < prev - 0.1 || seconds - prev > 1.0 {
            resetMotion() // seeking / buffering discontinuity
        }
        lastTimestamp = seconds
        cutHold = max(0, cutHold - step)
        var cue = analyse(grid)
        if !replay.isEmpty, let closest = replay.min(by: { abs($0.timestamp - seconds) < abs($1.timestamp - seconds) }),
           abs(closest.timestamp - seconds) < 0.38 {
            cue = closest
        }
        if cutHold > 0 { cue = nil }
        let energy = min(0.25, max(0, cue?.energy ?? 0)) * strength
        let sx = max(-0.22, min(0.22, cue?.flowX ?? 0)) * strength
        let sy = max(-0.22, min(0.22, cue?.flowY ?? 0)) * strength
        if abs(sx) > 0.025 { motionKind = sx > 0 ? .bankRight : .bankLeft }
        else if abs(sy) > 0.025 { motionKind = sy > 0 ? .lift : .drop }
        else if energy > 0.1 { motionKind = .turbulence }
        else { motionKind = .engineRumble }

        let smooth: Float = 1 - expf(-step * 5)
        rumble += (energy - rumble) * smooth
        velocity += (Vec2(sx, sy) - velocity) * smooth
        let t = Float(seconds)
        let forward = simd_length_squared(seatForward) > 0.01 ? simd_normalize(seatForward) : Vec3(0, 0, 1)
        let right = simd_normalize(simd_cross(forward, Vec3(0, 1, 0)))
        let targetTilt = Vec2(-velocity.y * 0.05 + sinf(t * 6) * rumble * 0.01,
                              -velocity.x * 0.07 + sinf(t * 3.8) * rumble * 0.015)
        let targetOffset = right * (velocity.x * 0.035) +
            Vec3(0, velocity.y * 0.045 + sinf(t * 17) * rumble * 0.012, 0) +
            forward * (-energy * 0.025)
        seatTilt += (targetTilt - seatTilt) * smooth
        seatOffset += (targetOffset - seatOffset) * smooth
        strobe = 0 // No flashing from brightness alone.
        fogBoost = 0 // No atmospheric effects without a classifier.

        if let c = cue, grid != nil, seconds - lastRecorded >= 0.48, mediaID != nil {
            stored.append(FourDXMotionCue(timestamp: seconds, energy: c.energy, flowX: c.flowX, flowY: c.flowY))
            lastRecorded = seconds
        }
        if seconds - lastSaved >= 20, !stored.isEmpty {
            flushCache()
            stored.removeAll(keepingCapacity: true)
            lastSaved = seconds
        }
        if let p = rumblePlayer, seconds - lastHapticUpdate > 0.075 {
            lastHapticUpdate = seconds
            try? p.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                value: min(0.35, rumble), relativeTime: 0)], atTime: CHHapticTimeImmediate)
        }
    }
}

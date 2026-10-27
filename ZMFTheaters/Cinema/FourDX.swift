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
    private(set) var mist: Float = 0
    private(set) var snow: Float = 0
    private(set) var ash: Float = 0
    private(set) var virtualFog: Float = 0
    private(set) var inTrailerPreview = false
    /// Screen-space 4DX layer (0–1): water droplets/mist on your view, wind
    /// streaks and a bounded light flash. These are virtual visual effects
    /// for the iPhone display; no physical water, air or strobe hardware.
    private(set) var water: Float = 0
    private(set) var wind: Float = 0
    private(set) var flash: Float = 0
    /// Allows short, bounded preset/ride flashes (never from brightness).
    var flashesAllowed = false
    private var lastFlash: Double = -10
    private var lastSplash: Double = -10

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
    private var inRide = false

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
        lastHapticUpdate = -1
        rumble = 0
        strobe = 0
        fogBoost = 0
        seatOffset = .zero
        seatTilt = .zero
        mist = 0; snow = 0; ash = 0; virtualFog = 0
        water = 0; wind = 0; flash = 0
        lastFlash = -10; lastSplash = -10
        inTrailerPreview = false
        inRide = false
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
        // Binary search keeps repeated playback cheap even for a long movie.
        if !replay.isEmpty {
            var low = 0, high = replay.count
            while low < high {
                let mid = low + (high - low) / 2
                if replay[mid].timestamp < seconds { low = mid + 1 } else { high = mid }
            }
            var closest: FourDXMotionCue?
            if low < replay.count { closest = replay[low] }
            if low > 0, let c = closest {
                if abs(replay[low - 1].timestamp - seconds) < abs(c.timestamp - seconds) {
                    closest = replay[low - 1]
                }
            } else if low > 0 { closest = replay[low - 1] }
            if let c = closest, abs(c.timestamp - seconds) < 0.38 { cue = c }
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
        let horizontal = simd_cross(forward, Vec3(0, 1, 0))
        let right = simd_length_squared(horizontal) > 0.00001 ? simd_normalize(horizontal) : Vec3(1, 0, 0)
        // Gradual movement in the simulated chair with bounded pitch, bank,
        // vertical lift, forward thrust and vibration, not abrupt screen shake.
        let bank = max(-0.08, min(0.08, -velocity.x * 0.34))
        let pitch = max(-0.07, min(0.07, -velocity.y * 0.25))
        let targetTilt = Vec2(pitch + sinf(t * 6) * rumble * 0.018,
                              bank + sinf(t * 3.8) * rumble * 0.02)
        let targetOffset = right * (velocity.x * 0.20) +
            Vec3(0, velocity.y * 0.20 + sinf(t * 7) * rumble * 0.045, 0) +
            forward * (-energy * 0.17)
        seatTilt += (targetTilt - seatTilt) * smooth
        seatOffset += (targetOffset - seatOffset) * smooth
        strobe = 0 // No flashing from brightness alone.
        fogBoost = 0 // No bright flash or hazardous physical effect is emitted.

        // Sequence is a visual demonstration, not scene classification.
        // Every preset takes turns through a 56-second loop and is intensity-
        // modulated. Later semantic recognition can select the actual cues.
        updateAtmosphere(timestamp: seconds, activity: rumble)
        // Wind follows measured picture motion (pans/fast movement), the same
        // evidence that drives the seat. Water mist only rides the labelled
        // demonstration mist scene; nothing is inferred from brightness.
        updateScreenLayer(step: step, wind: min(1, simd_length(velocity) * 4 + rumble * 1.6) * strength,
                          water: mist > 0.55 && rumble > 0.06 ? mist * 0.6 * strength : 0, flash: 0)

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

    /// On-device clock-synchronized virtual cinema cues. With protected YouTube
    /// playback the iframe exposes time and play/pause, NOT decoded video frames
    /// or audio FFT. The rhythm is selected by the user and cut markers are
    /// placed by the user while watching. No automatic edit detection claimed.
    func updateYouTubeCinema(dt: Float, timestamp: Double, intensity: Float,
                             seatForward: Vec3, preset: YouTubeMotionPreset,
                             bpm: Double, cuts: [Double]) {
        guard running else { return }
        if preset == .off { resetMotion(); return }
        let seconds = timestamp.isFinite ? max(0, timestamp) : 0
        let b = bpm.isFinite ? max(60, min(200, bpm)) : 120
        let step = dt.isFinite ? max(0, min(0.1, dt)) : 0
        let strength = intensity.isFinite ? max(0, min(1, intensity)) : 0
        if !inTrailerPreview { resetMotion(); inTrailerPreview = true }
        if let previous = lastTimestamp, seconds < previous - 0.16 || seconds - previous > 1.5 {
            resetMotion(); inTrailerPreview = true
        }
        lastTimestamp = seconds

        // Beat envelope varies by experience. Sharp marked cut cues only fire
        // near a user-provided edit marker, not an arbitrary camera change.
        let beat = Float(seconds * b / 60)
        let cycle = beat - floorf(beat)
        let onset = expf(-cycle * 9)
        let marker = cuts.contains { abs($0 - seconds) < 0.10 }
        let cutPulse: Float = marker ? 0.32 : 0
        let motion: Float
        let frequency: Float
        switch preset {
        case .edits: motion = 0.055; frequency = 1.45
        case .concert: motion = 0.038; frequency = 0.75
        case .minecraft: motion = 0.04; frequency = 1.2
        case .cinematic: motion = 0.03; frequency = 0.4
        case .off: motion = 0; frequency = 0
        }
        let t = Float(seconds)
        let pulse = min(0.38, (0.04 + onset * 0.19 + cutPulse) * strength)
        let alpha = 1 - expf(-step * (preset == .edits ? 9 : 5))
        let direction = sinf(t * frequency)
        let forward = simd_length_squared(seatForward) > 0.01 ? simd_normalize(seatForward) : Vec3(0, 0, 1)
        let horizontal = simd_cross(forward, Vec3(0, 1, 0))
        let right = simd_length_squared(horizontal) > 0.00001 ? simd_normalize(horizontal) : Vec3(1, 0, 0)
        let targetOffset = right * (direction * motion * strength) +
            Vec3(0, sinf(t * frequency * 0.8) * 0.037 * strength + pulse * 0.032, 0) +
            forward * (-pulse * 0.08)
        let targetTilt = Vec2(sinf(t * frequency * 0.82) * 0.045 * strength,
                             direction * 0.065 * strength)
        seatOffset += (targetOffset - seatOffset) * alpha
        seatTilt += (targetTilt - seatTilt) * alpha
        rumble += (pulse - rumble) * alpha
        motionKind = cutPulse > 0 ? .turbulence : (direction > 0 ? .bankRight : .bankLeft)
        strobe = 0
        updateAtmosphere(timestamp: seconds, activity: rumble)
        // Splash and light cues come from the user's own edit marks and the
        // chosen rhythm; they are clock-synchronised, not content-detected.
        if marker && seconds - lastSplash > 0.8 { lastSplash = seconds }
        let splash: Float = seconds - lastSplash < 0.6 ? strength : 0
        var light: Float = 0
        if flashesAllowed && (preset == .concert || preset == .edits) && onset > 0.85 && seconds - lastFlash > 0.5 {
            lastFlash = seconds
        }
        if flashesAllowed && seconds - lastFlash < 0.12 { light = 0.22 * strength }
        updateScreenLayer(step: step, wind: min(1, abs(direction) * motion * 14 + pulse) * strength,
                          water: max(splash, mist > 0.55 ? mist * 0.35 * strength : 0), flash: light)
        if let player = rumblePlayer, seconds - lastHapticUpdate > 0.075 {
            lastHapticUpdate = seconds
            try? player.sendParameters([CHHapticDynamicParameter(
                parameterID: .hapticIntensityControl, value: min(0.3, rumble), relativeTime: 0)],
                atTime: CHHapticTimeImmediate)
        }
    }

    /// Eases the screen-space layer. Water rises fast (a spray hits) and
    /// drains slowly; flash is capped at 0.35 and rate-limited by callers.
    private func updateScreenLayer(step: Float, wind w: Float, water wt: Float, flash f: Float) {
        let wTarget = max(0, min(1, w.isFinite ? w : 0))
        let waterTarget = max(0, min(1, wt.isFinite ? wt : 0))
        wind += (wTarget - wind) * (1 - expf(-step * 4))
        water += (waterTarget - water) * (1 - expf(-step * (waterTarget > water ? 9 : 0.45)))
        let fTarget = max(0, min(0.35, f.isFinite ? f : 0))
        flash += (fTarget - flash) * (1 - expf(-step * (fTarget > flash ? 30 : 8)))
    }

    /// Direct drive from a scripted ride (the ZMF roller-coaster intro): the
    /// ride's own physics provide seat motion, wind, spray and flashes.
    func updateRide(dt: Float, offset: Vec3, tilt: Vec2, rumble r: Float, wind w: Float, water wt: Float, flash f: Float, intensity: Float) {
        guard running else { return }
        if !inRide { resetMotion(); inRide = true }
        let step = dt.isFinite ? max(0, min(0.1, dt)) : 0
        let k = intensity.isFinite ? max(0, min(1, intensity)) : 0
        let alpha = 1 - expf(-step * 7)
        let clampedTilt = Vec2(max(-0.12, min(0.12, tilt.x)), max(-0.14, min(0.14, tilt.y))) * k
        let clampedOffset = Vec3(max(-0.12, min(0.12, offset.x)), max(-0.1, min(0.1, offset.y)), max(-0.12, min(0.12, offset.z))) * k
        seatOffset += (clampedOffset - seatOffset) * alpha
        seatTilt += (clampedTilt - seatTilt) * alpha
        rumble += (max(0, min(0.4, r)) * k - rumble) * alpha
        motionKind = .turbulence
        strobe = 0
        updateScreenLayer(step: step, wind: w * k, water: wt * k, flash: flashesAllowed ? f * k : 0)
        if let p = rumblePlayer {
            try? p.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                value: min(0.4, rumble), relativeTime: 0)], atTime: CHHapticTimeImmediate)
        }
    }

    private func updateAtmosphere(timestamp: Double, activity: Float) {
        let scene = Int(max(0, timestamp) / 14) % 4
        let pulse = 0.35 + 0.65 * max(0, min(1, (activity + 0.07) * 5))
        let smoothing: Float = 0.12
        mist += ((scene == 0 ? pulse : 0) - mist) * smoothing
        snow += ((scene == 1 ? pulse : 0) - snow) * smoothing
        ash += ((scene == 2 ? pulse : 0) - ash) * smoothing
        virtualFog += ((scene == 3 ? pulse : 0) - virtualFog) * smoothing
    }

    /// A gentle *scripted* preview motion when a YouTube iframe is playing.
    /// Never claims video pixels or audio have been analysed.
    func updateTrailerPreview(dt: Float, timestamp: Double, intensity: Float, seatForward: Vec3) {
        guard running else { return }
        if !inTrailerPreview { resetMotion(); inTrailerPreview = true }
        let step = dt.isFinite ? max(0, min(0.1, dt)) : 0
        let t = Float(timestamp.isFinite ? max(0, timestamp) : 0)
        let k = intensity.isFinite ? max(0, min(1, intensity)) : 0
        let forward = simd_length_squared(seatForward) > 0.01 ? simd_normalize(seatForward) : Vec3(0, 0, 1)
        let horizontal = simd_cross(forward, Vec3(0, 1, 0))
        let right = simd_length_squared(horizontal) > 0.00001 ? simd_normalize(horizontal) : Vec3(1, 0, 0)
        let alpha = 1 - expf(-step * 3.5)
        let targetOffset = right * (0.045 * sinf(t * 0.6) * k) +
            Vec3(0, 0.035 * sinf(t * 1.25) * k, 0) +
            forward * (0.025 * sinf(t * 0.4) * k)
        let targetTilt = Vec2(0.045 * sinf(t * 0.6) * k, 0.065 * sinf(t * 0.45) * k)
        seatOffset += (targetOffset - seatOffset) * alpha
        seatTilt += (targetTilt - seatTilt) * alpha
        rumble += ((0.05 + 0.04 * abs(sinf(t * 1.5))) * k - rumble) * alpha
        motionKind = .turbulence
        strobe = 0
        updateAtmosphere(timestamp: timestamp, activity: rumble)
        updateScreenLayer(step: step, wind: min(1, 0.25 + abs(sinf(t * 0.6)) * 0.5) * k,
                          water: mist > 0.55 ? mist * 0.45 * k : 0, flash: 0)
        if let p = rumblePlayer, Double(t) - lastHapticUpdate > 0.075 {
            lastHapticUpdate = Double(t)
            try? p.sendParameters([CHHapticDynamicParameter(
                parameterID: .hapticIntensityControl, value: min(0.2, rumble), relativeTime: 0)],
                atTime: CHHapticTimeImmediate)
        }
    }
}

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
        settings.fourDXForcePreview || (now >= previewStart && now < previewEnd)
    }

    /// Short line for signage and the title screen.
    static func teaser(now: Date = Date(), settings: AppSettings) -> String {
        if isPreviewActive(now: now, settings: settings) { return "4DX PREVIEW NOW PLAYING · Choose 4DX at the Box Office" }
        if now < previewStart {
            let days = Int(ceil(previewStart.timeIntervalSince(now) / 86_400))
            return "4DX PREVIEW · OCT 27–28 · \(days == 1 ? "tomorrow" : "in \(days) days")"
        }
        return "4DX PREVIEW ENDED · Full 4DX coming in a future update"
    }
}

/// Turns what's happening on screen into motion-seat movement, rumble, strobes
/// and fog bursts. 4DX cues are derived live from the picture (motion energy
/// and sudden brightness spikes across an 8×8 grid computed on the GPU), so
/// they work for every film without hand-authored effect tracks.
@MainActor
final class FourDXEngine {
    private(set) var rumble: Float = 0
    private(set) var strobe: Float = 0
    private(set) var fogBoost: Float = 0
    private(set) var seatOffset = Vec3.zero      // camera offset (m)
    private(set) var seatTilt = Vec2.zero        // pitch/roll (rad)

    private var prev = [Float](repeating: 0, count: 64)
    private var emaBright: Float = 0
    private var primed = false
    private var t: Float = 0
    private var engine: CHHapticEngine?
    private var rumblePlayer: CHHapticAdvancedPatternPlayer?
    private var lastHapticUpdate: Float = 0
    private(set) var running = false

    func start(haptics: Bool) {
        guard !running else { return }
        running = true
        primed = false
        guard haptics, CHHapticEngine.capabilitiesForHardware().supportsHaptics else { return }
        do {
            let e = try CHHapticEngine()
            e.isAutoShutdownEnabled = false
            e.resetHandler = { [weak e] in try? e?.start() }
            try e.start()
            let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.15),
            ], relativeTime: 0, duration: 3600)
            let player = try e.makeAdvancedPlayer(with: CHHapticPattern(events: [event], parameters: []))
            try player.start(atTime: CHHapticTimeImmediate)
            try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0, relativeTime: 0)], atTime: CHHapticTimeImmediate)
            engine = e
            rumblePlayer = player
        } catch {
            engine = nil
        }
    }

    func stop() {
        guard running else { return }
        running = false
        try? rumblePlayer?.stop(atTime: CHHapticTimeImmediate)
        rumblePlayer = nil
        engine?.stop(completionHandler: nil)
        engine = nil
        rumble = 0; strobe = 0; fogBoost = 0
        seatOffset = .zero; seatTilt = .zero
    }

    /// `grid` = 64 colour samples of the current screen image.
    func update(grid: UnsafePointer<Vec4>?, dt: Float, intensity: Float, seatForward: Vec3) {
        t += dt
        var motion: Float = 0
        var bright: Float = 0
        if running, let grid {
            for i in 0..<64 {
                let c = grid[i]
                let lum = c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722
                motion += abs(lum - prev[i])
                bright += lum
                prev[i] = lum
            }
            motion /= 64
            bright /= 64
        }
        if !primed { emaBright = bright; primed = true; motion = 0 }

        let cut = motion > 0.16                                   // hard scene cut, not action
        let target = running && !cut ? min(1, motion * 7) * intensity : 0
        rumble += (target - rumble) * min(1, dt * 5)
        let jump = bright - emaBright
        if running && !cut && jump > 0.08 {
            let hit = min(1, jump * 5) * intensity               // flash / explosion
            strobe = max(strobe, hit)
            fogBoost = min(1, fogBoost + hit * 0.6)
            impact(hit)
        }
        emaBright += (bright - emaBright) * min(1, dt * 2)
        strobe *= expf(-dt * 7)
        fogBoost *= expf(-dt * 1.2)

        // Motion seat: low-frequency sway from sustained action, a kick on impacts.
        let sway = rumble * 0.6 + strobe
        seatTilt = Vec2(sinf(t * 7.3) * 0.012, sinf(t * 5.1 + 1.3) * 0.016) * sway
        let right = simd_normalize(simd_cross(seatForward, Vec3(0, 1, 0)))
        seatOffset = Vec3(0, sinf(t * 23) * 0.006 * rumble - strobe * 0.03, 0) + right * (sinf(t * 17.7) * 0.008 * rumble)

        if let p = rumblePlayer, t - lastHapticUpdate > 0.05 {
            lastHapticUpdate = t
            try? p.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: min(1, rumble * 1.2), relativeTime: 0)],
                                  atTime: CHHapticTimeImmediate)
        }
    }

    private func impact(_ strength: Float) {
        guard let engine else { return }
        let event = CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: min(1, 0.4 + strength)),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.6),
        ], relativeTime: 0)
        if let pattern = try? CHHapticPattern(events: [event], parameters: []),
           let player = try? engine.makePlayer(with: pattern) {
            try? player.start(atTime: CHHapticTimeImmediate)
        }
    }
}

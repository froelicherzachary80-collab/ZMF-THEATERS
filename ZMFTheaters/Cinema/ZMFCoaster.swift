import Foundation
import AVFoundation
import simd

/// The ZMF THEATERS roller-coaster intro: an original first-person ride shown
/// on the auditorium screen before the feature (lift hill → big drop → banked
/// turns → splash tunnel → final hill onto the ZMF THEATERS marquee). The same
/// physics drive the virtual 4DX seat, wind, water spray and flashes.
///
/// The track is deterministic: given a ride time it always returns the same
/// pose, so seat motion can never drift from what is on screen.
final class ZMFCoasterTrack: @unchecked Sendable {
    static let shared = ZMFCoasterTrack()

    struct Pose {
        var position: Vec3
        var forward: Vec3
        var up: Vec3
        var speed: Float
        var bank: Float
        var slope: Float          // sin of the climb angle (+ up)
        var verticalG: Float      // extra g felt (+ pressed into seat)
        var lateralG: Float       // + pushed to the right
        var longitudinalG: Float  // + pushed back into the seat
        var distance: Float
        var inSplash: Bool
        var onLift: Bool
    }

    /// Control points of the layout (metres). Catmull-Rom through them.
    static let controlPoints: [Vec3] = [
        Vec3(0, 2, -12), Vec3(0, 2, 0), Vec3(0, 2, 16),
        Vec3(0, 7, 32), Vec3(0, 15, 48), Vec3(0, 23, 64), Vec3(0, 27, 76), Vec3(0, 27.5, 84),  // lift hill
        Vec3(0, 16, 98), Vec3(0, 3.5, 114),                                                   // first drop
        Vec3(7, 4, 130), Vec3(22, 7, 140), Vec3(38, 10, 136), Vec3(48, 9, 120),              // banked right turn
        Vec3(51, 12, 104), Vec3(49, 5, 88),                                                   // camel hump
        Vec3(43, 1.4, 72), Vec3(35, 1.4, 58),                                                 // splash tunnel
        Vec3(25, 6, 47), Vec3(12, 9, 44), Vec3(-2, 8, 52),                                   // left climb + turn
        Vec3(-14, 4, 66), Vec3(-24, 6, 84), Vec3(-28, 9, 102), Vec3(-28, 9.5, 118),          // final rise
        Vec3(-28, 9.5, 130), Vec3(-28, 9.5, 140)                                              // brake run / marquee
    ]

    static let liftStart: Float = 0.11                             // fraction of track length
    /// The chain releases just past the crest (found from the layout).
    private(set) var liftEnd: Float = 0.24
    static let splashRange: ClosedRange<Float> = 0.6...0.68
    static let logoPosition = Vec3(-28, 17, 168)
    static let poolCenter = Vec3(39, 0.05, 65)

    private(set) var points: [Vec3] = []      // dense samples
    private(set) var cumulative: [Float] = [] // arclength at each sample
    private(set) var length: Float = 0
    private var timeline: [(t: Float, s: Float, v: Float)] = []
    private(set) var rideDuration: Float = 0
    /// Total intro length: ride plus a hold on the marquee.
    var duration: Double { Double(rideDuration) + 4.5 }

    /// Smoothed bank angle per metre of track, shared by the camera and the
    /// track geometry so the rails always roll with the view.
    private(set) var bankByMeter: [Float] = []

    init() {
        build()
        simulate()
        computeBanking()
    }

    private func speed(atDistance s: Float) -> Float {
        var lo = 0, hi = timeline.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if timeline[mid].s <= s { lo = mid } else { hi = mid } }
        return timeline[lo].v
    }

    private func computeBanking() {
        let meters = Int(length) + 2
        var raw = [Float](repeating: 0, count: meters)
        for m in 0..<meters {
            let s = Float(m), v = speed(atDistance: s)
            let span = max(4, v)
            let turn = simd_cross(tangent(at: s - span * 0.5), tangent(at: s + span * 0.5))
            raw[m] = max(-0.95, min(0.95, atanf(v * v * (turn.y / span) / 9.81) * 0.9))
        }
        bankByMeter = raw.indices.map { m in
            let lo = max(0, m - 6), hi = min(meters - 1, m + 6)
            return raw[lo...hi].reduce(0, +) / Float(hi - lo + 1)
        }
    }

    func bank(atDistance s: Float) -> Float {
        guard !bankByMeter.isEmpty else { return 0 }
        let x = max(0, min(Float(bankByMeter.count - 1), s))
        let i = Int(x), j = min(bankByMeter.count - 1, i + 1)
        return bankByMeter[i] + (bankByMeter[j] - bankByMeter[i]) * (x - Float(i))
    }

    /// Track frame at a distance: forward, right and (banked) up.
    func frame(atDistance s: Float) -> (forward: Vec3, right: Vec3, up: Vec3) {
        let fwd = tangent(at: s)
        let flat = simd_cross(fwd, Vec3(0, 1, 0))
        let right0 = simd_length(flat) > 1e-4 ? simd_normalize(flat) : Vec3(1, 0, 0)
        let up0 = simd_normalize(simd_cross(right0, fwd))
        let b = bank(atDistance: s)
        let up = simd_normalize(up0 * cosf(b) - right0 * sinf(b))
        return (fwd, simd_normalize(simd_cross(fwd, up)), up)
    }

    private func catmull(_ p0: Vec3, _ p1: Vec3, _ p2: Vec3, _ p3: Vec3, _ t: Float) -> Vec3 {
        let t2 = t * t, t3 = t2 * t
        let a = p1 * 2
        let b = (p2 - p0) * t
        let c = (p0 * 2 - p1 * 5 + p2 * 4 - p3) * t2
        let d = (p1 * 3 - p0 - p2 * 3 + p3) * t3
        return (a + b + c + d) * 0.5
    }

    private func build() {
        let cp = Self.controlPoints
        let n = cp.count
        for i in 0..<(n - 1) {
            let p0 = cp[max(0, i - 1)], p1 = cp[i], p2 = cp[i + 1], p3 = cp[min(n - 1, i + 2)]
            for k in 0..<80 { points.append(catmull(p0, p1, p2, p3, Float(k) / 80)) }
        }
        points.append(cp[n - 1])
        cumulative = [0]
        for i in 1..<points.count { cumulative.append(cumulative[i - 1] + simd_distance(points[i], points[i - 1])) }
        length = cumulative.last ?? 1
        if let crest = points.indices.max(by: { points[$0].y < points[$1].y }) {
            liftEnd = cumulative[crest] / length + 0.005
        }
    }

    /// Position at arclength s (clamped) using the dense table.
    func point(at s: Float) -> Vec3 {
        let x = max(0, min(length, s))
        var lo = 0, hi = cumulative.count - 1
        while hi - lo > 1 { let mid = (lo + hi) / 2; if cumulative[mid] <= x { lo = mid } else { hi = mid } }
        let span = max(1e-4, cumulative[hi] - cumulative[lo])
        return simd_mix(points[lo], points[hi], Vec3(repeating: (x - cumulative[lo]) / span))
    }

    func tangent(at s: Float) -> Vec3 {
        let d = point(at: s + 0.8) - point(at: s - 0.8)
        return simd_length(d) > 1e-4 ? simd_normalize(d) : Vec3(0, 0, 1)
    }

    private func height(at s: Float) -> Float { point(at: s).y }

    /// Energy-based speed with a chain lift, rolling friction and a final brake.
    private func simulate() {
        let g: Float = 9.81
        var s: Float = 0, v: Float = 3.5, t: Float = 0
        let dt: Float = 1.0 / 120
        let liftA = Self.liftStart * length, liftB = liftEnd * length
        let brake = length - 30
        timeline = [(0, 0, v)]
        while s < length - 0.05 && t < 120 {
            if s < liftA {
                v += (5.5 - v) * min(1, dt * 1.2)                // station push
            } else if s < liftB {
                v += (7 - v) * min(1, dt * 2)                    // chain lift
            } else if s > brake {
                v = max(1.2, min(v, sqrtf(2 * 1.6 * (length - s)) + 1.2))   // magnetic brakes
            } else {
                let slope = tangent(at: s).y
                v += (-g * slope - 0.003 * v * v - 0.15) * dt     // gravity, drag, rolling
                v = max(5, v)                                    // booster tyres keep it moving
            }
            s += v * dt
            t += dt
            timeline.append((t, min(s, length), v))
        }
        rideDuration = t
    }

    /// Ride pose at time t (seconds since the intro began).
    func pose(at time: Double) -> Pose {
        let t = Float(max(0, min(Double(rideDuration), time.isFinite ? time : 0)))
        let i = min(timeline.count - 1, max(0, Int(t * 120)))
        let s = timeline[i].s, v = timeline[i].v
        let prevV = timeline[max(0, i - 12)].v
        let fwd = tangent(at: s)
        let ahead = tangent(at: s + max(2, v * 0.5))
        let behind = tangent(at: s - max(2, v * 0.5))
        let ds = max(4, v * 1.0)
        // Curvature split into horizontal (bank) and vertical (airtime) parts.
        let turn = simd_cross(behind, ahead)
        let horizontalK = turn.y / ds
        let verticalK = (ahead.y - behind.y) / ds
        let latA = v * v * horizontalK
        let g: Float = 9.81
        let bank = self.bank(atDistance: s)
        let up = frame(atDistance: s).up
        let frac = s / max(1, length)
        return Pose(position: point(at: s), forward: fwd, up: up, speed: v, bank: bank, slope: fwd.y,
                    verticalG: max(-1.2, min(2.5, v * v * verticalK / g)),
                    lateralG: max(-1.5, min(1.5, latA / g - sinf(bank))),
                    longitudinalG: max(-1, min(1, (v - prevV) / 0.1 / g)),
                    distance: s,
                    inSplash: Self.splashRange.contains(frac) && point(at: s).y < 3,
                    onLift: frac > Self.liftStart && frac < liftEnd)
    }

    /// Bounded 4DX seat cue in the seat's own frame (x right, y up, z back).
    struct SeatCue { var offset: Vec3; var tilt: Vec2; var rumble: Float; var wind: Float; var water: Float; var flash: Float }

    func seatCue(at time: Double) -> SeatCue {
        let p = pose(at: time)
        let finale = time > Double(rideDuration) - 1.5
        let fw = Float(time)
        let chain: Float = p.onLift ? 0.12 + 0.08 * (sinf(fw * 38) > 0.6 ? 1 : 0) : 0
        let flashOn = finale && sinf(fw * 4.7) > 0.93
        return SeatCue(offset: Vec3(-p.lateralG * 0.05, (p.verticalG) * 0.035 - 0.01, p.longitudinalG * 0.06),
                       tilt: Vec2(p.slope * 0.22 - p.longitudinalG * 0.04, -p.bank * 0.14 + p.lateralG * 0.03),
                       rumble: min(0.4, p.speed / 30 * 0.3 + chain),
                       wind: min(1, p.speed / 22),
                       water: p.inSplash ? 1 : 0,
                       flash: flashOn ? 0.3 : 0)
    }
}

/// Original announcer lines spoken with the system voice. Timed to the ride.
@MainActor
final class ZMFCoasterAnnouncer {
    private let synth = AVSpeechSynthesizer()
    private var spoken = Set<Int>()
    var enabled = true

    private var script: [(Double, String)] {
        let end = Double(ZMFCoasterTrack.shared.rideDuration)
        return [
            (0.6, "Welcome to Z M F Theaters."),
            (4.5, "Please keep your hands and feet inside the ride… and hold on to your popcorn."),
            (end * 0.27, "Here we go!"),
            (end * 0.62, "Hope you don't mind getting a little wet."),
            (end - 0.5, "Z M F Theaters. Sit back, relax, and enjoy the show.")
        ]
    }

    func update(time: Double) {
        guard enabled else { return }
        for (i, line) in script.enumerated() where time >= line.0 && !spoken.contains(i) {
            spoken.insert(i)
            let u = AVSpeechUtterance(string: line.1)
            u.rate = 0.47
            u.pitchMultiplier = 0.82
            u.volume = 0.9
            u.voice = AVSpeechSynthesisVoice(language: "en-US")
            synth.speak(u)
        }
    }

    func reset() {
        spoken.removeAll()
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}

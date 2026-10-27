import SwiftUI
import simd

/// Wraps a YouTube player so it moves with the virtual 4DX seat and gets the
/// on-screen water spray, mist, wind and flash layer drawn over it. Values
/// come from the renderer's FourDXEngine (player clock + preset, never pixels).
struct FourDXMotionStage<Content: View>: View {
    let engine: FourDXEngine?
    let enabled: Bool
    let showEffects: Bool
    @ViewBuilder var content: Content

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !enabled)) { timeline in
            let live = enabled && (engine?.running ?? false)
            let s = live ? FourDXScreenSample(engine!) : FourDXScreenSample()
            let t = timeline.date.timeIntervalSinceReferenceDate
            let jitter = CGFloat(s.rumble) * 3
            content
                .overlay {
                    if live && showEffects { FourDXScreenCanvas(sample: s, time: t).allowsHitTesting(false) }
                }
                // The view leans against your seat: bank rolls the picture,
                // lift/drop and thrust shift it, rumble adds a fine vibration.
                .rotationEffect(.radians(Double(-s.bank) * 0.35))
                .offset(x: CGFloat(-s.side) * 160 + jitter * CGFloat(sin(t * 61)),
                        y: CGFloat(s.lift) * 180 + CGFloat(s.pitch) * 90 + jitter * CGFloat(cos(t * 53)))
                .scaleEffect(1 + CGFloat(s.thrust) * 0.35)
        }
    }
}

struct FourDXScreenSample {
    var water: Float = 0, wind: Float = 0, flash: Float = 0, mist: Float = 0, rumble: Float = 0
    var bank: Float = 0, pitch: Float = 0, side: Float = 0, lift: Float = 0, thrust: Float = 0

    init() {}

    @MainActor init(_ e: FourDXEngine) {
        water = e.water; wind = e.wind; flash = e.flash; mist = e.mist; rumble = e.rumble
        bank = e.seatTilt.y; pitch = e.seatTilt.x
        // Seat offset is in world space; its length is enough for a 2D card.
        side = e.seatOffset.x + e.seatOffset.z * 0.3
        lift = -e.seatOffset.y
        thrust = max(-0.05, min(0.05, -simd_length(e.seatOffset) * 0.2))
    }
}

/// Procedural droplets that bead, slide and drain off the picture.
struct FourDXScreenCanvas: View {
    let sample: FourDXScreenSample
    let time: Double

    private func hash(_ n: Double) -> Double { let v = sin(n * 12.9898) * 43758.5453; return v - floor(v) }

    var body: some View {
        Canvas { ctx, size in
            let w = size.width, h = size.height
            if sample.mist > 0.02 || sample.water > 0.02 {
                ctx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(.white.opacity(Double(min(0.22, sample.mist * 0.12 + sample.water * 0.1)))))
            }
            let count = Int(min(1, sample.water) * 70)
            for i in 0..<count {
                let seed = Double(i) * 7.31
                let speed = 0.08 + hash(seed + 3) * 0.16
                let life = (time * speed + hash(seed)).truncatingRemainder(dividingBy: 1)
                let fade = min(1, life / 0.05) * min(1, (1 - life) / 0.4)
                let r = (3 + hash(seed + 1) * 9) * (w / 900 + 0.4)
                let x = hash(seed + 2) * w
                let y = hash(seed + 5) * h + life * h * 0.18 * hash(seed + 9)
                let rect = CGRect(x: x - r, y: y - r * 1.15, width: r * 2, height: r * 2.3)
                let a = Double(fade)
                ctx.fill(Path(ellipseIn: rect), with: .radialGradient(
                    Gradient(colors: [.white.opacity(0.05 * a), .white.opacity(0.22 * a), .black.opacity(0.25 * a)]),
                    center: CGPoint(x: x, y: y), startRadius: 0, endRadius: r * 1.2))
                ctx.fill(Path(ellipseIn: CGRect(x: x - r * 0.45, y: y - r * 0.7, width: r * 0.4, height: r * 0.32)),
                         with: .color(.white.opacity(0.7 * a)))
                if hash(seed + 11) > 0.65 {
                    var trail = Path()
                    trail.move(to: CGPoint(x: x, y: y - r))
                    trail.addLine(to: CGPoint(x: x + (hash(seed + 4) - 0.5) * 4, y: y - r - life * h * 0.2))
                    ctx.stroke(trail, with: .color(.white.opacity(0.18 * a)), lineWidth: max(1, r * 0.25))
                }
            }
            if sample.wind > 0.03 {
                let lines = Int(sample.wind * 26)
                for i in 0..<lines {
                    let seed = Double(i) * 3.7 + 100
                    let y = hash(seed) * h
                    let len = (0.08 + hash(seed + 1) * 0.18) * w
                    let x = ((time * (0.9 + hash(seed + 2) * 1.6) + hash(seed + 3)).truncatingRemainder(dividingBy: 1)) * (w + len) - len
                    let edge = abs(y / h - 0.5) > 0.22 || hash(seed + 6) > 0.7
                    guard edge else { continue }
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: y))
                    p.addLine(to: CGPoint(x: x + len, y: y + len * 0.02))
                    ctx.stroke(p, with: .color(.white.opacity(Double(sample.wind) * 0.22)), lineWidth: 1)
                }
            }
            if sample.flash > 0.01 {
                ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.white.opacity(Double(min(0.35, sample.flash)))))
            }
        }
    }
}

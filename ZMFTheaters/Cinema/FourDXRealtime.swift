import Foundation
import CoreHaptics
import simd

/// One analysed video frame from the 32×18 luminance grid.
struct FourDXMotionSample: Equatable {
    /// Apparent camera motion in grid cells per frame (+x = camera pans right,
    /// +y = camera tilts down). Sub-cell precision.
    var flow: Vec2
    /// + = camera pushing forward (picture expanding), − = pulling back.
    var zoom: Float
    /// + = picture rotating clockwise (camera rolling counter-clockwise).
    var roll: Float
    /// High-frequency jitter of the flow (handheld shake, impacts, vehicles).
    var shake: Float
    /// 0–1: how clearly a single motion explains the frame change.
    var confidence: Float
    /// Mean absolute luminance change (motion energy).
    var energy: Float
    var cut: Bool
    /// Large sudden brightening. Only ever used to *corroborate* a sound
    /// event; it never creates an effect on its own.
    var flash: Bool
}

/// Real-time camera-motion tracker on a 32×18 luminance grid: global block
/// matching with parabolic sub-cell refinement, plus per-quadrant flows for
/// zoom (push-in/pull-out) and roll. Deterministic, allocation-light.
struct FourDXMotionTracker {
    static let width = 32, height = 18
    private var prev: [Float] = []
    private var prevMean: Float = 0
    private var smoothFlow = Vec2.zero

    mutating func reset() { prev = []; prevMean = 0; smoothFlow = .zero }

    /// Returns nil until primed and while the video frame hasn't changed.
    mutating func analyse(_ lum: UnsafeBufferPointer<Float>) -> FourDXMotionSample? {
        let W = Self.width, H = Self.height
        guard lum.count >= W * H else { return nil }
        var cur = [Float](repeating: 0, count: W * H)
        var mean: Float = 0
        for i in 0..<(W * H) {
            let v = lum[i].isFinite ? max(0, min(1, lum[i])) : 0
            cur[i] = v; mean += v
        }
        mean /= Float(W * H)
        guard prev.count == W * H else { prev = cur; prevMean = mean; return nil }
        var diff: Float = 0
        for i in 0..<(W * H) { diff += abs(cur[i] - prev[i]) }
        diff /= Float(W * H)
        if diff < 0.0006 { return nil }     // same decoded frame shown again
        let flash = mean - prevMean > 0.15
        defer { prev = cur; prevMean = mean }
        if diff > 0.12 {
            smoothFlow = .zero
            return FourDXMotionSample(flow: .zero, zoom: 0, roll: 0, shake: 0, confidence: 0, energy: diff, cut: true, flash: flash)
        }
        let p = prev
        func cost(_ dx: Int, _ dy: Int, _ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Float {
            var s: Float = 0
            for y in y0..<y1 {
                let row = y * W, prow = (y + dy) * W
                for x in x0..<x1 { s += abs(cur[row + x] - p[prow + x + dx]) }
            }
            return s / Float((x1 - x0) * (y1 - y0))
        }
        // Integer search then parabolic sub-cell refinement; confidence is
        // how sharply the best match stands out from its neighbours.
        func search(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int, _ rx: Int, _ ry: Int) -> (Vec2, Float) {
            var costs = [Float](repeating: 0, count: (2 * rx + 1) * (2 * ry + 1))
            let stride = 2 * rx + 1
            var best: Float = .infinity, bx = 0, by = 0, sum: Float = 0
            for dy in -ry...ry {
                for dx in -rx...rx {
                    let c = cost(dx, dy, x0, x1, y0, y1)
                    costs[(dy + ry) * stride + dx + rx] = c
                    sum += c
                    if c < best { best = c; bx = dx; by = dy }
                }
            }
            func refine(_ cm: Float, _ c0: Float, _ cp: Float) -> Float {
                let den = cm - 2 * c0 + cp
                return den > 1e-7 ? max(-0.5, min(0.5, (cm - cp) / (2 * den))) : 0
            }
            var fx = Float(bx), fy = Float(by)
            if bx > -rx && bx < rx { fx += refine(costs[(by + ry) * stride + bx + rx - 1], best, costs[(by + ry) * stride + bx + rx + 1]) }
            if by > -ry && by < ry { fy += refine(costs[(by + ry - 1) * stride + bx + rx], best, costs[(by + ry + 1) * stride + bx + rx]) }
            let avg = sum / Float(costs.count)
            let conf: Float = avg > 0.002 ? max(0, min(1, (avg - best) / avg * 1.6)) : 0
            return (Vec2(fx, fy), conf)
        }
        let (global, confidence) = search(3, W - 3, 2, H - 2, 3, 2)
        let flow = confidence > 0.12 ? global : .zero

        // Quadrant flows → zoom and roll (translation removed first).
        let regions = [(3, 16, 2, 9), (16, W - 3, 2, 9), (3, 16, 9, H - 2), (16, W - 3, 9, H - 2)]
        let dirs = [Vec2(-1, -1), Vec2(1, -1), Vec2(-1, 1), Vec2(1, 1)].map { simd_normalize($0) }
        var zoom: Float = 0, roll: Float = 0
        for (i, r) in regions.enumerated() {
            let (q, _) = search(r.0, r.1, r.2, r.3, 2, 2)
            let content = -(q - global)
            zoom += simd_dot(content, dirs[i])
            roll += dirs[i].x * content.y - dirs[i].y * content.x
        }
        zoom = confidence > 0.12 ? zoom / 4 : 0
        roll = confidence > 0.12 ? roll / 4 : 0
        let shake = simd_length(flow - smoothFlow)
        smoothFlow += (flow - smoothFlow) * 0.3
        return FourDXMotionSample(flow: flow, zoom: zoom, roll: roll, shake: shake, confidence: confidence,
                                  energy: diff, cut: false, flash: flash)
    }
}

/// Core Haptics patterns for detected events. Built once per event; short.
enum FourDXHapticPatterns {
    static func pattern(for kind: FourDXEventKind, strength: Float) -> CHHapticPattern? {
        let s = max(0.2, min(1, strength))
        func tap(_ t: Double, _ i: Float, _ sh: Float) -> CHHapticEvent {
            CHHapticEvent(eventType: .hapticTransient, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: i),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: sh)], relativeTime: t)
        }
        switch kind {
        case .sharpHit:
            // Stab / punch / shot: a hard, bright strike with a short recoil.
            return try? CHHapticPattern(events: [tap(0, s, 0.95), tap(0.045, s * 0.45, 0.7)], parameters: [])
        case .boom:
            // Explosion: heavy thump, then a rolling low decay.
            let body = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                CHHapticEventParameter(parameterID: .hapticIntensity, value: s),
                CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.12)], relativeTime: 0.02, duration: 1.1)
            let curve = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
                .init(relativeTime: 0, value: 1), .init(relativeTime: 0.25, value: 0.7),
                .init(relativeTime: 0.7, value: 0.3), .init(relativeTime: 1.1, value: 0)], relativeTime: 0.02)
            return try? CHHapticPattern(events: [tap(0, 1, 0.3), body], parameterCurves: [curve])
        case .debris:
            // Debris patter: a few small, uneven ticks.
            var events: [CHHapticEvent] = []
            var t = 0.0
            for i in 0..<5 {
                let r = Float((sin(Double(i) * 12.9898 + Double(s) * 7) * 43758.5453).truncatingRemainder(dividingBy: 1))
                events.append(tap(t, s * (0.35 + abs(r) * 0.4), 0.6 + abs(r) * 0.4))
                t += 0.035 + Double(abs(r)) * 0.05
            }
            return try? CHHapticPattern(events: events, parameters: [])
        }
    }
}

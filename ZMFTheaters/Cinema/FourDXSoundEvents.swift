import Foundation

/// One ~6 ms chunk of the film's soundtrack, split into three bands.
struct FourDXAudioChunk: Equatable, Sendable {
    var low: Float      // RMS below ~150 Hz (booms, engines)
    var mid: Float      // 150 Hz – 3 kHz
    var high: Float     // above ~3 kHz (hits, cracks, shatter)
    var duration: Float // seconds covered by this chunk
}

/// Effect events detected in real time from the soundtrack, corroborated by
/// the picture where possible. These are *acoustic classes*, not scene
/// understanding: a "sharp hit" can be a stab, punch, gunshot or slam; a
/// "boom" is an explosion-like low-frequency blast (stronger when the
/// picture flashes at the same moment); "debris" is the crackle of small
/// transients that follows a boom. Nothing is inferred from brightness alone.
enum FourDXEventKind: String, CaseIterable, Sendable {
    case sharpHit, boom, debris
}

struct FourDXDetectedEvent: Equatable, Sendable {
    var kind: FourDXEventKind
    var time: Double      // seconds on the analyser's own clock
    var strength: Float   // 0–1
    var withFlash: Bool
}

/// Offline band split identical to the real-time tap (used by tests and tools).
func fourDXAudioChunks(mono: [Float], sampleRate: Double) -> [FourDXAudioChunk] {
    let a1 = 1 - expf(-2 * .pi * 150 / Float(sampleRate)), a2 = 1 - expf(-2 * .pi * 3000 / Float(sampleRate))
    var lp1: Float = 0, lp2: Float = 0, l: Float = 0, m2: Float = 0, h: Float = 0, n = 0
    var out: [FourDXAudioChunk] = []
    for x in mono {
        let v = x.isFinite ? x : 0
        lp1 += a1 * (v - lp1); lp2 += a2 * (v - lp2)
        let lo = lp1, mid = lp2 - lp1, hi = v - lp2
        l += lo * lo; m2 += mid * mid; h += hi * hi; n += 1
        if n >= 256 {
            let fn = Float(n)
            out.append(FourDXAudioChunk(low: (l / fn).squareRoot(), mid: (m2 / fn).squareRoot(), high: (h / fn).squareRoot(), duration: fn / Float(sampleRate)))
            l = 0; m2 = 0; h = 0; n = 0
        }
    }
    return out
}

/// Deterministic onset classifier: feed chunks in order, get events back.
struct FourDXSoundClassifier: Sendable {
    private(set) var time: Double = 0
    private var slowLow: Float = 0.01, slowMid: Float = 0.01, slowHigh: Float = 0.005
    private var fastLow: Float = 0
    private var lastHit: Double = -10, lastBoom: Double = -10, lastDebris: Double = -10
    private var debrisUntil: Double = -10
    private var lastFlash: Double = -10
    private var warm: Double = 0
    private var boomCandidate: Double = -1
    private var boomPeak: Float = 0
    private var lastLowEdge: Double = -10
    private var lowWasHigh = false
    private var candidateRhythmic = false
    /// Continuous low-frequency energy for rumble (0–1).
    private(set) var rumble: Float = 0
    /// 0.5 = conservative, 1 = default, 2 = very sensitive.
    var sensitivity: Float = 1

    mutating func noteFlash() { lastFlash = time }

    mutating func reset() { self = FourDXSoundClassifier(sensitivity: sensitivity) }

    init(sensitivity: Float = 1) { self.sensitivity = sensitivity }

    mutating func feed(_ c: FourDXAudioChunk) -> [FourDXDetectedEvent] {
        guard c.low.isFinite, c.mid.isFinite, c.high.isFinite, c.duration.isFinite, c.duration > 0 else { return [] }
        let dt = Double(min(0.1, c.duration))
        time += dt
        warm += dt
        var out: [FourDXDetectedEvent] = []
        let s = max(0.25, min(2.5, sensitivity))
        let ratioBoom: Float = 3.4 / s.squareRoot(), ratioHit: Float = 4.2 / s.squareRoot()
        fastLow += (c.low - fastLow) * min(1, Float(dt) / 0.03)
        let ready = warm > 0.4          // let the averages settle after a seek
        // A boom must *sustain* ~0.15 s: explosions do, kick drums and door
        // thuds decay within ~50 ms. Low-energy rising edges reveal rhythm: a
        // thump 0.25–1.6 s after another is a beat unless it is far louder.
        let lowHot = ready && fastLow > slowLow * ratioBoom && fastLow > 0.035 / s
        let lowEdge = fastLow > slowLow * 2.2 && fastLow > 0.025 && !lowWasHigh
        lowWasHigh = fastLow > slowLow * 1.6
        var rhythmic = false
        if lowEdge { rhythmic = time - lastLowEdge > 0.25 && time - lastLowEdge < 1.6; lastLowEdge = time }
        if lowHot && lowEdge && boomCandidate < 0 && time - lastBoom > 1.1 {
            boomCandidate = time; boomPeak = fastLow; candidateRhythmic = rhythmic
        }
        if boomCandidate >= 0 {
            boomPeak = max(boomPeak, fastLow)
            if fastLow < slowLow * ratioBoom * 0.55 {
                boomCandidate = -1
            } else if time - boomCandidate >= 0.15 {
                if candidateRhythmic && boomPeak < slowLow * ratioBoom * 2.2 {
                    boomCandidate = -1
                } else {
                    let flash = time - lastFlash < 0.4
                    let strength = min(1, 0.45 + (boomPeak / max(slowLow, 1e-4) - ratioBoom) * 0.08 + (flash ? 0.25 : 0))
                    out.append(FourDXDetectedEvent(kind: .boom, time: time, strength: strength, withFlash: flash))
                    lastBoom = time
                    debrisUntil = time + 1.8
                    boomCandidate = -1
                }
            }
        }
        let inDebris = time < debrisUntil && time - lastBoom > 0.12
        if inDebris, c.high > slowHigh * 1.8, c.high > 0.01 / s, time - lastDebris > 0.07 {
            out.append(FourDXDetectedEvent(kind: .debris, time: time, strength: min(1, 0.25 + c.high * 4), withFlash: false))
            lastDebris = time
        } else if !inDebris, ready, boomCandidate < 0, c.high > slowHigh * ratioHit, c.high > 0.02 / s, c.high > c.low * 0.6,
                  time - lastHit > 0.14, time - lastBoom > 0.25 {
            let strength = min(1, 0.4 + (c.high / max(slowHigh, 1e-4) - ratioHit) * 0.05)
            out.append(FourDXDetectedEvent(kind: .sharpHit, time: time, strength: strength, withFlash: false))
            lastHit = time
        }
        // Slow averages (~1.2 s) follow the soundtrack's own loudness.
        let k = min(1, Float(dt) / 1.2)
        slowLow += (c.low - slowLow) * k
        slowMid += (c.mid - slowMid) * k
        slowHigh += (c.high - slowHigh) * k
        slowLow = max(slowLow, 0.002); slowHigh = max(slowHigh, 0.001)
        rumble = min(1, max(0, (fastLow - 0.02) * 4 * s))
        return out
    }
}

import Foundation
import AVFoundation
import MediaToolbox
import os

/// Reads the film's decoded soundtrack in real time (an MTAudioProcessingTap
/// on the player item — the audio passes through untouched) and reduces it
/// to three-band energy chunks for the 4DX sound classifier. Audio never
/// leaves the device and nothing is recorded.
///
/// Works for direct-play files. HLS transcodes don't expose audio to taps, so
/// those streams fall back to picture-only 4DX.
final class AudioFeatureTap: @unchecked Sendable {
    private var lock = os_unfair_lock()
    private var pending: [FourDXAudioChunk] = []
    private var sampleRate: Double = 48_000
    private var channels = 2
    private var interleaved = false
    private var isFloat = true
    private var lp1: Float = 0, lp2: Float = 0
    private var acc = (low: Float(0), mid: Float(0), high: Float(0), n: 0)
    private(set) var active = false

    /// Chunks produced since the last call (oldest first).
    func drain() -> [FourDXAudioChunk] {
        os_unfair_lock_lock(&lock)
        let out = pending
        pending.removeAll(keepingCapacity: true)
        os_unfair_lock_unlock(&lock)
        return out
    }

    fileprivate func prepare(_ f: AudioStreamBasicDescription) {
        sampleRate = f.mSampleRate > 0 ? f.mSampleRate : 48_000
        channels = max(1, Int(f.mChannelsPerFrame))
        interleaved = f.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
        isFloat = f.mFormatFlags & kAudioFormatFlagIsFloat != 0 && f.mBitsPerChannel == 32
        lp1 = 0; lp2 = 0; acc = (0, 0, 0, 0)
        active = isFloat
    }

    fileprivate func process(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
        guard isFloat, frames > 0, !list.isEmpty else { return }
        let a1 = 1 - expf(-2 * .pi * 150 / Float(sampleRate))
        let a2 = 1 - expf(-2 * .pi * 3000 / Float(sampleRate))
        let chunk = 256
        for i in 0..<frames {
            var m: Float = 0
            if interleaved {
                guard let p = list[0].mData?.assumingMemoryBound(to: Float.self) else { return }
                for c in 0..<channels { m += p[i * channels + c] }
                m /= Float(channels)
            } else {
                var used = 0
                for b in list { if let p = b.mData?.assumingMemoryBound(to: Float.self), Int(b.mDataByteSize) / 4 > i { m += p[i]; used += 1 } }
                m /= Float(max(1, used))
            }
            lp1 += a1 * (m - lp1)
            lp2 += a2 * (m - lp2)
            let low = lp1, mid = lp2 - lp1, high = m - lp2
            acc.low += low * low; acc.mid += mid * mid; acc.high += high * high; acc.n += 1
            if acc.n >= chunk {
                let n = Float(acc.n)
                let c = FourDXAudioChunk(low: (acc.low / n).squareRoot(), mid: (acc.mid / n).squareRoot(),
                                         high: (acc.high / n).squareRoot(), duration: n / Float(sampleRate))
                acc = (0, 0, 0, 0)
                os_unfair_lock_lock(&lock)
                if pending.count < 600 { pending.append(c) }
                os_unfair_lock_unlock(&lock)
            }
        }
    }

    /// Builds an audio mix whose tap feeds this analyser. Returns nil when
    /// the tap can't be created.
    func makeMix(for track: AVAssetTrack) -> AVAudioMix? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(self).toOpaque()),
            init: { _, clientInfo, storageOut in storageOut.pointee = clientInfo },
            finalize: { tap in
                Unmanaged<AudioFeatureTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release()
            },
            prepare: { tap, _, format in
                Unmanaged<AudioFeatureTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue().prepare(format.pointee)
            },
            unprepare: nil,
            process: { tap, frames, _, bufferList, framesOut, flagsOut in
                guard MTAudioProcessingTapGetSourceAudio(tap, frames, bufferList, flagsOut, nil, framesOut) == noErr else { return }
                Unmanaged<AudioFeatureTap>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
                    .process(UnsafeMutableAudioBufferListPointer(bufferList), frames: Int(framesOut.pointee))
            })
        var tap: MTAudioProcessingTap?
        guard MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap) == noErr,
              let tap else {
            Unmanaged.passUnretained(self).release()   // balance passRetained when no tap took ownership
            return nil
        }
        let params = AVMutableAudioMixInputParameters(track: track)
        params.audioTapProcessor = tap
        let mix = AVMutableAudioMix()
        mix.inputParameters = [params]
        return mix
    }
}

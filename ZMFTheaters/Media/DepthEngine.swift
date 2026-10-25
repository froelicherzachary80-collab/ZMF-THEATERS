import Foundation
import CoreML
import Vision
import CoreVideo
import Accelerate

/// ZMF DepthCinema AI — monocular depth estimation for 2D → 3D conversion.
///
/// Runs Apple's Core ML build of **Depth Anything V2 (small, Float16)** on the
/// Neural Engine through Vision. Each result is normalised with temporally
/// smoothed min/max (so brightness of the depth map doesn't pump between
/// shots) and blended with the previous map (temporal stabilisation). The
/// renderer turns the stabilised map into left/right views and a red/cyan
/// anaglyph on the GPU.
///
/// The model is bundled at build time (see scripts/fetch-depth-model.sh). If it
/// is missing the engine reports itself unavailable and screenings stay in
/// genuine 2D — the app never fakes 3D with a colour filter.
final class DepthEngine: @unchecked Sendable {
    struct DepthMap {
        var values: [Float]
        var width: Int
        var height: Int
        var version: Int
    }

    static let modelName = "DepthAnythingV2SmallF16"

    private let queue = DispatchQueue(label: "zmf.depth", qos: .userInitiated)
    private let lock = NSLock()
    private var request: VNCoreMLRequest?
    private var busy = false
    private var lastSubmit = CFAbsoluteTimeGetCurrent() - 10
    private var smoothed: [Float] = []
    private var lo: Float = 0
    private var hi: Float = 1
    private var latestMap: DepthMap?
    private var counter = 0
    private(set) var loadError: String?
    private(set) var measuredHz: Double = 0
    private var lastResultTime = CFAbsoluteTimeGetCurrent()

    var isAvailable: Bool { request != nil }

    init() {
        guard let url = Bundle.main.url(forResource: Self.modelName, withExtension: "mlmodelc") else {
            loadError = "Depth model not bundled in this build"
            return
        }
        do {
            let config = MLModelConfiguration()
            config.computeUnits = .all
            let ml = try MLModel(contentsOf: url, configuration: config)
            let vn = try VNCoreMLModel(for: ml)
            let r = VNCoreMLRequest(model: vn)
            r.imageCropAndScaleOption = .scaleFill
            request = r
        } catch {
            loadError = "Depth model failed to load: \(error.localizedDescription)"
        }
    }

    /// The most recent stabilised depth map (near = 1, far = 0).
    var latest: DepthMap? {
        lock.lock(); defer { lock.unlock() }
        return latestMap
    }

    func reset() {
        lock.lock()
        latestMap = nil
        smoothed = []
        lock.unlock()
    }

    /// Offers a decoded video frame. Frames arriving while the model is busy or
    /// faster than `rate` are skipped; the last depth map keeps being used.
    func submit(_ pixelBuffer: CVPixelBuffer, rate: Double) {
        guard let request else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lock.lock()
        if busy || now - lastSubmit < 1 / max(1, rate) { lock.unlock(); return }
        busy = true
        lastSubmit = now
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            try? handler.perform([request])
            if let raw = Self.extract(request.results) { self.integrate(raw) }
            self.lock.lock(); self.busy = false; self.lock.unlock()
        }
    }

    // MARK: Model output → floats

    private static func extract(_ results: [VNObservation]?) -> (values: [Float], width: Int, height: Int)? {
        if let pb = (results?.first as? VNPixelBufferObservation)?.pixelBuffer {
            return floats(from: pb)
        }
        if let arr = (results?.first as? VNCoreMLFeatureValueObservation)?.featureValue.multiArrayValue {
            let shape = arr.shape.map { $0.intValue }
            guard shape.count >= 2 else { return nil }
            let h = shape[shape.count - 2], w = shape[shape.count - 1]
            var out = [Float](repeating: 0, count: w * h)
            for i in 0..<(w * h) { out[i] = arr[i].floatValue }
            return (out, w, h)
        }
        return nil
    }

    private static func floats(from pb: CVPixelBuffer) -> (values: [Float], width: Int, height: Int)? {
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        let rowBytes = CVPixelBufferGetBytesPerRow(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        var out = [Float](repeating: 0, count: w * h)
        switch CVPixelBufferGetPixelFormatType(pb) {
        case kCVPixelFormatType_OneComponent16Half:
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                var src = vImage_Buffer(data: UnsafeMutableRawPointer(row), height: 1, width: vImagePixelCount(w), rowBytes: w * 2)
                out.withUnsafeMutableBufferPointer { dst in
                    var d = vImage_Buffer(data: dst.baseAddress!.advanced(by: y * w), height: 1, width: vImagePixelCount(w), rowBytes: w * 4)
                    vImageConvert_Planar16FtoPlanarF(&src, &d, 0)
                }
            }
        case kCVPixelFormatType_OneComponent32Float, kCVPixelFormatType_DepthFloat32, kCVPixelFormatType_DisparityFloat32:
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: Float.self)
                for x in 0..<w { out[y * w + x] = row[x] }
            }
        case kCVPixelFormatType_OneComponent8:
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<w { out[y * w + x] = Float(row[x]) / 255 }
            }
        case kCVPixelFormatType_OneComponent16:
            for y in 0..<h {
                let row = base.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt16.self)
                for x in 0..<w { out[y * w + x] = Float(row[x]) / 65535 }
            }
        default:
            return nil
        }
        return (out, w, h)
    }

    // MARK: Normalisation + temporal stabilisation

    private func integrate(_ raw: (values: [Float], width: Int, height: Int)) {
        let v = raw.values
        var mn: Float = 0, mx: Float = 0
        vDSP_minv(v, 1, &mn, vDSP_Length(v.count))
        vDSP_maxv(v, 1, &mx, vDSP_Length(v.count))
        lock.lock()
        let first = smoothed.count != v.count
        // Slowly moving range so the 3D strength doesn't jump between shots.
        lo = first ? mn : lo + (mn - lo) * 0.2
        hi = first ? mx : hi + (mx - hi) * 0.2
        let inv = 1 / max(1e-5, hi - lo)
        let base = lo
        if first { smoothed = [Float](repeating: 0, count: v.count) }
        let keep: Float = first ? 0 : 0.55
        smoothed.withUnsafeMutableBufferPointer { out in
            v.withUnsafeBufferPointer { inp in
                for i in 0..<inp.count {
                    let n = min(1, max(0, (inp[i] - base) * inv))
                    out[i] = out[i] * keep + n * (1 - keep)
                }
            }
        }
        counter += 1
        latestMap = DepthMap(values: smoothed, width: raw.width, height: raw.height, version: counter)
        let now = CFAbsoluteTimeGetCurrent()
        measuredHz = measuredHz * 0.8 + (1 / max(0.001, now - lastResultTime)) * 0.2
        lastResultTime = now
        lock.unlock()
    }
}

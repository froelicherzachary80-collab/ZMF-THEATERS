import SwiftUI
import UIKit
import QuartzCore

/// CAMetalLayer-backed view driven by a CADisplayLink. Frame rate and render
/// resolution follow the graphics profile and drop automatically when the
/// device gets hot, so environment detail is sacrificed before the movie.
final class CinemaLayerView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    var renderer: Renderer?
    private var link: CADisplayLink?
    var quality: GraphicsQuality = .balanced { didSet { applyQuality() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        metalLayer.pixelFormat = .bgra8Unorm_srgb
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = true
        backgroundColor = .black
        NotificationCenter.default.addObserver(self, selector: #selector(thermalChanged), name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(_ renderer: Renderer) {
        self.renderer = renderer
        metalLayer.device = renderer.device
        if link == nil {
            let l = CADisplayLink(target: self, selector: #selector(step(_:)))
            l.add(to: .main, forMode: .common)
            link = l
        }
        applyQuality()
    }

    func detach() {
        link?.invalidate()
        link = nil
    }

    private var throttled: Bool {
        let s = ProcessInfo.processInfo.thermalState
        return s == .serious || s == .critical || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func applyQuality() {
        let q = throttled ? GraphicsQuality.battery : quality
        let fps: Float = q == .battery ? 30 : 60
        link?.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: fps, preferred: fps)
        setNeedsLayout()
    }

    @objc private func thermalChanged() {
        DispatchQueue.main.async { self.applyQuality() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let native = window?.screen.scale ?? 3
        let q = throttled ? GraphicsQuality.battery : quality
        let scale: CGFloat
        switch q {
        case .battery: scale = min(native, 1.5)
        case .balanced: scale = min(native, 2.2)
        case .cinematic: scale = native
        }
        contentScaleFactor = scale
        metalLayer.drawableSize = CGSize(width: bounds.width * scale, height: bounds.height * scale)
    }

    @objc private func step(_ link: CADisplayLink) {
        renderer?.draw(layer: metalLayer, timestamp: link.timestamp)
    }
}

struct MetalCinemaView: UIViewRepresentable {
    let renderer: Renderer
    let quality: GraphicsQuality

    func makeUIView(context: Context) -> CinemaLayerView {
        let v = CinemaLayerView(frame: .zero)
        v.attach(renderer)
        v.quality = quality
        return v
    }

    func updateUIView(_ v: CinemaLayerView, context: Context) {
        if v.quality != quality { v.quality = quality }
    }

    static func dismantleUIView(_ v: CinemaLayerView, coordinator: ()) {
        v.detach()
    }
}

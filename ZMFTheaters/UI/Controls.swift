import SwiftUI
import AVFoundation

/// Left-thumb analog stick. Reports a vector in -1…1 with +y meaning forward.
struct Joystick: View {
    var size: CGFloat
    var onChange: (SIMD2<Float>) -> Void
    @State private var knob: CGSize = .zero

    var body: some View {
        let radius = size / 2
        ZStack {
            Circle().fill(.white.opacity(0.08)).overlay(Circle().stroke(.white.opacity(0.35), lineWidth: 2))
            Circle().fill(.white.opacity(0.55)).frame(width: size * 0.42, height: size * 0.42).offset(knob)
        }
        .frame(width: size, height: size)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { v in
                    var t = v.translation
                    let len = sqrt(t.width * t.width + t.height * t.height)
                    if len > radius { t = CGSize(width: t.width / len * radius, height: t.height / len * radius) }
                    knob = t
                    onChange(SIMD2<Float>(Float(t.width / radius), Float(-t.height / radius)))
                }
                .onEnded { _ in
                    knob = .zero
                    onChange(.zero)
                }
        )
    }
}

/// Full-screen swipe-to-look surface placed underneath the buttons.
struct LookPad: View {
    var onDelta: (SIMD2<Float>) -> Void
    @State private var last: CGSize = .zero

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        let dx = v.translation.width - last.width
                        let dy = v.translation.height - last.height
                        last = v.translation
                        onDelta(SIMD2<Float>(Float(dx), Float(dy)))
                    }
                    .onEnded { _ in last = .zero }
            )
    }
}

struct HUDButton: View {
    let symbol: String
    var label: String? = nil
    var tint: Color = .white
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                if let label { Text(label).font(.system(size: 9, weight: .bold)) }
            }
            .foregroundStyle(tint)
            .frame(width: 46, height: 46)
            .background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.18)))
        }
    }
}

struct ActionButton: View {
    let title: String
    let symbol: String
    var color: Color = .orange
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: symbol).font(.system(size: 24, weight: .bold))
                Text(title).font(.system(size: 11, weight: .heavy))
            }
            .foregroundStyle(.white)
            .frame(width: 76, height: 76)
            .background(Circle().fill(color.opacity(0.85)))
            .overlay(Circle().stroke(.white.opacity(0.5), lineWidth: 2))
            .shadow(color: color.opacity(0.6), radius: 8)
        }
    }
}

/// Plays the same AVPlayer through an AVPlayerLayer for the optional
/// immersive fullscreen mode — playback position is never interrupted.
struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let v = LayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        v.backgroundColor = .black
        return v
    }

    func updateUIView(_ v: LayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
    }
}

func formatTime(_ s: Double) -> String {
    guard s.isFinite, s >= 0 else { return "--:--" }
    let t = Int(s)
    let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
}

import SwiftUI

/// Official YouTube trailer appears over the physical cinema screen area
/// instead of inside a floating modal panel. No video frames are copied.
struct YouTubePreshowOverlay: View {
    @ObservedObject var session: TheaterSession
    @EnvironmentObject var game: CinemaGame
    @EnvironmentObject var settingsStore: SettingsStore

    var body: some View {
        if let trailer = session.activeYouTubeTrailer {
            TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { _ in
                GeometryReader { geometry in
                    let size = geometry.size
                    let bounds = CinemaScreenProjection.projectedRect(
                        game: game, viewport: size,
                        verticalFOV: Float(settingsStore.settings.seatedFieldOfView))
                    let rect = bounds ?? CGRect(x: -1400, y: -1000, width: 40, height: 24)

                    ZStack(alignment: .bottom) {
                        Rectangle().fill(.black)
                            .frame(width: rect.width + 4, height: rect.height + 4)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)

                        YouTubePreshowPlayer(
                            trailer: trailer,
                            onStateChange: { playing, seconds in session.updateYouTubePlayback(playing: playing, seconds: seconds) },
                            onEnded: { session.completeYouTubeTrailer() },
                            onError: { session.completeYouTubeTrailer(error: $0) }
                        )
                        .id(trailer.id)
                        .frame(width: max(40, rect.width), height: max(24, rect.height))
                        .background(.black)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(bounds != nil)

                        HStack(spacing: 10) {
                            Image(systemName: "play.rectangle.fill")
                                .foregroundStyle(.red)
                            Text(trailer.title).lineLimit(1)
                            Text(trailer.presentation == .fourDX ? "4DX PREVIEW" : "TRAILER")
                                .font(.caption2.bold()).foregroundStyle(.cyan)
                            Spacer(minLength: 6)
                            Button("CENTER") { game.recenterCinemaScreen() }
                            Button("NEXT") { session.completeYouTubeTrailer() }
                            Button("SKIP PRESHOW") { session.skipPreshow() }
                        }
                        .font(.caption2.bold())
                        .foregroundStyle(.white)
                        .buttonStyle(.borderless)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 9)
                        .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 10))
                        .frame(maxWidth: min(size.width - 45, 870))
                        .padding(.bottom, 39)
                    }
                    .frame(width: size.width, height: size.height)
                }
            }
            .zIndex(8)
        }
    }
}

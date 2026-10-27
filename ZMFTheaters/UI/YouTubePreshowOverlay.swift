import SwiftUI

/// The official YouTube trailer stays on the real auditorium screen; the
/// controls are a lightweight stationary HUD outside the projected picture.
struct YouTubePreshowOverlay: View {
    @ObservedObject var session: TheaterSession
    var renderer: Renderer?
    var settings = AppSettings()

    var body: some View {
        if let trailer = session.activeYouTubeTrailer {
            ZStack {
                CinemaScreenLockedPlayer(seatedFovDegrees: settings.seatedFieldOfView,
                                         engine: renderer?.fourDX,
                                         fourDX: trailer.presentation.uses4DX,
                                         showEffects: settings.fourDXScreenEffects) {
                    YouTubePreshowPlayer(
                        trailer: trailer, stereo3D: trailer.presentation.uses3D,
                        onStateChange: { playing, seconds in session.updateYouTubePlayback(playing: playing, seconds: seconds) },
                        onEnded: { session.completeYouTubeTrailer() },
                        onError: { session.completeYouTubeTrailer(error: $0) }
                    )
                    .id(trailer.id)
                }
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.rectangle.fill").foregroundStyle(.red)
                        Text("ZMF THEATERS+ · OFFICIAL YOUTUBE PREVIEW")
                            .font(.caption2.weight(.black)).lineLimit(1)
                        Spacer()
                        Text(trailer.presentation.badge)
                            .font(.caption2.bold()).foregroundStyle(.cyan)
                    }
                    .padding(10)
                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 10))
                    Spacer()
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(trailer.title).font(.caption.bold()).lineLimit(1)
                            Text("Trailer stays on the auditorium screen · tap Play if needed.")
                                .font(.caption2).foregroundStyle(.white.opacity(0.75))
                        }
                        Spacer(minLength: 5)
                        Button("Next") { session.completeYouTubeTrailer() }
                            .buttonStyle(.bordered)
                        Button("Skip") { session.skipPreshow() }
                            .buttonStyle(.borderedProminent).tint(.orange)
                    }
                    .padding(10)
                    .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 10))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            .zIndex(8)
        }
    }
}

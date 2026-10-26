import SwiftUI

/// Native in-cinema preshow portal for a YouTube player. Embedded videos remain
/// in YouTube's own player; they cannot be silently fed into the Metal screen
/// renderer, extracted, downloaded, or converted into an anaglyph film.
struct YouTubePreshowOverlay: View {
    @ObservedObject var session: TheaterSession

    var body: some View {
        if let trailer = session.activeYouTubeTrailer {
            GeometryReader { geometry in
                let horizontal = geometry.size.width > geometry.size.height
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        Image(systemName: "play.rectangle.fill").foregroundStyle(.red)
                        Text("ZMF THEATERS+  •  OFFICIAL YOUTUBE PREVIEW")
                            .font(.caption2.weight(.black))
                            .lineLimit(1)
                        Spacer()
                        Text(trailer.presentation == .fourDX ? "4DX VIRTUAL MOTION" : "STANDARD")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(trailer.presentation == .fourDX ? .cyan : .white)
                    }
                    .padding(.horizontal, 8)

                    YouTubePreshowPlayer(
                        trailer: trailer,
                        onStateChange: { playing, seconds in session.updateYouTubePlayback(playing: playing, seconds: seconds) },
                        onEnded: { session.completeYouTubeTrailer() },
                        onError: { session.completeYouTubeTrailer(error: $0) }
                    )
                    .id(trailer.id)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .background(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(trailer.title).font(.caption.weight(.semibold)).lineLimit(1)
                            Text("Tap Play if the trailer does not start automatically.")
                                .font(.caption2).foregroundStyle(.white.opacity(0.7))
                        }
                        Spacer(minLength: 4)
                        Button("Next trailer") { session.completeYouTubeTrailer() }
                            .buttonStyle(.bordered).tint(.cyan)
                        Button("Skip preshow") { session.skipPreshow() }
                            .buttonStyle(.borderedProminent).tint(.orange)
                    }.padding(.horizontal, 8)
                }
                .padding(12)
                .frame(maxWidth: horizontal ? min(geometry.size.width * 0.78, 920) : geometry.size.width - 24)
                .background(.black.opacity(0.94), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.16), lineWidth: 1))
                .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
            .zIndex(8)
        }
    }
}

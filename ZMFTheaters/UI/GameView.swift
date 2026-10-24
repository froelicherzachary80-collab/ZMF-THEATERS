import SwiftUI

enum GameSheet: String, Identifiable {
    case boxOffice, concessions, wallet, map, admin, phone
    var id: String { rawValue }
}

struct GameView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var game: CinemaGame
    @EnvironmentObject var session: TheaterSession
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var wallet: Wallet
    @State private var sheet: GameSheet?
    @State private var fullscreen = false

    private var settings: AppSettings { settingsStore.settings }

    var body: some View {
        ZStack {
            if let renderer = model.renderer {
                MetalCinemaView(renderer: renderer, quality: settings.graphicsQuality).ignoresSafeArea()
            } else {
                Color.black.ignoresSafeArea()
                Text("Metal is unavailable on this device.").foregroundStyle(.red)
            }

            LookPad { game.lookDelta += $0 }.ignoresSafeArea()

            hudLayer

            if fullscreen {
                FullscreenOverlay(engine: session.feature, close: { fullscreen = false })
                    .transition(.opacity)
            }
        }
        .sheet(item: $sheet) { s in sheetContent(s) }
        .onAppear {
            // Gameplay prefers landscape; menus still work in portrait.
            if let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscape)) { _ in }
            }
        }
        .alert("Resume screening?", isPresented: resumeBinding, presenting: model.showResumePrompt) { p in
            Button("Resume at \(formatTime(p.position))") { model.startScreening(ticket: p.ticket, item: p.item, resumeAt: p.position) }
            Button("Start from the beginning") { model.startScreening(ticket: p.ticket, item: p.item, resumeAt: nil) }
        } message: { p in
            Text("You stopped “\(p.item.displayTitle)” at \(formatTime(p.position)).")
        }
    }

    private var resumeBinding: Binding<Bool> {
        Binding(get: { model.showResumePrompt != nil }, set: { if !$0 { model.showResumePrompt = nil } })
    }

    @ViewBuilder
    private func sheetContent(_ s: GameSheet) -> some View {
        switch s {
        case .boxOffice: BoxOfficeView(startTab: .nowShowing)
        case .phone: BoxOfficeView(startTab: .tickets)
        case .concessions: ConcessionView()
        case .wallet: WalletView()
        case .map: CinemaMapView()
        case .admin: AdminView()
        }
    }

    // MARK: HUD

    private var hudLayer: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            if game.hud.seated && session.isRunning {
                ScreeningControls(engine: session.feature, fullscreen: $fullscreen)
                    .padding(.bottom, 6)
            }
            bottomBar
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                chip(game.hud.zoneName, symbol: "mappin.and.ellipse")
                Button { sheet = .wallet } label: { chip("Z$\(wallet.balance)", symbol: "creditcard.fill", tint: .yellow) }
                if let t = model.guidedTicket {
                    Button { sheet = .phone } label: { chip("\(t.title) · Room \(String(format: "%02d", t.roomId)) · \(t.seatLabel)", symbol: "ticket.fill", tint: .orange) }
                }
            }
            Spacer()
            VStack(spacing: 6) {
                if let toast = model.toast {
                    Text(toast).font(.footnote.bold()).padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.black.opacity(0.7), in: Capsule()).foregroundStyle(.white)
                }
                if let angle = game.hud.guidanceAngle, let label = game.hud.guidanceLabel {
                    HStack(spacing: 6) {
                        Image(systemName: "location.north.fill")
                            .rotationEffect(.radians(Double(-angle)))
                            .foregroundStyle(.orange)
                        Text("\(label) · \(Int(game.hud.guidanceDistance)) m").font(.caption.bold())
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.55), in: Capsule())
                }
                if session.isRunning && !game.hud.seated {
                    Text(session.phaseLabel).font(.caption.bold()).padding(6).background(.black.opacity(0.55), in: Capsule())
                }
            }
            Spacer()
            HStack(spacing: 6) {
                HUDButton(symbol: "map.fill", label: "MAP") { sheet = .map }
                HUDButton(symbol: "ticket.fill", label: "TICKET") { sheet = .phone }
                HUDButton(symbol: "creditcard.fill", label: "WALLET") { sheet = .wallet }
                HUDButton(symbol: "iphone", label: "PHONE") { sheet = .boxOffice }
                HUDButton(symbol: game.cameraMode == .firstPerson ? "eye.fill" : "figure.stand", label: "CAMERA") {
                    game.cameraMode = game.cameraMode == .firstPerson ? .thirdPerson : .firstPerson
                }
                HUDButton(symbol: "gearshape.fill", label: "ADMIN") { sheet = .admin }
                HUDButton(symbol: "house.fill", label: "EXIT") {
                    model.leaveScreening()
                    model.mode = nil
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack(alignment: .bottom) {
            if settings.swapControls { actionCluster; Spacer(); joystickArea } else { joystickArea; Spacer(); actionCluster }
        }
    }

    @ViewBuilder
    private var joystickArea: some View {
        if !game.hud.seated {
            Joystick(size: CGFloat(settings.joystickSize)) { game.moveInput = $0 }
        } else {
            Color.clear.frame(width: 1, height: 1)
        }
    }

    private var actionCluster: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if let prompt = game.hud.prompt {
                Text(prompt).font(.caption.bold()).padding(8).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 200)
            }
            if game.hud.seated {
                VStack(spacing: 8) {
                    if wallet.snackCount(.popcorn) + wallet.snackCount(.soda) + wallet.snackCount(.candy) > 0 {
                        HUDButton(symbol: "popcorn.fill", label: "SNACK", tint: .yellow) { eatSnack() }
                    }
                    HUDButton(symbol: "chair.lounge.fill", label: game.reclined ? "UPRIGHT" : "RECLINE") { game.toggleRecline() }
                }
                ActionButton(title: "STAND", symbol: "figure.stand", color: .gray) { model.standUp() }
            } else if case .seat(let room, let row, let seat)? = game.hud.interactable {
                ActionButton(title: "SIT", symbol: "chair.fill", color: .green) { model.sitDown(room: room, row: row, seat: seat) }
            } else {
                ActionButton(title: "INTERACT", symbol: "hand.tap.fill", color: game.hud.interactable == nil ? .gray : .orange) { interact() }
            }
        }
    }

    private func chip(_ text: String, symbol: String, tint: Color = .white) -> some View {
        Label(text, systemImage: symbol)
            .font(.caption.bold())
            .lineLimit(1)
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
    }

    private func interact() {
        switch game.hud.interactable {
        case .boxOffice?, .kiosk?: sheet = .boxOffice
        case .concession?: sheet = .concessions
        case .door(let id)?:
            let room = CinemaRooms.room(id)
            if game.isUnlocked(id) {
                model.flash("Room \(room.code) \(room.name) — doors open. Find your seat!")
            } else {
                model.flash("Room \(room.code) needs a ticket — visit the Box Office.")
            }
        case .seat(let room, let row, let seat)?:
            model.sitDown(room: room, row: row, seat: seat)
        case nil:
            model.flash("Walk up to the Box Office, Concessions, a door or your seat.")
        }
    }

    private func eatSnack() {
        for s in Snack.allCases where wallet.consumeSnack(s) {
            model.flash(s == .soda ? "Sip… ahh." : "Crunch! Enjoying your \(s.label.lowercased()).")
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            return
        }
    }
}

/// Transport bar shown while seated during a screening.
struct ScreeningControls: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: TheaterSession
    @ObservedObject var engine: PlaybackEngine
    @Binding var fullscreen: Bool

    var body: some View {
        VStack(spacing: 6) {
            if let sub = engine.subtitleText, session.phase == .feature {
                Text(sub).font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
            }
            HStack(spacing: 12) {
                Text(session.phaseLabel).font(.caption.bold()).foregroundStyle(.orange)
                switch session.phase {
                case .welcome, .trailer, .ident, .countdown:
                    Button("Skip preshow") { session.skipPreshow() }.font(.caption.bold())
                case .failed:
                    Button("Retry") { session.retry() }.font(.caption.bold()).tint(.orange)
                default:
                    EmptyView()
                }
                if session.phase == .feature || session.phase == .credits {
                    FeatureTransport(engine: engine)
                    Button { fullscreen = true } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                }
                Button(role: .destructive) { model.leaveScreening() } label: { Image(systemName: "xmark.circle.fill") }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.black.opacity(0.6), in: Capsule())
        }
        .foregroundStyle(.white)
    }
}

struct FeatureTransport: View {
    @ObservedObject var engine: PlaybackEngine

    var body: some View {
        HStack(spacing: 10) {
            Button { engine.skip(-10) } label: { Image(systemName: "gobackward.10") }
            Button { engine.togglePlay() } label: { Image(systemName: engine.status == .paused ? "play.fill" : "pause.fill") }
            Button { engine.skip(30) } label: { Image(systemName: "goforward.30") }
            Text("\(formatTime(engine.currentTime)) / \(formatTime(engine.duration))").font(.caption.monospacedDigit())
            Slider(value: Binding(get: { engine.currentTime }, set: { engine.seek(to: $0) }), in: 0...max(1, engine.duration))
                .frame(width: 150)
            if engine.status == .buffering { ProgressView().controlSize(.small) }
            Menu {
                Section("Audio") {
                    ForEach(engine.audioTracks) { t in
                        Button { Task { await engine.selectAudio(t.id) } } label: {
                            Label(t.label, systemImage: engine.selectedAudio == t.id ? "checkmark" : "speaker.wave.2")
                        }
                    }
                }
                Section("Subtitles") {
                    Button { Task { await engine.selectSubtitle(nil) } } label: { Label("Off", systemImage: engine.selectedSubtitle == nil ? "checkmark" : "captions.bubble") }
                    ForEach(engine.subtitleTracks) { t in
                        Button { Task { await engine.selectSubtitle(t.id) } } label: {
                            Label(t.label, systemImage: engine.selectedSubtitle == t.id ? "checkmark" : "captions.bubble")
                        }
                    }
                }
                Section("Volume") {
                    Button("100%") { engine.volume = 1 }
                    Button("70%") { engine.volume = 0.7 }
                    Button("40%") { engine.volume = 0.4 }
                }
                Section { Text("Playback: \(engine.playMethod)") }
            } label: { Image(systemName: "ellipsis.circle") }
        }
    }
}

struct FullscreenOverlay: View {
    @ObservedObject var engine: PlaybackEngine
    let close: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            PlayerLayerView(player: engine.player).ignoresSafeArea()
            VStack {
                Spacer()
                if let sub = engine.subtitleText {
                    Text(sub).font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                        .padding(8).background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .padding(.bottom, 30)
                }
            }
            .frame(maxWidth: .infinity)
            Button(action: close) {
                Label("Back to theater", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(.caption.bold()).padding(10).background(.black.opacity(0.6), in: Capsule())
            }
            .padding()
        }
    }
}

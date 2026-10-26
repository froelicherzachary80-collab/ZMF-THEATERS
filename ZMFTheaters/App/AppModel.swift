import Foundation
import Combine
import UIKit
import AVFoundation

enum GameMode: String, Codable {
    case singleplayer
    case privateAI
}

/// Root object wiring the media engine, programming director, economy,
/// screening session, game world and renderer together.
@MainActor
final class AppModel: ObservableObject {
    let settingsStore = SettingsStore()
    let library = MediaLibrary()
    let wallet = Wallet()
    let rotation = RotationDirector()
    let session = TheaterSession()
    let youtubeCinema = YouTubeCinemaSession()
    let game = CinemaGame()
    let party = WatchParty()
    let renderer: Renderer?

    @Published var mode: GameMode?
    @Published var toast: String?
    @Published private(set) var guidedTicket: Ticket?
    @Published var showResumePrompt: (ticket: Ticket, item: MediaItem, position: Double)?

    private var cancellables = Set<AnyCancellable>()
    private var signageTask: Task<Void, Never>?

    var settings: AppSettings { settingsStore.settings }

    init() {
        renderer = Renderer()
        renderer?.game = game
        renderer?.session = session
        renderer?.youtubeCinema = youtubeCinema
        party.library = library
        party.session = session
        party.onNeedScreening = { [weak self] item, start in self?.startPartyScreening(item: item, startAt: start) }
        party.$members
            .sink { [weak self] names in self?.updatePartyGuests(names) }
            .store(in: &cancellables)
        wallet.$state
            .sink { [weak self] st in
                self?.renderer?.carrying = ((st.snacks[Snack.popcorn.rawValue] ?? 0) + (st.snacks[Snack.candy.rawValue] ?? 0) > 0,
                                            (st.snacks[Snack.soda.rawValue] ?? 0) > 0)
            }
            .store(in: &cancellables)
        session.onTicketUsed = { [weak self] t in
            self?.wallet.markUsed(t)
            self?.refreshUnlocks()
        }

        settingsStore.$settings
            .sink { [weak self] s in
                guard let self else { return }
                self.renderer?.settings = s
                self.game.lookSensitivity = Float(s.lookSensitivity)
                self.game.allDoorsUnlocked = s.allDoorsUnlocked
            }
            .store(in: &cancellables)

        // Forward nested ObservableObject changes so views observing AppModel refresh.
        for publisher in [library.objectWillChange.eraseToAnyPublisher(), wallet.objectWillChange.eraseToAnyPublisher(),
                          rotation.objectWillChange.eraseToAnyPublisher(), settingsStore.objectWillChange.eraseToAnyPublisher(),
                          party.objectWillChange.eraseToAnyPublisher(), youtubeCinema.objectWillChange.eraseToAnyPublisher()] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        }

        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback, options: [])
        try? AVAudioSession.sharedInstance().setActive(true)
        refreshUnlocks()
    }

    // MARK: Lifecycle

    func launch() async {
        for msg in wallet.applyRewards(settings: settings) { flash(msg) }
        await library.refreshStatuses()
        let stale = library.servers.contains { ($0.lastSync ?? .distantPast) < Date().addingTimeInterval(-6 * 3600) }
        if stale && library.servers.contains(where: { $0.isOnline }) { await library.syncAll() }
        refreshProgramme()
    }

    /// Re-evaluates the rotation and rebuilds every piece of signage that shows it.
    func refreshProgramme(force: Bool = false) {
        rotation.ensureCurrent(catalog: library.items, settings: settings, force: force)
        refreshSignage()
    }

    /// `-zmfShot lobby|hall|room|seat` jumps straight to a camera position. Used by
    /// CI to capture simulator screenshots of the real renderer.
    func applyLaunchArguments() {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-zmfShot"), i + 1 < args.count else { return }
        mode = .singleplayer
        switch args[i + 1] {
        case "lobby":
            game.debugPlace(Vec3(0, 0, 1.5), yaw: 0, pitch: 0.12)
        case "hall":
            game.debugPlace(Vec3(1.5, 0, 22), yaw: -0.15, pitch: 0.02)
        case "room":
            let t = CinemaWorld.transform(room: 5)
            game.debugPlace(t.point(Vec3(23, 0, 7)), yaw: CinemaWorld.screenYaw(5), pitch: -0.12)
        case "seat", "seatleft":
            let item = MediaItem(serverAccountId: UUID(), itemId: "demo", kind: .movie, title: "Preshow Demo", year: 2026)
            let ticket = Ticket(mediaId: item.id, title: item.title, roomId: 9, row: 5, seat: 3, showtime: nil, isPrivate: true, kind: .vip, price: 0,
                                format: args.contains("-zmfDemo3D") ? .anaglyph3D : nil)
            let seat = CinemaWorld.seatPosition(room: 9, row: 5, seat: 3)
            game.debugPlace(seat, yaw: CinemaWorld.screenYaw(9), pitch: 0)
            game.sit(room: 9, row: 5, seat: 3)
            session.begin(ticket: ticket, item: item, resumeAt: nil, library: library, settings: settings)
            if args[i + 1] == "seatleft" { game.lookDelta = Vec2(-240, 10) }
            if args.contains("-zmfDemoParty") {
                updatePartyGuests(["Alex", "Sam"])
                renderer?.carrying = (true, true)
            }
        case "seat3d":
            // Plays the first file in Documents/Trailers as a 3D-ticket feature.
            let files = (try? FileManager.default.contentsOfDirectory(at: JSONStore.trailersDirectory, includingPropertiesForKeys: nil)) ?? []
            guard let file = files.first(where: { $0.pathExtension.lowercased() == "mp4" }) else { break }
            let item = MediaItem(serverAccountId: UUID(), itemId: "local:" + file.path, kind: .movie, title: "3D Conversion Test", year: 2026)
            let ticket = Ticket(mediaId: item.id, title: item.title, roomId: 9, row: 3, seat: 3, showtime: nil, isPrivate: true,
                                kind: .threeD, price: 0, format: .anaglyph3D)
            settingsStore.settings.autoHideControls = false   // keep the 3D status visible for the CI screenshot
            game.debugPlace(CinemaWorld.seatPosition(room: 9, row: 3, seat: 3), yaw: CinemaWorld.screenYaw(9), pitch: 0)
            game.sit(room: 9, row: 3, seat: 3)
            session.begin(ticket: ticket, item: item, resumeAt: nil, library: library, settings: settings, skipPreshow: true)
        default:
            break
        }
    }

    func flash(_ message: String) {
        toast = message
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toast == message { toast = nil }
        }
    }

    // MARK: Programme

    func featured(_ roomId: Int) -> MediaItem? {
        guard let id = rotation.current?.mediaId(for: roomId) else { return nil }
        return library.item(id: id)
    }

    func nextShowtimes(_ roomId: Int, limit: Int = 6) -> [Showtime] {
        ShowtimeScheduler.upcoming(roomId: roomId, runtimeMinutes: featured(roomId)?.runtimeMinutes, settings: settings, limit: limit)
    }

    func refreshSignage() {
        guard let renderer else { return }
        signageTask?.cancel()
        let fmt = ShowtimeScheduler.timeFormatter(settings)
        renderer.setTexture("sign.menu", renderer.factory.menuBoard(settings))
        renderer.setTexture("sign.4dx", renderer.factory.fourDXTeaser(active: fourDXAvailable, line: FourDX.teaser(settings: settings)))
        for room in CinemaRooms.all {
            let film = featured(room.id)
            renderer.setTexture("door.\(room.id)", renderer.factory.doorSign(room: room, film: film?.title))
            renderer.setTexture("poster.\(room.id)", renderer.factory.poster(image: nil, title: film?.title ?? room.name, room: room))
            let next = nextShowtimes(room.id, limit: 1).first.map { "Next showing \(fmt.string(from: $0.featureStart))" }
            renderer.setTexture("screen.\(room.id)", renderer.factory.idleScreen(room: room, title: film?.title, backdrop: nil, next: next))
        }
        let lib = library
        signageTask = Task { [weak self] in
            for room in CinemaRooms.all {
                guard let self, !Task.isCancelled, let film = self.featured(room.id), let renderer = self.renderer else { continue }
                let poster = film.hasPrimaryImage ? await ImageLoader.shared.image(for: film, library: lib, maxWidth: 400) : nil
                if poster != nil {
                    renderer.setTexture("poster.\(room.id)", renderer.factory.poster(image: poster, title: film.title, room: room))
                }
                let backdrop = film.hasBackdrop ? await ImageLoader.shared.image(for: film, library: lib, type: "Backdrop", maxWidth: 1200) : nil
                let next = self.nextShowtimes(room.id, limit: 1).first.map { "Next showing \(fmt.string(from: $0.featureStart))" }
                renderer.setTexture("screen.\(room.id)", renderer.factory.idleScreen(room: room, title: film.title, backdrop: backdrop, next: next))
            }
        }
    }

    // MARK: Tickets

    /// Base price by format (2D Z$150 · 3D Z$225 · 4DX Z$400), plus the VIP
    /// upgrade (Z$350 − Z$150 = Z$200) for the recliner rows E–F.
    func price(room: CinemaRoom, row: Int, format: ScreeningFormat = .standard2D) -> (Int, TicketKind) {
        let vip = Seating.vipRows.contains(row)
        let base: Int
        switch format {
        case .standard2D: base = settings.standardPrice
        case .anaglyph3D: base = settings.threeDPrice
        case .fourDX, .fourDX3D: base = settings.fourDXPrice
        }
        let upgrade = vip ? max(0, settings.vipPrice - settings.standardPrice) : 0
        let kind: TicketKind = vip ? .vip : (format.usesDepth ? .threeD : .standard)
        return (base + upgrade, kind)
    }

    var fourDXAvailable: Bool { FourDX.isPreviewActive(settings: settings) }

    func takenSeats(room: Int, showtime: Date?) -> Set<Int> {
        Set(wallet.activeTickets.filter { $0.roomId == room && $0.showtime == showtime && !$0.isPrivate }.map { $0.row * 100 + $0.seat })
    }

    @discardableResult
    func purchase(item: MediaItem, room: CinemaRoom, row: Int, seat: Int, showtime: Showtime?, episodeQueue: [String] = [],
                  format: ScreeningFormat = .standard2D) -> Ticket? {
        let format = (format.uses4DX && !fourDXAvailable) ? .standard2D : format
        let (p, kind) = price(room: room, row: row, format: format)
        let t = Ticket(mediaId: item.id, title: item.displayTitle, roomId: room.id, row: row, seat: seat,
                       showtime: showtime?.featureStart, isPrivate: showtime == nil, kind: kind, price: p, episodeQueue: episodeQueue,
                       format: format)
        guard wallet.issue(t, settings: settings) else {
            flash("Not enough ZMF CASH for this ticket.")
            return nil
        }
        refreshUnlocks()
        guide(to: t)
        flash("\(format.label) ticket · Room \(room.code) · Seat \(t.seatLabel)\(format.usesDepth ? " · grab your red/cyan glasses" : "")")
        return t
    }

    func refund(_ t: Ticket) {
        wallet.refund(t)
        if guidedTicket?.id == t.id { guide(to: nil) }
        refreshUnlocks()
        flash("Refunded Z$\(t.price)")
    }

    func guide(to ticket: Ticket?) {
        guidedTicket = ticket
        game.seatTarget = ticket.map { (room: $0.roomId, row: $0.row, seat: $0.seat) }
    }

    func refreshUnlocks() {
        game.unlockedRooms = Set(wallet.activeTickets.map { $0.roomId })
    }

    // MARK: YouTube 4DX Browser

    func startYouTubeCinema(videoID: String, title: String) {
        // Explicit user action; keep independent Jellyfin features intact.
        if session.isRunning { session.end() }
        if mode == nil { mode = .singleplayer }
        let id = 9
        game.debugPlace(CinemaWorld.seatPosition(room: id, row: 4, seat: 3),
                        yaw: CinemaWorld.screenYaw(id), pitch: 0)
        game.sit(room: id, row: 4, seat: 3)
        youtubeCinema.open(videoID: videoID, title: title,
                           preset: settings.youtubeCinemaPreset,
                           bpm: settings.youtubeCinemaBPM,
                           cuts: settings.youtubeCueMarksByVideo[videoID] ?? [])
        flash("YouTube Cinema · Open video, tap Play to start virtual 4DX")
    }

    func stopYouTubeCinema() {
        youtubeCinema.close()
        game.seatMotion = (.zero, .zero)
    }

    // MARK: Screening

    /// Called when the player taps SIT at their ticketed seat.
    func sitDown(room: Int, row: Int, seat: Int) {
        game.sit(room: room, row: row, seat: seat)
        guard let ticket = wallet.activeTickets.first(where: { $0.roomId == room && $0.row == row && $0.seat == seat }) ?? guidedTicket,
              let item = library.item(id: ticket.mediaId) else { return }
        if session.isRunning, session.ticket?.id == ticket.id { return } // already screening; just sat back down
        let serverResume = item.resumeTicks.map { Double($0) / 10_000_000 } ?? 0
        let local = ResumeStore.shared.position(for: item.id) ?? 0
        let resume = max(serverResume, local)
        if resume > 60, (item.runtimeMinutes.map { resume < Double($0 * 60) * 0.95 } ?? true) {
            showResumePrompt = (ticket, item, resume)
        } else {
            startScreening(ticket: ticket, item: item, resumeAt: nil)
        }
    }

    func startScreening(ticket: Ticket, item: MediaItem, resumeAt: Double?) {
        showResumePrompt = nil
        session.begin(ticket: ticket, item: item, resumeAt: resumeAt, library: library, settings: settings, skipPreshow: resumeAt != nil)
    }

    // MARK: Watch party

    /// A friend's party is playing a title: take a free party seat in the right
    /// auditorium and let SyncPlay drive playback.
    func startPartyScreening(item: MediaItem, startAt: Double) {
        let room: CinemaRoom
        let row: Int
        let seat: Int
        if let s = game.seatedAt {
            room = CinemaRooms.room(s.room); row = s.row; seat = s.seat
        } else {
            room = CinemaRooms.bestRoom(for: item); row = 4; seat = 3
        }
        let ticket = Ticket(mediaId: item.id, title: item.displayTitle, roomId: room.id, row: row, seat: seat,
                            showtime: nil, isPrivate: true, kind: .standard, price: 0)
        _ = wallet.issue(ticket, settings: settings)
        refreshUnlocks()
        guide(to: ticket)
        if game.seatedAt == nil {
            game.debugPlace(CinemaWorld.seatPosition(room: room.id, row: row, seat: seat), yaw: CinemaWorld.screenYaw(room.id), pitch: 0)
            game.sit(room: room.id, row: row, seat: seat)
        }
        if mode == nil { mode = .singleplayer }
        flash("Watch party · Room \(room.code) · \(item.displayTitle)")
        session.beginParty(ticket: ticket, item: item, startAt: startAt, library: library, settings: settings) { [weak self] in
            self?.party.localReady()
        }
    }

    private func updatePartyGuests(_ names: [String]) {
        guard let renderer else { return }
        let others = names.filter { $0 != party.myName }
        renderer.partyGuests = others
        for (i, name) in others.prefix(7).enumerated() {
            renderer.setTexture("party.name.\(i)", renderer.factory.label(name, size: CGSize(width: 384, height: 96),
                font: .systemFont(ofSize: 54, weight: .heavy), fg: .white, bg: UIColor(red: 0.1, green: 0.1, blue: 0.16, alpha: 1), border: .orange))
        }
    }

    /// 3D conversion state shown in the screening controls.
    var stereoStatus: String? { renderer?.stereoStatus(for: session) }

    func standUp() {
        game.stand()
    }

    func leaveScreening() {
        session.end()
        if game.isSeated { game.stand() }
    }
}


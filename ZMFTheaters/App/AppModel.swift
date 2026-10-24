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
    let game = CinemaGame()
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
                          rotation.objectWillChange.eraseToAnyPublisher(), settingsStore.objectWillChange.eraseToAnyPublisher()] {
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
        case "seat":
            let item = MediaItem(serverAccountId: UUID(), itemId: "demo", kind: .movie, title: "Preshow Demo", year: 2026)
            let ticket = Ticket(mediaId: item.id, title: item.title, roomId: 9, row: 5, seat: 3, showtime: nil, isPrivate: true, kind: .vip, price: 0)
            let seat = CinemaWorld.seatPosition(room: 9, row: 5, seat: 3)
            game.debugPlace(seat, yaw: CinemaWorld.screenYaw(9), pitch: 0)
            game.sit(room: 9, row: 5, seat: 3)
            session.begin(ticket: ticket, item: item, resumeAt: nil, library: library, settings: settings)
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

    func price(room: CinemaRoom, row: Int) -> (Int, TicketKind) {
        if Seating.vipRows.contains(row) { return (settings.vipPrice, .vip) }
        if room.is3D { return (settings.threeDPrice, .threeD) }
        return (settings.standardPrice, .standard)
    }

    func takenSeats(room: Int, showtime: Date?) -> Set<Int> {
        Set(wallet.activeTickets.filter { $0.roomId == room && $0.showtime == showtime && !$0.isPrivate }.map { $0.row * 100 + $0.seat })
    }

    @discardableResult
    func purchase(item: MediaItem, room: CinemaRoom, row: Int, seat: Int, showtime: Showtime?, episodeQueue: [String] = []) -> Ticket? {
        let (p, kind) = price(room: room, row: row)
        let t = Ticket(mediaId: item.id, title: item.displayTitle, roomId: room.id, row: row, seat: seat,
                       showtime: showtime?.featureStart, isPrivate: showtime == nil, kind: kind, price: p, episodeQueue: episodeQueue)
        guard wallet.issue(t, settings: settings) else {
            flash("Not enough ZMF CASH for this ticket.")
            return nil
        }
        refreshUnlocks()
        guide(to: t)
        flash("Ticket purchased · Room \(room.code) · Seat \(t.seatLabel)")
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

    func standUp() {
        game.stand()
    }

    func leaveScreening() {
        session.end()
        if game.isSeated { game.stand() }
    }
}

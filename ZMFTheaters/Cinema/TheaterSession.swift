import Foundation
import Combine

/// Runs one screening: welcome card → owner-imported trailers → reminders →
/// ZMF ident → countdown → feature (auto-started from Jellyfin) → credits and
/// lights up → optional intermission and next episode.
///
/// The feature stream is negotiated in parallel with the preshow so it starts
/// the instant the countdown ends.
@MainActor
final class TheaterSession: ObservableObject {
    enum Phase: Equatable {
        case idle, welcome, trailer, ident, countdown, feature, credits, intermission, finished
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var ticket: Ticket?
    @Published private(set) var item: MediaItem?
    /// 1 = house lights fully up, ~0 = dark for the feature. The renderer eases toward this.
    @Published private(set) var targetLights: Float = 1
    @Published private(set) var slideLines: [String] = []
    @Published private(set) var slideVersion = 0
    @Published private(set) var countdown = 0

    let feature = PlaybackEngine()
    let trailers = PlaybackEngine()

    private var runTask: Task<Void, Never>?
    private var prepareTask: Task<Void, Error>?
    private weak var library: MediaLibrary?
    private var settings = AppSettings()
    var onTicketUsed: ((Ticket) -> Void)?

    init() {
        trailers.reportsToServer = false
    }

    var roomId: Int? { phase == .idle ? nil : ticket?.roomId }
    var isRunning: Bool { phase != .idle }

    /// The player whose frames belong on the screen right now.
    var screenEngine: PlaybackEngine? {
        switch phase {
        case .trailer: return trailers
        case .feature, .credits: return feature
        default: return nil
        }
    }

    var showsIdent: Bool { phase == .ident }

    var phaseLabel: String {
        switch phase {
        case .idle: return ""
        case .welcome: return "Preshow"
        case .trailer: return "Trailers"
        case .ident: return "ZMF Presentation"
        case .countdown: return "Feature in \(countdown)"
        case .feature: return "Now playing"
        case .credits: return "Credits"
        case .intermission: return "Intermission · \(countdown)s"
        case .finished: return "Screening complete"
        case .failed: return "Playback problem"
        }
    }

    private func setSlide(_ lines: [String]) {
        slideLines = lines
        slideVersion += 1
    }

    // MARK: Control

    func begin(ticket: Ticket, item: MediaItem, resumeAt: Double?, library: MediaLibrary, settings: AppSettings, skipPreshow: Bool = false) {
        end()
        self.ticket = ticket
        self.item = item
        self.library = library
        self.settings = settings
        startPreparing(item: item, resumeAt: resumeAt)
        runTask = Task { [weak self] in await self?.run(skipPreshow: skipPreshow) }
    }

    func skipPreshow() {
        guard [.welcome, .trailer, .ident, .countdown].contains(phase) else { return }
        runTask?.cancel()
        trailers.stop()
        runTask = Task { [weak self] in await self?.run(skipPreshow: true) }
    }

    /// Recovery after a network drop or expired session: re-negotiates and resumes.
    func retry() {
        guard let item else { return }
        let resume = max(feature.currentTime, ResumeStore.shared.position(for: item.id) ?? 0)
        runTask?.cancel()
        feature.stop()
        startPreparing(item: item, resumeAt: resume)
        runTask = Task { [weak self] in await self?.run(skipPreshow: true) }
    }

    func end() {
        runTask?.cancel(); runTask = nil
        prepareTask?.cancel(); prepareTask = nil
        if feature.status != .idle { feature.stop() }
        if trailers.status != .idle { trailers.stop() }
        phase = .idle
        targetLights = 1
        ticket = nil
        item = nil
    }

    private func startPreparing(item: MediaItem, resumeAt: Double?) {
        let maxBitrate = settings.maxBitrateMbps * 1_000_000
        let lib = library
        let engine = feature
        let subtitlePref = settings.preferredSubtitleLanguage.lowercased()
        prepareTask = Task {
            guard let lib, let server = lib.server(for: item), let userId = server.userId else {
                throw JellyfinError(message: "The server for this title is no longer connected.", statusCode: nil)
            }
            try await lib.withReauth(server) { client in
                try await engine.prepare(item: item, client: client, userId: userId, maxBitrate: maxBitrate, startAt: resumeAt)
            }
            if !subtitlePref.isEmpty, let track = engine.subtitleTracks.first(where: { $0.label.lowercased().contains(subtitlePref) }) {
                await engine.selectSubtitle(track.id)
            }
        }
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    private func trailerFiles() -> [URL] {
        let dir = JSONStore.trailersDirectory
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { ["mp4", "m4v", "mov"].contains($0.pathExtension.lowercased()) }
    }

    // MARK: Sequence

    private func run(skipPreshow: Bool) async {
        guard let ticket, let item else { return }
        let room = CinemaRooms.room(ticket.roomId)
        do {
            if settings.preshowEnabled && !skipPreshow {
                phase = .welcome
                targetLights = 0.75
                setSlide(["WELCOME TO ZMF THEATERS+", room.name.uppercased(), "Now presenting: \(item.displayTitle)", "Seat \(ticket.seatLabel) · Room \(room.code)"])
                try await sleep(Double(settings.welcomeSeconds))

                for url in trailerFiles().shuffled().prefix(max(0, settings.maxTrailers)) {
                    phase = .trailer
                    targetLights = 0.35
                    do {
                        try await trailers.prepareLocal(url: url)
                        trailers.play()
                        let deadline = Date().addingTimeInterval(360)
                        while Date() < deadline {
                            if trailers.status == .ended { break }
                            if case .failed = trailers.status { break }
                            try await sleep(0.25)
                        }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        // A broken trailer file must never block the feature.
                    }
                    trailers.stop()
                }

                phase = .welcome
                targetLights = 0.3
                setSlide(["A FRIENDLY REMINDER", "PLEASE SILENCE YOUR PHONE", "Sit back, relax, and enjoy the show"])
                try await sleep(5)

                phase = .ident
                targetLights = 0.12
                try await sleep(Double(settings.introSeconds))

                phase = .countdown
                targetLights = 0.06
                for n in stride(from: max(1, settings.countdownSeconds), through: 1, by: -1) {
                    countdown = n
                    setSlide(["FEATURE PRESENTATION", "\(n)", item.displayTitle])
                    try await sleep(1)
                }
            }

            phase = .countdown
            setSlide(["FEATURE PRESENTATION", "Connecting to your server…", item.displayTitle])
            try await prepareTask?.value

            phase = .feature
            targetLights = 0.03
            feature.play()
            while true {
                if feature.status == .ended { break }
                if case .failed(let msg) = feature.status { throw JellyfinError(message: msg, statusCode: nil) }
                try await sleep(0.5)
            }

            phase = .credits
            targetLights = 1
            onTicketUsed?(ticket)
            try await sleep(6)

            if settings.autoplayNextEpisode, let nextId = ticket.episodeQueue.first, let next = library?.item(id: nextId) {
                phase = .intermission
                targetLights = 0.8
                for n in stride(from: max(1, settings.intermissionSeconds), through: 1, by: -1) {
                    countdown = n
                    setSlide(["INTERMISSION", "Up next in \(n)", next.displayTitle])
                    try await sleep(1)
                }
                var t = ticket
                t.mediaId = next.id
                t.title = next.displayTitle
                t.episodeQueue = Array(ticket.episodeQueue.dropFirst())
                self.ticket = t
                self.item = next
                feature.stop()
                startPreparing(item: next, resumeAt: nil)
                runTask = Task { [weak self] in await self?.run(skipPreshow: true) }
                return
            }

            phase = .finished
            setSlide(["THANK YOU FOR VISITING", "ZMF THEATERS+", "House lights up · Please exit safely"])
        } catch is CancellationError {
            return
        } catch {
            if Task.isCancelled { return }
            phase = .failed(error.localizedDescription)
            targetLights = 0.8
            setSlide(["PLAYBACK PROBLEM", "Tap Retry to reconnect", error.localizedDescription])
        }
    }
}

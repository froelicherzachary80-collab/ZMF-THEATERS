import Foundation
import AVFoundation
import CoreVideo
import Combine
import UIKit

struct SubtitleCue: Equatable {
    var start: Double
    var end: Double
    var text: String
}

enum SubtitleParser {
    /// Parses WebVTT (Jellyfin converts every text subtitle format to VTT on request).
    static func parseVTT(_ raw: String) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2,
                  let s = time(parts[0]),
                  let e = time(parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? "") else { continue }
            let text = lines[(ti + 1)...].joined(separator: "\n")
                .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            if !text.isEmpty { cues.append(SubtitleCue(start: s, end: e, text: text)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    static func time(_ raw: String) -> Double? {
        let t = raw.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let comps = t.split(separator: ":").map(String.init)
        guard !comps.isEmpty, comps.count <= 3 else { return nil }
        var total = 0.0
        for c in comps {
            guard let v = Double(c) else { return nil }
            total = total * 60 + v
        }
        return total
    }
}

struct TrackOption: Identifiable, Hashable {
    var id: Int
    var label: String
}

/// Local resume positions for interrupted screenings (in addition to Jellyfin's own).
@MainActor
final class ResumeStore {
    static let shared = ResumeStore()
    private var records: [String: WatchRecord]
    private let store = JSONStore.shared

    init() { records = store.load([String: WatchRecord].self, "resume") ?? [:] }

    func position(for mediaId: String) -> Double? {
        guard let r = records[mediaId], r.durationSeconds > 0 else { return nil }
        let frac = r.positionSeconds / r.durationSeconds
        return (r.positionSeconds > 60 && frac < 0.95) ? r.positionSeconds : nil
    }

    func save(mediaId: String, position: Double, duration: Double) {
        records[mediaId] = WatchRecord(mediaId: mediaId, positionSeconds: position, durationSeconds: duration, updatedAt: Date())
        store.save(records, "resume")
    }

    func clear(_ mediaId: String) {
        records[mediaId] = nil
        store.save(records, "resume")
    }

    var history: [WatchRecord] { records.values.sorted { $0.updatedAt > $1.updatedAt } }
}

/// AVFoundation playback for one stream. Frames are pulled from an
/// AVPlayerItemVideoOutput by the renderer and mapped into Metal textures, so
/// the real movie is drawn onto the virtual cinema screen.
@MainActor
final class PlaybackEngine: ObservableObject {
    enum Status: Equatable {
        case idle, loading, ready, playing, paused, buffering, ended
        case failed(String)
    }

    struct Context {
        var client: JellyfinClient
        var item: MediaItem
        var userId: String
        var mediaSourceId: String
        var playSessionId: String?
        var playMethod: String
        var audioIndex: Int?
    }

    let player = AVPlayer()
    @Published private(set) var status: Status = .idle
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var playMethod = ""
    @Published private(set) var audioTracks: [TrackOption] = []
    @Published private(set) var subtitleTracks: [TrackOption] = []
    @Published private(set) var selectedAudio: Int?
    @Published private(set) var selectedSubtitle: Int?
    @Published private(set) var subtitleText: String?
    @Published var volume: Float = 1 { didSet { player.volume = volume } }

    private(set) var videoOutput: AVPlayerItemVideoOutput?
    private(set) var context: Context?
    private var cues: [SubtitleCue] = []
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var failObserver: NSObjectProtocol?
    private var lastReport = Date.distantPast
    private var started = false
    var reportsToServer = true

    init() {
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t.seconds) }
        }
    }

    var isActive: Bool {
        switch status {
        case .playing, .paused, .buffering, .ready: return true
        default: return false
        }
    }

    // MARK: Loading

    /// Negotiates playback with the item's own server (direct play when the
    /// container/codecs are native to iOS, otherwise HLS remux/transcode).
    func prepare(item: MediaItem, client: JellyfinClient, userId: String, maxBitrate: Int, startAt: Double?, audioIndex: Int? = nil) async throws {
        status = .loading
        let info = try await client.playbackInfo(itemId: item.itemId, userId: userId, maxBitrate: maxBitrate, audioStreamIndex: audioIndex)
        guard let source = info.mediaSources?.first, let sourceId = source.id else {
            throw JellyfinError(message: "The server returned no playable media source for “\(item.title)”.", statusCode: nil)
        }
        let url: URL
        let method: String
        if source.supportsDirectPlay == true, audioIndex == nil {
            url = client.directStreamURL(itemId: item.itemId, mediaSourceId: sourceId, playSessionId: info.playSessionId, tag: source.eTag)
            method = "DirectPlay"
        } else if let t = source.transcodingUrl, let u = client.transcodeURL(relative: t) {
            url = u
            method = (source.supportsDirectStream == true) ? "DirectStream" : "Transcode"
        } else if source.supportsDirectPlay == true {
            url = client.directStreamURL(itemId: item.itemId, mediaSourceId: sourceId, playSessionId: info.playSessionId, tag: source.eTag)
            method = "DirectPlay"
        } else {
            throw JellyfinError(message: "This file can't be played natively and the server offered no transcode. Enable transcoding for this Jellyfin user.", statusCode: nil)
        }

        let streams = source.mediaStreams ?? []
        audioTracks = streams.filter { ($0.type ?? "").lowercased() == "audio" }.compactMap { s in
            s.index.map { TrackOption(id: $0, label: s.displayTitle ?? s.language ?? "Audio \($0)") }
        }
        subtitleTracks = streams.filter { ($0.type ?? "").lowercased() == "subtitle" && ($0.isTextSubtitleStream ?? true) }.compactMap { s in
            s.index.map { TrackOption(id: $0, label: s.displayTitle ?? s.language ?? "Subtitle \($0)") }
        }
        selectedAudio = audioIndex ?? source.defaultAudioStreamIndex

        context = Context(client: client, item: item, userId: userId, mediaSourceId: sourceId, playSessionId: info.playSessionId, playMethod: method, audioIndex: audioIndex)
        playMethod = method
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Authorization": client.authorizationHeader]])
        try await load(asset: asset, startAt: startAt)
        started = false
    }

    /// Plays a local file (owner-imported trailers and preshow reels). Never reported to Jellyfin.
    func prepareLocal(url: URL) async throws {
        context = nil
        status = .loading
        audioTracks = []; subtitleTracks = []; cues = []; subtitleText = nil
        playMethod = "Local"
        try await load(asset: AVURLAsset(url: url), startAt: nil)
    }

    private func load(asset: AVURLAsset, startAt: Double?) async throws {
        let item = AVPlayerItem(asset: asset)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        item.add(output)
        item.preferredForwardBufferDuration = 20
        videoOutput = output
        observe(item)
        player.replaceCurrentItem(with: item)

        let deadline = Date().addingTimeInterval(45)
        while item.status == .unknown {
            if Date() > deadline { throw JellyfinError(message: "Timed out waiting for the stream to start.", statusCode: nil) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        if item.status == .failed {
            let msg = item.error?.localizedDescription ?? "Unknown AVFoundation error"
            status = .failed(msg)
            throw JellyfinError(message: "Playback failed: \(msg)", statusCode: nil)
        }
        duration = item.duration.seconds.isFinite ? item.duration.seconds : 0
        if let startAt, startAt > 1 {
            await player.seek(to: CMTime(seconds: startAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        status = .ready
    }

    private func observe(_ item: AVPlayerItem) {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        if let failObserver { NotificationCenter.default.removeObserver(failObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnd() }
        }
        failObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let err = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error)?.localizedDescription ?? "Stream interrupted"
            MainActor.assumeIsolated { self?.status = .failed(err) }
        }
    }

    // MARK: Transport

    func play() {
        player.play()
        status = .playing
        UIApplication.shared.isIdleTimerDisabled = true
        if !started, reportsToServer, let ctx = context {
            started = true
            let body = reportBody(ctx, paused: false)
            Task { await ctx.client.reportPlaybackStart(body) }
        }
    }

    func pause() {
        player.pause()
        status = .paused
        report(force: true)
    }

    func togglePlay() { status == .playing || status == .buffering ? pause() : play() }

    func seek(to seconds: Double) {
        let clamped = max(0, min(seconds, duration > 0 ? duration - 1 : seconds))
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600))
        currentTime = clamped
    }

    func skip(_ delta: Double) { seek(to: currentTime + delta) }

    func stop() {
        report(force: true)
        if reportsToServer, started, let ctx = context {
            var body = reportBody(ctx, paused: true)
            body["Failed"] = false
            Task { await ctx.client.reportPlaybackStopped(body) }
        }
        if let ctx = context, duration > 0 {
            ResumeStore.shared.save(mediaId: ctx.item.id, position: currentTime, duration: duration)
        }
        player.pause()
        player.replaceCurrentItem(with: nil)
        videoOutput = nil
        context = nil
        started = false
        cues = []
        subtitleText = nil
        status = .idle
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func handleEnd() {
        if let ctx = context { ResumeStore.shared.clear(ctx.item.id) }
        if reportsToServer, started, let ctx = context {
            var body = reportBody(ctx, paused: false)
            body["PositionTicks"] = Int64(duration * 10_000_000)
            Task { await ctx.client.reportPlaybackStopped(body) }
            started = false
        }
        status = .ended
        UIApplication.shared.isIdleTimerDisabled = false
    }

    // MARK: Tracks

    func selectAudio(_ index: Int) async {
        guard let ctx = context, index != selectedAudio else { return }
        let resume = currentTime
        let wasPlaying = status == .playing
        player.pause()
        do {
            try await prepare(item: ctx.item, client: ctx.client, userId: ctx.userId, maxBitrate: 60_000_000, startAt: resume, audioIndex: index)
            if wasPlaying { play() }
        } catch {
            status = .failed(error.localizedDescription)
        }
    }

    func selectSubtitle(_ index: Int?) async {
        selectedSubtitle = index
        cues = []
        subtitleText = nil
        guard let index, let ctx = context else { return }
        let url = ctx.client.subtitleURL(itemId: ctx.item.itemId, mediaSourceId: ctx.mediaSourceId, streamIndex: index)
        var req = URLRequest(url: url)
        req.setValue(ctx.client.authorizationHeader, forHTTPHeaderField: "Authorization")
        if let result = try? await ctx.client.session.data(for: req), let text = String(data: result.0, encoding: .utf8) {
            cues = SubtitleParser.parseVTT(text)
        }
    }

    // MARK: Frame access (called by the renderer every frame)

    func copyLatestPixelBuffer() -> CVPixelBuffer? {
        guard let out = videoOutput else { return nil }
        let t = out.itemTime(forHostTime: CACurrentMediaTime())
        guard out.hasNewPixelBuffer(forItemTime: t) else { return nil }
        return out.copyPixelBuffer(forItemTime: t, itemTimeForDisplay: nil)
    }

    // MARK: Ticking & reporting

    private func tick(_ t: Double) {
        guard t.isFinite else { return }
        currentTime = t
        if let item = player.currentItem, item.duration.seconds.isFinite { duration = item.duration.seconds }
        if status == .playing || status == .buffering {
            status = player.timeControlStatus == .waitingToPlayAtSpecifiedRate ? .buffering : .playing
        }
        if !cues.isEmpty {
            subtitleText = cues.first(where: { $0.start <= t && t <= $0.end })?.text
        }
        report(force: false)
    }

    private func report(force: Bool) {
        guard reportsToServer, started, let ctx = context else { return }
        guard force || Date().timeIntervalSince(lastReport) > 10 else { return }
        lastReport = Date()
        let body = reportBody(ctx, paused: status == .paused)
        Task { await ctx.client.reportPlaybackProgress(body) }
        if duration > 0 { ResumeStore.shared.save(mediaId: ctx.item.id, position: currentTime, duration: duration) }
    }

    private func reportBody(_ ctx: Context, paused: Bool) -> [String: Any] {
        var body: [String: Any] = [
            "ItemId": ctx.item.itemId,
            "MediaSourceId": ctx.mediaSourceId,
            "PositionTicks": Int64(max(0, currentTime) * 10_000_000),
            "IsPaused": paused,
            "CanSeek": true,
            "PlayMethod": ctx.playMethod,
            "VolumeLevel": Int(volume * 100),
        ]
        if let p = ctx.playSessionId { body["PlaySessionId"] = p }
        if let a = ctx.audioIndex { body["AudioStreamIndex"] = a }
        if let s = selectedSubtitle { body["SubtitleStreamIndex"] = s }
        return body
    }
}

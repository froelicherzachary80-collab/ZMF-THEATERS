import Foundation
import Combine
import AVFoundation

struct PartyGroup: Identifiable, Hashable {
    var id: String
    var name: String
    var state: String
    var participants: [String]
    var serverId: UUID
}

/// Online watch parties built on Jellyfin **SyncPlay**. The owner's Jellyfin
/// server is the shared "public server": everyone in a group streams the film
/// from it, and the server tells every client exactly when to play, pause and
/// seek. Friends can join from ZMF THEATERS+ on iPhone, the ZMF THEATERS+
/// Windows app, or any official Jellyfin client that supports SyncPlay.
@MainActor
final class WatchParty: ObservableObject {
    @Published private(set) var groups: [PartyGroup] = []
    @Published private(set) var group: PartyGroup?
    @Published private(set) var members: [String] = []
    @Published private(set) var status = "Not in a watch party"
    @Published private(set) var events: [String] = []
    @Published private(set) var busy = false

    var isInParty: Bool { group != nil }

    weak var library: MediaLibrary?
    weak var session: TheaterSession?
    /// Called when the group's play queue names a title this device isn't showing yet.
    var onNeedScreening: ((MediaItem, Double) -> Void)?

    private var server: ServerAccount?
    private var client: JellyfinClient?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var keepAliveTask: Task<Void, Never>?
    private var driftTask: Task<Void, Never>?
    private var scheduledTask: Task<Void, Never>?
    private var serverOffset: Double = 0          // server clock − local clock, seconds
    private var playlistItemId: String?
    private var anchor: (serverTime: Date, seconds: Double)?  // last Unpause, for drift correction
    private var waitingToHostItem: MediaItem?
    private var isHost = false

    var myName: String? { server?.username }

    // MARK: Discovery

    func refreshGroups() async {
        guard let library else { return }
        var found: [PartyGroup] = []
        for s in library.servers where s.isOnline {
            guard let c = library.client(for: s) else { continue }
            if let raw = try? await rawJSON(c, c.makeRequest("/SyncPlay/List")) as? [[String: Any]] {
                for g in raw {
                    guard let id = g["GroupId"] as? String else { continue }
                    found.append(PartyGroup(id: id, name: g["GroupName"] as? String ?? "Watch party",
                                            state: g["State"] as? String ?? "", participants: g["Participants"] as? [String] ?? [], serverId: s.id))
                }
            }
        }
        groups = found
    }

    // MARK: Hosting & joining

    /// Starts a party for the film currently on this device's screen.
    func host(item: MediaItem) async {
        guard let library, let s = library.server(for: item) else { return }
        busy = true
        defer { busy = false }
        do {
            try await connect(s)
            let name = "ZMF · \(item.displayTitle)"
            waitingToHostItem = item
            isHost = true
            try await post("/SyncPlay/New", ["GroupName": name])
            status = "Starting party…"
        } catch {
            status = "Couldn't start a party: \(error.localizedDescription)"
        }
    }

    func join(_ g: PartyGroup) async {
        guard let library, let s = library.servers.first(where: { $0.id == g.serverId }) else { return }
        busy = true
        defer { busy = false }
        do {
            try await connect(s)
            try await post("/SyncPlay/Join", ["GroupId": g.id])
            status = "Joining \(g.name)…"
        } catch {
            status = "Couldn't join: \(error.localizedDescription)"
        }
    }

    func leave() async {
        if group != nil { try? await post("/SyncPlay/Leave", nil) }
        teardown(message: "Left the watch party")
    }

    // MARK: User transport (routed through the server so everyone stays together)

    func userTogglePlay() {
        guard let engine = session?.feature else { return }
        let path = (engine.status == .playing || engine.status == .buffering) ? "/SyncPlay/Pause" : "/SyncPlay/Unpause"
        Task { try? await post(path, nil) }
    }

    func userSeek(to seconds: Double) {
        Task { try? await post("/SyncPlay/Seek", ["PositionTicks": ticks(seconds)]) }
    }

    // MARK: Connection

    private func connect(_ s: ServerAccount) async throws {
        if server?.id == s.id, socket != nil { return }
        teardown(message: nil)
        guard let library, let c = library.client(for: s), let token = c.token, let base = s.baseURL else {
            throw JellyfinError(message: "Server is not signed in.", statusCode: nil)
        }
        server = s
        client = c
        // Register this session as a video player so SyncPlay can command it.
        try? await c.send(c.makeRequest("/Sessions/Capabilities/Full", method: "POST", json: [
            "PlayableMediaTypes": ["Video"], "SupportedCommands": [], "SupportsMediaControl": true, "SupportsPersistentIdentifier": true,
        ]))
        await syncClock()

        var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.path = (comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path) + "/socket"
        comps.queryItems = [URLQueryItem(name: "api_key", value: token), URLQueryItem(name: "deviceId", value: c.deviceId)]
        guard let wsURL = comps.url else { throw JellyfinError(message: "Bad socket URL", statusCode: nil) }
        let task = c.session.webSocketTask(with: wsURL)
        socket = task
        task.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop(task) }
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                try? await task.send(.string("{\"MessageType\":\"KeepAlive\"}"))
                await self?.syncClock()
            }
        }
        status = "Connected to \(s.displayName)"
    }

    private func teardown(message: String?) {
        receiveTask?.cancel(); keepAliveTask?.cancel(); driftTask?.cancel(); scheduledTask?.cancel()
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        group = nil
        members = []
        anchor = nil
        playlistItemId = nil
        waitingToHostItem = nil
        isHost = false
        session?.feature.player.rate = session?.feature.status == .playing ? 1 : 0
        if let message { status = message }
    }

    /// NTP-style estimate of the server clock using Jellyfin's /GetUtcTime.
    private func syncClock() async {
        guard let c = client else { return }
        var best: (rtt: Double, offset: Double)?
        for _ in 0..<3 {
            let sent = Date()
            guard let obj = try? await rawJSON(c, c.makeRequest("/GetUtcTime")) as? [String: Any],
                  let recvS = obj["RequestReceptionTime"] as? String, let sendS = obj["ResponseTransmissionTime"] as? String,
                  let recv = JellyfinCoding.parseDate(recvS), let srvSend = JellyfinCoding.parseDate(sendS) else { continue }
            let got = Date()
            let rtt = got.timeIntervalSince(sent) - srvSend.timeIntervalSince(recv)
            let offset = (recv.timeIntervalSince(sent) + srvSend.timeIntervalSince(got)) / 2
            if best == nil || rtt < best!.rtt { best = (rtt, offset) }
        }
        if let best { serverOffset = best.offset }
    }

    private var serverNow: Date { Date().addingTimeInterval(serverOffset) }

    // MARK: Messages

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while !Task.isCancelled {
            do {
                let msg = try await task.receive()
                var data: Data?
                switch msg {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let data, let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    handle(obj)
                }
            } catch {
                if !Task.isCancelled && group != nil {
                    status = "Connection lost — tap Rejoin"
                    events.insert("Connection to the server dropped", at: 0)
                }
                return
            }
        }
    }

    private func handle(_ msg: [String: Any]) {
        let type = msg["MessageType"] as? String ?? ""
        switch type {
        case "ForceKeepAlive":
            Task { try? await socket?.send(.string("{\"MessageType\":\"KeepAlive\"}")) }
        case "SyncPlayGroupUpdate":
            if let d = msg["Data"] as? [String: Any] { handleGroupUpdate(d) }
        case "SyncPlayCommand":
            if let d = msg["Data"] as? [String: Any] { handleCommand(d) }
        default:
            break
        }
    }

    private func handleGroupUpdate(_ d: [String: Any]) {
        let kind = d["Type"] as? String ?? ""
        let payload = d["Data"]
        switch kind {
        case "GroupJoined":
            if let g = payload as? [String: Any], let id = g["GroupId"] as? String {
                group = PartyGroup(id: id, name: g["GroupName"] as? String ?? "Watch party", state: g["State"] as? String ?? "",
                                   participants: g["Participants"] as? [String] ?? [], serverId: server?.id ?? UUID())
                members = g["Participants"] as? [String] ?? []
                status = "In “\(group!.name)”"
                events.insert("You joined \(group!.name)", at: 0)
                if let item = waitingToHostItem {
                    waitingToHostItem = nil
                    let start = session?.feature.currentTime ?? 0
                    Task { try? await post("/SyncPlay/SetNewQueue", ["PlayingQueue": [item.itemId], "PlayingItemPosition": 0, "StartPositionTicks": ticks(start)]) }
                }
            }
        case "UserJoined":
            if let name = payload as? String {
                if !members.contains(name) { members.append(name) }
                events.insert("\(name) joined the party", at: 0)
            }
        case "UserLeft":
            if let name = payload as? String {
                members.removeAll { $0 == name }
                events.insert("\(name) left the party", at: 0)
            }
        case "GroupLeft", "NotInGroup", "GroupDoesNotExist":
            teardown(message: kind == "GroupDoesNotExist" ? "That party no longer exists" : "Not in a watch party")
        case "LibraryAccessDenied":
            status = "Your Jellyfin account can't access this title"
        case "StateUpdate":
            if let s = payload as? [String: Any], let st = s["State"] as? String {
                group?.state = st
                if st == "Waiting" { status = "Waiting for everyone to buffer…" } else if let g = group { status = "In “\(g.name)” · \(st)" }
            }
        case "PlayQueue":
            if let q = payload as? [String: Any] { handlePlayQueue(q) }
        default:
            break
        }
    }

    private func handlePlayQueue(_ q: [String: Any]) {
        guard let list = q["Playlist"] as? [[String: Any]], !list.isEmpty else { return }
        let index = min(max(0, q["PlayingItemIndex"] as? Int ?? 0), list.count - 1)
        guard let itemId = list[index]["ItemId"] as? String else { return }
        playlistItemId = list[index]["PlaylistItemId"] as? String
        let startSeconds = Double((q["StartPositionTicks"] as? NSNumber)?.int64Value ?? 0) / 10_000_000

        if let session, session.item?.itemId == itemId, session.feature.isActive {
            // Already showing this film: line up at the agreed position and report ready.
            session.feature.pause()
            session.feature.seek(to: startSeconds)
            let host = isHost
            Task {
                await self.sendReady(position: startSeconds)
                if host {
                    // The host keeps the film rolling once everyone has buffered.
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    try? await self.post("/SyncPlay/Unpause", nil)
                }
            }
            return
        }
        guard let library, let s = server, let c = client, let uid = s.userId else { return }
        Task {
            do {
                let dto = try await c.item(userId: uid, itemId: itemId)
                let item = dto.toMediaItem(server: s.id, libraryId: nil)
                library.remember([item])
                onNeedScreening?(item, startSeconds)
            } catch {
                status = "Couldn't load the party's film: \(error.localizedDescription)"
            }
        }
    }

    /// Called by the screening once the feature is buffered and paused at the queue position.
    func localReady() {
        guard isInParty, let engine = session?.feature else { return }
        Task { await sendReady(position: engine.currentTime) }
    }

    private func sendReady(position: Double) async {
        var body: [String: Any] = ["When": iso(serverNow), "PositionTicks": ticks(position), "IsPlaying": false]
        if let p = playlistItemId { body["PlaylistItemId"] = p }
        try? await post("/SyncPlay/Ready", body)
    }

    private func handleCommand(_ d: [String: Any]) {
        guard let engine = session?.feature else { return }
        let command = d["Command"] as? String ?? ""
        let when = (d["When"] as? String).flatMap(JellyfinCoding.parseDate) ?? serverNow
        let position = Double((d["PositionTicks"] as? NSNumber)?.int64Value ?? Int64(engine.currentTime * 10_000_000)) / 10_000_000
        scheduledTask?.cancel()
        switch command {
        case "Unpause":
            let delay = when.timeIntervalSince(serverNow)
            anchor = (when, position)
            if delay > 0 {
                engine.seek(to: position)
                scheduledTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    guard !Task.isCancelled else { return }
                    self?.session?.feature.play()
                }
            } else {
                engine.seek(to: position - delay)
                engine.play()
            }
            startDriftCorrection()
        case "Pause":
            anchor = nil
            driftTask?.cancel()
            engine.player.rate = 0
            engine.pause()
            engine.seek(to: position)
        case "Seek":
            anchor = nil
            engine.pause()
            engine.seek(to: position)
            Task {
                try? await Task.sleep(nanoseconds: 800_000_000)
                await self.sendReady(position: position)
            }
        case "Stop":
            anchor = nil
            driftTask?.cancel()
            engine.pause()
        default:
            break
        }
    }

    /// Keeps this device within a fraction of a second of the group: small
    /// drift is absorbed by nudging the playback rate, large drift by seeking.
    private func startDriftCorrection() {
        driftTask?.cancel()
        driftTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let self else { return }
                guard let anchor = self.anchor, let engine = self.session?.feature, engine.status == .playing else { continue }
                let expected = anchor.seconds + self.serverNow.timeIntervalSince(anchor.serverTime)
                let drift = engine.currentTime - expected
                if abs(drift) > 1.5 {
                    engine.seek(to: expected)
                    engine.player.rate = 1
                } else if abs(drift) > 0.15 {
                    engine.player.rate = drift > 0 ? 0.95 : 1.05
                } else if engine.player.rate != 1 {
                    engine.player.rate = 1
                }
            }
        }
    }

    // MARK: HTTP helpers

    private func post(_ path: String, _ body: [String: Any]?) async throws {
        guard let c = client else { throw JellyfinError(message: "Not connected", statusCode: nil) }
        try await c.send(c.makeRequest(path, method: "POST", json: body ?? [:]))
    }

    private func rawJSON(_ c: JellyfinClient, _ req: URLRequest) async throws -> Any {
        let (data, resp) = try await c.session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http((resp as? HTTPURLResponse)?.statusCode ?? 0, String(data: data, encoding: .utf8) ?? "")
        }
        return try JSONSerialization.jsonObject(with: data)
    }

    private func ticks(_ seconds: Double) -> Int64 { Int64(max(0, seconds) * 10_000_000) }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

import Foundation
import Combine

/// Connects the iPhone to the Windows ZMF THEATERS+ "Home 4DX" host (the PC
/// is the 4DX brain that drives the fan and lights). While a film plays on
/// the phone, its playback position is reported once a second so the PC can
/// replay that title's analysed effect timeline in sync. Only the Jellyfin
/// item id, title, position and play state are sent — never video or audio.
@MainActor
final class Home4DXLink: ObservableObject {
    @Published private(set) var status = "Not connected"
    @Published private(set) var connected = false
    @Published private(set) var hostNote = ""
    @Published private(set) var equipmentStatus = "Equipment status has not been refreshed."
    @Published private(set) var physicalArmed = false
    @Published private(set) var stopped = false
    private var token: String?
    private var base: URL?
    private var loop: Task<Void, Never>?
    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        return URLSession(configuration: c)
    }()

    static let codeKey = "home4dx.accessCode"

    /// e.g. "192.168.1.20:8977" or "http://my-pc.tailnet.ts.net:8977".
    static func normalise(_ raw: String) -> URL? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.contains("://") { s = "http://" + s }
        guard var c = URLComponents(string: s), c.host != nil else { return nil }
        if c.port == nil { c.port = 8977 }
        c.path = ""
        return c.url
    }

    func connect(host: String, code: String) async {
        guard let url = Self.normalise(host) else { status = "Enter your PC's address"; return }
        base = url
        var req = URLRequest(url: url.appendingPathComponent("api/login"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["code": code, "name": "iPhone", "clientTimeMs": Int64(Date().timeIntervalSince1970 * 1000)])
        do {
            let (data, resp) = try await session.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let t = json["token"] as? String else {
                status = "PC rejected the access code"; connected = false; return
            }
            token = t
            connected = true
            status = "Connected to \(url.host ?? "PC")"
            await refreshEquipment()
        } catch {
            connected = false
            status = "Can't reach the PC: \(error.localizedDescription)"
        }
    }

    func disconnect() {
        loop?.cancel(); loop = nil
        token = nil; connected = false; status = "Not connected"
    }

    /// Starts reporting phone playback. `current` returns nil when nothing plays.
    func startReporting(_ current: @escaping @MainActor () -> (mediaId: String, title: String, position: Double, playing: Bool)?) {
        loop?.cancel()
        loop = Task { [weak self] in
            var lastPlaying = false
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard let self, self.connected, let now = current() else { continue }
                if !now.playing && !lastPlaying { continue }   // idle: report pause once
                lastPlaying = now.playing
                await self.post("api/playback/report", [
                    "mediaId": now.mediaId, "title": now.title, "position": now.position, "playing": now.playing,
                    "clientTimeMs": Int64(Date().timeIntervalSince1970 * 1000),
                ])
            }
        }
    }

    func emergencyStop() async {
        await post("api/estop", [:])
        await refreshEquipment()
    }

    /// Read-only device dashboard; the PC remains the sole power controller.
    func refreshEquipment() async {
        guard let base, let token else { equipmentStatus = "Connect to the Windows 4DX host first."; return }
        var req = URLRequest(url: base.appendingPathComponent("api/status"))
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        do {
            let (data, response) = try await session.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                equipmentStatus = "Could not read equipment from Windows host."; return
            }
            physicalArmed = body["physicalEnabled"] as? Bool ?? false
            stopped = body["emergencyStopped"] as? Bool ?? false
            let devices = body["devices"] as? [[String: Any]] ?? []
            equipmentStatus = devices.map { item in
                let id = item["id"] as? String ?? "DEVICE"
                let state = item["state"] as? String ?? "unknown"
                let power = item["reportedOn"] as? Bool
                let powerLabel = power == nil ? "unverified" : (power! ? "ON" : "OFF")
                return "\(id): \(powerLabel) — \(state)"
            }.joined(separator: "\n")
        } catch {
            equipmentStatus = "PC unreachable: \(error.localizedDescription)"
        }
    }

    private func post(_ path: String, _ body: [String: Any]) async {
        guard let base, let token else { return }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        do {
            let (data, resp) = try await session.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 401 { connected = false; status = "Session expired — reconnect"; return }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { hostNote = json["note"] as? String ?? "" }
        } catch {
            status = "PC unreachable: \(error.localizedDescription)"
        }
    }
}

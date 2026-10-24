import Foundation
import Combine

/// Unified catalog across every connected Jellyfin server. Owns server
/// accounts, their per-server clients and the merged, persisted catalog.
@MainActor
final class MediaLibrary: ObservableObject {
    @Published private(set) var servers: [ServerAccount]
    @Published private(set) var items: [MediaItem]
    @Published private(set) var syncing: Set<UUID> = []
    @Published var lastError: String?
    /// dedupeKey -> preferred MediaItem.id chosen by the owner.
    @Published var preferredSources: [String: String]

    private let store: JSONStore
    private var clients: [UUID: JellyfinClient] = [:]
    private let session: URLSession

    init(store: JSONStore = .shared, session: URLSession = .shared) {
        self.store = store
        self.session = session
        self.servers = store.load([ServerAccount].self, "servers") ?? []
        self.items = store.load([MediaItem].self, "catalog") ?? []
        self.preferredSources = store.load([String: String].self, "preferredSources") ?? [:]
    }

    // MARK: - Derived catalog views

    var movies: [MediaItem] { uniqueVisible(items.filter { $0.kind == .movie }) }
    var series: [MediaItem] { uniqueVisible(items.filter { $0.kind == .series }) }

    func item(id: String) -> MediaItem? { items.first { $0.id == id } }

    func server(for item: MediaItem) -> ServerAccount? { servers.first { $0.id == item.serverAccountId } }

    func isAvailable(_ item: MediaItem) -> Bool { server(for: item)?.isOnline ?? false }

    /// All copies of the same title across servers.
    func sources(for item: MediaItem) -> [MediaItem] {
        let key = item.dedupeKey
        return items.filter { $0.kind == item.kind && $0.dedupeKey == key }
    }

    func setPreferredSource(_ item: MediaItem) {
        preferredSources[item.dedupeKey] = item.id
        store.save(preferredSources, "preferredSources")
    }

    /// Collapses duplicates to one entry each, honouring the owner's preferred
    /// source, otherwise preferring an online server and higher resolution.
    private func uniqueVisible(_ list: [MediaItem]) -> [MediaItem] {
        var groups: [String: [MediaItem]] = [:]
        var order: [String] = []
        for i in list {
            let k = i.dedupeKey
            if groups[k] == nil { order.append(k) }
            groups[k, default: []].append(i)
        }
        func rank(_ r: String?) -> Int { ["4K": 4, "1080p": 3, "720p": 2, "SD": 1][r ?? ""] ?? 0 }
        return order.compactMap { k in
            let g = groups[k]!
            if let pref = preferredSources[k], let p = g.first(where: { $0.id == pref }) { return p }
            return g.max { a, b in
                let ao = isAvailable(a) ? 1 : 0, bo = isAvailable(b) ? 1 : 0
                if ao != bo { return ao < bo }
                return rank(a.videoResolution) < rank(b.videoResolution)
            }
        }
    }

    // MARK: - Clients

    func client(for server: ServerAccount) -> JellyfinClient? {
        if let c = clients[server.id] { return c }
        guard let base = server.baseURL else { return nil }
        let c = JellyfinClient(baseURL: base, token: Keychain.get(Keychain.tokenKey(server.id)), deviceId: Keychain.deviceId, session: session)
        clients[server.id] = c
        return c
    }

    func client(for item: MediaItem) -> JellyfinClient? {
        guard let s = server(for: item) else { return nil }
        return client(for: s)
    }

    private func update(_ server: ServerAccount) {
        if let i = servers.firstIndex(where: { $0.id == server.id }) { servers[i] = server } else { servers.append(server) }
        store.save(servers, "servers")
    }

    // MARK: - Server manager

    /// Tests reachability, authenticates and stores secrets in the Keychain.
    func addOrUpdateServer(existing: ServerAccount?, name: String, url rawURL: String, username: String, password: String?) async throws -> ServerAccount {
        let normalized = ServerAccount.normalize(rawURL)
        guard let base = URL(string: normalized), base.host != nil else {
            throw JellyfinError(message: "That server address is not a valid URL.", statusCode: nil)
        }
        var account = existing ?? ServerAccount(displayName: name, url: normalized, username: username)
        account.displayName = name.isEmpty ? (account.serverName ?? "Jellyfin") : name
        account.url = normalized
        account.username = username

        let pw = (password?.isEmpty == false) ? password! : (Keychain.get(Keychain.passwordKey(account.id)) ?? "")
        let probe = JellyfinClient(baseURL: base, token: nil, deviceId: Keychain.deviceId, session: session)
        let info = try await probe.publicInfo()
        let auth = try await probe.authenticate(username: username, password: pw)

        account.serverName = info.serverName
        account.serverVersion = info.version
        account.serverId = auth.serverId ?? info.id
        account.userId = auth.user.id
        account.isOnline = true
        account.lastStatus = "Connected as \(auth.user.name ?? username)"

        Keychain.set(auth.accessToken, for: Keychain.tokenKey(account.id))
        Keychain.set(pw, for: Keychain.passwordKey(account.id))
        clients[account.id] = probe

        if let libs = try? await probe.libraries(userId: auth.user.id) {
            account.knownLibraries = libs.map { LibraryInfo(id: $0.id, name: $0.name ?? "Library", collectionType: $0.collectionType) }
        }
        update(account)
        return account
    }

    func removeServer(_ server: ServerAccount) {
        servers.removeAll { $0.id == server.id }
        items.removeAll { $0.serverAccountId == server.id }
        clients[server.id] = nil
        Keychain.delete(Keychain.tokenKey(server.id))
        Keychain.delete(Keychain.passwordKey(server.id))
        store.save(servers, "servers")
        store.save(items, "catalog")
    }

    func setSelectedLibraries(_ server: ServerAccount, ids: [String]) {
        var s = server
        s.selectedLibraryIds = ids
        update(s)
    }

    func testConnection(_ server: ServerAccount) async -> String {
        guard let c = client(for: server) else { return "Invalid server URL." }
        var s = server
        do {
            let info = try await c.publicInfo()
            if let uid = s.userId { _ = try await withReauth(s) { try await $0.libraries(userId: uid) } }
            s.isOnline = true
            s.lastStatus = "Online · \(info.serverName ?? "Jellyfin") \(info.version ?? "")"
        } catch {
            s.isOnline = false
            s.lastStatus = error.localizedDescription
        }
        update(s)
        return s.lastStatus ?? ""
    }

    /// Runs a request; on HTTP 401 re-authenticates with the Keychain password once and retries.
    func withReauth<T>(_ server: ServerAccount, _ op: (JellyfinClient) async throws -> T) async throws -> T {
        guard let c = client(for: server) else { throw JellyfinError(message: "Invalid server URL.", statusCode: nil) }
        do {
            return try await op(c)
        } catch let e as JellyfinError where e.statusCode == 401 {
            guard let pw = Keychain.get(Keychain.passwordKey(server.id)) else { throw e }
            let auth = try await c.authenticate(username: server.username, password: pw)
            Keychain.set(auth.accessToken, for: Keychain.tokenKey(server.id))
            return try await op(c)
        }
    }

    // MARK: - Sync

    func syncAll() async {
        for s in servers { await sync(s) }
    }

    func sync(_ server: ServerAccount) async {
        guard let userId = server.userId else { return }
        syncing.insert(server.id)
        defer { syncing.remove(server.id) }
        var s = server
        do {
            let libs = try await withReauth(server) { try await $0.libraries(userId: userId) }
            s.knownLibraries = libs.map { LibraryInfo(id: $0.id, name: $0.name ?? "Library", collectionType: $0.collectionType) }
            let videoLibs = libs.filter { lib in
                let t = (lib.collectionType ?? "").lowercased()
                return t.isEmpty || t == "movies" || t == "tvshows" || t == "homevideos" || t == "mixed" || t == "boxsets"
            }
            let wanted = s.selectedLibraryIds.isEmpty ? videoLibs : videoLibs.filter { s.selectedLibraryIds.contains($0.id) }

            var fresh: [MediaItem] = []
            for lib in wanted {
                var start = 0
                let page = 300
                while true {
                    let result = try await withReauth(server) {
                        try await $0.items(userId: userId, parentId: lib.id, types: "Movie,Series", startIndex: start, limit: page)
                    }
                    fresh += result.items.map { $0.toMediaItem(server: server.id, libraryId: lib.id) }
                    start += result.items.count
                    if result.items.count < page || start >= (result.totalRecordCount ?? 0) { break }
                }
            }
            // An item can live in several libraries (e.g. box sets); keep one copy.
            var seen = Set<String>()
            fresh = fresh.filter { seen.insert($0.id).inserted }

            items.removeAll { $0.serverAccountId == server.id }
            items.append(contentsOf: fresh)
            store.save(items, "catalog")
            s.isOnline = true
            s.lastSync = Date()
            s.lastStatus = "Synced \(fresh.filter { $0.kind == .movie }.count) movies, \(fresh.filter { $0.kind == .series }.count) shows"
        } catch {
            s.isOnline = false
            s.lastStatus = "Sync failed: \(error.localizedDescription)"
            lastError = s.lastStatus
        }
        update(s)
    }

    /// Lightweight reachability probe used at launch so the schedule can label
    /// offline titles without needing a full re-sync.
    func refreshStatuses() async {
        for s in servers {
            var copy = s
            if let c = client(for: s), (try? await c.publicInfo()) != nil {
                copy.isOnline = true
            } else {
                copy.isOnline = false
                copy.lastStatus = "Offline — showing last synced catalog"
            }
            update(copy)
        }
    }

    // MARK: - TV

    func seasons(of series: MediaItem) async throws -> [JFItem] {
        guard let s = server(for: series), let uid = s.userId else { throw JellyfinError(message: "Server missing.", statusCode: nil) }
        return try await withReauth(s) { try await $0.seasons(seriesId: series.itemId, userId: uid) }
    }

    func episodes(of series: MediaItem, seasonId: String) async throws -> [MediaItem] {
        guard let s = server(for: series), let uid = s.userId else { throw JellyfinError(message: "Server missing.", statusCode: nil) }
        let eps = try await withReauth(s) { try await $0.episodes(seriesId: series.itemId, seasonId: seasonId, userId: uid) }
        return eps.map { $0.toMediaItem(server: s.id, libraryId: series.libraryId) }
    }

    /// Episodes are fetched on demand rather than stored in the catalog; keep
    /// any we have resolved so tickets can refer to them later.
    func remember(_ episodes: [MediaItem]) {
        var changed = false
        for e in episodes where !items.contains(where: { $0.id == e.id }) {
            items.append(e); changed = true
        }
        if changed { store.save(items, "catalog") }
    }
}

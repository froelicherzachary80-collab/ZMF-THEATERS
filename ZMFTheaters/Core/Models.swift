import Foundation

/// A personal Jellyfin account the owner has connected. Secrets (password,
/// access token) never live here — they are stored in the Keychain keyed by `id`.
struct ServerAccount: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var displayName: String
    var url: String
    var username: String
    var userId: String?
    var serverId: String?
    var serverName: String?
    var serverVersion: String?
    /// Library (view) ids to include. Empty means "all video libraries".
    var selectedLibraryIds: [String] = []
    var knownLibraries: [LibraryInfo] = []
    var lastSync: Date?
    var lastStatus: String?
    var isOnline: Bool = false

    var baseURL: URL? { URL(string: url) }
    var isHTTPS: Bool { url.lowercased().hasPrefix("https://") }

    static func normalize(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "https://" + s
        }
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }
}

struct LibraryInfo: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var collectionType: String?
}

enum MediaKind: String, Codable, Hashable {
    case movie, series, episode
}

/// One playable (or browsable) item from one specific server. Items always keep
/// their origin server so a token is only ever sent to the server that issued it.
struct MediaItem: Codable, Identifiable, Hashable {
    var serverAccountId: UUID
    var itemId: String
    var kind: MediaKind
    var title: String
    var year: Int?
    var runtimeTicks: Int64?
    var genres: [String] = []
    var tags: [String] = []
    var studios: [String] = []
    var overview: String?
    var officialRating: String?
    var communityRating: Double?
    var hasPrimaryImage: Bool = false
    var hasBackdrop: Bool = false
    var videoResolution: String?
    var audioLanguages: [String] = []
    var subtitleLanguages: [String] = []
    var providerIds: [String: String] = [:]
    var resumeTicks: Int64?
    var played: Bool = false
    var seriesId: String?
    var seriesName: String?
    var seasonId: String?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var libraryId: String?
    var dateAdded: Date?

    var id: String { MediaItem.makeId(serverAccountId, itemId) }
    static func makeId(_ server: UUID, _ item: String) -> String { server.uuidString + ":" + item }

    var runtimeMinutes: Int? {
        guard let t = runtimeTicks, t > 0 else { return nil }
        return Int((Double(t) / 600_000_000).rounded())
    }

    var displayTitle: String {
        if kind == .episode, let s = parentIndexNumber, let e = indexNumber {
            return "\(seriesName ?? title) S\(s)E\(e) · \(title)"
        }
        return title
    }

    /// Key used to detect the same film on several servers.
    var dedupeKey: String {
        let lowered = Dictionary(uniqueKeysWithValues: providerIds.map { ($0.key.lowercased(), $0.value) })
        if let tmdb = lowered["tmdb"], !tmdb.isEmpty { return "tmdb:\(tmdb)" }
        if let imdb = lowered["imdb"], !imdb.isEmpty { return "imdb:\(imdb)" }
        return "t:\(title.lowercased())|\(year ?? 0)"
    }

    /// Lowercased haystack of genres, tags, studios and title used for room classification.
    var classificationTerms: [String] {
        (genres + tags + studios + [title]).map { $0.lowercased() }
    }
}

enum TicketKind: String, Codable {
    case standard, threeD, vip

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .threeD: return "3D"
        case .vip: return "VIP"
        }
    }
}

enum TicketStatus: String, Codable {
    case active, used, refunded
}

struct Ticket: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var mediaId: String
    var title: String
    var roomId: Int
    var row: Int          // 0 = row A (front)
    var seat: Int         // 0-based seat index within the row
    var showtime: Date?   // nil = private screening "now"
    var isPrivate: Bool
    var kind: TicketKind
    var price: Int
    var purchasedAt: Date = Date()
    var status: TicketStatus = .active
    /// Optional queue of follow-up episodes for continuous TV playback.
    var episodeQueue: [String] = []

    var seatLabel: String { "\(Seating.rowLetter(row))\(seat + 1)" }
}

enum Seating {
    static let rows = 8
    static let seatsPerRow = 8
    static let vipRows: Set<Int> = [4, 5]   // rows E and F — the sweet spot
    static func rowLetter(_ r: Int) -> String { String(UnicodeScalar(UInt8(65 + r))) }
}

struct WalletTransaction: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var date: Date = Date()
    var amount: Int
    var memo: String
}

struct WatchRecord: Codable, Hashable {
    var mediaId: String
    var positionSeconds: Double
    var durationSeconds: Double
    var updatedAt: Date
}

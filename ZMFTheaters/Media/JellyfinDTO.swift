import Foundation

// Data transfer objects for the subset of the documented Jellyfin REST API that
// ZMF THEATERS+ uses. Jellyfin serialises keys in PascalCase; `JellyfinCoding`
// converts them to camelCase so these structs stay idiomatic Swift.

enum JellyfinCoding {
    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init(stringValue: String) { self.stringValue = stringValue }
        init(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }

    static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .custom { path in
            let raw = path.last!.stringValue
            guard let first = raw.first else { return AnyKey(stringValue: raw) }
            return AnyKey(stringValue: first.lowercased() + raw.dropFirst())
        }
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            return JellyfinCoding.parseDate(s) ?? Date.distantPast
        }
        return d
    }

    static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        // Jellyfin emits 7 fractional digits, which ISO8601DateFormatter rejects; trim them.
        if let dot = s.firstIndex(of: ".") {
            var tail = s[s.index(after: dot)...]
            var zone = ""
            if let z = tail.firstIndex(where: { $0 == "Z" || $0 == "+" || $0 == "-" }) {
                zone = String(tail[z...]); tail = tail[..<z]
            }
            let trimmed = String(s[..<dot]) + "." + String(tail.prefix(3)) + (zone.isEmpty ? "Z" : zone)
            if let d = f.date(from: trimmed) { return d }
        }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

struct JFPublicSystemInfo: Decodable {
    var serverName: String?
    var version: String?
    var id: String?
    var productName: String?
}

struct JFUser: Decodable {
    var id: String
    var name: String?
    var serverId: String?
}

struct JFAuthResult: Decodable {
    var accessToken: String
    var serverId: String?
    var user: JFUser
}

struct JFUserData: Decodable {
    var playbackPositionTicks: Int64?
    var played: Bool?
}

struct JFMediaStream: Decodable {
    var type: String?
    var codec: String?
    var language: String?
    var displayTitle: String?
    var index: Int?
    var height: Int?
    var width: Int?
    var isExternal: Bool?
    var isTextSubtitleStream: Bool?
    var isDefault: Bool?
    var deliveryUrl: String?
    var deliveryMethod: String?
    var channels: Int?
}

struct JFItem: Decodable {
    var id: String
    var name: String?
    var type: String?
    var productionYear: Int?
    var runTimeTicks: Int64?
    var genres: [String]?
    var tags: [String]?
    var studios: [JFNameId]?
    var overview: String?
    var officialRating: String?
    var communityRating: Double?
    var imageTags: [String: String]?
    var backdropImageTags: [String]?
    var mediaStreams: [JFMediaStream]?
    var providerIds: [String: String]?
    var userData: JFUserData?
    var seriesId: String?
    var seriesName: String?
    var seasonId: String?
    var indexNumber: Int?
    var parentIndexNumber: Int?
    var collectionType: String?
    var dateCreated: Date?
    var parentId: String?
}

struct JFNameId: Decodable {
    var name: String?
    var id: String?
}

struct JFItemsResult: Decodable {
    var items: [JFItem]
    var totalRecordCount: Int?
}

struct JFMediaSource: Decodable {
    var id: String?
    var container: String?
    var supportsDirectPlay: Bool?
    var supportsDirectStream: Bool?
    var supportsTranscoding: Bool?
    var transcodingUrl: String?
    var transcodingSubProtocol: String?
    var mediaStreams: [JFMediaStream]?
    var bitrate: Int?
    var runTimeTicks: Int64?
    var defaultAudioStreamIndex: Int?
    var defaultSubtitleStreamIndex: Int?
    var eTag: String?
}

struct JFPlaybackInfo: Decodable {
    var mediaSources: [JFMediaSource]?
    var playSessionId: String?
    var errorCode: String?
}

extension JFItem {
    func toMediaItem(server: UUID, libraryId: String?) -> MediaItem {
        let kind: MediaKind
        switch (type ?? "").lowercased() {
        case "series": kind = .series
        case "episode": kind = .episode
        default: kind = .movie
        }
        let streams = mediaStreams ?? []
        let video = streams.first { ($0.type ?? "").lowercased() == "video" }
        let res: String? = video.flatMap { v in
            guard let h = v.height else { return nil }
            let w = v.width ?? 0
            if h >= 2000 || w >= 3800 { return "4K" }
            if h >= 1000 || w >= 1900 { return "1080p" }
            if h >= 700 || w >= 1260 { return "720p" }
            return "SD"
        }
        let audio = streams.filter { ($0.type ?? "").lowercased() == "audio" }.map { $0.language ?? $0.displayTitle ?? "und" }
        let subs = streams.filter { ($0.type ?? "").lowercased() == "subtitle" }.map { $0.language ?? $0.displayTitle ?? "und" }
        let tagKeys = Set((imageTags ?? [:]).keys.map { $0.lowercased() })
        return MediaItem(
            serverAccountId: server,
            itemId: id,
            kind: kind,
            title: name ?? "Untitled",
            year: productionYear,
            runtimeTicks: runTimeTicks,
            genres: genres ?? [],
            tags: tags ?? [],
            studios: (studios ?? []).compactMap { $0.name },
            overview: overview,
            officialRating: officialRating,
            communityRating: communityRating,
            hasPrimaryImage: tagKeys.contains("primary"),
            hasBackdrop: !(backdropImageTags ?? []).isEmpty,
            videoResolution: res,
            audioLanguages: Array(Set(audio)).sorted(),
            subtitleLanguages: Array(Set(subs)).sorted(),
            providerIds: providerIds ?? [:],
            resumeTicks: userData?.playbackPositionTicks,
            played: userData?.played ?? false,
            seriesId: seriesId,
            seriesName: seriesName,
            seasonId: seasonId,
            indexNumber: indexNumber,
            parentIndexNumber: parentIndexNumber,
            libraryId: libraryId,
            dateAdded: dateCreated
        )
    }
}

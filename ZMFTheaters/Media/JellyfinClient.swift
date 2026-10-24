import Foundation

struct JellyfinError: LocalizedError, Equatable {
    var message: String
    var statusCode: Int?
    var errorDescription: String? { message }

    static func http(_ code: Int, _ body: String) -> JellyfinError {
        let hint: String
        switch code {
        case 401: hint = "Unauthorized — the session expired or the username/password is wrong."
        case 403: hint = "Forbidden — this Jellyfin user is not allowed to do that."
        case 404: hint = "Not found on this server."
        case 500...599: hint = "The Jellyfin server reported an internal error."
        default: hint = "Unexpected response."
        }
        let detail = body.isEmpty ? "" : " (\(body.prefix(160)))"
        return JellyfinError(message: "HTTP \(code): \(hint)\(detail)", statusCode: code)
    }
}

/// Talks to ONE Jellyfin server using its documented REST API. A client instance
/// only ever holds the token issued by its own server, which is how the app
/// guarantees tokens never leak between servers.
final class JellyfinClient {
    let baseURL: URL
    var token: String?
    let deviceId: String
    let session: URLSession

    static let clientName = "ZMF Theaters"
    static let clientVersion = "0.1.0"

    init(baseURL: URL, token: String?, deviceId: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.deviceId = deviceId
        self.session = session
    }

    var authorizationHeader: String {
        var s = "MediaBrowser Client=\"\(Self.clientName)\", Device=\"iPhone\", DeviceId=\"\(deviceId)\", Version=\"\(Self.clientVersion)\""
        if let token { s += ", Token=\"\(token)\"" }
        return s
    }

    func url(_ path: String, _ query: [URLQueryItem] = []) -> URL {
        var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        let basePath = comps.path.hasSuffix("/") ? String(comps.path.dropLast()) : comps.path
        comps.path = basePath + path
        if !query.isEmpty { comps.queryItems = query }
        return comps.url!
    }

    func makeRequest(_ path: String, query: [URLQueryItem] = [], method: String = "GET", json: Any? = nil) -> URLRequest {
        var req = URLRequest(url: url(path, query))
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let json {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        }
        return req
    }

    private func data(for req: URLRequest) async throws -> Data {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: req)
        } catch let e as URLError {
            throw JellyfinError(message: "Network error: \(e.localizedDescription)", statusCode: nil)
        }
        guard let http = response as? HTTPURLResponse else {
            throw JellyfinError(message: "No HTTP response from server.", statusCode: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw JellyfinError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        return data
    }

    func get<T: Decodable>(_ type: T.Type, _ req: URLRequest) async throws -> T {
        let d = try await data(for: req)
        do {
            return try JellyfinCoding.decoder.decode(T.self, from: d)
        } catch {
            throw JellyfinError(message: "Could not read the server's response: \(error.localizedDescription)", statusCode: nil)
        }
    }

    func send(_ req: URLRequest) async throws {
        _ = try await data(for: req)
    }

    // MARK: - System & auth

    func publicInfo() async throws -> JFPublicSystemInfo {
        try await get(JFPublicSystemInfo.self, makeRequest("/System/Info/Public"))
    }

    func authenticate(username: String, password: String) async throws -> JFAuthResult {
        let req = makeRequest("/Users/AuthenticateByName", method: "POST", json: ["Username": username, "Pw": password])
        let result = try await get(JFAuthResult.self, req)
        token = result.accessToken
        return result
    }

    // MARK: - Library discovery

    /// Top level libraries ("views") for the user. Uses the 10.9+ route and falls
    /// back to the legacy user-scoped route for older servers.
    func libraries(userId: String) async throws -> [JFItem] {
        do {
            return try await get(JFItemsResult.self, makeRequest("/UserViews", query: [.init(name: "userId", value: userId)])).items
        } catch let e as JellyfinError where e.statusCode == 404 {
            return try await get(JFItemsResult.self, makeRequest("/Users/\(userId)/Views")).items
        }
    }

    static let itemFields = "Genres,Overview,ProductionYear,Tags,Studios,ProviderIds,MediaStreams,DateCreated,OfficialRating,CommunityRating"

    func items(userId: String, parentId: String?, types: String, startIndex: Int, limit: Int) async throws -> JFItemsResult {
        var q: [URLQueryItem] = [
            .init(name: "userId", value: userId),
            .init(name: "IncludeItemTypes", value: types),
            .init(name: "Recursive", value: "true"),
            .init(name: "Fields", value: Self.itemFields),
            .init(name: "SortBy", value: "SortName"),
            .init(name: "StartIndex", value: String(startIndex)),
            .init(name: "Limit", value: String(limit)),
            .init(name: "EnableImageTypes", value: "Primary,Backdrop"),
            .init(name: "ImageTypeLimit", value: "1"),
        ]
        if let parentId { q.append(.init(name: "ParentId", value: parentId)) }
        do {
            return try await get(JFItemsResult.self, makeRequest("/Items", query: q))
        } catch let e as JellyfinError where e.statusCode == 404 {
            let legacy = q.filter { $0.name != "userId" }
            return try await get(JFItemsResult.self, makeRequest("/Users/\(userId)/Items", query: legacy))
        }
    }

    func item(userId: String, itemId: String) async throws -> JFItem {
        let q: [URLQueryItem] = [.init(name: "userId", value: userId), .init(name: "Ids", value: itemId), .init(name: "Fields", value: Self.itemFields)]
        let result = try await get(JFItemsResult.self, makeRequest("/Items", query: q))
        guard let first = result.items.first else { throw JellyfinError(message: "That title is no longer on the server.", statusCode: 404) }
        return first
    }

    func seasons(seriesId: String, userId: String) async throws -> [JFItem] {
        try await get(JFItemsResult.self, makeRequest("/Shows/\(seriesId)/Seasons", query: [.init(name: "userId", value: userId)])).items
    }

    func episodes(seriesId: String, seasonId: String, userId: String) async throws -> [JFItem] {
        let q: [URLQueryItem] = [
            .init(name: "userId", value: userId),
            .init(name: "seasonId", value: seasonId),
            .init(name: "Fields", value: Self.itemFields),
        ]
        return try await get(JFItemsResult.self, makeRequest("/Shows/\(seriesId)/Episodes", query: q)).items
    }

    // MARK: - Images

    func imageURL(itemId: String, type: String = "Primary", maxWidth: Int = 600) -> URL {
        url("/Items/\(itemId)/Images/\(type)", [.init(name: "maxWidth", value: String(maxWidth)), .init(name: "quality", value: "90")])
    }

    // MARK: - Playback negotiation

    /// Device profile describing what AVFoundation on iPhone decodes natively.
    /// Anything else is remuxed or transcoded by the server into HLS.
    static func deviceProfile(maxBitrate: Int) -> [String: Any] {
        [
            "Name": "ZMF Theaters iOS",
            "MaxStreamingBitrate": maxBitrate,
            "MaxStaticBitrate": maxBitrate,
            "MusicStreamingTranscodingBitrate": 384_000,
            "DirectPlayProfiles": [
                ["Container": "mp4,m4v,mov", "Type": "Video", "VideoCodec": "h264,hevc", "AudioCodec": "aac,ac3,eac3,mp3,alac,flac"],
            ],
            "TranscodingProfiles": [
                ["Container": "mp4", "Type": "Video", "VideoCodec": "hevc,h264", "AudioCodec": "aac,ac3,eac3",
                 "Protocol": "hls", "Context": "Streaming", "MaxAudioChannels": "6", "MinSegments": 2, "BreakOnNonKeyFrames": true],
                ["Container": "ts", "Type": "Video", "VideoCodec": "h264", "AudioCodec": "aac,ac3,eac3",
                 "Protocol": "hls", "Context": "Streaming", "MaxAudioChannels": "6", "MinSegments": 2, "BreakOnNonKeyFrames": true],
            ],
            "ContainerProfiles": [],
            "CodecProfiles": [],
            "SubtitleProfiles": [
                ["Format": "vtt", "Method": "External"],
                ["Format": "srt", "Method": "External"],
                ["Format": "subrip", "Method": "External"],
                ["Format": "ass", "Method": "External"],
                ["Format": "ssa", "Method": "External"],
            ],
        ]
    }

    func playbackInfo(itemId: String, userId: String, maxBitrate: Int, audioStreamIndex: Int? = nil) async throws -> JFPlaybackInfo {
        var body: [String: Any] = [
            "UserId": userId,
            "MaxStreamingBitrate": maxBitrate,
            "EnableDirectPlay": true,
            "EnableDirectStream": true,
            "EnableTranscoding": true,
            "AllowVideoStreamCopy": true,
            "AllowAudioStreamCopy": true,
            "AutoOpenLiveStream": true,
            "DeviceProfile": Self.deviceProfile(maxBitrate: maxBitrate),
        ]
        var q: [URLQueryItem] = [.init(name: "userId", value: userId)]
        if let audioStreamIndex {
            body["AudioStreamIndex"] = audioStreamIndex
            q.append(.init(name: "AudioStreamIndex", value: String(audioStreamIndex)))
        }
        let info = try await get(JFPlaybackInfo.self, makeRequest("/Items/\(itemId)/PlaybackInfo", query: q, method: "POST", json: body))
        if let code = info.errorCode, !code.isEmpty {
            throw JellyfinError(message: "Jellyfin refused playback: \(code)", statusCode: nil)
        }
        return info
    }

    /// Appends the access token as a query parameter. AVPlayer cannot attach the
    /// Authorization header to every HLS segment request, so streams use the
    /// documented `api_key` / `ApiKey` parameters instead.
    func authorizedStreamURL(_ url: URL) -> URL {
        guard let token, var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var items = comps.queryItems ?? []
        let names = Set(items.map { $0.name.lowercased() })
        if !names.contains("api_key") { items.append(.init(name: "api_key", value: token)) }
        if !names.contains("apikey") { items.append(.init(name: "ApiKey", value: token)) }
        comps.queryItems = items
        return comps.url ?? url
    }

    func directStreamURL(itemId: String, mediaSourceId: String, playSessionId: String?, tag: String?) -> URL {
        var q: [URLQueryItem] = [
            .init(name: "static", value: "true"),
            .init(name: "mediaSourceId", value: mediaSourceId),
            .init(name: "deviceId", value: deviceId),
        ]
        if let playSessionId { q.append(.init(name: "PlaySessionId", value: playSessionId)) }
        if let tag { q.append(.init(name: "Tag", value: tag)) }
        return authorizedStreamURL(url("/Videos/\(itemId)/stream", q))
    }

    func transcodeURL(relative: String) -> URL? {
        // TranscodingUrl is server-relative and already carries its own query string.
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        guard let u = URL(string: base + relative) else { return nil }
        return authorizedStreamURL(u)
    }

    func subtitleURL(itemId: String, mediaSourceId: String, streamIndex: Int) -> URL {
        authorizedStreamURL(url("/Videos/\(itemId)/\(mediaSourceId)/Subtitles/\(streamIndex)/0/Stream.vtt"))
    }

    // MARK: - Session reporting

    func reportPlaybackStart(_ body: [String: Any]) async {
        try? await send(makeRequest("/Sessions/Playing", method: "POST", json: body))
    }

    func reportPlaybackProgress(_ body: [String: Any]) async {
        try? await send(makeRequest("/Sessions/Playing/Progress", method: "POST", json: body))
    }

    func reportPlaybackStopped(_ body: [String: Any]) async {
        try? await send(makeRequest("/Sessions/Playing/Stopped", method: "POST", json: body))
    }
}

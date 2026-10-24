import XCTest
@testable import ZMFTheaters

/// Intercepts URLSession traffic so the Jellyfin API client can be exercised
/// against recorded fixture responses without a live server.
final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest, Data?) -> (Int, Data))?
    static var log: [(URLRequest, Data?)] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            body = data
        }
        Self.log.append((request, body))
        let (status, data) = Self.handler?(request, body) ?? (404, Data())
        let resp = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func session() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: cfg)
    }
}

enum Fixtures {
    static let auth = """
    {"User":{"Name":"zach","ServerId":"srv1","Id":"user-123"},"SessionInfo":{},"AccessToken":"token-abc","ServerId":"srv1"}
    """
    static let publicInfo = """
    {"LocalAddress":"http://10.0.0.2:8096","ServerName":"Home Movies","Version":"10.10.7","ProductName":"Jellyfin Server","Id":"srv1","StartupWizardCompleted":true}
    """
    static let views = """
    {"Items":[{"Name":"Movies","Id":"lib-movies","CollectionType":"movies","Type":"CollectionFolder"},{"Name":"Music","Id":"lib-music","CollectionType":"music","Type":"CollectionFolder"}],"TotalRecordCount":2}
    """
    static let items = """
    {"Items":[
      {"Name":"Casablanca","Id":"m1","Type":"Movie","ProductionYear":1942,"RunTimeTicks":61200000000,"Genres":["Drama","Romance"],"ImageTags":{"Primary":"abc"},"BackdropImageTags":["b1"],"ProviderIds":{"Tmdb":"289","Imdb":"tt0034583"},"UserData":{"PlaybackPositionTicks":0,"Played":false},"DateCreated":"2024-05-01T12:00:00.1234567Z",
       "MediaStreams":[{"Type":"Video","Codec":"h264","Height":1080,"Width":1920,"Index":0},{"Type":"Audio","Codec":"aac","Language":"eng","Index":1},{"Type":"Subtitle","Codec":"subrip","Language":"spa","Index":2,"IsTextSubtitleStream":true}]},
      {"Name":"Iron Man","Id":"m2","Type":"Movie","ProductionYear":2008,"RunTimeTicks":75600000000,"Genres":["Action","Science Fiction"],"Studios":[{"Name":"Marvel Studios","Id":"s1"}],"Tags":["superhero"],"ImageTags":{"Primary":"def"},"ProviderIds":{"Tmdb":"1726"}},
      {"Name":"The Office","Id":"tv1","Type":"Series","ProductionYear":2005,"Genres":["Comedy"]}
    ],"TotalRecordCount":3}
    """
    static let playbackInfo = """
    {"MediaSources":[{"Id":"ms1","Container":"mkv","SupportsDirectPlay":false,"SupportsDirectStream":true,"SupportsTranscoding":true,
      "TranscodingUrl":"/videos/m2/master.m3u8?DeviceId=d&MediaSourceId=ms1&PlaySessionId=ps1","MediaStreams":[{"Type":"Audio","Index":1,"DisplayTitle":"English - Dolby Digital - 5.1"}]}],
     "PlaySessionId":"ps1"}
    """
}

@MainActor
final class JellyfinClientTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubProtocol.log = []
        StubProtocol.handler = { req, _ in
            let path = req.url!.path
            switch path {
            case "/System/Info/Public": return (200, Data(Fixtures.publicInfo.utf8))
            case "/Users/AuthenticateByName": return (200, Data(Fixtures.auth.utf8))
            case "/UserViews": return (200, Data(Fixtures.views.utf8))
            case "/Items": return (200, Data(Fixtures.items.utf8))
            case "/Items/m2/PlaybackInfo": return (200, Data(Fixtures.playbackInfo.utf8))
            default: return (404, Data())
            }
        }
    }

    func testAuthenticationSendsDocumentedHeaderAndBody() async throws {
        let c = JellyfinClient(baseURL: URL(string: "https://media.example.com")!, token: nil, deviceId: "dev-1", session: StubProtocol.session())
        let auth = try await c.authenticate(username: "zach", password: "secret")
        XCTAssertEqual(auth.accessToken, "token-abc")
        XCTAssertEqual(auth.user.id, "user-123")
        XCTAssertEqual(c.token, "token-abc")

        let (req, body) = try XCTUnwrap(StubProtocol.log.last)
        XCTAssertEqual(req.httpMethod, "POST")
        let header = try XCTUnwrap(req.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(header.hasPrefix("MediaBrowser "))
        XCTAssertTrue(header.contains("DeviceId=\"dev-1\""))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as? [String: String])
        XCTAssertEqual(json["Username"], "zach")
        XCTAssertEqual(json["Pw"], "secret")
    }

    func testItemsDecodeIntoUnifiedCatalogModel() async throws {
        let c = JellyfinClient(baseURL: URL(string: "https://media.example.com")!, token: "t", deviceId: "d", session: StubProtocol.session())
        let result = try await c.items(userId: "user-123", parentId: "lib-movies", types: "Movie,Series", startIndex: 0, limit: 100)
        XCTAssertEqual(result.items.count, 3)
        let server = UUID()
        let items = result.items.map { $0.toMediaItem(server: server, libraryId: "lib-movies") }

        let casablanca = items[0]
        XCTAssertEqual(casablanca.kind, .movie)
        XCTAssertEqual(casablanca.year, 1942)
        XCTAssertEqual(casablanca.runtimeMinutes, 102)
        XCTAssertEqual(casablanca.videoResolution, "1080p")
        XCTAssertTrue(casablanca.hasPrimaryImage)
        XCTAssertTrue(casablanca.hasBackdrop)
        XCTAssertEqual(casablanca.subtitleLanguages, ["spa"])
        XCTAssertEqual(casablanca.dedupeKey, "tmdb:289")
        XCTAssertNotNil(casablanca.dateAdded)
        XCTAssertEqual(casablanca.serverAccountId, server)

        XCTAssertEqual(items[1].studios, ["Marvel Studios"])
        XCTAssertEqual(items[2].kind, .series)
    }

    func testTokensAreScopedToTheirOwnServer() {
        let a = JellyfinClient(baseURL: URL(string: "https://a.example.com")!, token: "token-A", deviceId: "d")
        let b = JellyfinClient(baseURL: URL(string: "https://b.example.com/jellyfin")!, token: "token-B", deviceId: "d")
        let ua = a.directStreamURL(itemId: "x", mediaSourceId: "x", playSessionId: nil, tag: nil)
        let ub = b.directStreamURL(itemId: "y", mediaSourceId: "y", playSessionId: nil, tag: nil)
        XCTAssertEqual(ua.host, "a.example.com")
        XCTAssertTrue(ua.absoluteString.contains("token-A"))
        XCTAssertFalse(ua.absoluteString.contains("token-B"))
        XCTAssertEqual(ub.host, "b.example.com")
        XCTAssertTrue(ub.path.hasPrefix("/jellyfin/Videos/y/stream"))
        XCTAssertFalse(ub.absoluteString.contains("token-A"))
        XCTAssertTrue(a.makeRequest("/Items").value(forHTTPHeaderField: "Authorization")!.contains("Token=\"token-A\""))
    }

    func testPlaybackInfoNegotiatesTranscodeWithDeviceProfile() async throws {
        let c = JellyfinClient(baseURL: URL(string: "https://media.example.com")!, token: "tok", deviceId: "d", session: StubProtocol.session())
        let info = try await c.playbackInfo(itemId: "m2", userId: "user-123", maxBitrate: 40_000_000)
        XCTAssertEqual(info.playSessionId, "ps1")
        let source = try XCTUnwrap(info.mediaSources?.first)
        XCTAssertEqual(source.supportsDirectPlay, false)
        let url = try XCTUnwrap(c.transcodeURL(relative: try XCTUnwrap(source.transcodingUrl)))
        XCTAssertTrue(url.absoluteString.hasPrefix("https://media.example.com/videos/m2/master.m3u8"))
        XCTAssertTrue(url.absoluteString.contains("api_key=tok"))

        let (_, body) = try XCTUnwrap(StubProtocol.log.last)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(body)) as? [String: Any])
        let profile = try XCTUnwrap(json["DeviceProfile"] as? [String: Any])
        XCTAssertNotNil(profile["DirectPlayProfiles"])
        XCTAssertNotNil(profile["TranscodingProfiles"])
    }

    func testHTTPErrorsAreReportedHonestly() async {
        StubProtocol.handler = { _, _ in (401, Data("Unauthorized".utf8)) }
        let c = JellyfinClient(baseURL: URL(string: "https://media.example.com")!, token: "bad", deviceId: "d", session: StubProtocol.session())
        do {
            _ = try await c.libraries(userId: "u")
            XCTFail("expected an error")
        } catch let e as JellyfinError {
            XCTAssertEqual(e.statusCode, 401)
        } catch {
            XCTFail("unexpected error type \(error)")
        }
    }

    func testJellyfinSevenDigitFractionalDates() {
        XCTAssertNotNil(JellyfinCoding.parseDate("2024-05-01T12:00:00.1234567Z"))
        XCTAssertNotNil(JellyfinCoding.parseDate("2024-05-01T12:00:00Z"))
    }
}

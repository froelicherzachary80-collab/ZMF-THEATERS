import XCTest
@testable import ZMFTheaters

@MainActor
final class CinemaLogicTests: XCTestCase {
    private let server = UUID()

    private func movie(_ id: String, _ year: Int, _ genres: [String], rating: Double? = nil) -> MediaItem {
        MediaItem(serverAccountId: server, itemId: id, kind: .movie, title: "Film \(id)", year: year, runtimeTicks: 72_000_000_000,
                  genres: genres, communityRating: rating)
    }

    private func library() -> [MediaItem] {
        var out: [MediaItem] = []
        let genreSets: [[String]] = [["Action"], ["Adventure"], ["Romance"], ["Horror"], ["Comedy"], ["Animation"],
                                     ["Fantasy"], ["Science Fiction"], ["Mystery"], ["Drama"], ["Thriller"], ["Family"]]
        for i in 0..<60 {
            out.append(movie("n\(i)", 2000 + i % 25, genreSets[i % genreSets.count], rating: i % 3 == 0 ? 8.0 : 6.0))
        }
        for i in 0..<8 { out.append(movie("c\(i)", 1950 + i * 5, ["Drama"])) }
        var hero = movie("hero", 2012, ["Action"])
        hero.studios = ["Marvel Studios"]
        out.append(hero)
        return out
    }

    func testCombinedFormatAndPermanentAvailability() throws {
        XCTAssertEqual(ScreeningFormat.allCases.count, 4)
        XCTAssertTrue(ScreeningFormat.fourDX3D.usesDepth)
        XCTAssertTrue(ScreeningFormat.fourDX3D.uses4DX)
        XCTAssertFalse(ScreeningFormat.standard2D.usesDepth)
        XCTAssertFalse(ScreeningFormat.standard2D.uses4DX)
        XCTAssertTrue(FourDX.isPreviewActive(now: Date.distantFuture, settings: AppSettings()))
        let saved = Data("\"fourDX\"".utf8)
        XCTAssertEqual(try JSONDecoder().decode(ScreeningFormat.self, from: saved), .fourDX)
    }

    func testFlashDoesNotCreateImpactAndStopResetsSeat() {
        let engine = FourDXEngine()
        engine.start(haptics: false)
        for i in 0..<60 {
            let samples = [Vec4](repeating: Vec4(repeating: i % 2 == 0 ? 0 : 1), count: 64)
            samples.withUnsafeBufferPointer { grid in
                engine.update(grid: grid.baseAddress, dt: 1 / 24, intensity: 1,
                              seatForward: Vec3(0, 0, 1), timestamp: Double(i) / 24)
            }
            XCTAssertEqual(engine.strobe, 0)
            XCTAssertEqual(engine.fogBoost, 0)
        }
        engine.update(grid: nil, dt: .nan, intensity: .infinity,
                      seatForward: Vec3(0, 0, 1), timestamp: .nan)
        XCTAssertTrue(engine.seatOffset.x.isFinite)
        engine.stop()
        engine.update(grid: nil, dt: 0.016, intensity: 1,
                      seatForward: Vec3(0, 0, 1), timestamp: .nan)
        XCTAssertEqual(engine.rumble, 0)
        XCTAssertEqual(engine.seatOffset, .zero)
        XCTAssertEqual(engine.seatTilt, .zero)
    }

    func testMotionCueCacheIsReusableAndRejectsChangedDuration() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = FourDXCueCache(directory: dir)
        let cues = [
            FourDXMotionCue(timestamp: 5.0, energy: 0.13, flowX: -0.1, flowY: 0),
            FourDXMotionCue(timestamp: 6.0, energy: 0.1, flowX: 0.1, flowY: 0)
        ]
        await cache.save(mediaID: "local-film-A", duration: 120, cues: cues)
        let loaded = await cache.load(mediaID: "local-film-A", duration: 120)
        XCTAssertEqual(loaded.count, 2)
        XCTAssertEqual(loaded[0].timestamp, 5)
        let differentMedia = await cache.load(mediaID: "local-film-B", duration: 120)
        XCTAssertTrue(differentMedia.isEmpty)
        let changedVersion = await cache.load(mediaID: "local-film-A", duration: 145)
        XCTAssertTrue(changedVersion.isEmpty)
    }

    func testPictureMotionDoesNotTriggerFlashesAndResetsOnSeek() {
        let engine = FourDXEngine()
        engine.start(haptics: false)
        for f in 0..<80 {
            let samples = (0..<64).map { i -> Vec4 in
                let x = Float(i % 8)
                let value = 0.15 + 0.07 * sinf((x + Float(f) * 0.4) * 0.45)
                return Vec4(value, value, value, 1)
            }
            samples.withUnsafeBufferPointer { grid in
                engine.update(grid: grid.baseAddress, dt: 1 / 30, intensity: 1,
                              seatForward: Vec3(0, 0, 1), timestamp: Double(f) / 30)
            }
            XCTAssertTrue(engine.rumble.isFinite)
            XCTAssertLessThanOrEqual(engine.rumble, 0.25)
            XCTAssertEqual(engine.strobe, 0)
            XCTAssertEqual(engine.fogBoost, 0)
        }
        let dark = [Vec4](repeating: Vec4(0, 0, 0, 1), count: 64)
        dark.withUnsafeBufferPointer { grid in
            engine.update(grid: grid.baseAddress, dt: 1 / 30, intensity: 1,
                          seatForward: Vec3(0, 0, 1), timestamp: 0)
        }
        XCTAssertEqual(engine.rumble, 0)
        XCTAssertEqual(engine.seatOffset, .zero)
        engine.stop()
    }

    func testYouTubeTrailerLinkValidationAndSecurity() {
        let id = "dQw4w9WgXcQ"
        XCTAssertEqual(PreshowYouTubeTrailer.videoID(from: "https://www.youtube.com/watch?v=\(id)&t=3"), id)
        XCTAssertEqual(PreshowYouTubeTrailer.videoID(from: "https://youtu.be/\(id)"), id)
        XCTAssertEqual(PreshowYouTubeTrailer.videoID(from: "https://m.youtube.com/shorts/\(id)"), id)
        XCTAssertEqual(PreshowYouTubeTrailer.videoID(from: "https://www.youtube-nocookie.com/embed/\(id)"), id)
        XCTAssertNil(PreshowYouTubeTrailer.videoID(from: "http://www.youtube.com/watch?v=\(id)"))
        XCTAssertNil(PreshowYouTubeTrailer.videoID(from: "https://youtube.com.evil.example/watch?v=\(id)"))
        XCTAssertNil(PreshowYouTubeTrailer.videoID(from: "https://www.youtube.com/watch?v=hello"))
        XCTAssertNil(PreshowYouTubeTrailer.videoID(from: "javascript:alert('x')"))
        XCTAssertNil(PreshowYouTubeTrailer.videoID(from: "https://example.com/watch?v=\(id)"))
    }

    func testNewTrailerTogglesAndAtmosphereSettingsSurviveCoding() throws {
        var settings = AppSettings()
        settings.standardTrailersEnabled = false
        settings.fourDXTrailersEnabled = true
        settings.fourDXVirtualAsh = false
        settings.youtubeTrailers = [
            PreshowYouTubeTrailer(title: "Space Adventure", videoID: "dQw4w9WgXcQ", presentation: .fourDX)
        ]
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertFalse(decoded.standardTrailersEnabled)
        XCTAssertTrue(decoded.fourDXTrailersEnabled)
        XCTAssertFalse(decoded.fourDXVirtualAsh)
        XCTAssertEqual(decoded.youtubeTrailers.first?.presentation, .fourDX)
    }

    func testVirtualAtmosphereMotionRampsAndResetsSafely() {
        let engine = FourDXEngine()
        engine.start(haptics: false)
        for frame in 0..<60 {
            engine.updateTrailerPreview(dt: 1 / 30, timestamp: Double(frame) / 30,
                                        intensity: 0.8, seatForward: Vec3(0, 0, 1))
        }
        XCTAssertGreaterThan(engine.mist, 0.1)
        XCTAssertEqual(engine.strobe, 0)
        XCTAssertTrue(engine.seatOffset.x.isFinite)
        XCTAssertLessThan(engine.seatOffset.y.magnitude, 0.25)
        XCTAssertLessThan(engine.seatTilt.x.magnitude, 0.2)
        engine.stop()
        XCTAssertEqual(engine.mist, 0)
        XCTAssertEqual(engine.snow, 0)
        XCTAssertEqual(engine.ash, 0)
        XCTAssertEqual(engine.virtualFog, 0)
        XCTAssertEqual(engine.seatTilt, .zero)
    }

    func testYouTubeProjectorWebsiteSurvivesBrowserDismissal() {
        let session = YouTubeCinemaSession()
        session.openBrowser(address: "https://www.youtube.com/results?search_query=movie+trailers")
        XCTAssertTrue(session.isOpen)
        XCTAssertTrue(session.browserOpen)
        XCTAssertNil(session.video)
        XCTAssertEqual(session.projectedAddress, "https://www.youtube.com/results?search_query=movie+trailers")
        session.open(videoID: "dQw4w9WgXcQ", title: "Cinema", preset: .cinematic, bpm: 125, cuts: [])
        XCTAssertTrue(session.isOpen)
        XCTAssertFalse(session.browserOpen)
        XCTAssertNotNil(session.video)
        session.openBrowser()
        XCTAssertTrue(session.isOpen, "the web browser stays on the cinema screen")
        XCTAssertNil(session.video)
        session.close()
        XCTAssertFalse(session.isOpen)
    }

    func testYouTubeProjectorCannotNavigateToNonYouTubeAddress() {
        let session = YouTubeCinemaSession()
        session.openBrowser(address: "https://youtube.com.evil.example/")
        XCTAssertEqual(session.projectedAddress, "https://m.youtube.com")
        session.openBrowser(address: "file:///private/")
        XCTAssertEqual(session.projectedAddress, "https://m.youtube.com")
    }

    func testYouTubePlayerProjectsOntoRealAuditoriumScreen() {
        let size = CGSize(width: 1179, height: 2556)
        let fov = Float(AppSettings().seatedFieldOfView) * .pi / 180
        for room in [5, 9] {
            let seat = CinemaWorld.seatPosition(room: room, row: 4, seat: 3)
            let eye = seat + Vec3(0, 1.12, 0)
            let center = CinemaWorld.screenCenter(room)
            let camera = CinemaGame.CameraState(eye: eye, target: center)
            let rect = CinemaScreenAnchor.frame(room: room, camera: camera,
                                                fieldOfView: fov, viewport: size)
            XCTAssertNotNil(rect, "screen in both mirrored wings must project in front of the viewer")
            XCTAssertGreaterThan(rect?.width ?? 0, 120)
            XCTAssertGreaterThan(rect?.height ?? 0, 40)
            XCTAssertLessThan(abs((rect?.midX ?? 0) - size.width / 2), size.width * 0.12)
        }
    }

    func testYouTubeScreenAnchorIsWorldFixedWhenSeatMoves() {
        let room = 9
        let seat = CinemaWorld.seatPosition(room: room, row: 4, seat: 3)
        let center = CinemaWorld.screenCenter(room)
        let eye = seat + Vec3(0, 1.12, 0)
        let viewport = CGSize(width: 1179, height: 2556)
        let fov = Float(AppSettings().seatedFieldOfView) * .pi / 180
        let atRest = CinemaScreenAnchor.frame(
            room: room, camera: .init(eye: eye, target: center),
            fieldOfView: fov, viewport: viewport)!
        // The modelled 4DX seat lifts the camera, while the world screen stays
        // at CinemaWorld.screenCenter(room); the web player follows projection.
        let rise = Vec3(0, 0.17, 0)
        let whileRising = CinemaScreenAnchor.frame(
            room: room, camera: .init(eye: eye + rise, target: center + rise),
            fieldOfView: fov, viewport: viewport)!
        XCTAssertGreaterThan(abs(atRest.midY - whileRising.midY), 1,
                             "projected screen moves relative to the viewer, not with seat-mounted UI")
        let backwards = CinemaScreenAnchor.frame(
            room: room, camera: .init(eye: eye, target: eye + Vec3(-1, 0, 0)),
            fieldOfView: fov, viewport: viewport)
        XCTAssertNil(backwards, "screen behind the camera must not become a floating overlay")
    }

    func testYouTubeCinemaSessionClockAndManualCutRecording() {
        let cinema = YouTubeCinemaSession()
        cinema.open(videoID: "dQw4w9WgXcQ", title: "Test",
                    preset: .edits, bpm: 140, cuts: [5, 4, 4, .nan, -2])
        XCTAssertEqual(cinema.bpm, 140)
        XCTAssertEqual(cinema.cutMarks, [4, 5])
        cinema.receive(playing: true, seconds: 7.12)
        XCTAssertEqual(cinema.recordCut().last!, 7.12, accuracy: 0.001)
        XCTAssertEqual(cinema.cutMarks.count, 3)
        cinema.receive(playing: false, seconds: 7.5)
        XCTAssertEqual(cinema.recordCut().count, 3)
        cinema.close()
        XCTAssertNil(cinema.video)
        XCTAssertTrue(cinema.cutMarks.isEmpty)
    }

    func testYouTubeMotionIsBoundedAndStopsWhenClosed() {
        let engine = FourDXEngine()
        engine.start(haptics: false)
        let cuts = [0.5, 1, 2, 3.5]
        for f in 0..<120 {
            engine.updateYouTubeCinema(dt: 1 / 60, timestamp: Double(f) / 60, intensity: 1,
                seatForward: Vec3(0, 0, 1), preset: .edits, bpm: 125, cuts: cuts)
            XCTAssertLessThanOrEqual(engine.rumble, 0.38)
            XCTAssertLessThan(engine.seatOffset.y.magnitude, 0.2)
            XCTAssertLessThan(engine.seatTilt.x.magnitude, 0.2)
            XCTAssertEqual(engine.strobe, 0)
        }
        engine.updateYouTubeCinema(dt: 1 / 60, timestamp: 0.2, intensity: 1,
            seatForward: Vec3(0, 0, 1), preset: .off, bpm: 125, cuts: [])
        XCTAssertEqual(engine.rumble, 0)
        engine.stop()
        XCTAssertEqual(engine.seatTilt, .zero)
        XCTAssertEqual(engine.seatOffset, .zero)
    }

    func testRotationFillsTwelveRoomsWithoutDuplicatesAndRespectsEras() {
        let s = AppSettings()
        let (assign, notes) = RotationDirector.select(candidates: library(), index: 5, settings: s, recent: [])
        XCTAssertEqual(assign.count, 12)
        XCTAssertEqual(Set(assign.values).count, 12, "no film should be in two rooms when the library is large enough")
        let byId = Dictionary(uniqueKeysWithValues: library().map { ($0.id, $0) })
        let classic = byId[assign["1"]!]!
        XCTAssertTrue((1900...1999).contains(classic.year!), "Room 01 must only show 1900–1999 films")
        for room in 2...12 {
            XCTAssertGreaterThanOrEqual(byId[assign[String(room)]!]!.year!, 2000)
        }
        XCTAssertEqual(byId[assign["7"]!]!.itemId, "hero", "the only superhero title should land in Superhero Universe")
        XCTAssertEqual(notes["5"], "Genre match")
    }

    func testRotationIsDeterministicAndAvoidsConsecutiveRepeats() {
        let s = AppSettings()
        let lib = library()
        let (a1, _) = RotationDirector.select(candidates: lib, index: 10, settings: s, recent: [])
        let (a2, _) = RotationDirector.select(candidates: lib, index: 10, settings: s, recent: [])
        XCTAssertEqual(a1, a2, "same seed and period must give the same programme")

        let (next, _) = RotationDirector.select(candidates: lib, index: 11, settings: s, recent: [Array(a1.values)])
        let previous = Set(a1.values)
        let repeats = next.filter { previous.contains($0.value) && $0.key != "7" && $0.key != "1" }
        XCTAssertTrue(repeats.isEmpty, "films must not repeat in consecutive rotations when alternatives exist: \(repeats)")
    }

    func testRoomOneNeverRelaxesItsEraEvenWithoutClassics() {
        let modernOnly = library().filter { ($0.year ?? 0) >= 2000 }
        let (assign, notes) = RotationDirector.select(candidates: modernOnly, index: 0, settings: AppSettings(), recent: [])
        XCTAssertNil(assign["1"])
        XCTAssertEqual(notes["1"], "No eligible title in connected libraries")
    }

    func testPeriodIndexUsesWallClockFromAnchor() {
        var s = AppSettings()
        s.rotationDays = 3
        let anchor = s.rotationAnchor
        XCTAssertEqual(RotationDirector.periodIndex(now: anchor.addingTimeInterval(10), settings: s), 0)
        XCTAssertEqual(RotationDirector.periodIndex(now: anchor.addingTimeInterval(3 * 86_400 + 1), settings: s), 1)
        // Re-opening the app 40 days later lands on the correct rotation.
        XCTAssertEqual(RotationDirector.periodIndex(now: anchor.addingTimeInterval(40 * 86_400), settings: s), 13)
    }

    func testShowtimesSeparatePreshowFromFeature() {
        let s = AppSettings()
        let shows = ShowtimeScheduler.showtimes(roomId: 2, runtimeMinutes: 120, day: Date(), settings: s)
        XCTAssertGreaterThan(shows.count, 3)
        for show in shows {
            XCTAssertEqual(show.featureStart.timeIntervalSince(show.preshowStart), 600, accuracy: 0.5)
            XCTAssertEqual(show.end.timeIntervalSince(show.featureStart), 7200, accuracy: 0.5)
        }
        for (a, b) in zip(shows, shows.dropFirst()) {
            XCTAssertGreaterThanOrEqual(b.preshowStart.timeIntervalSince(a.end), Double(s.cleanupMinutes * 60))
        }
    }

    func testBestRoomClassification() {
        XCTAssertEqual(CinemaRooms.bestRoom(for: movie("a", 1985, ["Action"])).id, 1)
        XCTAssertEqual(CinemaRooms.bestRoom(for: movie("b", 2019, ["Horror"])).id, 5)
        XCTAssertEqual(CinemaRooms.bestRoom(for: movie("c", 2016, ["Animation", "Family"])).id, 10)
        XCTAssertEqual(CinemaRooms.bestRoom(for: movie("d", 2014, ["Science Fiction"])).id, 9)
    }

    func testVTTParsing() {
        let vtt = """
        WEBVTT

        1
        00:00:01.000 --> 00:00:03.500 align:middle
        Hello <i>there</i>

        00:01:02.250 --> 00:01:04.000
        Second line
        """
        let cues = SubtitleParser.parseVTT(vtt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].text, "Hello there")
        XCTAssertEqual(cues[1].start, 62.25, accuracy: 0.001)
    }

    func testWalkableSpaceAndLockedDoors() {
        XCTAssertTrue(CinemaWorld.isWalkable(CinemaWorld.spawn, doorOpen: { _ in false }))
        let doorway = Vec2(-4.1, CinemaWorld.roomBaseZ(3) + 7)
        XCTAssertFalse(CinemaWorld.isWalkable(doorway, doorOpen: { _ in false }), "closed doors block entry")
        XCTAssertTrue(CinemaWorld.isWalkable(doorway, doorOpen: { _ in true }))
        let seat = CinemaWorld.seatPosition(room: 9, row: 4, seat: 3)
        XCTAssertEqual(CinemaWorld.zone(at: Vec2(seat.x, seat.z)), .room(9))
    }

    // MARK: Real-time 4DX (synthetic signals only — not movie content)

    private struct SeededRNG: RandomNumberGenerator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> UInt64 { state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407; return state }
    }

    private func synth(_ seconds: Double, _ f: (Double) -> Float) -> [Float] {
        (0..<Int(seconds * 48_000)).map { f(Double($0) / 48_000) }
    }

    private func dialogue(_ t: Double) -> Float {
        Float(0.08 * sin(2 * .pi * 220 * t) * (0.5 + 0.5 * sin(2 * .pi * 4 * t)) +
              0.08 * sin(2 * .pi * 660 * t) * (0.5 + 0.5 * sin(2 * .pi * 3.3 * t)))
    }

    private func events(_ pcm: [Float], sensitivity: Float = 1) -> [FourDXDetectedEvent] {
        var c = FourDXSoundClassifier(sensitivity: sensitivity)
        return fourDXAudioChunks(mono: pcm, sampleRate: 48_000).flatMap { c.feed($0) }
    }

    func testDialogueAndMusicBeatsCreateNoEvents() {
        XCTAssertTrue(events(synth(6, dialogue), sensitivity: 2).isEmpty)
        let music = synth(6) { t in self.dialogue(t) + Float(0.25 * exp(-(t.truncatingRemainder(dividingBy: 0.5)) * 20) * sin(2 * .pi * 80 * t)) }
        XCTAssertFalse(events(music, sensitivity: 2).contains { $0.kind == .boom }, "kick drums are rhythm, not explosions")
    }

    func testBoomThenDebrisAndSharpHits() {
        var rng = SeededRNG()
        var pcm = synth(6) { t in self.dialogue(t) + (t > 3 ? Float(0.6 * exp(-(t - 3) * 3) * sin(2 * .pi * 50 * (t - 3))) : 0) }
        for k in 0..<8 { let st = Int((3.35 + Double(k) * 0.13) * 48_000); for i in 0..<96 { pcm[st + i] += Float.random(in: -0.5...0.5, using: &rng) * (1 - Float(i) / 96) } }
        let e = events(pcm)
        let boom = e.first { $0.kind == .boom }
        XCTAssertNotNil(boom)
        XCTAssertEqual(boom?.time ?? 0, 3.15, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(e.filter { $0.kind == .debris }.count, 4)
        XCTAssertFalse(e.contains { $0.kind == .sharpHit }, "crackle after a blast is debris")

        var hits = synth(6, dialogue)
        for at in [2.0, 4.0] { let st = Int(at * 48_000); for i in 0..<240 { hits[st + i] += Float.random(in: -0.7...0.7, using: &rng) * (1 - Float(i) / 240) } }
        XCTAssertEqual(events(hits).filter { $0.kind == .sharpHit }.count, 2)
    }

    private func pattern(_ x: Float, _ y: Float) -> Float {
        0.5 + 0.2 * sinf(x * 0.9 + 1.3 * sinf(y * 0.4)) + 0.15 * sinf(y * 1.1 + x * 0.3) + 0.1 * sinf(x * 2.3 - y * 1.7)
    }

    private func motion(_ map: (Int, Float, Float) -> (Float, Float)) -> FourDXMotionSample? {
        var tracker = FourDXMotionTracker()
        var last: FourDXMotionSample?
        for f in 0..<6 {
            var g = [Float](repeating: 0, count: 32 * 18)
            for y in 0..<18 { for x in 0..<32 { let (u, v) = map(f, Float(x) + 0.5 - 16, Float(y) + 0.5 - 9); g[y * 32 + x] = pattern(u, v) } }
            if let s = g.withUnsafeBufferPointer({ tracker.analyse($0) }) { last = s }
        }
        return last
    }

    func testMotionTrackerReadsPanTiltZoomAndRoll() {
        let pan = motion { f, x, y in (x + Float(f) * 0.6, y) }
        XCTAssertGreaterThan(pan?.flow.x ?? 0, 0.4)
        let tilt = motion { f, x, y in (x, y + Float(f) * 0.4) }
        XCTAssertGreaterThan(tilt?.flow.y ?? 0, 0.2)
        let push = motion { f, x, y in (x / powf(1.04, Float(f)), y / powf(1.04, Float(f))) }
        XCTAssertGreaterThan(push?.zoom ?? 0, 0.08)
        let pull = motion { f, x, y in (x * powf(1.04, Float(f)), y * powf(1.04, Float(f))) }
        XCTAssertLessThan(pull?.zoom ?? 0, -0.08)
        let rot = motion { f, x, y in let a = -Float(f) * 2 * .pi / 180; return (x * cosf(a) - y * sinf(a), x * sinf(a) + y * cosf(a)) }
        XCTAssertGreaterThan(rot?.roll ?? 0, 0.05)
        XCTAssertNil(motion { _, x, y in (x, y) }, "a still picture produces no motion")
    }
}

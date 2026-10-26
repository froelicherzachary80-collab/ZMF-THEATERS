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
}


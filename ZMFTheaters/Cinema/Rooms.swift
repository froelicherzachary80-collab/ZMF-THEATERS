import Foundation
import simd

enum DecorStyle: String, Codable {
    case palace, industrial, expedition, lounge, gothic, comedy
    case hero, enchanted, galaxy, toybox, noir, premiere
}

struct RoomTheme {
    var wall: SIMD3<Float>
    var accent: SIMD3<Float>
    var carpet: SIMD3<Float>
    var seat: SIMD3<Float>
    var light: SIMD3<Float>
    var decor: DecorStyle
    var fog: Float
}

/// One of the twelve permanent auditoriums. Genre identity and era rules are
/// fixed; Room 01 is permanently restricted to 1900–1999 releases.
struct CinemaRoom: Identifiable, Hashable {
    let id: Int
    let name: String
    let is3D: Bool
    let eraStart: Int
    let eraEnd: Int?
    let primaryTerms: [String]
    let relatedTerms: [String]
    let blurb: String
    let theme: RoomTheme

    static func == (a: CinemaRoom, b: CinemaRoom) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    var code: String { String(format: "%02d", id) }
    var title: String { "ROOM \(code) — \(name.uppercased())" }
    var eraLabel: String { eraEnd.map { "\(eraStart)–\($0)" } ?? "\(eraStart) onward" }
    /// Rooms 01–06 are on the west side of the hall, 07–12 on the east side.
    var isWestWing: Bool { id <= 6 }
    var wingIndex: Int { (id - 1) % 6 }

    func eraAllows(_ item: MediaItem) -> Bool {
        guard let y = item.year else { return false }
        if y < eraStart { return false }
        if let end = eraEnd, y > end { return false }
        return true
    }

    private func matches(_ item: MediaItem, _ terms: [String]) -> Bool {
        let hay = item.classificationTerms
        return terms.contains { t in hay.contains { $0.contains(t) } }
    }

    func primaryMatch(_ item: MediaItem) -> Bool {
        if id == 12 { return (item.communityRating ?? 0) >= 7.5 }
        if id == 1 { return true } // any genre qualifies for the classic palace
        return matches(item, primaryTerms)
    }

    func relatedMatch(_ item: MediaItem) -> Bool {
        id == 12 || id == 1 || matches(item, relatedTerms)
    }
}

enum CinemaRooms {
    static let all: [CinemaRoom] = [
        CinemaRoom(id: 1, name: "Classic Century", is3D: false, eraStart: 1900, eraEnd: 1999,
                   primaryTerms: [], relatedTerms: [],
                   blurb: "A gilded golden-age movie palace for films released 1900–1999.",
                   theme: RoomTheme(wall: [0.32, 0.06, 0.07], accent: [0.85, 0.65, 0.25], carpet: [0.35, 0.04, 0.05], seat: [0.55, 0.06, 0.08], light: [1.0, 0.78, 0.45], decor: .palace, fog: 0.012)),
        CinemaRoom(id: 2, name: "Action Arena", is3D: false, eraStart: 2000, eraEnd: nil,
                   primaryTerms: ["action", "war", "spy", "martial"], relatedTerms: ["thriller", "crime", "adventure", "western"],
                   blurb: "Steel, sparks and spectacle — action, espionage and fighting films.",
                   theme: RoomTheme(wall: [0.12, 0.12, 0.13], accent: [1.0, 0.45, 0.08], carpet: [0.08, 0.08, 0.09], seat: [0.15, 0.15, 0.16], light: [1.0, 0.55, 0.2], decor: .industrial, fog: 0.01)),
        CinemaRoom(id: 3, name: "Adventure Hall", is3D: false, eraStart: 2000, eraEnd: nil,
                   primaryTerms: ["adventure"], relatedTerms: ["action", "fantasy", "western", "family", "history"],
                   blurb: "Explorers' lodge for treasure hunts, survival and expeditions.",
                   theme: RoomTheme(wall: [0.22, 0.15, 0.08], accent: [0.35, 0.55, 0.25], carpet: [0.18, 0.12, 0.06], seat: [0.4, 0.25, 0.12], light: [1.0, 0.8, 0.5], decor: .expedition, fog: 0.008)),
        CinemaRoom(id: 4, name: "Romance Lounge", is3D: false, eraStart: 2000, eraEnd: nil,
                   primaryTerms: ["romance"], relatedTerms: ["drama", "music", "comedy"],
                   blurb: "Rose-gold velvet lounge for love stories and romantic comedies.",
                   theme: RoomTheme(wall: [0.35, 0.12, 0.18], accent: [0.95, 0.65, 0.6], carpet: [0.3, 0.08, 0.14], seat: [0.6, 0.2, 0.3], light: [1.0, 0.6, 0.65], decor: .lounge, fog: 0.008)),
        CinemaRoom(id: 5, name: "Horror Chamber", is3D: false, eraStart: 2000, eraEnd: nil,
                   primaryTerms: ["horror"], relatedTerms: ["thriller", "mystery", "supernatural", "paranormal"],
                   blurb: "A candle-lit gothic crypt for horror, slashers and the paranormal.",
                   theme: RoomTheme(wall: [0.08, 0.06, 0.06], accent: [0.6, 0.05, 0.05], carpet: [0.12, 0.02, 0.02], seat: [0.18, 0.04, 0.04], light: [1.0, 0.35, 0.2], decor: .gothic, fog: 0.03)),
        CinemaRoom(id: 6, name: "Comedy Club", is3D: false, eraStart: 2000, eraEnd: nil,
                   primaryTerms: ["comedy"], relatedTerms: ["family", "animation", "music"],
                   blurb: "Bright stage-club energy for comedy, satire and feel-good films.",
                   theme: RoomTheme(wall: [0.1, 0.18, 0.35], accent: [1.0, 0.85, 0.2], carpet: [0.08, 0.1, 0.25], seat: [0.85, 0.2, 0.2], light: [1.0, 0.9, 0.6], decor: .comedy, fog: 0.004)),
        CinemaRoom(id: 7, name: "Superhero Universe", is3D: true, eraStart: 2000, eraEnd: nil,
                   primaryTerms: ["superhero", "marvel", "dc comics", "dc films", "comic"], relatedTerms: ["action", "science fiction", "sci-fi", "fantasy"],
                   blurb: "Neon hero HQ for Marvel, superhero and comic-book films.",
                   theme: RoomTheme(wall: [0.06, 0.08, 0.2], accent: [0.9, 0.12, 0.15], carpet: [0.05, 0.05, 0.15], seat: [0.12, 0.15, 0.4], light: [0.35, 0.55, 1.0], decor: .hero, fog: 0.008)),
        CinemaRoom(id: 8, name: "Fantasy Kingdom", is3D: true, eraStart: 2000, eraEnd: nil,
                   primaryTerms: ["fantasy"], relatedTerms: ["adventure", "family", "animation", "mythology"],
                   blurb: "Enchanted crystal hall of magic, myth and legend.",
                   theme: RoomTheme(wall: [0.15, 0.08, 0.25], accent: [0.3, 0.95, 0.65], carpet: [0.1, 0.05, 0.18], seat: [0.3, 0.12, 0.45], light: [0.7, 0.5, 1.0], decor: .enchanted, fog: 0.015)),
        CinemaRoom(id: 9, name: "Sci-Fi Galaxy", is3D: true, eraStart: 2000, eraEnd: nil,
                   primaryTerms: ["science fiction", "sci-fi", "space"], relatedTerms: ["action", "adventure", "thriller"],
                   blurb: "Starship observation deck for science fiction and space opera.",
                   theme: RoomTheme(wall: [0.04, 0.07, 0.1], accent: [0.1, 0.9, 1.0], carpet: [0.03, 0.05, 0.08], seat: [0.15, 0.2, 0.25], light: [0.4, 0.9, 1.0], decor: .galaxy, fog: 0.006)),
        CinemaRoom(id: 10, name: "Animation World", is3D: true, eraStart: 2000, eraEnd: nil,
                   primaryTerms: ["animation", "anime"], relatedTerms: ["family", "kids", "comedy", "fantasy"],
                   blurb: "Candy-colour toybox theater for animated features.",
                   theme: RoomTheme(wall: [0.35, 0.25, 0.45], accent: [1.0, 0.6, 0.2], carpet: [0.2, 0.3, 0.5], seat: [0.2, 0.6, 0.9], light: [1.0, 0.95, 0.85], decor: .toybox, fog: 0.003)),
        CinemaRoom(id: 11, name: "Mystery Vault", is3D: true, eraStart: 2000, eraEnd: nil,
                   primaryTerms: ["mystery", "thriller", "crime"], relatedTerms: ["drama", "horror", "suspense"],
                   blurb: "Art-deco vault of mysteries, thrillers and investigations.",
                   theme: RoomTheme(wall: [0.05, 0.12, 0.12], accent: [0.8, 0.7, 0.4], carpet: [0.04, 0.08, 0.08], seat: [0.1, 0.22, 0.22], light: [0.9, 0.85, 0.6], decor: .noir, fog: 0.018)),
        CinemaRoom(id: 12, name: "Premiere Palace", is3D: true, eraStart: 2000, eraEnd: nil,
                   primaryTerms: [], relatedTerms: [],
                   blurb: "Red-carpet flagship for premieres, features and special events.",
                   theme: RoomTheme(wall: [0.2, 0.03, 0.04], accent: [1.0, 0.82, 0.35], carpet: [0.45, 0.03, 0.05], seat: [0.12, 0.1, 0.1], light: [1.0, 0.88, 0.6], decor: .premiere, fog: 0.008)),
    ]

    static func room(_ id: Int) -> CinemaRoom { all[max(0, min(11, id - 1))] }

    /// Picks the auditorium for a private screening of any library title.
    static func bestRoom(for item: MediaItem, seriesGenresFrom series: MediaItem? = nil) -> CinemaRoom {
        var probe = item
        if let series, probe.genres.isEmpty { probe.genres = series.genres; probe.tags = series.tags; probe.studios = series.studios }
        if probe.year == nil { probe.year = series?.year }
        if let y = probe.year, y < 2000 { return room(1) }
        let ordered = all.filter { $0.id != 1 && $0.id != 12 }
        if let r = ordered.first(where: { $0.primaryMatch(probe) }) { return r }
        if let r = ordered.first(where: { $0.relatedMatch(probe) }) { return r }
        return room(12)
    }
}

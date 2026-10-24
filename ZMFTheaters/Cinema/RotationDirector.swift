import Foundation
import Combine

/// Deterministic SplitMix64 so a given (seed, rotation index) always produces
/// the same programme — useful for tests and for re-deriving lost state.
struct SeededRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

struct Rotation: Codable, Hashable {
    var index: Int
    var start: Date
    var end: Date
    /// roomId (string) -> MediaItem.id
    var assignments: [String: String]
    /// roomId (string) -> how the title was chosen (fallback level)
    var notes: [String: String]
    var generatedAt: Date

    func mediaId(for room: Int) -> String? { assignments[String(room)] }
}

/// The automated programming director: twelve featured films, one per room,
/// replaced every `rotationDays` days (default 3) measured from a fixed anchor.
@MainActor
final class RotationDirector: ObservableObject {
    struct State: Codable {
        var current: Rotation?
        var history: [Rotation] = []
    }

    @Published private(set) var state: State
    private let store: JSONStore

    init(store: JSONStore = .shared) {
        self.store = store
        self.state = store.load(State.self, "rotation") ?? State()
    }

    var current: Rotation? { state.current }

    static func periodIndex(now: Date, settings: AppSettings) -> Int {
        let length = Double(max(1, settings.rotationDays)) * 86_400
        return Int(floor(now.timeIntervalSince(settings.rotationAnchor) / length))
    }

    static func periodBounds(index: Int, settings: AppSettings) -> (Date, Date) {
        let length = Double(max(1, settings.rotationDays)) * 86_400
        let start = settings.rotationAnchor.addingTimeInterval(Double(index) * length)
        return (start, start.addingTimeInterval(length))
    }

    /// Restores or generates the rotation for "now". Keeps the stored rotation
    /// stable inside its interval; if the catalog is empty (servers offline) the
    /// last valid rotation is retained.
    func ensureCurrent(now: Date = Date(), catalog: [MediaItem], settings: AppSettings, force: Bool = false) {
        let idx = Self.periodIndex(now: now, settings: settings)
        if !force, let cur = state.current {
            if !settings.rotationEnabled { return }
            if cur.index == idx && !cur.assignments.isEmpty { return }
        }
        let movies = catalog.filter { $0.kind == .movie }
        guard !movies.isEmpty else { return }

        let recent = ([state.current] + state.history.map { Optional($0) })
            .compactMap { $0 }
            .filter { $0.index != idx }
            .map { Array($0.assignments.values) }
        let (assign, notes) = Self.select(candidates: movies, index: idx, settings: settings, recent: recent)
        let (start, end) = Self.periodBounds(index: idx, settings: settings)
        let rotation = Rotation(index: idx, start: start, end: end, assignments: assign, notes: notes, generatedAt: now)

        if let old = state.current, old.index != idx {
            state.history.insert(old, at: 0)
            if state.history.count > 30 { state.history.removeLast(state.history.count - 30) }
        }
        state.current = rotation
        store.save(state, "rotation")
    }

    /// Rooms are filled from the most restrictive to the most permissive so
    /// scarce genres claim their titles before the catch-all rooms do.
    static let fillOrder = [1, 7, 5, 4, 10, 8, 9, 11, 6, 2, 3, 12]

    /// Pure selection function (unit tested). Fallback hierarchy per room:
    ///  1. primary genre, correct era, outside the repeat cooldown
    ///  2. primary genre, correct era, not in the previous rotation
    ///  3. related genre, correct era, not in the previous rotation
    ///  4. any genre, correct era, not in the previous rotation
    ///  5. primary genre or era match, repeats from the previous rotation allowed
    ///  6. correct era even if already used by another room this rotation
    /// The era rule is never relaxed, so Room 01 only ever shows 1900–1999 films.
    static func select(candidates: [MediaItem], index: Int, settings: AppSettings, recent: [[String]]) -> ([String: String], [String: String]) {
        var rng = SeededRNG(seed: settings.rotationSeed ^ (UInt64(bitPattern: Int64(index)) &* 0x2545_F491_4F6C_DD1D))
        let excluded = Set(settings.excludedMediaIds)
        let excludedLibs = Set(settings.excludedLibraryIds)
        let pool = candidates
            .filter { !excluded.contains($0.id) && !excludedLibs.contains($0.libraryId ?? "") }
            .sorted { $0.id < $1.id } // stable order before seeded shuffling
        let previous = Set(recent.first ?? [])
        let cooldown = Set(recent.prefix(max(1, settings.repeatCooldownRotations)).flatMap { $0 })
        let preferred = settings.preferredGenres.map { $0.lowercased() }

        var used = Set<String>()
        var assign: [String: String] = [:]
        var notes: [String: String] = [:]

        func pick(_ list: [MediaItem]) -> MediaItem? {
            guard !list.isEmpty else { return nil }
            let weights = list.map { item -> Int in
                preferred.isEmpty ? 1 : (item.classificationTerms.contains { t in preferred.contains { t.contains($0) } } ? 3 : 1)
            }
            let total = weights.reduce(0, +)
            var roll = Int(rng.next() % UInt64(total))
            for (i, w) in weights.enumerated() {
                if roll < w { return list[i] }
                roll -= w
            }
            return list.last
        }

        for roomId in fillOrder {
            let room = CinemaRooms.room(roomId)
            let key = String(roomId)
            if let o = settings.featuredOverrides[key], let item = pool.first(where: { $0.id == o }) {
                assign[key] = item.id; used.insert(item.id); notes[key] = "Owner override"
                continue
            }
            let era = pool.filter { room.eraAllows($0) }
            let levels: [(String, [MediaItem])] = [
                ("Genre match", era.filter { room.primaryMatch($0) && !cooldown.contains($0.id) && !used.contains($0.id) }),
                ("Genre match (cooldown relaxed)", era.filter { room.primaryMatch($0) && !previous.contains($0.id) && !used.contains($0.id) }),
                ("Related genre fallback", era.filter { room.relatedMatch($0) && !previous.contains($0.id) && !used.contains($0.id) }),
                ("Era fallback", era.filter { !previous.contains($0.id) && !used.contains($0.id) }),
                ("Repeat allowed (limited library)", era.filter { !used.contains($0.id) }),
                ("Shared with another room (limited library)", era),
            ]
            for (label, list) in levels {
                if let chosen = pick(list) {
                    assign[key] = chosen.id; used.insert(chosen.id); notes[key] = label
                    break
                }
            }
            if assign[key] == nil { notes[key] = "No eligible title in connected libraries" }
        }
        return (assign, notes)
    }
}

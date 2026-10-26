import Foundation
import simd

/// ZMF ORIGINAL FORMAT: BeyondScreen 4DX
/// Visual scene extensions are procedurally authored on the iPhone. They are
/// not claims to reconstruct copyrighted actors, real film sets or spoken
/// dialogue from movie frames. The movie on the screen remains untouched.
enum BeyondScene: String, Codable, CaseIterable, Identifiable {
    case underwater, helicopter, enchanted, romance, haunted, cosmic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .underwater: return "UNDERWATER"
        case .helicopter: return "HELICOPTER / FOREST"
        case .enchanted: return "MAGIC FOREST"
        case .romance: return "ROMANCE"
        case .haunted: return "HAUNTED"
        case .cosmic: return "COSMIC"
        }
    }
    var symbol: String {
        switch self {
        case .underwater: return "water.waves"
        case .helicopter: return "wind"
        case .enchanted: return "sparkles"
        case .romance: return "heart"
        case .haunted: return "moon.stars"
        case .cosmic: return "sparkle"
        }
    }
    var accent: Vec4 {
        switch self {
        case .underwater: return Vec4(0.10, 0.7, 0.95, 1)
        case .helicopter: return Vec4(0.33, 0.85, 0.46, 1)
        case .enchanted: return Vec4(0.6, 0.45, 1.0, 1)
        case .romance: return Vec4(1.0, 0.38, 0.58, 1)
        case .haunted: return Vec4(0.50, 0.58, 0.77, 1)
        case .cosmic: return Vec4(0.25, 0.65, 1.0, 1)
        }
    }
}

enum BeyondGenre: String, CaseIterable {
    case romance, action, horror, fantasy, scienceFiction, adventure, calm

    static func classify(_ genres: [String], title: String = "") -> BeyondGenre {
        let text = (genres + [title]).joined(separator: " ").lowercased()
        if text.contains("horror") || text.contains("slasher") { return .horror }
        if text.contains("romance") || text.contains("romantic") { return .romance }
        if text.contains("fantasy") || text.contains("magic") { return .fantasy }
        if text.contains("science fiction") || text.contains("sci-fi") || text.contains("space") { return .scienceFiction }
        if text.contains("action") || text.contains("war") || text.contains("thriller") { return .action }
        if text.contains("adventure") { return .adventure }
        return .calm
    }

    var baseScene: BeyondScene {
        switch self {
        case .romance: return .romance
        case .action: return .helicopter
        case .horror: return .haunted
        case .fantasy: return .enchanted
        case .scienceFiction: return .cosmic
        case .adventure: return .underwater
        case .calm: return .enchanted
        }
    }
    /// Deliberate genre limits; no uncontrolled spikes or real chair control.
    var motionScale: Float {
        switch self {
        case .romance: return 0.34
        case .action: return 1.0
        case .horror: return 0.77
        case .fantasy: return 0.59
        case .scienceFiction: return 0.74
        case .adventure: return 0.82
        case .calm: return 0.27
        }
    }
    var responseRate: Float {
        switch self {
        case .romance, .calm: return 2.2
        case .horror: return 7.2
        case .action: return 6.5
        default: return 4.3
        }
    }
}

enum BeyondScreen {
    /// Override is saved per owned media ID; changing a scene never alters the
    /// video, its subtitle timing, original soundtrack or streaming rules.
    static func scene(mediaID: String?, genres: [String], title: String,
                      overrides: [String: BeyondScene]) -> BeyondScene {
        if let mediaID, let forced = overrides[mediaID] { return forced }
        return BeyondGenre.classify(genres, title: title).baseScene
    }

    /// Lightweight deterministic authored particles and prop placement.
    /// O(1) memory, no paid cloud inference or network requests.
    @inline(__always) static func hash(_ x: Float) -> Float {
        let n = sinf(x * 12.9898 + 78.233) * 43758.5453
        return n - floorf(n)
    }

    static func ambience(scene: BeyondScene, activity: Float, time: Float) -> (density: Float, drift: Float) {
        let a = max(0, min(1, activity))
        let density: Float
        switch scene {
        case .underwater: density = 0.85
        case .helicopter: density = 0.75 + a * 0.15
        case .enchanted: density = 0.6
        case .romance: density = 0.34
        case .haunted: density = 0.64
        case .cosmic: density = 0.55
        }
        return (density, 0.4 + sinf(time * 0.25) * 0.15)
    }
}

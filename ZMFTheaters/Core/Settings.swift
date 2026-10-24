import Foundation
import Combine

enum GraphicsQuality: String, Codable, CaseIterable, Identifiable {
    case battery, balanced, cinematic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .battery: return "Battery Saver (30 FPS)"
        case .balanced: return "Balanced"
        case .cinematic: return "Cinematic"
        }
    }
}

/// Every owner-tunable setting. Persisted as one JSON document.
struct AppSettings: Codable, Equatable {
    // MARK: Rotation director
    var rotationEnabled = true
    var rotationDays = 3
    /// Rotation periods are counted from this instant using wall-clock time,
    /// so the right rotation is restored even after the app was closed for weeks.
    var rotationAnchor: Date = AppSettings.defaultAnchor
    var rotationSeed: UInt64 = 2026
    var repeatCooldownRotations = 4
    var preferredGenres: [String] = []
    var excludedMediaIds: [String] = []
    var excludedLibraryIds: [String] = []
    /// roomId (as string) -> MediaItem.id
    var featuredOverrides: [String: String] = [:]

    // MARK: Showtimes
    var timeZoneId = "America/New_York"
    var openingHour = 10
    /// Hours after midnight of the opening day; 25 = 1 AM next day.
    var closingHour = 25
    var cleanupMinutes = 20

    // MARK: Preshow
    var preshowEnabled = true
    var welcomeSeconds = 15
    var maxTrailers = 3
    var introSeconds = 12
    var countdownSeconds = 10

    // MARK: Economy (fictional Z$ only)
    var standardPrice = 150
    var threeDPrice = 225
    var vipPrice = 350
    var popcornPrice = 35
    var sodaPrice = 25
    var candyPrice = 20
    var weeklyReward = 3000
    var dailyBonus = 100
    var unlimitedCash = false

    // MARK: Admin
    var allDoorsUnlocked = false

    // MARK: Graphics
    var graphicsQuality: GraphicsQuality = .balanced
    var fogEnabled = true
    var screenBrightness: Double = 1.0

    // MARK: Controls
    var joystickSize: Double = 140
    var lookSensitivity: Double = 1.0
    var swapControls = false
    /// Hide every on-screen control while seated during a screening; tap to show.
    var autoHideControls = true
    var seatedFieldOfView: Double = 55
    var bloomStrength: Double = 0.6
    var projectorBeam = true
    var filmGrain = true

    // MARK: Playback
    var maxBitrateMbps = 60
    var autoplayNextEpisode = true
    var intermissionSeconds = 20
    var preferredSubtitleLanguage = ""

    static var defaultAnchor: Date {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 23; c.hour = 0
        c.timeZone = TimeZone(identifier: "America/New_York")
        return Calendar(identifier: .gregorian).date(from: c) ?? Date(timeIntervalSince1970: 1_792_728_000)
    }

    var timeZone: TimeZone { TimeZone(identifier: timeZoneId) ?? .current }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var settings: AppSettings {
        didSet { if settings != oldValue { store.save(settings, "settings") } }
    }
    private let store: JSONStore

    init(store: JSONStore = .shared) {
        self.store = store
        self.settings = store.loadMerged(AppSettings(), "settings")
    }
}

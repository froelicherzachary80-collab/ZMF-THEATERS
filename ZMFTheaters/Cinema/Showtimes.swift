import Foundation

struct Showtime: Identifiable, Hashable {
    var roomId: Int
    var preshowStart: Date
    var featureStart: Date
    var end: Date
    var id: String { "\(roomId)-\(Int(preshowStart.timeIntervalSince1970))" }
}

/// Generates each room's independent daily schedule on a simulated real-world
/// clock in the owner's time zone (default America/New_York).
enum ShowtimeScheduler {
    static func preshowMinutes(_ s: AppSettings) -> Int { s.preshowEnabled ? 10 : 0 }

    static func showtimes(roomId: Int, runtimeMinutes: Int?, day: Date, settings: AppSettings) -> [Showtime] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = settings.timeZone
        let midnight = cal.startOfDay(for: day)
        let runtime = max(30, runtimeMinutes ?? 120)
        let pre = preshowMinutes(settings)
        let raw = pre + runtime + max(0, settings.cleanupMinutes)
        let cycle = Int((Double(raw) / 15).rounded(.up)) * 15
        // Stagger rooms by 15 minutes so start times spread across the hour.
        let offset = ((roomId - 1) % 4) * 15
        var t = midnight.addingTimeInterval(TimeInterval((settings.openingHour * 60 + offset) * 60))
        let closing = midnight.addingTimeInterval(TimeInterval(settings.closingHour * 3600))
        var out: [Showtime] = []
        while t < closing {
            let feature = t.addingTimeInterval(TimeInterval(pre * 60))
            out.append(Showtime(roomId: roomId, preshowStart: t, featureStart: feature, end: feature.addingTimeInterval(TimeInterval(runtime * 60))))
            t = t.addingTimeInterval(TimeInterval(cycle * 60))
        }
        return out
    }

    /// Next showings whose preshow has not yet started, spanning today and tomorrow.
    static func upcoming(roomId: Int, runtimeMinutes: Int?, now: Date = Date(), settings: AppSettings, limit: Int = 6) -> [Showtime] {
        let yesterday = now.addingTimeInterval(-86_400)
        let tomorrow = now.addingTimeInterval(86_400)
        let all = [yesterday, now, tomorrow].flatMap { showtimes(roomId: roomId, runtimeMinutes: runtimeMinutes, day: $0, settings: settings) }
        return Array(all.filter { $0.preshowStart >= now }.sorted { $0.preshowStart < $1.preshowStart }.prefix(limit))
    }

    static func timeFormatter(_ s: AppSettings) -> DateFormatter {
        let f = DateFormatter()
        f.timeZone = s.timeZone
        f.dateFormat = "EEE h:mm a"
        return f
    }
}

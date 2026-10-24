import Foundation

/// Device-local JSON persistence in Application Support. Every store (servers,
/// catalog, rotation, wallet, settings) is a small Codable document, written
/// atomically so a crash never leaves a half-written file.
final class JSONStore {
    static let shared = JSONStore()

    let directory: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(directory: URL? = nil) {
        if let directory {
            self.directory = directory
        } else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = base.appendingPathComponent("ZMFTheaters", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    func load<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        let url = directory.appendingPathComponent(name + ".json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decoder.decode(T.self, from: data)
    }

    /// Loads a document and fills any keys missing from older saves with the
    /// defaults, so adding a new setting never wipes the owner's configuration.
    func loadMerged<T: Codable>(_ defaults: T, _ name: String) -> T {
        let url = directory.appendingPathComponent(name + ".json")
        guard let data = try? Data(contentsOf: url) else { return defaults }
        if let direct = try? decoder.decode(T.self, from: data) { return direct }
        guard let saved = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let baseData = try? encoder.encode(defaults),
              var base = (try? JSONSerialization.jsonObject(with: baseData)) as? [String: Any] else { return defaults }
        for (k, v) in saved where base[k] != nil { base[k] = v }
        guard let merged = try? JSONSerialization.data(withJSONObject: base),
              let value = try? decoder.decode(T.self, from: merged) else { return defaults }
        return value
    }

    func save<T: Encodable>(_ value: T, _ name: String) {
        let url = directory.appendingPathComponent(name + ".json")
        guard let data = try? encoder.encode(value) else { return }
        try? data.write(to: url, options: .atomic)
    }

    /// Folder (visible in the Files app) where the owner drops permitted trailers.
    static var trailersDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = docs.appendingPathComponent("Trailers", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}

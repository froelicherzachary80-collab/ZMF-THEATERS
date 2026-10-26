import Foundation
import Combine
import Vision
import CoreVideo

/// A throttled on-device semantic hint engine for owned/local/Jellyfin frames.
/// No frames are uploaded or generated. The movie's real actors and sets are
/// not reconstructed; the labels choose an original procedural world preset.
@MainActor
final class BeyondSceneDirector: ObservableObject {
    @Published private(set) var detectedScene: BeyondScene = .cosmic
    @Published private(set) var genre: BeyondGenre = .calm
    @Published private(set) var evidence = "Genre-based environment"
    @Published private(set) var confidence: Float = 0
    @Published private(set) var recognizedCount = 0
    @Published var sceneOverride: BeyondScene?
    @Published var detectionEnabled = true
    @Published var charactersEnabled = true
    @Published var environmentIntensity: Double = 0.8
    @Published var motionEnabled = true

    var scene: BeyondScene { sceneOverride ?? detectedScene }
    private var currentMedia = ""
    private var lastAnalyze = -10.0
    private var lastChange = -10.0
    private var processing = false
    private var proposedScene: BeyondScene?
    private var confirmations = 0
    private var revision = 0

    func begin(id: String, genres: [String], title: String, overrides: [String: BeyondScene]) {
        guard currentMedia != id else { return }
        currentMedia = id
        revision += 1
        genre = BeyondGenre.classify(genres, title: title)
        detectedScene = genre.baseScene
        sceneOverride = overrides[id]
        evidence = "Genre: \(genre.rawValue)"
        confidence = 0
        recognizedCount = 0
        lastAnalyze = -10
        lastChange = -10
        processing = false
        confirmations = 0
        proposedScene = nil
    }

    func reset() {
        currentMedia = ""
        revision += 1
        processing = false
        sceneOverride = nil
        proposedScene = nil
        confirmations = 0
        evidence = "Scene director idle"
    }

    func select(_ value: BeyondScene?) {
        sceneOverride = value
        evidence = value == nil ? "Automatic scene selection" : "Hand-picked: \(value!.label)"
    }

    /// At most one classification every two seconds, with hysteresis to
    /// avoid flickering worlds on every edit. This never handles YouTube video.
    func analyze(pixelBuffer: CVPixelBuffer, seconds: Double) {
        guard detectionEnabled, sceneOverride == nil, !currentMedia.isEmpty,
              !processing, seconds.isFinite, seconds >= 0,
              seconds - lastAnalyze >= 2.0 else { return }
        processing = true
        lastAnalyze = seconds
        let run = revision
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let request = VNClassifyImageRequest()
            do {
                try VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:]).perform([request])
                let labels: [(String, Float)] = (request.results ?? []).prefix(24).map {
                    ($0.identifier.lowercased(), $0.confidence)
                }
                Task { @MainActor [weak self] in
                    guard let self, self.revision == run else { return }
                    self.processing = false
                    self.accept(labels: labels, seconds: seconds)
                }
            } catch {
                Task { @MainActor [weak self] in
                    guard let self, self.revision == run else { return }
                    self.processing = false
                    self.evidence = "Vision unavailable; genre fallback active"
                }
            }
        }
    }

    private func accept(labels: [(String, Float)], seconds: Double) {
        guard detectionEnabled, sceneOverride == nil,
              let (world, conf, label) = Self.classify(labels) else { return }
        if proposedScene == world { confirmations += 1 }
        else { proposedScene = world; confirmations = 1 }
        guard confirmations >= 2, seconds - lastChange >= 4 else { return }
        if world != detectedScene {
            detectedScene = world
            lastChange = seconds
            recognizedCount += 1
        }
        confidence = conf
        evidence = "On-device Vision: \(label), \(Int(conf * 100))% confidence"
    }

    static func classify(_ labels: [(String, Float)]) -> (BeyondScene, Float, String)? {
        let rules: [(BeyondScene, [String])] = [
            (.underwater, ["underwater","sea","ocean","coral","reef","aquarium","scuba","whale","diving"]),
            (.helicopter, ["helicopter","aircraft","airplane","aerial","skydiving","mountain"]),
            (.enchanted, ["forest","woodland","tree","foliage","garden","jungle","flower"]),
            (.cosmic, ["astronaut","galaxy","outer space","planet","cosmos","spacecraft"]),
            (.haunted, ["cemetery","graveyard","haunted","castle","dungeon","cave"]),
            (.romance, ["wedding","flowers","bouquet","sunset","couple","candle"])
        ]
        for (text, confidence) in labels where confidence >= 0.12 {
            if let found = rules.first(where: { $0.1.contains(where: { text.contains($0) }) }) {
                return (found.0, confidence, text)
            }
        }
        return nil
    }
}

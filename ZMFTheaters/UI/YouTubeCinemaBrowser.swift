import Foundation
import SwiftUI
import WebKit
import UIKit

/// These modes drive original, local virtual-environment motion, not the
/// YouTube audiovisual stream. YouTube player/ads/controls are left intact.
enum YouTubeMotionPreset: String, Codable, CaseIterable, Identifiable {
    case off, edits, concert, minecraft, cinematic
    var id: String { rawValue }
    var label: String {
        switch self {
        case .off: return "Off"
        case .edits: return "Edits"
        case .concert: return "Concert"
        case .minecraft: return "Minecraft"
        case .cinematic: return "Cinema"
        }
    }
}

@MainActor
final class YouTubeCinemaSession: ObservableObject {
    @Published private(set) var video: PreshowYouTubeTrailer?
    @Published private(set) var playing = false
    @Published private(set) var seconds: Double = 0
    private var clockSyncUptime = ProcessInfo.processInfo.systemUptime
    var playbackTime: Double {
        guard playing else { return seconds }
        // Interpolate between official YouTube player position callbacks.
        // At most 0.5s extrapolation so buffering does not drive seat for long.
        return seconds + min(0.5, max(0, ProcessInfo.processInfo.systemUptime - clockSyncUptime))
    }
    @Published var error: String?
    @Published var preset: YouTubeMotionPreset = .edits
    @Published var bpm: Double = 120
    @Published private(set) var cutMarks: [Double] = []

    var isOpen: Bool { video != nil }
    var videoID: String? { video?.videoID }
    var hasVideo: Bool { video != nil }

    func open(videoID: String, title: String, preset: YouTubeMotionPreset, bpm: Double, cuts: [Double]) {
        guard videoID.count == 11,
              PreshowYouTubeTrailer.videoID(from: "https://youtu.be/" + videoID) == videoID else { return }
        self.video = PreshowYouTubeTrailer(title: String(title.prefix(120)), videoID: videoID, presentation: .fourDX)
        self.preset = preset
        self.bpm = min(200, max(60, bpm.isFinite ? bpm : 120))
        self.cutMarks = Array(Set(cuts.filter { $0.isFinite && $0 >= 0 })).sorted().prefix(1500).map { $0 }
        seconds = 0
        clockSyncUptime = ProcessInfo.processInfo.systemUptime
        playing = false
        error = nil
    }

    func receive(playing: Bool, seconds: Double) {
        guard video != nil else { return }
        self.playing = playing
        if seconds.isFinite { self.seconds = max(0, seconds) }
        clockSyncUptime = ProcessInfo.processInfo.systemUptime
    }

    func recordCut() -> [Double] {
        guard video != nil, playing, seconds.isFinite else { return cutMarks }
        let now = playbackTime
        if !cutMarks.contains(where: { abs($0 - now) < 0.15 }) {
            cutMarks.append(now)
            cutMarks.sort()
            if cutMarks.count > 1500 { cutMarks.removeFirst() }
        }
        return cutMarks
    }

    func clearCuts() { cutMarks = [] }

    func close() {
        video = nil
        playing = false
        seconds = 0
        error = nil
        cutMarks.removeAll()
    }
}

/// Free in-app browser uses the public YouTube website; no YouTube Data API
/// key, scraper, download proxy, subscription bypass or external service.
@MainActor
final class YouTubeBrowserController: ObservableObject {
    @Published var address = "https://m.youtube.com"
    @Published var pageTitle = "YouTube"
    @Published var canBack = false
    @Published var loading = false
    @Published var message: String?
    weak var webView: WKWebView?

    func goHome() { open(URL(string: "https://m.youtube.com")!) }

    func search(_ term: String) {
        let query = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        if let id = PreshowYouTubeTrailer.videoID(from: query) {
            open(URL(string: "https://www.youtube.com/watch?v=" + id)!)
            return
        }
        var parts = URLComponents(string: "https://m.youtube.com/results")!
        parts.queryItems = [URLQueryItem(name: "search_query", value: String(query.prefix(200)))]
        if let url = parts.url { open(url) }
    }

    func open(_ url: URL) {
        guard url.scheme == "https" else { return }
        message = nil
        webView?.load(URLRequest(url: url))
    }

    func back() { if webView?.canGoBack == true { webView?.goBack() } }

    func watchCurrent(_ completion: @escaping (String, String) -> Void) {
        guard let webView else { message = "Browser not ready."; return }
        // YouTube is a single-page app: reading location on tap reliably
        // handles internal client-side navigation that WK delegates may miss.
        webView.evaluateJavaScript("window.location.href") { [weak self, weak webView] result, _ in
            Task { @MainActor in
                guard let self else { return }
                let raw = result as? String ?? webView?.url?.absoluteString ?? ""
                guard let id = PreshowYouTubeTrailer.videoID(from: raw) else {
                    self.message = "Open a YouTube video, Short, or livestream first, then choose Watch in Cinema."
                    return
                }
                completion(id, webView?.title ?? "YouTube video")
            }
        }
    }

    func updateURL(_ webView: WKWebView) {
        if let url = webView.url { address = url.absoluteString }
        pageTitle = webView.title ?? "YouTube"
        canBack = webView.canGoBack
        loading = webView.isLoading
    }
}

struct YouTubeWebsiteView: UIViewRepresentable {
    @ObservedObject var controller: YouTubeBrowserController

    func makeCoordinator() -> Coordinator { Coordinator(controller: controller) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default() // retain website history/cookies
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        let web = WKWebView(frame: .zero, configuration: config)
        web.allowsBackForwardNavigationGestures = true
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.scrollView.contentInsetAdjustmentBehavior = .never
        controller.webView = web
        web.load(URLRequest(url: URL(string: "https://m.youtube.com")!))
        return web
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    static func dismantleUIView(_ webView: WKWebView, coordinator: Coordinator) {
        webView.stopLoading()
        webView.loadHTMLString("", baseURL: nil)
        coordinator.controller.webView = nil
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        let controller: YouTubeBrowserController
        init(controller: YouTubeBrowserController) { self.controller = controller }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            controller.updateURL(webView)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            controller.updateURL(webView)
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            controller.loading = false
            controller.message = error.localizedDescription
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            controller.loading = false
            controller.message = "YouTube could not load: " + error.localizedDescription
        }

        // Normal browser hyperlinks/new tabs keep working.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let url = navigationAction.request.url {
                if url.scheme == "https", let host = url.host?.lowercased(),
                   (host == "youtube.com" || host.hasSuffix(".youtube.com") ||
                    host == "youtu.be" || host.hasSuffix(".youtu.be")) {
                    webView.load(URLRequest(url: url))
                } else {
                    UIApplication.shared.open(url)
                }
            }
            return nil
        }
    }
}

struct YouTubeBrowserView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = YouTubeBrowserController()
    @State private var query = ""

    private let suggested = [
        ("Edits", "2026 fan edits 4K"),
        ("Concerts", "live concert performances"),
        ("Minecraft", "Minecraft survival SMP"),
        ("Gaming", "gaming cinematic highlights")
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Search YouTube or paste a video link", text: $query)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.search)
                        .onSubmit { browser.search(query) }
                    Button { browser.search(query) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderedProminent)
                    Button { browser.back() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!browser.canBack)
                    Button { browser.goHome() } label: { Image(systemName: "house") }
                }.padding(.horizontal, 10).padding(.top, 4)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(suggested.indices, id: \.self) { index in
                            let item = suggested[index]
                            Button(item.0) {
                                query = item.1
                                browser.search(item.1)
                            }.buttonStyle(.bordered)
                        }
                    }.padding(.horizontal, 10)
                }
                if browser.loading { ProgressView().controlSize(.small) }
                if let message = browser.message {
                    Text(message).font(.caption).foregroundStyle(.orange).padding(.horizontal)
                }
                YouTubeWebsiteView(controller: browser).background(.black)
                HStack(spacing: 10) {
                    Image(systemName: "globe").foregroundStyle(.secondary)
                    Text(browser.address).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        browser.watchCurrent { id, title in
                            model.startYouTubeCinema(videoID: id, title: title)
                            dismiss()
                        }
                    } label: {
                        Label("Watch in 4DX Cinema", systemImage: "theatermasks.fill")
                            .font(.caption.weight(.semibold))
                    }.buttonStyle(.borderedProminent).tint(.orange)
                }.padding(.horizontal, 12).padding(.vertical, 7)
            }
            .navigationTitle("YouTube Cinema Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// Official YouTube playback appears directly over the virtual auditorium
/// movie screen, with position recalculated from the seated camera. This is
/// screen-space WebKit composition, not extraction of restricted video frames.
/// The full theater stays visible around the movie screen.
struct YouTubeCinemaOverlay: View {
    @ObservedObject var cinema: YouTubeCinemaSession
    @EnvironmentObject var settingsStore: SettingsStore
    @EnvironmentObject var game: CinemaGame
    let onBrowse: () -> Void
    let onClose: () -> Void
    @State private var advancedControls = false
    @State private var toolbarVisible = true

    var body: some View {
        if let video = cinema.video {
            TimelineView(.periodic(from: .now, by: 1.0 / 24.0)) { _ in
                GeometryReader { geometry in
                    let size = geometry.size
                    let projected = CinemaScreenProjection.projectedRect(
                        game: game, viewport: size,
                        verticalFOV: Float(settingsStore.settings.seatedFieldOfView))
                    // Keep the WKWebView mounted across head movement, rather
                    // than reloading the YouTube video whenever we look away.
                    let rect = projected ?? CGRect(x: -1400, y: -1000, width: 40, height: 24)

                    ZStack(alignment: .bottom) {
                        // A black projection masking surface hides the previous
                        // movie title and "next showing" card during YouTube.
                        Rectangle()
                            .fill(.black)
                            .frame(width: rect.width + 4, height: rect.height + 4)
                            .position(x: rect.midX, y: rect.midY)
                            .allowsHitTesting(false)
                        YouTubePreshowPlayer(
                            trailer: video,
                            onStateChange: { isPlaying, seconds in
                                cinema.receive(playing: isPlaying, seconds: seconds)
                            },
                            onEnded: { cinema.receive(playing: false, seconds: cinema.seconds) },
                            onError: { cinema.error = $0 }
                        )
                        .id(video.videoID)
                        .frame(width: max(40, rect.width), height: max(24, rect.height))
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(projected != nil)

                        // Compact theater controls stay outside the projected
                        // screen; they disappear when the viewer chooses Hide.
                        if toolbarVisible {
                            VStack(spacing: 6) {
                                HStack(spacing: 9) {
                                    Image(systemName: "play.rectangle.fill").foregroundStyle(.red)
                                    Text(video.title).lineLimit(1)
                                        .font(.caption2.weight(.semibold))
                                    Text(cinema.preset == .off ? "2D" : "4DX")
                                        .font(.caption2.bold()).foregroundStyle(.cyan)
                                    Spacer(minLength: 6)
                                    Button { game.recenterCinemaScreen() } label: {
                                        Label("CENTER", systemImage: "viewfinder")
                                    }.accessibilityLabel("Recenter the movie screen")
                                    Button { advancedControls.toggle() } label: {
                                        Image(systemName: "slider.horizontal.3")
                                    }.accessibilityLabel("4DX settings")
                                    Button(action: onBrowse) {
                                        Image(systemName: "magnifyingglass")
                                    }.accessibilityLabel("Browse YouTube")
                                    Button(action: onClose) {
                                        Image(systemName: "xmark.circle.fill")
                                    }.accessibilityLabel("Close YouTube")
                                }
                                .font(.caption2.bold())
                                .buttonStyle(.borderless)

                                HStack(spacing: 8) {
                                    Picker("Mode", selection: $cinema.preset) {
                                        ForEach(YouTubeMotionPreset.allCases) { mode in
                                            Text(mode.label).tag(mode)
                                        }
                                    }
                                    .pickerStyle(.menu)
                                    .onChange(of: cinema.preset) { _, mode in
                                        settingsStore.settings.youtubeCinemaPreset = mode
                                    }
                                    Button {
                                        let cues = cinema.recordCut()
                                        if let id = cinema.videoID {
                                            settingsStore.settings.youtubeCueMarksByVideo[id] = cues
                                        }
                                    } label: {
                                        Label("MARK EDIT", systemImage: "waveform.path")
                                    }
                                    .disabled(!cinema.playing)
                                    Button {
                                        toolbarVisible = false
                                    } label: {
                                        Label("HIDE", systemImage: "eye.slash")
                                    }
                                    Spacer(minLength: 1)
                                    Text("\(Int(cinema.bpm)) BPM · \(cinema.cutMarks.count) cues")
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(.white.opacity(0.7))
                                }
                                .font(.caption2)
                                .buttonStyle(.borderless)
                                if advancedControls {
                                    HStack(spacing: 10) {
                                        Text("Rhythm")
                                        Slider(value: $cinema.bpm, in: 60...200, step: 5)
                                            .onChange(of: cinema.bpm) { _, next in
                                                settingsStore.settings.youtubeCinemaBPM = next
                                            }
                                        Button("Clear marks", role: .destructive) {
                                            cinema.clearCuts()
                                            if let id = cinema.videoID {
                                                settingsStore.settings.youtubeCueMarksByVideo[id] = []
                                            }
                                        }
                                    }.font(.caption2)
                                }
                                if let error = cinema.error {
                                    Text(error).font(.caption2).foregroundStyle(.orange)
                                }
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 11))
                            .frame(maxWidth: min(size.width - 45, 870))
                            .padding(.bottom, 38)
                            .transition(.opacity)
                        } else {
                            HStack {
                                Button {
                                    toolbarVisible = true
                                } label: {
                                    Label("4DX CONTROLS", systemImage: "slider.horizontal.3")
                                        .font(.caption2.bold())
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 11)
                                        .padding(.vertical, 7)
                                        .background(.black.opacity(0.55), in: Capsule())
                                }
                                Spacer()
                            }
                            .padding(.leading, 14)
                            .padding(.bottom, 39)
                        }
                    }
                    .frame(width: size.width, height: size.height)
                }
            }
            .zIndex(10)
        }
    }
}

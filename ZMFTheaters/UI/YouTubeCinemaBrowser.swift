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
    /// 2D / 3D / 4DX / 4DX + 3D for this YouTube screening.
    @Published var format: TrailerPresentation = .fourDX
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

/// The YouTube iframe remains visible and unmodified. The original ZMF
/// cinematic environment and synchronized *virtual seat* run behind it.
struct YouTubeCinemaOverlay: View {
    @ObservedObject var cinema: YouTubeCinemaSession
    var renderer: Renderer?
    @EnvironmentObject var settingsStore: SettingsStore
    let onBrowse: () -> Void
    let onClose: () -> Void
    @State private var advancedControls = false

    var body: some View {
        if let video = cinema.video {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                VStack(spacing: 8) {
                    HStack(spacing: 10) {
                        Label("YOUTUBE • ZMF CINEMA", systemImage: "play.rectangle.fill")
                            .font(.caption.bold()).foregroundStyle(.white)
                        Spacer()
                        Menu {
                            Picker("Format", selection: $cinema.format) {
                                ForEach(TrailerPresentation.allCases) { Text($0.label).tag($0) }
                            }
                        } label: {
                            Text(cinema.format.uses4DX && cinema.preset == .off ? (cinema.format.uses3D ? "3D" : "2D") : cinema.format.badge)
                                .font(.caption2.bold()).foregroundStyle(.cyan)
                        }
                        .accessibilityLabel("Presentation format")
                        Button { advancedControls.toggle() } label: { Image(systemName: "slider.horizontal.3") }
                            .accessibilityLabel("4DX motion settings")
                        Button(action: onBrowse) { Image(systemName: "magnifyingglass") }
                            .accessibilityLabel("Browse more videos")
                        Button(action: onClose) { Image(systemName: "xmark.circle.fill") }
                            .accessibilityLabel("Close YouTube cinema")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)

                    FourDXMotionStage(engine: renderer?.fourDX, enabled: cinema.format.uses4DX,
                                      showEffects: settingsStore.settings.fourDXScreenEffects) {
                        YouTubePreshowPlayer(trailer: video, stereo3D: cinema.format.uses3D,
                            onStateChange: { isPlaying, time in cinema.receive(playing: isPlaying, seconds: time) },
                            onEnded: { cinema.receive(playing: false, seconds: cinema.seconds) },
                            onError: { cinema.error = $0 }
                        )
                        .id(video.videoID)
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .layoutPriority(1)

                    if let error = cinema.error {
                        Text(error).font(.caption2).foregroundStyle(.orange)
                    }
                    HStack(spacing: 10) {
                        Picker("4DX", selection: $cinema.preset) {
                            ForEach(YouTubeMotionPreset.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: cinema.preset) { _, next in settingsStore.settings.youtubeCinemaPreset = next }
                        Button {
                            let cues = cinema.recordCut()
                            if let id = cinema.videoID { settingsStore.settings.youtubeCueMarksByVideo[id] = cues }
                        } label: {
                            Label("Mark edit", systemImage: "waveform.path")
                                .font(.caption2.bold())
                        }
                        .buttonStyle(.bordered)
                        .disabled(!cinema.playing)
                    }
                    if advancedControls {
                        HStack(spacing: 10) {
                            Text("Rhythm \(Int(cinema.bpm)) BPM").font(.caption2.bold())
                            Slider(value: $cinema.bpm, in: 60...200, step: 5)
                                .onChange(of: cinema.bpm) { _, next in settingsStore.settings.youtubeCinemaBPM = next }
                            Text("\(cinema.cutMarks.count) cuts").font(.caption2).monospacedDigit()
                            Button("Clear cuts", role: .destructive) {
                                cinema.clearCuts()
                                if let id = cinema.videoID { settingsStore.settings.youtubeCueMarksByVideo[id] = [] }
                            }.font(.caption2).disabled(cinema.cutMarks.isEmpty)
                        }
                    }
                    Text(cinema.format.uses3D ? "3D: wear red/cyan glasses (stereo window — YouTube pixels can't be depth-converted). 4DX follows the player clock + rhythm + your marked cuts (cuts also splash water). Tap Play." : "4DX uses the official player clock + selected rhythm + your marked cuts (cuts also splash water); it cannot detect actual edits or sounds inside YouTube videos. Tap Play in the player.")
                        .font(.caption2).foregroundStyle(.white.opacity(0.72)).lineLimit(2)
                }
                .padding(10)
                .background(.black.opacity(0.87), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(.cyan.opacity(0.25)))
                .frame(maxWidth: landscape ? min(geometry.size.width * 0.77, 1050) : geometry.size.width - 16,
                       maxHeight: geometry.size.height * 0.97)
                .position(x: geometry.size.width * 0.5, y: geometry.size.height * 0.49)
            }
            .zIndex(10)
        }
    }
}

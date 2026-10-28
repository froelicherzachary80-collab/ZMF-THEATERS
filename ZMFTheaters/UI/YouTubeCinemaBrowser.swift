import Foundation
import SwiftUI
import WebKit
import UIKit
import simd

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
    @Published private(set) var browserOpen = false
    @Published private(set) var projectedAddress = "https://m.youtube.com"
    @Published private(set) var projectionRevision = 0
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

    /// An active projection is *not* the dismissible YouTube browsing sheet.
    /// This keeps the cinema screen occupied while the HUD is hidden.
    var isOpen: Bool { browserOpen || video != nil }
    var videoID: String? { video?.videoID }
    var hasVideo: Bool { video != nil }

    func openBrowser(address: String? = nil) {
        if let address, let url = URL(string: address), url.scheme?.lowercased() == "https",
           let host = url.host?.lowercased(),
           (host == "youtube.com" || host.hasSuffix(".youtube.com") ||
            host == "youtu.be" || host == "www.youtu.be") {
            projectedAddress = url.absoluteString
        } else if !isOpen {
            projectedAddress = "https://m.youtube.com"
        }
        projectionRevision &+= 1
        browserOpen = true
        video = nil
        playing = false
        seconds = 0
        error = nil
    }

    func open(videoID: String, title: String, preset: YouTubeMotionPreset, bpm: Double, cuts: [Double]) {
        guard videoID.count == 11,
              PreshowYouTubeTrailer.videoID(from: "https://youtu.be/" + videoID) == videoID else { return }
        self.video = PreshowYouTubeTrailer(title: String(title.prefix(120)), videoID: videoID, presentation: .fourDX)
        browserOpen = false
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
        browserOpen = false
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
    var initialURL = "https://m.youtube.com"

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
        let url = URL(string: initialURL).flatMap { u -> URL? in
            guard u.scheme?.lowercased() == "https", let host = u.host?.lowercased(),
                  host == "youtube.com" || host.hasSuffix(".youtube.com") ||
                  host == "youtu.be" || host == "www.youtu.be" else { return nil }
            return u
        } ?? URL(string: "https://m.youtube.com")!
        web.load(URLRequest(url: url))
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
                        Label("Play on projector", systemImage: "theatermasks.fill")
                            .font(.caption.weight(.semibold))
                    }.buttonStyle(.borderedProminent).tint(.orange)
                }.padding(.horizontal, 12).padding(.vertical, 7)
            }
            .navigationTitle("YouTube Cinema Browser")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Project browser") {
                        // Closing the browser panel must NOT restore the old
                        // film-signage picture. Transfer the website to the
                        // persistent auditorium projector.
                        model.openYouTubeProjector(address: browser.address)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

/// Perspective-projects the actual, stationary auditorium screen into the
/// Metal camera viewport. There are no 4DX seat offsets on the *screen*
/// geometry; all virtual seat travel happens through the same camera used by
/// the Metal renderer. The projection is recomputed from the room screen's
/// WORLD coordinates, so the browser is no longer a head-locked floating card.
enum CinemaScreenAnchor {
    static func frame(room: Int, camera: CinemaGame.CameraState, fieldOfView: Float, viewport: CGSize) -> CGRect? {
        guard (1...12).contains(room), viewport.width > 1, viewport.height > 1,
              fieldOfView.isFinite && fieldOfView > 0.1 && fieldOfView < 3 else { return nil }
        let aspect = Float(viewport.width / viewport.height)
        let diff = camera.target - camera.eye
        guard simd_length_squared(diff) > 0.001 else { return nil }
        let projection = Mat4.perspective(fovyRadians: fieldOfView, aspect: aspect, near: 0.05, far: 160)
        let view = Mat4.lookAt(eye: camera.eye, target: camera.target, up: Vec3(0, 1, 0))
        let vp = projection * view
        let normal = CinemaWorld.screenNormal(room)
        let right = simd_normalize(simd_cross(-normal, Vec3(0, 1, 0)))
        // MeshBuilder uses a 0.35m screen curvature: mid-plane follows its
        // center instead of a drifting UI card. Keep a tiny black edge.
        let center = CinemaWorld.screenCenter(room) + normal * 0.17
        let w = CinemaWorld.screenSize.x * 0.485
        let h = CinemaWorld.screenSize.y * 0.485
        let up = Vec3(0, 1, 0)
        // Break SIMD arithmetic into explicitly typed terms for the Swift
        // compiler (large chained SIMD expressions can time out type-checking).
        let horizontalOffset: Vec3 = right * w
        let verticalOffset: Vec3 = up * h
        let leftCenter: Vec3 = center - horizontalOffset
        let rightCenter: Vec3 = center + horizontalOffset
        let topLeft: Vec3 = leftCenter + verticalOffset
        let topRight: Vec3 = rightCenter + verticalOffset
        let bottomLeft: Vec3 = leftCenter - verticalOffset
        let bottomRight: Vec3 = rightCenter - verticalOffset
        let corners: [Vec3] = [topLeft, topRight, bottomLeft, bottomRight]
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity
        var minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for point in corners {
            let clip = vp * Vec4(point.x, point.y, point.z, 1)
            // If a corner falls behind the near plane, do NOT stretch or
            // reposition the web browser to an unrelated area of the cinema.
            guard clip.w > 0.05, clip.x.isFinite, clip.y.isFinite else { return nil }
            let x = CGFloat((clip.x / clip.w + 1) * 0.5) * viewport.width
            let y = CGFloat((1 - clip.y / clip.w) * 0.5) * viewport.height
            guard x.isFinite, y.isFinite else { return nil }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
        let width = maxX - minX, height = maxY - minY
        guard width > 2, height > 2, width < 10000, height < 10000 else { return nil }
        return CGRect(x: minX, y: minY, width: width, height: height)
    }
}

/// The YouTube WKWebView is positioned over the auditorium's projected
/// physical screen plane. The video stays unmodified and interactive; only
/// the view's CGRect tracks perspective, independent of 4DX hit/rumble.
/// The on-screen particle layer is separate and never shakes the iframe.
struct CinemaScreenLockedPlayer<Content: View>: View {
    @EnvironmentObject private var game: CinemaGame
    let seatedFovDegrees: Double
    let engine: FourDXEngine?
    let fourDX: Bool
    let showEffects: Bool
    @ViewBuilder var content: Content

    var body: some View {
        GeometryReader { viewport in
            TimelineView(.animation(minimumInterval: 1.0 / 30)) { time in
                let camera = game.camera()
                let room: Int? = game.seatedAt?.room ?? {
                    if case .room(let id) = game.zone { return id }
                    return nil
                }()
                let fov = game.isSeated ? Float(seatedFovDegrees) * .pi / 180 : 1.1
                let rect = room.flatMap {
                    CinemaScreenAnchor.frame(room: $0, camera: camera, fieldOfView: fov, viewport: viewport.size)
                }
                let r = rect ?? CGRect(x: -10000, y: -10000, width: 16, height: 9)
                let live = fourDX && (engine?.running ?? false)
                let sample = live ? FourDXScreenSample(engine!) : FourDXScreenSample()
                content
                    .frame(width: r.width, height: r.height)
                    .background(.black)
                    .overlay {
                        if live && showEffects {
                            FourDXScreenCanvas(sample: sample, time: time.date.timeIntervalSinceReferenceDate)
                                .allowsHitTesting(false)
                        }
                    }
                    .clipped()
                    .position(x: r.midX, y: r.midY)
                    .opacity(rect == nil ? 0 : 1)
                    .accessibilityLabel("YouTube player anchored to the auditorium screen")
            }
            .frame(width: viewport.size.width, height: viewport.size.height)
        }
    }
}

/// The YouTube iframe remains visible and unmodified. The original ZMF
/// cinematic environment and synchronized *virtual seat* run behind it.
/// One projection surface shared by full YouTube browsing and video playback.
/// Only the theatre projector owns the WKWebView. The controls are tiny HUD
/// chrome outside the screen, never another closable floating TV window.
struct YouTubeCinemaOverlay: View {
    @ObservedObject var cinema: YouTubeCinemaSession
    var renderer: Renderer?
    @EnvironmentObject private var settingsStore: SettingsStore
    @StateObject private var browser = YouTubeBrowserController()
    let onBrowse: () -> Void
    let onClose: () -> Void
    @State private var controlsVisible = true

    private func showVideoFromBrowser() {
        browser.watchCurrent { id, title in
            let marks = settingsStore.settings.youtubeCueMarksByVideo[id] ?? []
            cinema.open(videoID: id, title: title, preset: cinema.preset,
                        bpm: cinema.bpm, cuts: marks)
        }
    }

    var body: some View {
        if cinema.isOpen {
            ZStack {
                CinemaScreenLockedPlayer(
                    seatedFovDegrees: settingsStore.settings.seatedFieldOfView,
                    engine: renderer?.fourDX,
                    fourDX: cinema.video != nil && cinema.format.uses4DX,
                    showEffects: settingsStore.settings.fourDXScreenEffects
                ) {
                    if cinema.browserOpen {
                        YouTubeWebsiteView(controller: browser, initialURL: cinema.projectedAddress)
                            .id(cinema.projectionRevision)
                    } else if let video = cinema.video {
                        YouTubePreshowPlayer(
                            trailer: video,
                            stereo3D: cinema.format.uses3D,
                            onStateChange: { playing, seconds in
                                cinema.receive(playing: playing, seconds: seconds)
                            },
                            onEnded: { cinema.receive(playing: false, seconds: cinema.seconds) },
                            onError: { cinema.error = $0 }
                        )
                        .id(video.videoID)
                    }
                }
                .ignoresSafeArea()
                // Do not cover the projected movie with an extra translucent
                // player panel. This is only a low-profile control strip.
                VStack {
                    Spacer(minLength: 0)
                    if controlsVisible {
                        controls
                            .padding(.horizontal, 8)
                            .padding(.bottom, 8)
                            .transition(.opacity)
                    } else {
                        HStack {
                            Spacer()
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) { controlsVisible = true }
                            } label: {
                                Label("Projector controls", systemImage: "slider.horizontal.3")
                                    .font(.caption2.bold())
                                    .padding(8)
                                    .background(.black.opacity(0.75), in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.white)
                        }
                        .padding(.trailing, 8)
                        .padding(.bottom, 8)
                    }
                }
            }
            .onChange(of: cinema.playing) { _, isPlaying in
                if isPlaying {
                    withAnimation(.easeOut(duration: 0.2)) { controlsVisible = false }
                }
            }
            .zIndex(10)
        }
    }

    private var controls: some View {
        VStack(alignment: .center, spacing: 5) {
            if let error = cinema.error {
                Text(error).foregroundStyle(.orange).font(.caption2)
            }
            if cinema.browserOpen, let message = browser.message {
                Text(message).foregroundStyle(.orange).font(.caption2)
            }
            HStack(spacing: 8) {
                Label("ON CINEMA SCREEN", systemImage: "video.fill")
                    .font(.caption2.bold())
                    .foregroundStyle(.cyan)
                    .lineLimit(1)
                if cinema.browserOpen {
                    Button { browser.back() } label: { Image(systemName: "chevron.backward") }
                        .disabled(!browser.canBack)
                    Button { browser.goHome() } label: { Image(systemName: "house") }
                    Button(action: onBrowse) {
                        Label("Search", systemImage: "magnifyingglass")
                    }
                    Button(action: showVideoFromBrowser) {
                        Label("Play video", systemImage: "play.rectangle.fill")
                    }
                } else {
                    Menu {
                        Picker("Format", selection: $cinema.format) {
                            ForEach(TrailerPresentation.allCases) { Text($0.label).tag($0) }
                        }
                        Picker("Motion profile", selection: $cinema.preset) {
                            ForEach(YouTubeMotionPreset.allCases) { mode in
                                Text(mode.label).tag(mode)
                            }
                        }
                    } label: {
                        Label("4DX options", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        let address = browser.address
                        cinema.openBrowser(address: address)
                    } label: {
                        Label("Browse", systemImage: "globe")
                    }
                    Button {
                        let marks = cinema.recordCut()
                        if let id = cinema.videoID {
                            settingsStore.settings.youtubeCueMarksByVideo[id] = marks
                        }
                    } label: {
                        Image(systemName: "waveform.path")
                    }.disabled(!cinema.playing)
                }
                Spacer(minLength: 3)
                Button { withAnimation { controlsVisible = false } } label: {
                    Image(systemName: "eye.slash")
                }.accessibilityLabel("Hide controls, keep projector playing")
                Button(action: onClose) {
                    Label("Stop", systemImage: "stop.fill")
                }.tint(.red).accessibilityLabel("Stop projector playback")
            }
            .font(.caption2.bold())
            .buttonStyle(.bordered)
            .foregroundStyle(.white)
            .lineLimit(1)
        }
        .padding(6)
        .background(.black.opacity(0.84), in: RoundedRectangle(cornerRadius: 12))
    }
}

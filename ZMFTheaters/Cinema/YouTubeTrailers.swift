import Foundation
import SwiftUI
import WebKit

/// Public links are embedded with the official YouTube IFrame Player API.
/// No downloader, scraping, stream extraction or playback bypass is used.
enum TrailerPresentation: String, Codable, CaseIterable, Identifiable {
    case standard, fourDX
    var id: String { rawValue }
    var label: String { self == .fourDX ? "4DX virtual preview" : "Standard preview" }
}

struct PreshowYouTubeTrailer: Codable, Equatable, Identifiable {
    var id = UUID()
    var title: String
    var videoID: String
    var presentation: TrailerPresentation

    static func videoID(from raw: String) -> String? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return nil }
        let path = url.pathComponents.filter { $0 != "/" }
        var id: String?
        switch host {
        case "youtu.be", "www.youtu.be":
            id = path.first
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
             "youtube-nocookie.com", "www.youtube-nocookie.com":
            if path.first == "watch" {
                id = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                    .queryItems?.first(where: { $0.name == "v" })?.value
            } else if ["shorts", "embed", "live"].contains(path.first ?? "") && path.count > 1 {
                id = path[1]
            }
        default: return nil
        }
        guard let id, id.count == 11,
              id.utf8.allSatisfy({ ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8).contains($0) }) else { return nil }
        return id
    }
}

/// YouTube refuses unrestricted frame access for embedded playback. The 4DX
/// preview preset is therefore marked as simulated, not content-aware motion.
struct YouTubePreshowPlayer: UIViewRepresentable {
    let trailer: PreshowYouTubeTrailer
    let onStateChange: (Bool, Double) -> Void
    let onEnded: () -> Void
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let bridge = WKUserContentController()
        bridge.add(context.coordinator, name: "zmfTrailer")
        // Watch-page fallback clock: reads the official page's own <video>
        // position so 4DX motion follows real playback. Read-only; nothing is
        // extracted, downloaded or altered.
        bridge.addUserScript(WKUserScript(source: Self.watchClockScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = bridge
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = [.audio, .video]
        let webview = WKWebView(frame: .zero, configuration: config)
        webview.scrollView.isScrollEnabled = false
        webview.isOpaque = false
        webview.backgroundColor = .black
        webview.navigationDelegate = context.coordinator
        context.coordinator.webview = webview
        load(trailer, in: webview)
        return webview
    }

    func updateUIView(_ webview: WKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.loadedID != trailer.videoID {
            context.coordinator.loadedID = trailer.videoID
            context.coordinator.usingWatchPage = false
            load(trailer, in: webview)
        }
    }

    /// Embedders must identify themselves (Referer/origin) or YouTube answers
    /// with error 152/153. The page origin is the app's own bundle identity,
    /// never a spoofed youtube.com origin.
    static let embedOrigin = "https://com.zmf.theatersplus"

    static let watchClockScript = """
    (function(){
      if(!/(^|\\.)youtube\\.com$/.test(location.hostname)) return;
      setInterval(function(){
        var v=document.querySelector('video');
        if(!v) return;
        try{window.webkit.messageHandlers.zmfTrailer.postMessage({kind:'tick',value:{playing:!v.paused&&!v.ended&&v.readyState>2,time:v.currentTime||0}});}catch(e){}
        if(v.ended&&!window.__zmfEnded){window.__zmfEnded=1;try{window.webkit.messageHandlers.zmfTrailer.postMessage({kind:'ended',value:0});}catch(e){}}
      },350);
    })();
    """

    private func load(_ trailer: PreshowYouTubeTrailer, in webview: WKWebView) {
        // videoID is strictly validated as eleven URL-safe characters.
        guard trailer.videoID.count == 11,
              trailer.videoID.utf8.allSatisfy({ ("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_".utf8).contains($0) }) else { return }
        let html = """
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1.0, user-scalable=no">
        <style>html,body,#player{margin:0;padding:0;background:black;width:100%;height:100%;overflow:hidden}</style>
        </head><body><div id="player"></div><script>
        var player;
        function tell(kind, value) {
          try { window.webkit.messageHandlers.zmfTrailer.postMessage({kind:kind,value:value}); } catch(e) {}
        }
        function onYouTubeIframeAPIReady() {
          player = new YT.Player('player', {
            videoId: '\(trailer.videoID)', width:'100%', height:'100%',
            playerVars:{playsinline:1,controls:1,rel:0,enablejsapi:1,origin:'\(Self.embedOrigin)',widget_referrer:'\(Self.embedOrigin)'},
            events:{
              onReady:function(){tell('ready',0);},
              onStateChange:function(e){
                tell('state',e.data);
                if(e.data===0){tell('ended',0);}
              },
              onError:function(e){tell('error',e.data);}
            }
          });
        }
        setInterval(function() {
          if(player && player.getPlayerState) {
            try {tell('tick',{playing:player.getPlayerState()===1,time:player.getCurrentTime()||0});}catch(e){}
          }
        },350);
        </script><script src="https://www.youtube.com/iframe_api"></script></body></html>
        """
        webview.loadHTMLString(html, baseURL: URL(string: Self.embedOrigin))
    }

    static func dismantleUIView(_ webview: WKWebView, coordinator: Coordinator) {
        webview.stopLoading()
        webview.loadHTMLString("", baseURL: nil)
        webview.configuration.userContentController.removeScriptMessageHandler(forName: "zmfTrailer")
        coordinator.webview = nil
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: YouTubePreshowPlayer
        weak var webview: WKWebView?
        var loadedID: String
        var usingWatchPage = false
        init(parent: YouTubePreshowPlayer) {
            self.parent = parent
            loadedID = parent.trailer.videoID
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "zmfTrailer", let data = message.body as? [String: Any],
                  let kind = data["kind"] as? String else { return }
            switch kind {
            case "ended": parent.onEnded()
            case "error":
                let code = data["value"] as? Int ?? 0
                // 101/150: owner disabled embedding. 152/153: embed identity
                // rejected. Play the same video on YouTube's own watch page
                // instead, keeping the 4DX clock from its player.
                if [101, 150, 152, 153].contains(code), !usingWatchPage, let webview,
                   let url = URL(string: "https://m.youtube.com/watch?v=" + loadedID) {
                    usingWatchPage = true
                    webview.scrollView.isScrollEnabled = true
                    webview.load(URLRequest(url: url))
                } else {
                    parent.onError("YouTube could not play this video (error \(code)). Try Watch video on YouTube.")
                }
            case "state":
                if let value = data["value"] as? Int, value == 0 { parent.onEnded() }
            case "tick":
                guard let value = data["value"] as? [String: Any] else { return }
                let playing = value["playing"] as? Bool ?? false
                let seconds = (value["time"] as? Double ?? 0)
                parent.onStateChange(playing, seconds.isFinite ? max(0, seconds) : 0)
            default: break
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Keep embedded playback and the user on YouTube-owned pages only.
            if let u = navigationAction.request.url, let host = u.host?.lowercased(),
               (host == "youtube.com" || host.hasSuffix(".youtube.com") ||
                host == "youtube-nocookie.com" || host.hasSuffix(".youtube-nocookie.com") ||
                host == "googlevideo.com" || host.hasSuffix(".googlevideo.com") ||
                host == "ytimg.com" || host.hasSuffix(".ytimg.com") ||
                host == "google.com" || host.hasSuffix(".google.com")) {
                decisionHandler(.allow)
            } else {
                decisionHandler(navigationAction.navigationType == .other ? .allow : .cancel)
            }
        }
    }
}

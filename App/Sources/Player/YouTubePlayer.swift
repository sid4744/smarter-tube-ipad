import SwiftUI
import WebKit

/// YouTube's own embedded player in a hidden web view (Google handles the SABR streaming).
/// The app drives it like a TV tuner: load a video at a position, hear back when the picture is up.
@MainActor
final class YouTubePlayer: NSObject, ObservableObject, WKScriptMessageHandler {
    enum Event {
        case ready
        case playing
        case ended
        case error(Int) // 101/150/152/153 = the owner doesn't allow embedding
    }

    let webView: WKWebView
    var onEvent: ((Event) -> Void)?
    @Published private(set) var position: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    private(set) var isReady = false
    private var pending: (id: String, start: Double)?

    override init() {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        config.allowsPictureInPictureMediaPlayback = false
        let controller = WKUserContentController()
        // runs inside YouTube's iframe too: its own title/logo/cards would show under our green display
        controller.addUserScript(WKUserScript(source: Self.hideYouTubeChrome, injectionTime: .atDocumentEnd, forMainFrameOnly: false))
        config.userContentController = controller
        webView = WKWebView(frame: .zero, configuration: config)
        super.init()
        controller.add(WeakHandler(self), name: "yt")
        webView.isOpaque = false
        webView.backgroundColor = .black
        webView.scrollView.isScrollEnabled = false
        webView.isUserInteractionEnabled = false // the TV gestures sit on top
        // A real https page as the embedder: YouTube refuses embeds without a referrer (error 152/153).
        webView.loadHTMLString(Self.html, baseURL: URL(string: "https://sid4744.github.io/smarter-tv/"))
    }

    func load(videoId: String, start: Double) {
        guard isReady else {
            pending = (videoId, start)
            return
        }
        position = start
        duration = 0
        run("load('\(videoId)', \(Int(start)))")
    }

    /// Playback speed (0.25...2). YouTube resets it for every new video, so it's applied again when one starts.
    private(set) var rate = 1.0

    func setRate(_ r: Double) {
        rate = r
        run("player && player.setPlaybackRate(\(r))")
    }

    func restart() { run("seek(0)") }
    func setVolume(_ volume: Double) { run("player && player.setVolume(\(Int(volume * 100)))") }
    func pause() { run("player && player.pauseVideo()") }
    func play() { run("player && player.playVideo()") }
    func togglePlay() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        position = max(0, seconds)
        run("seek(\(Int(max(0, seconds))))")
    }

    func skip(_ delta: Double) {
        let limit = duration > 0 ? duration - 1 : .greatestFiniteMagnitude
        seek(to: min(limit, max(0, position + delta)))
    }

    private func run(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    nonisolated func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        let value = body["value"]
        Task { @MainActor in self.handle(type, value) }
    }

    private func handle(_ type: String, _ value: Any?) {
        switch type {
        case "ready":
            isReady = true
            onEvent?(.ready)
            if let p = pending {
                pending = nil
                load(videoId: p.id, start: p.start)
            }
        case "state":
            let state = (value as? NSNumber)?.intValue ?? -2
            isPlaying = state == 1 || state == 3
            if state == 1 {
                if rate != 1 { setRate(rate) }
                onEvent?(.playing)
            }
            if state == 0 { onEvent?(.ended) }
        case "error":
            onEvent?(.error((value as? NSNumber)?.intValue ?? -1))
        case "time":
            if let arr = value as? [NSNumber], arr.count == 2 {
                position = arr[0].doubleValue
                duration = arr[1].doubleValue
            }
        default:
            break
        }
    }

    private static let hideYouTubeChrome = """
    (function () {
      if (!/(^|\\.)youtube(-nocookie)?\\.com$/.test(location.hostname)) return;
      var s = document.createElement('style');
      s.textContent = '.ytp-chrome-top,.ytp-chrome-bottom,.ytp-gradient-top,.ytp-gradient-bottom,.ytp-title,'
        + '.ytp-title-channel,.ytp-show-cards-title,.ytp-watermark,.ytp-youtube-button,.ytp-pause-overlay,'
        + '.ytp-pause-overlay-container,.ytp-ce-element,.ytp-endscreen-content,.ytp-cards-teaser,.ytp-cards-button,'
        + '.ytp-paid-content-overlay,.ytp-impression-link,.ytp-large-play-button,.ytp-contextmenu,.ytp-tooltip,'
        + '.ytp-overflow-button,.ytp-share-button,.ytp-watch-later-button,.ytp-copylink-button,.iv-branding,'
        + '.branding-img,.annotation{display:none!important}';
      (document.head || document.documentElement).appendChild(s);
    })();
    """

    private static let html = """
    <!DOCTYPE html><html><head>
    <meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no">
    <style>html,body{margin:0;padding:0;background:#000;width:100%;height:100%;overflow:hidden}
    #p{position:absolute;left:0;top:0;width:100%;height:100%}</style></head>
    <body><div id="p"></div>
    <script src="https://www.youtube.com/iframe_api"></script>
    <script>
    var player;
    function post(t, v) { window.webkit.messageHandlers.yt.postMessage({type: t, value: (v === undefined ? null : v)}); }
    function onYouTubeIframeAPIReady() {
      player = new YT.Player('p', {
        width: '100%', height: '100%',
        playerVars: {autoplay: 1, controls: 0, disablekb: 1, fs: 0, iv_load_policy: 3, modestbranding: 1,
                     playsinline: 1, rel: 0, cc_load_policy: 0, origin: 'https://sid4744.github.io'},
        events: {
          onReady: function () { post('ready'); },
          onStateChange: function (e) { post('state', e.data); },
          onError: function (e) { post('error', e.data); }
        }
      });
    }
    function load(id, start) { player.loadVideoById({videoId: id, startSeconds: start}); }
    function seek(s) { player.seekTo(s, true); player.playVideo(); }
    setInterval(function () {
      if (player && player.getCurrentTime) { post('time', [player.getCurrentTime() || 0, player.getDuration() || 0]); }
    }, 500);
    </script></body></html>
    """
}

/// Avoids the retain cycle between WKUserContentController and the player.
private final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ target: WKScriptMessageHandler) { self.target = target }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
        target?.userContentController(c, didReceive: m)
    }
}

/// Puts the player's web view into SwiftUI.
struct YouTubePlayerView: UIViewRepresentable {
    let player: YouTubePlayer
    func makeUIView(context: Context) -> WKWebView { player.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

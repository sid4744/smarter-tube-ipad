import SwiftUI

/// Watching one video, full screen. Touch:
/// tap = controls, double tap left/right third = back/forward 10 s, middle = pause,
/// drag up/down on the left third = brightness, right third = volume, middle = swipe down to close,
/// pinch out/in = fill the screen / fit. The TV button switches to TV view: this video on the
/// TV mode's tube, with static, the CRT look and the green on-screen display.
struct PlayerScreen: View {
    let onClose: () -> Void
    @State private var video: FeedVideo
    @StateObject private var player = YouTubePlayer()
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var related: [FeedVideo] = []
    @State private var scrubbing: Double?
    @State private var dragMode = DragMode.none
    @State private var lastY: CGFloat = 0
    @State private var volume = 1.0
    @State private var level: (label: String, value: Double, at: Date)?
    @State private var tvView: Bool
    @State private var tvStatic = false
    @State private var staticSince = Date()
    @State private var zoomFill = false
    @State private var pull: CGFloat = 0
    @State private var rate = 1.0
    @AppStorage(TVSettings.Key.fill) private var tvFill = false
    private let fromStart: Bool

    enum DragMode { case none, brightness, volume, dismiss, ignored }

    init(video: FeedVideo, tvView: Bool = false, fromStart: Bool = false, onClose: @escaping () -> Void) {
        _video = State(initialValue: video)
        _tvView = State(initialValue: tvView)
        self.fromStart = fromStart
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { geo in
            let full = CGRect(origin: .zero, size: geo.size)
            let screen = tvView ? PictureLayout.tvScreen(in: geo.size, fill: tvFill) : full
            let videoRect = tvView || zoomFill ? PictureLayout.cover(screen) : full
            ZStack {
                Color.black

                YouTubePlayerView(player: player)
                    .picture(screen: screen, video: videoRect)

                if tvView {
                    StaticNoise()
                        .frame(width: screen.width, height: screen.height)
                        .position(x: screen.midX, y: screen.midY)
                        .opacity(tvStatic ? 1 : 0)
                        .animation(.easeOut(duration: 0.5), value: tvStatic)
                        .allowsHitTesting(false)
                    CRTOverlay(rect: screen)
                }

                touchLayer(size: geo.size)

                if tvView {
                    // TV view: close + TV OFF stay in the black corners; the rest comes and goes with a tap
                    tvControls(place: OSDPlacement(size: geo.size, pic: screen), full: controls)
                } else if controls {
                    controlsLayer(size: geo.size)
                        .transition(.opacity)
                }

                levelLayer
            }
            .offset(y: pull)
            .animation(.easeInOut(duration: 0.35), value: tvView)
            .animation(.easeInOut(duration: 0.25), value: zoomFill)
            .animation(.easeInOut(duration: 0.25), value: tvFill)
        }
        .ignoresSafeArea()
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            player.onEvent = { event in handle(event) }
            start(video, fromStart: fromStart)
        }
        .onDisappear { player.pause() }
    }

    // MARK: - Touch

    private func touchLayer(size: CGSize) -> some View {
        Color.clear.contentShape(Rectangle())
            .gesture(
                SpatialTapGesture(count: 2).onEnded { e in
                    Haptics.tap()
                    if e.location.x < size.width / 3 { player.skip(-10); flash("-10 S") }
                    else if e.location.x > size.width * 2 / 3 { player.skip(10); flash("+10 S") }
                    else { flash(player.isPlaying ? "PAUSE" : "PLAY"); player.togglePlay() }
                }
                .exclusively(before: TapGesture().onEnded { toggleControls() })
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 18)
                    .onChanged { g in
                        if dragMode == .none {
                            let vertical = abs(g.translation.height) > abs(g.translation.width) * 1.3
                            if !vertical { dragMode = .ignored }
                            else if g.startLocation.x < size.width / 3 { dragMode = .brightness }
                            else if g.startLocation.x > size.width * 2 / 3 { dragMode = .volume }
                            else { dragMode = .dismiss }
                            lastY = g.location.y
                        }
                        switch dragMode {
                        case .brightness, .volume:
                            let delta = Double((lastY - g.location.y) / (size.height * 0.6))
                            lastY = g.location.y
                            if dragMode == .brightness {
                                let b = min(1, max(0.02, UIScreen.main.brightness + delta))
                                UIScreen.main.brightness = b
                                level = ("BRIGHTNESS", b, Date())
                            } else {
                                volume = min(1, max(0, volume + delta))
                                player.setVolume(volume)
                                level = ("VOLUME", volume, Date())
                            }
                        case .dismiss:
                            pull = max(0, g.translation.height)
                        default:
                            break
                        }
                    }
                    .onEnded { g in
                        if dragMode == .dismiss {
                            if g.translation.height > 140 || g.predictedEndTranslation.height > 420 {
                                onClose()
                            } else {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { pull = 0 }
                            }
                        }
                        dragMode = .none
                    }
            )
            .simultaneousGesture(
                MagnificationGesture().onEnded { scale in
                    guard scale > 1.12 || scale < 0.89 else { return }
                    Haptics.tap()
                    if tvView { tvFill = scale > 1 } else { zoomFill = scale > 1 }
                }
            )
    }

    // MARK: - Regular controls

    @ViewBuilder
    private func controlsLayer(size: CGSize) -> some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .center, spacing: 12) {
                    iconButton("chevron.down", action: onClose)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.title).font(.headline).lineLimit(2)
                        Text(video.author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    iconButton(zoomFill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right") {
                        zoomFill.toggle(); poke()
                    }
                    ShareLink(item: video.watchURL) {
                        Image(systemName: "square.and.arrow.up").font(.title3.weight(.semibold))
                            .frame(width: 52, height: 52).contentShape(Rectangle())
                    }
                    Button { setTV(true) } label: {
                        Label("TV", systemImage: "tv")
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 18).frame(height: 46)
                            .overlay(Capsule().stroke(Color.osdGreen, lineWidth: 2))
                            .foregroundStyle(Color.osdGreen)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20).padding(.top, 20)

                Spacer()

                HStack(spacing: 70) {
                    roundButton("gobackward.10") { player.skip(-10); poke() }
                    roundButton(player.isPlaying ? "pause.fill" : "play.fill", big: true) { player.togglePlay(); poke() }
                    roundButton("goforward.10") { player.skip(10); poke() }
                }

                Spacer()

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(OSDTime.format(scrubbing ?? player.position))
                        Spacer()
                        Text(OSDTime.format(player.duration))
                    }
                    .font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Slider(value: Binding(get: { scrubbing ?? player.position },
                                          set: { scrubbing = $0; poke() }),
                           in: 0...max(1, player.duration)) { editing in
                        if !editing, let s = scrubbing {
                            player.seek(to: s)
                            scrubbing = nil
                        }
                    }
                    SpeedSlider(rate: rate, onChange: setRate, onTouch: poke)
                        .frame(width: 320)
                    if !related.isEmpty {
                        Text("UP NEXT")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.osdGreen)
                            .padding(.top, 6)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(related.prefix(20)) { v in
                                    Button { Haptics.tap(); start(v) } label: { VideoCard(video: v, width: 200) }
                                        .buttonStyle(PressStyle())
                                }
                            }
                        }
                        .frame(height: 210)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 28)
            }
            .foregroundStyle(.white)
        }
    }

    private func iconButton(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.title2.weight(.bold))
                .frame(width: 52, height: 52)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func roundButton(_ icon: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: big ? 44 : 30, weight: .bold))
                .frame(width: big ? 92 : 68, height: big ? 92 : 68)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
        .buttonStyle(PressStyle())
    }

    // MARK: - TV view controls

    /// The TV mode's on-screen display for this one video: title, buttons, and a timeline you can drag.
    private func tvControls(place: OSDPlacement, full: Bool) -> some View {
        ZStack {
            if full || place.inBands {
                XPCloseButton(action: onClose)
                    .position(place.close)

                OSDButton("TV OFF", size: 16) { setTV(false) }
                    .fixedSize()
                    .position(place.corner)
            }

            if full {
                VStack(alignment: .leading, spacing: 6) {
                    OSDText(video.title, size: 22)
                    OSDText(video.author, size: 16, dim: true)
                }
                .lineLimit(1)
                .frame(width: place.titleWidth, alignment: .leading)
                .position(place.title)
                .allowsHitTesting(false)

                SpeedSlider(rate: rate, onChange: setRate, onTouch: poke)
                    .frame(width: place.speedWidth)
                    .position(place.speed)

                if player.duration > 0 {
                    VStack(alignment: .leading, spacing: 8) {
                        OSDText(OSDTime.format(scrubbing ?? player.position) + " / " + OSDTime.format(player.duration), size: 16)
                        GeometryReader { g in
                            SegmentBar(value: (scrubbing ?? player.position) / player.duration)
                                .frame(height: 16)
                                .frame(maxHeight: .infinity)
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { d in
                                            scrubbing = min(1, max(0, d.location.x / g.size.width)) * player.duration
                                            poke()
                                        }
                                        .onEnded { _ in
                                            if let s = scrubbing { player.seek(to: s) }
                                            scrubbing = nil
                                        }
                                )
                        }
                        .frame(height: 44)
                    }
                    .frame(width: place.timelineWidth)
                    .position(place.timeline)
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: full)
    }

    private var levelLayer: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { t in
            if let level, t.date.timeIntervalSince(level.at) < 1.3 {
                VStack(alignment: .leading, spacing: 8) {
                    OSDText(level.label, size: 18)
                    SegmentBar(value: level.value).frame(width: 320, height: 18)
                }
                .padding(18)
                .background(Color.black.opacity(tvView ? 0 : 0.55))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Behaviour

    private func start(_ v: FeedVideo, fromStart: Bool = false) {
        video = v
        var startAt = 0.0
        if !fromStart, let p = v.percentWatched, p > 0, p < 95 { startAt = p / 100 * v.durationSec } // carry on where you left it
        if tvView { beginStatic() }
        player.load(videoId: v.id, start: startAt)
        poke()
        related = []
        Task {
            related = (try? await YouTubeFeed.related(to: v.id, accessToken: try await Session.accessToken())) ?? []
        }
    }

    private func handle(_ event: YouTubePlayer.Event) {
        switch event {
        case .playing:
            endStatic(after: TVSettings.staticSeconds)
        case .ended:
            guard TVSettings.autoplay, let next = related.first else { return }
            start(next, fromStart: true)
        case .error:
            tvStatic = false // let YouTube's own message show
        case .ready:
            break
        }
    }

    private func setRate(_ r: Double) {
        rate = r
        player.setRate(r)
        poke()
    }

    private func setTV(_ on: Bool) {
        Haptics.click()
        tvView = on
        if on {
            beginStatic() // a burst of static, as if you'd just tuned in
            endStatic(after: max(0.5, TVSettings.staticSeconds))
        } else {
            tvStatic = false
        }
        poke()
    }

    private func beginStatic() {
        tvStatic = true
        staticSince = Date()
    }

    private func endStatic(after seconds: Double) {
        guard tvStatic else { return }
        let since = staticSince
        let wait = seconds - Date().timeIntervalSince(since)
        Task {
            if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
            if staticSince == since { tvStatic = false }
        }
    }

    private func toggleControls() {
        withAnimation(.easeInOut(duration: 0.2)) { controls.toggle() }
        if controls { poke() }
    }

    /// Keep the controls up for a few more seconds.
    private func poke() {
        withAnimation(.easeInOut(duration: 0.2)) { controls = true }
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled && scrubbing == nil {
                withAnimation(.easeInOut(duration: 0.3)) { controls = false }
            }
        }
    }

    private func flash(_ text: String) {
        level = (text, player.duration > 0 ? player.position / player.duration : 0, Date())
    }
}

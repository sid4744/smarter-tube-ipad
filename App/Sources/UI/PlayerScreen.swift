import SwiftUI

/// Watching one video: full screen, controls on tap, double tap left/right = back/forward 10 s,
/// drag up/down on the left = brightness, on the right = volume, related videos underneath.
struct PlayerScreen: View {
    let onClose: () -> Void
    @State private var video: FeedVideo
    @StateObject private var player = YouTubePlayer()
    @State private var controls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var related: [FeedVideo] = []
    @State private var scrubbing: Double?
    @State private var dragMode = 0 // 0 none, 1 brightness, 2 volume
    @State private var lastY: CGFloat = 0
    @State private var volume = 1.0
    @State private var level: (label: String, value: Double, at: Date)?

    init(video: FeedVideo, onClose: @escaping () -> Void) {
        _video = State(initialValue: video)
        self.onClose = onClose
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                YouTubePlayerView(player: player)
                    .ignoresSafeArea()

                // touch layer
                Color.clear.contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture(count: 2).onEnded { e in
                            if e.location.x < geo.size.width / 3 { player.skip(-10); flash("-10 S") }
                            else if e.location.x > geo.size.width * 2 / 3 { player.skip(10); flash("+10 S") }
                            else { player.togglePlay() }
                        }
                        .exclusively(before: TapGesture().onEnded { toggleControls() })
                    )
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 18)
                            .onChanged { g in
                                if dragMode == 0 && abs(g.translation.height) > abs(g.translation.width) * 1.3 {
                                    dragMode = g.startLocation.x < geo.size.width / 2 ? 1 : 2
                                    lastY = g.location.y
                                }
                                guard dragMode != 0 else { return }
                                let delta = Double((lastY - g.location.y) / (geo.size.height * 0.6))
                                lastY = g.location.y
                                if dragMode == 1 {
                                    let b = min(1, max(0.02, UIScreen.main.brightness + delta))
                                    UIScreen.main.brightness = b
                                    level = ("BRIGHTNESS", b, Date())
                                } else {
                                    volume = min(1, max(0, volume + delta))
                                    player.setVolume(volume)
                                    level = ("VOLUME", volume, Date())
                                }
                            }
                            .onEnded { _ in dragMode = 0 }
                    )

                if controls {
                    controlsLayer(size: geo.size)
                        .transition(.opacity)
                }

                levelLayer
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            start(video)
        }
        .onDisappear { player.pause() }
    }

    // MARK: - Controls

    @ViewBuilder
    private func controlsLayer(size: CGSize) -> some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.75), .clear, .clear, .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    Button(action: onClose) {
                        Image(systemName: "chevron.down").font(.title2.weight(.bold)).padding(12)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(video.title).font(.headline).lineLimit(2)
                        Text(video.author).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 20).padding(.top, 16)

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
                    if !related.isEmpty {
                        Text("UP NEXT")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.osdGreen)
                            .padding(.top, 6)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 14) {
                                ForEach(related.prefix(20)) { v in
                                    Button { start(v) } label: { VideoCard(video: v, width: 200) }
                                        .buttonStyle(.plain)
                                }
                            }
                        }
                        .frame(height: 210)
                    }
                }
                .padding(.horizontal, 28).padding(.bottom, 20)
            }
            .foregroundStyle(.white)
        }
    }

    private func roundButton(_ icon: String, big: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: big ? 44 : 30, weight: .bold))
                .frame(width: big ? 92 : 68, height: big ? 92 : 68)
                .background(Circle().fill(Color.black.opacity(0.45)))
        }
        .buttonStyle(.plain)
    }

    private var levelLayer: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { t in
            if let level, t.date.timeIntervalSince(level.at) < 1.3 {
                VStack(alignment: .leading, spacing: 8) {
                    OSDText(level.label, size: 18)
                    SegmentBar(value: level.value).frame(width: 320, height: 18)
                }
                .padding(18)
                .background(Color.black.opacity(0.55))
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Behaviour

    private func start(_ v: FeedVideo) {
        video = v
        var startAt = 0.0
        if let p = v.percentWatched, p > 0, p < 95 { startAt = p / 100 * v.durationSec } // carry on where you left it
        player.load(videoId: v.id, start: startAt)
        poke()
        related = []
        Task {
            related = (try? await YouTubeFeed.related(to: v.id, accessToken: try await Session.accessToken())) ?? []
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

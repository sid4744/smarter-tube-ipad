import SwiftUI

/// The TV: the picture inside a rounded "tube", static between channels, the green on-screen display,
/// and touch controls (swipe = channels, tap = info, double tap = from the top,
/// drag up/down on the left = brightness, on the right = volume, long press = menu).
struct TVModeView: View {
    @StateObject private var tv = TVModel()
    let onExit: () -> Void
    @State private var menuShown = false
    @State private var dragMode = DragMode.none
    @State private var lastDragY: CGFloat = 0
    @AppStorage(TVSettings.Key.fill) private var fill = false

    enum DragMode { case none, horizontal, brightness, volume, ignored }

    var body: some View {
        GeometryReader { geo in
            let pic = PictureLayout.tvScreen(in: geo.size, fill: fill)
            ZStack {
                Color.black

                YouTubePlayerView(player: tv.player)
                    .picture(screen: pic, video: PictureLayout.cover(pic))

                StaticNoise()
                    .frame(width: pic.width, height: pic.height)
                    .position(x: pic.midX, y: pic.midY)
                    .opacity(tv.staticOn && !tv.poweringOn ? 1 : 0)
                    .animation(.easeOut(duration: 0.6), value: tv.staticOn)

                if tv.poweringOn {
                    PowerOnView(rect: pic, duration: TVSettings.powerOnSeconds)
                }

                CRTOverlay(rect: pic)

                // the "remote": gestures live on their own layer, under the buttons, so the buttons get their taps
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        TapGesture(count: 2).onEnded { tv.restartProgram() }
                            .exclusively(before: TapGesture(count: 1).onEnded { tv.showInfo() })
                    )
                    .simultaneousGesture(dragGesture(size: geo.size))
                    .simultaneousGesture(
                        // pinch out = fill the whole display, pinch in = back to a 16:9 tube
                        MagnificationGesture().onEnded { scale in
                            guard scale > 1.12 || scale < 0.89 else { return }
                            Haptics.tap()
                            withAnimation(.easeInOut(duration: 0.3)) { fill = scale > 1 }
                        }
                    )
                    .onLongPressGesture(minimumDuration: 1.2) { menuShown = true }

                OSDLayer(tv: tv, place: OSDPlacement(size: geo.size, pic: pic))

                TVTouchControls(tv: tv, place: OSDPlacement(size: geo.size, pic: pic), onExit: onExit)

                if let message = tv.message {
                    OSDText(message, size: 22).position(x: pic.midX, y: pic.midY)
                        .allowsHitTesting(false)
                }
            }
        }
        .ignoresSafeArea()
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            tv.start()
        }
        .onDisappear { tv.player.pause() }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        .confirmationDialog("TV mode", isPresented: $menuShown) {
            Button("Switch off (back to Smarter Tube)") { onExit() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func dragGesture(size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { g in
                if dragMode == .none {
                    let dx = g.translation.width, dy = g.translation.height
                    if abs(dy) > abs(dx) * 1.2 {
                        dragMode = g.startLocation.x < size.width / 2 ? .brightness : .volume
                        lastDragY = g.location.y
                    } else {
                        dragMode = .horizontal
                    }
                }
                if dragMode == .brightness || dragMode == .volume {
                    // a drag over ~80% of the screen height covers the whole range
                    let delta = Double((lastDragY - g.location.y) / (size.height * 0.8))
                    lastDragY = g.location.y
                    dragMode == .brightness ? tv.adjustBrightness(by: delta) : tv.adjustVolume(by: delta)
                }
            }
            .onEnded { g in
                if dragMode == .horizontal && abs(g.translation.width) > 60 {
                    // swipe left = next channel (the picture moves away to the left)
                    g.translation.width < 0 ? tv.channelUp() : tv.channelDown()
                    Haptics.click()
                }
                dragMode = .none
            }
    }

}

// MARK: - Static

/// Black-and-white TV snow, redrawn ~18 times a second, with a rolling bright band.
struct StaticNoise: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 18)) { timeline in
            Image(uiImage: NoiseImage.make(time: timeline.date.timeIntervalSinceReferenceDate))
                .resizable()
                .interpolation(.low)
        }
    }
}

enum NoiseImage {
    static let width = 192, height = 108

    static func make(time: TimeInterval) -> UIImage {
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        let band = Int((time * 160).truncatingRemainder(dividingBy: Double(height + 30))) - 15
        for y in 0..<height {
            let boost = (y >= band && y < band + 9) ? 70 : 0
            for x in 0..<width {
                let v = UInt8(min(255, Int.random(in: 0...255) + boost))
                let i = (y * width + x) * 4
                pixels[i] = v; pixels[i + 1] = v; pixels[i + 2] = v
            }
        }
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cg = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                         space: CGColorSpaceCreateDeviceRGB(),
                         bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                         provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        return UIImage(cgImage: cg)
    }
}

// MARK: - Power-on

/// Switching the set on: the beam hits the middle of the tube, smears into a line, opens up into a
/// glowing screen, and the glow dies down into the static.
struct PowerOnView: View {
    let rect: CGRect
    let duration: Double
    @State private var start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            let u = min(1, timeline.date.timeIntervalSince(start) / duration)
            ZStack {
                Color.black
                if u > 0.08 && u < 0.28 {
                    let a = (u - 0.08) / 0.2
                    let w = rect.width * smooth((a - 0.3) / 0.7)
                    Circle()
                        .fill(RadialGradient(colors: [.white, Color(white: 0.8).opacity(0.4), .clear],
                                             center: .center, startRadius: 0, endRadius: rect.height * 0.12))
                        .frame(width: rect.height * 0.24, height: rect.height * 0.24)
                        .opacity(smooth(a * 2))
                        .position(x: rect.midX, y: rect.midY)
                    Rectangle().fill(Color.white)
                        .frame(width: max(2, w), height: 3)
                        .shadow(color: .white, radius: 8)
                        .position(x: rect.midX, y: rect.midY)
                } else if u >= 0.28 && u < 0.48 {
                    let a = smooth((u - 0.28) / 0.2)
                    Rectangle().fill(Color(red: 0.91, green: 0.93, blue: 1))
                        .frame(width: rect.width, height: max(3, rect.height * a))
                        .blur(radius: 6 * (1 - a))
                        .position(x: rect.midX, y: rect.midY)
                } else if u >= 0.48 {
                    let a = (u - 0.48) / 0.52
                    StaticNoise()
                        .frame(width: rect.width, height: rect.height)
                        .opacity(smooth(a * 1.8))
                        .position(x: rect.midX, y: rect.midY)
                    Rectangle().fill(Color(red: 0.91, green: 0.93, blue: 1))
                        .frame(width: rect.width, height: rect.height)
                        .opacity(0.94 * exp(-a * 3.6))
                        .position(x: rect.midX, y: rect.midY)
                }
            }
        }
        .onAppear { start = Date() }
    }

    private func smooth(_ x: Double) -> Double {
        let t = min(1, max(0, x))
        return t * t * (3 - 2 * t)
    }
}

// MARK: - CRT look

/// Scanlines and darker edges over the picture, and the rounded corners of the tube around it.
struct CRTOverlay: View {
    let rect: CGRect
    @AppStorage(TVSettings.Key.scanlines) private var scanlines = true
    @AppStorage(TVSettings.Key.vignette) private var vignette = true
    @AppStorage(TVSettings.Key.corners) private var corners = true

    var body: some View {
        ZStack {
            if scanlines {
                Scanlines()
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            if vignette {
                RadialGradient(colors: [.clear, .clear, .black.opacity(0.2), .black.opacity(0.5)],
                               center: .center, startRadius: 0, endRadius: hypot(rect.width, rect.height) / 2)
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
            }
            if corners {
                TubeMask(rect: rect, radius: min(rect.width, rect.height) * 0.06)
                    .fill(Color.black, style: FillStyle(eoFill: true))
            }
        }
        .allowsHitTesting(false)
    }
}

/// Black everywhere except a rounded rectangle: the tube's corners.
struct TubeMask: Shape {
    let rect: CGRect
    let radius: CGFloat

    func path(in bounds: CGRect) -> Path {
        var p = Path(bounds)
        p.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius))
        return p
    }
}

// MARK: - On-screen display

/// Channel number, title and a volume-bar style timeline, in the TV mode's green.
struct OSDLayer: View {
    @ObservedObject var tv: TVModel
    let place: OSDPlacement

    private var rect: CGRect { place.pic }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let now = timeline.date
            let visible = now < tv.osdUntil && !tv.poweringOn
            ZStack {
                if visible {
                    VStack(alignment: .trailing, spacing: 0) {
                        OSDText("CH", size: place.channelSize / 4, dim: true)
                        OSDText(String(format: "%02d", tv.channel), size: place.channelSize)
                    }
                    .position(place.channel)

                    if tv.titleShown, let v = tv.current {
                        VStack(alignment: .leading, spacing: 6) {
                            OSDText(v.title, size: 22)
                            OSDText(v.author, size: 16, dim: true)
                        }
                        .frame(width: place.titleWidth, alignment: .leading)
                        .lineLimit(1)
                        .position(place.title)
                    }

                    if !tv.staticOn, tv.player.duration > 0 {
                        VStack(alignment: .leading, spacing: 8) {
                            OSDText(Self.time(tv.player.position) + " / " + Self.time(tv.player.duration), size: 16)
                            SegmentBar(value: tv.player.position / tv.player.duration)
                                .frame(height: 16)
                        }
                        .frame(width: place.timelineWidth)
                        .position(place.timeline)
                    }
                }

                if let level = tv.level, now.timeIntervalSince(level.at) < 1.5 {
                    VStack(alignment: .leading, spacing: 8) {
                        OSDText(level.label, size: 18)
                        SegmentBar(value: level.value).frame(height: 18)
                    }
                    .frame(width: rect.width * 0.5)
                    .position(x: rect.midX, y: rect.minY + rect.height * 0.75)
                }
            }
        }
        .allowsHitTesting(false)
    }

    static func time(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// The buttons that come up with the on-screen display: the close button (top left) and the speed bar.
struct TVTouchControls: View {
    @ObservedObject var tv: TVModel
    let place: OSDPlacement
    let onExit: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { timeline in
            let visible = (timeline.date < tv.osdUntil && !tv.poweringOn) || tv.message != nil
            ZStack {
                // comes and goes with the rest of the on-screen display (tap to bring it back)
                if visible {
                    XPCloseButton(action: onExit)
                        .position(place.close)
                }
                if visible {
                    SpeedSlider(rate: tv.rate, onChange: { tv.setRate($0) }, onTouch: { tv.keepOSD() })
                        .frame(width: place.speedWidth)
                        .position(place.speed)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.easeInOut(duration: 0.25), value: visible)
        }
    }
}

/// A row of vertical bars, like an old set's volume display.
struct SegmentBar: View {
    let value: Double
    var bars = 40

    var body: some View {
        GeometryReader { geo in
            let pitch = geo.size.width / CGFloat(bars)
            HStack(spacing: pitch * 0.45) {
                ForEach(0..<bars, id: \.self) { i in
                    Rectangle()
                        .fill(Color.osdGreen.opacity(Double(i) < value * Double(bars) ? 1 : 0.22))
                        .frame(width: pitch * 0.55)
                }
            }
        }
    }
}

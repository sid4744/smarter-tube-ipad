import SwiftUI

/// TV mode and playback settings, kept in UserDefaults. The Settings screen edits them with
/// @AppStorage using the same keys and defaults; the TV code reads them here.
enum TVSettings {
    enum Key {
        static let scanlines = "tv.scanlines"
        static let vignette = "tv.vignette"
        static let corners = "tv.corners"
        static let fill = "tv.fill"
        static let powerOn = "tv.powerOn"
        static let powerOnSeconds = "tv.powerOnSeconds"
        static let staticSeconds = "tv.staticSeconds"
        static let channelZero = "tv.channelZero"
        static let midway = "tv.midway"
        static let osdSeconds = "tv.osdSeconds"
        static let autoplay = "play.autoplay"
        static let hideKids = "feed.hideKids"
    }

    private static func bool(_ key: String, _ fallback: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? fallback
    }

    private static func number(_ key: String, _ fallback: Double) -> Double {
        UserDefaults.standard.object(forKey: key) as? Double ?? fallback
    }

    static var powerOn: Bool { bool(Key.powerOn, true) }
    /// 0 when the power-on animation is switched off.
    static var powerOnSeconds: Double { powerOn ? number(Key.powerOnSeconds, 2.8) : 0 }
    static var staticSeconds: Double { number(Key.staticSeconds, 0.9) }
    static var channelZero: Bool { bool(Key.channelZero, true) }
    static var midway: Bool { bool(Key.midway, true) }
    static var osdSeconds: Double { number(Key.osdSeconds, 4.5) }
    static var autoplay: Bool { bool(Key.autoplay, true) }
    static var hideKids: Bool { bool(Key.hideKids, true) }
}

/// Where the picture goes on the TV: the tube ("screen") and the 16:9 video inside it.
enum PictureLayout {
    /// The tube: a 16:9 picture fitted to the display, or the whole display when filling.
    static func tvScreen(in size: CGSize, fill: Bool) -> CGRect {
        if fill { return CGRect(origin: .zero, size: size) }
        // leave black space: a strip on top for the close button, a band below for the on-screen display
        let top = topBand, bottom = bottomBand
        let available = max(100, size.height - top - bottom)
        var w = size.width - 24, h = w * 9 / 16
        if h > available {
            h = available
            w = h * 16 / 9
        }
        return CGRect(x: (size.width - w) / 2, y: top + (available - h) / 2, width: w, height: h)
    }

    static let topBand: CGFloat = 76
    static let bottomBand: CGFloat = 150

    /// A 16:9 rectangle that covers `rect` (cropping whatever sticks out).
    static func cover(_ rect: CGRect) -> CGRect {
        var w = rect.width, h = rect.width * 9 / 16
        if h < rect.height {
            h = rect.height
            w = h * 16 / 9
        }
        return CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h)
    }
}

/// Where the TV's on-screen display goes: in the black band under a fitted tube,
/// or over the picture when it fills the screen. The close button is always in the top-left corner.
struct OSDPlacement {
    let size: CGSize
    let pic: CGRect

    var inBands: Bool { size.height - pic.maxY >= 120 }

    private var left: CGFloat { inBands ? pic.minX + 20 : pic.minX + margin }
    private var right: CGFloat { inBands ? pic.maxX - 20 : pic.maxX - margin }
    private var margin: CGFloat { max(pic.width * 0.045, 28) }

    var close: CGPoint { CGPoint(x: 44, y: 40) }
    /// Top-right corner, opposite the close button (the player's "TV OFF").
    var corner: CGPoint { CGPoint(x: size.width - 74, y: 40) }

    var channel: CGPoint {
        inBands ? CGPoint(x: right - 36, y: pic.maxY + 44) : CGPoint(x: right - 50, y: pic.minY + margin + 40)
    }
    var channelSize: CGFloat { inBands ? 40 : 64 }

    var titleWidth: CGFloat { inBands ? (right - left) * 0.74 : pic.width * 0.56 }
    var title: CGPoint {
        inBands ? CGPoint(x: left + titleWidth / 2, y: pic.maxY + 40)
            : CGPoint(x: left + 76 + titleWidth / 2, y: pic.minY + margin + 30) // clear of the close button
    }

    var timelineWidth: CGFloat { inBands ? (right - left) * 0.6 : right - left }
    var timeline: CGPoint {
        inBands ? CGPoint(x: left + timelineWidth / 2, y: pic.maxY + 108) : CGPoint(x: pic.midX, y: pic.maxY - margin - 20)
    }

    var speedWidth: CGFloat { inBands ? min(360, (right - left) * 0.34) : min(380, pic.width * 0.42) }
    var speed: CGPoint {
        inBands ? CGPoint(x: right - speedWidth / 2, y: pic.maxY + 104)
            : CGPoint(x: left + speedWidth / 2, y: pic.maxY - margin - 105)
    }
}

extension OSDPlacement {
    /// Captions: in the black band under the tube (inside the picture while the band shows the info),
    /// or near the bottom of a full-screen picture (above the info when it's up).
    func captionPoint(osdVisible: Bool) -> CGPoint {
        if inBands {
            return osdVisible ? CGPoint(x: pic.midX, y: pic.maxY - 56) : CGPoint(x: pic.midX, y: (pic.maxY + size.height) / 2)
        }
        return osdVisible ? CGPoint(x: pic.midX, y: speed.y - 96) : CGPoint(x: pic.midX, y: size.height - 64)
    }

    var captionWidth: CGFloat { max(200, min(pic.width, size.width) - 80) }
}

/// Subtitles drawn by the app (so they land where we want, not wherever the video's crop puts them).
struct CaptionLayer: View {
    @ObservedObject var player: YouTubePlayer
    let point: CGPoint
    let width: CGFloat
    var tvStyle = true

    var body: some View {
        ZStack {
            if !player.caption.isEmpty {
                Text(player.caption)
                    .font(tvStyle ? .system(size: 24, weight: .semibold, design: .monospaced) : .system(size: 24, weight: .semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Color.black.opacity(0.78))
                    .frame(maxWidth: width)
                    .fixedSize(horizontal: false, vertical: true)
                    .position(point)
            }
        }
        .animation(.easeInOut(duration: 0.25), value: point)
        .allowsHitTesting(false)
    }
}

/// Short taps of the Taptic Engine for touch feedback.
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func click() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
}

extension View {
    /// The video player, cropped to `screen` with the 16:9 video at `video`. One modifier so the
    /// web view stays in the same place in the view tree and keeps playing when the layout changes.
    func picture(screen: CGRect, video: CGRect) -> some View {
        self.frame(width: video.width, height: video.height)
            .position(x: video.midX - screen.minX, y: video.midY - screen.minY)
            .frame(width: screen.width, height: screen.height)
            .clipped()
            .position(x: screen.midX, y: screen.midY)
    }
}

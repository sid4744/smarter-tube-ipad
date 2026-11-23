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
        var w = size.width, h = size.width * 9 / 16
        if h > size.height {
            h = size.height
            w = h * 16 / 9
        }
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

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

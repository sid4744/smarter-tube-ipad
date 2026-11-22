import SwiftUI

/// The cable-TV logic (the iPad version of Smarter Tube's TvModeController):
/// your home feed as numbered channels, channel 0 = what you last watched, static between channels,
/// programs that keep "running" while you're away.
@MainActor
final class TVModel: ObservableObject {
    @Published private(set) var channel = 1
    @Published private(set) var staticOn = true
    @Published private(set) var poweringOn = true
    @Published private(set) var osdUntil = Date.distantPast
    @Published private(set) var titleShown = false
    @Published private(set) var message: String?
    @Published private(set) var level: (label: String, value: Double, at: Date)?

    let player = YouTubePlayer()
    private var channels: [Int: FeedVideo] = [:]
    private var spare: [FeedVideo] = []
    private var memory: [Int: (id: String, position: Double, at: Date)] = [:]
    private var tunedAt = Date()
    private var direction = 1
    private var tuneSerial = 0
    private var started = false
    private var volume = 1.0

    static let powerOnSeconds = 2.8
    static let minStatic = 0.9

    var current: FeedVideo? { channels[channel] }

    init() {
        player.onEvent = { [weak self] event in self?.handle(event) }
    }

    // MARK: - Switching on

    func start() {
        guard !started else { return }
        started = true
        poweringOn = true
        staticOn = true
        let powerOnEnd = Date().addingTimeInterval(Self.powerOnSeconds)
        Task {
            do {
                guard var tokens = Keychain.load() else { message = "NOT SIGNED IN"; return }
                let access = try await YouTubeAuth.accessToken(&tokens)
                var feed = try await YouTubeFeed.home(accessToken: access)
                feed.shuffle()
                let reserve = min(8, feed.count / 4)
                spare = Array(feed.prefix(reserve))
                for (i, video) in feed.dropFirst(reserve).prefix(99).enumerated() {
                    channels[i + 1] = video
                }
                guard !channels.isEmpty else { message = "YOUR HOME FEED IS EMPTY"; return }
                let wait = powerOnEnd.timeIntervalSinceNow
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                poweringOn = false
                tune(1)
            } catch {
                poweringOn = false
                message = "COULDN'T LOAD CHANNELS"
            }
        }
    }

    // MARK: - Channels

    func channelUp() {
        direction = 1
        let keys = channels.keys.filter { $0 > 0 }.sorted()
        let next = keys.first { $0 > channel } ?? keys.first ?? 1
        tune(next)
    }

    func channelDown() {
        direction = -1
        if channel == 1 {
            tuneZero()
            return
        }
        let keys = channels.keys.filter { $0 > 0 }.sorted()
        let prev = keys.last { $0 < channel } ?? keys.last ?? 1
        tune(prev)
    }

    /// Channel 0: the most recent video in your history, looked up fresh every time, resumed where you left it.
    private func tuneZero() {
        remember()
        channel = 0
        beginStatic()
        let serial = tuneSerial
        Task {
            do {
                guard var tokens = Keychain.load() else { return }
                let access = try await YouTubeAuth.accessToken(&tokens)
                let history = try await YouTubeFeed.history(accessToken: access)
                guard serial == tuneSerial, let last = history.first else {
                    if serial == tuneSerial { tune(1) }
                    return
                }
                channels[0] = last
                var start = (last.percentWatched ?? 0) / 100 * last.durationSec
                if let m = memory[0], m.id == last.id { start = m.position }
                if start > last.durationSec - 10 { start = 0 }
                load(last, at: start)
            } catch {
                if serial == tuneSerial { tune(1) }
            }
        }
    }

    private func tune(_ n: Int) {
        guard let video = channels[n] else { return }
        remember()
        channel = n
        beginStatic()
        load(video, at: startPosition(for: n, video))
    }

    private func beginStatic() {
        tuneSerial += 1
        tunedAt = Date()
        staticOn = true
        titleShown = false
        osdUntil = .distantFuture // the number shows over the static
    }

    private func load(_ video: FeedVideo, at start: Double) {
        player.load(videoId: video.id, start: start)
    }

    /// Like walking in on a broadcast: somewhere in the middle, or where it "is now" if you were here recently.
    private func startPosition(for n: Int, _ video: FeedVideo) -> Double {
        if let m = memory[n], m.id == video.id, Date().timeIntervalSince(m.at) < 30 * 60 {
            return min(m.position + Date().timeIntervalSince(m.at), max(0, video.durationSec - 5))
        }
        guard video.durationSec > 60 else { return 0 }
        return video.durationSec * Double.random(in: 0.05...0.85)
    }

    private func remember() {
        guard !staticOn, let v = channels[channel] else { return }
        memory[channel] = (v.id, player.position, Date())
    }

    // MARK: - Player events

    private func handle(_ event: YouTubePlayer.Event) {
        switch event {
        case .playing:
            guard staticOn, !poweringOn else { return }
            let serial = tuneSerial
            let wait = Self.minStatic - Date().timeIntervalSince(tunedAt)
            Task {
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
                guard serial == tuneSerial else { return }
                staticOn = false
                osdUntil = Date().addingTimeInterval(4.5)
            }
        case .ended:
            nextProgram()
        case .error(let code):
            // can't be embedded (or broken): this channel is off the air, try the next one
            message = nil
            _ = code
            if channel == 0 {
                tune(1)
            } else {
                direction >= 0 ? channelUp() : channelDown()
            }
        case .ready:
            break
        }
    }

    /// The program on this channel is over: something new comes on.
    private func nextProgram() {
        guard !spare.isEmpty else { return }
        let next = spare.removeFirst()
        channels[channel] = next
        memory[channel] = nil
        beginStatic()
        load(next, at: 0)
    }

    // MARK: - Touch controls

    func showInfo() {
        titleShown = true
        osdUntil = Date().addingTimeInterval(4.5)
    }

    func restartProgram() {
        guard !staticOn else { return }
        player.restart()
        showInfo()
    }

    func adjustBrightness(by delta: Double) {
        let b = min(1, max(0.02, UIScreen.main.brightness + delta))
        UIScreen.main.brightness = b
        level = ("BRIGHTNESS", b, Date())
    }

    func adjustVolume(by delta: Double) {
        volume = min(1, max(0, volume + delta))
        player.setVolume(volume)
        level = ("VOLUME", volume, Date())
    }
}

import SwiftUI

/// The signed-in access token, refreshed when needed.
enum Session {
    static func accessToken() async throws -> String {
        guard var tokens = Keychain.load() else { throw YouTubeAuth.AuthError.denied("not signed in") }
        return try await YouTubeAuth.accessToken(&tokens)
    }
}

// MARK: - Playing a video from anywhere

/// What to open in the player: the video, whether in TV view, and whether to ignore the saved position.
struct PlayRequest: Identifiable {
    let id = UUID()
    let video: FeedVideo
    var tv = false
    var fromStart = false
}

/// Handed down the view tree so any card can start the player.
struct PlayAction {
    var run: (PlayRequest) -> Void = { _ in }

    func callAsFunction(_ video: FeedVideo, tv: Bool = false, fromStart: Bool = false) {
        run(PlayRequest(video: video, tv: tv, fromStart: fromStart))
    }
}

private struct PlayActionKey: EnvironmentKey {
    static let defaultValue = PlayAction()
}

extension EnvironmentValues {
    var play: PlayAction {
        get { self[PlayActionKey.self] }
        set { self[PlayActionKey.self] = newValue }
    }
}

extension FeedVideo {
    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=" + id)! }
    var bigThumbnailURL: URL { URL(string: "https://i.ytimg.com/vi/" + id + "/maxresdefault.jpg")! }
}

// MARK: - Main layout

/// SmartTube's layout on the iPad: sections on the left, rows of videos on the right.
struct MainView: View {
    @ObservedObject var auth: AuthModel
    @State private var section: Section? = .home
    @State private var playing: PlayRequest?
    @State private var tvMode = false

    enum Section: String, CaseIterable, Identifiable {
        case home = "Home", subscriptions = "Subscriptions", history = "History", search = "Search", tv = "TV mode", settings = "Settings"
        var id: String { rawValue }

        var icon: String {
            switch self {
            case .home: return "house.fill"
            case .subscriptions: return "play.rectangle.on.rectangle.fill"
            case .history: return "clock.arrow.circlepath"
            case .search: return "magnifyingglass"
            case .tv: return "tv.fill"
            case .settings: return "gearshape.fill"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { s in
                Label(s.rawValue, systemImage: s.icon)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .padding(.vertical, 8) // roomier rows for fingers
                    .tag(s)
            }
            .navigationTitle("Smarter Tube")
            .listStyle(.sidebar)
        } detail: {
            NavigationStack {
                Group {
                    switch section ?? .home {
                    case .home: BrowseView(browseId: "FEwhat_to_watch", isHome: true)
                    case .subscriptions: BrowseView(browseId: "FEsubscriptions")
                    case .history: BrowseView(browseId: "FEhistory")
                    case .search: SearchView()
                    case .tv: TVModeLauncher(start: { tvMode = true }, settings: { section = .settings })
                    case .settings: SettingsView(auth: auth)
                    }
                }
                .navigationTitle((section ?? .home).rawValue)
            }
        }
        .tint(Color.osdGreen)
        .environment(\.play, PlayAction { playing = $0 })
        .onChange(of: section) { _, new in
            if new == .tv { tvMode = true }
        }
        .fullScreenCover(item: $playing) { r in
            PlayerScreen(video: r.video, tvView: r.tv, fromStart: r.fromStart) { playing = nil }
        }
        .fullScreenCover(isPresented: $tvMode) {
            TVModeView(onExit: { tvMode = false })
        }
    }
}

// MARK: - Browse screens

/// One browse screen: titled rows of video cards, loading more as you scroll.
/// Home also gets a swipeable "top picks" carousel and a "Continue watching" row.
struct BrowseView: View {
    let browseId: String
    var isHome = false
    @State private var shelves: [Shelf] = []
    @State private var continueWatching: [FeedVideo] = []
    @State private var next: String?
    @State private var error: String?
    @State private var loading = true
    @State private var loadingMore = false

    private let heroCount = 6

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 30) {
                if loading && shelves.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
                if let error {
                    Text(error).foregroundStyle(.secondary).padding()
                }
                if isHome, let first = shelves.first, first.videos.count > 2 {
                    HeroCarousel(videos: Array(first.videos.prefix(heroCount)))
                }
                if isHome, !continueWatching.isEmpty {
                    ShelfRow(shelf: Shelf(title: "Continue watching", videos: continueWatching))
                }
                ForEach(Array(displayed.enumerated()), id: \.element.id) { _, shelf in
                    ShelfRow(shelf: shelf)
                }
                if next != nil && !shelves.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                        .onAppear { Task { await loadMore() } }
                }
            }
            .padding(.vertical, 16)
        }
        .refreshable { await load() }
        .task(id: browseId) { await load() }
        .background(Color.black)
    }

    /// On Home the carousel shows the first row's top videos, so the row starts after them.
    private var displayed: [Shelf] {
        guard isHome, var first = shelves.first, first.videos.count > 2 else { return shelves }
        first.videos = Array(first.videos.dropFirst(heroCount))
        return (first.videos.isEmpty ? [] : [first]) + shelves.dropFirst()
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let token = try await Session.accessToken()
            async let page = YouTubeFeed.page(browseId: browseId, accessToken: token)
            async let history: [FeedVideo] = isHome ? ((try? await YouTubeFeed.history(accessToken: token)) ?? []) : []
            let p = try await page
            var out: [Shelf] = []
            YouTubeFeed.merge(p.shelves, into: &out)
            shelves = out
            next = p.next
            continueWatching = Array((await history).filter { ($0.percentWatched ?? 0) > 0 && ($0.percentWatched ?? 0) < 95 }.prefix(20))
            error = shelves.isEmpty && next == nil ? "Nothing here yet." : nil
            if shelves.isEmpty { await loadMore() }
        } catch {
            self.error = "Couldn't load: \(error.localizedDescription)"
        }
    }

    /// The next page(s), until something new turns up.
    private func loadMore() async {
        guard !loadingMore, let token = next else { return }
        loadingMore = true
        defer { loadingMore = false }
        var cursor: String? = token
        var tries = 0
        while let c = cursor, tries < 3 {
            tries += 1
            guard let p = try? await YouTubeFeed.page(continuation: c, accessToken: try await Session.accessToken()) else {
                cursor = nil
                break
            }
            cursor = p.next
            let before = shelves.reduce(0) { $0 + $1.videos.count }
            var out = shelves
            YouTubeFeed.merge(p.shelves, into: &out)
            shelves = out
            if shelves.reduce(0, { $0 + $1.videos.count }) > before { break }
        }
        next = cursor
    }
}

/// Swipeable big cards for the top of Home.
struct HeroCarousel: View {
    let videos: [FeedVideo]
    @State private var page = 0

    var body: some View {
        TabView(selection: $page) {
            ForEach(Array(videos.enumerated()), id: \.element.id) { i, v in
                HeroCard(video: v).tag(i)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .frame(height: 460)
    }
}

struct HeroCard: View {
    let video: FeedVideo
    @Environment(\.play) private var play

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color(white: 0.1)
                .overlay {
                    AsyncImage(url: video.bigThumbnailURL) { phase in
                        if let image = phase.image {
                            image.resizable().aspectRatio(contentMode: .fill)
                        } else if phase.error != nil {
                            AsyncImage(url: video.thumbnailURL) { $0.resizable().aspectRatio(contentMode: .fill) } placeholder: { Color.clear }
                        } else {
                            Color.clear
                        }
                    }
                }
                .clipped()

            LinearGradient(colors: [.clear, .clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom)

            VStack(alignment: .leading, spacing: 10) {
                Text("TOP PICK")
                    .font(.system(size: 14, weight: .heavy, design: .monospaced))
                    .foregroundStyle(Color.osdGreen)
                Text(video.title)
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Text([video.author, video.details].filter { !$0.isEmpty }.joined(separator: " • "))
                    .font(.system(size: 15))
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
                HStack(spacing: 14) {
                    Button { Haptics.tap(); play(video) } label: {
                        Label("Play", systemImage: "play.fill")
                            .font(.system(size: 17, weight: .bold))
                            .padding(.horizontal, 26).frame(height: 50)
                            .background(Capsule().fill(Color.white))
                            .foregroundStyle(.black)
                    }
                    Button { Haptics.tap(); play(video, tv: true) } label: {
                        Label("TV view", systemImage: "tv")
                            .font(.system(size: 17, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 22).frame(height: 50)
                            .overlay(Capsule().stroke(Color.osdGreen, lineWidth: 2))
                            .foregroundStyle(Color.osdGreen)
                    }
                }
                .buttonStyle(PressStyle())
                .padding(.top, 6)
            }
            .padding(30)
            .padding(.bottom, 18) // room for the page dots
        }
        .clipShape(RoundedRectangle(cornerRadius: 20))
        .padding(.horizontal, 20)
        .contentShape(Rectangle())
        .onTapGesture { Haptics.tap(); play(video) }
    }
}

struct ShelfRow: View {
    let shelf: Shelf

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !shelf.title.isEmpty {
                NavigationLink {
                    ShelfGrid(shelf: shelf)
                } label: {
                    HStack(spacing: 8) {
                        Text(shelf.title)
                            .font(.system(.title3, design: .monospaced).weight(.bold))
                        Image(systemName: "chevron.right").font(.system(size: 15, weight: .bold))
                        Spacer()
                        Text("See all").font(.system(size: 14, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(Color.osdGreen)
                    .padding(.horizontal, 20)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if shelf.isGrid {
                VideoGrid(videos: shelf.videos)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(shelf.videos) { VideoButton(video: $0) }
                    }
                    .padding(.horizontal, 20)
                }
            }
        }
    }
}

/// "See all": every video of a row in a grid.
struct ShelfGrid: View {
    let shelf: Shelf

    var body: some View {
        ScrollView {
            VideoGrid(videos: shelf.videos).padding(.vertical, 16)
        }
        .background(Color.black)
        .navigationTitle(shelf.title)
    }
}

struct VideoGrid: View {
    let videos: [FeedVideo]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 280, maximum: 340), spacing: 18, alignment: .top)],
                  alignment: .leading, spacing: 26) {
            ForEach(videos) { VideoButton(video: $0, width: 280) }
        }
        .padding(.horizontal, 20)
    }
}

// MARK: - Cards

/// A card you can tap to play, or press and hold for more (TV view, from the beginning, share).
struct VideoButton: View {
    let video: FeedVideo
    var width: CGFloat = 300
    @Environment(\.play) private var play

    var body: some View {
        Button { Haptics.tap(); play(video) } label: { VideoCard(video: video, width: width) }
            .buttonStyle(PressStyle())
            .contextMenu {
                Button { play(video) } label: { Label("Play", systemImage: "play.fill") }
                Button { play(video, tv: true) } label: { Label("Watch in TV view", systemImage: "tv") }
                if (video.percentWatched ?? 0) > 0 {
                    Button { play(video, fromStart: true) } label: { Label("Play from the beginning", systemImage: "backward.end.fill") }
                }
                ShareLink(item: video.watchURL) { Label("Share", systemImage: "square.and.arrow.up") }
            }
    }
}

/// Cards shrink a little under your finger.
struct PressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

/// Thumbnail with length and progress, title, channel, views/date.
struct VideoCard: View {
    let video: FeedVideo
    var width: CGFloat = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                AsyncImage(url: video.thumbnailURL) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color(white: 0.12)
                }
                .frame(width: width, height: width * 9 / 16)
                .clipped()

                Text(video.durationText)
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(Color.black.opacity(0.8))
                    .foregroundStyle(.white)
                    .padding(6)

                if let p = video.percentWatched, p > 0 {
                    GeometryReader { geo in
                        Rectangle().fill(Color.red)
                            .frame(width: geo.size.width * min(1, p / 100), height: 3)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                }
            }
            .frame(width: width, height: width * 9 / 16)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            Text(video.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            Text(video.author)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !video.details.isEmpty {
                Text(video.details)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: width, alignment: .leading)
        .contentShape(Rectangle())
    }
}

// MARK: - Search

struct SearchView: View {
    @State private var query = ""
    @State private var shelves: [Shelf] = []
    @State private var searching = false
    @AppStorage("search.recent") private var recentText = ""

    private var recent: [String] { recentText.split(separator: "\n").map(String.init) }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if searching { ProgressView().frame(maxWidth: .infinity).padding(.top, 60) }
                if shelves.isEmpty && !searching && !recent.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("RECENT")
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(Color.osdGreen)
                        ForEach(recent, id: \.self) { q in
                            Button {
                                query = q
                                Task { await run() }
                            } label: {
                                Label(q, systemImage: "clock")
                                    .font(.system(size: 18))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                ForEach(shelves) { ShelfRow(shelf: $0) }
            }
            .padding(.vertical, 16)
        }
        .background(Color.black)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search YouTube")
        .onSubmit(of: .search) { Task { await run() } }
        .onChange(of: query) { _, q in
            if q.isEmpty { shelves = [] }
        }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        recentText = ([q] + recent.filter { $0 != q }).prefix(8).joined(separator: "\n")
        searching = true
        defer { searching = false }
        shelves = (try? await YouTubeFeed.search(q, accessToken: try await Session.accessToken())) ?? []
    }
}

// MARK: - TV mode launcher

struct TVModeLauncher: View {
    let start: () -> Void
    let settings: () -> Void

    var body: some View {
        VStack(spacing: 26) {
            Image(systemName: "tv").font(.system(size: 80)).foregroundStyle(Color.osdGreen)
            OSDText("YOUR HOME FEED AS CABLE TV", size: 18, dim: true)
            OSDButton("SWITCH ON", action: start)
            VStack(spacing: 8) {
                OSDText("SWIPE LEFT/RIGHT  CHANNELS", size: 13, dim: true)
                OSDText("TAP  WHAT'S ON     DOUBLE TAP  FROM THE TOP", size: 13, dim: true)
                OSDText("DRAG LEFT/RIGHT SIDE  BRIGHTNESS/VOLUME", size: 13, dim: true)
                OSDText("PINCH  FILL/FIT     HOLD  SWITCH OFF", size: 13, dim: true)
            }
            .padding(.top, 10)
            Button("TV mode settings", action: settings)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .frame(minHeight: 44)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var auth: AuthModel

    @AppStorage(TVSettings.Key.powerOn) private var powerOn = true
    @AppStorage(TVSettings.Key.powerOnSeconds) private var powerOnSeconds = 2.8
    @AppStorage(TVSettings.Key.staticSeconds) private var staticSeconds = 0.9
    @AppStorage(TVSettings.Key.channelZero) private var channelZero = true
    @AppStorage(TVSettings.Key.midway) private var midway = true
    @AppStorage(TVSettings.Key.fill) private var fill = false
    @AppStorage(TVSettings.Key.osdSeconds) private var osdSeconds = 4.5
    @AppStorage(TVSettings.Key.scanlines) private var scanlines = true
    @AppStorage(TVSettings.Key.vignette) private var vignette = true
    @AppStorage(TVSettings.Key.corners) private var corners = true
    @AppStorage(TVSettings.Key.autoplay) private var autoplay = true
    @AppStorage(TVSettings.Key.hideKids) private var hideKids = true

    var body: some View {
        Form {
            Section("Account") {
                if case .signedIn(let name) = auth.state {
                    LabeledContent("Signed in as", value: name ?? "your account")
                }
                Button("Sign out", role: .destructive) { auth.signOut() }
            }

            Section {
                Toggle("Power-on animation", isOn: $powerOn)
                if powerOn {
                    slider("Power-on length", value: $powerOnSeconds, in: 1.5...5, step: 0.1)
                }
                slider("Static between channels", value: $staticSeconds, in: 0.3...2.5, step: 0.1)
                slider("On-screen display", value: $osdSeconds, in: 2...10, step: 0.5)
                Toggle("Channel 0: last watched video", isOn: $channelZero)
                Toggle("Join programs part-way through", isOn: $midway)
                Toggle("Fill the whole screen", isOn: $fill)
            } header: {
                Text("TV mode")
            } footer: {
                Text("Channel 0 sits below channel 1 and resumes what you watched last. Pinch the picture to switch between fill and fit.")
            }

            Section("CRT look") {
                Toggle("Scanlines", isOn: $scanlines)
                Toggle("Darker edges (vignette)", isOn: $vignette)
                Toggle("Rounded tube corners", isOn: $corners)
            }

            Section("Playback") {
                Toggle("Autoplay the next video", isOn: $autoplay)
                Toggle("Hide kids' videos", isOn: $hideKids)
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                Text("Smarter Tube for iPad. Plays videos with YouTube's own player for now; the full CRT shader comes with the native player.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>, step: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LabeledContent(title, value: String(format: "%.1f s", value.wrappedValue))
            Slider(value: value, in: range, step: step)
        }
        .padding(.vertical, 4)
    }
}

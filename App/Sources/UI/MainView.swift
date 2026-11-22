import SwiftUI

/// The signed-in access token, refreshed when needed.
enum Session {
    static func accessToken() async throws -> String {
        guard var tokens = Keychain.load() else { throw YouTubeAuth.AuthError.denied("not signed in") }
        return try await YouTubeAuth.accessToken(&tokens)
    }
}

/// SmartTube's layout on the iPad: sections on the left, rows of videos on the right.
struct MainView: View {
    @ObservedObject var auth: AuthModel
    @State private var section: Section? = .home
    @State private var playing: FeedVideo?
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
                    .tag(s)
            }
            .navigationTitle("Smarter Tube")
            .listStyle(.sidebar)
        } detail: {
            NavigationStack {
                Group {
                    switch section ?? .home {
                    case .home: BrowseView(browseId: "FEwhat_to_watch", pages: 4, onPlay: play)
                    case .subscriptions: BrowseView(browseId: "FEsubscriptions", pages: 3, onPlay: play)
                    case .history: BrowseView(browseId: "FEhistory", pages: 2, onPlay: play)
                    case .search: SearchView(onPlay: play)
                    case .tv: TVModeLauncher { tvMode = true }
                    case .settings: SettingsView(auth: auth)
                    }
                }
                .navigationTitle((section ?? .home).rawValue)
            }
        }
        .tint(Color.osdGreen)
        .onChange(of: section) { _, new in
            if new == .tv { tvMode = true }
        }
        .fullScreenCover(item: $playing) { video in
            PlayerScreen(video: video) { playing = nil }
        }
        .fullScreenCover(isPresented: $tvMode) {
            TVModeView(onExit: {
                tvMode = false
                if section == .tv { section = .home }
            })
        }
    }

    private func play(_ video: FeedVideo) {
        playing = video
    }
}

/// One browse screen: titled rows of video cards.
struct BrowseView: View {
    let browseId: String
    let pages: Int
    let onPlay: (FeedVideo) -> Void
    @State private var shelves: [Shelf] = []
    @State private var error: String?
    @State private var loading = true

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if loading && shelves.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 80)
                }
                if let error {
                    Text(error).foregroundStyle(.secondary).padding()
                }
                ForEach(shelves) { shelf in
                    ShelfRow(shelf: shelf, onPlay: onPlay)
                }
            }
            .padding(.vertical, 16)
        }
        .refreshable { await load() }
        .task(id: browseId) { await load() }
        .background(Color.black)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            shelves = try await YouTubeFeed.shelves(browseId: browseId, accessToken: try await Session.accessToken(), maxPages: pages)
            error = shelves.isEmpty ? "Nothing here yet." : nil
        } catch {
            self.error = "Couldn't load: \(error.localizedDescription)"
        }
    }
}

struct ShelfRow: View {
    let shelf: Shelf
    let onPlay: (FeedVideo) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !shelf.title.isEmpty {
                Text(shelf.title)
                    .font(.system(.title3, design: .monospaced).weight(.bold))
                    .foregroundStyle(Color.osdGreen)
                    .padding(.horizontal, 20)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 16) {
                    ForEach(shelf.videos) { v in
                        Button { onPlay(v) } label: { VideoCard(video: v) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 20)
            }
        }
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
    }
}

struct SearchView: View {
    let onPlay: (FeedVideo) -> Void
    @State private var query = ""
    @State private var shelves: [Shelf] = []
    @State private var searching = false

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if searching { ProgressView().frame(maxWidth: .infinity).padding(.top, 60) }
                ForEach(shelves) { ShelfRow(shelf: $0, onPlay: onPlay) }
            }
            .padding(.vertical, 16)
        }
        .background(Color.black)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search YouTube")
        .onSubmit(of: .search) { Task { await run() } }
    }

    private func run() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searching = true
        defer { searching = false }
        shelves = (try? await YouTubeFeed.search(q, accessToken: try await Session.accessToken())) ?? []
    }
}

struct TVModeLauncher: View {
    let start: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "tv").font(.system(size: 80)).foregroundStyle(Color.osdGreen)
            OSDText("YOUR HOME FEED AS CABLE TV", size: 18, dim: true)
            OSDButton("SWITCH ON", action: start)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }
}

struct SettingsView: View {
    @ObservedObject var auth: AuthModel

    var body: some View {
        Form {
            Section("Account") {
                if case .signedIn(let name) = auth.state {
                    LabeledContent("Signed in as", value: name ?? "your account")
                }
                Button("Sign out", role: .destructive) { auth.signOut() }
            }
            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?")
                Text("Smarter Tube for iPad. Plays videos with YouTube's own player for now; the full CRT shader comes with the native player.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

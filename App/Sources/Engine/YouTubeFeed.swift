import Foundation

/// One video card (home feed, subscriptions, history, search, related).
struct FeedVideo: Identifiable, Equatable, Hashable {
    let id: String
    let title: String
    let author: String
    let durationSec: Double
    /// 0...100 for videos you've started (how far you got), else nil.
    let percentWatched: Double?
    var thumbnail: URL? = nil
    var details: String = ""

    var durationText: String { OSDTime.format(durationSec) }
    var thumbnailURL: URL { thumbnail ?? URL(string: "https://i.ytimg.com/vi/" + id + "/hqdefault.jpg")! }
}

/// A titled row of videos ("Recommended", "Recently uploaded", ...).
struct Shelf: Identifiable {
    let id = UUID()
    let title: String
    let videos: [FeedVideo]
}

enum OSDTime {
    static func format(_ s: Double) -> String {
        let t = Int(max(0, s))
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
            : String(format: "%d:%02d", t / 60, t % 60)
    }
}

/// The home feed and the history, the way SmartTube asks for them (TV client, signed in).
enum YouTubeFeed {
    private static var tvClient: [String: Any] {
        ["clientName": "TVHTML5", "clientVersion": "7.20260901.15.00", "userAgent": YouTubeAuth.tvUserAgent,
         "hl": "en", "gl": "NL", "utcOffsetMinutes": TimeZone.current.secondsFromGMT() / 60,
         "tvAppInfo": ["appQuality": "TV_APP_QUALITY_FULL_ANIMATION", "zylonLeftNav": true],
         "webpSupport": false, "animatedWebpSupport": true]
    }

    /// Your home feed, following the "more shelves" pages until there are enough videos.
    static func home(accessToken: String, want: Int = 80, maxPages: Int = 8) async throws -> [FeedVideo] {
        var videos: [FeedVideo] = []
        var seen = Set<String>()
        var root = try await browse(["browseId": "FEwhat_to_watch"], accessToken: accessToken)
        var pages = 1
        while true {
            for v in parseTiles(root) where seen.insert(v.id).inserted {
                videos.append(v)
            }
            guard videos.count < want, pages < maxPages, let next = sectionContinuation(root) else { break }
            root = try await browse(["continuation": next], accessToken: accessToken)
            pages += 1
        }
        return videos
    }

    /// Your watch history, most recent first.
    static func history(accessToken: String) async throws -> [FeedVideo] {
        let root = try await browse(["browseId": "FEhistory"], accessToken: accessToken)
        return parseTiles(root)
    }

    // MARK: - Shelves (the browse screens)

    /// A browse page as titled rows, following "more shelves" pages up to `maxPages`.
    static func shelves(browseId: String, accessToken: String, maxPages: Int = 4) async throws -> [Shelf] {
        var out: [Shelf] = []
        var root = try await browse(["browseId": browseId], accessToken: accessToken)
        var pages = 1
        while true {
            out += parseShelves(root)
            guard pages < maxPages, let next = sectionContinuation(root) else { break }
            root = try await browse(["continuation": next], accessToken: accessToken)
            pages += 1
        }
        return out
    }

    static func search(_ query: String, accessToken: String) async throws -> [Shelf] {
        var body: [String: Any] = ["query": query]
        body["context"] = ["client": tvClient, "user": ["enableSafetyMode": false, "lockedSafetyMode": false]]
        let data = try await YouTubeAuth.post("https://www.youtube.com/youtubei/v1/search?prettyPrint=false",
                                              json: body, bearer: accessToken)
        return parseShelves(try JSONSerialization.jsonObject(with: data))
    }

    /// What YouTube recommends alongside this video (its "up next").
    static func related(to videoId: String, accessToken: String) async throws -> [FeedVideo] {
        var body: [String: Any] = ["videoId": videoId]
        body["context"] = ["client": tvClient, "user": ["enableSafetyMode": false, "lockedSafetyMode": false]]
        let data = try await YouTubeAuth.post("https://www.youtube.com/youtubei/v1/next?prettyPrint=false",
                                              json: body, bearer: accessToken)
        let root = try JSONSerialization.jsonObject(with: data)
        var seen = Set<String>([videoId])
        return (parseTiles(root) + parseLockups(root)).filter { seen.insert($0.id).inserted }
    }

    static func parseShelves(_ root: Any) -> [Shelf] {
        var shelves: [[String: Any]] = []
        collect("shelfRenderer", in: root, into: &shelves)
        return shelves.compactMap { shelf in
            let header: Any = shelf["headerRenderer"] ?? shelf["title"] ?? [String: Any]()
            let title = JSONWalk.first("title", in: header).flatMap(JSONWalk.text) ?? JSONWalk.text(header) ?? ""
            var seen = Set<String>()
            let videos = (parseTiles(shelf) + parseLockups(shelf)).filter { seen.insert($0.id).inserted }
            let clean = title.trimmingCharacters(in: .whitespaces)
            return videos.isEmpty || clean.lowercased() == "shorts" ? nil : Shelf(title: clean, videos: videos)
        }
    }

    /// Search and some newer screens use "lockup" cards instead of TV tiles.
    static func parseLockups(_ root: Any) -> [FeedVideo] {
        var lockups: [[String: Any]] = []
        collect("lockupViewModel", in: root, into: &lockups)
        return lockups.compactMap { l in
            guard (l["contentType"] as? String) == "LOCKUP_CONTENT_TYPE_VIDEO", let id = l["contentId"] as? String else { return nil }
            let meta = (l["metadata"] as? [String: Any])?["lockupMetadataViewModel"] as? [String: Any] ?? [:]
            let title = ((meta["title"] as? [String: Any])?["content"] as? String) ?? ""
            let rows = (JSONWalk.first("metadataRows", in: meta) as? [[String: Any]]) ?? []
            func rowText(_ i: Int) -> String {
                guard i < rows.count, let parts = rows[i]["metadataParts"] as? [[String: Any]] else { return "" }
                return parts.compactMap { ($0["text"] as? [String: Any])?["content"] as? String }.joined(separator: " • ")
            }
            let image: Any = l["contentImage"] ?? [String: Any]()
            let duration = (JSONWalk.first("thumbnailBadgeViewModel", in: image) as? [String: Any])?["text"] as? String
            let percent = (JSONWalk.first("startPercent", in: image) as? NSNumber)?.doubleValue
            let sources = JSONWalk.first("sources", in: image) as? [[String: Any]]
            let thumb = (sources?.first?["url"] as? String).flatMap { URL(string: $0) }
            let seconds = duration.map { parseDuration($0) } ?? 0
            if seconds < 61 { return nil } // Shorts and live
            let v = FeedVideo(id: id, title: title, author: rowText(0), durationSec: seconds, percentWatched: percent,
                              thumbnail: thumb, details: rowText(1))
            return isForKids(v) ? nil : v
        }
    }

    // MARK: - Request + parsing

    private static func browse(_ payload: [String: Any], accessToken: String) async throws -> Any {
        var body = payload
        body["context"] = ["client": tvClient, "user": ["enableSafetyMode": false, "lockedSafetyMode": false]]
        let data = try await YouTubeAuth.post("https://www.youtube.com/youtubei/v1/browse?prettyPrint=false",
                                              json: body, bearer: accessToken)
        return try JSONSerialization.jsonObject(with: data)
    }

    /// Every video tile in a TV browse response.
    static func parseTiles(_ root: Any) -> [FeedVideo] {
        var tiles: [[String: Any]] = []
        collect("tileRenderer", in: root, into: &tiles)
        return tiles.compactMap { tile in
            guard (tile["contentType"] as? String) == "TILE_CONTENT_TYPE_VIDEO",
                  let id = (tile["contentId"] as? String)
                    ?? (JSONWalk.first("videoId", in: tile["onSelectCommand"] ?? [String: Any]()) as? String)
            else { return nil }
            let meta = (tile["metadata"] as? [String: Any])?["tileMetadataRenderer"] as? [String: Any] ?? [:]
            let title = meta["title"].flatMap(JSONWalk.text) ?? ""
            let firstLine = (meta["lines"] as? [Any])?.first
            let author = firstLine.flatMap { JSONWalk.first("text", in: $0) }.flatMap(JSONWalk.text) ?? ""
            let header = (tile["header"] as? [String: Any])?["tileHeaderRenderer"] as? [String: Any] ?? [:]
            var duration: Double = 0
            var percent: Double?
            var live = false
            for overlay in header["thumbnailOverlays"] as? [[String: Any]] ?? [] {
                if let time = overlay["thumbnailOverlayTimeStatusRenderer"] as? [String: Any] {
                    if (time["style"] as? String) == "LIVE" { live = true }
                    if let text = time["text"].flatMap(JSONWalk.text) { duration = parseDuration(text) }
                }
                if let resume = overlay["thumbnailOverlayResumePlaybackRenderer"] as? [String: Any] {
                    percent = (resume["percentDurationWatched"] as? NSNumber)?.doubleValue
                }
            }
            if live || duration < 61 { return nil } // no live streams, no Shorts
            let thumbs = (JSONWalk.first("thumbnails", in: header) as? [[String: Any]]) ?? []
            let thumb = (thumbs.last?["url"] as? String).flatMap { URL(string: $0) }
            let lines = (meta["lines"] as? [Any]) ?? []
            var details = ""
            if lines.count > 1, let items = JSONWalk.first("items", in: lines[1]) as? [Any] {
                details = items.compactMap { item -> String? in
                    JSONWalk.first("text", in: item).flatMap { JSONWalk.text($0) }
                }.filter { $0 != "•" }.joined(separator: " • ")
            }
            let video = FeedVideo(id: id, title: title, author: author, durationSec: duration, percentWatched: percent,
                                  thumbnail: thumb, details: details)
            return isForKids(video) ? nil : video
        }
    }

    private static func collect(_ key: String, in node: Any, into out: inout [[String: Any]]) {
        if let dict = node as? [String: Any] {
            if let hit = dict[key] as? [String: Any] { out.append(hit) }
            for v in dict.values { collect(key, in: v, into: &out) }
        } else if let arr = node as? [Any] {
            for v in arr { collect(key, in: v, into: &out) }
        }
    }

    /// The section list's own "more shelves" token (not the per-shelf ones).
    private static func sectionContinuation(_ root: Any) -> String? {
        var token: String?
        func find(_ node: Any) {
            if let dict = node as? [String: Any] {
                for (k, v) in dict {
                    if (k == "sectionListRenderer" || k == "sectionListContinuation"), let list = v as? [String: Any],
                       let conts = list["continuations"] as? [[String: Any]] {
                        for c in conts {
                            if let t = (c["nextContinuationData"] as? [String: Any])?["continuation"] as? String { token = t }
                        }
                    }
                    find(v)
                }
            } else if let arr = node as? [Any] {
                arr.forEach(find)
            }
        }
        find(root)
        return token
    }

    /// "1:02:03" -> 3723
    static func parseDuration(_ text: String) -> Double {
        let parts = text.split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count == text.split(separator: ":").count else { return 0 }
        return parts.reduce(0) { $0 * 60 + $1 }
    }

    // Same kids filter as Smarter Tube on the Fire TV (YouTube gives no "made for kids" flag here)
    private static let kids = try! NSRegularExpression(pattern:
        "\\bkids?\\b|for kids|for children|children'?s songs?|nursery|rhymes|toddler|preschool|baby shark|"
        + "peppa|cocomelon|moonbug|ben and holly|ben & holly|blippi|paw patrol|bluey|pinkfong|little baby bum|"
        + "super simple|chuchu|muffin man|wheels on the bus|cartoons? for|kids tv|kidstv|baby songs?|"
        + "learn colou?rs|finger family|hey bear|morphle|little angel|dave and ava|bebefinn|ms rachel|"
        + "pj masks|masha and the bear|thomas & friends|thomas and friends|fireman sam|teletubbies",
        options: [.caseInsensitive])

    static func isForKids(_ v: FeedVideo) -> Bool {
        let text = v.title + " | " + v.author
        return kids.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

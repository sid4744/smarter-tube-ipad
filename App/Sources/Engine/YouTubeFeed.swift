import Foundation

/// One video from the home feed or the watch history.
struct FeedVideo: Identifiable, Equatable {
    let id: String
    let title: String
    let author: String
    let durationSec: Double
    /// 0...100 for history items (how far you got), else nil.
    let percentWatched: Double?
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
            let video = FeedVideo(id: id, title: title, author: author, durationSec: duration, percentWatched: percent)
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

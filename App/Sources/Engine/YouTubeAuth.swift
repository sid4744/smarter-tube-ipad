import Foundation
import Security

/// Signs in the way a smart TV does (ported from SmartTube's MediaServiceCore):
/// the app shows a code, you confirm it at google.com/device on your phone.
/// The YouTube TV web app's own client id/secret are read from its JavaScript.
enum YouTubeAuth {
    static let tvUserAgent = "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/25.lts.30.1034943-gold (unlike Gecko), Unknown_TV_Unknown_0/Unknown (Unknown, Unknown)"
    static let scope = "http://gdata.youtube.com https://www.googleapis.com/auth/youtube-paid-content"

    struct Client: Codable {
        let id: String
        let secret: String
    }

    struct DeviceCode: Decodable {
        let deviceCode: String
        let userCode: String
        let verificationUrl: String?
        let expiresIn: Int?
        let interval: Int?

        enum CodingKeys: String, CodingKey {
            case deviceCode = "device_code", userCode = "user_code", verificationUrl = "verification_url"
            case expiresIn = "expires_in", interval
        }
    }

    struct Tokens: Codable {
        var refreshToken: String
        var accessToken: String
        var expiresAt: Date
        var client: Client
    }

    enum AuthError: LocalizedError {
        case noClient, denied(String), expired, badResponse

        var errorDescription: String? {
            switch self {
            case .noClient: return "Couldn't read YouTube TV's sign-in details."
            case .denied(let why): return "Sign-in refused: \(why)"
            case .expired: return "The code expired. Get a new one."
            case .badResponse: return "YouTube sent an unexpected answer."
            }
        }
    }

    // MARK: - Steps

    /// YouTube TV's own OAuth client, read from the /tv page's base script.
    static func fetchClient() async throws -> Client {
        let page = try await get("https://www.youtube.com/tv")
        let patterns = [#"id="base-js" src="(.*?)""#, #"\.src = '(.*?m=base)'"#, #"\.src = '(.*?)'; .\.id = 'base-js'"#]
        guard let path = patterns.lazy.compactMap({ firstMatch($0, in: page) }).first else { throw AuthError.noClient }
        let js = try await get(path.hasPrefix("http") ? path : "https://www.youtube.com" + path)
        guard let id = firstMatch(#"clientId:"([-\w]+\.apps\.googleusercontent\.com)",\n?[$\w]+:"\w+""#, in: js),
              let secret = firstMatch(#"clientId:"[-\w]+\.apps\.googleusercontent\.com",\n?[$\w]+:"(\w+)""#, in: js)
        else { throw AuthError.noClient }
        return Client(id: id, secret: secret)
    }

    static func requestCode(client: Client) async throws -> DeviceCode {
        let body: [String: Any] = ["client_id": client.id, "device_id": UUID().uuidString.lowercased(),
                                   "model_name": "ytlr::", "scope": scope]
        let data = try await post("https://www.youtube.com/o/oauth2/device/code", json: body)
        return try JSONDecoder().decode(DeviceCode.self, from: data)
    }

    /// Waits until the code is confirmed on the phone (or expires / is refused).
    static func waitForTokens(client: Client, code: DeviceCode) async throws -> Tokens {
        let deadline = Date().addingTimeInterval(TimeInterval(code.expiresIn ?? 1800))
        var interval = UInt64(max(code.interval ?? 5, 2))
        while Date() < deadline {
            try Task.checkCancellation()
            let data = try await post("https://www.youtube.com/o/oauth2/token", json: [
                "code": code.deviceCode, "client_id": client.id, "client_secret": client.secret,
                "grant_type": "http://oauth.net/grant_type/device/1.0"])
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            if let refresh = obj["refresh_token"] as? String, let access = obj["access_token"] as? String {
                let expires = (obj["expires_in"] as? Double) ?? 3600
                return Tokens(refreshToken: refresh, accessToken: access,
                              expiresAt: Date().addingTimeInterval(expires), client: client)
            }
            switch obj["error"] as? String {
            case "authorization_pending", nil: break
            case "slow_down": interval += 2
            case "expired_token": throw AuthError.expired
            case let other?: throw AuthError.denied(other)
            }
            try await Task.sleep(nanoseconds: interval * 1_000_000_000)
        }
        throw AuthError.expired
    }

    /// A fresh access token (refreshed when it's about to run out).
    static func accessToken(_ tokens: inout Tokens) async throws -> String {
        if tokens.expiresAt.timeIntervalSinceNow > 60 {
            return tokens.accessToken
        }
        let data = try await post("https://www.youtube.com/o/oauth2/token", json: [
            "refresh_token": tokens.refreshToken, "client_id": tokens.client.id,
            "client_secret": tokens.client.secret, "grant_type": "refresh_token"])
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard let access = obj["access_token"] as? String else {
            throw AuthError.denied((obj["error"] as? String) ?? "refresh failed")
        }
        tokens.accessToken = access
        tokens.expiresAt = Date().addingTimeInterval((obj["expires_in"] as? Double) ?? 3600)
        Keychain.save(tokens)
        return access
    }

    /// The signed-in account's display name (and photo), via the TV client's accounts list.
    static func accountInfo(accessToken: String) async throws -> (name: String?, photo: URL?) {
        let body: [String: Any] = [
            "context": ["client": ["clientName": "TVHTML5", "clientVersion": "7.20260901.15.00",
                                   "userAgent": tvUserAgent, "hl": "en"]],
            "accountReadMask": ["returnOwner": true, "returnBrandAccounts": true, "returnPersonaAccounts": false]]
        let data = try await post("https://www.youtube.com/youtubei/v1/account/accounts_list?prettyPrint=false",
                                  json: body, bearer: accessToken)
        let root = try JSONSerialization.jsonObject(with: data)
        let name = JSONWalk.first("accountName", in: root).flatMap(JSONWalk.text)
        let photo = JSONWalk.first("accountPhoto", in: root)
            .flatMap { JSONWalk.first("url", in: $0) as? String }
            .flatMap { URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }
        return (name, photo)
    }

    // MARK: - HTTP

    static func get(_ url: String) async throws -> String {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue(tvUserAgent, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        return String(decoding: data, as: UTF8.self)
    }

    static func post(_ url: String, json: [String: Any], bearer: String? = nil) async throws -> Data {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(tvUserAgent, forHTTPHeaderField: "User-Agent")
        if let bearer { req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: json)
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }
}

/// Small helpers for digging through YouTube's deeply nested JSON.
enum JSONWalk {
    /// First value stored under `key`, anywhere in the tree (depth-first).
    static func first(_ key: String, in node: Any) -> Any? {
        if let dict = node as? [String: Any] {
            if let v = dict[key] { return v }
            for v in dict.values { if let found = first(key, in: v) { return found } }
        } else if let arr = node as? [Any] {
            for v in arr { if let found = first(key, in: v) { return found } }
        }
        return nil
    }

    /// Text of a YouTube text object: {"simpleText": ...} or {"runs": [{"text": ...}]}.
    static func text(_ node: Any) -> String? {
        if let s = node as? String { return s }
        guard let dict = node as? [String: Any] else { return nil }
        if let s = dict["simpleText"] as? String { return s }
        if let runs = dict["runs"] as? [[String: Any]] {
            return runs.compactMap { $0["text"] as? String }.joined()
        }
        return nil
    }
}

/// The sign-in lives in the iPad's Keychain (this device only).
enum Keychain {
    private static let service = "app.smarter.tv.youtube"
    private static let account = "tokens"

    static func save(_ tokens: YouTubeAuth.Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        delete()
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                                    kSecValueData as String: data]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func load() -> YouTubeAuth.Tokens? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return try? JSONDecoder().decode(YouTubeAuth.Tokens.self, from: data)
    }

    static func delete() {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}

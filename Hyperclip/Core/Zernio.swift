import Foundation

/// Posting clips to social networks through Zernio (zernio.com), which holds the connections to X, YouTube, TikTok,
/// Instagram, LinkedIn, Facebook, Threads, Bluesky and the rest. Accounts are connected in Zernio's dashboard;
/// Hyperclip only needs an API key.
nonisolated enum Zernio {
    static let base = URL(string: "https://zernio.com/api/v1")!

    struct Account: Identifiable, Hashable, Sendable, Decodable {
        var id: String
        var platform: String
        var username: String?
        var displayName: String?
        var profilePicture: String?
        var isActive: Bool?
        var needsReconnection: Bool?

        enum CodingKeys: String, CodingKey {
            case id = "_id", platform, username, displayName, profilePicture, isActive, needsReconnection
        }

        var name: String { displayName ?? username ?? Zernio.name(of: platform) }
        var handle: String? { username.map { $0.hasPrefix("@") ? $0 : "@\($0)" } }
        var isUsable: Bool { isActive != false && needsReconnection != true }
    }

    /// Who sees a YouTube upload.
    enum Visibility: String, CaseIterable, Identifiable, Sendable {
        case `public`, unlisted, `private`
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    /// TikTok's privacy levels; an account may not offer all of them.
    enum TikTokPrivacy: String, CaseIterable, Identifiable, Sendable {
        case everyone = "PUBLIC_TO_EVERYONE", friends = "MUTUAL_FOLLOW_FRIENDS", followers = "FOLLOWER_OF_CREATOR", me = "SELF_ONLY"
        var id: String { rawValue }
        var label: String {
            switch self {
            case .everyone: "Everyone"
            case .friends: "Friends"
            case .followers: "Followers"
            case .me: "Only me"
            }
        }
    }

    struct Post: Sendable {
        var caption: String
        var title: String
        var accounts: [Account]
        var youtubeVisibility: Visibility = .public
        var tiktokPrivacy: TikTokPrivacy = .everyone
        /// Nil publishes right away.
        var schedule: Date?
    }

    /// How a post went on one platform.
    struct Outcome: Identifiable, Sendable, Hashable {
        var id: String { platform + (url ?? "") + status }
        var platform: String
        var status: String
        var url: String?
        var error: String?

        var succeeded: Bool { ["published", "scheduled", "pending", "publishing"].contains(status) }
    }

    enum Failure: LocalizedError {
        case noKey, server(Int, String)

        var errorDescription: String? {
            switch self {
            case .noKey: "Add your Zernio API key in Settings › Publishing."
            case .server(let status, let message): status == 401 ? "Zernio refused the API key. Check it in Settings › Publishing." : message
            }
        }
    }

    static var hasKey: Bool { Secret.zernio.value != nil }

    static func accounts() async throws -> [Account] {
        struct Response: Decodable { var accounts: [Account] }
        let data = try await request("GET", "accounts")
        return try JSONDecoder().decode(Response.self, from: data).accounts
            .sorted { ($0.platform, $0.name) < ($1.platform, $1.name) }
    }

    /// Uploads the file to Zernio's storage, then creates the post on every chosen account.
    static func publish(_ file: URL, post: Post, progress: @escaping @Sendable (Double, String) -> Void) async throws -> [Outcome] {
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
        progress(0, "Preparing the upload")
        let presign = try await request("POST", "media/presign", body: ["filename": file.lastPathComponent, "contentType": "video/mp4", "size": size])
        guard let object = try JSONSerialization.jsonObject(with: presign) as? [String: Any],
              let upload = (object["uploadUrl"] as? String).flatMap(URL.init(string:)), let publicURL = object["publicUrl"] as? String
        else { throw Failure.server(0, "Zernio didn't return an upload address.") }

        try await put(file, to: upload) { fraction in progress(fraction * 0.85, "Uploading \(Int(fraction * 100))%") }

        progress(0.9, post.schedule == nil ? "Publishing" : "Scheduling")
        let platforms: [[String: Any]] = post.accounts.map { account in
            var entry: [String: Any] = ["platform": account.platform, "accountId": account.id]
            if account.platform == "youtube" {
                entry["platformSpecificData"] = ["title": String(post.title.prefix(100)), "visibility": post.youtubeVisibility.rawValue]
            }
            return entry
        }
        var body: [String: Any] = [
            "content": post.caption,
            "title": post.title,
            "mediaItems": [["url": publicURL, "type": "video"]],
            "platforms": platforms,
        ]
        if post.accounts.contains(where: { $0.platform == "tiktok" }) {
            body["tiktokSettings"] = [
                "privacy_level": post.tiktokPrivacy.rawValue, "allow_comment": true, "allow_duet": true, "allow_stitch": true,
                "content_preview_confirmed": true, "express_consent_given": true,
            ]
        }
        if let schedule = post.schedule {
            body["scheduledFor"] = ISO8601DateFormatter().string(from: schedule)
        } else {
            body["publishNow"] = true
        }
        let data = try await request("POST", "posts", body: body, timeout: 600, accepting: [200, 201, 207])
        progress(1, "Done")
        return outcomes(from: data, accounts: post.accounts, scheduled: post.schedule != nil)
    }

    private static func outcomes(from data: Data, accounts: [Account], scheduled: Bool) -> [Outcome] {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let post = object?["post"] as? [String: Any] ?? object ?? [:]
        let entries = post["platforms"] as? [[String: Any]] ?? []
        guard !entries.isEmpty else {
            return accounts.map { Outcome(platform: $0.platform, status: scheduled ? "scheduled" : "published") }
        }
        return entries.map { entry in
            let error = entry["error"] as? String ?? (entry["error"] as? [String: Any])?["message"] as? String ?? entry["errorMessage"] as? String
            return Outcome(platform: entry["platform"] as? String ?? "?", status: entry["status"] as? String ?? (error == nil ? "published" : "failed"),
                           url: entry["platformPostUrl"] as? String, error: error)
        }
    }

    private static func request(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 60,
                                accepting: Set<Int> = [200, 201]) async throws -> Data {
        guard let key = Secret.zernio.value else { throw Failure.noKey }
        var request = URLRequest(url: base.appending(path: path), timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "Idempotency-Key")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard accepting.contains(status) else {
            let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = object?["error"] as? String ?? object?["message"] as? String ?? String(decoding: data.prefix(240), as: UTF8.self)
            throw Failure.server(status, "Zernio answered HTTP \(status): \(message)")
        }
        return data
    }

    /// The upload goes straight to storage, without the API key.
    private static func put(_ file: URL, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        var request = URLRequest(url: url, timeoutInterval: 1800)
        request.httpMethod = "PUT"
        request.setValue("video/mp4", forHTTPHeaderField: "Content-Type")
        let watcher = UploadProgress(progress)
        let (_, response) = try await URLSession.shared.upload(for: request, fromFile: file, delegate: watcher)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw Failure.server(status, "The upload failed with HTTP \(status).") }
    }

    static func name(of platform: String) -> String {
        switch platform {
        case "twitter": "X"
        case "youtube": "YouTube"
        case "tiktok": "TikTok"
        case "linkedin": "LinkedIn"
        case "instagram": "Instagram"
        case "facebook": "Facebook"
        case "threads": "Threads"
        case "bluesky": "Bluesky"
        case "pinterest": "Pinterest"
        case "reddit": "Reddit"
        case "snapchat": "Snapchat"
        case "telegram": "Telegram"
        default: platform.capitalized
        }
    }

    /// One test call for Settings: the connected accounts.
    static func test() async throws -> String {
        let accounts = try await accounts()
        let platforms = Set(accounts.map { name(of: $0.platform) }).sorted()
        return accounts.isEmpty ? "Connected, but no accounts yet. Connect some in Zernio's dashboard."
            : "Connected: \(accounts.count) account\(accounts.count == 1 ? "" : "s") on \(platforms.joined(separator: ", "))."
    }
}

nonisolated private final class UploadProgress: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let report: @Sendable (Double) -> Void
    init(_ report: @escaping @Sendable (Double) -> Void) { self.report = report }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        report(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
    }
}

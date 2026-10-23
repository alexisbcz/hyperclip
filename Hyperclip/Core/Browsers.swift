import AppKit
import CommonCrypto
import Security
import SQLite3

/// A browser whose cookies yt-dlp can sign in with, for videos that need an account: age-restricted, members-only,
/// private, or anything a site hides from downloaders it doesn't recognize.
nonisolated struct Browser: Identifiable, Hashable, Sendable {
    enum Engine: Hashable, Sendable {
        case safari
        /// `keychain` is the Keychain item the browser keeps its cookie key in. When yt-dlp knows the browser it reads the
        /// cookies itself (`ytdlp`); otherwise Hyperclip decrypts them and hands yt-dlp a cookies.txt.
        case chromium(keychain: String, ytdlp: String?)
        case firefox
    }

    let id: String
    let name: String
    let bundleID: String
    let engine: Engine
    /// Under ~/Library/Application Support, the folder holding its profiles.
    let dataFolder: String

    nonisolated var root: URL {
        if engine == .safari {
            return URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Containers/com.apple.Safari/Data/Library/Cookies")
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: dataFolder, directoryHint: .isDirectory)
    }

    var appURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) }

    var icon: NSImage? { appURL.map { NSWorkspace.shared.icon(forFile: $0.path) } }

    var isInstalled: Bool {
        appURL != nil && (engine == .safari || FileManager.default.fileExists(atPath: root.path))
    }

    static let all: [Browser] = [
        Browser(id: "safari", name: "Safari", bundleID: "com.apple.Safari", engine: .safari, dataFolder: ""),
        Browser(id: "chrome", name: "Google Chrome", bundleID: "com.google.Chrome", engine: .chromium(keychain: "Chrome Safe Storage", ytdlp: "chrome"), dataFolder: "Google/Chrome"),
        Browser(id: "arc", name: "Arc", bundleID: "company.thebrowser.Browser", engine: .chromium(keychain: "Arc Safe Storage", ytdlp: nil), dataFolder: "Arc/User Data"),
        Browser(id: "dia", name: "Dia", bundleID: "company.thebrowser.dia", engine: .chromium(keychain: "Dia Safe Storage", ytdlp: nil), dataFolder: "Dia/User Data"),
        Browser(id: "brave", name: "Brave", bundleID: "com.brave.Browser", engine: .chromium(keychain: "Brave Safe Storage", ytdlp: "brave"), dataFolder: "BraveSoftware/Brave-Browser"),
        Browser(id: "edge", name: "Microsoft Edge", bundleID: "com.microsoft.edgemac", engine: .chromium(keychain: "Microsoft Edge Safe Storage", ytdlp: "edge"), dataFolder: "Microsoft Edge"),
        Browser(id: "helium", name: "Helium", bundleID: "net.imput.helium", engine: .chromium(keychain: "Chromium Safe Storage", ytdlp: "chromium"), dataFolder: "net.imput.helium"),
        Browser(id: "chromium", name: "Chromium", bundleID: "org.chromium.Chromium", engine: .chromium(keychain: "Chromium Safe Storage", ytdlp: "chromium"), dataFolder: "Chromium"),
        Browser(id: "vivaldi", name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi", engine: .chromium(keychain: "Vivaldi Safe Storage", ytdlp: "vivaldi"), dataFolder: "Vivaldi"),
        Browser(id: "opera", name: "Opera", bundleID: "com.operasoftware.Opera", engine: .chromium(keychain: "Opera Safe Storage", ytdlp: "opera"), dataFolder: "com.operasoftware.Opera"),
        Browser(id: "comet", name: "Comet", bundleID: "ai.perplexity.comet", engine: .chromium(keychain: "Comet Safe Storage", ytdlp: nil), dataFolder: "Comet"),
        Browser(id: "firefox", name: "Firefox", bundleID: "org.mozilla.firefox", engine: .firefox, dataFolder: "Firefox"),
        Browser(id: "zen", name: "Zen", bundleID: "app.zen-browser.zen", engine: .firefox, dataFolder: "zen"),
        Browser(id: "librewolf", name: "LibreWolf", bundleID: "io.gitlab.librewolf-community", engine: .firefox, dataFolder: "librewolf"),
    ]

    static var installed: [Browser] { all.filter(\.isInstalled) }

    static func with(id: String?) -> Browser? { all.first { $0.id == id } }

    struct Profile: Identifiable, Hashable, Sendable {
        /// The profile's folder, relative to the browser's data folder.
        var id: String
        var name: String
    }

    /// Profiles by the names shown in the browser.
    var profiles: [Profile] {
        switch engine {
        case .safari:
            return []
        case .chromium:
            let state = root.appending(path: "Local State")
            guard let data = try? Data(contentsOf: state),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cache = (json["profile"] as? [String: Any])?["info_cache"] as? [String: Any]
            else {
                return FileManager.default.fileExists(atPath: root.appending(path: "Default").path) ? [Profile(id: "Default", name: "Default")] : []
            }
            return cache.map { folder, info in
                Profile(id: folder, name: ((info as? [String: Any])?["name"] as? String) ?? folder)
            }
            .sorted { $0.id == "Default" || ($1.id != "Default" && $0.name < $1.name) }
        case .firefox:
            let ini = (try? String(contentsOf: root.appending(path: "profiles.ini"), encoding: .utf8)) ?? ""
            var profiles: [Profile] = []
            var name: String?
            for line in ini.split(whereSeparator: \.isNewline) {
                if line.hasPrefix("[") { name = nil }
                if line.hasPrefix("Name=") { name = String(line.dropFirst(5)) }
                if line.hasPrefix("Path=") {
                    let path = String(line.dropFirst(5))
                    profiles.append(Profile(id: path, name: name ?? path))
                }
            }
            return profiles
        }
    }

    func folder(of profile: String?) -> URL? {
        guard let profile, !profile.isEmpty else { return nil }
        return root.appending(path: profile, directoryHint: .isDirectory)
    }
}

/// The cookies to send with downloads, as chosen in Settings › Downloads.
nonisolated struct CookieSource: Sendable {
    var browser: Browser?
    var profile: String?
    var file: URL?

    static var current: CookieSource {
        let defaults = UserDefaults.standard
        let source = defaults.string(forKey: Pref.cookieSource) ?? "none"
        if source == "file" {
            return CookieSource(file: defaults.string(forKey: Pref.cookieFile).flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) })
        }
        return CookieSource(browser: Browser.with(id: source), profile: defaults.string(forKey: Pref.cookieProfile))
    }

    var isEmpty: Bool { browser == nil && file == nil }

    /// yt-dlp's arguments for these cookies, writing a cookies.txt first for browsers it can't read itself.
    /// The caller deletes `temporary` when the download is over.
    func arguments() throws -> (arguments: [String], temporary: URL?) {
        if let file { return (["--cookies", file.path], nil) }
        guard let browser else { return ([], nil) }
        let profileFolder = profile.flatMap { $0.isEmpty ? nil : browser.root.appending(path: $0, directoryHint: .isDirectory) }
        switch browser.engine {
        case .safari:
            return (["--cookies-from-browser", "safari"], nil)
        case .firefox:
            let folder = profileFolder ?? browser.root
            return (["--cookies-from-browser", browser.id == "firefox" && profileFolder == nil ? "firefox" : "firefox:\(folder.path)"], nil)
        case .chromium(let keychain, let ytdlp):
            if let ytdlp {
                // yt-dlp finds its own browsers' folders; any other one sharing their Keychain item needs the path.
                let folder = profileFolder ?? browser.root.appending(path: "Default")
                return (["--cookies-from-browser", browser.id == ytdlp && profileFolder == nil ? ytdlp : "\(ytdlp):\(folder.path)"], nil)
            }
            let folder = profileFolder ?? browser.root.appending(path: "Default")
            let file = FileManager.default.temporaryDirectory.appending(path: "hyperclip-cookies-\(UUID().uuidString).txt")
            try ChromiumCookies.export(profile: folder, keychain: keychain, to: file)
            return (["--cookies", file.path], file)
        }
    }

    /// Reads the cookies once and reports how many there are, so Settings can show it works before a download needs it.
    func test() async throws -> String {
        if let file {
            let text = try String(contentsOf: file, encoding: .utf8)
            let count = text.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("#") || $0.hasPrefix("#HttpOnly_") }.count
            return "\(count) cookies in \(file.lastPathComponent)"
        }
        let (arguments, temporary) = try arguments()
        defer { temporary.map { try? FileManager.default.removeItem(at: $0) } }
        if let temporary {
            return try Self.summary(of: temporary)
        }
        // With --cookies and no URL, yt-dlp saves the cookies it read, then complains there was nothing to download.
        let ytdlp = try Tools.require(.ytdlp)
        let output = FileManager.default.temporaryDirectory.appending(path: "hyperclip-test-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: output) }
        let log = (try? await Shell.run(ytdlp, arguments + ["--cookies", output.path])) ?? ""
        guard FileManager.default.fileExists(atPath: output.path) else {
            throw CookieError.unreadable(Shell.Failure(tool: "yt-dlp", status: 1, output: log).errorDescription ?? "yt-dlp couldn't read them.")
        }
        return try Self.summary(of: output)
    }

    private static func summary(of file: URL) throws -> String {
        let lines = try String(contentsOf: file, encoding: .utf8).split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("#") || $0.hasPrefix("#HttpOnly_") }
        let youtube = lines.filter { $0.contains("youtube.com") }.count
        return "Read \(lines.count) cookies" + (youtube > 0 ? ", \(youtube) of them for YouTube" : ". None are for YouTube; sign in there first.")
    }
}

nonisolated enum CookieError: LocalizedError {
    case keychain(String)
    case noDatabase(URL)
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .keychain(let item): "Couldn't read “\(item)” from the Keychain. Allow Hyperclip when macOS asks."
        case .noDatabase(let folder): "No cookies in \(folder.path). Pick another profile."
        case .unreadable(let message): message
        }
    }
}

/// Reads a Chromium browser's cookies the way the browser does on macOS: a key derived from a password in the Keychain,
/// then AES-128-CBC, and writes them as a Netscape cookies.txt yt-dlp understands.
nonisolated enum ChromiumCookies {
    static func export(profile: URL, keychain: String, to file: URL) throws {
        let database = [profile.appending(path: "Network/Cookies"), profile.appending(path: "Cookies")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
        guard let database else { throw CookieError.noDatabase(profile) }
        let password = try keychainPassword(keychain)
        let key = deriveKey(password)

        // The browser holds the database open, so read a copy.
        let copy = FileManager.default.temporaryDirectory.appending(path: "hyperclip-\(UUID().uuidString).sqlite")
        try FileManager.default.copyItem(at: database, to: copy)
        defer { try? FileManager.default.removeItem(at: copy) }

        var db: OpaquePointer?
        guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw CookieError.unreadable("Couldn't open the cookie database.")
        }
        defer { sqlite3_close(db) }

        // From version 24, each value starts with a hash of its domain.
        var version = 0
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = 'version'", -1, &statement, nil) == SQLITE_OK,
           sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) {
            version = Int(String(cString: text)) ?? 0
        }
        sqlite3_finalize(statement)

        let query = "SELECT host_key, name, value, encrypted_value, path, expires_utc, is_secure, is_httponly FROM cookies"
        guard sqlite3_prepare_v2(db, query, -1, &statement, nil) == SQLITE_OK else {
            throw CookieError.unreadable("The cookie database isn't in a format Hyperclip knows.")
        }
        defer { sqlite3_finalize(statement) }

        var lines = ["# Netscape HTTP Cookie File", "# Written by Hyperclip for yt-dlp", ""]
        while sqlite3_step(statement) == SQLITE_ROW {
            let host = string(statement, 0)
            let name = string(statement, 1)
            var value = string(statement, 2)
            if value.isEmpty, let blob = sqlite3_column_blob(statement, 3) {
                let encrypted = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 3)))
                guard let decrypted = decrypt(encrypted, key: key, stripsHash: version >= 24) else { continue }
                value = decrypted
            }
            let path = string(statement, 4)
            let expires = sqlite3_column_int64(statement, 5)
            let unix = expires > 0 ? max(0, expires / 1_000_000 - 11_644_473_600) : 0
            let secure = sqlite3_column_int(statement, 6) != 0
            let httpOnly = sqlite3_column_int(statement, 7) != 0
            let domain = (httpOnly ? "#HttpOnly_" : "") + host
            lines.append([domain, host.hasPrefix(".") ? "TRUE" : "FALSE", path, secure ? "TRUE" : "FALSE", String(unix), name, value].joined(separator: "\t"))
        }
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func string(_ statement: OpaquePointer?, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    private static func keychainPassword(_ service: String) throws -> Data {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            throw CookieError.keychain(service)
        }
        return data
    }

    private static func deriveKey(_ password: Data) -> Data {
        let salt = Array("saltysalt".utf8)
        var key = [UInt8](repeating: 0, count: kCCKeySizeAES128)
        password.withUnsafeBytes { raw in
            _ = CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), raw.baseAddress?.assumingMemoryBound(to: CChar.self), password.count,
                                     salt, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003, &key, key.count)
        }
        return Data(key)
    }

    private static func decrypt(_ data: Data, key: Data, stripsHash: Bool) -> String? {
        guard data.count > 3, data.prefix(3) == Data("v10".utf8) else { return nil }
        let payload = data.dropFirst(3)
        let iv = [UInt8](repeating: 0x20, count: kCCBlockSizeAES128)
        var output = [UInt8](repeating: 0, count: payload.count + kCCBlockSizeAES128)
        var length = 0
        let status = key.withUnsafeBytes { keyBytes in
            payload.withUnsafeBytes { input in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count, iv, input.baseAddress, payload.count, &output, output.count, &length)
            }
        }
        guard status == kCCSuccess else { return nil }
        var bytes = output.prefix(length)
        if stripsHash, bytes.count >= 32 { bytes = bytes.dropFirst(32) }
        return String(bytes: bytes, encoding: .utf8)
    }
}

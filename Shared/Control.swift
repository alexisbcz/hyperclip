import Foundation

/// How the `hyperclip` command, its MCP server and anything else on this Mac drive the app.
///
/// The app listens on `Control.socket` for one JSON object per line, `{"method": "...", "params": {...}}`,
/// and answers each with `{"ok": true, "result": ...}` or `{"ok": false, "error": "..."}`. The app does all
/// the work, so whatever an agent starts shows in the window as it happens. Methods are listed in `ControlMethod`.
nonisolated enum Control {
    static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Hyperclip", directoryHint: .isDirectory)
    }

    /// Only your user can open it.
    static var socket: URL { support.appending(path: "control.sock") }

    static let bundleID = "dev.alexis.Hyperclip"
}

/// Every method the app answers. A project is its id (or the start of it), a word of its title, or `latest`.
/// A clip is its id (or the start of it) or its number in time order, from 1.
nonisolated enum ControlMethod: String, CaseIterable, Sendable {
    /// → `{version, tools, settings summary, busy}`
    case status
    /// → `[ProjectSummary]`
    case listProjects
    /// Params: `project`. → `ProjectDetail`, with clips, exports and what it's busy with.
    case getProject
    /// Params: `url` or `path`, `from`, `to` (seconds, downloads only part). → `ProjectSummary`; work goes on in the background.
    case importVideo
    /// Params: `project`, `engine` (apple, whisper, api), `language`.
    case transcribe
    /// Params: `project`, `format` (text, words, srt, sentences), `from`, `to`. → `{text}` or `{words}` or `{sentences}`.
    case transcript
    /// Params: `project`, `method` (heuristic, decision, llm), `count`, `minLength`, `maxLength`, `guidance`.
    case findClips
    /// Params: `project`, `start`, `end` (seconds), `title`. → `ClipInfo`
    case addClip
    /// Params: `project`, `clip`, and any of `start`, `end`, `title`, `framing` (speaker, center, default). → `ClipInfo`
    case updateClip
    /// Params: `project`, `clip`.
    case deleteClip
    /// Params: `project`, `clips` (array; omit for every clip), `best` (the top N by score), and overrides
    /// `aspect` (vertical, portrait, square, original), `framing`, `resolution` (p1080, p720, source), `captions` (bold, clean, boxed, pop, none).
    /// → `{queued: [clip ids]}`; poll `getProject` for `exporting` and `exports`.
    case export
    /// → `[ExportInfo]`, newest first.
    case listExports
    /// Params: `export` (id or start of it, or `latest`), `accounts` (Zernio account ids, or platform names like
    /// `youtube`), `caption`, `title`, `at` (ISO 8601, to schedule), `visibility`, `tiktokPrivacy`, `tiktokConsent`.
    /// → `[{platform, status, url, error}]`
    case publish
    /// → Zernio accounts `[{id, platform, username, displayName}]`
    case accounts
    /// → `{key: value}` for every setting in `ControlSettings`.
    case getSettings
    /// Params: `key`, `value`. → the new settings.
    case setSetting
    /// → Whisper and Liquid models with `kind` (whisper, decision, language), `installed`, `selected`, `downloading`.
    case listModels
    /// Params: `model` (an id like large-v3-turbo-q5_0 or d1-Omni-2B).
    case downloadModel
    /// Params: `project`. Stops what it's doing.
    case cancel
    /// Params: `project`. Removes it and anything it downloaded; exports stay.
    case deleteProject
    /// Params: `project`, `clip`. Brings the window forward on it.
    case show
}

nonisolated struct ControlRequest: Codable, Sendable {
    var method: String
    var params: [String: JSONValue] = [:]

    init(method: String, params: [String: JSONValue] = [:]) {
        self.method = method
        self.params = params
    }

    /// `params` may be left out: `{"method": "status"}`.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        method = try c.decode(String.self, forKey: .method)
        params = try c.decodeIfPresent([String: JSONValue].self, forKey: .params) ?? [:]
    }
}

nonisolated struct ControlResponse: Codable, Sendable {
    var ok: Bool
    var result: JSONValue?
    var error: String?
}

nonisolated struct ControlError: LocalizedError, Sendable {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Sends requests to the app. Blocking, so call it off the main thread.
nonisolated enum ControlClient {
    static func send(_ method: ControlMethod, params: [String: JSONValue] = [:], timeout: TimeInterval = 60) throws -> JSONValue {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlError("Couldn't open a socket.") }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_un.make(Control.socket.path)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { throw ControlError("Hyperclip isn't running.") }

        var line = try JSONEncoder().encode(ControlRequest(method: method.rawValue, params: params))
        line.append(0x0A)
        try line.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress! + offset, buffer.count - offset)
                guard n > 0 else { throw ControlError("Lost the connection to Hyperclip.") }
                offset += n
            }
        }
        var reply = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        while !reply.contains(0x0A) {
            let n = read(fd, &chunk, chunk.count)
            guard n > 0 else { throw ControlError(n == 0 ? "Hyperclip closed the connection." : "Hyperclip didn't answer in time.") }
            reply.append(contentsOf: chunk[0..<n])
        }
        let response = try JSONDecoder().decode(ControlResponse.self, from: reply.prefix { $0 != 0x0A })
        guard response.ok else { throw ControlError(response.error ?? "Hyperclip refused \(method.rawValue).") }
        return response.result ?? .null
    }

    static var isAppRunning: Bool { (try? send(.status, timeout: 3)) != nil }
}

nonisolated extension sockaddr_un {
    static func make(_ path: String) -> sockaddr_un {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            let bytes = Array(path.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return addr
    }
}

/// Any JSON value, for method parameters and results.
nonisolated enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { o[key] } else { nil }
    }

    var string: String? { if case .string(let s) = self { s } else { nil } }
    var double: Double? { if case .number(let n) = self { n } else { nil } }
    var int: Int? { double.map { Int($0) } }
    var bool: Bool? { if case .bool(let b) = self { b } else { nil } }
    var array: [JSONValue]? { if case .array(let a) = self { a } else { nil } }

    /// Round-trips any Encodable through JSON.
    init(encoding value: some Encodable) throws {
        self = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }

    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(T.self, from: JSONEncoder().encode(self))
    }
}

nonisolated extension JSONValue {
    var object: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }

    /// Pretty JSON, for `--json` and agents.
    var pretty: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(self)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}

nonisolated extension JSONValue: ExpressibleByStringLiteral, ExpressibleByBooleanLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral, ExpressibleByNilLiteral {
    init(stringLiteral value: String) { self = .string(value) }
    init(booleanLiteral value: Bool) { self = .bool(value) }
    init(integerLiteral value: Int) { self = .number(Double(value)) }
    init(floatLiteral value: Double) { self = .number(value) }
    init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    init(dictionaryLiteral elements: (String, JSONValue)...) { self = .object(Dictionary(elements, uniquingKeysWith: { $1 })) }
    init(nilLiteral: ()) { self = .null }
}

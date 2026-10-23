import AppKit
import Observation

/// A command-line tool Hyperclip runs.
nonisolated enum Tool: String, CaseIterable, Identifiable, Sendable {
    case ytdlp, ffmpeg, whisper

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ytdlp: "yt-dlp"
        case .ffmpeg: "FFmpeg"
        case .whisper: "whisper.cpp"
        }
    }

    var purpose: String {
        switch self {
        case .ytdlp: "Downloads videos from YouTube, TikTok, X, Twitch and over a thousand other sites."
        case .ffmpeg: "Lets yt-dlp merge the best video and audio streams, and converts videos the Mac can't play."
        case .whisper: "Runs Whisper models on the GPU for transcription."
        }
    }

    /// Executable names to look for, in order.
    var executables: [String] {
        switch self {
        case .ytdlp: ["yt-dlp", "yt-dlp_macos"]
        case .ffmpeg: ["ffmpeg"]
        case .whisper: ["whisper-cli", "whisper-cpp"]
        }
    }

    var pathPreference: String {
        switch self {
        case .ytdlp: Pref.ytdlpPath
        case .ffmpeg: Pref.ffmpegPath
        case .whisper: Pref.whisperPath
        }
    }

    var formula: String {
        switch self {
        case .ytdlp: "yt-dlp"
        case .ffmpeg: "ffmpeg"
        case .whisper: "whisper-cpp"
        }
    }

    var homepage: URL {
        switch self {
        case .ytdlp: URL(string: "https://github.com/yt-dlp/yt-dlp")!
        case .ffmpeg: URL(string: "https://ffmpeg.org")!
        case .whisper: URL(string: "https://github.com/ggml-org/whisper.cpp")!
        }
    }

    /// Where it is: the path set in Settings, else the first match on the search path.
    var location: URL? {
        let manager = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: pathPreference), !custom.isEmpty {
            return manager.isExecutableFile(atPath: custom) ? URL(fileURLWithPath: custom) : nil
        }
        for folder in Shell.searchPath {
            for name in executables {
                let path = folder + "/" + name
                if manager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    var missingMessage: String {
        "\(name) isn't installed. Install it from Settings › Tools, or with Homebrew: brew install \(formula)"
    }
}

/// What's installed, which versions, and installs in progress.
@Observable
final class Tools {
    static let shared = Tools()

    /// Where Hyperclip puts tools it downloads itself.
    nonisolated static let binFolder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Hyperclip/bin", directoryHint: .isDirectory)

    private(set) var locations: [Tool: URL] = [:]
    private(set) var versions: [Tool: String] = [:]
    private(set) var busy: Set<Tool> = []
    private(set) var log: [Tool: String] = [:]
    private(set) var errors: [Tool: String] = [:]

    init() { refresh() }

    var hasHomebrew: Bool { Self.homebrew != nil }

    private static var homebrew: URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"].first { FileManager.default.isExecutableFile(atPath: $0) }.map(URL.init(fileURLWithPath:))
    }

    func refresh() {
        for tool in Tool.allCases {
            locations[tool] = tool.location
        }
        Task {
            for tool in Tool.allCases {
                versions[tool] = await Self.version(of: tool)
            }
        }
    }

    func isInstalled(_ tool: Tool) -> Bool { locations[tool] != nil }

    private nonisolated static func version(of tool: Tool) async -> String? {
        guard let url = tool.location else { return nil }
        switch tool {
        case .ytdlp:
            return try? await Shell.run(url, ["--version"]).trimmingCharacters(in: .whitespacesAndNewlines)
        case .ffmpeg:
            let output = try? await Shell.run(url, ["-version"])
            return output?.split(separator: "\n").first?.split(separator: " ").dropFirst(2).first.map(String.init)
        case .whisper:
            return nil
        }
    }

    /// Downloads yt-dlp's self-contained macOS build into Hyperclip's own folder, which needs neither Homebrew nor Python.
    func downloadYtdlp() {
        run(.ytdlp) { tools in
            let source = URL(string: "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!
            let (file, response) = try await URLSession.shared.download(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try FileManager.default.createDirectory(at: Self.binFolder, withIntermediateDirectories: true)
            let destination = Self.binFolder.appending(path: "yt-dlp")
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: file, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
            tools.append("Downloaded to \(destination.path)", for: .ytdlp)
        }
    }

    /// Sites change all the time and yt-dlp keeps up, so updating fixes most failed downloads.
    func update(_ tool: Tool) {
        guard let url = locations[tool] else { return install(tool) }
        if tool == .ytdlp, !url.path.contains("/Cellar/"), url.resolvingSymlinksInPath().path.contains("Homebrew") == false,
           !url.path.hasPrefix("/opt/homebrew"), !url.path.hasPrefix("/usr/local") {
            run(tool) { tools in
                try await Shell.run(url, ["-U"]) { line in Task { @MainActor in tools.append(line, for: tool) } }
            }
        } else {
            brew(["upgrade", tool.formula], for: tool)
        }
    }

    func install(_ tool: Tool) {
        if hasHomebrew {
            brew(["install", tool.formula], for: tool)
        } else if tool == .ytdlp {
            downloadYtdlp()
        } else {
            NSWorkspace.shared.open(tool.homepage)
        }
    }

    private func brew(_ arguments: [String], for tool: Tool) {
        guard let brew = Self.homebrew else { return }
        run(tool) { tools in
            try await Shell.run(brew, arguments) { line in Task { @MainActor in tools.append(line, for: tool) } }
        }
    }

    private func run(_ tool: Tool, _ body: @escaping (Tools) async throws -> Void) {
        guard !busy.contains(tool) else { return }
        busy.insert(tool)
        errors[tool] = nil
        log[tool] = ""
        Task {
            do {
                try await body(self)
            } catch {
                errors[tool] = error.localizedDescription
            }
            busy.remove(tool)
            refresh()
        }
    }

    private func append(_ line: String, for tool: Tool) {
        log[tool, default: ""] += line + "\n"
    }

    /// The tool, or an error that says how to get it.
    nonisolated static func require(_ tool: Tool) throws -> URL {
        guard let url = tool.location else { throw ToolMissing(tool: tool) }
        return url
    }
}

nonisolated struct ToolMissing: LocalizedError {
    var tool: Tool
    var errorDescription: String? { tool.missingMessage }
}

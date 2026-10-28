import AppKit
import Observation

/// A command-line tool Hyperclip runs.
nonisolated enum Tool: String, CaseIterable, Identifiable, Sendable {
    case ytdlp, ffmpeg, whisper, llama

    var id: String { rawValue }

    var name: String {
        switch self {
        case .ytdlp: "yt-dlp"
        case .ffmpeg: "FFmpeg"
        case .whisper: "whisper.cpp"
        case .llama: "llama.cpp"
        }
    }

    var purpose: String {
        switch self {
        case .ytdlp: "Downloads videos from YouTube, TikTok, X, Twitch and over a thousand other sites."
        case .ffmpeg: "Lets yt-dlp merge the best video and audio streams, and converts videos the Mac can't play."
        case .whisper: "Runs Whisper models on the GPU for transcription."
        case .llama: "Runs Liquid's d1 and LFM3 models on this Mac to find clips. Hyperclip starts and stops it as needed."
        }
    }

    /// Executable names to look for, in order.
    var executables: [String] {
        switch self {
        case .ytdlp: ["yt-dlp", "yt-dlp_macos"]
        case .ffmpeg: ["ffmpeg"]
        case .whisper: ["whisper-cli", "whisper-cpp"]
        case .llama: ["llama-server"]
        }
    }

    var pathPreference: String {
        switch self {
        case .ytdlp: Pref.ytdlpPath
        case .ffmpeg: Pref.ffmpegPath
        case .whisper: Pref.whisperPath
        case .llama: Pref.llamaPath
        }
    }

    var formula: String {
        switch self {
        case .ytdlp: "yt-dlp"
        case .ffmpeg: "ffmpeg"
        case .whisper: "whisper-cpp"
        case .llama: "llama.cpp"
        }
    }

    var homepage: URL {
        switch self {
        case .ytdlp: URL(string: "https://github.com/yt-dlp/yt-dlp")!
        case .ffmpeg: URL(string: "https://ffmpeg.org")!
        case .whisper: URL(string: "https://github.com/ggml-org/whisper.cpp")!
        case .llama: URL(string: "https://github.com/ggml-org/llama.cpp")!
        }
    }

    /// Where it is: the path set in Settings, else the first match on the search path.
    /// llama.cpp is only the release Hyperclip installs, since older builds (Homebrew's among them) can't run LFM3.
    var location: URL? {
        let manager = FileManager.default
        if let custom = UserDefaults.standard.string(forKey: pathPreference), !custom.isEmpty {
            return manager.isExecutableFile(atPath: custom) ? URL(fileURLWithPath: custom) : nil
        }
        for folder in self == .llama ? [LlamaServer.folder.path] : Shell.searchPath {
            for name in executables {
                let path = folder + "/" + name
                if manager.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
            }
        }
        return nil
    }

    var missingMessage: String {
        if self == .llama { return "llama.cpp isn't installed. Install it under Models & Tools." }
        return "\(name) isn't installed. Install it from Settings › Tools, or with Homebrew: brew install \(formula)"
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
        case .llama:
            // "version: 0.8.0-dev (build 11960, commit 8642541b2)"
            let output = try? await Shell.run(url, ["--version"])
            return output?.firstMatch(of: /build (\d+)/).map { "b\($0.1)" }
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

    /// Downloads llama.cpp's macOS release into Hyperclip's own folder. Homebrew's build is too old for LFM3.
    func downloadLlama() {
        run(.llama) { tools in try await tools.fetchLlama() }
    }

    /// llama.cpp, installing it first if it isn't, for a caller that needs it now.
    @discardableResult
    func requireLlama() async throws -> URL {
        while busy.contains(.llama) { try await Task.sleep(for: .milliseconds(300)) }
        if let url = Tool.llama.location { return url }
        busy.insert(.llama)
        errors[.llama] = nil
        log[.llama] = ""
        defer {
            busy.remove(.llama)
            refresh()
        }
        do {
            try await fetchLlama()
        } catch {
            errors[.llama] = error.localizedDescription
            throw error
        }
        return try Self.require(.llama)
    }

    private func fetchLlama() async throws {
        append("Downloading \(LlamaServer.archive.absoluteString)", for: .llama)
        let (file, response) = try await URLSession.shared.download(from: LlamaServer.archive)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        defer { try? FileManager.default.removeItem(at: file) }
        try FileManager.default.createDirectory(at: Self.binFolder, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: LlamaServer.folder)
        // The archive unpacks to llama-<release>/, with its libraries next to the programs.
        try await Shell.run(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", file.path, "-C", Self.binFolder.path])
        _ = try? await Shell.run(URL(fileURLWithPath: "/usr/bin/xattr"), ["-dr", "com.apple.quarantine", LlamaServer.folder.path])
        guard Tool.llama.location != nil else { throw Finder.Failure.server("The llama.cpp download has no llama-server in it.") }
        append("Installed in \(LlamaServer.folder.path)", for: .llama)
    }

    /// Sites change all the time and yt-dlp keeps up, so updating fixes most failed downloads.
    func update(_ tool: Tool) {
        guard let url = locations[tool] else { return install(tool) }
        if tool == .llama { return downloadLlama() }
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
        if tool == .llama {
            downloadLlama()
        } else if hasHomebrew {
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

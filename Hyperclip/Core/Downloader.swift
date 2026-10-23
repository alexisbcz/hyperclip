import Foundation

/// Downloads a video with yt-dlp, preferring H.264 in an MP4 so AVFoundation can play, edit and export it.
nonisolated enum Downloader {
    struct Progress: Sendable {
        var fraction: Double?
        var detail: String
    }

    struct Result: Sendable {
        var file: URL
        var title: String?
        var channel: String?
    }

    /// `section` downloads only that span of the video, in seconds.
    static func download(_ url: String, to folder: URL, section: ClosedRange<Double>? = nil,
                         progress: @escaping @Sendable (Progress) -> Void) async throws -> Result {
        let ytdlp = try Tools.require(.ytdlp)
        let hasFFmpeg = Tool.ffmpeg.location != nil
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let defaults = UserDefaults.standard
        let height = defaults.object(forKey: Pref.maxHeight) == nil ? Defaults.maxHeight : defaults.integer(forKey: Pref.maxHeight)
        var arguments = [
            "--newline", "--progress", "--no-playlist", "--no-mtime", "--no-part",
            "--progress-template", "download:HCPROG %(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--print", "before_dl:HCMETA %(title)j|%(uploader,channel)j",
            "--print", "after_move:HCFILE %(filepath)s",
            "-o", folder.path + "/video.%(ext)s",
        ]
        if hasFFmpeg {
            // Separate streams, merged: YouTube only serves its best quality that way.
            let limit = height > 0 ? "res:\(height)," : ""
            arguments += ["-S", "\(limit)vcodec:h264,acodec:aac", "--merge-output-format", "mp4"]
            if let ffmpeg = Tool.ffmpeg.location { arguments += ["--ffmpeg-location", ffmpeg.path] }
        } else {
            let limit = height > 0 ? "[height<=\(height)]" : ""
            arguments += ["-f", "b[ext=mp4]\(limit)/b\(limit)/b"]
        }
        if let section {
            arguments += ["--download-sections", "*\(section.lowerBound)-\(section.upperBound)"]
            if hasFFmpeg { arguments += ["--force-keyframes-at-cuts"] }
        }
        if let rate = defaults.string(forKey: Pref.rateLimit), !rate.trimmingCharacters(in: .whitespaces).isEmpty {
            arguments += ["-r", rate.trimmingCharacters(in: .whitespaces)]
        }
        let (cookies, temporary) = try CookieSource.current.arguments()
        defer { temporary.map { try? FileManager.default.removeItem(at: $0) } }
        arguments += cookies
        arguments += split(defaults.string(forKey: Pref.extraArguments) ?? "")
        arguments += ["--", url]

        let state = DownloadState()
        progress(Progress(fraction: nil, detail: "Starting yt-dlp"))
        try await Shell.run(ytdlp, arguments) { line in
            if let update = state.read(line) { progress(update) }
        }
        guard let file = state.file ?? newestVideo(in: folder) else {
            throw Shell.Failure(tool: "yt-dlp", status: 1, output: "ERROR: yt-dlp finished without saving a video.")
        }
        return Result(file: file, title: state.title, channel: state.channel)
    }

    /// The video's title and length without downloading it, for the import box.
    static func info(_ url: String) async throws -> (title: String, duration: Double?) {
        let ytdlp = try Tools.require(.ytdlp)
        let (cookies, temporary) = try CookieSource.current.arguments()
        defer { temporary.map { try? FileManager.default.removeItem(at: $0) } }
        let output = try await Shell.run(ytdlp, ["--no-playlist", "--skip-download", "--print", "%(title)s|%(duration)s"] + cookies + ["--", url])
        let line = output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        let parts = line.split(separator: "|", omittingEmptySubsequences: false)
        return (parts.first.map(String.init) ?? url, parts.count > 1 ? Double(parts[1]) : nil)
    }

    private static func newestVideo(in folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { ["mp4", "mov", "m4v", "mkv", "webm"].contains($0.pathExtension.lowercased()) }
            .max { ($0.modificationDate ?? .distantPast) < ($1.modificationDate ?? .distantPast) }
    }

    /// Splits extra arguments like a shell would, honoring quotes.
    static func split(_ text: String) -> [String] {
        var arguments: [String] = []
        var current = ""
        var quote: Character?
        var hasToken = false
        for character in text {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" {
                quote = character
                hasToken = true
            } else if character.isWhitespace {
                if hasToken || !current.isEmpty { arguments.append(current) }
                current = ""
                hasToken = false
            } else {
                current.append(character)
            }
        }
        if hasToken || !current.isEmpty { arguments.append(current) }
        return arguments
    }
}

/// What yt-dlp has said so far, read from its output.
nonisolated private final class DownloadState: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var file: URL?
    private(set) var title: String?
    private(set) var channel: String?
    /// yt-dlp downloads the video and audio streams one after the other, each from 0 to 100%.
    private var stream = 0

    func read(_ line: String) -> Downloader.Progress? {
        lock.lock()
        defer { lock.unlock() }
        if line.hasPrefix("HCMETA ") {
            let parts = line.dropFirst(7).split(separator: "|", maxSplits: 1).map(String.init)
            title = parts.first.flatMap(Self.decode)
            channel = parts.count > 1 ? Self.decode(parts[1]) : nil
            return Downloader.Progress(fraction: nil, detail: title.map { "Found “\($0)”" } ?? "Found the video")
        }
        if line.hasPrefix("HCFILE ") {
            file = URL(fileURLWithPath: String(line.dropFirst(7)))
            return nil
        }
        if line.contains("[download] Destination:") {
            stream += 1
            return nil
        }
        if line.hasPrefix("HCPROG ") {
            let parts = line.dropFirst(7).split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let percent = parts.first.flatMap({ Double($0.replacingOccurrences(of: "%", with: "")) }) else { return nil }
            var detail = stream > 1 ? "Downloading the audio" : "Downloading the video"
            if parts.count > 1, !parts[1].isEmpty, parts[1] != "Unknown B/s", parts[1] != "N/A" { detail += " · \(parts[1])" }
            if parts.count > 2, !parts[2].isEmpty, parts[2] != "Unknown", parts[2] != "N/A" { detail += " · \(parts[2]) left" }
            return Downloader.Progress(fraction: percent / 100, detail: detail)
        }
        if line.hasPrefix("[Merger]") || line.hasPrefix("[VideoConvertor]") {
            return Downloader.Progress(fraction: nil, detail: "Merging video and audio")
        }
        if line.hasPrefix("[youtube]") || line.hasPrefix("[info]") {
            return Downloader.Progress(fraction: nil, detail: "Reading the page")
        }
        return nil
    }

    private static func decode(_ json: String) -> String? {
        guard let data = json.data(using: .utf8), let value = try? JSONDecoder().decode(String?.self, from: data) else { return nil }
        return value
    }
}

extension URL {
    nonisolated var modificationDate: Date? {
        (try? resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }
}

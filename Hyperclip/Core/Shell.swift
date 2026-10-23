import Foundation

/// Runs the command-line tools Hyperclip leans on (yt-dlp, ffmpeg, whisper.cpp), streaming their output line by line.
nonisolated enum Shell {
    struct Failure: LocalizedError {
        var tool: String
        var status: Int32
        var output: String

        var errorDescription: String? {
            // The last lines are where tools explain themselves; an "ERROR:" line, if yt-dlp wrote one, is the best of them.
            let lines = output.split(whereSeparator: \.isNewline).map(String.init)
            if let error = lines.last(where: { $0.hasPrefix("ERROR:") }) {
                return error.replacingOccurrences(of: "ERROR: ", with: "")
            }
            let tail = lines.suffix(3).joined(separator: "\n")
            return tail.isEmpty ? "\(tool) stopped with status \(status)." : tail
        }
    }

    /// Where Homebrew and friends put tools; apps opened from the Finder don't get the shell's PATH.
    static let searchPath = [
        Tools.binFolder.path, "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
        NSHomeDirectory() + "/.local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
    ]

    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let existing = environment["PATH"].map { [$0] } ?? []
        environment["PATH"] = (searchPath + existing).joined(separator: ":")
        environment["PYTHONUNBUFFERED"] = "1"
        return environment
    }

    /// Runs to completion and returns everything it printed. Cancelling the task stops the process.
    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], in directory: URL? = nil,
                    onLine: (@Sendable (String) -> Void)? = nil) async throws -> String {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice

        let buffer = LineBuffer(onLine: onLine)
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else {
                buffer.append(data)
            }
        }

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                process.terminationHandler = { process in
                    continuation.resume(returning: process.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        output.fileHandleForReading.readabilityHandler = nil
        if let rest = try? output.fileHandleForReading.readToEnd() { buffer.append(rest) }
        buffer.flush()
        try Task.checkCancellation()
        let text = buffer.text
        guard status == 0 else {
            throw Failure(tool: executable.lastPathComponent, status: status, output: text)
        }
        return text
    }
}

/// Collects a process's output and hands over each complete line, splitting on carriage returns too,
/// since progress bars redraw a line with them.
nonisolated private final class LineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func append(_ chunk: Data) {
        lock.lock()
        data.append(chunk)
        pending.append(chunk)
        var lines: [String] = []
        while let index = pending.firstIndex(where: { $0 == 10 || $0 == 13 }) {
            let line = pending[pending.startIndex..<index]
            pending.removeSubrange(pending.startIndex...index)
            if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
        }
        lock.unlock()
        lines.forEach { onLine?($0) }
    }

    func flush() {
        lock.lock()
        let rest = pending
        pending.removeAll()
        lock.unlock()
        if !rest.isEmpty { onLine?(String(decoding: rest, as: UTF8.self)) }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

import Foundation

/// One `hyperclip` subcommand. Each group of commands lives in its own file as static members, and
/// main.swift lists them all in `commands`, so adding one touches one line there.
nonisolated struct Command: Sendable {
    let name: String
    var aliases: [String] = []
    /// The arguments, after the name: "<project> [--wait]".
    var arguments = ""
    /// One line for `hyperclip --help`.
    let summary: String
    /// More, for `hyperclip help <command>`.
    var details = ""
    let run: @Sendable (inout Arguments) throws -> Void

    var usage: String { "hyperclip \(name)\(arguments.isEmpty ? "" : " \(arguments)")" }
}

/// What's left of the command line, taken as a command reads it.
nonisolated struct Arguments {
    private(set) var items: [String]
    /// Everything after a lone `--`, passed through untouched (`exec`, `ssh`).
    private(set) var passthrough: [String]?

    init(_ items: [String]) {
        if let dash = items.firstIndex(of: "--") {
            self.items = Array(items[..<dash])
            passthrough = Array(items[(dash + 1)...])
        } else {
            self.items = items
        }
    }

    /// Takes `--name` if it's there.
    mutating func flag(_ names: String...) -> Bool {
        guard let i = items.firstIndex(where: names.contains) else { return false }
        items.remove(at: i)
        return true
    }

    /// Takes `--name value` or `--name=value`.
    mutating func option(_ name: String) throws -> String? {
        if let i = items.firstIndex(where: { $0.hasPrefix(name + "=") }) {
            return String(items.remove(at: i).dropFirst(name.count + 1))
        }
        guard let i = items.firstIndex(of: name) else { return nil }
        guard i + 1 < items.count else { throw Failure("\(name) needs a value.") }
        items.remove(at: i)
        return items.remove(at: i)
    }

    /// Takes the next argument that isn't an option.
    mutating func next(_ what: String) throws -> String {
        guard let value = optionalNext() else { throw Failure("missing \(what).") }
        return value
    }

    mutating func optionalNext() -> String? {
        guard let i = items.firstIndex(where: { !$0.hasPrefix("-") || $0 == "-" }) else { return nil }
        return items.remove(at: i)
    }

    /// Takes whatever's left, options included.
    mutating func rest() -> [String] {
        defer { items = [] }
        return items
    }

    /// Fails on anything a command didn't take, so a typo doesn't pass silently.
    func done() throws {
        if let extra = items.first { throw Failure("unexpected \(extra).") }
    }
}

nonisolated struct Failure: LocalizedError {
    let errorDescription: String?
    /// The process's exit status.
    var status: Int32 = 1
    init(_ message: String, status: Int32 = 1) {
        errorDescription = message
        self.status = status
    }
}

// MARK: - The app

/// Reaching the app, which does the work: it's started hidden when it isn't running.
nonisolated enum App {
    /// The Hyperclip.app this command belongs to: it lives at Hyperclip.app/Contents/Resources/bin/hyperclip, or
    /// beside it in a build folder. Nil when it's neither, and Launch Services finds the app by bundle id.
    static var url: URL? {
        let me = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).resolvingSymlinksInPath()
        let inside = me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if inside.pathExtension == "app" { return inside }
        let beside = me.deletingLastPathComponent().appending(path: "Hyperclip.app")
        return FileManager.default.fileExists(atPath: beside.path) ? beside : nil
    }

    static var version: String {
        url.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String } ?? "dev"
    }

    /// Starts Hyperclip in the background, without a window coming forward, and waits for its socket.
    static func ensureRunning() throws {
        if ControlClient.isAppRunning { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-g", "-j"] + (url.map { ["-a", $0.path] } ?? ["-b", Control.bundleID])
        p.standardError = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw Failure("couldn't open Hyperclip. Is it installed?") }
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            if ControlClient.isAppRunning { return }
            usleep(300_000)
        }
        throw Failure("Hyperclip opened but didn't answer. Open it once by hand, then try again.")
    }

    @discardableResult
    static func call(_ method: ControlMethod, _ params: [String: JSONValue] = [:], timeout: TimeInterval = 120) throws -> JSONValue {
        try ensureRunning()
        do {
            return try ControlClient.send(method, params: params, timeout: timeout)
        } catch let error as ControlError {
            throw Failure(error.errorDescription ?? "Hyperclip refused \(method.rawValue).")
        }
    }

    /// Waits while a project downloads, transcribes or finds clips. `report` gets each change of step.
    static func waitUntilIdle(_ project: String, limit: TimeInterval = .infinity, report: (JSONValue) -> Void = { _ in }) throws -> JSONValue {
        let deadline = Date().addingTimeInterval(limit)
        usleep(300_000)
        while true {
            let detail = try call(.getProject, ["project": .string(project)])
            if detail["busy"]?.bool != true || Date() > deadline { return detail }
            report(detail)
            usleep(500_000)
        }
    }

    /// Waits for queued exports to finish, reporting the progress of the one going.
    static func waitForExports(_ project: String, clips: Set<String>, limit: TimeInterval = .infinity, report: (Double, Int) -> Void = { _, _ in }) throws -> JSONValue {
        let deadline = Date().addingTimeInterval(limit)
        while true {
            let detail = try call(.getProject, ["project": .string(project)])
            let going = (detail["exporting"]?.object ?? [:]).filter { clips.contains($0.key) }
            if going.isEmpty || Date() > deadline { return detail }
            report(going.values.compactMap(\.double).max() ?? 0, going.count)
            usleep(500_000)
        }
    }
}

// MARK: - Output

nonisolated func printJSON(_ value: JSONValue) {
    print(value.pretty)
}

/// Columns padded to line up, the last one left ragged.
nonisolated func printTable(_ header: [String], _ rows: [[String]]) {
    let all = [header] + rows
    let widths = header.indices.map { column in all.map { $0[column].count }.max() ?? 0 }
    for row in all {
        let cells = row.enumerated().map { i, cell in i == row.count - 1 ? cell : cell.padding(toLength: widths[i], withPad: " ", startingAt: 0) }
        print(cells.joined(separator: "  "))
    }
}

nonisolated func printError(_ message: String) {
    FileHandle.standardError.write(Data("hyperclip: \(message)\n".utf8))
}

/// One status line on stderr, redrawn in place on a terminal.
nonisolated final class StatusLine: @unchecked Sendable {
    private var last = ""
    private let isTerminal = isatty(STDERR_FILENO) != 0

    func show(_ text: String) {
        guard text != last else { return }
        last = text
        if isTerminal {
            FileHandle.standardError.write(Data("\r\u{1B}[K\(text)".utf8))
        } else {
            FileHandle.standardError.write(Data("\(text)\n".utf8))
        }
    }

    func finish() {
        if isTerminal, !last.isEmpty { FileHandle.standardError.write(Data("\r\u{1B}[K".utf8)) }
        last = ""
    }
}

/// "Transcribing 42% · Whisper (whisper.cpp)" from a project's status.
nonisolated func describe(_ status: JSONValue?) -> String {
    guard let status else { return "" }
    if let text = status.string { return text }
    var line = status["step"]?.string ?? "Working"
    if let progress = status["progress"]?.double { line += " \(Int(progress * 100))%" }
    if let detail = status["detail"]?.string, !detail.isEmpty { line += " · \(detail)" }
    return line
}

nonisolated extension Double {
    /// 1:05 or 1:02:03.
    var clock: String {
        guard isFinite else { return "0:00" }
        let total = Int(self.rounded(.down))
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
}

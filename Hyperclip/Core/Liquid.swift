import AppKit
import Observation

/// One of Liquid's open models, in llama.cpp's GGUF format from Hugging Face, run by the llama-server Hyperclip manages.
nonisolated struct LiquidModel: Identifiable, Hashable, Sendable {
    enum Role: Sendable { case decision, language }

    /// Also the name llama-server serves it under.
    let id: String
    let name: String
    let summary: String
    let role: Role
    let file: String
    var projector: String?
    let size: Int64
    var hearsAudio = false
    var recommended = false
    /// llama-server options for this model, as in its presets file.
    var options: [String: String] = [:]

    var repo: String { "LiquidAI/\(id)-GGUF" }
    var fileNames: [String] { [file] + (projector.map { [$0] } ?? []) }
    func source(_ name: String) -> URL { URL(string: "https://huggingface.co/\(repo)/resolve/main/\(name)")! }

    static let licence = URL(string: "https://huggingface.co/LiquidAI/d1-2B/blob/main/LICENSE")!

    // A question is read in one batch, so the batch holds the state and a clip's sound; four requests run at once.
    private static let decisionOptions = ["batch-size": "8192", "ubatch-size": "8192", "ctx-size": "32768", "parallel": "4"]

    static let all: [LiquidModel] = [
        LiquidModel(id: "d1-Omni-2B", name: "d1-Omni-2B", summary: "Decision model that also hears each clip, so the delivery counts, not only the words.",
                    role: .decision, file: "d1-Omni-2B-Q8_0.gguf", projector: "mmproj-d1-Omni-2B-Q8_0.gguf", size: 2_172_345_280,
                    hearsAudio: true, recommended: true, options: decisionOptions),
        LiquidModel(id: "d1-2B", name: "d1-2B", summary: "Decision model that reads the transcript only. Better calibrated on text, and quicker.",
                    role: .decision, file: "d1-2B-Q8_0.gguf", projector: "mmproj-d1-2B-Q8_0.gguf", size: 2_049_272_160, options: decisionOptions),
        LiquidModel(id: "LFM3-1.7B", name: "LFM3-1.7B", summary: "Language model with a long memory: it reads hours of transcript at once and titles each clip.",
                    role: .language, file: "LFM3-1.7B-Q4_K_M.gguf", size: 1_099_627_808, recommended: true,
                    options: ["ctx-size": "131072", "parallel": "1"]),
    ]

    static var decisionModels: [LiquidModel] { all.filter { $0.role == .decision } }
    static let language = all.first { $0.id == "LFM3-1.7B" }!

    /// The decision model chosen in Settings.
    static var decision: LiquidModel {
        let id = Prefs.string(Pref.decisionLocalModel)
        return decisionModels.first { $0.id == id } ?? decisionModels[0]
    }

    static let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Hyperclip/Models/liquid", directoryHint: .isDirectory)

    /// LM Studio keeps the same files by repository, so one already there needn't download again.
    private var otherFolders: [URL] {
        [URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".lmstudio/models/\(repo)")]
    }

    func location(of name: String) -> URL? {
        ([Self.folder] + otherFolders).map { $0.appending(path: name) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var isDownloaded: Bool { fileNames.allSatisfy { location(of: $0) != nil } }
    var isShared: Bool { location(of: file).map { !$0.path.hasPrefix(Self.folder.path) } ?? false }
}

/// Downloads of Liquid's models, with progress.
@Observable
final class LiquidModels {
    static let shared = LiquidModels()

    private(set) var progress: [String: Double] = [:]
    private(set) var errors: [String: String] = [:]
    /// Bumped when files change, so views re-read what's on disk.
    private(set) var revision = 0
    @ObservationIgnored private var downloads: [String: Task<Void, Error>] = [:]
    @ObservationIgnored private var transfers: [String: URLSessionDownloadTask] = [:]

    func isDownloading(_ model: LiquidModel) -> Bool { progress[model.id] != nil }

    func download(_ model: LiquidModel) {
        Task { try? await fetch(model) }
    }

    /// Downloads what's missing of the model, or waits for the download under way.
    func fetch(_ model: LiquidModel, onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        if model.isDownloaded { return }
        if let running = downloads[model.id] {
            let watch = Task {
                while !Task.isCancelled, let fraction = progress[model.id] {
                    onProgress?(fraction)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { watch.cancel() }
            return try await running.value
        }
        errors[model.id] = nil
        progress[model.id] = 0
        let task = Task {
            var done: Int64 = 0
            for name in model.fileNames where model.location(of: name) == nil {
                try await fetch(model.source(name), to: LiquidModel.folder.appending(path: name), for: model) { received in
                    let fraction = min(1, Double(done + received) / Double(model.size))
                    self.progress[model.id] = fraction
                    onProgress?(fraction)
                }
                done += Int64(model.location(of: name).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0)
            }
        }
        downloads[model.id] = task
        defer {
            downloads[model.id] = nil
            progress[model.id] = nil
            revision += 1
        }
        do {
            try await task.value
        } catch {
            if (error as? URLError)?.code != .cancelled { errors[model.id] = error.localizedDescription }
            throw error
        }
    }

    private func fetch(_ source: URL, to destination: URL, for model: LiquidModel, onBytes: (Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: LiquidModel.folder, withIntermediateDirectories: true)
        let outcome = Outcome()
        let task = URLSession.shared.downloadTask(with: source) { file, response, error in
            if let error { return outcome.finish(error) }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let file, status == 200 else { return outcome.finish(Finder.Failure.server("Hugging Face answered with HTTP \(status).")) }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: file, to: destination)
                outcome.finish(nil)
            } catch {
                outcome.finish(error)
            }
        }
        transfers[model.id] = task
        defer { transfers[model.id] = nil }
        task.resume()
        while !outcome.isFinished {
            if Task.isCancelled { task.cancel() }
            onBytes(task.countOfBytesReceived)
            try? await Task.sleep(for: .milliseconds(300))
        }
        if let error = outcome.error { throw error }
    }

    func cancel(_ model: LiquidModel) {
        transfers[model.id]?.cancel()
    }

    func delete(_ model: LiquidModel) {
        guard !model.isShared else { return }
        for name in model.fileNames {
            if let file = model.location(of: name) { try? FileManager.default.removeItem(at: file) }
        }
        revision += 1
    }

    func reveal(_ model: LiquidModel) {
        if let file = model.location(of: model.file) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }
}

/// How a download ended, set from URLSession's queue and read on the main actor.
nonisolated private final class Outcome: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var failure: Error?

    func finish(_ error: Error?) {
        lock.withLock { done = true; failure = error }
    }

    var isFinished: Bool { lock.withLock { done } }
    var error: Error? { lock.withLock { failure } }
}

/// The llama-server Hyperclip runs for Liquid's models: one process in router mode, which loads the model a request names
/// and keeps one in memory at a time. It starts when a clip finder needs it and stops when Hyperclip quits or after a while unused.
@Observable
final class LlamaServer {
    static let shared = LlamaServer()

    enum State: Equatable { case stopped, starting, running }

    private(set) var state = State.stopped
    private(set) var port: Int?
    private(set) var log = ""
    private(set) var error: String?
    @ObservationIgnored private var process: Process?
    @ObservationIgnored private var served: Set<String> = []
    @ObservationIgnored private var users = 0
    @ObservationIgnored private var lastUse = Date()
    @ObservationIgnored private var idleWatch: Task<Void, Never>?

    /// The llama.cpp release Hyperclip installs: the first with LFM3 and d1 support.
    nonisolated static let release = "b11960"
    nonisolated static var folder: URL { Tools.binFolder.appending(path: "llama-\(release)", directoryHint: .isDirectory) }
    nonisolated static var archive: URL {
        URL(string: "https://github.com/ggml-org/llama.cpp/releases/download/\(release)/llama-\(release)-bin-macos-arm64.tar.gz")!
    }

    private static let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appending(path: "Hyperclip")
    private static var presets: URL { support.appending(path: "llama-server.ini") }
    private static var pidFile: URL { support.appending(path: "llama-server.pid") }
    private static let idleLimit: TimeInterval = 600

    var base: URL? { port.map { URL(string: "http://127.0.0.1:\($0)")! } }

    /// The server's address, ready for `model`: installs llama.cpp and downloads the model first if they're missing.
    /// Call `end()` when done, so the server can stop once nothing uses it.
    func begin(_ model: LiquidModel, progress: @escaping @Sendable (Double, String) -> Void) async throws -> URL {
        users += 1
        lastUse = Date()
        do {
            if !Tools.shared.isInstalled(.llama) {
                progress(0, "Installing llama.cpp")
                try await Tools.shared.requireLlama()
            }
            if !model.isDownloaded {
                progress(0, "Downloading \(model.name)")
                try await LiquidModels.shared.fetch(model) { fraction in progress(fraction, "Downloading \(model.name)") }
            }
            if state != .running || !served.contains(model.id) || process?.isRunning != true {
                progress(0, "Starting \(model.name)")
                try await start()
            }
            guard let base else { throw Finder.Failure.server("llama-server didn't start.") }
            return base
        } catch {
            end()
            throw error
        }
    }

    func end() {
        users = max(0, users - 1)
        lastUse = Date()
    }

    /// Starts the server with every downloaded model, or restarts it so it picks up new ones.
    func start() async throws {
        stop()
        let executable = try Tools.require(.llama)
        state = .starting
        error = nil
        log = ""
        let models = LiquidModel.all.filter(\.isDownloaded)
        guard !models.isEmpty else {
            state = .stopped
            throw Finder.Failure.server("Download a Liquid model first, under Models & Tools.")
        }
        try FileManager.default.createDirectory(at: Self.support, withIntermediateDirectories: true)
        try Self.presetsFile(models).write(to: Self.presets, atomically: true, encoding: .utf8)
        killLeftover()

        let port = Prefs.int(Pref.localPort, default: 0) > 0 ? Prefs.int(Pref.localPort, default: 0) : Self.freePort()
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--models-preset", Self.presets.path, "--models-max", "1", "--host", "127.0.0.1", "--port", String(port), "--no-webui"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        output.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { handle.readabilityHandler = nil; return }
            let text = String(decoding: data, as: UTF8.self)
            Task { @MainActor in LlamaServer.shared.append(text) }
        }
        process.terminationHandler = { _ in
            Task { @MainActor in LlamaServer.shared.exited(process) }
        }
        try process.run()
        self.process = process
        self.port = port
        served = Set(models.map(\.id))
        try? String(process.processIdentifier).write(to: Self.pidFile, atomically: true, encoding: .utf8)

        // The router answers at once; each model loads on its first request.
        let health = URL(string: "http://127.0.0.1:\(port)/health")!
        for _ in 0..<100 {
            guard process.isRunning else { break }
            if let (_, response) = try? await URLSession.shared.data(from: health), (response as? HTTPURLResponse)?.statusCode == 200 {
                state = .running
                watchIdle()
                return
            }
            try await Task.sleep(for: .milliseconds(200))
        }
        let tail = log.split(whereSeparator: \.isNewline).suffix(3).joined(separator: "\n")
        stop()
        throw Finder.Failure.server("llama-server didn't start. \(tail)")
    }

    func stop() {
        idleWatch?.cancel()
        idleWatch = nil
        if let process, process.isRunning { process.terminate() }
        process = nil
        port = nil
        served = []
        state = .stopped
        try? FileManager.default.removeItem(at: Self.pidFile)
    }

    private func exited(_ ended: Process) {
        guard ended === process else { return }
        if ended.terminationStatus != 0 { error = log.split(whereSeparator: \.isNewline).last.map(String.init) }
        stop()
    }

    private func append(_ text: String) {
        log += text
        if log.count > 40_000 { log = String(log.suffix(20_000)) }
    }

    private func watchIdle() {
        idleWatch = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                if users == 0, Date().timeIntervalSince(lastUse) > Self.idleLimit { stop() }
            }
        }
    }

    /// A server left behind by a Hyperclip that didn't quit cleanly.
    private func killLeftover() {
        guard let text = try? String(contentsOf: Self.pidFile, encoding: .utf8), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)),
              NSRunningApplication(processIdentifier: pid) == nil else { return }
        var name = [UInt8](repeating: 0, count: 256)
        let length = proc_name(pid, &name, UInt32(name.count))
        if length > 0, String(decoding: name.prefix(Int(length)), as: UTF8.self) == "llama-server" { kill(pid, SIGTERM) }
    }

    private nonisolated static func presetsFile(_ models: [LiquidModel]) -> String {
        models.map { model in
            var lines = ["[\(model.id)]", "model = \(model.location(of: model.file)!.path)"]
            if let projector = model.projector, let file = model.location(of: projector) { lines.append("mmproj = \(file.path)") }
            lines += model.options.sorted { $0.key < $1.key }.map { "\($0.key) = \($0.value)" }
            return lines.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }

    private nonisolated static func freePort() -> Int {
        let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(socket) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, size) == 0 && getsockname(socket, $0, &size) == 0 }
        }
        return bound ? Int(UInt16(bigEndian: address.sin_port)) : 18080
    }
}

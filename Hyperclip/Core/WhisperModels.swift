import AppKit
import Observation

/// A Whisper model in whisper.cpp's format, from Hugging Face.
nonisolated struct WhisperModel: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let summary: String
    let size: Int64
    var recommended = false

    var fileName: String { "ggml-\(id).bin" }
    var source: URL { URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(fileName)")! }

    static let all: [WhisperModel] = [
        WhisperModel(id: "large-v3-turbo-q5_0", name: "Large v3 Turbo (quantized)", summary: "Near the best accuracy at a third of the size. The one to get.", size: 574_041_195, recommended: true),
        WhisperModel(id: "large-v3-turbo", name: "Large v3 Turbo", summary: "Accurate in about a hundred languages and fast on Apple silicon.", size: 1_624_555_275),
        WhisperModel(id: "large-v3", name: "Large v3", summary: "The most accurate, and the slowest.", size: 3_095_033_483),
        WhisperModel(id: "medium", name: "Medium", summary: "Good accuracy, multilingual.", size: 1_533_763_059),
        WhisperModel(id: "small", name: "Small", summary: "Quick, decent in major languages.", size: 487_601_967),
        WhisperModel(id: "base", name: "Base", summary: "Fast drafts.", size: 147_951_465),
        WhisperModel(id: "base.en", name: "Base (English)", summary: "Fast, English only.", size: 147_964_211),
        WhisperModel(id: "tiny", name: "Tiny", summary: "Fastest, roughest.", size: 77_691_713),
    ]

    static let folder: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "Hyperclip/Models/whisper", directoryHint: .isDirectory)

    /// Where other apps keep whisper.cpp models, so one already on the Mac needn't download again.
    static let otherFolders: [URL] = [
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".cache/whisper-cpp"),
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".cache/whisper"),
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support/MacWhisper/models"),
    ]

    var file: URL? {
        ([Self.folder] + Self.otherFolders).map { $0.appending(path: fileName) }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    var isShared: Bool { file.map { !$0.path.hasPrefix(Self.folder.path) } ?? false }

    static var selected: WhisperModel {
        let id = UserDefaults.standard.string(forKey: Pref.whisperModel)
        return all.first { $0.id == id } ?? all.first { $0.file != nil } ?? all[0]
    }

    /// The chosen model's file, or any downloaded one if the chosen one isn't.
    static var selectedFile: URL? {
        selected.file ?? all.lazy.compactMap(\.file).first
    }
}

/// Downloads of Whisper models, with progress.
@Observable
final class WhisperModels {
    static let shared = WhisperModels()

    private(set) var progress: [String: Double] = [:]
    private(set) var errors: [String: String] = [:]
    /// Bumped when files change, so views re-read what's on disk.
    private(set) var revision = 0
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]

    func isDownloading(_ model: WhisperModel) -> Bool { progress[model.id] != nil }

    func download(_ model: WhisperModel) {
        guard tasks[model.id] == nil else { return }
        errors[model.id] = nil
        progress[model.id] = 0
        let task = URLSession.shared.downloadTask(with: model.source) { file, response, error in
            var failure = error?.localizedDescription
            if failure == nil, let file {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if status == 200 {
                    do {
                        try FileManager.default.createDirectory(at: WhisperModel.folder, withIntermediateDirectories: true)
                        let destination = WhisperModel.folder.appending(path: model.fileName)
                        try? FileManager.default.removeItem(at: destination)
                        try FileManager.default.moveItem(at: file, to: destination)
                    } catch {
                        failure = error.localizedDescription
                    }
                } else {
                    failure = "Hugging Face answered with HTTP \(status)."
                }
            }
            Task { @MainActor in WhisperModels.shared.finish(model, error: failure) }
        }
        tasks[model.id] = task
        task.resume()
        Task {
            while let task = tasks[model.id] {
                progress[model.id] = task.progress.fractionCompleted
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    func cancel(_ model: WhisperModel) {
        tasks[model.id]?.cancel()
    }

    private func finish(_ model: WhisperModel, error: String?) {
        tasks[model.id] = nil
        progress[model.id] = nil
        if let error, error != "cancelled" { errors[model.id] = error }
        if error == nil, UserDefaults.standard.string(forKey: Pref.whisperModel) == nil {
            UserDefaults.standard.set(model.id, forKey: Pref.whisperModel)
        }
        revision += 1
    }

    func delete(_ model: WhisperModel) {
        guard let file = model.file, !model.isShared else { return }
        try? FileManager.default.removeItem(at: file)
        revision += 1
    }

    func reveal(_ model: WhisperModel) {
        if let file = model.file { NSWorkspace.shared.activateFileViewerSelecting([file]) }
    }
}

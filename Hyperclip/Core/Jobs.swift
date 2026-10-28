import AppKit
import Observation

/// What each project is busy with, from download to export, and the steps that chain them.
@Observable
final class Jobs {
    static let shared = Jobs()

    struct Job: Equatable {
        enum Kind: Equatable {
            case download, convert, analyze, transcribe, find, frame

            var title: String {
                switch self {
                case .download: "Downloading"
                case .convert: "Converting"
                case .analyze: "Reading the audio"
                case .transcribe: "Transcribing"
                case .find: "Finding clips"
                case .frame: "Finding the speaker"
                }
            }
        }

        var kind: Kind
        var progress: Double?
        var detail: String = ""
    }

    /// The step each project is on.
    private(set) var running: [UUID: Job] = [:]
    /// Exports in progress, by clip.
    private(set) var exporting: [UUID: Double] = [:]
    /// The last thing that went wrong, by project.
    var errors: [UUID: String] = [:]
    /// Clips that just finished exporting, for the "Show in Finder" button.
    private(set) var exported: [UUID: URL] = [:]

    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var exportQueue: Task<Void, Never>?

    private var library: Library { .shared }

    func isBusy(_ id: UUID) -> Bool { running[id] != nil || tasks[id] != nil }

    // MARK: Import

    /// Starts a project for a link right away, so it shows in the sidebar while it downloads.
    @discardableResult
    func importLink(_ link: String, section: ClosedRange<Double>? = nil) -> UUID {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        var project = Project(title: URL(string: trimmed)?.host()?.replacingOccurrences(of: "www.", with: "") ?? "Video", sourceURL: trimmed)
        project.title = "Downloading from \(project.title)…"
        library.save(project)
        let id = project.id
        start(id) {
            self.set(id, .download, detail: "Starting")
            let folder = Library.folder(of: id)
            let result = try await Downloader.download(trimmed, to: folder, section: section) { update in
                Task { @MainActor in Jobs.shared.set(id, .download, progress: update.fraction, detail: update.detail) }
            }
            self.library.update(id) {
                $0.title = result.title ?? result.file.deletingPathExtension().lastPathComponent
                $0.channel = result.channel
                $0.media = result.file
            }
            try await self.prepare(id)
        }
        return id
    }

    /// Opens a video file where it is, converting a copy only if the Mac can't play it.
    @discardableResult
    func importFile(_ url: URL) -> UUID {
        let project = Project(title: url.deletingPathExtension().lastPathComponent, media: url)
        library.save(project)
        let id = project.id
        start(id) { try await self.prepare(id) }
        return id
    }

    /// Size, length, thumbnail and a playable file, then transcription and clips if those are on.
    private func prepare(_ id: UUID) async throws {
        guard var media = library.project(id)?.media else { throw Exporter.Failure.noVideo }
        set(id, .analyze, detail: "Reading the video")
        var info = try await Media.info(media)
        if !info.isPlayable {
            let converted = Library.folder(of: id).appending(path: "video-converted.mp4")
            set(id, .convert, progress: 0, detail: "Re-encoding to H.264 so it plays on the Mac")
            try await Media.convert(media, to: converted, duration: info.duration) { fraction in
                Task { @MainActor in Jobs.shared.set(id, .convert, progress: fraction, detail: "Re-encoding to H.264") }
            }
            // A download's original isn't needed any more; a file of yours is left alone.
            if media.path.hasPrefix(Library.folder(of: id).path) { try? FileManager.default.removeItem(at: media) }
            media = converted
            info = try await Media.info(media)
        }
        await Media.thumbnail(of: media, at: min(info.duration * 0.2, 30), to: Library.thumbnail(of: id))
        library.update(id) {
            $0.media = media
            $0.duration = info.duration
            $0.width = Double(info.size.width)
            $0.height = Double(info.size.height)
        }
        if info.hasAudio, Prefs.bool(Pref.autoTranscribe, default: true) {
            try await runTranscription(id)
            if Prefs.bool(Pref.autoFind, default: true) { try await runFinder(id) }
        }
    }

    // MARK: Transcription

    func transcribe(_ id: UUID, engine: TranscriptionEngine? = nil, language: String? = nil) {
        start(id) {
            try await self.runTranscription(id, engine: engine, language: language)
            if Prefs.bool(Pref.autoFind, default: true), self.library.project(id)?.clips.isEmpty ?? true { try await self.runFinder(id) }
        }
    }

    private func runTranscription(_ id: UUID, engine chosen: TranscriptionEngine? = nil, language: String? = nil) async throws {
        guard let project = library.project(id), let media = project.media else { throw Exporter.Failure.noVideo }
        set(id, .analyze, detail: "Extracting the sound")
        let wav = Library.folder(of: id).appending(path: "audio.wav")
        try FileManager.default.createDirectory(at: Library.folder(of: id), withIntermediateDirectories: true)
        let loudness = try await Media.extractAudio(media, to: wav)
        defer { try? FileManager.default.removeItem(at: wav) }
        library.update(id) { $0.loudness = loudness }

        let engine = chosen ?? .current
        set(id, .transcribe, progress: 0, detail: engine.title)
        let transcript = try await Transcriber.transcribe(wav, duration: project.duration, engine: engine, language: language ?? Prefs.language) { fraction in
            Task { @MainActor in Jobs.shared.set(id, .transcribe, progress: fraction, detail: engine.title) }
        }
        library.update(id) { $0.transcript = transcript }
    }

    // MARK: Finding clips

    func findClips(_ id: UUID, settings: Finder.Settings? = nil) {
        start(id) { try await self.runFinder(id, settings: settings) }
    }

    private func runFinder(_ id: UUID, settings: Finder.Settings? = nil) async throws {
        guard let project = library.project(id), project.transcript != nil else { return }
        let settings = settings ?? .current
        set(id, .find, progress: nil, detail: settings.method.title)
        let found = try await Finder.find(in: project, settings: settings) { fraction, detail in
            Task { @MainActor in Jobs.shared.set(id, .find, progress: fraction, detail: detail) }
        }
        // New finds replace the old ones; clips you made or touched stay.
        library.update(id) { project in
            project.clips.removeAll { $0.origin == .found }
            project.clips += found
            project.clips.sort { $0.start < $1.start }
        }
    }

    // MARK: Framing

    /// Tracks the speaker for a clip ahead of export, so the preview shows where the crop goes.
    func frame(_ projectID: UUID, clip clipID: UUID) {
        guard let project = library.project(projectID), let clip = project.clip(clipID), let media = project.media else { return }
        let words = Array(project.transcript?.words(in: clip.range) ?? [])
        start(projectID) {
            self.set(projectID, .frame, progress: 0, detail: clip.title)
            let track = try await Reframer.track(media, range: clip.range, words: words) { fraction in
                Task { @MainActor in Jobs.shared.set(projectID, .frame, progress: fraction, detail: clip.title) }
            }
            self.library.update(projectID) { project in
                guard var clip = project.clip(clipID) else { return }
                clip.track = track
                project.update(clip)
            }
        }
    }

    // MARK: Export

    /// Queues clips for export, one at a time, since each already uses the whole media engine.
    func export(_ projectID: UUID, clips clipIDs: [UUID], options: Exporter.Options? = nil) {
        let previous = exportQueue
        for id in clipIDs where exporting[id] == nil { exporting[id] = 0 }
        exportQueue = Task {
            await previous?.value
            for clipID in clipIDs {
                guard exporting[clipID] != nil else { continue }
                await exportOne(projectID, clipID, options: options ?? .current)
            }
        }
    }

    private func exportOne(_ projectID: UUID, _ clipID: UUID, options: Exporter.Options) async {
        defer { exporting[clipID] = nil }
        guard let project = library.project(projectID), let clip = project.clip(clipID), let media = project.media else { return }
        let destination = Exporter.destination(for: clip.title, project: project.title)
        let words = Array(project.transcript?.words(in: clip.range) ?? [])
        do {
            // The speaker's track is worth keeping: it makes the preview match and the next export quicker.
            var clip = clip
            if clip.track == nil, (clip.framing ?? options.framing) == .speaker, options.aspect != .original {
                let track = try await Reframer.track(media, range: clip.range, words: words) { fraction in
                    Task { @MainActor in Jobs.shared.exporting[clipID] = fraction * 0.3 }
                }
                clip.track = track
                library.update(projectID) { $0.update(clip) }
            }
            try await Exporter.export(media, clip: clip, words: words, options: options, to: destination) { fraction in
                Task { @MainActor in
                    if Jobs.shared.exporting[clipID] != nil { Jobs.shared.exporting[clipID] = 0.3 + fraction * 0.7 }
                }
            }
            let record = Export(clipID: clipID, title: clip.title, file: destination, aspect: options.aspect, duration: clip.duration)
            library.update(projectID) { $0.exports.insert(record, at: 0) }
            exported[clipID] = destination
        } catch {
            errors[projectID] = error.localizedDescription
        }
    }

    func cancelExport(_ clipID: UUID) {
        exporting[clipID] = nil
    }

    // MARK: Plumbing

    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
    }

    private func start(_ id: UUID, _ body: @escaping () async throws -> Void) {
        guard tasks[id] == nil else { return }
        errors[id] = nil
        tasks[id] = Task {
            do {
                try await body()
            } catch is CancellationError {
            } catch {
                errors[id] = error.localizedDescription
            }
            running[id] = nil
            tasks[id] = nil
        }
    }

    private func set(_ id: UUID, _ kind: Job.Kind, progress: Double? = nil, detail: String = "") {
        guard tasks[id] != nil else { return }
        running[id] = Job(kind: kind, progress: progress, detail: detail)
    }
}

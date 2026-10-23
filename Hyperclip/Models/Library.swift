import AppKit
import Observation

/// Every project, each in its own folder under Application Support with its JSON, thumbnail and downloads.
@Observable
final class Library {
    static let shared = Library()

    private(set) var projects: [Project] = []

    static let folder: URL = {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "Hyperclip", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }()

    static var projectsFolder: URL { folder.appending(path: "Projects", directoryHint: .isDirectory) }

    init() {
        load()
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Library.shared.flush() }
        }
    }

    static func folder(of id: UUID) -> URL {
        projectsFolder.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    static func thumbnail(of id: UUID) -> URL {
        folder(of: id).appending(path: "thumbnail.jpg")
    }

    func project(_ id: UUID?) -> Project? {
        projects.first { $0.id == id }
    }

    /// Adds a project, or replaces the one with its id, and writes it to disk.
    func save(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.insert(project, at: 0)
        }
        pending.insert(project.id)
        // Edits come in bursts, like dragging a clip's edge, so writes wait for a pause.
        writer?.cancel()
        writer = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            flush()
        }
    }

    @ObservationIgnored private var pending: Set<UUID> = []
    @ObservationIgnored private var writer: Task<Void, Never>?

    /// Writes every changed project now.
    func flush() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        for id in pending {
            guard let project = project(id) else { continue }
            let folder = Self.folder(of: id)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try? encoder.encode(project).write(to: folder.appending(path: "project.json"), options: .atomic)
        }
        pending.removeAll()
    }

    /// Changes a project in place and saves it.
    func update(_ id: UUID, _ change: (inout Project) -> Void) {
        guard var project = project(id) else { return }
        change(&project)
        save(project)
    }

    /// Removes the project and its folder, which holds anything it downloaded. Exports stay where they are.
    func delete(_ id: UUID) {
        projects.removeAll { $0.id == id }
        pending.remove(id)
        try? FileManager.default.removeItem(at: Self.folder(of: id))
    }

    var allExports: [(project: Project, export: Export)] {
        projects.flatMap { project in project.exports.map { (project, $0) } }
            .filter { FileManager.default.fileExists(atPath: $0.export.file.path) }
            .sorted { $0.export.createdAt > $1.export.createdAt }
    }

    private func load() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: Self.projectsFolder, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        projects = folders.compactMap { folder in
            guard let data = try? Data(contentsOf: folder.appending(path: "project.json")) else { return nil }
            return try? decoder.decode(Project.self, from: data)
        }
        .sorted { $0.createdAt > $1.createdAt }
    }
}

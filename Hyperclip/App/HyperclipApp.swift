import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct HyperclipApp: App {
    @State private var studio = Studio()

    var body: some Scene {
        Window("Hyperclip", id: "main") {
            ContentView()
                .environment(studio)
                .environment(Library.shared)
                .environment(Jobs.shared)
                .environment(Tools.shared)
                .environment(WhisperModels.shared)
                .modifier(AppAppearance())
                .frame(minWidth: 1160, minHeight: 680)
                #if DEBUG
                .task { Snapshot.runIfRequested(studio) }
                #endif
        }
        .defaultSize(width: 1400, height: 880)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New from Link…") { studio.destination = .start }
                    .keyboardShortcut("n")
                Button("Open Video…") { studio.openFile() }
                    .keyboardShortcut("o")
            }
            CommandMenu("Clip") {
                Button("Play or Pause") { studio.player.toggle() }
                    .disabled(studio.project == nil)
                Button("Play Selected Clip") { studio.playSelectedClip() }
                    .disabled(studio.selectedClip == nil)
                Divider()
                Button("Mark In") { studio.markIn() }
                    .disabled(studio.project == nil)
                Button("Mark Out") { studio.markOut() }
                    .disabled(studio.project == nil)
                Button("New Clip from In to Out") { studio.addClipFromMarks() }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(studio.marks == nil)
                Divider()
                Button("Transcribe") { studio.project.map { Jobs.shared.transcribe($0.id) } }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                    .disabled(studio.project == nil)
                Button("Find Clips") { studio.project.map { Jobs.shared.findClips($0.id) } }
                    .keyboardShortcut("k")
                    .disabled(studio.project?.transcript == nil)
                Divider()
                Button("Export Selected Clip") { studio.exportSelected() }
                    .keyboardShortcut("e")
                    .disabled(studio.selectedClip == nil)
                Button("Export All Clips") { studio.exportAll() }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(studio.project?.clips.isEmpty ?? true)
                Divider()
                Button("Delete Selected Clip") { studio.deleteSelectedClip() }
                    .keyboardShortcut(.delete, modifiers: [.command])
                    .disabled(studio.selectedClip == nil)
            }
            CommandGroup(after: .sidebar) {
                Button("New") { studio.destination = .start }
                    .keyboardShortcut("1")
                Button("Exports") { studio.destination = .exports }
                    .keyboardShortcut("2")
                Button("Models & Tools") { studio.destination = .models }
                    .keyboardShortcut("3")
                Divider()
            }
        }

        Settings {
            SettingsView()
                .environment(Tools.shared)
                .environment(WhisperModels.shared)
                .modifier(AppAppearance())
        }
    }
}

/// What the window shows.
enum Destination: Hashable {
    case start
    case project(UUID)
    case exports
    case models
}

/// The window's shared state: where you are, the selected clip, and the player.
@Observable
final class Studio {
    var destination: Destination? = .start {
        didSet {
            if case .project(let id) = destination, id != oldValue.projectID {
                selectedClipID = nil
                marks = nil
                if let media = Library.shared.project(id)?.media { player.load(media) }
            }
        }
    }
    var selectedClipID: UUID?
    /// The export being posted, in the Publish sheet.
    var publishing: Publishing?

    struct Publishing: Identifiable {
        var projectID: UUID
        var export: Export
        var id: UUID { export.id }
    }
    /// In and out points marked in the editor, before they become a clip.
    var marks: (in: Double?, out: Double?)?
    let player = Player()

    var project: Project? {
        guard case .project(let id) = destination else { return nil }
        return Library.shared.project(id)
    }

    var selectedClip: Clip? { project?.clip(selectedClipID) }

    func open(_ id: UUID) { destination = .project(id) }

    func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie]
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        var last: UUID?
        for url in panel.urls { last = Jobs.shared.importFile(url) }
        if let last { open(last) }
    }

    func select(_ clip: Clip?, seek: Bool = true) {
        selectedClipID = clip?.id
        if let clip, seek { player.seek(to: clip.start) }
    }

    func playSelectedClip() {
        guard let clip = selectedClip else { return }
        player.play(clip.range)
    }

    func markIn() {
        var marks = self.marks ?? (nil, nil)
        marks.in = player.time
        if let out = marks.out, out <= player.time { marks.out = nil }
        self.marks = marks
    }

    func markOut() {
        var marks = self.marks ?? (nil, nil)
        marks.out = player.time
        if let start = marks.in, start >= player.time { marks.in = nil }
        self.marks = marks
        if marks.in != nil { addClipFromMarks() }
    }

    func addClipFromMarks() {
        guard let project, let start = marks?.in, let end = marks?.out, end > start + 0.3 else { return }
        addClip(start: start, end: end, to: project.id)
        marks = nil
    }

    /// A clip you made, titled from what's said in it.
    func addClip(start: Double, end: Double, to id: UUID) {
        let text = Library.shared.project(id)?.transcript?.text(in: start...end) ?? ""
        let title = text.isEmpty ? "Clip at \(start.clock)" : Finder.title(from: String(text.prefix(80)))
        let clip = Clip(start: start, end: end, title: title, origin: .manual)
        Library.shared.update(id) { project in
            project.clips.append(clip)
            project.clips.sort { $0.start < $1.start }
        }
        selectedClipID = clip.id
    }

    func exportSelected() {
        guard let project, let clip = selectedClip else { return }
        Jobs.shared.export(project.id, clips: [clip.id])
    }

    func exportAll() {
        guard let project else { return }
        Jobs.shared.export(project.id, clips: project.clips.map(\.id))
    }

    /// Opens the Publish sheet for a clip, exporting it first if it hasn't been.
    func publish(_ clipID: UUID, in projectID: UUID) {
        if let export = Library.shared.project(projectID)?.exports.first(where: { $0.clipID == clipID && FileManager.default.fileExists(atPath: $0.file.path) }) {
            publishing = Publishing(projectID: projectID, export: export)
            return
        }
        Jobs.shared.export(projectID, clips: [clipID])
        Task {
            while Jobs.shared.exporting[clipID] != nil { try? await Task.sleep(for: .milliseconds(300)) }
            if let export = Library.shared.project(projectID)?.exports.first(where: { $0.clipID == clipID }) {
                publishing = Publishing(projectID: projectID, export: export)
            }
        }
    }

    func deleteSelectedClip() {
        guard let project, let id = selectedClipID else { return }
        Library.shared.update(project.id) { $0.clips.removeAll { $0.id == id } }
        selectedClipID = nil
    }

    func deleteProject(_ id: UUID) {
        Jobs.shared.cancel(id)
        if destination == .project(id) {
            player.unload()
            destination = .start
        }
        Library.shared.delete(id)
    }
}

extension Optional where Wrapped == Destination {
    var projectID: UUID? {
        if case .project(let id) = self { return id }
        return nil
    }
}

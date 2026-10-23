import SwiftUI

struct ContentView: View {
    @Environment(Studio.self) private var studio
    @Environment(Library.self) private var library
    @Environment(Jobs.self) private var jobs
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var studio = studio
        NavigationSplitView {
            List(selection: $studio.destination) {
                SwiftUI.Section {
                    Label("New", systemImage: "plus.circle").tag(Destination.start)
                }
                if !library.projects.isEmpty {
                    SwiftUI.Section("Videos") {
                        ForEach(library.projects) { project in
                            ProjectRow(project: project)
                                .tag(Destination.project(project.id))
                                .contextMenu { ProjectMenu(project: project) }
                        }
                    }
                }
                SwiftUI.Section("Library") {
                    Label("Exports", systemImage: "square.and.arrow.up.on.square")
                        .badge(library.allExports.count)
                        .tag(Destination.exports)
                    Label("Models & Tools", systemImage: "shippingbox")
                        .tag(Destination.models)
                }
            }
            .modifier(SidebarDarkening())
            .navigationSplitViewColumnWidth(min: 220, ideal: 250, max: 320)
        } detail: {
            Group {
                switch studio.destination {
                case .project(let id):
                    if let project = library.project(id) {
                        EditorView(project: project)
                            .id(id)
                    } else {
                        StartView()
                    }
                case .exports: ExportsView()
                case .models: ModelsView()
                case .start, nil: StartView()
                }
            }
            .modifier(PageBackground())
        }
        .sheet(item: $studio.publishing) { item in
            PublishSheet(projectID: item.projectID, export: item.export)
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            Self.importDropped(providers, into: studio)
        }
        #if DEBUG
        .task {
            if ProcessInfo.processInfo.environment["HYPERCLIP_OPEN_SETTINGS"] != nil { openSettings() }
        }
        #endif
    }

    /// Video files dropped anywhere on the window become projects.
    static func importDropped(_ providers: [NSItemProvider], into studio: Studio) -> Bool {
        var accepted = false
        for provider in providers where provider.canLoadObject(ofClass: URL.self) {
            accepted = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in studio.open(Jobs.shared.importFile(url)) }
            }
        }
        return accepted
    }
}

/// A video in the sidebar: its thumbnail, title, and what it's busy with.
private struct ProjectRow: View {
    @Environment(Jobs.self) private var jobs
    let project: Project

    var body: some View {
        HStack(spacing: 10) {
            Thumbnail(project: project)
                .frame(width: 52, height: 30)
                .clipShape(.rect(cornerRadius: 5))
                .overlay {
                    if let job = jobs.running[project.id] {
                        ZStack {
                            RoundedRectangle(cornerRadius: 5).fill(.black.opacity(0.5))
                            if let progress = job.progress {
                                ProgressRing(progress: progress).frame(width: 16, height: 16)
                            } else {
                                ProgressView().controlSize(.mini).tint(.white)
                            }
                        }
                    }
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(project.title).lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(jobs.errors[project.id] != nil ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }

    private var subtitle: String {
        if let job = jobs.running[project.id] {
            return job.progress.map { "\(job.kind.title) · \(Int($0 * 100))%" } ?? job.kind.title
        }
        if jobs.errors[project.id] != nil { return "Something went wrong" }
        var parts: [String] = []
        if project.duration > 0 { parts.append(project.duration.clock) }
        if !project.clips.isEmpty { parts.append("\(project.clips.count) clip\(project.clips.count == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }
}

/// Actions on a whole video, from the sidebar and the editor's toolbar.
struct ProjectMenu: View {
    @Environment(Studio.self) private var studio
    @Environment(Jobs.self) private var jobs
    let project: Project

    var body: some View {
        Button("Transcribe Again") { jobs.transcribe(project.id) }
            .disabled(jobs.isBusy(project.id) || project.media == nil)
        Button("Find Clips Again") { jobs.findClips(project.id) }
            .disabled(jobs.isBusy(project.id) || project.transcript == nil)
        if jobs.isBusy(project.id) {
            Button("Stop") { jobs.cancel(project.id) }
        }
        Divider()
        if let media = project.media {
            Button("Show Video in Finder") { NSWorkspace.shared.activateFileViewerSelecting([media]) }
        }
        if let link = project.sourceURL, let url = URL(string: link) {
            Button("Open Original Page") { NSWorkspace.shared.open(url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            }
        }
        Divider()
        Button("Delete Video", role: .destructive) { studio.deleteProject(project.id) }
    }
}

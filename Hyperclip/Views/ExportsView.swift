import AVFoundation
import QuickLookUI
import SwiftUI
import UniformTypeIdentifiers

/// Every exported clip, ready to drag into an upload page or a messaging app.
struct ExportsView: View {
    @Environment(Library.self) private var library
    @Environment(Studio.self) private var studio

    var body: some View {
        let exports = library.allExports
        Group {
            if exports.isEmpty {
                EmptyState(title: "No exports yet", icon: "square.and.arrow.up.on.square",
                           message: "Clips you export show here, and in \(Prefs.exportFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).") {}
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 170, maximum: 220), spacing: 18)], spacing: 22) {
                        ForEach(exports, id: \.export.id) { item in
                            ExportTile(project: item.project, export: item.export)
                        }
                    }
                    .padding(24)
                }
            }
        }
        .navigationTitle("Exports")
        .toolbar {
            Button {
                try? FileManager.default.createDirectory(at: Prefs.exportFolder, withIntermediateDirectories: true)
                NSWorkspace.shared.open(Prefs.exportFolder)
            } label: {
                Label("Open Folder", systemImage: "folder")
            }
        }
    }
}

private struct ExportTile: View {
    @Environment(Studio.self) private var studio
    let project: Project
    let export: Export
    @State private var image: NSImage?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12).fill(.black)
                if let image {
                    Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
                }
                if hovering {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white.opacity(0.9))
                        .shadow(radius: 6)
                }
            }
            .aspectRatio(9 / 16, contentMode: .fit)
            .clipShape(.rect(cornerRadius: 12))
            .overlay(alignment: .bottomTrailing) {
                Text(export.duration.clock)
                    .font(.caption2.weight(.semibold)).monospacedDigit()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                    .foregroundStyle(.white)
                    .padding(8)
            }
            .onTapGesture { NSWorkspace.shared.open(export.file) }
            .onHover { hovering = $0 }
            .onDrag { NSItemProvider(contentsOf: export.file) ?? NSItemProvider() }

            Text(export.title).font(.callout.weight(.medium)).lineLimit(2)
            if let posts = export.posts, !posts.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "paperplane.fill")
                    Text(Set(posts.filter { $0.status != "failed" }.map { Zernio.name(of: $0.platform) }).sorted().joined(separator: ", "))
                }
                .font(.caption)
                .foregroundStyle(.tint)
                .lineLimit(1)
            }
            HStack(spacing: 6) {
                Text(project.title).lineLimit(1)
                Spacer()
                Text(export.aspect.label)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(export.file) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([export.file]) }
            Button("Publish…") { studio.publishing = Studio.Publishing(projectID: project.id, export: export) }
            Button("Go to Clip") {
                studio.open(project.id)
                studio.selectedClipID = export.clipID
            }
            ShareLink(item: export.file)
            Divider()
            Button("Move to Trash", role: .destructive) {
                NSWorkspace.shared.recycle([export.file])
                Library.shared.update(project.id) { $0.exports.removeAll { $0.id == export.id } }
            }
        }
        .task(id: export.file) {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: export.file))
            generator.appliesPreferredTrackTransform = true
            generator.maximumSize = CGSize(width: 440, height: 440)
            if let (cgImage, _) = try? await generator.image(at: CMTime(seconds: min(1.5, export.duration / 3), preferredTimescale: 600)) {
                image = NSImage(cgImage: cgImage, size: .zero)
            }
        }
    }
}

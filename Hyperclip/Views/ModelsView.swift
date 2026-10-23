import SwiftUI

/// Transcription models and the command-line tools Hyperclip runs, with what's installed and what's missing.
struct ModelsView: View {
    @Environment(Tools.self) private var tools
    @Environment(WhisperModels.self) private var whisper
    @AppStorage(Pref.engine) private var engine = TranscriptionEngine.whisper

    var body: some View {
        List {
            SwiftUI.Section {
                ForEach(TranscriptionEngine.allCases) { option in
                    EngineRow(engine: option, isSelected: engine == option) { engine = option }
                }
            } header: {
                Text("Transcription")
            }

            SwiftUI.Section {
                ForEach(WhisperModel.all) { WhisperRow(model: $0) }
            } header: {
                Text("Whisper models")
            } footer: {
                Text("From huggingface.co/ggerganov/whisper.cpp. Each runs entirely on this Mac once downloaded. Models already on the Mac (in ~/.cache/whisper-cpp, say) are used where they are.")
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                ForEach(Tool.allCases) { ToolRow(tool: $0) }
            } header: {
                Text("Tools")
            } footer: {
                Text(tools.hasHomebrew ? "Installs and updates go through Homebrew." : "Homebrew isn't installed, so yt-dlp downloads on its own; FFmpeg and whisper.cpp link to their sites.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .navigationTitle("Models & Tools")
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { tools.refresh() }
        }
        .onAppear { tools.refresh() }
        .id(whisper.revision)
    }
}

private struct EngineRow: View {
    let engine: TranscriptionEngine
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: engine.icon)
                .font(.title2)
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(engine.title).font(.headline)
                Text(engine.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if isSelected {
                Label("In use", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Use", action: select)
            }
        }
        .padding(.vertical, 6)
    }
}

private struct WhisperRow: View {
    @Environment(WhisperModels.self) private var models
    @AppStorage(Pref.whisperModel) private var selected = ""
    let model: WhisperModel

    var body: some View {
        let file = model.file
        HStack(spacing: 14) {
            Image(systemName: file != nil ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(file != nil ? Color.green : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).font(.headline)
                    if model.recommended { Chip(text: "Recommended") }
                    if WhisperModel.selected == model, file != nil { Chip(text: "In use", icon: "checkmark") }
                }
                Text(model.summary).foregroundStyle(.secondary)
                if model.isShared, let file {
                    Text(file.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.caption).foregroundStyle(.tertiary)
                }
                if let error = models.errors[model.id] {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
            Spacer()
            if let progress = models.progress[model.id] {
                VStack(alignment: .trailing, spacing: 4) {
                    ProgressView(value: progress).frame(width: 120)
                    Text("\(Int64(Double(model.size) * progress).bytes) of \(model.size.bytes)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }
                Button { models.cancel(model) } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            } else if file != nil {
                if WhisperModel.selected != model {
                    Button("Use") { selected = model.id }
                }
                Menu {
                    Button("Show in Finder") { models.reveal(model) }
                    if !model.isShared {
                        Divider()
                        Button("Delete", role: .destructive) { models.delete(model) }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
            } else {
                Text(model.size.bytes).foregroundStyle(.secondary).monospacedDigit()
                Button("Download") { models.download(model) }
            }
        }
        .padding(.vertical, 6)
    }
}

private struct ToolRow: View {
    @Environment(Tools.self) private var tools
    let tool: Tool
    @State private var showsLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: tools.isInstalled(tool) ? "checkmark.circle.fill" : "exclamationmark.circle")
                    .font(.title2)
                    .foregroundStyle(tools.isInstalled(tool) ? Color.green : .orange)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(tool.name).font(.headline)
                        if let version = tools.versions[tool] { Chip(text: version) }
                    }
                    Text(tool.purpose).foregroundStyle(.secondary)
                    if let location = tools.locations[tool] {
                        Text(location.path).font(.caption).foregroundStyle(.tertiary).textSelection(.enabled)
                    }
                    if let error = tools.errors[tool] {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Spacer()
                if tools.busy.contains(tool) {
                    ProgressView().controlSize(.small)
                } else if tools.isInstalled(tool) {
                    if tool != .whisper || tools.hasHomebrew {
                        Button("Update") { tools.update(tool) }
                    }
                } else {
                    Button(tools.hasHomebrew || tool == .ytdlp ? "Install" : "Get It") { tools.install(tool) }
                        .buttonStyle(.borderedProminent)
                }
            }
            if let log = tools.log[tool], !log.isEmpty {
                DisclosureGroup("Output", isExpanded: $showsLog) {
                    ScrollView {
                        Text(log)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 140)
                }
                .font(.caption)
                .padding(.leading, 42)
            }
        }
        .padding(.vertical, 6)
    }
}

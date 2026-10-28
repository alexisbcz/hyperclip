import SwiftUI

/// Transcription models and the command-line tools Hyperclip runs, with what's installed and what's missing.
struct ModelsView: View {
    @Environment(Tools.self) private var tools
    @Environment(WhisperModels.self) private var whisper
    @Environment(LiquidModels.self) private var liquid
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
                ForEach(LiquidModel.all) { LiquidModelRow(model: $0) }
                LlamaServerRow()
            } header: {
                Text("Liquid models")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("From huggingface.co/LiquidAI, run by llama.cpp on this Mac. d1 answers the clip finder's questions as a decision model; LFM3 reads the whole transcript as a language model. Pick them under Settings › Clips.")
                    LiquidLicenceNote()
                }
                .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                ForEach(Tool.allCases) { ToolRow(tool: $0) }
            } header: {
                Text("Tools")
            } footer: {
                Text(tools.hasHomebrew ? "Installs and updates go through Homebrew, except llama.cpp: Hyperclip downloads release \(LlamaServer.release) itself, since Homebrew's is too old for Liquid's models." : "Homebrew isn't installed, so yt-dlp and llama.cpp download on their own; FFmpeg and whisper.cpp link to their sites.")
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
        .id("\(whisper.revision)-\(liquid.revision)")
    }
}

/// One of Liquid's models: whether it's here, its download, and what it's for.
struct LiquidModelRow: View {
    @Environment(LiquidModels.self) private var models
    let model: LiquidModel

    var body: some View {
        let downloaded = model.isDownloaded
        HStack(spacing: 14) {
            Image(systemName: downloaded ? "checkmark.circle.fill" : "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(downloaded ? Color.green : .secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(model.name).font(.headline)
                    Chip(text: model.role == .decision ? "Decision" : "Language")
                    if model.hearsAudio { Chip(text: "Hears audio", icon: "waveform") }
                    if model.recommended { Chip(text: "Recommended") }
                }
                Text(model.summary).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
            } else if downloaded {
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
        .id(models.revision)
    }
}

/// Where the user picks one of Liquid's models, its licence has to be mentioned.
struct LiquidLicenceNote: View {
    var body: some View {
        Text("Liquid's models are under the [LFM Open License v1.0](https://huggingface.co/LiquidAI/d1-2B/blob/main/LICENSE): free to use for individuals and for companies under $10 million in yearly revenue, with conditions above that.")
    }
}

/// The llama-server Hyperclip runs for Liquid's models, started when a clip finder needs it.
private struct LlamaServerRow: View {
    @Environment(LlamaServer.self) private var server
    @Environment(Tools.self) private var tools
    @State private var showsLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 14) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(server.state == .running ? Color.green : .secondary)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text("llama-server").font(.headline)
                    Text(status).foregroundStyle(.secondary)
                    if let error = server.error {
                        Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
                Spacer()
                switch server.state {
                case .starting:
                    ProgressView().controlSize(.small)
                case .running:
                    Button("Stop") { server.stop() }
                case .stopped:
                    Button("Start") { Task { try? await server.start() } }
                        .disabled(!tools.isInstalled(.llama) || !LiquidModel.all.contains(where: \.isDownloaded))
                }
            }
            if !server.log.isEmpty {
                DisclosureGroup("Output", isExpanded: $showsLog) {
                    ScrollView {
                        Text(server.log.suffix(6_000))
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

    private var status: String {
        switch server.state {
        case .running: "Running on port \(server.port ?? 0). It stops when Hyperclip quits, or after 10 minutes unused."
        case .starting: "Starting…"
        case .stopped: tools.isInstalled(.llama) ? "Stopped. Hyperclip starts it when a clip finder needs it." : "Needs llama.cpp, which installs below, or on its own the first time it's needed."
        }
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
                    if tool != .llama, tool != .whisper || tools.hasHomebrew {
                        Button("Update") { tools.update(tool) }
                    }
                } else {
                    Button(tools.hasHomebrew || tool == .ytdlp || tool == .llama ? "Install" : "Get It") { tools.install(tool) }
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

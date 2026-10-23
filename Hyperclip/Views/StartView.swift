import SwiftUI
import UniformTypeIdentifiers

/// Where a video comes in: a link to download, or a file.
struct StartView: View {
    @Environment(Studio.self) private var studio
    @Environment(Library.self) private var library
    @Environment(Tools.self) private var tools
    @Environment(\.openSettings) private var openSettings

    @State private var link = ""
    @State private var partOnly = false
    @State private var from = ""
    @State private var to = ""
    @State private var clipboard: String?
    @State private var isTargeted = false
    @FocusState private var linkFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                header
                linkBox
                dropZone
                PipelineSummary()
                if !library.projects.isEmpty { recent }
            }
            .frame(maxWidth: 720)
            .padding(.horizontal, 40)
            .padding(.vertical, 44)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("New")
        .onAppear {
            readClipboard()
            linkFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in readClipboard() }
    }

    private var header: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 76, height: 76)
            Text("Turn long videos into shorts")
                .font(.system(size: 28, weight: .bold, design: .rounded))
            Text("Paste a link or drop a video. Hyperclip transcribes it on this Mac, finds the moments worth posting, and exports them vertical, captioned and framed on the speaker.")
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 560)
        }
    }

    private var linkBox: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .font(.title3)
                TextField("Paste a YouTube, TikTok, Instagram, X or Twitch link", text: $link)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($linkFocused)
                    .onSubmit(start)
                Button(action: start) {
                    Label("Clip It", systemImage: "scissors")
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!isLink(link) || !tools.isInstalled(.ytdlp))
            }
            .padding(.leading, 16)
            .padding(.trailing, 8)
            .padding(.vertical, 8)
            .background(.background.opacity(0.6), in: .rect(cornerRadius: 14))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(linkFocused ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator), lineWidth: linkFocused ? 2 : 1))

            HStack(spacing: 14) {
                if let clipboard, clipboard != link {
                    Button {
                        link = clipboard
                    } label: {
                        Label("Use \(Self.short(clipboard))", systemImage: "doc.on.clipboard")
                            .lineLimit(1)
                    }
                    .buttonStyle(.link)
                }
                Spacer()
                Toggle("Only part of it", isOn: $partOnly.animation(.snappy))
                    .toggleStyle(.checkbox)
                    .help("Downloads just that stretch of a long stream or podcast.")
                if partOnly {
                    TextField("from 0:00", text: $from).frame(width: 74)
                    TextField("to 30:00", text: $to).frame(width: 74)
                }
            }
            .font(.callout)
            .padding(.horizontal, 4)

            if !tools.isInstalled(.ytdlp) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("Downloading needs yt-dlp.")
                    Spacer()
                    if tools.busy.contains(.ytdlp) {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Install yt-dlp") { tools.install(.ytdlp) }
                    }
                }
                .font(.callout)
                .padding(12)
                .background(Color.orange.opacity(0.1), in: .rect(cornerRadius: 10))
            }
        }
    }

    private var dropZone: some View {
        Button(action: studio.openFile) {
            VStack(spacing: 8) {
                Image(systemName: "film.stack")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text("Drop a video here, or choose a file")
                    .font(.headline)
                Text("MP4, MOV, MKV, WebM… Videos the Mac can't play are converted with FFmpeg.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
            .background(isTargeted ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                    .foregroundStyle(isTargeted ? AnyShapeStyle(.tint) : AnyShapeStyle(.separator))
            )
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            ContentView.importDropped(providers, into: studio)
        }
    }

    private var recent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recent").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                ForEach(library.projects.prefix(6)) { project in
                    Button { studio.open(project.id) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Thumbnail(project: project)
                                .aspectRatio(16 / 9, contentMode: .fit)
                                .clipShape(.rect(cornerRadius: 10))
                                .overlay(alignment: .bottomTrailing) {
                                    if project.duration > 0 {
                                        Text(project.duration.clock)
                                            .font(.caption2.weight(.semibold)).monospacedDigit()
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(.black.opacity(0.6), in: .rect(cornerRadius: 4))
                                            .foregroundStyle(.white)
                                            .padding(6)
                                    }
                                }
                            Text(project.title).font(.callout.weight(.medium)).lineLimit(2)
                            Text(project.clips.isEmpty ? (project.channel ?? " ") : "\(project.clips.count) clips")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func start() {
        guard isLink(link), tools.isInstalled(.ytdlp) else { return }
        var section: ClosedRange<Double>?
        if partOnly, let start = Self.seconds(from) ?? (from.isEmpty ? 0 : nil), let end = Self.seconds(to), end > start {
            section = start...end
        }
        let id = Jobs.shared.importLink(link, section: section)
        link = ""
        studio.open(id)
    }

    private func readClipboard() {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        clipboard = text.flatMap { isLink($0) ? $0 : nil }
    }

    private func isLink(_ text: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme else { return false }
        return ["http", "https"].contains(scheme.lowercased()) && url.host() != nil
    }

    static func short(_ link: String) -> String {
        guard let url = URL(string: link), let host = url.host() else { return link }
        let path = url.path().count > 18 ? String(url.path().prefix(18)) + "…" : url.path()
        return host.replacingOccurrences(of: "www.", with: "") + path
    }

    /// "1:02:03", "12:30" or "95" as seconds.
    static func seconds(_ text: String) -> Double? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }
}

/// How each step is set up, with a way into its settings.
private struct PipelineSummary: View {
    @Environment(\.openSettings) private var openSettings
    @Environment(WhisperModels.self) private var whisper
    @AppStorage(Pref.engine) private var engine = TranscriptionEngine.whisper
    @AppStorage(Pref.finder) private var finder = FinderMethod.heuristic
    @AppStorage(Pref.aspect) private var aspect = Aspect.vertical
    @AppStorage(Pref.captionStyle) private var captions = CaptionStyle.Preset.bold
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        HStack(spacing: 12) {
            step(1, "Transcribe", engine == .whisper ? "Whisper · \(WhisperModel.selected.name)" : engine.title, icon: "captions.bubble", tab: "transcription",
                 warning: engine == .whisper && WhisperModel.selectedFile == nil ? "Download a model" : nil)
            step(2, "Find clips", finder.title, icon: "sparkle.magnifyingglass", tab: "finding")
            step(3, "Export", "\(aspect.label) · \(captions.name)", icon: "square.and.arrow.up", tab: "captions")
        }
        .id(whisper.revision)
    }

    private func step(_ number: Int, _ title: String, _ value: String, icon: String, tab: String, warning: String? = nil) -> some View {
        Button {
            self.tab = tab
            openSettings()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: icon).foregroundStyle(.tint)
                    Text(title).font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(number)").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                }
                Text(value).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let warning {
                    Text(warning).font(.caption.weight(.medium)).foregroundStyle(.orange)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.5)))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .help("Change in Settings")
    }
}

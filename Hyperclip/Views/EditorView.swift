import SwiftUI

/// One video: the preview, the timeline, and its clips and transcript side by side.
struct EditorView: View {
    @Environment(Studio.self) private var studio
    @Environment(Jobs.self) private var jobs
    let project: Project

    @AppStorage(Pref.aspect) private var aspect = Aspect.vertical
    @AppStorage("editor.cropped") private var cropped = false
    @AppStorage("editor.inspector") private var inspector = "clips"
    @State private var keys: Any?

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 22)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
                JobBanner(projectID: project.id)
                    .padding(.horizontal, 22)
                    .padding(.bottom, jobs.running[project.id] != nil || jobs.errors[project.id] != nil ? 12 : 0)
                if project.media != nil, project.duration > 0 {
                    PreviewView(project: project, cropped: cropped && aspect != .original)
                        .clipShape(.rect(cornerRadius: 12))
                        .padding(.horizontal, 22)
                    TransportBar(project: project)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 10)
                    timeline
                        .frame(height: 112)
                        .background(.quaternary.opacity(0.25))
                        .overlay(alignment: .top) { Divider() }
                } else {
                    waiting
                }
            }
            .frame(minWidth: 480)
            Divider()
            Inspector(project: project, tab: $inspector)
                .frame(width: 340)
        }
        .navigationTitle(project.title)
        .toolbar {
            ToolbarItemGroup {
                Menu {
                    Picker("Shape", selection: $aspect) {
                        ForEach(Aspect.allCases) { Text($0.name).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label(aspect.label, systemImage: aspect.icon)
                        .labelStyle(.titleAndIcon)
                }
                .help("The shape clips export in")
                Toggle(isOn: $cropped) {
                    Label("Preview Crop", systemImage: "crop")
                }
                .help("Preview the clip cropped, as it will export")
                .disabled(aspect == .original)
            }
            ToolbarItem {
                Menu {
                    ProjectMenu(project: project)
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
            ToolbarItem {
                Button {
                    studio.exportAll()
                } label: {
                    Label("Export All", systemImage: "square.and.arrow.up.on.square")
                }
                .help("Export every clip (⇧⌘E)")
                .disabled(project.clips.isEmpty)
            }
        }
        .onAppear {
            if let media = project.media { studio.player.load(media) }
            keys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                nonisolated(unsafe) let event = event
                let handled = MainActor.assumeIsolated { handle(event) }
                return handled ? nil : event
            }
        }
        .onDisappear {
            if let keys { NSEvent.removeMonitor(keys) }
            studio.player.pause()
        }
        .onChange(of: project.media) { _, media in
            if let media { studio.player.load(media) }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(project.title)
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let channel = project.channel { Text(channel) }
                    if project.duration > 0 { Text(project.duration.clock).monospacedDigit() }
                    if let transcript = project.transcript {
                        Text("\(transcript.words.count.formatted()) words")
                        Text(transcript.engine)
                    }
                    if let link = project.sourceURL, let url = URL(string: link) {
                        Link(destination: url) {
                            Label(url.host()?.replacingOccurrences(of: "www.", with: "") ?? "Source", systemImage: "arrow.up.right.square")
                        }
                    }
                }
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer()
        }
    }

    private var timeline: some View {
        ClipTimeline(
            duration: project.duration,
            loudness: project.loudness ?? [],
            clips: project.clips,
            selected: studio.selectedClipID,
            marks: studio.marks,
            time: studio.player.time,
            isPlaying: studio.player.isPlaying,
            seek: { studio.player.seek(to: $0) },
            select: { id in studio.select(project.clip(id), seek: false) },
            trim: { id, start, end in
                Library.shared.update(project.id) { project in
                    guard var clip = project.clip(id) else { return }
                    if abs(clip.start - start) > 0.001 { clip.track = nil }
                    clip.start = start
                    clip.end = end
                    clip.track = clip.track?.trimmed(to: clip.duration)
                    project.update(clip)
                }
            }
        )
    }

    private var waiting: some View {
        VStack(spacing: 14) {
            Spacer()
            Thumbnail(project: project)
                .frame(width: 320, height: 180)
                .clipShape(.rect(cornerRadius: 12))
                .opacity(0.6)
            if jobs.running[project.id] == nil, jobs.errors[project.id] != nil {
                Text("The video isn't ready.").foregroundStyle(.secondary)
                if let link = project.sourceURL {
                    Button("Try Again") {
                        let id = jobs.importLink(link)
                        studio.deleteProject(project.id)
                        studio.open(id)
                    }
                }
            } else {
                Text("The video shows here once it's ready.").foregroundStyle(.secondary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    /// Editor keys, unless you're typing in a text field.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window?.isKeyWindow == true, event.window?.identifier?.rawValue.contains("main") ?? true,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if let text = event.window?.firstResponder as? NSTextView, text.isEditable { return false }
        let player = studio.player
        switch event.keyCode {
        case 49: player.toggle()                                     // space
        case 123: player.step(by: event.modifierFlags.contains(.shift) ? -5 : -1)   // left
        case 124: player.step(by: event.modifierFlags.contains(.shift) ? 5 : 1)     // right
        case 36, 76: studio.playSelectedClip()                       // return
        default:
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "i": studio.markIn()
            case "o": studio.markOut()
            case "j": player.step(by: -10)
            case "k": player.pause()
            case "l": player.step(by: 10)
            case ",": player.step(by: -1 / 30)
            case ".": player.step(by: 1 / 30)
            default: return false
            }
        }
        return true
    }
}

/// Play controls, the time, and marking a clip by hand.
private struct TransportBar: View {
    @Environment(Studio.self) private var studio
    let project: Project

    var body: some View {
        let player = studio.player
        HStack(spacing: 14) {
            HStack(spacing: 4) {
                Button { player.step(by: -5) } label: { Image(systemName: "gobackward.5") }
                    .help("Back 5 seconds (⇧←)")
                Button { player.toggle() } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                        .frame(width: 34, height: 28)
                }
                .help("Play or pause (Space)")
                Button { player.step(by: 5) } label: { Image(systemName: "goforward.5") }
                    .help("Forward 5 seconds (⇧→)")
            }
            .buttonStyle(.borderless)
            .font(.title3)

            Text("\(player.time.preciseClock) / \(project.duration.clock)")
                .monospacedDigit()
                .font(.callout)
                .foregroundStyle(.secondary)

            Spacer()

            HStack(spacing: 8) {
                Button { studio.markIn() } label: {
                    Label(studio.marks?.in.map { "In \($0.preciseClock)" } ?? "Mark In", systemImage: "chevron.left.to.line")
                }
                .help("Mark where a clip starts (I)")
                Button { studio.markOut() } label: {
                    Label(studio.marks?.out.map { "Out \($0.preciseClock)" } ?? "Mark Out", systemImage: "chevron.right.to.line")
                }
                .help("Mark where it ends, which makes the clip (O)")
                if studio.marks != nil {
                    Button { studio.marks = nil } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help("Clear the marks")
                }
            }
            .controlSize(.small)
        }
    }
}

// MARK: - Inspector

private struct Inspector: View {
    @Environment(Studio.self) private var studio
    @Environment(Jobs.self) private var jobs
    @Environment(\.textSize) private var textSize
    let project: Project
    @Binding var tab: String
    @State private var selection: ClosedRange<Double>?

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                Text("Clips").tag("clips")
                Text("Transcript").tag("transcript")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if tab == "clips" {
                ClipsPanel(project: project)
            } else if let transcript = project.transcript {
                TranscriptView(transcript: transcript, time: studio.player.time, isPlaying: studio.player.isPlaying,
                               clip: studio.selectedClip, fontSize: textSize, seek: { studio.player.seek(to: $0) },
                               selectionChanged: { range in selection = range })
                    .overlay(alignment: .bottom) {
                        if let selection {
                            HStack {
                                Text("\(selection.lowerBound.preciseClock)–\(selection.upperBound.preciseClock) · \((selection.upperBound - selection.lowerBound).shortDuration)")
                                    .monospacedDigit()
                                    .font(.callout)
                                Spacer()
                                Button("New Clip") {
                                    studio.addClip(start: max(0, selection.lowerBound - 0.1), end: selection.upperBound + 0.3, to: project.id)
                                    self.selection = nil
                                    tab = "clips"
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(10)
                            .background(.regularMaterial, in: .rect(cornerRadius: 12))
                            .padding(12)
                        }
                    }
            } else {
                NoTranscript(project: project)
            }
        }
    }
}

private struct NoTranscript: View {
    @Environment(Jobs.self) private var jobs
    let project: Project

    var body: some View {
        if jobs.running[project.id] != nil {
            EmptyState(title: "Working on it", icon: "hourglass", message: "The transcript and clips show here as soon as they're ready.") {}
        } else {
            EmptyState(title: "No transcript yet", icon: "captions.bubble",
                       message: "Hyperclip finds clips and writes captions from the transcript. You can still mark clips by hand with I and O.") {
                Button("Transcribe") { jobs.transcribe(project.id) }
                    .disabled(project.media == nil)
            }
        }
    }
}

private struct ClipsPanel: View {
    @Environment(Studio.self) private var studio
    @Environment(Jobs.self) private var jobs
    let project: Project
    @AppStorage("clips.sort") private var sort = "time"

    var body: some View {
        if project.transcript == nil, project.clips.isEmpty {
            NoTranscript(project: project)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text(project.clips.isEmpty ? "No clips" : "\(project.clips.count) clip\(project.clips.count == 1 ? "" : "s")")
                        .font(.headline)
                    Spacer()
                    Picker("Sort", selection: $sort) {
                        Text("By Time").tag("time")
                        Text("By Score").tag("score")
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    Button {
                        jobs.findClips(project.id)
                    } label: {
                        Label("Find", systemImage: "sparkle.magnifyingglass")
                    }
                    .help("Find clips again with the method set in Settings (⌘K)")
                    .disabled(project.transcript == nil || jobs.isBusy(project.id))
                }
                .controlSize(.small)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if project.clips.isEmpty {
                    EmptyState(title: "No clips yet", icon: "scissors",
                               message: "Find clips automatically, select words in the transcript, or mark a clip with I and O while the video plays.") {
                        Button("Find Clips") { jobs.findClips(project.id) }
                            .disabled(jobs.isBusy(project.id))
                    }
                } else {
                    ScrollViewReader { reader in
                        ScrollView {
                            LazyVStack(spacing: 6) {
                                ForEach(sorted) { clip in
                                    ClipRow(project: project, clip: clip, isSelected: clip.id == studio.selectedClipID)
                                        .id(clip.id)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.bottom, 10)
                        }
                        .onChange(of: studio.selectedClipID) { _, id in
                            if let id { withAnimation(.snappy) { reader.scrollTo(id, anchor: .center) } }
                        }
                    }
                    if let clip = studio.selectedClip {
                        Divider()
                        ClipDetail(project: project, clip: clip)
                    }
                }
            }
        }
    }

    private var sorted: [Clip] {
        sort == "score" ? project.clips.sorted { ($0.score ?? -1) > ($1.score ?? -1) } : project.clips.sorted { $0.start < $1.start }
    }
}

private struct ClipRow: View {
    @Environment(Studio.self) private var studio
    @Environment(Jobs.self) private var jobs
    let project: Project
    let clip: Clip
    let isSelected: Bool
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let score = clip.score {
                ScoreBadge(score: score)
            } else {
                Image(systemName: "hand.point.up.left.fill")
                    .foregroundStyle(.teal)
                    .frame(width: 34, height: 34)
                    .background(Color.teal.opacity(0.14), in: .circle)
                    .help("A clip you made")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(clip.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(clip.start.clock)–\(clip.end.clock) · \(clip.duration.shortDuration)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if !clip.reasons.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(clip.reasons.prefix(2), id: \.self) { Chip(text: $0) }
                    }
                    .lineLimit(1)
                }
                if let progress = jobs.exporting[clip.id] {
                    ProgressView(value: progress)
                        .controlSize(.small)
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 0)
            if hovering || isSelected {
                VStack(spacing: 6) {
                    Button { studio.select(clip); studio.player.play(clip.range) } label: { Image(systemName: "play.fill") }
                        .help("Play this clip (Return)")
                    if let file = jobs.exported[clip.id] {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([file]) } label: { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                            .help("Exported. Show in Finder")
                    } else {
                        Button { jobs.export(project.id, clips: [clip.id]) } label: { Image(systemName: "square.and.arrow.up") }
                            .help("Export this clip (⌘E)")
                            .disabled(jobs.exporting[clip.id] != nil)
                    }
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(10)
        .background(isSelected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(hovering ? Color.primary.opacity(0.04) : .clear), in: .rect(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(isSelected ? AnyShapeStyle(.tint.opacity(0.5)) : AnyShapeStyle(.clear)))
        .contentShape(.rect)
        .onTapGesture { studio.select(clip) }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Play") { studio.select(clip); studio.player.play(clip.range) }
            Button("Export") { jobs.export(project.id, clips: [clip.id]) }
            Button("Publish…") { studio.publish(clip.id, in: project.id) }
            Divider()
            Button("Delete", role: .destructive) {
                Library.shared.update(project.id) { $0.clips.removeAll { $0.id == clip.id } }
            }
        }
    }
}

/// The selected clip's title, edges and framing, and its export.
private struct ClipDetail: View {
    @Environment(Studio.self) private var studio
    @Environment(Jobs.self) private var jobs
    let project: Project
    let clip: Clip
    @State private var title = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Title", text: $title)
                .textFieldStyle(.roundedBorder)
                .onSubmit(saveTitle)
                .onChange(of: clip.id, initial: true) { title = clip.title }
                .onChange(of: title) { saveTitle() }

            HStack(spacing: 16) {
                edge("Start", clip.start) { change(start: $0) }
                edge("End", clip.end) { change(end: $0) }
            }

            HStack {
                Picker("Framing", selection: Binding(get: { clip.framing }, set: { framing in
                    Library.shared.update(project.id) { project in
                        var clip = clip
                        clip.framing = framing
                        project.update(clip)
                    }
                })) {
                    Text("Default").tag(Framing?.none)
                    ForEach(Framing.allCases) { Text($0.label).tag(Framing?.some($0)) }
                }
                .fixedSize()
                Spacer()
                if clip.track == nil, (clip.framing ?? Prefs.value(Pref.framing, default: Framing.speaker)) == .speaker {
                    Button("Find Speaker") { jobs.frame(project.id, clip: clip.id) }
                        .help("Track the speaker now, so the preview shows the crop")
                        .disabled(jobs.isBusy(project.id))
                }
            }
            .controlSize(.small)

            HStack {
                Button {
                    studio.player.play(clip.range)
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                Spacer()
                if let progress = jobs.exporting[clip.id] {
                    ProgressView(value: progress).frame(width: 90)
                    Button("Cancel") { jobs.cancelExport(clip.id) }
                } else {
                    if let file = jobs.exported[clip.id] {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                    }
                    Button {
                        studio.publish(clip.id, in: project.id)
                    } label: {
                        Label("Publish", systemImage: "paperplane")
                    }
                    .help("Post to X, YouTube, TikTok, LinkedIn and more through Zernio")
                    Button {
                        jobs.export(project.id, clips: [clip.id])
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(16)
    }

    private func edge(_ label: String, _ value: Double, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 2) {
                Button { set(value - 0.1) } label: { Image(systemName: "minus") }
                    .help("0.1 second earlier")
                Text(value.preciseClock)
                    .monospacedDigit()
                    .font(.callout)
                    .frame(minWidth: 56)
                Button { set(value + 0.1) } label: { Image(systemName: "plus") }
                    .help("0.1 second later")
                Button { set(studio.player.time) } label: { Image(systemName: "arrow.down.to.line") }
                    .help("Set to the playhead")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }

    private func change(start: Double? = nil, end: Double? = nil) {
        Library.shared.update(project.id) { project in
            var clip = clip
            if let start { clip.start = max(0, min(start, clip.end - 0.5)); clip.track = nil }
            if let end { clip.end = min(project.duration, max(end, clip.start + 0.5)) }
            project.update(clip)
        }
        studio.player.seek(to: start ?? end ?? clip.start)
    }

    private func saveTitle() {
        guard title != clip.title, !title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        Library.shared.update(project.id) { project in
            var clip = clip
            clip.title = title
            project.update(clip)
        }
    }
}

import SwiftUI
import UniformTypeIdentifiers

/// The Settings window (⌘,): native tabs and grouped forms, like System Settings.
struct SettingsView: View {
    /// Reopens on the tab you used last.
    @AppStorage("settings.tab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Downloads", systemImage: "arrow.down.circle", value: "downloads") { DownloadSettings() }
            Tab("Transcription", systemImage: "captions.bubble", value: "transcription") { TranscriptionSettings() }
            Tab("Clip Finding", systemImage: "sparkle.magnifyingglass", value: "finding") { FindingSettings() }
            Tab("Captions & Export", systemImage: "textformat", value: "captions") { CaptionSettings() }
            Tab("Publishing", systemImage: "paperplane", value: "publishing") { PublishingSettings() }
            Tab("Appearance", systemImage: "paintpalette", value: "appearance") { AppearanceSettings() }
        }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(Pref.exportFolder) private var exportFolder = ""
    @AppStorage(Pref.autoTranscribe) private var autoTranscribe = true
    @AppStorage(Pref.autoFind) private var autoFind = true

    var body: some View {
        Form {
            SwiftUI.Section {
                Toggle("Transcribe new videos right away", isOn: $autoTranscribe)
                Toggle("Then find clips", isOn: $autoFind)
                    .disabled(!autoTranscribe)
            } footer: {
                Text("With both on, a pasted link turns into a list of clips with no more clicks.")
                    .foregroundStyle(.secondary)
            }
            SwiftUI.Section {
                LabeledContent("Export to") {
                    HStack {
                        Text(Prefs.exportFolder.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { exportFolder = url.path }
                        }
                    }
                }
                LabeledContent("Library") {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Projects, downloads and thumbnails").foregroundStyle(.secondary)
                        Button("Show in Finder") { NSWorkspace.shared.open(Library.folder) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }
}

// MARK: - Downloads

private struct DownloadSettings: View {
    @Environment(Tools.self) private var tools
    @AppStorage(Pref.maxHeight) private var maxHeight = Defaults.maxHeight
    @AppStorage(Pref.cookieSource) private var cookieSource = "none"
    @AppStorage(Pref.cookieProfile) private var cookieProfile = ""
    @AppStorage(Pref.cookieFile) private var cookieFile = ""
    @AppStorage(Pref.extraArguments) private var extraArguments = ""
    @AppStorage(Pref.rateLimit) private var rateLimit = ""
    @AppStorage(Pref.ytdlpPath) private var ytdlpPath = ""
    @State private var testResult: Result<String, Error>?
    @State private var testing = false

    private var browser: Browser? { Browser.with(id: cookieSource) }

    var body: some View {
        Form {
            SwiftUI.Section {
                LabeledContent("yt-dlp") {
                    HStack(spacing: 8) {
                        if tools.busy.contains(.ytdlp) {
                            ProgressView().controlSize(.small)
                        } else if let version = tools.versions[.ytdlp] {
                            Text(version).foregroundStyle(.secondary).monospacedDigit()
                            Button("Update") { tools.update(.ytdlp) }
                        } else if tools.isInstalled(.ytdlp) {
                            Text("Installed").foregroundStyle(.secondary)
                        } else {
                            Button("Install") { tools.install(.ytdlp) }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                TextField("Custom location", text: $ytdlpPath, prompt: Text(tools.locations[.ytdlp]?.path ?? "/opt/homebrew/bin/yt-dlp"))
                    .onSubmit { tools.refresh() }
                Picker("Best quality", selection: $maxHeight) {
                    Text("2160p (4K)").tag(2160)
                    Text("1440p").tag(1440)
                    Text("1080p").tag(1080)
                    Text("720p").tag(720)
                    Text("No limit").tag(0)
                }
                TextField("Speed limit", text: $rateLimit, prompt: Text("None, or like 5M"))
            } header: {
                Text("Downloader")
            } footer: {
                Text("When a site stops working, update yt-dlp first; it keeps up with changes within days. Hyperclip prefers H.264 so the Mac can play and export without converting.")
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                Picker("Use cookies from", selection: $cookieSource) {
                    Text("Nothing").tag("none")
                    Divider()
                    ForEach(Browser.installed) { browser in
                        HStack {
                            if let icon = browser.icon { Image(nsImage: icon.resized(16)) }
                            Text(browser.name)
                        }
                        .tag(browser.id)
                    }
                    let others = Browser.all.filter { !$0.isInstalled }
                    if !others.isEmpty {
                        Menu("Other Browsers") {
                            ForEach(others) { Text($0.name).tag($0.id) }
                        }
                    }
                    Divider()
                    Text("A cookies.txt File").tag("file")
                }
                .onChange(of: cookieSource) {
                    cookieProfile = ""
                    testResult = nil
                }

                if let browser {
                    let profiles = browser.profiles
                    if profiles.count > 1 {
                        Picker("Profile", selection: $cookieProfile) {
                            Text("Default").tag("")
                            ForEach(profiles) { Text($0.name).tag($0.id) }
                        }
                    }
                    if browser.engine == .safari {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "lock.shield").foregroundStyle(.orange)
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Safari keeps its cookies where only apps with Full Disk Access can read them. Add Hyperclip under Privacy & Security › Full Disk Access.")
                                    .font(.callout)
                                Button("Open Full Disk Access") {
                                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                                }
                                .controlSize(.small)
                            }
                        }
                    } else if case .chromium(let keychain, _) = browser.engine {
                        Text("macOS asks once for access to “\(keychain)” in the Keychain: choose Always Allow. Signing in through \(browser.name) works best with the browser closed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }

                if cookieSource == "file" {
                    LabeledContent("File") {
                        HStack {
                            Text(cookieFile.isEmpty ? "None chosen" : (cookieFile as NSString).lastPathComponent)
                                .foregroundStyle(.secondary)
                            Button("Choose…") {
                                let panel = NSOpenPanel()
                                panel.allowedContentTypes = [.plainText, .text, .data]
                                if panel.runModal() == .OK, let url = panel.url { cookieFile = url.path }
                            }
                        }
                    }
                }

                if cookieSource != "none" {
                    HStack {
                        Button("Test") { test() }
                            .disabled(testing || (cookieSource == "file" && cookieFile.isEmpty))
                        if testing { ProgressView().controlSize(.small) }
                        switch testResult {
                        case .success(let message):
                            Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failure(let error):
                            Label(error.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                                .textSelection(.enabled)
                        case nil:
                            EmptyView()
                        }
                    }
                    .font(.callout)
                }
            } header: {
                Text("Signing in")
            } footer: {
                Text("Some videos need an account: age-restricted, members-only or private ones, or when YouTube asks to confirm you're not a bot. Sign in to the site in your browser and Hyperclip downloads as you. Cookies are read for each download and never leave this Mac.")
                    .foregroundStyle(.secondary)
            }

            SwiftUI.Section {
                TextField("Extra arguments", text: $extraArguments, prompt: Text("--sponsorblock-remove all"))
                    .font(.system(.body, design: .monospaced))
            } header: {
                Text("Advanced")
            } footer: {
                Text("Passed to yt-dlp as they are, before the link.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 640)
    }

    private func test() {
        testing = true
        testResult = nil
        Task {
            do {
                testResult = .success(try await CookieSource.current.test())
            } catch {
                testResult = .failure(error)
            }
            testing = false
        }
    }
}

// MARK: - Transcription

private struct TranscriptionSettings: View {
    @Environment(Tools.self) private var tools
    @Environment(WhisperModels.self) private var models
    @AppStorage(Pref.engine) private var engine = TranscriptionEngine.whisper
    @AppStorage(Pref.language) private var language = ""
    @AppStorage(Pref.whisperModel) private var whisperModel = ""
    @AppStorage(Pref.whisperThreads) private var threads = 0
    @AppStorage(Pref.transcriptionURL) private var apiURL = ""
    @AppStorage(Pref.transcriptionModel) private var apiModel = ""

    var body: some View {
        Form {
            SwiftUI.Section {
                Picker("Engine", selection: $engine) {
                    ForEach(TranscriptionEngine.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.radioGroup)
                Text(engine.summary).font(.callout).foregroundStyle(.secondary)
                Picker("Language", selection: $language) {
                    Text(engine == .apple ? "System language" : "Detect automatically").tag("")
                    Divider()
                    ForEach(Self.languages, id: \.self) { code in
                        Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                    }
                }
            }

            if engine == .whisper {
                SwiftUI.Section {
                    let downloaded = WhisperModel.all.filter { $0.file != nil }
                    if downloaded.isEmpty {
                        HStack {
                            Text("No model yet.")
                            Spacer()
                            let recommended = WhisperModel.all[0]
                            if let progress = models.progress[recommended.id] {
                                ProgressView(value: progress).frame(width: 120)
                            } else {
                                Button("Download \(recommended.name) (\(recommended.size.bytes))") { models.download(recommended) }
                            }
                        }
                    } else {
                        Picker("Model", selection: Binding(get: { WhisperModel.selected.id }, set: { whisperModel = $0 })) {
                            ForEach(downloaded) { Text($0.name).tag($0.id) }
                        }
                    }
                    LabeledContent("whisper.cpp") {
                        if tools.isInstalled(.whisper) {
                            Text(tools.locations[.whisper]?.path ?? "").foregroundStyle(.secondary).font(.callout)
                        } else if tools.busy.contains(.whisper) {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Install") { tools.install(.whisper) }
                        }
                    }
                    Picker("Threads", selection: $threads) {
                        Text("Automatic").tag(0)
                        ForEach([2, 4, 6, 8, 10, 12], id: \.self) { Text("\($0)").tag($0) }
                    }
                } header: {
                    Text("Whisper")
                } footer: {
                    Text("More models are under Models & Tools.").foregroundStyle(.secondary)
                }
                .id(models.revision)
            }

            if engine == .api {
                SwiftUI.Section {
                    TextField("Server", text: $apiURL, prompt: Text("https://api.openai.com/v1"))
                    TextField("Model", text: $apiModel, prompt: Text("whisper-1"))
                    KeyField(secret: .transcription)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Hyperclip sends 16 kHz mono audio and asks for word timestamps (verbose_json). Hosted services cap uploads, around 25 MB, which is about 13 minutes; transcribe longer videos locally. Groq: https://api.groq.com/openai/v1 with whisper-large-v3-turbo.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 560)
    }

    static let languages = ["en", "fr", "es", "de", "it", "pt", "nl", "ja", "zh", "ko", "ru", "ar", "hi", "pl", "tr", "sv", "uk", "id", "vi"]
}

// MARK: - Clip finding

private struct FindingSettings: View {
    @AppStorage(Pref.finder) private var method = FinderMethod.heuristic
    @AppStorage(Pref.clipCount) private var count = Defaults.clipCount
    @AppStorage(Pref.minLength) private var minLength = Defaults.minLength
    @AppStorage(Pref.maxLength) private var maxLength = Defaults.maxLength
    @AppStorage(Pref.decisionPreset) private var decisionPreset = DecisionPreset.typesafe
    @AppStorage(Pref.decisionURL) private var decisionURL = ""
    @AppStorage(Pref.decisionPath) private var decisionPath = ""
    @AppStorage(Pref.decisionModel) private var decisionModel = ""
    @AppStorage(Pref.llmPreset) private var llmPreset = LLMPreset.ollama
    @AppStorage(Pref.llmURL) private var llmURL = ""
    @AppStorage(Pref.llmModel) private var llmModel = ""
    @AppStorage(Pref.llmGuidance) private var guidance = ""
    @State private var testResult: Result<String, Error>?
    @State private var testing = false

    var body: some View {
        Form {
            SwiftUI.Section {
                Picker("Method", selection: $method) {
                    ForEach(FinderMethod.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .onChange(of: method) { testResult = nil }
                Text(method.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            SwiftUI.Section("Clips") {
                Stepper("Up to \(count) clips per video", value: $count, in: 1...30)
                LabeledContent("Length") {
                    HStack(spacing: 8) {
                        TextField("", value: $minLength, format: .number).frame(width: 50)
                        Text("to")
                        TextField("", value: $maxLength, format: .number).frame(width: 50)
                        Text("seconds").foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 8) {
                    Text("Presets").foregroundStyle(.secondary)
                    Button("Shorts 15–45s") { minLength = 15; maxLength = 45 }
                    Button("Reels 20–60s") { minLength = 20; maxLength = 60 }
                    Button("TikTok 30–90s") { minLength = 30; maxLength = 90 }
                }
                .controlSize(.small)
            }

            if method == .decision {
                SwiftUI.Section {
                    Picker("Server", selection: $decisionPreset) {
                        ForEach(DecisionPreset.allCases) { Text($0.name).tag($0) }
                    }
                    .onChange(of: decisionPreset) {
                        decisionURL = ""
                        decisionPath = ""
                        decisionModel = ""
                        testResult = nil
                    }
                    TextField("Address", text: $decisionURL, prompt: Text(decisionPreset.url))
                    TextField("Endpoint", text: $decisionPath, prompt: Text(decisionPreset.path))
                    TextField("Model", text: $decisionModel, prompt: Text(decisionPreset.model.isEmpty ? "As the server decides" : decisionPreset.model))
                    KeyField(secret: .decision)
                    testRow { try await Decision.test() }
                } header: {
                    Text("Decision model")
                } footer: {
                    Text("Each shortlisted clip is sent as state, with four typed questions: a score for the hook, a yes/no on standing alone, a score for the payoff and a yes/no on being shared. Hyperclip weighs the probabilities into one score. Self-hosted models such as Laya or Von run on a CPU in about 2 GB.")
                        .foregroundStyle(.secondary)
                }
            }

            if method == .llm {
                SwiftUI.Section {
                    Picker("Server", selection: $llmPreset) {
                        ForEach(LLMPreset.allCases) { Text($0.name).tag($0) }
                    }
                    .onChange(of: llmPreset) {
                        llmURL = ""
                        llmModel = ""
                        testResult = nil
                    }
                    TextField("Address", text: $llmURL, prompt: Text(llmPreset.url.isEmpty ? "https://…/v1" : llmPreset.url))
                    TextField("Model", text: $llmModel, prompt: Text(llmPreset.model.isEmpty ? "The loaded model" : llmPreset.model))
                    if !llmPreset.isLocal { KeyField(secret: .llm) }
                    TextField("Look for", text: $guidance, prompt: Text("Funny moments, hot takes, practical tips…"), axis: .vertical)
                        .lineLimit(2...4)
                    testRow { try await LLM.test() }
                } header: {
                    Text("Language model")
                } footer: {
                    Text(llmPreset == .ollama ? "Run `ollama pull qwen3:8b` first. Any model works; bigger ones pick better clips and titles." : "Any chat model behind an OpenAI-compatible /chat/completions endpoint.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 640)
    }

    private func testRow(_ run: @escaping () async throws -> String) -> some View {
        HStack {
            Button("Test Connection") {
                testing = true
                testResult = nil
                Task {
                    do { testResult = .success(try await run()) } catch { testResult = .failure(error) }
                    testing = false
                }
            }
            .disabled(testing)
            if testing { ProgressView().controlSize(.small) }
            switch testResult {
            case .success(let message): Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            case .failure(let error): Label(error.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
            case nil: EmptyView()
            }
        }
        .font(.callout)
    }
}

// MARK: - Publishing

private struct PublishingSettings: View {
    @State private var testResult: Result<String, Error>?
    @State private var testing = false

    var body: some View {
        Form {
            SwiftUI.Section {
                KeyField(secret: .zernio)
                HStack {
                    Button("Test") {
                        testing = true
                        testResult = nil
                        Task {
                            do { testResult = .success(try await Zernio.test()) } catch { testResult = .failure(error) }
                            testing = false
                        }
                    }
                    .disabled(testing)
                    if testing { ProgressView().controlSize(.small) }
                    switch testResult {
                    case .success(let message): Label(message, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .failure(let error): Label(error.localizedDescription, systemImage: "xmark.octagon.fill").foregroundStyle(.red).lineLimit(3)
                    case nil: EmptyView()
                    }
                }
                .font(.callout)
            } header: {
                Text("Zernio")
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Zernio posts to X, YouTube, TikTok, Instagram, LinkedIn, Facebook, Threads, Bluesky, Pinterest and more with one API. Connect your accounts in its dashboard, create an API key there, and paste it here. Clips upload straight to Zernio's storage, then publish now or at the time you pick.")
                    HStack {
                        Link("Open the dashboard", destination: URL(string: "https://zernio.com/dashboard")!)
                        Link("Pricing", destination: URL(string: "https://zernio.com/pricing")!)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }
}

/// An API key, saved in the Keychain.
private struct KeyField: View {
    let secret: Secret
    @State private var key = ""
    @State private var saved: String?

    var body: some View {
        HStack {
            SecureField("API key", text: $key, prompt: Text(saved == nil ? "Optional" : "Saved in the Keychain"))
                .onSubmit(save)
            if key != "" || saved != nil {
                Button(key.isEmpty ? "Remove" : "Save", action: save)
                    .disabled(key.isEmpty && saved == nil)
            }
        }
        .onAppear { saved = secret.value }
    }

    private func save() {
        secret.save(key)
        saved = secret.value
        key = ""
    }
}

// MARK: - Captions and export

private struct CaptionSettings: View {
    @AppStorage(Pref.aspect) private var aspect = Aspect.vertical
    @AppStorage(Pref.framing) private var framing = Framing.speaker
    @AppStorage(Pref.resolution) private var resolution = Resolution.p1080
    @AppStorage(Pref.captionStyle) private var preset = CaptionStyle.Preset.bold
    @AppStorage(Pref.captionFont) private var font = Defaults.captionFont
    @AppStorage(Pref.captionSize) private var size = Defaults.captionSize
    @AppStorage(Pref.captionWords) private var words = Defaults.captionWords
    @AppStorage(Pref.captionUppercase) private var uppercase = true
    @AppStorage(Pref.captionHighlight) private var highlight = Defaults.captionHighlight
    @AppStorage(Pref.captionPosition) private var position = Defaults.captionPosition

    var body: some View {
        Form {
            SwiftUI.Section {
                CaptionPreview()
                    .listRowInsets(EdgeInsets())
            }

            SwiftUI.Section("Captions") {
                Picker("Style", selection: $preset) {
                    ForEach(CaptionStyle.Preset.allCases) { Text($0.name).tag($0) }
                }
                if preset != .none {
                    Picker("Font", selection: $font) {
                        ForEach(Self.fonts, id: \.self) { Text($0).font(.custom($0, size: 13)).tag($0) }
                    }
                    LabeledContent("Size") {
                        HStack {
                            Slider(value: $size, in: 40...120, step: 2).frame(width: 200)
                            Text("\(Int(size))").monospacedDigit().foregroundStyle(.secondary).frame(width: 30)
                        }
                    }
                    if preset != .pop {
                        Stepper("\(words) word\(words == 1 ? "" : "s") at a time", value: $words, in: 1...8)
                    }
                    Toggle("Capital letters", isOn: $uppercase)
                    ColorPicker("Word being said", selection: Binding(
                        get: { Color(nsColor: NSColor(hex: highlight) ?? .systemYellow) },
                        set: { highlight = NSColor($0).hex }
                    ), supportsOpacity: false)
                    LabeledContent("Position") {
                        HStack {
                            Text("Top").foregroundStyle(.secondary)
                            Slider(value: $position, in: 0.12...0.9).frame(width: 180)
                            Text("Bottom").foregroundStyle(.secondary)
                        }
                    }
                }
            }

            SwiftUI.Section("Video") {
                Picker("Shape", selection: $aspect) {
                    ForEach(Aspect.allCases) { Text($0.name).tag($0) }
                }
                Picker("Framing", selection: $framing) {
                    ForEach(Framing.allCases) { Text($0.label).tag($0) }
                }
                Picker("Resolution", selection: $resolution) {
                    ForEach(Resolution.allCases) { Text($0.label).tag($0) }
                }
            }

            SwiftUI.Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        for key in [Pref.captionStyle, Pref.captionFont, Pref.captionSize, Pref.captionWords, Pref.captionUppercase,
                                    Pref.captionHighlight, Pref.captionPosition, Pref.aspect, Pref.framing, Pref.resolution] {
                            UserDefaults.standard.removeObject(forKey: key)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 600, height: 760)
    }

    static let fonts = ["Helvetica Neue", "SF Pro Display", "Avenir Next", "Futura", "Montserrat", "Inter", "Arial Rounded MT Bold",
                        "Impact", "Georgia", "Menlo"].filter { NSFontManager.shared.availableFontFamilies.contains($0) || $0 == "SF Pro Display" }
}

/// A frame with captions as they'll look, redrawn as the settings change.
private struct CaptionPreview: View {
    @AppStorage(Pref.captionStyle) private var preset = CaptionStyle.Preset.bold
    @AppStorage(Pref.captionFont) private var font = Defaults.captionFont
    @AppStorage(Pref.captionSize) private var size = Defaults.captionSize
    @AppStorage(Pref.captionWords) private var words = Defaults.captionWords
    @AppStorage(Pref.captionUppercase) private var uppercase = true
    @AppStorage(Pref.captionHighlight) private var highlight = Defaults.captionHighlight
    @AppStorage(Pref.captionPosition) private var position = Defaults.captionPosition
    @AppStorage(Pref.aspect) private var aspect = Aspect.vertical

    private static let sample: [Word] = "Nobody tells you this about building a company".split(separator: " ").enumerated().map { index, word in
        Word(text: String(word), start: Double(index) * 0.4, end: Double(index) * 0.4 + 0.35)
    }

    var body: some View {
        let ratio = aspect.ratio ?? 16.0 / 9
        let height: CGFloat = 300
        let width = height * ratio
        let clip = Clip(start: 0, end: 4, title: "", origin: .manual)
        let style = CaptionStyle.current
        let pages = CaptionPage.pages(for: Self.sample, clip: clip, perPage: style.wordsPerPage)
        let page = pages.first
        HStack {
            Spacer()
            ZStack {
                LinearGradient(colors: [Color(white: 0.32), Color(white: 0.12)], startPoint: .top, endPoint: .bottom)
                Image(systemName: "person.fill")
                    .font(.system(size: height * 0.42))
                    .foregroundStyle(.white.opacity(0.14))
                    .offset(y: height * 0.08)
                CaptionPreviewLayer(page: page, active: 1, size: CGSize(width: width, height: height))
                    .id("\(preset)\(font)\(size)\(words)\(uppercase)\(highlight)\(position)\(aspect)")
            }
            .frame(width: width, height: height)
            .clipShape(.rect(cornerRadius: 12))
            Spacer()
        }
        .padding(.vertical, 18)
        .background(.black.opacity(0.04))
    }
}

private struct CaptionPreviewLayer: NSViewRepresentable {
    let page: CaptionPage?
    let active: Int
    let size: CGSize

    func makeNSView(context: Context) -> CaptionView { CaptionView() }

    func updateNSView(_ view: CaptionView, context: Context) {
        view.show(page.map { ($0, min(active, $0.words.count - 1)) }, style: .current, scale: size.width / 1080, size: size)
    }
}

// MARK: - Appearance

private struct AppearanceSettings: View {
    @AppStorage(Pref.theme) private var theme = Theme.system
    @AppStorage(Pref.accent) private var accent = AccentChoice.system
    @AppStorage(Pref.darkness) private var darkness = Pref.defaultDarkness
    @AppStorage(Pref.darkSidebar) private var darkSidebar = false
    @AppStorage(Pref.textSize) private var textSize = Pref.defaultTextSize

    var body: some View {
        Form {
            SwiftUI.Section("Theme") {
                HStack(spacing: 0) {
                    ForEach(Theme.allCases) { option in
                        ThemeOption(theme: option, isSelected: theme == option) {
                            withAnimation(.snappy) { theme = option }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 6)

                LabeledContent("Dark mode darkness") {
                    HStack(spacing: 10) {
                        Text("Gray").foregroundStyle(.secondary)
                        Slider(value: $darkness, in: 0...1)
                            .frame(width: 180)
                        Text("Black").foregroundStyle(.secondary)
                    }
                }
                Toggle("Darken the sidebar too", isOn: $darkSidebar)

                LabeledContent("Accent color") {
                    HStack(spacing: 9) {
                        ForEach(AccentChoice.allCases) { option in
                            AccentSwatch(choice: option, isSelected: accent == option) {
                                withAnimation(.snappy) { accent = option }
                            }
                        }
                    }
                }
            }

            SwiftUI.Section("Text") {
                LabeledContent("Transcript size") {
                    HStack(spacing: 10) {
                        Image(systemName: "textformat.size.smaller")
                            .foregroundStyle(.secondary)
                        Slider(value: $textSize, in: 12...22, step: 1)
                            .frame(width: 180)
                        Image(systemName: "textformat.size.larger")
                            .foregroundStyle(.secondary)
                        Text("\(Int(textSize)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 38, alignment: .trailing)
                    }
                }
            }

            SwiftUI.Section {
                HStack {
                    Spacer()
                    Button("Reset to Defaults") {
                        withAnimation(.snappy) { Pref.resetAppearance() }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 470)
    }
}

extension NSImage {
    func resized(_ side: CGFloat) -> NSImage {
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        image.unlockFocus()
        return image
    }
}

/// A miniature window in light, dark, or half of each, like System Settings' appearance picker.
private struct ThemeOption: View {
    let theme: Theme
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                thumbnail
                    .frame(width: 112, height: 72)
                    .clipShape(.rect(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.separator))
                    .padding(3)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(.tint, lineWidth: 3)
                            .opacity(isSelected ? 1 : 0)
                    }
                Text(theme.label)
                    .font(.callout)
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private var thumbnail: some View {
        switch theme {
        case .light: MiniWindow(dark: false)
        case .dark: MiniWindow(dark: true)
        case .system:
            MiniWindow(dark: false)
                .overlay(alignment: .trailing) {
                    MiniWindow(dark: true)
                        .mask(alignment: .trailing) { Rectangle().frame(width: 56) }
                }
        }
    }
}

/// Sidebar, a few lines of text, a timeline and the Export button, in a few rounded strokes.
private struct MiniWindow: View {
    let dark: Bool
    @AppStorage(Pref.darkness) private var darkness = Pref.defaultDarkness
    @AppStorage(Pref.darkSidebar) private var darkSidebar = false

    var body: some View {
        let background = dark ? Color(white: Color.pageWhite(darkness: darkness)) : Color(white: 0.98)
        let sidebar = dark ? Color(white: darkSidebar ? Color.sidebarWhite(darkness: darkness) : 0.2) : Color(white: 0.9)
        let ink = dark ? Color.white.opacity(0.28) : Color.black.opacity(0.16)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 2.5) {
                    ForEach([Color.red, .yellow, .green], id: \.self) { Circle().fill($0.opacity(0.85)).frame(width: 4, height: 4) }
                }
                .padding(.bottom, 4)
                Capsule().fill(.tint).frame(width: 22, height: 4)
                Capsule().fill(ink).frame(width: 18, height: 3)
                Capsule().fill(ink).frame(width: 20, height: 3)
                Spacer()
            }
            .padding(6)
            .frame(width: 34, alignment: .leading)
            .frame(maxHeight: .infinity)
            .background(sidebar)
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(ink).frame(width: 56, height: 3)
                Capsule().fill(ink).frame(width: 44, height: 3)
                HStack(spacing: 1.5) {
                    ForEach([3, 6, 9, 5, 8, 4, 7, 3], id: \.self) { height in
                        Capsule().fill(.tint.opacity(0.85)).frame(width: 2, height: CGFloat(height))
                    }
                }
                .frame(height: 10)
                Spacer()
                HStack {
                    Spacer()
                    Capsule().fill(.tint).frame(width: 18, height: 7)
                }
            }
            .padding(7)
        }
        .background(background)
    }
}

/// One accent color dot; "System" is the multicolor wheel macOS uses for "follow the system".
private struct AccentSwatch: View {
    let choice: AccentChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                if let color = choice.color {
                    Circle().fill(color.gradient)
                } else {
                    Circle().fill(AngularGradient(colors: [.red, .orange, .yellow, .green, .blue, .purple, .pink, .red], center: .center))
                }
                Circle().strokeBorder(.black.opacity(0.12))
                if isSelected {
                    Circle().fill(.white).frame(width: 7, height: 7)
                        .shadow(color: .black.opacity(0.25), radius: 1)
                }
            }
            .frame(width: 20, height: 20)
            .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(choice.label)
        .accessibilityLabel(choice.label)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

import AppKit

/// The app's side of the control socket: each `ControlMethod`, done with the same library and jobs the window
/// uses, so whatever the `hyperclip` command or an agent starts shows in the window as it happens.
enum ControlAPI {
    private static var server: ControlServer?

    static func start() {
        let server = ControlServer(path: Control.socket.path) { request in try await handle(request) }
        do {
            try server.start()
            self.server = server
        } catch {
            NSLog("Hyperclip: the control socket didn't start: \(error.localizedDescription)")
        }
    }

    static func stop() { server?.stop() }

    static func handle(_ request: ControlRequest) async throws -> JSONValue {
        guard let method = ControlMethod(rawValue: request.method) else {
            throw ControlError("No method \(request.method). Methods: \(ControlMethod.allCases.map(\.rawValue).joined(separator: ", ")).")
        }
        let params = Params(request.params)
        let library = Library.shared, jobs = Jobs.shared

        switch method {
        case .status:
            let tools = Tools.shared
            return [
                "app": "Hyperclip",
                "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"),
                "projects": .number(Double(library.projects.count)),
                "busy": .array(library.projects.filter { jobs.isBusy($0.id) }.map { summary($0) }),
                "exporting": .number(Double(jobs.exporting.count)),
                "tools": .object(Dictionary(uniqueKeysWithValues: Tool.allCases.map { tool in
                    (tool.rawValue, JSONValue.object(["installed": .bool(tools.isInstalled(tool)), "version": tools.versions[tool].map(JSONValue.string) ?? .null]))
                })),
                "transcription": .string(TranscriptionEngine.current.rawValue),
                "whisperModel": .string(WhisperModel.selectedFile == nil ? "none" : WhisperModel.selected.id),
                "clipFinding": .string(FinderMethod.current.rawValue),
                "publishing": .bool(Zernio.hasKey),
            ]

        case .listProjects:
            return .array(library.projects.map { summary($0) })

        case .getProject:
            return detail(try project(params))

        case .importVideo:
            let id: UUID
            if let link = params.string("url") {
                guard Tools.shared.isInstalled(.ytdlp) else { throw ControlError(Tool.ytdlp.missingMessage) }
                var section: ClosedRange<Double>?
                if let to = params.seconds("to") { section = (params.seconds("from") ?? 0)...to }
                id = jobs.importLink(link, section: section)
            } else if let path = params.string("path") {
                let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: url.path) else { throw ControlError("No file at \(url.path).") }
                id = jobs.importFile(url)
            } else {
                throw ControlError("importVideo needs a url or a path.")
            }
            return summary(library.project(id)!)

        case .transcribe:
            let project = try project(params)
            guard !jobs.isBusy(project.id) else { throw busy(project) }
            let engine = try params.string("engine").map { name in
                guard let engine = TranscriptionEngine(rawValue: name) else { throw ControlError("Engines: apple, whisper, api.") }
                return engine
            }
            jobs.transcribe(project.id, engine: engine, language: params.string("language"))
            return summary(library.project(project.id)!)

        case .transcript:
            let project = try project(params)
            guard let transcript = project.transcript else { throw ControlError("“\(project.title)” has no transcript yet. Transcribe it first.") }
            let from = params.seconds("from") ?? 0, to = params.seconds("to") ?? .infinity
            let words = transcript.words.filter { $0.end > from && $0.start < to }
            switch params.string("format") ?? "sentences" {
            case "text":
                return ["text": .string(words.map(\.text).joined(separator: " "))]
            case "words":
                return ["words": .array(words.map { ["text": .string($0.text), "start": .number(round($0.start)), "end": .number(round($0.end))] })]
            case "srt":
                return ["srt": .string(srt(transcript.sentences().filter { $0.end > from && $0.start < to }))]
            default:
                return ["sentences": .array(transcript.sentences().filter { $0.end > from && $0.start < to }.map {
                    ["index": .number(Double($0.index)), "start": .number(round($0.start)), "end": .number(round($0.end)), "text": .string($0.text)]
                })]
            }

        case .findClips:
            let project = try project(params)
            guard project.transcript != nil else { throw ControlError("“\(project.title)” has no transcript yet. Transcribe it first.") }
            guard !jobs.isBusy(project.id) else { throw busy(project) }
            var settings = Finder.Settings.current
            if let name = params.string("method") {
                guard let method = FinderMethod(rawValue: name) else { throw ControlError("Methods: heuristic, decision, llm.") }
                settings.method = method
            }
            if let count = params.int("count") { settings.count = max(1, count) }
            let low = params.double("minLength") ?? settings.lengths.lowerBound, high = params.double("maxLength") ?? settings.lengths.upperBound
            settings.lengths = min(low, high)...max(low, high, low + 5)
            jobs.findClips(project.id, settings: settings)
            return summary(library.project(project.id)!)

        case .addClip:
            let project = try project(params)
            guard let start = params.seconds("start"), let end = params.seconds("end"), end > start + 0.3 else {
                throw ControlError("addClip needs start and end, in seconds or as 1:02.5, with end after start.")
            }
            let text = project.transcript?.text(in: start...end) ?? ""
            let clip = Clip(start: max(0, start), end: min(project.duration > 0 ? project.duration : end, end),
                            title: params.string("title") ?? (text.isEmpty ? "Clip at \(start.clock)" : Finder.title(from: String(text.prefix(80)))),
                            origin: .manual)
            library.update(project.id) { project in
                project.clips.append(clip)
                project.clips.sort { $0.start < $1.start }
            }
            return info(clip, in: library.project(project.id)!)

        case .updateClip:
            let project = try project(params)
            var clip = try self.clip(params, in: project)
            if let start = params.seconds("start") { clip.start = max(0, start); clip.track = nil }
            if let end = params.seconds("end") { clip.end = end }
            guard clip.end > clip.start + 0.3 else { throw ControlError("The clip would end before it starts.") }
            if let title = params.string("title") { clip.title = title }
            if let framing = params.string("framing") {
                guard framing == "default" || Framing(rawValue: framing) != nil else { throw ControlError("Framing: speaker, center or default.") }
                clip.framing = Framing(rawValue: framing)
            }
            let updated = clip
            library.update(project.id) { $0.update(updated) }
            return info(updated, in: library.project(project.id)!)

        case .deleteClip:
            let project = try project(params)
            let clip = try self.clip(params, in: project)
            library.update(project.id) { $0.clips.removeAll { $0.id == clip.id } }
            return ["deleted": .string(clip.id.uuidString)]

        case .export:
            let project = try project(params)
            guard project.media != nil else { throw ControlError("“\(project.title)” has no video yet.") }
            var clips: [Clip]
            if let names = params.array("clips") {
                clips = try names.map { try clip(named: $0, in: project) }
            } else if let best = params.int("best") {
                clips = Array(project.clips.sorted { ($0.score ?? -1) > ($1.score ?? -1) }.prefix(best))
            } else {
                clips = project.clips
            }
            guard !clips.isEmpty else { throw ControlError("“\(project.title)” has no clips to export. Find clips or add one first.") }
            var options = Exporter.Options.current
            if let name = params.string("aspect") {
                guard let aspect = Aspect(rawValue: name) ?? Aspect.allCases.first(where: { $0.label == name }) else {
                    throw ControlError("Aspect: vertical (9:16), portrait (4:5), square (1:1) or original.")
                }
                options.aspect = aspect
            }
            if let name = params.string("framing") {
                guard let framing = Framing(rawValue: name) else { throw ControlError("Framing: speaker or center.") }
                options.framing = framing
            }
            if let name = params.string("resolution") {
                guard let resolution = Resolution(rawValue: name) else { throw ControlError("Resolution: p1080, p720 or source.") }
                options.resolution = resolution
            }
            if let name = params.string("captions") {
                guard let preset = CaptionStyle.Preset(rawValue: name) else { throw ControlError("Captions: bold, clean, boxed, pop or none.") }
                options.captions = .make(preset, saved: preset == Prefs.value(Pref.captionStyle, default: CaptionStyle.Preset.bold))
            }
            jobs.export(project.id, clips: clips.map(\.id), options: options)
            return ["queued": .array(clips.map { .string($0.id.uuidString) }), "folder": .string(Prefs.exportFolder.path)]

        case .listExports:
            return .array(library.allExports.map { exportInfo($0.export, project: $0.project) })

        case .publish:
            let (project, export) = try findExport(params.string("export") ?? "latest")
            guard Zernio.hasKey else { throw Zernio.Failure.noKey }
            let available = try await Zernio.accounts()
            let wanted = params.array("accounts") ?? []
            guard !wanted.isEmpty else {
                throw ControlError("Say which accounts to post to: \(available.map { "\($0.platform):\($0.id)" }.joined(separator: ", ")).")
            }
            var chosen: [Zernio.Account] = []
            for name in wanted {
                let key = name.lowercased() == "x" ? "twitter" : name.lowercased()
                let matches = available.filter { $0.id == name || $0.platform == key || $0.username?.lowercased() == key.trimmingCharacters(in: ["@"]) }
                guard !matches.isEmpty else { throw ControlError("No connected account matches \(name). Run accounts to see them.") }
                chosen += matches.filter { account in !chosen.contains { $0.id == account.id } }
            }
            if chosen.contains(where: { $0.platform == "tiktok" }), params.bool("tiktokConsent") != true {
                throw ControlError("Posting to TikTok needs tiktokConsent: true, confirming the creator agrees to TikTok's Music Usage Confirmation.")
            }
            var post = Zernio.Post(caption: params.string("caption") ?? export.title, title: params.string("title") ?? export.title, accounts: chosen)
            if let visibility = params.string("visibility") {
                guard let value = Zernio.Visibility(rawValue: visibility) else { throw ControlError("Visibility: public, unlisted or private.") }
                post.youtubeVisibility = value
            }
            if let privacy = params.string("tiktokPrivacy") {
                guard let value = Zernio.TikTokPrivacy(rawValue: privacy) else {
                    throw ControlError("TikTok privacy: \(Zernio.TikTokPrivacy.allCases.map(\.rawValue).joined(separator: ", ")).")
                }
                post.tiktokPrivacy = value
            }
            if let at = params.string("at") {
                guard let date = ISO8601DateFormatter().date(from: at) else { throw ControlError("at must be ISO 8601 with a zone, like 2026-10-24T18:00:00+02:00.") }
                post.schedule = date
            }
            let outcomes = try await Zernio.publish(export.file, post: post) { _, _ in }
            record(outcomes, accounts: chosen, export: export.id, project: project.id)
            return .array(outcomes.map {
                ["platform": .string($0.platform), "status": .string($0.status), "url": $0.url.map(JSONValue.string) ?? .null, "error": $0.error.map(JSONValue.string) ?? .null]
            })

        case .accounts:
            return .array(try await Zernio.accounts().map {
                ["id": .string($0.id), "platform": .string($0.platform), "username": $0.username.map(JSONValue.string) ?? .null,
                 "displayName": $0.displayName.map(JSONValue.string) ?? .null, "usable": .bool($0.isUsable)]
            })

        case .getSettings:
            return ControlSettings.all

        case .setSetting:
            guard let key = params.string("key"), let value = params.raw("value") else { throw ControlError("setSetting needs key and value.") }
            try ControlSettings.set(key, value)
            return ControlSettings.all

        case .listModels:
            return .array(WhisperModel.all.map { model in
                [
                    "id": .string(model.id), "name": .string(model.name), "size": .number(Double(model.size)),
                    "installed": .bool(model.file != nil), "selected": .bool(model.file != nil && WhisperModel.selected == model),
                    "downloading": WhisperModels.shared.progress[model.id].map(JSONValue.number) ?? .null,
                ]
            })

        case .downloadModel:
            guard let id = params.string("model"), let model = WhisperModel.all.first(where: { $0.id == id }) else {
                throw ControlError("Models: \(WhisperModel.all.map(\.id).joined(separator: ", ")).")
            }
            if model.file == nil { WhisperModels.shared.download(model) }
            return ["model": .string(model.id), "installed": .bool(model.file != nil)]

        case .cancel:
            let project = try project(params)
            jobs.cancel(project.id)
            return summary(project)

        case .deleteProject:
            let project = try project(params)
            Studio.shared.deleteProject(project.id)
            return ["deleted": .string(project.id.uuidString)]

        case .show:
            NSApp.unhide(nil)
            NSApp.activate()
            NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true || $0.frame.width > 700 }?.makeKeyAndOrderFront(nil)
            if params.string("project") != nil {
                let project = try project(params)
                Studio.shared.open(project.id)
                if params.string("clip") != nil || params.int("clip") != nil { Studio.shared.select(try clip(params, in: project)) }
            }
            return ["shown": true]
        }
    }

    // MARK: - Finding things

    static func project(_ params: Params) throws -> Project {
        guard let name = params.string("project") else { throw ControlError("Say which project: its id, a word of its title, or latest.") }
        return try findProject(name)
    }

    static func findProject(_ name: String) throws -> Project {
        let projects = Library.shared.projects
        if name == "latest" {
            guard let latest = projects.max(by: { $0.createdAt < $1.createdAt }) else { throw ControlError("There are no projects yet.") }
            return latest
        }
        let lower = name.lowercased()
        if let exact = projects.first(where: { $0.id.uuidString.lowercased().hasPrefix(lower) }) { return exact }
        let matches = projects.filter { $0.title.lowercased().contains(lower) }
        guard let first = matches.first else { throw ControlError("No project matches “\(name)”. Run list to see them.") }
        guard matches.count == 1 else {
            throw ControlError("“\(name)” matches \(matches.count) projects: \(matches.map { "\($0.title) (\($0.id.uuidString.prefix(8)))" }.joined(separator: ", ")).")
        }
        return first
    }

    static func clip(_ params: Params, in project: Project) throws -> Clip {
        if let number = params.int("clip") { return try clip(named: String(number), in: project) }
        guard let name = params.string("clip") else { throw ControlError("Say which clip: its number or id.") }
        return try clip(named: name, in: project)
    }

    static func clip(named name: String, in project: Project) throws -> Clip {
        let ordered = project.clips.sorted { $0.start < $1.start }
        if let number = Int(name), ordered.indices.contains(number - 1) { return ordered[number - 1] }
        if let clip = ordered.first(where: { $0.id.uuidString.lowercased().hasPrefix(name.lowercased()) }) { return clip }
        throw ControlError("No clip \(name) in “\(project.title)”, which has \(ordered.count).")
    }

    static func findExport(_ name: String) throws -> (Project, Export) {
        let all = Library.shared.allExports
        guard let found = name == "latest" ? all.first : all.first(where: { $0.export.id.uuidString.lowercased().hasPrefix(name.lowercased()) }) else {
            throw ControlError(all.isEmpty ? "Nothing's been exported yet." : "No export matches \(name). Run exports to see them.")
        }
        return (found.project, found.export)
    }

    private static func busy(_ project: Project) -> ControlError {
        ControlError("“\(project.title)” is busy: \(Jobs.shared.running[project.id]?.kind.title.lowercased() ?? "working"). Wait, or cancel it.")
    }

    /// Notes where an export was posted, as the Publish sheet does.
    static func record(_ outcomes: [Zernio.Outcome], accounts: [Zernio.Account], export: UUID, project: UUID) {
        let names = Dictionary(accounts.map { ($0.platform, $0.handle ?? $0.name) }, uniquingKeysWith: { a, _ in a })
        Library.shared.update(project) { project in
            guard let index = project.exports.firstIndex(where: { $0.id == export }) else { return }
            project.exports[index].posts = (project.exports[index].posts ?? []) + outcomes.map {
                Publication(platform: $0.platform, account: names[$0.platform] ?? "", status: $0.status, url: $0.url)
            }
        }
    }

    // MARK: - Shapes

    static func summary(_ project: Project) -> JSONValue {
        let jobs = Jobs.shared
        var status: JSONValue = "ready"
        if let job = jobs.running[project.id] {
            status = ["step": .string(job.kind.title), "progress": job.progress.map(JSONValue.number) ?? .null, "detail": .string(job.detail)]
        } else if jobs.isBusy(project.id) {
            status = "starting"
        } else if project.media == nil || project.duration == 0 {
            status = jobs.errors[project.id] == nil ? "waiting" : "failed"
        }
        return [
            "id": .string(project.id.uuidString),
            "title": .string(project.title),
            "source": project.sourceURL.map(JSONValue.string) ?? .null,
            "channel": project.channel.map(JSONValue.string) ?? .null,
            "duration": .number(round(project.duration)),
            "transcribed": .bool(project.transcript != nil),
            "clips": .number(Double(project.clips.count)),
            "exports": .number(Double(project.exports.count)),
            "busy": .bool(jobs.isBusy(project.id)),
            "status": status,
            "error": jobs.errors[project.id].map(JSONValue.string) ?? .null,
            "created": .string(ISO8601DateFormatter().string(from: project.createdAt)),
        ]
    }

    static func detail(_ project: Project) -> JSONValue {
        guard case .object(var object) = summary(project) else { return .null }
        object["media"] = project.media.map { .string($0.path) } ?? .null
        object["language"] = project.transcript?.language.map(JSONValue.string) ?? .null
        object["transcribedWith"] = project.transcript.map { .string($0.engine) } ?? .null
        object["words"] = .number(Double(project.transcript?.words.count ?? 0))
        object["clipList"] = .array(project.clips.sorted { $0.start < $1.start }.map { info($0, in: project) })
        object["exportList"] = .array(project.exports.map { exportInfo($0, project: project) })
        object["exporting"] = .object(Dictionary(uniqueKeysWithValues: project.clips.compactMap { clip in
            Jobs.shared.exporting[clip.id].map { (clip.id.uuidString, JSONValue.number($0)) }
        }))
        return .object(object)
    }

    static func info(_ clip: Clip, in project: Project) -> JSONValue {
        let number = (project.clips.sorted { $0.start < $1.start }.firstIndex { $0.id == clip.id } ?? 0) + 1
        let text = project.transcript?.text(in: clip.range) ?? ""
        let export = project.exports.first { $0.clipID == clip.id && FileManager.default.fileExists(atPath: $0.file.path) }
        return [
            "number": .number(Double(number)),
            "id": .string(clip.id.uuidString),
            "title": .string(clip.title),
            "start": .number(round(clip.start)),
            "end": .number(round(clip.end)),
            "duration": .number(round(clip.duration)),
            "score": clip.score.map(JSONValue.number) ?? .null,
            "reasons": .array(clip.reasons.map(JSONValue.string)),
            "origin": .string(clip.origin.rawValue),
            "framing": .string(clip.framing?.rawValue ?? "default"),
            "text": .string(text.count > 600 ? String(text.prefix(600)) + "…" : text),
            "exported": export.map { .string($0.file.path) } ?? .null,
        ]
    }

    static func exportInfo(_ export: Export, project: Project) -> JSONValue {
        [
            "id": .string(export.id.uuidString),
            "clip": .string(export.clipID.uuidString),
            "project": .string(project.title),
            "projectId": .string(project.id.uuidString),
            "title": .string(export.title),
            "file": .string(export.file.path),
            "aspect": .string(export.aspect.rawValue),
            "duration": .number(round(export.duration)),
            "created": .string(ISO8601DateFormatter().string(from: export.createdAt)),
            "posts": .array((export.posts ?? []).map {
                ["platform": .string($0.platform), "status": .string($0.status), "url": $0.url.map(JSONValue.string) ?? .null]
            }),
        ]
    }

    private static func round(_ value: Double) -> Double { (value * 100).rounded() / 100 }

    private static func srt(_ sentences: [Sentence]) -> String {
        func stamp(_ t: Double) -> String {
            let ms = Int((t * 1000).rounded())
            return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
        }
        return sentences.enumerated().map { "\($0.offset + 1)\n\(stamp($0.element.start)) --> \(stamp($0.element.end))\n\($0.element.text)\n" }
            .joined(separator: "\n")
    }
}

/// A request's parameters, read leniently: numbers may come as strings, times as 1:02.5.
struct Params {
    let values: [String: JSONValue]
    init(_ values: [String: JSONValue]) { self.values = values }

    func raw(_ key: String) -> JSONValue? { values[key].flatMap { $0 == .null ? nil : $0 } }

    func string(_ key: String) -> String? {
        switch raw(key) {
        case .string(let s): s.isEmpty ? nil : s
        case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
        case .bool(let b): String(b)
        default: nil
        }
    }

    func double(_ key: String) -> Double? {
        switch raw(key) {
        case .number(let n): n
        case .string(let s): Double(s)
        default: nil
        }
    }

    func int(_ key: String) -> Int? {
        if case .number(let n) = raw(key) { return Int(n) }
        if case .string(let s) = raw(key) { return Int(s) }
        return nil
    }

    func bool(_ key: String) -> Bool? {
        switch raw(key) {
        case .bool(let b): b
        case .string(let s): ["true", "yes", "1"].contains(s.lowercased())
        case .number(let n): n != 0
        default: nil
        }
    }

    /// Seconds, from a number or "1:02:03.5".
    func seconds(_ key: String) -> Double? {
        if case .number(let n) = raw(key) { return n }
        guard let text = string(key) else { return nil }
        let parts = text.split(separator: ":").map { Double($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
        return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
    }

    func array(_ key: String) -> [String]? {
        switch raw(key) {
        case .array(let items): items.compactMap { $0.string ?? $0.int.map(String.init) }
        case .string(let s): s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        default: nil
        }
    }
}

/// The settings the `hyperclip settings` command and agents can read and change, by short name.
enum ControlSettings {
    enum Kind { case text, flag, number, choice([String]) }

    static let entries: [(name: String, key: String, kind: Kind, fallback: JSONValue)] = [
        ("engine", Pref.engine, .choice(TranscriptionEngine.allCases.map(\.rawValue)), "whisper"),
        ("language", Pref.language, .text, ""),
        ("whisperModel", Pref.whisperModel, .choice(WhisperModel.all.map(\.id)), ""),
        ("clipFinding", Pref.finder, .choice(FinderMethod.allCases.map(\.rawValue)), "heuristic"),
        ("clipCount", Pref.clipCount, .number, .number(Double(Defaults.clipCount))),
        ("minLength", Pref.minLength, .number, .number(Defaults.minLength)),
        ("maxLength", Pref.maxLength, .number, .number(Defaults.maxLength)),
        ("aspect", Pref.aspect, .choice(Aspect.allCases.map(\.rawValue)), "vertical"),
        ("framing", Pref.framing, .choice(Framing.allCases.map(\.rawValue)), "speaker"),
        ("resolution", Pref.resolution, .choice(Resolution.allCases.map(\.rawValue)), "p1080"),
        ("captions", Pref.captionStyle, .choice(CaptionStyle.Preset.allCases.map(\.rawValue)), "bold"),
        ("captionFont", Pref.captionFont, .text, .string(Defaults.captionFont)),
        ("captionSize", Pref.captionSize, .number, .number(Defaults.captionSize)),
        ("captionWords", Pref.captionWords, .number, .number(Double(Defaults.captionWords))),
        ("captionUppercase", Pref.captionUppercase, .flag, true),
        ("captionHighlight", Pref.captionHighlight, .text, .string(Defaults.captionHighlight)),
        ("captionColor", Pref.captionColor, .text, "#FFFFFF"),
        ("captionHighlightMode", Pref.captionHighlightMode, .choice(CaptionStyle.HighlightMode.allCases.map(\.rawValue)), "color"),
        ("captionWeight", Pref.captionWeight, .choice(CaptionStyle.Weight.allCases.map(\.rawValue)), "heavy"),
        ("captionOutline", Pref.captionOutline, .number, 22),
        ("captionOutlineColor", Pref.captionOutlineColor, .text, "#000000"),
        ("captionShadow", Pref.captionShadow, .flag, true),
        ("captionBackground", Pref.captionBackground, .flag, false),
        ("captionBackgroundColor", Pref.captionBackgroundColor, .text, "#000000"),
        ("captionBackgroundOpacity", Pref.captionBackgroundOpacity, .number, 0.72),
        ("captionPunctuation", Pref.captionPunctuation, .flag, false),
        ("captionAnimate", Pref.captionAnimate, .flag, true),
        ("captionPosition", Pref.captionPosition, .number, .number(Defaults.captionPosition)),
        ("autoTranscribe", Pref.autoTranscribe, .flag, true),
        ("autoFind", Pref.autoFind, .flag, true),
        ("exportFolder", Pref.exportFolder, .text, .string(Defaults.exportFolder.path)),
        ("maxHeight", Pref.maxHeight, .number, .number(Double(Defaults.maxHeight))),
        ("cookies", Pref.cookieSource, .choice(["none", "file"] + Browser.all.map(\.id)), "none"),
        ("cookieProfile", Pref.cookieProfile, .text, ""),
        ("cookieFile", Pref.cookieFile, .text, ""),
        ("llmPreset", Pref.llmPreset, .choice(LLMPreset.allCases.map(\.rawValue)), "ollama"),
        ("llmURL", Pref.llmURL, .text, ""),
        ("llmModel", Pref.llmModel, .text, ""),
        ("llmGuidance", Pref.llmGuidance, .text, ""),
        ("decisionPreset", Pref.decisionPreset, .choice(DecisionPreset.allCases.map(\.rawValue)), "typesafe"),
        ("decisionURL", Pref.decisionURL, .text, ""),
        ("decisionModel", Pref.decisionModel, .text, ""),
    ]

    static var all: JSONValue {
        let defaults = UserDefaults.standard
        return .object(Dictionary(uniqueKeysWithValues: entries.map { entry in
            guard let stored = defaults.object(forKey: entry.key) else { return (entry.name, entry.fallback) }
            let value: JSONValue = switch entry.kind {
            case .flag: .bool(defaults.bool(forKey: entry.key))
            case .number: .number(defaults.double(forKey: entry.key))
            case .text, .choice: .string(stored as? String ?? "\(stored)")
            }
            return (entry.name, value)
        }))
    }

    static func set(_ name: String, _ value: JSONValue) throws {
        guard let entry = entries.first(where: { $0.name.lowercased() == name.lowercased() }) else {
            throw ControlError("No setting \(name). Settings: \(entries.map(\.name).joined(separator: ", ")).")
        }
        let defaults = UserDefaults.standard
        let text = value.string ?? value.double.map { $0 == $0.rounded() ? String(Int($0)) : String($0) } ?? value.bool.map(String.init)
        switch entry.kind {
        case .flag:
            guard let flag = value.bool ?? text.map({ ["true", "yes", "1", "on"].contains($0.lowercased()) }) else { throw ControlError("\(entry.name) is true or false.") }
            defaults.set(flag, forKey: entry.key)
        case .number:
            guard let number = value.double ?? text.flatMap(Double.init) else { throw ControlError("\(entry.name) is a number.") }
            if entry.key == Pref.clipCount || entry.key == Pref.captionWords || entry.key == Pref.maxHeight {
                defaults.set(Int(number), forKey: entry.key)
            } else {
                defaults.set(number, forKey: entry.key)
            }
        case .choice(let options):
            guard let text, options.contains(text) else { throw ControlError("\(entry.name) is one of: \(options.joined(separator: ", ")).") }
            // A caption style is a template: it sets every caption setting.
            if entry.key == Pref.captionStyle, let preset = CaptionStyle.Preset(rawValue: text) {
                CaptionStyle.apply(preset)
            } else {
                defaults.set(text, forKey: entry.key)
            }
        case .text:
            if entry.key == Pref.captionColor || entry.key == Pref.captionHighlight || entry.key == Pref.captionOutlineColor || entry.key == Pref.captionBackgroundColor {
                guard let text, let color = NSColor(hex: text) else { throw ControlError("\(entry.name) is a color like #FFD60A.") }
                defaults.set(color.hex, forKey: entry.key)
            } else if let text, !text.isEmpty {
                defaults.set(text, forKey: entry.key)
            } else {
                defaults.removeObject(forKey: entry.key)
            }
        }
    }
}

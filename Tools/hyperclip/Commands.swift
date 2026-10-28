import Foundation

// Every `hyperclip` command. Each one is a request to the app (see `ControlMethod`); `--json` prints the app's
// answer as it is, for scripts, and `--wait` follows the work to the end with a status line on stderr.

nonisolated extension Command {
    // MARK: Videos

    static let status = Command(name: "status", arguments: "[--json]", summary: "show whether Hyperclip is running, its tools and what it's busy with") { args in
        let json = args.flag("--json")
        try args.done()
        let status = try App.call(.status)
        if json { return printJSON(status) }
        print("Hyperclip \(status["version"]?.string ?? "") · \(status["projects"]?.int ?? 0) videos")
        for (name, tool) in (status["tools"]?.object ?? [:]).sorted(by: { $0.key < $1.key }) {
            let installed = tool["installed"]?.bool == true
            print("  \(name.padding(toLength: 8, withPad: " ", startingAt: 0)) \(installed ? (tool["version"]?.string ?? "installed") : "missing")")
        }
        print("  transcription: \(status["transcription"]?.string ?? "") (\(status["whisperModel"]?.string ?? "")) · clip finding: \(status["clipFinding"]?.string ?? "") · publishing: \(status["publishing"]?.bool == true ? "on" : "no Zernio key")")
        for busy in status["busy"]?.array ?? [] {
            print("  busy: \(busy["title"]?.string ?? "") · \(describe(busy["status"]))")
        }
    }

    static let list = Command(name: "list", aliases: ["ls"], arguments: "[--json]", summary: "list your videos") { args in
        let json = args.flag("--json")
        try args.done()
        let projects = try App.call(.listProjects)
        if json { return printJSON(projects) }
        let rows = (projects.array ?? []).map { project -> [String] in
            let status = project["busy"]?.bool == true ? describe(project["status"]) : (project["error"]?.string.map { "failed: \($0)" } ?? "ready")
            return [String(project["id"]?.string?.prefix(8) ?? ""), (project["duration"]?.double ?? 0).clock, "\(project["clips"]?.int ?? 0)",
                    "\(project["exports"]?.int ?? 0)", status, project["title"]?.string ?? ""]
        }
        rows.isEmpty ? print("No videos yet. Try: hyperclip import <link>") : printTable(["ID", "LENGTH", "CLIPS", "EXPORTS", "STATUS", "TITLE"], rows)
    }

    static let show = Command(name: "show", aliases: ["info"], arguments: "<video> [--json]", summary: "show a video's details, clips and exports",
                              details: "A video is its id (or the start of it), a word of its title, or latest.") { args in
        let json = args.flag("--json")
        let project = try args.next("video")
        try args.done()
        let detail = try App.call(.getProject, ["project": .string(project)])
        if json { return printJSON(detail) }
        print(detail["title"]?.string ?? "")
        var facts = [(detail["duration"]?.double ?? 0).clock]
        if let channel = detail["channel"]?.string { facts.append(channel) }
        if let source = detail["source"]?.string { facts.append(source) }
        if let engine = detail["transcribedWith"]?.string { facts.append("\(detail["words"]?.int ?? 0) words, \(engine)") }
        print(facts.joined(separator: " · "))
        print("id \(detail["id"]?.string ?? "")")
        if detail["busy"]?.bool == true { print("busy: \(describe(detail["status"]))") }
        if let error = detail["error"]?.string { print("error: \(error)") }
        print("")
        printClips(detail)
        let exports = detail["exportList"]?.array ?? []
        if !exports.isEmpty {
            print("\nExports:")
            for export in exports { print("  \(export["file"]?.string ?? "")") }
        }
    }

    static let `import` = Command(name: "import", aliases: ["add"], arguments: "<link|file> [--from <time>] [--to <time>] [--wait] [--json]",
                                  summary: "download a video from a link, or open a file, then transcribe it and find clips",
                                  details: """
                                  Links work for YouTube, TikTok, Instagram, X, Twitch and every other site yt-dlp knows. --from and --to
                                  download only that part, as seconds or 1:02:03. Transcription and clip finding follow on their own
                                  unless they're turned off in Settings. --wait shows the progress and returns when it's all done.
                                  """) { args in
        let json = args.flag("--json"), wait = args.flag("--wait")
        let from = try args.option("--from"), to = try args.option("--to")
        let source = try args.next("link or file")
        try args.done()
        var params: [String: JSONValue] = [:]
        if source.hasPrefix("http://") || source.hasPrefix("https://") {
            params["url"] = .string(source)
        } else {
            params["path"] = .string(URL(fileURLWithPath: (source as NSString).expandingTildeInPath).standardizedFileURL.path)
        }
        if let from { params["from"] = .string(from) }
        if let to { params["to"] = .string(to) }
        let project = try App.call(.importVideo, params)
        let id = project["id"]?.string ?? "latest"
        guard wait else { return json ? printJSON(project) : print("Started \(id.prefix(8)). Follow it with: hyperclip show \(id.prefix(8))") }
        try finish(id, json: json)
    }

    static let transcribe = Command(name: "transcribe", arguments: "<video> [--engine apple|whisper|api] [--language <code>] [--wait] [--json]",
                                    summary: "transcribe a video again, then find clips if it has none") { args in
        let json = args.flag("--json"), wait = args.flag("--wait")
        var params: [String: JSONValue] = [:]
        if let engine = try args.option("--engine") { params["engine"] = .string(engine) }
        if let language = try args.option("--language") { params["language"] = .string(language) }
        params["project"] = .string(try args.next("video"))
        try args.done()
        let project = try App.call(.transcribe, params)
        guard wait else { return json ? printJSON(project) : print("Transcribing \(project["title"]?.string ?? "").") }
        try finish(project["id"]?.string ?? "latest", json: json)
    }

    static let transcript = Command(name: "transcript", arguments: "<video> [--format text|sentences|srt|words] [--from <time>] [--to <time>] [--json]",
                                    summary: "print a video's transcript, with times") { args in
        let json = args.flag("--json")
        var params: [String: JSONValue] = ["format": .string(try args.option("--format") ?? "sentences")]
        if let from = try args.option("--from") { params["from"] = .string(from) }
        if let to = try args.option("--to") { params["to"] = .string(to) }
        params["project"] = .string(try args.next("video"))
        try args.done()
        let result = try App.call(.transcript, params)
        if json { return printJSON(result) }
        if let text = result["text"]?.string ?? result["srt"]?.string { return print(text) }
        for sentence in result["sentences"]?.array ?? [] {
            print("[\((sentence["start"]?.double ?? 0).clock)] \(sentence["text"]?.string ?? "")")
        }
        for word in result["words"]?.array ?? [] {
            print("\(String(format: "%8.2f", word["start"]?.double ?? 0))  \(word["text"]?.string ?? "")")
        }
    }

    static let find = Command(name: "find", arguments: "<video> [--method heuristic|decision|llm] [--count <n>] [--min <s>] [--max <s>] [--wait] [--json]",
                              summary: "find the moments worth clipping",
                              details: "Found clips replace the ones found before; clips you made or changed stay. The method and lengths default to Settings › Clip Finding.") { args in
        let json = args.flag("--json"), wait = args.flag("--wait")
        var params: [String: JSONValue] = [:]
        if let method = try args.option("--method") { params["method"] = .string(method) }
        if let count = try args.option("--count") { params["count"] = .string(count) }
        if let min = try args.option("--min") { params["minLength"] = .string(min) }
        if let max = try args.option("--max") { params["maxLength"] = .string(max) }
        params["project"] = .string(try args.next("video"))
        try args.done()
        let project = try App.call(.findClips, params)
        guard wait else { return json ? printJSON(project) : print("Finding clips in \(project["title"]?.string ?? "").") }
        try finish(project["id"]?.string ?? "latest", json: json)
    }

    // MARK: Clips

    static let clips = Command(name: "clips", arguments: "<video> [--json]", summary: "list a video's clips, numbered in time order") { args in
        let json = args.flag("--json")
        let project = try args.next("video")
        try args.done()
        let detail = try App.call(.getProject, ["project": .string(project)])
        if json { return printJSON(detail["clipList"] ?? []) }
        printClips(detail)
    }

    static let clip = Command(name: "clip", arguments: "add <video> <start> <end> [--title <t>] | set <video> <clip> [--start] [--end] [--title] [--framing speaker|center|default] | rm <video> <clip>",
                              summary: "make, trim, rename or delete a clip",
                              details: "Times are seconds or 1:02.5. A clip is its number from `hyperclip clips` or its id.") { args in
        let json = args.flag("--json")
        let action = try args.next("add, set or rm")
        var params: [String: JSONValue] = [:]
        let result: JSONValue
        switch action {
        case "add", "new":
            if let title = try args.option("--title") { params["title"] = .string(title) }
            params["project"] = .string(try args.next("video"))
            params["start"] = .string(try args.next("start"))
            params["end"] = .string(try args.next("end"))
            try args.done()
            result = try App.call(.addClip, params)
        case "set", "edit":
            for (option, key) in [("--start", "start"), ("--end", "end"), ("--title", "title"), ("--framing", "framing")] {
                if let value = try args.option(option) { params[key] = .string(value) }
            }
            params["project"] = .string(try args.next("video"))
            params["clip"] = .string(try args.next("clip"))
            try args.done()
            result = try App.call(.updateClip, params)
        case "rm", "delete", "remove":
            params["project"] = .string(try args.next("video"))
            params["clip"] = .string(try args.next("clip"))
            try args.done()
            result = try App.call(.deleteClip, params)
            return json ? printJSON(result) : print("Deleted.")
        default:
            throw Failure("clip takes add, set or rm.")
        }
        if json { return printJSON(result) }
        print("\(result["number"]?.int ?? 0). \(result["title"]?.string ?? "")  \((result["start"]?.double ?? 0).clock)–\((result["end"]?.double ?? 0).clock)")
    }

    static let export = Command(name: "export", arguments: "<video> [<clip>…] [--best <n>] [--aspect vertical|portrait|square|original] [--captions bold|clean|boxed|pop|none] [--framing speaker|center] [--resolution p1080|p720|source] [--wait] [--json]",
                                summary: "render clips: cropped, captioned and framed on the speaker",
                                details: "With no clips named, every clip exports; --best exports the highest-scoring ones. Options left out follow Settings › Captions & Export. Files go to the export folder (~/Movies/Hyperclip).") { args in
        let json = args.flag("--json"), wait = args.flag("--wait")
        var params: [String: JSONValue] = [:]
        if let best = try args.option("--best") { params["best"] = .string(best) }
        for option in ["aspect", "captions", "framing", "resolution"] {
            if let value = try args.option("--\(option)") { params[option] = .string(value) }
        }
        let project = try args.next("video")
        params["project"] = .string(project)
        var clips: [String] = []
        while let clip = args.optionalNext() { clips.append(clip) }
        if !clips.isEmpty { params["clips"] = .array(clips.map(JSONValue.string)) }
        try args.done()
        let queued = try App.call(.export, params)
        let ids = Set(queued["queued"]?.array?.compactMap(\.string) ?? [])
        guard wait else {
            return json ? printJSON(queued) : print("Exporting \(ids.count) clip\(ids.count == 1 ? "" : "s") to \(queued["folder"]?.string ?? "").")
        }
        let line = StatusLine()
        let detail = try App.waitForExports(project, clips: ids) { progress, left in
            line.show("Exporting · \(ids.count - left + 1) of \(ids.count) · \(Int(progress * 100))%")
        }
        line.finish()
        let files = (detail["exportList"]?.array ?? []).filter { ids.contains($0["clip"]?.string ?? "") }
        if let error = detail["error"]?.string { printError(error) }
        if json { return printJSON(.array(files)) }
        files.forEach { print($0["file"]?.string ?? "") }
    }

    static let exports = Command(name: "exports", arguments: "[--json]", summary: "list exported clips, newest first") { args in
        let json = args.flag("--json")
        try args.done()
        let exports = try App.call(.listExports)
        if json { return printJSON(exports) }
        let rows = (exports.array ?? []).map { export -> [String] in
            let posted = (export["posts"]?.array ?? []).compactMap { $0["platform"]?.string }
            return [String(export["id"]?.string?.prefix(8) ?? ""), (export["duration"]?.double ?? 0).clock, export["aspect"]?.string ?? "",
                    posted.isEmpty ? "-" : Set(posted).sorted().joined(separator: ","), export["file"]?.string ?? ""]
        }
        rows.isEmpty ? print("Nothing exported yet.") : printTable(["ID", "LENGTH", "SHAPE", "POSTED", "FILE"], rows)
    }

    // MARK: Publishing

    static let publish = Command(name: "publish", aliases: ["post"],
                                 arguments: "<export|latest> --to <accounts> [--caption <text>] [--title <t>] [--at <ISO 8601>] [--visibility public|unlisted|private] [--tiktok-privacy <level>] [--tiktok-consent] [--json]",
                                 summary: "post an exported clip through Zernio, now or at a set time",
                                 details: """
                                 --to takes platforms (youtube, tiktok, x, linkedin, instagram, …) or Zernio account ids, separated by commas;
                                 see `hyperclip accounts`. Posting to TikTok needs --tiktok-consent: the creator agrees to TikTok's Music Usage
                                 Confirmation. Needs a Zernio API key in Settings › Publishing.
                                 """) { args in
        let json = args.flag("--json"), consent = args.flag("--tiktok-consent")
        guard let to = try args.option("--to") else { throw Failure("say where to post with --to, like --to youtube,tiktok. See hyperclip accounts.") }
        var params: [String: JSONValue] = ["accounts": .array(to.split(separator: ",").map { .string(String($0)) }), "tiktokConsent": .bool(consent)]
        for (option, key) in [("--caption", "caption"), ("--title", "title"), ("--at", "at"), ("--visibility", "visibility"), ("--tiktok-privacy", "tiktokPrivacy")] {
            if let value = try args.option(option) { params[key] = .string(value) }
        }
        params["export"] = .string(args.optionalNext() ?? "latest")
        try args.done()
        let line = StatusLine()
        line.show("Uploading and posting…")
        let outcomes = try App.call(.publish, params, timeout: 1800)
        line.finish()
        if json { return printJSON(outcomes) }
        for outcome in outcomes.array ?? [] {
            var text = "\(outcome["platform"]?.string ?? ""): \(outcome["status"]?.string ?? "")"
            if let url = outcome["url"]?.string { text += " \(url)" }
            if let error = outcome["error"]?.string { text += " (\(error))" }
            print(text)
        }
    }

    static let accounts = Command(name: "accounts", arguments: "[--json]", summary: "list the social accounts connected in Zernio") { args in
        let json = args.flag("--json")
        try args.done()
        let accounts = try App.call(.accounts)
        if json { return printJSON(accounts) }
        let rows = (accounts.array ?? []).map { account in
            [account["platform"]?.string ?? "", account["username"]?.string ?? account["displayName"]?.string ?? "",
             account["usable"]?.bool == false ? "reconnect in Zernio" : "ok", account["id"]?.string ?? ""]
        }
        rows.isEmpty ? print("No accounts. Connect some at https://zernio.com/dashboard") : printTable(["PLATFORM", "ACCOUNT", "STATE", "ID"], rows)
    }

    // MARK: Setup

    static let settings = Command(name: "settings", aliases: ["config"], arguments: "[get [<name>] | set <name> <value>] [--json]",
                                  summary: "read or change settings: transcription engine, clip finding, captions, shape…") { args in
        let json = args.flag("--json")
        let action = args.optionalNext() ?? "get"
        switch action {
        case "set":
            let name = try args.next("setting"), value = try args.next("value")
            try args.done()
            let settings = try App.call(.setSetting, ["key": .string(name), "value": .string(value)])
            json ? printJSON(settings) : print("\(name) = \(settings[name].map(display) ?? value)")
        case "get":
            let name = args.optionalNext()
            try args.done()
            let settings = try App.call(.getSettings)
            if let name {
                guard let value = settings[name] else { throw Failure("no setting \(name). Run hyperclip settings to see them.") }
                return json ? printJSON(value) : print(display(value))
            }
            if json { return printJSON(settings) }
            printTable(["SETTING", "VALUE"], (settings.object ?? [:]).sorted { $0.key < $1.key }.map { [$0.key, display($0.value)] })
        default:
            throw Failure("settings takes get or set.")
        }
    }

    static let models = Command(name: "models", arguments: "[download <id> [--wait]] [--json]", summary: "list Whisper and Liquid models, or download one") { args in
        let json = args.flag("--json"), wait = args.flag("--wait")
        if args.optionalNext() == "download" {
            let id = try args.next("model")
            try args.done()
            let result = try App.call(.downloadModel, ["model": .string(id)])
            guard wait, result["installed"]?.bool != true else { return json ? printJSON(result) : print("Downloading \(id).") }
            let line = StatusLine()
            while true {
                let model = (try App.call(.listModels).array ?? []).first { $0["id"]?.string == id }
                if model?["installed"]?.bool == true || model?["downloading"] == nil || model?["downloading"] == .null { break }
                line.show("Downloading \(id) · \(Int((model?["downloading"]?.double ?? 0) * 100))%")
                usleep(500_000)
            }
            line.finish()
            return print("Downloaded \(id).")
        }
        try args.done()
        let models = try App.call(.listModels)
        if json { return printJSON(models) }
        printTable(["MODEL", "KIND", "SIZE", "STATE"], (models.array ?? []).map { model in
            let state = model["selected"]?.bool == true ? "in use" : model["installed"]?.bool == true ? "installed"
                : model["downloading"]?.double.map { "downloading \(Int($0 * 100))%" } ?? "-"
            return [model["id"]?.string ?? "", model["kind"]?.string ?? "whisper", ByteCountFormatter.string(fromByteCount: Int64(model["size"]?.double ?? 0), countStyle: .file), state]
        })
    }

    static let cancel = Command(name: "cancel", aliases: ["stop"], arguments: "<video>", summary: "stop what a video is busy with") { args in
        let project = try args.next("video")
        try args.done()
        try App.call(.cancel, ["project": .string(project)])
        print("Stopped.")
    }

    static let delete = Command(name: "delete", aliases: ["rm"], arguments: "<video>", summary: "remove a video and what it downloaded; exports stay") { args in
        let project = try args.next("video")
        try args.done()
        try App.call(.deleteProject, ["project": .string(project)])
        print("Deleted.")
    }

    static let open = Command(name: "open", arguments: "[<video> [<clip>]]", summary: "bring Hyperclip forward, on a video and clip") { args in
        var params: [String: JSONValue] = [:]
        if let project = args.optionalNext() { params["project"] = .string(project) }
        if let clip = args.optionalNext() { params["clip"] = .string(clip) }
        try args.done()
        try App.call(.show, params)
    }

    static let api = Command(name: "api", arguments: "<method> [<json params>]", summary: "send any control request and print the answer",
                             details: "Methods: \(ControlMethod.allCases.map(\.rawValue).joined(separator: ", ")).\nExample: hyperclip api getProject '{\"project\": \"latest\"}'") { args in
        let name = try args.next("method")
        guard let method = ControlMethod(rawValue: name) else { throw Failure("no method \(name). Methods: \(ControlMethod.allCases.map(\.rawValue).joined(separator: ", ")).") }
        var params: [String: JSONValue] = [:]
        if let text = args.optionalNext() {
            guard let object = (try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)))?.object else { throw Failure("params must be a JSON object.") }
            params = object
        }
        try args.done()
        printJSON(try App.call(method, params, timeout: 1800))
    }

    static let mcp = Command(name: "mcp", summary: "run the MCP server for AI agents, on stdin and stdout",
                             details: "Add it to an agent from Settings › Agents, or by hand: command hyperclip, args [\"mcp\"].") { args in
        try args.done()
        MCP.serve()
    }
}

// MARK: - Helpers

/// Follows a project to the end of its work, then prints its clips.
nonisolated private func finish(_ id: String, json: Bool) throws {
    let line = StatusLine()
    let detail = try App.waitUntilIdle(id) { line.show(describe($0["status"])) }
    line.finish()
    if let error = detail["error"]?.string { throw Failure(error) }
    if json { return printJSON(detail) }
    print(detail["title"]?.string ?? "")
    printClips(detail)
}

nonisolated private func printClips(_ detail: JSONValue) {
    let clips = detail["clipList"]?.array ?? []
    guard !clips.isEmpty else {
        return print(detail["transcribed"]?.bool == true ? "No clips yet. Try: hyperclip find \(detail["id"]?.string?.prefix(8) ?? "latest")" : "No transcript yet.")
    }
    printTable(["#", "SCORE", "TIME", "LENGTH", "TITLE"], clips.map { clip in
        ["\(clip["number"]?.int ?? 0)", clip["score"]?.double.map { String(Int($0)) } ?? "you",
         "\((clip["start"]?.double ?? 0).clock)–\((clip["end"]?.double ?? 0).clock)", "\(Int(clip["duration"]?.double ?? 0))s", clip["title"]?.string ?? ""]
    })
}

nonisolated private func display(_ value: JSONValue) -> String {
    switch value {
    case .string(let s): s.isEmpty ? "(default)" : s
    case .number(let n): n == n.rounded() ? String(Int(n)) : String(n)
    case .bool(let b): String(b)
    default: value.pretty
    }
}

import Foundation

// `hyperclip mcp`: a Model Context Protocol server on stdin and stdout, so AI agents (Claude Code, Codex,
// Cursor, …) can turn videos into clips. It speaks JSON-RPC 2.0, one message per line, and drives the app
// through its control socket, so the app does the work and shows it as it happens.
//
// It's dual-era: legacy clients open with `initialize` (2025-11-25 and earlier), modern ones (2026-07-28)
// send their version in every request's `_meta` and may probe with `server/discover`.

nonisolated enum MCP {
    static let modernVersion = "2026-07-28"
    static let legacyVersions = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    static let versionKey = "io.modelcontextprotocol/protocolVersion"

    static let instructions = """
    Hyperclip turns long videos into short, captioned vertical clips on this Mac. The usual flow: import_video \
    with a link (YouTube, TikTok, X, Twitch… anything yt-dlp downloads) or a file path; it downloads, transcribes \
    and finds clips, and waits until that's done. Then list_clips to see them with scores and what's said, \
    get_transcript to read the video and pick moments yourself, add_clip or update_clip to cut or trim by \
    timestamps, and export_clips to render them (9:16, captions, framed on the speaker). publish posts an export \
    through Zernio to YouTube, TikTok, X, LinkedIn and more. A video is its id, a word of its title, or "latest"; \
    a clip is its number from list_clips or its id. Times are seconds. Everything shows in the Hyperclip window as \
    it happens.
    """

    /// Reads requests until stdin closes. Each request runs on its own thread, so a long command doesn't
    /// hold up the rest; replies go out whole, one per line.
    static func serve() -> Never {
        setvbuf(stdout, nil, _IOFBF, 1 << 16)
        let session = Session()
        let group = DispatchGroup()
        while let line = readLine(strippingNewline: true) {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(line.utf8)) else {
                session.send(error: -32700, message: "Parse error: send one JSON-RPC message per line.", id: .null)
                continue
            }
            // A batch, from clients of 2025-03-26.
            let messages = message.array ?? [message]
            for message in messages {
                group.enter()
                DispatchQueue.global().async {
                    session.handle(message)
                    group.leave()
                }
            }
        }
        group.wait()
        exit(0)
    }

    final class Session: @unchecked Sendable {
        private let lock = NSLock()

        func handle(_ message: JSONValue) {
            guard let method = message["method"]?.string else { return } // A response to us; we never ask.
            let id = message["id"]
            let params = message["params"] ?? .object([:])
            // Notifications (initialized, cancelled, …) need no answer.
            guard let id else { return }
            let requested = params["_meta"]?[MCP.versionKey]?.string
            let modern = requested != nil
            if let requested, requested != MCP.modernVersion, !MCP.legacyVersions.contains(requested) {
                send(error: -32022, message: "Unsupported protocol version", id: id,
                     data: ["supported": .array(([MCP.modernVersion] + MCP.legacyVersions).map { .string($0) }), "requested": .string(requested)])
                return
            }
            do {
                var result: [String: JSONValue]
                switch method {
                case "initialize":
                    let asked = params["protocolVersion"]?.string ?? ""
                    result = [
                        "protocolVersion": .string(MCP.legacyVersions.contains(asked) ? asked : MCP.legacyVersions[0]),
                        "capabilities": ["tools": ["listChanged": false]],
                        "serverInfo": serverInfo,
                        "instructions": .string(MCP.instructions),
                    ]
                case "server/discover":
                    result = [
                        "supportedVersions": .array(([MCP.modernVersion] + MCP.legacyVersions).map { .string($0) }),
                        "capabilities": ["tools": [:]],
                        "instructions": .string(MCP.instructions),
                        "ttlMs": 3_600_000, "cacheScope": "public",
                    ]
                case "ping":
                    result = [:]
                case "tools/list":
                    result = ["tools": .array(Tools.all.map(\.definition))]
                    if modern { result["ttlMs"] = 3_600_000; result["cacheScope"] = "public" }
                case "tools/call":
                    guard let name = params["name"]?.string else { throw RPCError(-32602, "tools/call needs a tool name.") }
                    guard let tool = Tools.all.first(where: { $0.name == name }) else {
                        throw RPCError(-32602, "Unknown tool \(name). Call tools/list to see them.")
                    }
                    let arguments = params["arguments"] ?? .object([:])
                    do {
                        result = ["content": .array(try tool.run(arguments, self).map(\.json)), "isError": false]
                    } catch {
                        // Tool failures go back to the model as results, so it can read them and adjust.
                        result = ["content": [["type": "text", "text": .string(error.localizedDescription)]], "isError": true]
                    }
                default:
                    throw RPCError(-32601, "Method not found: \(method)")
                }
                if modern {
                    result["resultType"] = "complete"
                    result["_meta"] = ["io.modelcontextprotocol/serverInfo": serverInfo]
                }
                send(["jsonrpc": "2.0", "id": id, "result": .object(result)])
            } catch let error as RPCError {
                send(error: error.code, message: error.message, id: id)
            } catch {
                send(error: -32603, message: error.localizedDescription, id: id)
            }
        }

        func send(error code: Int, message: String, id: JSONValue, data: JSONValue? = nil) {
            var error: [String: JSONValue] = ["code": .number(Double(code)), "message": .string(message)]
            if let data { error["data"] = data }
            send(["jsonrpc": "2.0", "id": id, "error": .object(error)])
        }

        private func send(_ message: JSONValue) {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.withoutEscapingSlashes]
            guard var data = try? encoder.encode(message) else { return }
            data.append(0x0A)
            lock.withLock {
                FileHandle.standardOutput.write(data)
            }
        }

        private var serverInfo: JSONValue {
            ["name": "hyperclip", "title": "Hyperclip", "version": .string(App.version)]
        }
    }

    struct RPCError: Error {
        let code: Int
        let message: String
        init(_ code: Int, _ message: String) { self.code = code; self.message = message }
    }
}

// MARK: - Tool results

nonisolated enum Content {
    case text(String)
    case png(Data)

    var json: JSONValue {
        switch self {
        case .text(let text): ["type": "text", "text": .string(text)]
        case .png(let data): ["type": "image", "data": .string(data.base64EncodedString()), "mimeType": "image/png"]
        }
    }
}

nonisolated struct ToolFailure: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

// MARK: - Tools

nonisolated struct Tool: Sendable {
    let name: String
    let title: String
    let description: String
    /// JSON Schema properties, and which are required.
    let properties: [String: JSONValue]
    let required: [String]
    let readOnly: Bool
    let destructive: Bool
    let run: @Sendable (JSONValue, MCP.Session) throws -> [Content]

    var definition: JSONValue {
        [
            "name": .string(name), "title": .string(title), "description": .string(description),
            "inputSchema": ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) })],
            "annotations": ["title": .string(title), "readOnlyHint": .bool(readOnly), "destructiveHint": .bool(destructive), "openWorldHint": .bool(name == "import_video" || name == "publish")],
        ]
    }

    /// A tool that's one control request: its arguments, renamed where needed, become the request's params.
    static func request(_ name: String, _ title: String, _ description: String, method: ControlMethod, properties: [String: JSONValue] = [:],
                        required: [String] = [], readOnly: Bool = false, destructive: Bool = false,
                        rename: [String: String] = [:], timeout: TimeInterval = 120) -> Tool {
        Tool(name: name, title: title, description: description, properties: properties, required: required, readOnly: readOnly, destructive: destructive) { args, _ in
            [.text(try App.call(method, params(args, rename: rename), timeout: timeout).pretty)]
        }
    }

    static func params(_ args: JSONValue, rename: [String: String] = [:]) -> [String: JSONValue] {
        var params: [String: JSONValue] = [:]
        for (key, value) in args.object ?? [:] where key != "wait" { params[rename[key] ?? key] = value }
        return params
    }
}

nonisolated enum Tools {
    private static let project: JSONValue = ["type": "string", "description": "The video: its id (or the start of it), a word of its title, or \"latest\"."]
    private static let clip: JSONValue = ["type": "string", "description": "The clip's number from list_clips (1 is the earliest) or its id."]
    private static let seconds: JSONValue = ["type": "number", "description": "Seconds from the start of the video."]
    private static let wait: JSONValue = ["type": "boolean", "description": "Wait until the work is done (up to 15 minutes) and return the result. Default true."]

    /// After work that runs in the background: waits, then answers with the project as it ended up.
    private static func settle(_ project: String, _ args: JSONValue) throws -> [Content] {
        guard args["wait"]?.bool != false else {
            return [.text("Started. Call get_project with \"\(project)\" to follow it.\n" + (try App.call(.getProject, ["project": .string(project)])).pretty)]
        }
        let detail = try App.waitUntilIdle(project, limit: 900)
        if let error = detail["error"]?.string, detail["busy"]?.bool != true { throw ToolFailure(error) }
        let note = detail["busy"]?.bool == true ? "Still working (\(describe(detail["status"]))). Call get_project again in a while.\n" : ""
        return [.text(note + summarize(detail))]
    }

    /// The project with its clips, short enough for a model to read whole.
    private static func summarize(_ detail: JSONValue) -> String {
        var object = detail.object ?? [:]
        object["exportList"] = nil
        return JSONValue.object(object).pretty
    }

    static let all: [Tool] = [
        .request("status", "Status", "Whether Hyperclip's tools are installed (yt-dlp, FFmpeg, whisper.cpp), the transcription engine and clip finding method in use, whether publishing is set up, and what's busy.",
                 method: .status, readOnly: true),

        .request("list_projects", "List Videos", "Every video in Hyperclip, newest first: id, title, length, number of clips and exports, and whether it's busy.",
                 method: .listProjects, readOnly: true),

        .request("get_project", "Get Video", "A video's details: source, transcript language, status and progress, every clip (number, start and end in seconds, score, title, what's said) and every export (file paths).",
                 method: .getProject, properties: ["project": project], required: ["project"], readOnly: true),

        Tool(name: "import_video", title: "Import Video",
             description: "Downloads a video from a link (YouTube, TikTok, Instagram, X, Twitch, podcasts… anything yt-dlp supports) or opens a local file, then transcribes it and finds clips. Waits until that's done by default and returns the clips. from/to download only that part of a long video.",
             properties: [
                "url": ["type": "string", "description": "A link to the video."],
                "path": ["type": "string", "description": "Or an absolute path to a video file on this Mac."],
                "from": seconds, "to": seconds, "wait": wait,
             ], required: [], readOnly: false, destructive: false) { args, _ in
            let project = try App.call(.importVideo, Tool.params(args))
            return try settle(project["id"]?.string ?? "latest", args)
        },

        Tool(name: "transcribe", title: "Transcribe",
             description: "Transcribes a video again, with word timings: engine apple (built in, fast), whisper (most accurate, detects the language) or api. Finds clips afterwards if the video has none.",
             properties: [
                "project": project,
                "engine": ["type": "string", "enum": ["apple", "whisper", "api"]],
                "language": ["type": "string", "description": "A language code like en or fr. Leave out to use the setting (Whisper detects it)."],
                "wait": wait,
             ], required: ["project"], readOnly: false, destructive: false) { args, _ in
            let project = try App.call(.transcribe, Tool.params(args))
            return try settle(project["id"]?.string ?? "latest", args)
        },

        .request("get_transcript", "Get Transcript",
                 "What's said in a video, with times in seconds. format sentences (default: numbered sentences with start and end), text, srt, or words (each word timed, for exact cuts). from/to limit it to a stretch.",
                 method: .transcript,
                 properties: ["project": project, "format": ["type": "string", "enum": ["sentences", "text", "srt", "words"]], "from": seconds, "to": seconds],
                 required: ["project"], readOnly: true),

        Tool(name: "find_clips", title: "Find Clips",
             description: "Finds the moments worth posting and replaces earlier finds (clips made or edited by hand stay). method heuristic scores hooks, payoffs, pace and energy with no AI; decision asks a Jev-compatible decision model; llm asks a language model. Leave options out to use the app's settings.",
             properties: [
                "project": project,
                "method": ["type": "string", "enum": ["heuristic", "decision", "llm"]],
                "count": ["type": "integer", "description": "How many clips, at most."],
                "minLength": ["type": "number", "description": "Shortest clip, in seconds."],
                "maxLength": ["type": "number", "description": "Longest clip, in seconds."],
                "wait": wait,
             ], required: ["project"], readOnly: false, destructive: false) { args, _ in
            let project = try App.call(.findClips, Tool.params(args))
            return try settle(project["id"]?.string ?? "latest", args)
        },

        Tool(name: "list_clips", title: "List Clips",
             description: "A video's clips in time order: number, id, start, end and duration in seconds, score (0–100, for found clips), why it scored, title, the words said, and the exported file if there is one.",
             properties: ["project": project], required: ["project"], readOnly: true, destructive: false) { args, _ in
            let detail = try App.call(.getProject, Tool.params(args))
            return [.text((detail["clipList"] ?? []).pretty)]
        },

        .request("add_clip", "Add Clip", "Makes a clip from start to end (seconds). Start it on the first word of a sentence and end it just after a sentence ends; get_transcript with format words gives exact times. The title defaults to its opening words.",
                 method: .addClip, properties: ["project": project, "start": seconds, "end": seconds, "title": ["type": "string"]],
                 required: ["project", "start", "end"]),

        .request("update_clip", "Update Clip", "Trims, retitles or reframes a clip. framing speaker follows the speaker's face, center crops the middle, default uses the setting.",
                 method: .updateClip,
                 properties: ["project": project, "clip": clip, "start": seconds, "end": seconds, "title": ["type": "string"],
                              "framing": ["type": "string", "enum": ["speaker", "center", "default"]]],
                 required: ["project", "clip"]),

        .request("delete_clip", "Delete Clip", "Deletes a clip. Its exports stay.", method: .deleteClip,
                 properties: ["project": project, "clip": clip], required: ["project", "clip"], destructive: true),

        Tool(name: "export_clips", title: "Export Clips",
             description: "Renders clips to MP4: cropped to the shape, framed on the speaker, captions burned in word by word. Pick clips by number or id, or best for the top N by score; neither exports them all. Options left out use the app's settings. Waits and returns the file paths by default.",
             properties: [
                "project": project,
                "clips": ["type": "array", "items": ["type": "string"], "description": "Clip numbers or ids."],
                "best": ["type": "integer", "description": "Export the N highest-scoring clips instead."],
                "aspect": ["type": "string", "enum": ["vertical", "portrait", "square", "original"], "description": "vertical is 9:16, portrait 4:5, square 1:1."],
                "captions": ["type": "string", "enum": ["bold", "clean", "boxed", "pop", "none"]],
                "framing": ["type": "string", "enum": ["speaker", "center"]],
                "resolution": ["type": "string", "enum": ["p1080", "p720", "source"]],
                "wait": wait,
             ], required: ["project"], readOnly: false, destructive: false) { args, _ in
            let queued = try App.call(.export, Tool.params(args))
            let ids = Set(queued["queued"]?.array?.compactMap(\.string) ?? [])
            let project = args["project"]?.string ?? "latest"
            guard args["wait"]?.bool != false else { return [.text("Exporting \(ids.count) clips to \(queued["folder"]?.string ?? "the export folder"). Call get_project to follow.")] }
            let detail = try App.waitForExports(project, clips: ids, limit: 900)
            let files = (detail["exportList"]?.array ?? []).filter { ids.contains($0["clip"]?.string ?? "") }
            if files.isEmpty, let error = detail["error"]?.string { throw ToolFailure(error) }
            return [.text(JSONValue.array(files).pretty)]
        },

        .request("list_exports", "List Exports", "Every exported clip, newest first, with its file path, shape, length and where it's been posted.",
                 method: .listExports, readOnly: true),

        .request("list_accounts", "List Social Accounts", "The social accounts connected in Zernio that publish can post to: platform, username and id.",
                 method: .accounts, readOnly: true),

        .request("publish", "Publish", "Posts an exported clip through Zernio, now or at a time. accounts are platform names (youtube, tiktok, x, linkedin, instagram, facebook, threads, bluesky…) or account ids from list_accounts. Posting to TikTok needs tiktokConsent true, which confirms the creator agreed to TikTok's Music Usage Confirmation; only set it when they have. Ask the user before publishing.",
                 method: .publish,
                 properties: [
                    "export": ["type": "string", "description": "The export's id from list_exports, or \"latest\"."],
                    "accounts": ["type": "array", "items": ["type": "string"]],
                    "caption": ["type": "string"],
                    "title": ["type": "string", "description": "The YouTube title."],
                    "at": ["type": "string", "description": "When to post, ISO 8601 with a time zone. Leave out to post now."],
                    "visibility": ["type": "string", "enum": ["public", "unlisted", "private"], "description": "YouTube visibility."],
                    "tiktokPrivacy": ["type": "string", "enum": ["PUBLIC_TO_EVERYONE", "MUTUAL_FOLLOW_FRIENDS", "FOLLOWER_OF_CREATOR", "SELF_ONLY"]],
                    "tiktokConsent": ["type": "boolean"],
                 ], required: ["export", "accounts", "caption"], timeout: 1800),

        .request("get_settings", "Get Settings", "Hyperclip's settings: transcription engine and language, Whisper model, clip finding method and lengths, export shape, framing, resolution and caption style.",
                 method: .getSettings, readOnly: true),

        .request("set_setting", "Change Setting", "Changes one setting by name (see get_settings), like captions to clean or engine to apple.",
                 method: .setSetting, properties: ["key": ["type": "string"], "value": ["type": ["string", "number", "boolean"]]], required: ["key", "value"]),

        .request("list_models", "List Whisper Models", "Whisper models: which are downloaded, which is in use, and downloads in progress.", method: .listModels, readOnly: true),

        .request("download_model", "Download Whisper Model", "Starts downloading a Whisper model by id, like large-v3-turbo-q5_0. Call list_models to follow it.",
                 method: .downloadModel, properties: ["model": ["type": "string"]], required: ["model"]),

        .request("cancel", "Cancel", "Stops what a video is busy with: downloading, transcribing or finding clips.", method: .cancel,
                 properties: ["project": project], required: ["project"]),

        .request("show", "Show in Hyperclip", "Brings the Hyperclip window forward, on a video and clip if given, for the user to look at.", method: .show,
                 properties: ["project": project, "clip": clip]),
    ]
}

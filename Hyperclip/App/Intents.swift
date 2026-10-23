import AppIntents
import Foundation

// Shortcuts actions: the same control methods the `hyperclip` command uses, so a shortcut can take a link from the
// share sheet, clip it, and hand the best clips to the next action.

struct ClipVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Clip a Video"
    static let description = IntentDescription("Downloads a video from a link, transcribes it and finds the moments worth posting.")

    @Parameter(title: "Link") var link: URL

    static var parameterSummary: some ParameterSummary { Summary("Clip \(\.$link)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let project = try await ControlAPI.handle(ControlRequest(method: "importVideo", params: ["url": .string(link.absoluteString)]))
        let id = project["id"]?.string ?? "latest"
        try await IntentWaiting.untilIdle(id)
        let detail = try await ControlAPI.handle(ControlRequest(method: "getProject", params: ["project": .string(id)]))
        if let error = detail["error"]?.string { throw ControlError(error) }
        let titles = detail["clipList"]?.array?.compactMap { $0["title"]?.string } ?? []
        let summary = "\(detail["title"]?.string ?? "The video"): \(titles.count) clips"
        return .result(value: ([summary] + titles.map { "• \($0)" }).joined(separator: "\n"), dialog: IntentDialog(stringLiteral: summary))
    }
}

struct ExportBestClipsIntent: AppIntent {
    static let title: LocalizedStringResource = "Export the Best Clips"
    static let description = IntentDescription("Exports a video's highest-scoring clips with your caption and shape settings, and returns the files.")

    @Parameter(title: "Video", description: "A word of its title, or latest.", default: "latest") var video: String
    @Parameter(title: "How many", default: 3) var count: Int

    static var parameterSummary: some ParameterSummary { Summary("Export the best \(\.$count) clips of \(\.$video)") }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let queued = try await ControlAPI.handle(ControlRequest(method: "export", params: ["project": .string(video), "best": .number(Double(count))]))
        let clips = Set(queued["queued"]?.array?.compactMap(\.string) ?? [])
        while await MainActor.run(body: { Jobs.shared.exporting.keys.contains { clips.contains($0.uuidString) } }) {
            try await Task.sleep(for: .milliseconds(500))
        }
        let exports = try await ControlAPI.handle(ControlRequest(method: "listExports"))
        let files = (exports.array ?? []).filter { clips.contains($0["clip"]?.string ?? "") }.compactMap { $0["file"]?.string }
        return .result(value: files.map { IntentFile(fileURL: URL(fileURLWithPath: $0)) })
    }
}

struct ListClipsIntent: AppIntent {
    static let title: LocalizedStringResource = "Get Clips"
    static let description = IntentDescription("Lists a video's clips with their times and scores.")

    @Parameter(title: "Video", description: "A word of its title, or latest.", default: "latest") var video: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let detail = try await ControlAPI.handle(ControlRequest(method: "getProject", params: ["project": .string(video)]))
        let lines = (detail["clipList"]?.array ?? []).map { clip -> String in
            let score = clip["score"]?.int.map { " (\($0))" } ?? ""
            return "\(clip["number"]?.int ?? 0). \(clip["title"]?.string ?? "")\(score) \((clip["start"]?.double ?? 0).clock)–\((clip["end"]?.double ?? 0).clock)"
        }
        return .result(value: lines.joined(separator: "\n"))
    }
}

nonisolated struct HyperclipShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ClipVideoIntent(), phrases: ["Clip a video with \(.applicationName)"], shortTitle: "Clip a Video", systemImageName: "scissors")
        AppShortcut(intent: ExportBestClipsIntent(), phrases: ["Export the best clips with \(.applicationName)"], shortTitle: "Export Best Clips",
                    systemImageName: "square.and.arrow.up")
        AppShortcut(intent: ListClipsIntent(), phrases: ["Get clips from \(.applicationName)"], shortTitle: "Get Clips", systemImageName: "list.bullet")
    }
}

nonisolated enum IntentWaiting {
    /// Waits while a project downloads, transcribes and finds clips.
    static func untilIdle(_ project: String) async throws {
        try await Task.sleep(for: .milliseconds(300))
        while try await ControlAPI.handle(ControlRequest(method: "getProject", params: ["project": .string(project)]))["busy"]?.bool == true {
            try await Task.sleep(for: .seconds(1))
        }
    }
}

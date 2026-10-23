import Foundation

/// Every user preference, by its UserDefaults key, so views can share one `@AppStorage` spelling.
nonisolated enum Pref {
    // General
    static let exportFolder = "general.exportFolder"
    static let autoTranscribe = "general.autoTranscribe"
    static let autoFind = "general.autoFind"

    // Downloads
    static let ytdlpPath = "download.ytdlpPath"
    static let ffmpegPath = "download.ffmpegPath"
    static let maxHeight = "download.maxHeight"
    static let cookieSource = "download.cookieSource"
    static let cookieProfile = "download.cookieProfile"
    static let cookieFile = "download.cookieFile"
    static let extraArguments = "download.extraArguments"
    static let rateLimit = "download.rateLimit"

    // Transcription
    static let engine = "transcribe.engine"
    static let language = "transcribe.language"
    static let whisperModel = "transcribe.whisperModel"
    static let whisperPath = "transcribe.whisperPath"
    static let whisperThreads = "transcribe.whisperThreads"
    static let transcriptionURL = "transcribe.apiURL"
    static let transcriptionModel = "transcribe.apiModel"

    // Clip finding
    static let finder = "find.method"
    static let clipCount = "find.count"
    static let minLength = "find.minLength"
    static let maxLength = "find.maxLength"
    static let decisionPreset = "find.decision.preset"
    static let decisionURL = "find.decision.url"
    static let decisionPath = "find.decision.path"
    static let decisionModel = "find.decision.model"
    static let llmPreset = "find.llm.preset"
    static let llmURL = "find.llm.url"
    static let llmModel = "find.llm.model"
    static let llmGuidance = "find.llm.guidance"

    // Export and captions
    static let aspect = "export.aspect"
    static let framing = "export.framing"
    static let resolution = "export.resolution"
    static let captionStyle = "captions.style"
    static let captionFont = "captions.font"
    static let captionSize = "captions.size"
    static let captionWords = "captions.words"
    static let captionUppercase = "captions.uppercase"
    static let captionHighlight = "captions.highlight"
    static let captionPosition = "captions.position"
}

nonisolated enum Defaults {
    static let maxHeight = 1080
    static let clipCount = 8
    static let minLength = 20.0
    static let maxLength = 60.0
    static let captionFont = "Helvetica Neue"
    static let captionSize = 92.0
    static let captionWords = 3
    static let captionPosition = 0.72
    static let captionHighlight = "#FFD60A"

    static var exportFolder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0].appending(path: "Hyperclip", directoryHint: .isDirectory)
    }
}

/// Reads preferences outside of views, with the same defaults the views show.
nonisolated enum Prefs {
    private static var store: UserDefaults { .standard }

    static func string(_ key: String) -> String? {
        store.string(forKey: key).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    static func bool(_ key: String, default value: Bool) -> Bool {
        store.object(forKey: key) == nil ? value : store.bool(forKey: key)
    }

    static func double(_ key: String, default value: Double) -> Double {
        store.object(forKey: key) == nil ? value : store.double(forKey: key)
    }

    static func int(_ key: String, default value: Int) -> Int {
        store.object(forKey: key) == nil ? value : store.integer(forKey: key)
    }

    static func value<T: RawRepresentable>(_ key: String, default value: T) -> T where T.RawValue == String {
        store.string(forKey: key).flatMap(T.init(rawValue:)) ?? value
    }

    static var exportFolder: URL {
        string(Pref.exportFolder).map { URL(fileURLWithPath: $0, isDirectory: true) } ?? Defaults.exportFolder
    }

    static var language: String? { string(Pref.language) }

    static var clipLengths: ClosedRange<Double> {
        let low = double(Pref.minLength, default: Defaults.minLength)
        let high = double(Pref.maxLength, default: Defaults.maxLength)
        return min(low, high)...max(low, high, low + 5)
    }
}

/// The shape of an exported clip.
nonisolated enum Aspect: String, CaseIterable, Identifiable, Codable, Sendable {
    case vertical, portrait, square, original

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vertical: "9:16"
        case .portrait: "4:5"
        case .square: "1:1"
        case .original: "Original"
        }
    }

    var name: String {
        switch self {
        case .vertical: "Vertical (9:16)"
        case .portrait: "Portrait (4:5)"
        case .square: "Square (1:1)"
        case .original: "Original"
        }
    }

    var icon: String {
        switch self {
        case .vertical: "rectangle.portrait"
        case .portrait: "rectangle.portrait"
        case .square: "square"
        case .original: "rectangle"
        }
    }

    /// Width over height, or nil to keep the source's.
    var ratio: Double? {
        switch self {
        case .vertical: 9.0 / 16
        case .portrait: 4.0 / 5
        case .square: 1
        case .original: nil
        }
    }
}

/// Where a cropped clip looks.
nonisolated enum Framing: String, CaseIterable, Identifiable, Codable, Sendable {
    case speaker, center

    var id: String { rawValue }
    var label: String { self == .speaker ? "Follow the speaker" : "Center" }
}

/// How tall an export is, before cropping to its aspect.
nonisolated enum Resolution: String, CaseIterable, Identifiable, Sendable {
    case p1080, p720, source

    var id: String { rawValue }
    var label: String {
        switch self {
        case .p1080: "1080p"
        case .p720: "720p"
        case .source: "Same as the video"
        }
    }

    /// The short side of the export, or nil for the source's own pixels.
    var shortSide: Double? {
        switch self {
        case .p1080: 1080
        case .p720: 720
        case .source: nil
        }
    }
}

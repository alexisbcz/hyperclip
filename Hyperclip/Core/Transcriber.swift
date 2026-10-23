import AVFoundation
import Foundation
import Speech

/// Who writes the transcript.
nonisolated enum TranscriptionEngine: String, CaseIterable, Identifiable, Sendable {
    case apple, whisper, api

    var id: String { rawValue }

    var name: String {
        switch self {
        case .apple: "Apple"
        case .whisper: "Whisper"
        case .api: "API"
        }
    }

    var title: String {
        switch self {
        case .apple: "Apple on-device"
        case .whisper: "Whisper (whisper.cpp)"
        case .api: "OpenAI-compatible API"
        }
    }

    var summary: String {
        switch self {
        case .apple: "Built into macOS: fast and private, nothing to install. Set the language in Settings, since it can't detect it."
        case .whisper: "OpenAI's open Whisper models, run on this Mac's GPU by whisper.cpp. Detects the language and handles accents and jargon best."
        case .api: "Any server with an /audio/transcriptions endpoint and word timestamps: OpenAI, Groq, a local Speaches or Hypervoice server."
        }
    }

    var icon: String {
        switch self {
        case .apple: "apple.logo"
        case .whisper: "waveform.badge.mic"
        case .api: "network"
        }
    }

    static var current: TranscriptionEngine { Prefs.value(Pref.engine, default: .whisper) }
}

nonisolated enum Transcriber {
    enum Failure: LocalizedError {
        case noModel, unsupportedLanguage(String), noWords, badResponse(String)

        var errorDescription: String? {
            switch self {
            case .noModel: "Download a Whisper model first, under Models."
            case .unsupportedLanguage(let language): "Apple's transcriber doesn't support \(language). Pick another language or use Whisper."
            case .noWords: "No speech was found in this video."
            case .badResponse(let detail): "The transcription server answered with something unexpected: \(detail)"
            }
        }
    }

    /// Transcribes 16 kHz mono WAV into timed words. `progress` goes from 0 to 1.
    static func transcribe(_ wav: URL, duration: Double, engine: TranscriptionEngine, language: String?,
                           progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let transcript: Transcript
        switch engine {
        case .apple: transcript = try await apple(wav, duration: duration, language: language, progress: progress)
        case .whisper: transcript = try await whisper(wav, language: language, progress: progress)
        case .api: transcript = try await api(wav, language: language)
        }
        guard !transcript.words.isEmpty else { throw Failure.noWords }
        return transcript
    }

    // MARK: Apple

    private static func apple(_ wav: URL, duration: Double, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let wanted = Locale(identifier: language ?? Locale.current.identifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) else {
            throw Failure.unsupportedLanguage(Locale.current.localizedString(forIdentifier: wanted.identifier) ?? wanted.identifier)
        }
        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let file = try AVAudioFile(forReading: wav)

        let collect = Task {
            var words: [Word] = []
            for try await result in transcriber.results {
                var joins = false
                for run in result.text.runs {
                    let piece = String(result.text[run.range].characters)
                    let trimmed = piece.trimmingCharacters(in: .whitespacesAndNewlines)
                    // Spaces come as runs of their own, often without times; they end the word before.
                    guard let range = run.audioTimeRange, !trimmed.isEmpty else {
                        if piece.last?.isWhitespace == true { joins = false }
                        continue
                    }
                    // Runs can be pieces of a word: one with no space before it joins the word before it.
                    if joins, piece.first?.isWhitespace == false, !words.isEmpty {
                        words[words.count - 1].text += trimmed
                        words[words.count - 1].end = range.end.seconds
                    } else {
                        words.append(Word(text: trimmed, start: range.start.seconds, end: range.end.seconds))
                    }
                    joins = piece.last?.isWhitespace == false
                }
                if duration > 0 { progress(min(1, result.range.end.seconds / duration)) }
            }
            return words
        }
        try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
        let words = try await collect.value
        return Transcript(words: words, language: locale.language.languageCode?.identifier, engine: "Apple")
    }

    // MARK: whisper.cpp

    private static func whisper(_ wav: URL, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> Transcript {
        let cli = try Tools.require(.whisper)
        guard let model = WhisperModel.selectedFile else { throw Failure.noModel }
        let base = wav.deletingPathExtension().appendingPathExtension("whisper")
        let threads = Prefs.int(Pref.whisperThreads, default: 0)
        var arguments = ["-m", model.path, "-f", wav.path, "-oj", "-ml", "1", "-sow", "-pp", "-of", base.path,
                         "-l", language ?? "auto"]
        if threads > 0 { arguments += ["-t", String(threads)] }
        try await Shell.run(cli, arguments) { line in
            guard let range = line.range(of: "progress = ") else { return }
            let number = line[range.upperBound...].trimmingCharacters(in: CharacterSet(charactersIn: "% "))
            if let value = Double(number) { progress(value / 100) }
        }
        let json = base.appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: json) }
        let output = try JSONDecoder().decode(WhisperOutput.self, from: Data(contentsOf: json))
        var words: [Word] = []
        for segment in output.transcription {
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !(text.hasPrefix("[") && text.hasSuffix("]")) else { continue }
            let start = Double(segment.offsets.from) / 1000, end = Double(segment.offsets.to) / 1000
            // Punctuation can come out as its own segment; it belongs to the word before.
            if text.allSatisfy({ $0.isPunctuation }), !words.isEmpty {
                words[words.count - 1].text += text
                continue
            }
            words.append(Word(text: text, start: start, end: max(end, start + 0.05)))
        }
        return Transcript(words: words, language: output.result?.language, engine: "Whisper · \(WhisperModel.selected.name)")
    }

    private struct WhisperOutput: Decodable {
        struct Segment: Decodable {
            struct Offsets: Decodable { var from: Int; var to: Int }
            var offsets: Offsets
            var text: String
        }
        struct Result: Decodable { var language: String? }
        var transcription: [Segment]
        var result: Result?
    }

    // MARK: OpenAI-compatible

    private static func api(_ wav: URL, language: String?) async throws -> Transcript {
        let defaults = UserDefaults.standard
        let base = (defaults.string(forKey: Pref.transcriptionURL) ?? "").trimmingCharacters(in: .whitespaces)
        let model = (defaults.string(forKey: Pref.transcriptionModel) ?? "").trimmingCharacters(in: .whitespaces)
        guard let url = URL(string: (base.isEmpty ? "https://api.openai.com/v1" : base).trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/audio/transcriptions") else {
            throw Failure.badResponse("the server address isn't a URL")
        }
        let boundary = "hyperclip-\(UUID().uuidString)"
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model.isEmpty ? "whisper-1" : model)
        field("response_format", "verbose_json")
        field("timestamp_granularities[]", "word")
        field("timestamp_granularities[]", "segment")
        if let language { field("language", language) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8))
        body.append(try Data(contentsOf: wav))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: url, timeoutInterval: 1800)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if let key = Secret.transcription.value { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Failure.badResponse("HTTP \(status): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        let decoded = try JSONDecoder().decode(APIOutput.self, from: data)
        var words = (decoded.words ?? []).map { Word(text: $0.word.trimmingCharacters(in: .whitespaces), start: $0.start, end: $0.end) }
        if words.isEmpty {
            // Without word timings, spread each segment's words evenly across it.
            for segment in decoded.segments ?? [] {
                let pieces = segment.text.split(whereSeparator: \.isWhitespace)
                let step = (segment.end - segment.start) / Double(max(1, pieces.count))
                for (index, piece) in pieces.enumerated() {
                    words.append(Word(text: String(piece), start: segment.start + Double(index) * step, end: segment.start + Double(index + 1) * step))
                }
            }
        } else if let text = decoded.text {
            words = punctuate(words, from: text)
        }
        return Transcript(words: words, language: decoded.language, engine: "API · \(model.isEmpty ? "whisper-1" : model)")
    }

    private struct APIOutput: Decodable {
        struct Timed: Decodable { var word: String; var start: Double; var end: Double }
        struct Segment: Decodable { var text: String; var start: Double; var end: Double }
        var text: String?
        var language: String?
        var words: [Timed]?
        var segments: [Segment]?
    }

    /// OpenAI's word timestamps leave out punctuation; this takes it back from the full text, word by word.
    private static func punctuate(_ words: [Word], from text: String) -> [Word] {
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        var result = words
        var cursor = 0
        for index in result.indices {
            let bare = result[index].text.lowercased().filter { $0.isLetter || $0.isNumber }
            var look = cursor
            while look < min(tokens.count, cursor + 4) {
                if tokens[look].lowercased().filter({ $0.isLetter || $0.isNumber }) == bare {
                    result[index].text = tokens[look]
                    cursor = look + 1
                    break
                }
                look += 1
            }
        }
        return result
    }
}

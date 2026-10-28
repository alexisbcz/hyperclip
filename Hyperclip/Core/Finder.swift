import Foundation

/// How Hyperclip picks the moments worth clipping.
nonisolated enum FinderMethod: String, CaseIterable, Identifiable, Sendable {
    case heuristic, decision, llm

    var id: String { rawValue }

    var name: String {
        switch self {
        case .heuristic: "Built-in"
        case .decision: "Decision model"
        case .llm: "Language model"
        }
    }

    var title: String {
        switch self {
        case .heuristic: "Built-in, no AI"
        case .decision: "Decision model (Jev-compatible)"
        case .llm: "Language model (OpenAI-compatible)"
        }
    }

    var summary: String {
        switch self {
        case .heuristic: "Scores every span of whole sentences on its hook, its payoff, the pace and energy of the delivery and its length. Instant, offline, free."
        case .decision: "Shortlists with the built-in scores, then asks a decision model typed questions about each one: how strong the hook is, whether it stands alone, how good the payoff is. Runs Liquid's d1 on this Mac, which can also hear the delivery, or works with TypeSafe's Jev and the open models that speak its API, like Laya, Von or Kev."
        case .llm: "Reads the whole transcript and picks moments like an editor would, with titles. Runs Liquid's LFM3 on this Mac, or works with Ollama, LM Studio or any OpenAI-compatible API."
        }
    }

    var icon: String {
        switch self {
        case .heuristic: "gauge.with.dots.needle.67percent"
        case .decision: "checklist"
        case .llm: "sparkles"
        }
    }

    static var current: FinderMethod { Prefs.value(Pref.finder, default: .heuristic) }
}

/// A server for decision models: state and typed questions in, probabilities out.
nonisolated enum DecisionPreset: String, CaseIterable, Identifiable, Sendable {
    case typesafe, liquid, local, anyjev, custom

    var id: String { rawValue }

    var name: String {
        switch self {
        case .typesafe: "TypeSafe Jev"
        case .liquid: "Liquid d1, on this Mac"
        case .local: "Self-hosted (Laya, Von, Kev…)"
        case .anyjev: "AnyJev"
        case .custom: "Custom"
        }
    }

    var url: String {
        switch self {
        case .typesafe: "https://api.typesafe.ai"
        case .local, .anyjev, .custom: "http://localhost:8000"
        case .liquid: ""
        }
    }

    var path: String { self == .anyjev ? "/v1/decide" : "/v1/systemone" }
    var model: String { self == .typesafe ? "jev-latest" : "" }
    var needsKey: Bool { self == .typesafe }
}

/// A server for chat models that speaks OpenAI's API.
nonisolated enum LLMPreset: String, CaseIterable, Identifiable, Sendable {
    case liquid, ollama, lmstudio, openai, openrouter, custom

    var id: String { rawValue }

    var name: String {
        switch self {
        case .liquid: "Liquid LFM3, on this Mac"
        case .ollama: "Ollama"
        case .lmstudio: "LM Studio"
        case .openai: "OpenAI"
        case .openrouter: "OpenRouter"
        case .custom: "Custom"
        }
    }

    var url: String {
        switch self {
        case .ollama: "http://localhost:11434/v1"
        case .lmstudio: "http://localhost:1234/v1"
        case .openai: "https://api.openai.com/v1"
        case .openrouter: "https://openrouter.ai/api/v1"
        case .liquid, .custom: ""
        }
    }

    var model: String {
        switch self {
        case .ollama: "qwen3:8b"
        case .lmstudio: ""
        case .openai: "gpt-5-mini"
        case .openrouter: "qwen/qwen3-235b-a22b"
        case .liquid: LiquidModel.language.id
        case .custom: ""
        }
    }

    var isLocal: Bool { self == .ollama || self == .lmstudio || self == .liquid }
}

/// Finds the moments of a video worth posting on their own.
nonisolated enum Finder {
    struct Settings: Sendable {
        var method: FinderMethod
        var count: Int
        var lengths: ClosedRange<Double>

        static var current: Settings {
            Settings(method: .current, count: Prefs.int(Pref.clipCount, default: Defaults.clipCount), lengths: Prefs.clipLengths)
        }
    }

    enum Failure: LocalizedError {
        case tooShort, server(String), unreadable(String)

        var errorDescription: String? {
            switch self {
            case .tooShort: "The video is shorter than the shortest clip. Lower the minimum length in Settings › Clip Finding."
            case .server(let detail): detail
            case .unreadable(let detail): "Couldn't make sense of the model's answer: \(detail)"
            }
        }
    }

    static func find(in project: Project, settings: Settings = .current, progress: @escaping @Sendable (Double, String) -> Void) async throws -> [Clip] {
        guard let transcript = project.transcript else { return [] }
        let sentences = transcript.sentences()
        var candidates = Heuristic.candidates(sentences, lengths: settings.lengths)
        if candidates.isEmpty, let first = sentences.first, let last = sentences.last {
            // A video shorter than the shortest clip is one clip.
            guard last.end - first.start <= settings.lengths.upperBound else { throw Failure.tooShort }
            candidates = [Heuristic.Candidate(first: 0, last: sentences.count - 1, start: first.start, end: last.end,
                                              text: sentences.map(\.text).joined(separator: " "), opening: first.text, closing: last.text)]
        }
        guard !candidates.isEmpty else { throw Failure.tooShort }
        let scored = Heuristic.score(candidates, transcript: transcript, loudness: project.loudness ?? [], lengths: settings.lengths)

        switch settings.method {
        case .heuristic:
            progress(1, "Scoring")
            return pick(scored, count: settings.count)
        case .decision:
            let shortlist = pick(scored, count: max(settings.count * 3, 12), overlap: 0.6)
            let excerpts = Dictionary(uniqueKeysWithValues: shortlist.map { ($0.id, transcript.text(in: $0.range)) })
            let rescored = try await Decision.rescore(shortlist, excerpts: excerpts, title: project.title, media: project.media, progress: progress)
            return pick(rescored, count: settings.count)
        case .llm:
            let picked = try await LLM.pick(sentences: sentences, title: project.title, settings: settings, progress: progress)
            return pick(picked, count: settings.count)
        }
    }

    /// The best clips that don't overlap much, best first.
    static func pick(_ clips: [Clip], count: Int, overlap allowed: Double = 0.2) -> [Clip] {
        var chosen: [Clip] = []
        for clip in clips.sorted(by: { ($0.score ?? 0) > ($1.score ?? 0) }) {
            let clashes = chosen.contains { other in
                let shared = min(clip.end, other.end) - max(clip.start, other.start)
                return shared > allowed * min(clip.duration, other.duration)
            }
            if !clashes { chosen.append(clip) }
            if chosen.count == count { break }
        }
        return chosen
    }

    /// A title from the clip's first sentence.
    static func title(from text: String) -> String {
        var title = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.count > 64 {
            let cut = title.prefix(64)
            title = (cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)) + "…"
        }
        while let last = title.last, ".,;:".contains(last) { title.removeLast() }
        return title.prefix(1).uppercased() + title.dropFirst()
    }
}

// MARK: - Built-in

/// Scores spans of whole sentences with signals that tend to make shorts work, no model needed.
nonisolated enum Heuristic {
    struct Candidate: Sendable {
        var first: Int
        var last: Int
        var start: Double
        var end: Double
        var text: String
        var opening: String
        var closing: String
    }

    static func candidates(_ sentences: [Sentence], lengths: ClosedRange<Double>) -> [Candidate] {
        var candidates: [Candidate] = []
        for first in sentences.indices {
            var last = first
            while last < sentences.count {
                let duration = sentences[last].end - sentences[first].start
                if duration > lengths.upperBound { break }
                if duration >= lengths.lowerBound {
                    let span = sentences[first...last]
                    candidates.append(Candidate(first: first, last: last, start: sentences[first].start, end: sentences[last].end,
                                                text: span.map(\.text).joined(separator: " "), opening: sentences[first].text,
                                                closing: sentences[last].text))
                }
                last += 1
            }
        }
        return candidates
    }

    /// Words that tend to open or close a good short, in English and French.
    static let strongWords: Set<String> = [
        "secret", "secrets", "mistake", "mistakes", "never", "always", "nobody", "everyone", "truth", "why", "how", "best", "worst",
        "crazy", "insane", "money", "million", "millions", "billion", "free", "stop", "biggest", "wrong", "actually", "honestly",
        "problem", "lesson", "learned", "realized", "changed", "shocking", "surprising", "simple", "hard", "fail", "failed",
        "jamais", "toujours", "personne", "vérité", "pourquoi", "comment", "erreur", "erreurs", "argent", "million", "fou", "folie",
        "gratuit", "problème", "leçon", "appris", "compris", "changé", "meilleur", "pire", "vraiment", "simple",
    ]

    static let youWords: Set<String> = ["you", "your", "you're", "yourself", "vous", "votre", "vos", "tu", "ton", "ta", "tes", "toi"]

    /// Words that lean on what came before, so a clip starting with one feels cut off.
    static let leaningWords: Set<String> = ["and", "but", "so", "because", "which", "then", "also", "or", "et", "mais", "donc", "car", "puis", "alors", "ou"]

    static func score(_ candidates: [Candidate], transcript: Transcript, loudness: [Float], lengths: ClosedRange<Double>) -> [Clip] {
        let meanLoudness = loudness.isEmpty ? 0 : loudness.reduce(0, +) / Float(loudness.count)
        let variance = loudness.isEmpty ? 0 : loudness.reduce(0) { $0 + ($1 - meanLoudness) * ($1 - meanLoudness) } / Float(loudness.count)
        let spread = max(0.02, sqrt(variance))
        let middle = (lengths.lowerBound + lengths.upperBound) / 2

        var raw: [(Candidate, Double, [String])] = candidates.map { candidate in
            var reasons: [String] = []
            let duration = max(1, candidate.end - candidate.start)
            let openingWords = tokens(candidate.opening)

            var hook = 0.0
            if candidate.opening.contains("?") { hook += 0.35; reasons.append("Opens with a question") }
            if candidate.opening.contains(where: \.isNumber) { hook += 0.15 }
            if openingWords.contains(where: youWords.contains) { hook += 0.15 }
            let strong = openingWords.filter(strongWords.contains).count
            hook += min(0.45, Double(strong) * 0.15)
            if openingWords.count <= 14 { hook += 0.1 }
            if let first = openingWords.first, leaningWords.contains(first) { hook -= 0.45 }
            hook = min(1, max(0, hook))
            if hook >= 0.45, !reasons.contains("Opens with a question") { reasons.append("Strong opening line") }

            let closingWords = tokens(candidate.closing)
            var payoff = 0.0
            if candidate.closing.contains("!") { payoff += 0.25 }
            payoff += min(0.5, Double(closingWords.filter(strongWords.contains).count) * 0.2)
            if let last = candidate.closing.last, ".!?…".contains(last) { payoff += 0.25 }
            payoff = min(1, payoff)
            if payoff >= 0.5 { reasons.append("Lands on a strong line") }

            let words = transcript.words(in: candidate.start...candidate.end)
            let pace = Double(words.count) / duration
            let density = min(1, max(0, (pace - 1.6) / 1.4))
            if pace > 2.8 { reasons.append("Fast-paced") }

            var longestPause = 0.0
            for (previous, next) in zip(words, words.dropFirst()) { longestPause = max(longestPause, next.start - previous.end) }
            let pausePenalty = longestPause > 2.5 ? min(0.3, (longestPause - 2.5) * 0.1) : 0

            var energy = 0.5
            if !loudness.isEmpty {
                let from = Int(candidate.start * Project.loudnessRate), to = min(loudness.count, Int(candidate.end * Project.loudnessRate))
                if from < to {
                    let slice = loudness[from..<to]
                    let mean = slice.reduce(0, +) / Float(slice.count)
                    energy = Double(min(1, max(0, 0.5 + (mean - meanLoudness) / (spread * 3))))
                    if energy > 0.68 { reasons.append("Lively delivery") }
                }
            }

            let fit = 1 - min(1, abs(duration - middle) / max(1, lengths.upperBound - lengths.lowerBound))
            var total = 0.32 * hook + 0.2 * payoff + 0.15 * density + 0.2 * energy + 0.13 * fit - pausePenalty
            // Opening on "and" or "so" sounds cut off, whatever else the clip has going for it.
            if let first = openingWords.first, leaningWords.contains(first) { total *= 0.75 }
            return (candidate, total, reasons)
        }

        // Spread scores over 35–98, so the list reads as a ranking.
        let values = raw.map(\.1)
        let low = values.min() ?? 0, high = values.max() ?? 1
        raw = raw.map { ($0.0, 35 + 63 * ($0.1 - low) / max(0.0001, high - low), $0.2) }
        return raw.map { candidate, score, reasons in
            Clip(start: max(0, candidate.start - 0.15), end: candidate.end + 0.35, title: Finder.title(from: candidate.opening),
                 origin: .found, score: score.rounded(), reasons: reasons)
        }
    }

    static func tokens(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && $0 != "'" && $0 != "’" }.map(String.init)
    }
}

// MARK: - Decision models

/// Rescoring with a decision model, through the System One API: a state, typed questions, probabilities back.
nonisolated enum Decision {
    struct Config: Sendable {
        var url: URL
        var model: String
        var key: String?
        /// Whether the model hears each clip's sound as well as reading its words.
        var hearsAudio = false

        static var current: Config? {
            let preset = Prefs.value(Pref.decisionPreset, default: DecisionPreset.typesafe)
            let base = Prefs.string(Pref.decisionURL) ?? preset.url
            let path = Prefs.string(Pref.decisionPath) ?? preset.path
            guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + (path.hasPrefix("/") ? path : "/" + path)) else { return nil }
            return Config(url: url, model: Prefs.string(Pref.decisionModel) ?? preset.model, key: Secret.decision.value)
        }

        /// Liquid's d1 when it's the one chosen, run by Hyperclip's own llama-server.
        static var local: LiquidModel? {
            Prefs.value(Pref.decisionPreset, default: DecisionPreset.typesafe) == .liquid ? LiquidModel.decision : nil
        }
    }

    /// The server to ask, starting Hyperclip's own when the model runs on this Mac. Pair with `disconnect`.
    private static func connect(progress: @escaping @Sendable (Double, String) -> Void) async throws -> Config {
        if let model = Config.local {
            let base = try await LlamaServer.shared.begin(model, progress: progress)
            return Config(url: base.appending(path: "v1/systemone"), model: model.id, hearsAudio: model.hearsAudio)
        }
        guard let config = Config.current else { throw Finder.Failure.server("The decision model's address isn't a URL.") }
        return config
    }

    private static func disconnect() async {
        if Config.local != nil { await LlamaServer.shared.end() }
    }

    nonisolated(unsafe) static let questions: [String: Any] = [
        "hook": [
            "type": "score",
            "instructions": "How well do the opening lines of this excerpt hook someone scrolling through short videos?",
            "criteria": [
                "Dull or confusing opening",
                "Mildly interesting opening",
                "Clear, intriguing opening",
                "Irresistible opening: a bold claim, a question or a tension the viewer has to see resolved",
            ],
        ],
        "standalone": [
            "type": "noul",
            "instructions": "Does this excerpt make complete sense on its own, without the rest of the video?",
        ],
        "payoff": [
            "type": "score",
            "instructions": "How satisfying is what the excerpt delivers: an insight, a punchline, a surprising fact, a strong opinion or an emotional moment?",
            "criteria": ["Nothing in particular", "A small point", "A clear, satisfying point", "A memorable payoff people will repeat"],
        ],
        "shareable": [
            "type": "noul",
            "instructions": "Would many viewers like, comment on or share this excerpt as a short video?",
        ],
    ]

    /// Asked as well when the model hears the clip.
    nonisolated(unsafe) static let delivery: [String: Any] = [
        "type": "score",
        "instructions": "How lively and engaging is the speaker's delivery in the recording: energy, pace, emotion?",
        "criteria": ["Flat or mumbled", "Calm and clear", "Engaged", "Energetic, gripping delivery"],
    ]

    /// The longest stretch of sound sent with a clip; its opening matters most, and longer passages lose accuracy.
    static let listening = 100.0

    static func rescore(_ clips: [Clip], excerpts: [UUID: String], title: String, media: URL?,
                        progress: @escaping @Sendable (Double, String) -> Void) async throws -> [Clip] {
        let config = try await connect(progress: progress)
        do {
            let results = try await rescore(clips, excerpts: excerpts, title: title, media: config.hearsAudio ? media : nil, config: config, progress: progress)
            await disconnect()
            return results
        } catch {
            await disconnect()
            throw error
        }
    }

    private static func rescore(_ clips: [Clip], excerpts: [UUID: String], title: String, media: URL?, config: Config,
                                progress: @escaping @Sendable (Double, String) -> Void) async throws -> [Clip] {
        var done = 0
        var results: [Clip] = []
        let asking = "Asking \(config.model.isEmpty ? "the decision model" : config.model)" + (media == nil ? "" : ", listening to each clip")
        progress(0, asking)
        try await withThrowingTaskGroup(of: Clip.self) { group in
            var iterator = clips.makeIterator()
            func next() -> Bool {
                guard let clip = iterator.next() else { return false }
                group.addTask { try await ask(config, about: clip, excerpt: excerpts[clip.id] ?? clip.title, title: title, media: media) }
                return true
            }
            for _ in 0..<4 where next() {}
            while let clip = try await group.next() {
                results.append(clip)
                done += 1
                progress(Double(done) / Double(clips.count), asking)
                _ = next()
            }
        }
        return results
    }

    private static func ask(_ config: Config, about clip: Clip, excerpt: String, title: String, media: URL?) async throws -> Clip {
        var body: [String: Any] = [
            "state": ["video_title": title, "excerpt": excerpt, "duration_seconds": Int(clip.duration)],
            "questions": questions,
        ]
        if let media {
            let sound = try await Media.audioClip(media, range: clip.start...min(clip.end, clip.start + listening))
            body["files"] = ["data:audio/wav;base64," + sound.base64EncodedString()]
            body["questions"] = questions.merging(["delivery": delivery]) { $1 }
        }
        if !config.model.isEmpty { body["model"] = config.model }
        let answers = try await post(config, body: body)
        let hook = level(answers, "hook") ?? 0.5
        let standalone = yes(answers, "standalone") ?? 0.5
        let payoff = level(answers, "payoff") ?? 0.5
        let shareable = yes(answers, "shareable") ?? 0.5
        var clip = clip
        var reasons: [String] = []
        if let delivery = level(answers, "delivery") {
            clip.score = (100 * (0.3 * hook + 0.15 * standalone + 0.25 * payoff + 0.1 * shareable + 0.2 * delivery)).rounded()
            if delivery > 0.6 { reasons.append("Lively delivery") } else if delivery < 0.35 { reasons.append("Flat delivery") }
        } else {
            clip.score = (100 * (0.35 * hook + 0.2 * standalone + 0.3 * payoff + 0.15 * shareable)).rounded()
        }
        if hook > 0.6 { reasons.insert("Strong hook", at: 0) }
        if standalone > 0.7 { reasons.append("Stands on its own") } else if standalone < 0.35 { reasons.append("Needs context") }
        if payoff > 0.6 { reasons.append("Memorable payoff") }
        if shareable > 0.6 { reasons.append("Likely to be shared") }
        clip.reasons = reasons.isEmpty ? ["Middling on every question"] : reasons
        return clip
    }

    /// A score question's answer from 0 to 1: the expected level when the server gives each level's probability,
    /// which separates clips better than the median level alone.
    static func level(_ answers: [String: Any], _ id: String) -> Double? {
        guard let answer = answers[id] as? [String: Any] else { return nil }
        if let probabilities = answer["probabilities"] as? [String: Any], probabilities.count > 1 {
            let pairs = probabilities.compactMap { key, value in Int(key).flatMap { level in (value as? NSNumber).map { (Double(level), $0.doubleValue) } } }
            if pairs.count == probabilities.count {
                let total = pairs.reduce(0) { $0 + $1.1 }
                if total > 0 { return pairs.reduce(0) { $0 + $1.0 * $1.1 } / total / Double(pairs.count - 1) }
            }
        }
        let levels = (answer["legend"] as? [String: Any])?.count ?? 4
        return ((answer["score"] as? NSNumber)?.doubleValue).map { $0 / Double(max(1, levels - 1)) }
    }

    /// A yes/no question's answer: the probability of yes.
    static func yes(_ answers: [String: Any], _ id: String) -> Double? {
        ((answers[id] as? [String: Any])?["noul"] as? NSNumber)?.doubleValue
    }

    private static func post(_ config: Config, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: config.url, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw Finder.Failure.server("\(config.url.host() ?? "The server") answered HTTP \(status): \(String(decoding: data.prefix(240), as: UTF8.self))")
        }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any], let answers = json["answers"] as? [String: Any] else {
            throw Finder.Failure.unreadable(String(decoding: data.prefix(240), as: UTF8.self))
        }
        return answers
    }

    /// One small request, to check the address, model and key in Settings.
    static func test() async throws -> String {
        let config = try await connect { _, _ in }
        defer { Task { await disconnect() } }
        var body: [String: Any] = [
            "state": "I can't believe nobody told me this before: you can save a third on groceries by doing one thing.",
            "questions": ["hook": questions["hook"]!],
        ]
        if !config.model.isEmpty { body["model"] = config.model }
        let answers = try await post(config, body: body)
        let score = level(answers, "hook").map { $0 * 3 }
        return score.map { "Connected. A sample hook scored \(String(format: "%.2f", $0)) out of 3." } ?? "Connected."
    }
}

// MARK: - Language models

/// Picking clips with a chat model that reads the numbered transcript.
nonisolated enum LLM {
    struct Config: Sendable {
        var url: URL
        var model: String
        var key: String?
        var isLocal: Bool
        /// Liquid's LFM3, run by Hyperclip's own llama-server.
        var isLiquid = false

        static var current: Config? {
            let preset = Prefs.value(Pref.llmPreset, default: LLMPreset.ollama)
            let base = Prefs.string(Pref.llmURL) ?? preset.url
            guard let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else { return nil }
            return Config(url: url, model: Prefs.string(Pref.llmModel) ?? preset.model, key: Secret.llm.value,
                          isLocal: url.host() == "localhost" || url.host() == "127.0.0.1")
        }

        static var isLiquid: Bool { Prefs.value(Pref.llmPreset, default: LLMPreset.ollama) == .liquid }
    }

    /// The server to ask, starting Hyperclip's own for LFM3. Pair with `disconnect`.
    private static func connect(progress: @escaping @Sendable (Double, String) -> Void) async throws -> Config {
        if Config.isLiquid {
            let model = LiquidModel.language
            let base = try await LlamaServer.shared.begin(model, progress: progress)
            return Config(url: base.appending(path: "v1/chat/completions"), model: model.id, isLocal: true, isLiquid: true)
        }
        guard let config = Config.current else { throw Finder.Failure.server("The language model's address isn't a URL.") }
        return config
    }

    private static func disconnect() async {
        if Config.isLiquid { await LlamaServer.shared.end() }
    }

    static func pick(sentences: [Sentence], title: String, settings: Finder.Settings,
                     progress: @escaping @Sendable (Double, String) -> Void) async throws -> [Clip] {
        let config = try await connect(progress: progress)
        do {
            let clips = try await pick(sentences: sentences, title: title, settings: settings, config: config, progress: progress)
            await disconnect()
            return clips
        } catch {
            await disconnect()
            throw error
        }
    }

    private static func pick(sentences: [Sentence], title: String, settings: Finder.Settings, config: Config,
                             progress: @escaping @Sendable (Double, String) -> Void) async throws -> [Clip] {
        let lines = sentences.map { "[\($0.index)] \($0.start.clock) \($0.text)" }
        // Local models often run with small contexts, so they read the transcript in smaller pieces.
        // LFM3 gets 128K tokens of it, so hours of transcript fit in one piece.
        let budget = config.isLiquid ? 400_000 : config.isLocal ? 7_000 : 60_000
        var chunks: [[String]] = [[]]
        var size = 0
        for line in lines {
            if size + line.count > budget, !chunks[chunks.count - 1].isEmpty {
                chunks.append([])
                size = 0
            }
            chunks[chunks.count - 1].append(line)
            size += line.count + 1
        }

        var clips: [Clip] = []
        let perChunk = max(2, Int((Double(settings.count) * 1.5 / Double(chunks.count)).rounded(.up)))
        for (index, chunk) in chunks.enumerated() {
            progress(Double(index) / Double(chunks.count), "Reading part \(index + 1) of \(chunks.count) with \(config.model.isEmpty ? "the model" : config.model)")
            let reply = try await complete(config, prompt: prompt(chunk, title: title, count: perChunk, lengths: settings.lengths))
            clips += try parse(reply, sentences: sentences, lengths: settings.lengths)
        }
        progress(1, "Done")
        return clips
    }

    private static func prompt(_ lines: [String], title: String, count: Int, lengths: ClosedRange<Double>) -> String {
        let guidance = Prefs.string(Pref.llmGuidance).map { "\nWhat the creator is looking for: \($0)\n" } ?? ""
        return """
        You are a top short-form video editor. Below is part of the transcript of a video titled "\(title)", one sentence per line: \
        its number in brackets, when it starts, then what is said.

        Pick up to \(count) moments that would work as standalone vertical short videos (TikTok, Reels, Shorts), each between \
        \(Int(lengths.lowerBound)) and \(Int(lengths.upperBound)) seconds long. A good moment opens with a hook in its first \
        sentence (a bold claim, a question, a surprising fact, tension), makes sense without the rest of the video, and ends \
        on a payoff: an insight, a punchline or a strong line. Never start on a sentence that depends on the one before it.
        \(guidance)
        Reply with JSON only, in this shape:
        {"clips": [{"first": <number of the first sentence>, "last": <number of the last sentence>, "title": "<a catchy title \
        under 60 characters, in the video's language>", "score": <0-100, how well it would perform>, "reason": "<why, in a few words>"}]}

        Transcript:
        \(lines.joined(separator: "\n"))
        """
    }

    private static func complete(_ config: Config, prompt: String, json: Bool = true) async throws -> String {
        var request = URLRequest(url: config.url, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let key = config.key { request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        var body: [String: Any] = [
            "model": config.model,
            "temperature": 0.4,
            "messages": [["role": "user", "content": prompt]],
        ]
        if config.isLiquid {
            // Liquid's recommended sampling for LFM3. Its reasoning runs to thousands of tokens on a long transcript
            // and picks no better clips, so it answers straight away.
            body["temperature"] = 0.1
            body["top_k"] = 50
            body["repeat_penalty"] = 1.1
            body["chat_template_kwargs"] = ["enable_thinking": false]
        }
        if json { body["response_format"] = ["type": "json_object"] }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 400, json, String(decoding: data, as: UTF8.self).contains("response_format") {
            return try await complete(config, prompt: prompt, json: false)
        }
        guard status == 200 else {
            throw Finder.Failure.server("\(config.url.host() ?? "The server") answered HTTP \(status): \(String(decoding: data.prefix(240), as: UTF8.self))")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = (object["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any],
              let content = message["content"] as? String
        else { throw Finder.Failure.unreadable(String(decoding: data.prefix(240), as: UTF8.self)) }
        return content
    }

    private static func parse(_ reply: String, sentences: [Sentence], lengths: ClosedRange<Double>) throws -> [Clip] {
        var text = reply
        // Reasoning models think out loud first.
        if let end = text.range(of: "</think>") { text = String(text[end.upperBound...]) }
        guard let open = text.firstIndex(of: "{"), let close = text.lastIndex(of: "}") else {
            throw Finder.Failure.unreadable(String(reply.prefix(200)))
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text[open...close].utf8)) as? [String: Any],
              let items = object["clips"] as? [[String: Any]]
        else { throw Finder.Failure.unreadable(String(reply.prefix(200))) }

        return items.compactMap { item in
            guard let first = (item["first"] as? NSNumber)?.intValue, var last = (item["last"] as? NSNumber)?.intValue,
                  sentences.indices.contains(first) else { return nil }
            last = min(max(first, last), sentences.count - 1)
            // Models misjudge lengths; trim from the end to fit, and drop what's far too short.
            while last > first, sentences[last].end - sentences[first].start > lengths.upperBound * 1.15 { last -= 1 }
            let start = sentences[first].start, end = sentences[last].end
            guard end - start >= lengths.lowerBound * 0.6 else { return nil }
            let title = (item["title"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }
            let reason = (item["reason"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }
            return Clip(start: max(0, start - 0.15), end: end + 0.35, title: title.flatMap { $0.isEmpty ? nil : $0 } ?? Finder.title(from: sentences[first].text),
                        origin: .found, score: (item["score"] as? NSNumber)?.doubleValue.rounded(), reasons: reason.map { [$0] } ?? [])
        }
    }

    /// One small request, to check the address, model and key in Settings.
    static func test() async throws -> String {
        let config = try await connect { _, _ in }
        defer { Task { await disconnect() } }
        let reply = try await complete(config, prompt: "Reply with JSON only: {\"ok\": true}")
        return reply.contains("ok") ? "Connected to \(config.model.isEmpty ? "the model" : config.model)." : "Connected, but the model answered: \(reply.prefix(80))"
    }
}

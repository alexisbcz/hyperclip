import Foundation

/// One spoken word and when it's said, in seconds from the start of the video.
nonisolated struct Word: Codable, Hashable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

/// A run of words that ends a thought: at a full stop, a question or exclamation mark, or a long pause.
nonisolated struct Sentence: Hashable, Sendable {
    var index: Int
    /// Indices into the transcript's words.
    var words: Range<Int>
    var start: Double
    var end: Double
    var text: String
}

nonisolated struct Transcript: Codable, Hashable, Sendable {
    var words: [Word]
    var language: String?
    /// Which engine wrote it, for showing in the editor.
    var engine: String

    var text: String { words.map(\.text).joined(separator: " ") }

    /// Words split into sentences. A pause this long also ends one, since some engines skip punctuation.
    func sentences(pause: Double = 1.2) -> [Sentence] {
        var sentences: [Sentence] = []
        var first = 0
        for index in words.indices {
            let word = words[index]
            let next = index + 1 < words.count ? words[index + 1] : nil
            let ends = word.text.last.map { ".!?…。！？".contains($0) } ?? false
            let paused = next.map { $0.start - word.end > pause } ?? true
            if ends || paused || next == nil {
                let range = first..<(index + 1)
                sentences.append(Sentence(index: sentences.count, words: range, start: words[first].start, end: word.end,
                                          text: words[range].map(\.text).joined(separator: " ")))
                first = index + 1
            }
        }
        return sentences
    }

    /// The words said within a span of time.
    func words(in range: ClosedRange<Double>) -> ArraySlice<Word> {
        let lower = words.partitioningIndex { $0.end > range.lowerBound }
        let upper = words.partitioningIndex { $0.start >= range.upperBound }
        return lower < upper ? words[lower..<upper] : []
    }

    func text(in range: ClosedRange<Double>) -> String {
        words(in: range).map(\.text).joined(separator: " ")
    }
}

/// A moment of a video worth posting on its own.
nonisolated struct Clip: Codable, Hashable, Identifiable, Sendable {
    enum Origin: String, Codable, Sendable {
        case manual, found
    }

    var id = UUID()
    var start: Double
    var end: Double
    var title: String
    var origin: Origin
    /// How likely it is to work as a short, from 0 to 100, for clips Hyperclip found.
    var score: Double?
    /// Why it scored the way it did, in a few short phrases.
    var reasons: [String] = []
    /// Overrides the export's framing for this clip.
    var framing: Framing?
    /// Where the crop follows the speaker to, across the clip.
    var track: SpeakerTrack?
    var createdAt = Date()

    static let trackStep = 0.5

    var duration: Double { end - start }
    var range: ClosedRange<Double> { start...max(start, end) }
}

/// Where the crop goes across a clip: horizontal centers from 0 to 1, one every `Clip.trackStep` seconds,
/// and the times, in seconds into the clip, where it cuts to another speaker instead of gliding.
nonisolated struct SpeakerTrack: Codable, Hashable, Sendable {
    var centers: [Double]
    var cuts: [Double] = []

    private enum CodingKeys: String, CodingKey { case centers, cuts }

    init(centers: [Double], cuts: [Double] = []) {
        self.centers = centers
        self.cuts = cuts
    }

    /// Also reads tracks saved before there were cuts, which were just the centers.
    init(from decoder: any Decoder) throws {
        if let centers = try? decoder.singleValueContainer().decode([Double].self) {
            self.init(centers: centers)
        } else {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.init(centers: try container.decode([Double].self, forKey: .centers),
                      cuts: try container.decodeIfPresent([Double].self, forKey: .cuts) ?? [])
        }
    }

    /// The track for a clip shortened to `duration`.
    func trimmed(to duration: Double) -> SpeakerTrack {
        SpeakerTrack(centers: Array(centers.prefix(Int(duration / Clip.trackStep) + 2)), cuts: cuts.filter { $0 < duration })
    }
}

/// A file Hyperclip exported.
nonisolated struct Export: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var clipID: UUID
    var title: String
    var file: URL
    var aspect: Aspect
    var duration: Double
    var createdAt = Date()
    /// Where it was posted through Zernio.
    var posts: [Publication]?
}

/// A clip posted to one platform.
nonisolated struct Publication: Codable, Hashable, Sendable {
    var platform: String
    var account: String
    var status: String
    var url: String?
    var date = Date()
}

/// A video and everything made from it: its transcript, its clips and their exports.
nonisolated struct Project: Codable, Hashable, Identifiable, Sendable {
    var id = UUID()
    var title: String
    /// The page it was downloaded from, if it was.
    var sourceURL: String?
    var channel: String?
    /// The video file. Downloads live in the project's folder; imported files stay where they were.
    var media: URL?
    var duration: Double = 0
    var width: Double = 0
    var height: Double = 0
    var transcript: Transcript?
    /// The loudness of the audio, ten values a second from 0 to 1, for the timeline and for finding clips.
    var loudness: [Float]?
    var clips: [Clip] = []
    var exports: [Export] = []
    var createdAt = Date()

    static let loudnessRate = 10.0

    var aspectRatio: Double { width > 0 && height > 0 ? width / height : 16.0 / 9 }

    func clip(_ id: UUID?) -> Clip? { clips.first { $0.id == id } }

    mutating func update(_ clip: Clip) {
        if let index = clips.firstIndex(where: { $0.id == clip.id }) { clips[index] = clip }
    }
}

nonisolated extension Double {
    /// 1:05 or 1:02:03.
    var clock: String {
        guard isFinite else { return "0:00" }
        let total = Int(self.rounded(.down))
        let hours = total / 3600, minutes = total / 60 % 60, seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }

    /// 1:05.4, for edit points.
    var preciseClock: String {
        guard isFinite else { return "0:00.0" }
        let tenths = Int((self * 10).rounded(.down)) % 10
        return "\(clock).\(tenths)"
    }

    /// "42s" or "1m 05s".
    var shortDuration: String {
        let total = Int(self.rounded())
        return total < 60 ? "\(total)s" : String(format: "%dm %02ds", total / 60, total % 60)
    }
}

nonisolated extension Collection {
    /// The first index where `predicate` turns true, for a predicate that's false and then true.
    func partitioningIndex(where predicate: (Element) -> Bool) -> Index {
        var low = startIndex
        var count = self.count
        while count > 0 {
            let half = count / 2
            let middle = index(low, offsetBy: half)
            if predicate(self[middle]) {
                count = half
            } else {
                low = index(after: middle)
                count -= half + 1
            }
        }
        return low
    }
}

import AVFoundation
import Vision

/// Finds who's talking across a clip, so a vertical crop can follow them.
nonisolated enum Reframer {
    /// Frames looked at per second: enough to see lips move.
    static let rate = 8.0

    /// A face in one frame, with the same `id` in every frame it's followed through.
    struct Face: Sendable {
        var id = 0
        /// Its middle, from 0 to 1 across and up the frame.
        var x: Double
        var y: Double
        /// Its height, as a fraction of the frame's.
        var size: Double
        /// A small grey picture of the mouth. Nil for a person whose face doesn't show.
        var mouth: Patch?
        /// How much the mouth changed since the frame before, from 0 for not at all.
        var motion: Double?
    }

    /// Where the crop goes across a clip: on whoever's talking, cutting when someone else takes over, held still
    /// otherwise and only moving when they really do, like an editor and a camera operator would.
    static func track(_ media: URL, range: ClosedRange<Double>, words: [Word], progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> SpeakerTrack {
        let frames = try await faces(in: media, range: range, progress: progress)
        let speech = frames.indices.map { words.isEmpty || saying(words, at: range.lowerBound + Double($0) / rate) }
        return track(frames, subjects: subjects(speakers(in: frames, speech: speech), frames: frames), duration: range.upperBound - range.lowerBound)
    }

    // MARK: Faces

    /// The faces in each frame, `rate` frames a second, followed from frame to frame.
    static func faces(in media: URL, range: ClosedRange<Double>, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [[Face]] {
        let asset = AVURLAsset(url: media)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        // Big enough to see the lips of a face in a wide shot.
        generator.maximumSize = CGSize(width: 1280, height: 1280)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5 / rate, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5 / rate, preferredTimescale: 600)

        let count = max(1, Int(((range.upperBound - range.lowerBound) * rate).rounded(.down)) + 1)
        let times = (0..<count).map { CMTime(seconds: range.lowerBound + Double($0) / rate, preferredTimescale: 600) }
        var frames = [[Face]](repeating: [], count: count)
        var follower = Follower()
        var last: Patch?
        var index = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            defer { index += 1; progress(Double(index) / Double(count)) }
            guard index < count, let image = try? result.image else { continue }
            // A different picture altogether is another camera: whoever's in it is someone new.
            let whole = Patch(image, around: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            if let whole, let last, whole.change(from: last) > 0.35 { follower.forget() }
            last = whole
            follower.aspect = Double(image.width) / Double(max(1, image.height))
            frames[index] = follower.follow(await faces(in: image), at: index)
        }
        return frames
    }

    /// Every face with a picture of its mouth, or the people when no face shows.
    private static func faces(in image: CGImage) async -> [Face] {
        let size = CGSize(width: image.width, height: image.height)
        if let found = try? await DetectFaceLandmarksRequest().perform(on: image), !found.isEmpty {
            return found.map { face in
                let box = face.boundingBox.toImageCoordinates(size, origin: .upperLeft)
                // The lips when they were found, else where a mouth usually is in a face.
                let lips = face.landmarks?.outerLips.pointsInImageCoordinates(size, origin: .upperLeft) ?? []
                let bounds = lips.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
                let onLips = !bounds.isNull && bounds.height > 1
                let center = onLips ? CGPoint(x: bounds.midX, y: bounds.midY) : CGPoint(x: box.midX, y: box.maxY - box.height * 0.22)
                let width = max(onLips ? bounds.width * 1.4 : 0, box.width * 0.45)
                var mouth = Patch(image, around: CGRect(x: center.x - width / 2, y: center.y - width / 3, width: width, height: width * 2 / 3))
                mouth?.byLips = onLips
                let normalized = face.boundingBox.cgRect
                return Face(x: normalized.midX, y: normalized.midY, size: normalized.height, mouth: mouth)
            }
        }
        let people = (try? await DetectHumanRectanglesRequest().perform(on: image)) ?? []
        return people.map { person in
            let box = person.boundingBox.cgRect
            return Face(x: box.midX, y: box.midY, size: box.height)
        }
    }

    /// A small grey picture of a mouth, or of a whole frame, to compare from one frame to the next.
    struct Patch: Sendable {
        static let width = 24, height = 16
        var pixels: [Double]
        /// Placed on the lips Vision found, rather than where a mouth usually is. Only pictures placed the same way compare.
        var byLips = false

        init?(_ image: CGImage, around rect: CGRect) {
            guard let crop = image.cropping(to: rect.integral), crop.width > 4, crop.height > 4 else { return nil }
            var bytes = [UInt8](repeating: 0, count: Self.width * Self.height)
            let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
                guard let context = CGContext(data: buffer.baseAddress, width: Self.width, height: Self.height, bitsPerComponent: 8,
                                              bytesPerRow: Self.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
                context.interpolationQuality = .medium
                context.draw(crop, in: CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
                return true
            }
            guard drawn else { return nil }
            // Without its average, so a change of light doesn't count.
            let mean = bytes.reduce(0) { $0 + Double($1) } / Double(bytes.count)
            pixels = bytes.map { Double($0) - mean }
        }

        /// How different two pictures of a mouth are, relative to their contrast, at the shift that lines them up best.
        func change(from other: Patch) -> Double {
            let margin = 2
            var best = Double.infinity
            for dy in -margin...margin {
                for dx in -margin...margin {
                    var total = 0.0
                    for y in margin..<(Self.height - margin) {
                        for x in margin..<(Self.width - margin) {
                            total += abs(pixels[y * Self.width + x] - other.pixels[(y + dy) * Self.width + x + dx])
                        }
                    }
                    best = min(best, total)
                }
            }
            let count = Double((Self.width - 2 * margin) * (Self.height - 2 * margin))
            let contrast = (pixels.reduce(0) { $0 + abs($1) } + other.pixels.reduce(0) { $0 + abs($1) }) / Double(2 * pixels.count)
            return best / count / max(4, contrast)
        }
    }

    /// Gives each face the id it had in recent frames when it's about where it was and about as big.
    private struct Follower {
        /// The frame's width over its height, so distances across and up compare.
        var aspect = 16.0 / 9
        private var seen: [Int: (face: Face, frame: Int)] = [:]
        private var next = 0

        mutating func forget() { seen = [:] }

        mutating func follow(_ faces: [Face], at frame: Int) -> [Face] {
            seen = seen.filter { frame - $0.value.frame <= Int(2 * rate) }
            var pairs: [(cost: Double, face: Int, id: Int)] = []
            for (index, face) in faces.enumerated() {
                for (id, last) in seen {
                    let distance = hypot((face.x - last.face.x) * aspect, face.y - last.face.y) / max(face.size, last.face.size)
                    let scale = abs(log(max(0.01, face.size) / max(0.01, last.face.size)))
                    if distance < 1, scale < 0.5 { pairs.append((distance + scale, index, id)) }
                }
            }
            var faces = faces
            var matched = Set<Int>(), taken = Set<Int>()
            for pair in pairs.sorted(by: { $0.cost < $1.cost }) where !matched.contains(pair.face) && !taken.contains(pair.id) {
                faces[pair.face].id = pair.id
                matched.insert(pair.face)
                taken.insert(pair.id)
            }
            for index in faces.indices where !matched.contains(index) {
                faces[index].id = next
                next += 1
            }
            for index in faces.indices {
                if let last = seen[faces[index].id], last.frame == frame - 1, let before = last.face.mouth, let now = faces[index].mouth, before.byLips == now.byLips {
                    faces[index].motion = now.change(from: before)
                }
                seen[faces[index].id] = (faces[index], frame)
            }
            return faces
        }
    }

    // MARK: Speakers

    /// Whether a word is being said at a time in the video.
    private static func saying(_ words: [Word], at time: Double) -> Bool {
        let index = words.partitioningIndex { $0.end + 0.15 > time }
        return index < words.count && words[index].start - 0.15 <= time
    }

    /// Who's talking in each frame: while words are said, the face whose mouth changes the most over half a second
    /// either side, if it clearly changes more than any other. Each face is measured above its own stillest,
    /// so a face that's always a little noisy doesn't win. A still mouth or a voice-over moves no mouth.
    static func speakers(in frames: [[Face]], speech: [Bool]) -> [Int?] {
        var motions: [Int: [Int: Double]] = [:]
        for (index, faces) in frames.enumerated() {
            for face in faces { if let motion = face.motion { motions[face.id, default: [:]][index] = motion } }
        }
        let floors = motions.mapValues { values in
            let sorted = values.values.sorted()
            return sorted[sorted.count / 5]
        }
        let half = Int(rate / 2)
        return frames.indices.map { index -> Int? in
            guard speech[index] else { return nil }
            // Faces much smaller than the biggest are in the background, or in a picture on the wall.
            let biggest = frames[index].map(\.size).max() ?? 0
            let scores = frames[index].filter { $0.size >= biggest / 2 }.compactMap { face -> (id: Int, motion: Double)? in
                let window = (index - half...index + half).compactMap { motions[face.id]?[$0] }
                guard window.count > half, let floor = floors[face.id] else { return nil }
                return (face.id, max(0, window.reduce(0, +) / Double(window.count) - floor))
            }.sorted { $0.motion > $1.motion }
            guard let best = scores.first, best.motion > 0.06 else { return nil }
            if scores.count > 1, best.motion < scores[1].motion * 1.5 + 0.02 { return nil }
            return best.id
        }
    }

    /// Who the crop is on in each frame. It starts on whoever talks first and moves to someone else once they've
    /// talked for about a second, from when they started. Pauses, short replies and voices with no moving mouth keep it where it is.
    /// With nobody seen talking, it's the most prominent face.
    static func subjects(_ speakers: [Int?], frames: [[Face]]) -> [Int?] {
        let turn = Int(rate)
        var subjects = [Int?](repeating: nil, count: frames.count)
        var subject: Int?
        var shotStart = 0
        var missing = 0
        for index in frames.indices {
            let window = max(0, index - turn + 1)...index
            let votes = speakers[window].reduce(into: [Int: Int]()) { counts, id in if let id { counts[id, default: 0] += 1 } }
            if let candidate = speakers[index], candidate != subject, votes[candidate, default: 0] * 10 >= turn * 6,
               subject.map({ votes[$0, default: 0] * 10 <= turn * 2 }) ?? true {
                // Cut back to when they started talking, or came into view just before, but never into the last shot's first second.
                var onset = window.first { speakers[$0] == candidate } ?? index
                let seen = (window.lowerBound...onset).first { frame in (frame...onset).allSatisfy { frames[$0].contains { $0.id == candidate } } } ?? onset
                if seen > window.lowerBound { onset = seen }
                let from = subject == nil ? 0 : max(onset, shotStart + turn)
                for frame in from...index { subjects[frame] = candidate }
                subject = candidate
                shotStart = from
                missing = 0
                continue
            }
            // Gone for a while, as when the video cuts to another camera: the biggest face that's settled there instead,
            // from when it came into view. A face glimpsed during a pan isn't one.
            if let current = subject {
                missing = frames[index].contains { $0.id == current } ? 0 : missing + 1
                if missing >= turn, let (face, since) = settled(in: frames, at: index, within: missing) {
                    let from = max(shotStart + 1, since)
                    for frame in from...index { subjects[frame] = face }
                    subject = face
                    shotStart = from
                    missing = 0
                }
            }
            subjects[index] = subject
        }
        // Before anyone talks: the first speaker, or with none, whoever's most on screen.
        let first = subjects.first { $0 != nil } ?? prominent(frames)
        for index in subjects.indices {
            guard subjects[index] == nil else { break }
            subjects[index] = first
        }
        return subjects
    }

    /// The biggest face that's been in view for half a second or more of the last `within` frames, and the frame it came into view.
    private static func settled(in frames: [[Face]], at index: Int, within: Int) -> (id: Int, since: Int)? {
        frames[index].compactMap { face -> (face: Face, since: Int)? in
            let since = (index - within + 1...index).first { frame in (frame...index).allSatisfy { frames[$0].contains { $0.id == face.id } } } ?? index
            return index - since + 1 >= Int(rate / 2) ? (face, since) : nil
        }
        .max { $0.face.size < $1.face.size }
        .map { ($0.face.id, $0.since) }
    }

    /// The face seen biggest and longest.
    private static func prominent(_ frames: [[Face]]) -> Int? {
        frames.joined().reduce(into: [Int: Double]()) { totals, face in totals[face.id, default: 0] += face.size }
            .max { $0.value < $1.value }?.key
    }

    // MARK: Track

    /// Samples where each frame's subject is every `Clip.trackStep` seconds, steadied within each shot, with a cut wherever the subject changes to someone elsewhere in the frame.
    static func track(_ frames: [[Face]], subjects: [Int?], duration: Double) -> SpeakerTrack {
        // Where the subject is in each frame, held where it can't be seen.
        var positions = [Double?](repeating: nil, count: frames.count)
        var last: [Int: Double] = [:]
        for index in frames.indices {
            guard let subject = subjects[index] else { continue }
            if let face = frames[index].first(where: { $0.id == subject }) { last[subject] = face.x }
            positions[index] = last[subject]
        }
        for index in frames.indices.reversed() where positions[index] == nil {
            positions[index] = index + 1 < frames.count && subjects[index + 1] == subjects[index] ? positions[index + 1] : nil
        }

        var cuts: [Double] = []
        for index in frames.indices.dropFirst() where subjects[index] != subjects[index - 1] {
            // Someone already in the frame gets a glide; someone elsewhere, a cut.
            if let from = positions[index - 1], let to = positions[index], abs(to - from) >= 0.1 {
                cuts.append(Double(index) / rate)
            }
        }

        let count = max(1, Int((duration / Clip.trackStep).rounded(.up)) + 1)
        let samples = (0..<count).map { sample -> Double? in
            let index = min(frames.count - 1, Int((Double(sample) * Clip.trackStep * rate).rounded()))
            guard index >= 0 else { return nil }
            let shot = shot(at: Double(sample) * Clip.trackStep, cuts: cuts)
            let near = (max(0, index - 2)...min(frames.count - 1, index + 2)).filter {
                subjects[$0] == subjects[index] && shot.contains(Double($0) / rate)
            }
            let values = near.compactMap { positions[$0] }.sorted()
            return values.isEmpty ? nil : values[values.count / 2]
        }

        // Steadied shot by shot, so a move never smears across a cut.
        var centers: [Double] = []
        var start = 0
        for bound in cuts.map({ sample(after: $0) }) + [count] where bound > start {
            centers += steady(fill(Array(samples[start..<min(count, bound)])))
            start = min(count, bound)
        }
        return SpeakerTrack(centers: centers, cuts: cuts)
    }

    /// Gaps take the nearest known center; with none at all, the middle.
    private static func fill(_ centers: [Double?]) -> [Double] {
        guard let first = centers.first(where: { $0 != nil }) ?? nil else { return centers.map { _ in 0.5 } }
        var last = first
        return centers.map { center in
            if let center { last = center }
            return last
        }
    }

    /// A median to drop stray detections, then a dead zone so small movements don't move the frame,
    /// then easing so the moves it does make glide.
    static func steady(_ centers: [Double]) -> [Double] {
        guard centers.count > 2 else { return centers }
        let median = centers.indices.map { index -> Double in
            let window = centers[max(0, index - 2)...min(centers.count - 1, index + 2)].sorted()
            return window[window.count / 2]
        }
        var held: [Double] = []
        var anchor = median[0]
        for (index, value) in median.enumerated() {
            // Move only when the speaker stays away from the frame's center for a moment.
            let ahead = median[index...min(median.count - 1, index + 2)]
            if abs(value - anchor) > 0.07, ahead.allSatisfy({ abs($0 - anchor) > 0.05 }) { anchor = value }
            held.append(anchor)
        }
        return held.indices.map { index in
            let window = held[max(0, index - 1)...min(held.count - 1, index + 1)]
            return window.reduce(0, +) / Double(window.count)
        }
    }

    // MARK: Playback

    /// The span of the clip, in seconds, between the cuts around a time.
    static func shot(at time: Double, cuts: [Double]) -> Range<Double> {
        (cuts.last { $0 <= time } ?? -.infinity)..<(cuts.first { $0 > time } ?? .infinity)
    }

    /// The first sample at or after a time.
    private static func sample(after time: Double) -> Int {
        Int((time / Clip.trackStep - 1e-9).rounded(.up))
    }

    /// The samples that fall within a shot.
    static func samples(in shot: Range<Double>, of track: SpeakerTrack) -> ClosedRange<Int> {
        let last = track.centers.count - 1
        let first = min(last, max(0, shot.lowerBound.isFinite ? sample(after: shot.lowerBound) : 0))
        let end = shot.upperBound.isFinite ? sample(after: shot.upperBound) - 1 : last
        return first...max(first, min(last, end))
    }

    /// The center at a time in the clip: interpolated between the samples of its shot, held before the first and after the last.
    static func center(in track: SpeakerTrack, at time: Double) -> Double {
        guard !track.centers.isEmpty else { return 0.5 }
        let samples = samples(in: shot(at: time, cuts: track.cuts), of: track)
        let position = time / Clip.trackStep
        let lower = min(samples.upperBound, max(samples.lowerBound, Int(position.rounded(.down))))
        let upper = min(samples.upperBound, lower + 1)
        let fraction = min(1, max(0, position - Double(lower)))
        return track.centers[lower] + (track.centers[upper] - track.centers[lower]) * fraction
    }
}

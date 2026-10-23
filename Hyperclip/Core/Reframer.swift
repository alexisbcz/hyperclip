import AVFoundation
import Vision

/// Finds where the speaker is across a clip, so a vertical crop can follow them.
nonisolated enum Reframer {
    /// Horizontal centers from 0 to 1, one every `Clip.trackStep` seconds of the clip, steadied so the frame
    /// holds still and only moves when the speaker really does, like a camera operator would.
    static func track(_ media: URL, range: ClosedRange<Double>, progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [Double] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: media))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 480)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.2, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.2, preferredTimescale: 600)

        let count = max(1, Int(((range.upperBound - range.lowerBound) / Clip.trackStep).rounded(.up)) + 1)
        let times = (0..<count).map { CMTime(seconds: range.lowerBound + Double($0) * Clip.trackStep, preferredTimescale: 600) }
        var centers = [Double?](repeating: nil, count: count)
        var index = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            defer { index += 1; progress(Double(index) / Double(count)) }
            guard index < count, let image = try? result.image else { continue }
            centers[index] = await speaker(in: image, near: centers[..<index].last { $0 != nil } ?? nil)
        }
        return steady(fill(centers))
    }

    /// The middle of the most prominent face, or of a person when no face shows.
    private static func speaker(in image: CGImage, near previous: Double?) async -> Double? {
        if let faces = try? await DetectFaceRectanglesRequest().perform(on: image), !faces.isEmpty {
            // The biggest face, unless a slightly smaller one is right where the last one was.
            let best = faces.max { a, b in
                weight(a.boundingBox.cgRect, previous) < weight(b.boundingBox.cgRect, previous)
            }
            return best.map { Double($0.boundingBox.cgRect.midX) }
        }
        if let people = try? await DetectHumanRectanglesRequest().perform(on: image), let person = people.max(by: { area($0.boundingBox.cgRect) < area($1.boundingBox.cgRect) }) {
            return Double(person.boundingBox.cgRect.midX)
        }
        return nil
    }

    private static func area(_ rect: CGRect) -> Double { Double(rect.width * rect.height) }

    private static func weight(_ rect: CGRect, _ previous: Double?) -> Double {
        let closeness = previous.map { 1 - min(1, abs(Double(rect.midX) - $0) * 3) } ?? 0
        return area(rect) * (1 + closeness)
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

    /// The center at a time in the clip, interpolated between samples.
    static func center(in track: [Double], at time: Double) -> Double {
        guard !track.isEmpty else { return 0.5 }
        let position = max(0, time / Clip.trackStep)
        let lower = min(track.count - 1, Int(position))
        let upper = min(track.count - 1, lower + 1)
        let fraction = position - Double(lower)
        return track[lower] + (track[upper] - track[lower]) * fraction
    }
}

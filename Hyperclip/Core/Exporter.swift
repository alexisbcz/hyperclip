import AppKit
import AVFoundation
import QuartzCore

/// Renders a clip with AVFoundation: trimmed, cropped to its aspect while following the speaker, captions burned in.
nonisolated enum Exporter {
    struct Options: Sendable {
        var aspect: Aspect
        var framing: Framing
        var resolution: Resolution
        var captions: CaptionStyle

        static var current: Options {
            Options(aspect: Prefs.value(Pref.aspect, default: .vertical), framing: Prefs.value(Pref.framing, default: .speaker),
                    resolution: Prefs.value(Pref.resolution, default: .p1080), captions: .current)
        }
    }

    enum Failure: LocalizedError {
        case noVideo, failed(String)

        var errorDescription: String? {
            switch self {
            case .noVideo: "The video file is missing."
            case .failed(let detail): "The export failed: \(detail)"
            }
        }
    }

    /// The crop and output size for a source of `size` at an aspect.
    struct Geometry: Sendable {
        var crop: CGSize
        var render: CGSize

        init(source size: CGSize, aspect: Aspect, resolution: Resolution) {
            let ratio = aspect.ratio ?? Double(size.width / size.height)
            if Double(size.width / size.height) > ratio {
                crop = CGSize(width: Double(size.height) * ratio, height: size.height)
            } else {
                crop = CGSize(width: size.width, height: Double(size.width) / ratio)
            }
            let short = resolution.shortSide ?? Double(min(crop.width, crop.height))
            let width = ratio <= 1 ? short : short * ratio
            let height = ratio <= 1 ? short / ratio : short
            // Encoders want even sizes.
            render = CGSize(width: (width / 2).rounded() * 2, height: (height / 2).rounded() * 2)
        }
    }

    static func export(_ media: URL, clip: Clip, words: [Word], options: Options, to destination: URL,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: media)
        guard let sourceVideo = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let sourceAudio = try await asset.loadTracks(withMediaType: .audio).first
        let (natural, preferred, frameRate) = try await sourceVideo.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let oriented = natural.applying(preferred)
        let size = CGSize(width: abs(oriented.width), height: abs(oriented.height))

        let assetDuration = try await asset.load(.duration).seconds
        let start = max(0, clip.start), end = min(assetDuration, clip.end)
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let duration = range.duration

        let composition = AVMutableComposition()
        guard let video = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.failed("couldn't add a video track")
        }
        try video.insertTimeRange(range, of: sourceVideo, at: .zero)
        if let sourceAudio, let audio = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            try audio.insertTimeRange(range, of: sourceAudio, at: .zero)
        }

        let geometry = Geometry(source: size, aspect: options.aspect, resolution: options.resolution)
        let scale = geometry.render.width / geometry.crop.width
        // Normalizes rotated sources so (0, 0) is the top left of the picture as it's shown.
        let upright = preferred.concatenating(CGAffineTransform(translationX: -min(0, oriented.width) , y: -min(0, oriented.height)))

        func transform(center: Double) -> CGAffineTransform {
            let maxX = size.width - geometry.crop.width
            let x = min(maxX, max(0, CGFloat(center) * size.width - geometry.crop.width / 2))
            let y = (size.height - geometry.crop.height) / 2
            return upright.concatenating(CGAffineTransform(translationX: -x, y: -y)).concatenating(CGAffineTransform(scaleX: scale, y: scale))
        }

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        let framing = clip.framing ?? options.framing
        let cropsWidth = geometry.crop.width < size.width - 1
        if cropsWidth, framing == .speaker {
            let track: [Double]
            if let saved = clip.track { track = saved } else { track = try await Reframer.track(media, range: start...end) }
            // A ramp between each pair of samples that differ; a hold where they don't.
            var index = 0
            while index < track.count {
                var next = index + 1
                while next < track.count, abs(track[next] - track[index]) < 0.002 { next += 1 }
                let from = CMTime(seconds: Double(index) * Clip.trackStep, preferredTimescale: 600)
                let toIndex = min(next, track.count - 1)
                let to = CMTime(seconds: min(duration.seconds, Double(toIndex) * Clip.trackStep), preferredTimescale: 600)
                guard from < duration else { break }
                if toIndex == index || to <= from {
                    layer.setTransform(transform(center: track[index]), at: from)
                } else if next - index > 1 {
                    // Held still, then the move happens over the last step.
                    let moveStart = CMTime(seconds: Double(toIndex - 1) * Clip.trackStep, preferredTimescale: 600)
                    layer.setTransform(transform(center: track[index]), at: from)
                    if moveStart < to { layer.setTransformRamp(fromStart: transform(center: track[index]), toEnd: transform(center: track[toIndex]), timeRange: CMTimeRange(start: moveStart, end: to)) }
                } else {
                    layer.setTransformRamp(fromStart: transform(center: track[index]), toEnd: transform(center: track[toIndex]), timeRange: CMTimeRange(start: from, end: to))
                }
                index = next
            }
        } else {
            layer.setTransform(transform(center: 0.5), at: .zero)
        }

        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = geometry.render
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate > 1 ? min(60, frameRate.rounded()) : 30))
        videoComposition.instructions = [instruction]

        if options.captions.isVisible, !words.isEmpty {
            let pages = CaptionPage.pages(for: words, clip: Clip(start: start, end: end, title: "", origin: .manual), perPage: options.captions.wordsPerPage)
            videoComposition.animationTool = captionTool(pages, style: options.captions, size: geometry.render)
        }

        try? FileManager.default.removeItem(at: destination)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else {
            throw Failure.failed("no export session")
        }
        session.videoComposition = videoComposition
        session.shouldOptimizeForNetworkUse = true
        nonisolated(unsafe) let watched = session
        let watcher = Task {
            for await state in watched.states(updateInterval: 0.2) {
                if case .exporting(let exportProgress) = state { progress(exportProgress.fractionCompleted) }
            }
        }
        defer { watcher.cancel() }
        try await session.export(to: destination, as: .mp4)
        progress(1)
    }

    /// Core Animation layers that show each caption page while its words are said, the current word highlighted.
    private static func captionTool(_ pages: [CaptionPage], style: CaptionStyle, size: CGSize) -> AVVideoCompositionCoreAnimationTool {
        let parent = CALayer()
        parent.frame = CGRect(origin: .zero, size: size)
        parent.isGeometryFlipped = true
        let video = CALayer()
        video.frame = parent.frame
        parent.addSublayer(video)

        let scale = size.width / 1080
        let maxWidth = size.width * 0.84
        for page in pages {
            // One layer per word being said, each showing the whole page with that word lit.
            for (index, word) in page.words.enumerated() {
                guard let image = style.render(page, active: index, scale: scale, maxWidth: maxWidth) else { continue }
                let width = CGFloat(image.width), height = CGFloat(image.height)
                let layer = CALayer()
                layer.contents = image
                layer.frame = CGRect(x: (size.width - width) / 2, y: size.height * style.position - height / 2, width: width, height: height)
                layer.opacity = 0

                let from = index == 0 ? page.start : word.start
                let to = index + 1 < page.words.count ? page.words[index + 1].start : page.end
                guard to > from else { continue }
                // Animations spanning the whole clip with discrete steps; ones that start mid-clip linger in exports.
                let total = max(0.1, pages.last?.end ?? to)
                let show = CAKeyframeAnimation(keyPath: "opacity")
                show.values = [0, 1, 0]
                show.keyTimes = [0, NSNumber(value: from / total), NSNumber(value: min(1, to / total)), 1]
                show.calculationMode = .discrete
                show.beginTime = AVCoreAnimationBeginTimeAtZero
                show.duration = total
                show.isRemovedOnCompletion = false
                show.fillMode = .both
                layer.add(show, forKey: "show")

                // Each page pops in.
                if index == 0, style.animate {
                    let pop = CAKeyframeAnimation(keyPath: "transform.scale")
                    let a = from / total, b = min(1, (from + 0.12) / total)
                    pop.values = [0.82, 0.82, 1, 1]
                    pop.keyTimes = [0, NSNumber(value: a), NSNumber(value: b), 1]
                    pop.beginTime = AVCoreAnimationBeginTimeAtZero
                    pop.duration = total
                    pop.isRemovedOnCompletion = false
                    pop.fillMode = .both
                    layer.add(pop, forKey: "pop")
                }
                parent.addSublayer(layer)
            }
        }
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
    }

    /// A file name in the export folder that isn't taken yet.
    static func destination(for title: String, project: String) -> URL {
        let folder = Prefs.exportFolder.appending(path: sanitize(project), directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = sanitize(title)
        var url = folder.appending(path: base + ".mp4")
        var number = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = folder.appending(path: "\(base) \(number).mp4")
            number += 1
        }
        return url
    }

    static func sanitize(_ name: String) -> String {
        let cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\\?%*|\"<>\n\r")).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        return String((cleaned.isEmpty ? "Clip" : cleaned).prefix(80))
    }
}

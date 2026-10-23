import AVKit
import SwiftUI

/// The video, either whole with the crop marked on it, or cropped the way the export will be, captions included.
struct PreviewView: View {
    @Environment(Studio.self) private var studio
    let project: Project
    /// Shows just the cropped frame, as exported.
    let cropped: Bool

    @AppStorage(Pref.aspect) private var aspect = Aspect.vertical
    @AppStorage(Pref.framing) private var framing = Framing.speaker
    // Read so the preview redraws when caption settings change.
    @AppStorage(Pref.captionStyle) private var captionPreset = CaptionStyle.Preset.bold
    @AppStorage(Pref.captionFont) private var captionFont = Defaults.captionFont
    @AppStorage(Pref.captionSize) private var captionSize = Defaults.captionSize
    @AppStorage(Pref.captionWords) private var captionWords = Defaults.captionWords
    @AppStorage(Pref.captionUppercase) private var captionUppercase = true
    @AppStorage(Pref.captionHighlight) private var captionHighlight = Defaults.captionHighlight
    @AppStorage(Pref.captionPosition) private var captionPosition = Defaults.captionPosition

    var body: some View {
        GeometryReader { proxy in
            let videoRatio = project.aspectRatio
            let cropRatio = aspect.ratio ?? videoRatio
            let clip = activeClip
            let center = cropCenter(clip)
            ZStack {
                if cropped {
                    croppedVideo(in: proxy.size, videoRatio: videoRatio, cropRatio: cropRatio, center: center, clip: clip)
                } else {
                    fullVideo(in: proxy.size, videoRatio: videoRatio, cropRatio: cropRatio, center: center, clip: clip)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(.black)
    }

    /// The selected clip if the playhead is in it, else whichever clip it's in.
    private var activeClip: Clip? {
        let time = studio.player.time
        if let selected = studio.selectedClip, selected.range.contains(time) { return selected }
        return project.clips.first { $0.range.contains(time) }
    }

    private func cropCenter(_ clip: Clip?) -> Double {
        guard let clip, (clip.framing ?? framing) == .speaker, let track = clip.track else { return 0.5 }
        return Reframer.center(in: track, at: studio.player.time - clip.start)
    }

    private func fullVideo(in size: CGSize, videoRatio: Double, cropRatio: Double, center: Double, clip: Clip?) -> some View {
        let fit = fitted(ratio: videoRatio, in: size)
        let cropWidth = cropRatio < videoRatio ? fit.height * cropRatio : fit.width
        let cropHeight = cropRatio < videoRatio ? fit.height : fit.width / cropRatio
        let x = min(fit.width - cropWidth, max(0, center * fit.width - cropWidth / 2))
        return ZStack(alignment: .topLeading) {
            VideoSurface(player: studio.player.avPlayer)
            if aspect != .original {
                // Darkens what the crop leaves out.
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: fit))
                    path.addRoundedRect(in: CGRect(x: x, y: (fit.height - cropHeight) / 2, width: cropWidth, height: cropHeight), cornerSize: CGSize(width: 4, height: 4))
                }
                .fill(.black.opacity(0.55), style: FillStyle(eoFill: true))
                .allowsHitTesting(false)
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(.white.opacity(0.85), lineWidth: 1.5)
                    .frame(width: cropWidth, height: cropHeight)
                    .offset(x: x, y: (fit.height - cropHeight) / 2)
                    .allowsHitTesting(false)
            }
            if let clip {
                CaptionLayer(project: project, clip: clip, time: studio.player.time, width: cropWidth, height: cropHeight)
                    .frame(width: cropWidth, height: cropHeight)
                    .offset(x: x, y: (fit.height - cropHeight) / 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: fit.width, height: fit.height)
        .animation(.smooth(duration: 0.25), value: center)
    }

    private func croppedVideo(in size: CGSize, videoRatio: Double, cropRatio: Double, center: Double, clip: Clip?) -> some View {
        let frame = fitted(ratio: cropRatio, in: CGSize(width: size.width, height: size.height - 24))
        let videoSize = cropRatio < videoRatio ? CGSize(width: frame.height * videoRatio, height: frame.height) : CGSize(width: frame.width, height: frame.width / videoRatio)
        let x = min(videoSize.width - frame.width, max(0, center * videoSize.width - frame.width / 2))
        return ZStack(alignment: .topLeading) {
            VideoSurface(player: studio.player.avPlayer)
                .frame(width: videoSize.width, height: videoSize.height)
                .offset(x: -x, y: -(videoSize.height - frame.height) / 2)
            if let clip {
                CaptionLayer(project: project, clip: clip, time: studio.player.time, width: frame.width, height: frame.height)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: frame.width, height: frame.height, alignment: .topLeading)
        .clipShape(.rect(cornerRadius: 10))
        .animation(.smooth(duration: 0.25), value: center)
    }

    private func fitted(ratio: Double, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return .zero }
        return size.width / size.height > ratio
            ? CGSize(width: size.height * ratio, height: size.height)
            : CGSize(width: size.width, height: size.width / ratio)
    }
}

/// AVPlayerView without its controls; the editor has its own.
struct VideoSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}

/// The captions as they'll be burned in, drawn with the same Core Animation text the export uses.
struct CaptionLayer: NSViewRepresentable {
    let project: Project
    let clip: Clip
    let time: Double
    let width: CGFloat
    let height: CGFloat

    func makeNSView(context: Context) -> CaptionView { CaptionView() }

    func updateNSView(_ view: CaptionView, context: Context) {
        let style = CaptionStyle.current
        guard style.isVisible, let transcript = project.transcript else {
            view.show(nil, style: style, scale: 1, size: CGSize(width: width, height: height))
            return
        }
        let pages = context.coordinator.pages(for: clip, transcript: transcript, perPage: style.wordsPerPage)
        let local = time - clip.start
        let page = pages.first { $0.start <= local && local < $0.end }
        let active = page?.activeWord(at: local)
        view.show(page.map { ($0, active) }, style: style, scale: width / 1080, size: CGSize(width: width, height: height))
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    /// Pages are worked out once per clip and caption setting, not on every frame.
    final class Coordinator {
        private var key: String?
        private var cached: [CaptionPage] = []

        func pages(for clip: Clip, transcript: Transcript, perPage: Int) -> [CaptionPage] {
            let key = "\(clip.id)-\(clip.start)-\(clip.end)-\(perPage)-\(transcript.words.count)"
            if key != self.key {
                self.key = key
                cached = CaptionPage.pages(for: transcript.words(in: clip.range), clip: clip, perPage: perPage)
            }
            return cached
        }
    }
}

final class CaptionView: NSView {
    private let box = CALayer()
    private var shown: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(box)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func show(_ page: (CaptionPage, Int?)?, style: CaptionStyle, scale: CGFloat, size: CGSize) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let (page, active) = page, size.width > 0 else {
            box.isHidden = true
            shown = nil
            return
        }
        box.isHidden = false
        let key = "\(page.start)-\(active ?? -1)-\(scale)-\(style.preset.rawValue)-\(style.font)-\(style.size)-\(style.uppercase)-\(style.highlight.hex)-\(style.position)-\(size)"
        guard key != shown else { return }
        shown = key
        let pixels = window?.backingScaleFactor ?? 2
        guard let image = style.render(page, active: active, scale: scale, maxWidth: size.width * 0.84, pixels: pixels) else { return }
        let width = CGFloat(image.width) / pixels, height = CGFloat(image.height) / pixels
        box.contents = image
        box.frame = CGRect(x: (size.width - width) / 2, y: size.height * style.position - height / 2, width: width, height: height)
    }
}

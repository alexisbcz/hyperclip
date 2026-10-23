import AppKit
import SwiftUI

/// The whole video along a line: its loudness, the clips on it, and the playhead. Scroll to pan, pinch or ⌘-scroll
/// to zoom, click to seek, drag a selected clip's edges to trim it.
struct ClipTimeline: NSViewRepresentable {
    let duration: Double
    let loudness: [Float]
    let clips: [Clip]
    let selected: UUID?
    let marks: (in: Double?, out: Double?)?
    let time: Double
    let isPlaying: Bool
    var seek: (Double) -> Void
    var select: (UUID?) -> Void
    var trim: (UUID, Double, Double) -> Void

    func makeNSView(context: Context) -> TimelineCanvas { TimelineCanvas() }

    func updateNSView(_ view: TimelineCanvas, context: Context) {
        view.duration = duration
        view.loudness = loudness
        view.clips = clips
        view.selected = selected
        view.marks = marks
        view.isPlaying = isPlaying
        view.time = time
        view.onSeek = seek
        view.onSelect = select
        view.onTrim = trim
        view.accent = NSColor.controlAccentColor
        view.needsDisplay = true
    }
}

final class TimelineCanvas: NSView {
    var duration: Double = 0 {
        didSet { if duration != oldValue { fitAll() } }
    }
    var loudness: [Float] = []
    var clips: [Clip] = []
    var selected: UUID?
    var marks: (in: Double?, out: Double?)?
    var isPlaying = false
    var time: Double = 0 {
        didSet { if isPlaying, dragging == nil { follow() } }
    }
    var accent = NSColor.controlAccentColor
    var onSeek: (Double) -> Void = { _ in }
    var onSelect: (UUID?) -> Void = { _ in }
    var onTrim: (UUID, Double, Double) -> Void = { _, _, _ in }

    /// The first second in view, and how many seconds each point spans.
    private var start: Double = 0
    private var scale: Double = 1

    private enum Drag { case scrub, startEdge(Clip), endEdge(Clip) }
    private var dragging: Drag?

    private let ruler: CGFloat = 20
    private let inset: CGFloat = 10

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    override func setFrameSize(_ newSize: NSSize) {
        let wasFitted = abs(visibleSeconds - duration) < 0.5 || scale == 1
        super.setFrameSize(newSize)
        if wasFitted { fitAll() }
    }

    private var usableWidth: CGFloat { max(1, bounds.width - inset * 2) }
    private var visibleSeconds: Double { Double(usableWidth) * scale }

    private func fitAll() {
        guard duration > 0 else { return }
        start = 0
        scale = duration / Double(usableWidth)
        needsDisplay = true
    }

    private func x(_ seconds: Double) -> CGFloat { inset + CGFloat((seconds - start) / scale) }
    private func seconds(_ x: CGFloat) -> Double { min(duration, max(0, start + Double(x - inset) * scale)) }

    private func clampStart() {
        start = min(max(0, start), max(0, duration - visibleSeconds))
    }

    /// Keeps the playhead in view while playing, paging ahead like a video editor does.
    private func follow() {
        guard duration > 0 else { return }
        if time < start || time > start + visibleSeconds * 0.95 {
            start = time - visibleSeconds * 0.1
            clampStart()
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard duration > 0 else { return }
        let height = bounds.height
        let track = CGRect(x: 0, y: ruler, width: bounds.width, height: height - ruler)

        drawRuler()

        // Loudness, as bars mirrored around the middle.
        if !loudness.isEmpty {
            let middle = track.midY
            let amplitude = (track.height - 16) / 2
            let step: CGFloat = 3
            NSColor.secondaryLabelColor.withAlphaComponent(0.35).setFill()
            var px = inset
            while px < bounds.width - inset {
                let from = seconds(px), to = seconds(px + step)
                let a = Int(from * Project.loudnessRate), b = max(a + 1, Int(to * Project.loudnessRate))
                if a < loudness.count {
                    let value = loudness[a..<min(b, loudness.count)].max() ?? 0
                    let h = max(1, CGFloat(value * value) * amplitude)
                    NSBezierPath(roundedRect: CGRect(x: px, y: middle - h, width: step - 1, height: h * 2), xRadius: 0.75, yRadius: 0.75).fill()
                }
                px += step
            }
        }

        // Clips.
        for clip in clips {
            let rect = CGRect(x: x(clip.start), y: track.minY + 4, width: max(2, x(clip.end) - x(clip.start)), height: track.height - 8)
            guard rect.maxX > 0, rect.minX < bounds.width else { continue }
            let isSelected = clip.id == selected
            let color = clip.origin == .manual ? NSColor.systemTeal : accent
            color.withAlphaComponent(isSelected ? 0.32 : 0.16).setFill()
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            path.fill()
            color.withAlphaComponent(isSelected ? 1 : 0.55).setStroke()
            path.lineWidth = isSelected ? 2 : 1
            path.stroke()
            if rect.width > 40 {
                let label = (clip.score.map { "\(Int($0)) · " } ?? "") + clip.title
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10.5, weight: .semibold),
                    .foregroundColor: NSColor.labelColor.withAlphaComponent(isSelected ? 0.95 : 0.7),
                ]
                let text = NSAttributedString(string: label, attributes: attributes)
                NSGraphicsContext.saveGraphicsState()
                NSBezierPath(rect: rect.insetBy(dx: 8, dy: 0)).addClip()
                text.draw(at: CGPoint(x: rect.minX + 8, y: rect.minY + 5))
                NSGraphicsContext.restoreGraphicsState()
            }
            if isSelected {
                for edge in [rect.minX, rect.maxX] {
                    let handle = CGRect(x: edge - 3, y: rect.midY - 14, width: 6, height: 28)
                    color.setFill()
                    NSBezierPath(roundedRect: handle, xRadius: 3, yRadius: 3).fill()
                }
            }
        }

        // Marked in and out points.
        if let marks {
            NSColor.systemYellow.setFill()
            NSColor.systemYellow.setStroke()
            if let a = marks.in, let b = marks.out {
                NSColor.systemYellow.withAlphaComponent(0.15).setFill()
                CGRect(x: x(a), y: track.minY, width: x(b) - x(a), height: track.height).fill()
                NSColor.systemYellow.setFill()
            }
            for point in [marks.in, marks.out].compactMap({ $0 }) {
                let px = x(point)
                CGRect(x: px - 1, y: track.minY, width: 2, height: track.height).fill()
            }
        }

        // Playhead.
        let px = x(time)
        if px >= 0, px <= bounds.width {
            NSColor.labelColor.setFill()
            CGRect(x: px - 1, y: ruler - 2, width: 2, height: height - ruler + 2).fill()
            let head = NSBezierPath()
            head.move(to: CGPoint(x: px - 6, y: ruler - 9))
            head.line(to: CGPoint(x: px + 6, y: ruler - 9))
            head.line(to: CGPoint(x: px, y: ruler - 1))
            head.close()
            head.fill()
        }
    }

    private func drawRuler() {
        // A tick interval that leaves room for labels.
        let candidates: [Double] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
        let interval = candidates.first { $0 / scale >= 70 } ?? 3600
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ]
        NSColor.separatorColor.setFill()
        var tick = (start / interval).rounded(.down) * interval
        while tick <= start + visibleSeconds + interval {
            let px = x(tick)
            if px >= inset - 1, px <= bounds.width {
                CGRect(x: px, y: ruler - 6, width: 1, height: 5).fill()
                NSAttributedString(string: tick.clock, attributes: attributes).draw(at: CGPoint(x: px + 3, y: 2))
                // Minor ticks.
                for minor in 1..<5 {
                    let mx = x(tick + interval * Double(minor) / 5)
                    if mx < bounds.width { CGRect(x: mx, y: ruler - 3, width: 1, height: 2).fill() }
                }
            }
            tick += interval
        }
    }

    // MARK: Interaction

    override func scrollWheel(with event: NSEvent) {
        guard duration > 0 else { return }
        if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
            zoom(by: 1 + event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.1), around: convert(event.locationInWindow, from: nil).x)
        } else {
            let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
            start -= Double(delta) * scale * (event.hasPreciseScrollingDeltas ? 1 : 8)
            clampStart()
            needsDisplay = true
        }
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil).x)
    }

    private func zoom(by factor: CGFloat, around px: CGFloat) {
        let anchor = seconds(px)
        let fullScale = duration / Double(usableWidth)
        scale = min(fullScale, max(0.005, scale / Double(max(0.2, factor))))
        start = anchor - Double(px - inset) * scale
        clampStart()
        needsDisplay = true
    }

    func zoomIn() { zoom(by: 1.6, around: x(time)) }
    func zoomOut() { zoom(by: 1 / 1.6, around: x(time)) }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let clip = clips.first(where: { $0.id == selected }) {
            if abs(point.x - x(clip.start)) < 7 { dragging = .startEdge(clip); return }
            if abs(point.x - x(clip.end)) < 7 { dragging = .endEdge(clip); return }
        }
        if point.y > ruler, let clip = clips.last(where: { x($0.start) <= point.x && point.x <= x($0.end) }), clip.id != selected {
            onSelect(clip.id)
            onSeek(clip.start)
            dragging = nil
            return
        }
        dragging = .scrub
        onSeek(seconds(point.x))
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let at = seconds(point.x)
        switch dragging {
        case .scrub: onSeek(at)
        case .startEdge(let clip):
            onTrim(clip.id, min(at, clip.end - 1), clip.end)
            onSeek(min(at, clip.end - 1))
        case .endEdge(let clip):
            onTrim(clip.id, clip.start, max(at, clip.start + 1))
            onSeek(max(at, clip.start + 1))
        case nil: break
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragging = nil
    }

    override func resetCursorRects() {
        guard let clip = clips.first(where: { $0.id == selected }) else { return }
        for edge in [x(clip.start), x(clip.end)] {
            addCursorRect(CGRect(x: edge - 6, y: ruler, width: 12, height: bounds.height - ruler), cursor: .resizeLeftRight)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        window?.invalidateCursorRects(for: self)
    }
}

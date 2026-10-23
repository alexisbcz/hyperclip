import AppKit
import SwiftUI

/// The transcript as text: click a word to jump to it, select words to make a clip of them.
/// The word being said is lit as the video plays, and the selected clip is shaded.
struct TranscriptView: NSViewRepresentable {
    let transcript: Transcript
    let time: Double
    let isPlaying: Bool
    let clip: Clip?
    let fontSize: CGFloat
    var seek: (Double) -> Void
    /// The span of the words selected, if any.
    var selectionChanged: (ClosedRange<Double>?) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let text = scroll.documentView as? NSTextView else { return scroll }
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.textContainerInset = NSSize(width: 18, height: 16)
        text.delegate = context.coordinator
        context.coordinator.textView = text
        let click = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.clicked(_:)))
        click.delaysPrimaryMouseButtonEvents = false
        text.addGestureRecognizer(click)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        coordinator.render(transcript, fontSize: fontSize)
        coordinator.shade(clip)
        coordinator.highlight(time: time, follow: isPlaying)
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: TranscriptView
        weak var textView: NSTextView?
        /// Each word's characters in the text.
        private var ranges: [NSRange] = []
        private var words: [Word] = []
        private var renderedKey: String?
        private var lit: Int?
        private var shaded: NSRange?
        private var lastUserScroll = Date.distantPast

        init(parent: TranscriptView) { self.parent = parent }

        func render(_ transcript: Transcript, fontSize: CGFloat) {
            let key = "\(transcript.words.count)-\(transcript.words.first?.start ?? 0)-\(transcript.words.last?.end ?? 0)-\(fontSize)"
            guard key != renderedKey, let textView else { return }
            renderedKey = key
            words = transcript.words
            ranges = []
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = fontSize * 0.42
            paragraph.paragraphSpacing = fontSize * 0.9
            let body: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
            let stamp: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: fontSize * 0.72, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .paragraphStyle: paragraph,
            ]
            let text = NSMutableAttributedString()
            // A new paragraph after a long pause or every few sentences, each with its time.
            var sentencesInParagraph = 0
            for (index, word) in words.enumerated() {
                let previous = index > 0 ? words[index - 1] : nil
                let newParagraph = previous == nil || word.start - previous!.end > 2.0
                    || (sentencesInParagraph >= 4 && previous!.text.last.map { ".!?".contains($0) } == true)
                if newParagraph {
                    if previous != nil { text.append(NSAttributedString(string: "\n", attributes: body)) }
                    text.append(NSAttributedString(string: word.start.clock + "   ", attributes: stamp))
                    sentencesInParagraph = 0
                } else {
                    text.append(NSAttributedString(string: " ", attributes: body))
                }
                ranges.append(NSRange(location: text.length, length: (word.text as NSString).length))
                text.append(NSAttributedString(string: word.text, attributes: body))
                if word.text.last.map({ ".!?".contains($0) }) == true { sentencesInParagraph += 1 }
            }
            textView.textStorage?.setAttributedString(text)
            lit = nil
            shaded = nil
        }

        func shade(_ clip: Clip?) {
            guard let storage = textView?.textStorage else { return }
            var range: NSRange?
            if let clip, let first = words.firstIndex(where: { $0.end > clip.start }),
               let last = words.lastIndex(where: { $0.start < clip.end }), first <= last {
                range = NSRange(location: ranges[first].location, length: NSMaxRange(ranges[last]) - ranges[first].location)
            }
            guard range != shaded else { return }
            storage.beginEditing()
            if let shaded, NSMaxRange(shaded) <= storage.length { storage.removeAttribute(.backgroundColor, range: shaded) }
            if let range { storage.addAttribute(.backgroundColor, value: NSColor.controlAccentColor.withAlphaComponent(0.13), range: range) }
            storage.endEditing()
            shaded = range
            lit = nil
        }

        func highlight(time: Double, follow: Bool) {
            guard let textView, let storage = textView.textStorage, !words.isEmpty else { return }
            let index = words.partitioningIndex { $0.end > time }
            let current = index < words.count && words[index].start <= time + 0.05 ? index : nil
            guard current != lit else { return }
            storage.beginEditing()
            if let lit, lit < ranges.count { storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: ranges[lit]) }
            if let current { storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: ranges[current]) }
            storage.endEditing()
            lit = current
            if follow, let current, Date().timeIntervalSince(lastUserScroll) > 3 {
                textView.scrollRangeToVisible(ranges[current])
            }
        }

        @objc func clicked(_ gesture: NSClickGestureRecognizer) {
            guard let textView, textView.selectedRange().length == 0 else { return }
            let point = gesture.location(in: textView)
            let character = textView.characterIndexForInsertion(at: point)
            if let index = ranges.firstIndex(where: { NSLocationInRange(character, $0) || NSMaxRange($0) == character }) {
                lastUserScroll = .distantPast
                parent.seek(words[index].start)
            }
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView else { return }
            let selection = textView.selectedRange()
            guard selection.length > 0,
                  let first = ranges.firstIndex(where: { NSMaxRange($0) > selection.location }),
                  let last = ranges.lastIndex(where: { $0.location < NSMaxRange(selection) }), first <= last
            else {
                parent.selectionChanged(nil)
                return
            }
            lastUserScroll = Date()
            parent.selectionChanged(words[first].start...words[last].end)
        }
    }
}

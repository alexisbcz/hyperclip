import AppKit

/// How captions look. Sizes are for a 1080-pixel-wide frame and scale with the export.
nonisolated struct CaptionStyle: Sendable, Equatable {
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case bold, clean, boxed, pop, none

        var id: String { rawValue }

        var name: String {
            switch self {
            case .bold: "Bold"
            case .clean: "Clean"
            case .boxed: "Boxed"
            case .pop: "One word"
            case .none: "No captions"
            }
        }

        var summary: String {
            switch self {
            case .bold: "Heavy outlined words, the current one in color."
            case .clean: "Light text with a soft shadow."
            case .boxed: "White text on a dark box."
            case .pop: "One big word at a time."
            case .none: "Export without captions."
            }
        }
    }

    var preset: Preset
    var font: String
    var size: Double
    var wordsPerPage: Int
    var uppercase: Bool
    var highlight: NSColor
    /// From the top of the frame (0) to the bottom (1), where the middle of the captions sits.
    var position: Double

    static var current: CaptionStyle {
        let preset = Prefs.value(Pref.captionStyle, default: Preset.bold)
        return CaptionStyle(
            preset: preset,
            font: Prefs.string(Pref.captionFont) ?? Defaults.captionFont,
            size: Prefs.double(Pref.captionSize, default: Defaults.captionSize),
            wordsPerPage: preset == .pop ? 1 : max(1, Prefs.int(Pref.captionWords, default: Defaults.captionWords)),
            uppercase: Prefs.bool(Pref.captionUppercase, default: true),
            highlight: NSColor(hex: Prefs.string(Pref.captionHighlight) ?? Defaults.captionHighlight) ?? .systemYellow,
            position: Prefs.double(Pref.captionPosition, default: Defaults.captionPosition)
        )
    }

    var isVisible: Bool { preset != .none }

    /// The font at a size, heavy for Bold and One word, falling back to the system's when the family is missing.
    func nsFont(size: CGFloat) -> NSFont {
        let weight: NSFont.Weight = preset == .clean || preset == .boxed ? .semibold : .heavy
        // The family's upright, normal-width face closest to the weight (AppKit's 0–15 scale: 8 semibold, 11 heavy).
        let target = weight == .heavy ? 11 : 8
        let unwanted = NSFontTraitMask([.italicFontMask, .condensedFontMask, .narrowFontMask, .compressedFontMask]).rawValue
        let faces = (NSFontManager.shared.availableMembers(ofFontFamily: font) ?? []).compactMap { member -> (name: String, weight: Int)? in
            guard member.count >= 4, let name = member[0] as? String, let weight = (member[2] as? NSNumber)?.intValue,
                  let traits = (member[3] as? NSNumber)?.uintValue, traits & unwanted == 0 else { return nil }
            return (name, weight)
        }
        if let face = faces.min(by: { abs($0.weight - target) * 2 + ($0.weight < target ? 1 : 0) < abs($1.weight - target) * 2 + ($1.weight < target ? 1 : 0) }),
           let match = NSFont(name: face.name, size: size) {
            return match
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    /// The caption page as styled text, with the word at `active` highlighted.
    func attributed(_ page: CaptionPage, active: Int?, scale: CGFloat) -> NSAttributedString {
        let font = nsFont(size: CGFloat(size) * scale * (preset == .pop ? 1.35 : 1))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 0.95
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .paragraphStyle: paragraph]
        let text = NSMutableAttributedString()
        for (index, word) in page.words.enumerated() {
            var attributes = base
            if index == active { attributes[.foregroundColor] = highlight }
            if index > 0 { text.append(NSAttributedString(string: " ", attributes: base)) }
            text.append(NSAttributedString(string: display(word.text), attributes: attributes))
        }
        return text
    }

    /// The page drawn into an image, box and shadow included, so the export and the preview show exactly the same pixels.
    /// `pixels` is the image's pixels per point.
    func render(_ page: CaptionPage, active: Int?, scale: CGFloat, maxWidth: CGFloat, pixels: CGFloat = 1) -> CGImage? {
        let text = attributed(page, active: active, scale: scale)
        let bounds = text.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
        // Room for the outline and shadow, or the box's padding.
        let padding = (preset == .boxed ? 24 : 16) * scale
        let textSize = CGSize(width: ceil(bounds.width) + 2, height: ceil(bounds.height))
        let size = CGSize(width: textSize.width + padding * 2, height: textSize.height + padding * 2)
        guard size.width > 1, let context = CGContext(data: nil, width: Int(size.width * pixels), height: Int(size.height * pixels), bitsPerComponent: 8,
                                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: pixels, y: pixels)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        if preset == .boxed {
            NSColor.black.withAlphaComponent(0.72).setFill()
            NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 18 * scale, yRadius: 18 * scale).fill()
        } else {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(preset == .clean ? 0.85 : 0.5)
            shadow.shadowBlurRadius = (preset == .clean ? 10 : 6) * scale
            shadow.shadowOffset = CGSize(width: 0, height: -(preset == .clean ? 3 : 4) * scale)
            shadow.set()
        }
        let rect = CGRect(origin: CGPoint(x: padding, y: padding), size: textSize)
        if preset == .bold || preset == .pop {
            // The outline first, then the letters over it, so the outline thickens them instead of eating into them.
            let outline = NSMutableAttributedString(attributedString: text)
            outline.addAttributes([.strokeColor: NSColor.black, .strokeWidth: 22.0, .foregroundColor: NSColor.clear],
                                  range: NSRange(location: 0, length: outline.length))
            outline.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
            NSShadow().set()
        }
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    func display(_ word: String) -> String {
        var word = word
        if preset == .bold || preset == .pop {
            while let last = word.last, ",.;:".contains(last) { word.removeLast() }
        }
        return uppercase ? word.uppercased() : word
    }
}

/// A few words shown together, with times relative to the clip's start.
nonisolated struct CaptionPage: Sendable, Hashable {
    var words: [Word]
    var start: Double
    var end: Double

    /// Which word is being said at `time`, holding the last one until the page ends.
    func activeWord(at time: Double) -> Int? {
        guard time >= start, time < end else { return nil }
        return words.lastIndex { $0.start <= time } ?? 0
    }

    /// Splits a clip's words into pages: a few words each, breaking early at the end of a sentence or a pause.
    static func pages(for words: some Collection<Word>, clip: Clip, perPage: Int) -> [CaptionPage] {
        let shifted = words.map { Word(text: $0.text, start: max(0, $0.start - clip.start), end: max(0, $0.end - clip.start)) }
        var pages: [CaptionPage] = []
        var current: [Word] = []
        for (index, word) in shifted.enumerated() {
            current.append(word)
            let next = index + 1 < shifted.count ? shifted[index + 1] : nil
            let ends = word.text.last.map { ".!?…,".contains($0) } ?? false
            let paused = next.map { $0.start - word.end > 0.6 } ?? true
            if current.count >= perPage || ends || paused {
                pages.append(CaptionPage(words: current, start: current[0].start, end: word.end))
                current = []
            }
        }
        // Each page stays up until the next one, or briefly after its last word.
        for index in pages.indices {
            let limit = index + 1 < pages.count ? pages[index + 1].start : clip.duration
            pages[index].end = min(limit, pages[index].end + 0.4)
            if index + 1 < pages.count, pages[index + 1].start - pages[index].end < 0.25 { pages[index].end = pages[index + 1].start }
        }
        return pages
    }
}

extension NSColor {
    nonisolated convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    nonisolated var hex: String {
        guard let color = usingColorSpace(.sRGB) else { return "#FFFFFF" }
        return String(format: "#%02X%02X%02X", Int(color.redComponent * 255), Int(color.greenComponent * 255), Int(color.blueComponent * 255))
    }
}

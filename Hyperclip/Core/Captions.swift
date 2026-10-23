import AppKit

/// How captions look. Sizes are for a 1080-pixel-wide frame and scale with the export.
/// A preset is a starting point: picking one sets every other value, which can then be changed one by one.
nonisolated struct CaptionStyle: Sendable, Equatable {
    enum Preset: String, CaseIterable, Identifiable, Sendable {
        case bold, clean, boxed, pop, karaoke, none

        var id: String { rawValue }

        var name: String {
            switch self {
            case .bold: "Bold"
            case .clean: "Clean"
            case .boxed: "Boxed"
            case .pop: "One word"
            case .karaoke: "Highlight box"
            case .none: "No captions"
            }
        }

        var summary: String {
            switch self {
            case .bold: "Heavy outlined words, the current one in color."
            case .clean: "Light text with a soft shadow."
            case .boxed: "White text on a dark box."
            case .pop: "One big word at a time."
            case .karaoke: "A colored box slides under the word being said."
            case .none: "Export without captions."
            }
        }
    }

    /// How the word being said stands out.
    enum HighlightMode: String, CaseIterable, Identifiable, Sendable {
        case color, box, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .color: "Colored text"
            case .box: "Box behind it"
            case .none: "Not at all"
            }
        }
    }

    enum Weight: String, CaseIterable, Identifiable, Sendable {
        case regular, medium, semibold, bold, heavy, black
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        /// AppKit's 0–15 weight scale, for picking a family's face.
        var appKit: Int { [5, 6, 8, 9, 11, 12][Self.allCases.firstIndex(of: self)!] }
        var system: NSFont.Weight { [.regular, .medium, .semibold, .bold, .heavy, .black][Self.allCases.firstIndex(of: self)!] }
    }

    var preset: Preset
    var font: String
    var weight: Weight
    var size: Double
    var wordsPerPage: Int
    var uppercase: Bool
    /// Keeps commas and full stops; off, they're dropped, as most shorts do.
    var punctuation: Bool
    var color: NSColor
    var highlight: NSColor
    var highlightMode: HighlightMode
    /// Outline thickness, as a percentage of the font size; 0 for none.
    var outline: Double
    var outlineColor: NSColor
    var shadow: Bool
    /// A box behind the whole caption.
    var background: Bool
    var backgroundColor: NSColor
    var backgroundOpacity: Double
    /// From the top of the frame (0) to the bottom (1), where the middle of the captions sits.
    var position: Double
    /// Each caption pops in.
    var animate: Bool

    /// Every caption setting with its value under each preset, by preference key.
    static func template(_ preset: Preset) -> [String: Any] {
        var values: [String: Any] = [
            Pref.captionWeight: Weight.heavy.rawValue, Pref.captionWords: 3, Pref.captionUppercase: true, Pref.captionPunctuation: false,
            Pref.captionColor: "#FFFFFF", Pref.captionHighlight: Defaults.captionHighlight, Pref.captionHighlightMode: HighlightMode.color.rawValue,
            Pref.captionOutline: 22.0, Pref.captionOutlineColor: "#000000", Pref.captionShadow: true,
            Pref.captionBackground: false, Pref.captionBackgroundColor: "#000000", Pref.captionBackgroundOpacity: 0.72, Pref.captionAnimate: true,
        ]
        switch preset {
        case .bold, .none:
            break
        case .clean:
            values[Pref.captionWeight] = Weight.semibold.rawValue
            values[Pref.captionUppercase] = false
            values[Pref.captionPunctuation] = true
            values[Pref.captionOutline] = 0.0
            values[Pref.captionWords] = 5
            values[Pref.captionAnimate] = false
        case .boxed:
            values[Pref.captionWeight] = Weight.semibold.rawValue
            values[Pref.captionUppercase] = false
            values[Pref.captionPunctuation] = true
            values[Pref.captionOutline] = 0.0
            values[Pref.captionShadow] = false
            values[Pref.captionBackground] = true
            values[Pref.captionWords] = 4
        case .pop:
            values[Pref.captionWords] = 1
            values[Pref.captionWeight] = Weight.black.rawValue
        case .karaoke:
            values[Pref.captionHighlightMode] = HighlightMode.box.rawValue
            values[Pref.captionHighlight] = "#7C3AED"
            values[Pref.captionOutline] = 0.0
            values[Pref.captionWeight] = Weight.black.rawValue
        }
        return values
    }

    /// Sets every caption setting to the preset's.
    static func apply(_ preset: Preset) {
        let defaults = UserDefaults.standard
        defaults.set(preset.rawValue, forKey: Pref.captionStyle)
        for (key, value) in template(preset) { defaults.set(value, forKey: key) }
    }

    static var current: CaptionStyle { make(Prefs.value(Pref.captionStyle, default: Preset.bold), saved: true) }

    /// A preset's look, with your changes to it when `saved`; font, size and position are always yours.
    static func make(_ preset: Preset, saved: Bool) -> CaptionStyle {
        let template = template(preset)
        func stored(_ key: String) -> Bool { saved && UserDefaults.standard.object(forKey: key) != nil }
        func color(_ key: String) -> NSColor {
            NSColor(hex: (stored(key) ? Prefs.string(key) : nil) ?? template[key] as? String ?? "#FFFFFF") ?? .white
        }
        func flag(_ key: String) -> Bool { stored(key) ? Prefs.bool(key, default: false) : template[key] as? Bool ?? false }
        func number(_ key: String) -> Double { stored(key) ? Prefs.double(key, default: 0) : template[key] as? Double ?? Double(template[key] as? Int ?? 0) }
        func text(_ key: String) -> String { (stored(key) ? Prefs.string(key) : nil) ?? template[key] as? String ?? "" }
        return CaptionStyle(
            preset: preset,
            font: Prefs.string(Pref.captionFont) ?? Defaults.captionFont,
            weight: Weight(rawValue: text(Pref.captionWeight)) ?? .heavy,
            size: Prefs.double(Pref.captionSize, default: Defaults.captionSize),
            wordsPerPage: max(1, Int(number(Pref.captionWords))),
            uppercase: flag(Pref.captionUppercase),
            punctuation: flag(Pref.captionPunctuation),
            color: color(Pref.captionColor),
            highlight: color(Pref.captionHighlight),
            highlightMode: HighlightMode(rawValue: text(Pref.captionHighlightMode)) ?? .color,
            outline: number(Pref.captionOutline),
            outlineColor: color(Pref.captionOutlineColor),
            shadow: flag(Pref.captionShadow),
            background: flag(Pref.captionBackground),
            backgroundColor: color(Pref.captionBackgroundColor),
            backgroundOpacity: number(Pref.captionBackgroundOpacity),
            position: Prefs.double(Pref.captionPosition, default: Defaults.captionPosition),
            animate: flag(Pref.captionAnimate)
        )
    }

    var isVisible: Bool { preset != .none }

    /// Changes whenever anything about the look does, for redrawing previews.
    var signature: String {
        "\(preset.rawValue)|\(font)|\(weight.rawValue)|\(size)|\(wordsPerPage)|\(uppercase)|\(punctuation)|\(color.hex)|\(highlight.hex)|\(highlightMode.rawValue)|\(outline)|\(outlineColor.hex)|\(shadow)|\(background)|\(backgroundColor.hex)|\(backgroundOpacity)|\(position)|\(animate)"
    }

    /// The family's upright, normal-width face closest to the weight, or the system font when the family is missing.
    func nsFont(size: CGFloat) -> NSFont {
        let unwanted = NSFontTraitMask([.italicFontMask, .condensedFontMask, .narrowFontMask, .compressedFontMask]).rawValue
        let faces = (NSFontManager.shared.availableMembers(ofFontFamily: font) ?? []).compactMap { member -> (name: String, weight: Int)? in
            guard member.count >= 4, let name = member[0] as? String, let weight = (member[2] as? NSNumber)?.intValue,
                  let traits = (member[3] as? NSNumber)?.uintValue, traits & unwanted == 0 else { return nil }
            return (name, weight)
        }
        let target = weight.appKit
        if let face = faces.min(by: { abs($0.weight - target) * 2 + ($0.weight < target ? 1 : 0) < abs($1.weight - target) * 2 + ($1.weight < target ? 1 : 0) }),
           let match = NSFont(name: face.name, size: size) {
            return match
        }
        return .systemFont(ofSize: size, weight: weight.system)
    }

    /// The caption page as styled text, with the word at `active` highlighted.
    func attributed(_ page: CaptionPage, active: Int?, scale: CGFloat) -> NSAttributedString {
        let font = nsFont(size: CGFloat(size) * scale * (wordsPerPage == 1 ? 1.35 : 1))
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineHeightMultiple = 0.95
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        let text = NSMutableAttributedString()
        for (index, word) in page.words.enumerated() {
            var attributes = base
            if index == active, highlightMode == .color { attributes[.foregroundColor] = highlight }
            if index > 0 { text.append(NSAttributedString(string: " ", attributes: base)) }
            text.append(NSAttributedString(string: display(word.text), attributes: attributes))
        }
        return text
    }

    /// Where each word sits in the attributed page, as character ranges.
    private func wordRanges(_ page: CaptionPage) -> [NSRange] {
        var location = 0
        return page.words.enumerated().map { index, word in
            if index > 0 { location += 1 }
            let length = (display(word.text) as NSString).length
            defer { location += length }
            return NSRange(location: location, length: length)
        }
    }

    /// The page drawn into an image, box and shadow included, so the export and the preview show exactly the same pixels.
    /// `pixels` is the image's pixels per point. One TextKit layout measures, places the highlight box and draws,
    /// so they always agree on where the lines break.
    func render(_ page: CaptionPage, active: Int?, scale: CGFloat, maxWidth: CGFloat, pixels: CGFloat = 1) -> CGImage? {
        let text = attributed(page, active: active, scale: scale)
        let storage = NSTextStorage(attributedString: text)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
        let glyphs = layout.glyphRange(for: container)
        let used = layout.usedRect(for: container)

        // Room for the outline, the shadow and the boxes.
        let padding = (background ? 24 : 16) * scale + CGFloat(outline) * 0.012 * CGFloat(size) * scale
        let size = CGSize(width: ceil(used.width) + padding * 2, height: ceil(used.height) + padding * 2)
        guard size.width > 1, size.height > 1,
              let context = CGContext(data: nil, width: Int(size.width * pixels), height: Int(size.height * pixels), bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // Top-left origin, as TextKit lays out.
        context.scaleBy(x: pixels, y: pixels)
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let origin = CGPoint(x: padding - used.minX, y: padding - used.minY)

        if background {
            backgroundColor.withAlphaComponent(backgroundOpacity).setFill()
            NSBezierPath(roundedRect: CGRect(origin: .zero, size: size), xRadius: 18 * scale, yRadius: 18 * scale).fill()
        }

        if highlightMode == .box, let active, active < page.words.count {
            let range = layout.glyphRange(forCharacterRange: wordRanges(page)[active], actualCharacterRange: nil)
            let inset = 0.14 * CGFloat(self.size) * scale
            highlight.setFill()
            // The word's own rectangles, one per line it spans, without the space before it.
            layout.enumerateEnclosingRects(forGlyphRange: range, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { rect, _ in
                let word = rect.offsetBy(dx: origin.x, dy: origin.y)
                NSBezierPath(roundedRect: word.insetBy(dx: -inset, dy: -inset * 0.35), xRadius: inset, yRadius: inset).fill()
            }
        }

        if shadow, !background {
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(outline > 0 ? 0.5 : 0.85)
            shadow.shadowBlurRadius = (outline > 0 ? 6 : 10) * scale
            shadow.shadowOffset = CGSize(width: 0, height: -(outline > 0 ? 4 : 3) * scale)
            shadow.set()
        }
        if outline > 0 {
            // The outline first, then the letters over it, so the outline thickens them instead of eating into them.
            let whole = NSRange(location: 0, length: storage.length)
            let fills = (0..<storage.length).map { storage.attribute(.foregroundColor, at: $0, effectiveRange: nil) }
            storage.addAttributes([.strokeColor: outlineColor, .strokeWidth: outline, .foregroundColor: NSColor.clear], range: whole)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            storage.removeAttribute(.strokeWidth, range: whole)
            for (index, fill) in fills.enumerated() { storage.addAttribute(.foregroundColor, value: fill ?? color, range: NSRange(location: index, length: 1)) }
            NSShadow().set()
        }
        layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
        NSGraphicsContext.restoreGraphicsState()
        return context.makeImage()
    }

    func display(_ word: String) -> String {
        var word = word
        if !punctuation {
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

import AppKit

/// The attribute keys the highlighter owns. It removes / overwrites only
/// these, so the paragraph style EditorController sets for tab stops (and
/// anything else other components add) survives re-highlighting.
enum HighlightAttributes {
    static let managedKeys: [NSAttributedString.Key] = [.font, .foregroundColor, .backgroundColor, .strikethroughStyle]
}

/// Appearance-adaptive colors for Markdown source. Each is resolved at draw
/// time, so switching between light and dark mode needs no re-highlight.
@MainActor
enum HighlightPalette {
    static let marker = NSColor.adaptive(light: 0xA2A2AA, dark: 0x6E6E78)
    static let heading = NSColor.adaptive(light: 0x1B5BB8, dark: 0x6CB2FF)
    static let inlineCode = NSColor.adaptive(light: 0xB0306A, dark: 0xF08DBC)
    static let inlineCodeBackground = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.08) : NSColor(white: 0, alpha: 0.05)
    }
    static let codeBlockBackground = NSColor(name: nil) { appearance in
        appearance.isDark ? NSColor(white: 1, alpha: 0.05) : NSColor(white: 0, alpha: 0.035)
    }
    static let fenceInfo = NSColor.adaptive(light: 0x8A5A00, dark: 0xE5B567)
    static let link = NSColor.adaptive(light: 0x0B63CE, dark: 0x5AA9FF)
    static let url = NSColor.adaptive(light: 0x7B7F87, dark: 0x8E949C)
    static let image = NSColor.adaptive(light: 0x7A3EB1, dark: 0xC79BFF)
    static let linkTitle = NSColor.adaptive(light: 0xA0522D, dark: 0xD8A07A)
    static let quoteMarker = NSColor.adaptive(light: 0x5F9E6E, dark: 0x7FBF8E)
    static let listMarker = NSColor.adaptive(light: 0xC2610C, dark: 0xF0A050)
    static let html = NSColor.adaptive(light: 0x8F4A1E, dark: 0xE09A6B)
    static let frontMatterKey = NSColor.adaptive(light: 0x6C3FB5, dark: 0xB79CFF)
    static let math = NSColor.adaptive(light: 0x0B7A75, dark: 0x5FD3C8)
    static let mathCommand = NSColor.adaptive(light: 0x075E9C, dark: 0x8BD0FF)

    private static var tokenColors: [TokenKind: NSColor] = [:]

    /// The tokenizer colors used by the preview, as one adaptive color.
    static func token(_ kind: TokenKind) -> NSColor? {
        if let cached = tokenColors[kind] { return cached }
        guard let light = kind.lightColor, let dark = kind.darkColor else { return nil }
        let color = NSColor(name: nil) { $0.isDark ? dark : light }
        tokenColors[kind] = color
        return color
    }
}

extension NSColor {
    static func adaptive(light: UInt32, dark: UInt32) -> NSColor {
        let light = NSColor(hex: light)
        let dark = NSColor(hex: dark)
        return NSColor(name: nil) { $0.isDark ? dark : light }
    }
}

extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// Fonts and attribute dictionaries for one base font. Dictionaries are
/// built once per style and shared, which keeps highlighting allocation-free
/// in the hot loop.
@MainActor
final class HighlightTheme {
    let baseFont: NSFont
    let baseAttributes: [NSAttributedString.Key: Any]
    private var fonts: [FontTraits: NSFont] = [:]
    private var cache: [SpanStyle: [NSAttributedString.Key: Any]] = [:]

    init(baseFont: NSFont) {
        self.baseFont = baseFont
        baseAttributes = [.font: baseFont, .foregroundColor: NSColor.textColor]
    }

    /// The base font with bold and/or italic. Headings stay at the base size
    /// so columns keep aligning in the monospaced editor.
    func font(_ traits: FontTraits) -> NSFont {
        if traits.isEmpty { return baseFont }
        if let font = fonts[traits] { return font }
        var symbolic = baseFont.fontDescriptor.symbolicTraits
        if traits.contains(.bold) { symbolic.insert(.bold) }
        if traits.contains(.italic) { symbolic.insert(.italic) }
        let descriptor = baseFont.fontDescriptor.withSymbolicTraits(symbolic)
        let font = NSFont(descriptor: descriptor, size: baseFont.pointSize) ?? baseFont
        fonts[traits] = font
        return font
    }

    func attributes(for style: SpanStyle) -> [NSAttributedString.Key: Any] {
        if let cached = cache[style] { return cached }
        let attributes = makeAttributes(style)
        cache[style] = attributes
        return attributes
    }

    private func makeAttributes(_ style: SpanStyle) -> [NSAttributedString.Key: Any] {
        typealias P = HighlightPalette
        switch style {
        case .marker: return [.foregroundColor: P.marker]
        case .heading: return [.foregroundColor: P.heading, .font: font(.bold)]
        case .font(let traits): return [.font: font(traits)]
        case .strikethrough:
            return [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .foregroundColor: NSColor.secondaryLabelColor]
        case .inlineCode: return [.foregroundColor: P.inlineCode, .backgroundColor: P.inlineCodeBackground]
        case .codeBlock: return [.backgroundColor: P.codeBlockBackground]
        case .fenceInfo: return [.foregroundColor: P.fenceInfo]
        case .link: return [.foregroundColor: P.link]
        case .url: return [.foregroundColor: P.url]
        case .image: return [.foregroundColor: P.image]
        case .linkTitle: return [.foregroundColor: P.linkTitle]
        case .quote: return [.foregroundColor: NSColor.secondaryLabelColor]
        case .quoteMarker: return [.foregroundColor: P.quoteMarker]
        case .listMarker, .taskBox: return [.foregroundColor: P.listMarker]
        case .html: return [.foregroundColor: P.html]
        case .comment: return [.foregroundColor: P.token(.comment) ?? P.marker]
        case .frontMatterKey: return [.foregroundColor: P.frontMatterKey]
        case .frontMatterValue: return [.foregroundColor: NSColor.secondaryLabelColor]
        case .math: return [.foregroundColor: P.math]
        case .mathCommand: return [.foregroundColor: P.mathCommand]
        case .token(let kind): return P.token(kind).map { [.foregroundColor: $0] } ?? [:]
        case .mermaidKeyword: return [.foregroundColor: P.token(.keyword) ?? P.heading]
        case .mermaidArrow: return [.foregroundColor: P.listMarker]
        case .mermaidText: return [.foregroundColor: P.token(.string) ?? P.link]
        }
    }
}

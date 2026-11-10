import AppKit

/// Classification of a source-code token. Output-agnostic: the HTML renderer
/// maps kinds to CSS classes, the PDF renderer to Core Text foreground colors.
enum TokenKind: Sendable {
    case plain
    case keyword
    case string
    case comment
    case number
    case preprocessor
}

struct Token: Sendable {
    var kind: TokenKind
    var text: String
}

/// A minimal lexer for one language. Implementations know nothing about
/// output formats — one tokenizer, two renderers.
protocol LanguageTokenizer: Sendable {
    func tokenize(_ code: String) -> [Token]
}

/// Maps fence info strings (`csharp`, `js`, …) to tokenizers.
/// Adding a language = writing one tokenizer type + one `register` call below.
enum SyntaxHighlighting {
    static let registry: [String: any LanguageTokenizer] = {
        var map: [String: any LanguageTokenizer] = [:]
        func register(_ aliases: [String], _ tokenizer: any LanguageTokenizer) {
            for alias in aliases { map[alias] = tokenizer }
        }
        register(["csharp", "cs", "c#"], CSharpTokenizer())
        register(["javascript", "js", "jsx"], JavaScriptTokenizer())
        register(["typescript", "ts", "tsx"], TypeScriptTokenizer())
        register(["python", "py"], PythonTokenizer())
        return map
    }()

    static func tokenizer(for language: String?) -> (any LanguageTokenizer)? {
        guard let language else { return nil }
        guard let first = language.split(separator: " ").first else { return nil }
        return registry[first.lowercased()]
    }
}

/// Accumulates tokens, merging consecutive plain characters into one token.
struct TokenBuilder {
    private var tokens: [Token] = []
    private var plainBuffer = ""

    mutating func plain(_ character: Character) {
        plainBuffer.append(character)
    }

    mutating func plain(_ text: String) {
        plainBuffer += text
    }

    mutating func emit(_ kind: TokenKind, _ text: String) {
        flush()
        tokens.append(Token(kind: kind, text: text))
    }

    mutating func finish() -> [Token] {
        flush()
        return tokens
    }

    private mutating func flush() {
        guard !plainBuffer.isEmpty else { return }
        tokens.append(Token(kind: .plain, text: plainBuffer))
        plainBuffer = ""
    }
}

// MARK: - Shared token colors (Xcode-like, light + dark)

extension TokenKind {
    /// CSS class emitted by `HtmlRenderer`; nil for plain text.
    var cssClass: String? {
        switch self {
        case .plain: nil
        case .keyword: "tok-keyword"
        case .string: "tok-string"
        case .comment: "tok-comment"
        case .number: "tok-number"
        case .preprocessor: "tok-preprocessor"
        }
    }

    /// Light-appearance color — single source of truth shared by the HTML
    /// preview CSS and the PDF renderer.
    var lightColor: NSColor? {
        switch self {
        case .plain: nil
        case .keyword: NSColor(hex: 0xAD3DA4)
        case .string: NSColor(hex: 0xC41A16)
        case .comment: NSColor(hex: 0x007400)
        case .number: NSColor(hex: 0x1C00CF)
        case .preprocessor: NSColor(hex: 0x643820)
        }
    }

    var darkColor: NSColor? {
        switch self {
        case .plain: nil
        case .keyword: NSColor(hex: 0xFC5FA3)
        case .string: NSColor(hex: 0xFC6A5D)
        case .comment: NSColor(hex: 0x7F8C98)
        case .number: NSColor(hex: 0xD0BF69)
        case .preprocessor: NSColor(hex: 0xFDB37B)
        }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255.0,
            green: CGFloat((hex >> 8) & 0xFF) / 255.0,
            blue: CGFloat(hex & 0xFF) / 255.0,
            alpha: 1
        )
    }

    var cssHex: String {
        let color = usingColorSpace(.sRGB) ?? self
        return String(
            format: "#%02x%02x%02x",
            Int(round(color.redComponent * 255)),
            Int(round(color.greenComponent * 255)),
            Int(round(color.blueComponent * 255))
        )
    }
}

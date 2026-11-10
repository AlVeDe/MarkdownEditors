import Foundation

/// One LaTeX command offered by the completion popup, as stored in
/// `Resources/latex-commands.json`.
///
/// The catalog lives in JSON rather than in Swift literals because it is
/// pure data — ~460 entries whose snippets are full of backslashes — and is
/// far easier to review, extend and validate (see `LatexCatalogTests`) as a
/// table. Every command in it renders with the bundled MathJax
/// (`tex-svg-full.js`, all TeX packages enabled); commands MathJax does not
/// know (`\pounds`, `\P`, …) are deliberately left out so a completion can
/// never insert something the preview then shows as an error.
struct LatexCommand: Decodable, Sendable, Equatable {
    /// The command name without the backslash (`alpha`, `left(`). What the
    /// popup matches the typed text against.
    let name: String
    /// Snippet that replaces `\` + the typed prefix, in the
    /// `CompletionItem.insertText` syntax (`${1:default}`, `$0`, `\$`).
    let insertText: String
    /// Coarse grouping shown in the popup ("Greek", "Relation", …).
    let category: String
    /// One-line explanation for the documentation panel.
    let description: String
    /// Unicode approximation of the rendered symbol, if there is one.
    let glyph: String?
    /// Label override for entries whose snippet differs from the plain name
    /// (`\sqrt[n]{…}` next to `\sqrt`).
    let label: String?
    /// The MathJax extension providing the command, when it is not in core
    /// TeX/AMS. All of them ship in the bundled `tex-svg-full.js`.
    let requires: String?
    /// Extra rank for everyday commands (`\frac`, `\alpha`).
    let priority: Int?

    /// What the popup lists: the backslash form, or the explicit label.
    var displayLabel: String { label ?? "\\" + name }

    /// True for commands that only stand for a glyph (Greek letters,
    /// relations, arrows) as opposed to commands that take arguments or
    /// change formatting — drives the icon in the popup.
    var isSymbol: Bool { glyph != nil && insertText == "\\" + name }
}

/// A LaTeX environment usable inside MathJax display math
/// (`\begin{pmatrix} … \end{pmatrix}`).
struct LatexEnvironment: Decodable, Sendable, Equatable {
    let name: String
    let description: String
    /// Snippet for a mandatory argument right after `\begin{name}`
    /// (`{${1:cc}}` for `array`), if the environment takes one.
    let argument: String?

    /// The body placeholder's number: after the argument's placeholders.
    private var bodyPlaceholder: Int { argument == nil ? 1 : 2 }

    /// Snippet that completes `\begin{` + typed prefix: the rest of the name,
    /// the argument, an indented body line and the matching `\end{…}`.
    ///
    /// - Parameter closingBraceFollows: the caret sits right before a `}`
    ///   (inserted by brace auto-pairing). The snippet then ends with
    ///   `\end{name` and lets that existing brace close it, so no stray `}`
    ///   is left behind and nothing has to be deleted after the caret.
    func beginSnippet(closingBraceFollows: Bool = false) -> String {
        let body = "}\(argument ?? "")\n\t${\(bodyPlaceholder)}\n\\end{\(name)"
        return name + body + (closingBraceFollows ? "" : "}")
    }

    /// The full `\begin{name} … \end{name}` snippet offered when `\begin`
    /// is typed as a command.
    var fullSnippet: String { "\\begin{" + beginSnippet() }
}

/// The command and environment tables, loaded once from the bundle.
struct LatexCatalog: Decodable, Sendable {
    let commands: [LatexCommand]
    let environments: [LatexEnvironment]

    static let empty = LatexCatalog(commands: [], environments: [])

    /// The bundled catalog. Falls back to an empty table (no completions,
    /// but no crash) if the resource is missing or malformed — the tests
    /// make sure it is neither.
    static let shared: LatexCatalog = (try? load()) ?? .empty

    static func load(from bundle: Bundle = .resources) throws -> LatexCatalog {
        guard let url = bundle.url(forResource: "latex-commands", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode(LatexCatalog.self, from: Data(contentsOf: url))
    }
}

/// The letter-style font commands whose argument is usually a single
/// capital (`\mathbb{R}`), with the Unicode Mathematical Alphanumeric
/// Symbols used to preview each letter in the popup.
enum LatexLetterFont: String, CaseIterable, Sendable {
    case mathbb, mathcal, mathscr, mathfrak

    /// Previewed letters (A–Z).
    static let letters: [Character] = (UInt8(ascii: "A")...UInt8(ascii: "Z")).map { Character(UnicodeScalar($0)) }

    /// Letters common enough in this font to rank first (number sets for
    /// `\mathbb`).
    var commonLetters: Set<Character> {
        switch self {
        case .mathbb: ["R", "N", "Z", "Q", "C"]
        case .mathcal: ["O", "L", "F"]
        case .mathscr, .mathfrak: []
        }
    }

    /// The Unicode character rendering `letter` in this font. Some letters
    /// predate the Mathematical Alphanumeric block and live in Letterlike
    /// Symbols instead (ℝ, ℬ, ℭ…) — their slots in the block are reserved
    /// holes, so they must be special-cased.
    func glyph(for letter: Character) -> String? {
        guard let ascii = letter.asciiValue, letter.isUppercase else { return nil }
        let exceptions: [Character: UInt32]
        let base: UInt32
        switch self {
        case .mathbb:
            base = 0x1D538
            exceptions = ["C": 0x2102, "H": 0x210D, "N": 0x2115, "P": 0x2119, "Q": 0x211A, "R": 0x211D, "Z": 0x2124]
        case .mathcal, .mathscr:
            base = 0x1D49C
            exceptions = ["B": 0x212C, "E": 0x2130, "F": 0x2131, "H": 0x210B, "I": 0x2110, "L": 0x2112, "M": 0x2133, "R": 0x211B]
        case .mathfrak:
            base = 0x1D504
            exceptions = ["C": 0x212D, "H": 0x210C, "I": 0x2111, "R": 0x211C, "Z": 0x2128]
        }
        let value = exceptions[letter] ?? base + UInt32(ascii - UInt8(ascii: "A"))
        return UnicodeScalar(value).map { String(Character($0)) }
    }
}

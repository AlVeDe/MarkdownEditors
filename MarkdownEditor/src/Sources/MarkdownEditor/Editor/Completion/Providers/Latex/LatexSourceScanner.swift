import Foundation

/// Small backwards scans over LaTeX source around the caret, on UTF-16
/// offsets so the ranges plug straight into `NSString`/`NSTextView`.
///
/// They are deliberately local (a few characters back from the caret, or
/// one formula): completion runs on every keystroke and must not re-parse
/// the document.
enum LatexSourceScanner {
    private static let backslash = UInt16(UInt8(ascii: "\\"))
    private static let openBrace = UInt16(UInt8(ascii: "{"))
    private static let closeBrace = UInt16(UInt8(ascii: "}"))
    private static let star = UInt16(UInt8(ascii: "*"))

    /// TeX control words consist of ASCII letters only.
    static func isLetter(_ unit: UInt16) -> Bool {
        (0x41...0x5A).contains(unit) || (0x61...0x7A).contains(unit)
    }

    /// Start of the run of characters satisfying `predicate` that ends at
    /// `location`.
    private static func runStart(in text: NSString, before location: Int, where predicate: (UInt16) -> Bool) -> Int {
        var start = location
        while start > 0, predicate(text.character(at: start - 1)) { start -= 1 }
        return start
    }

    /// Whether the backslash at `index` starts a control sequence, i.e. it
    /// is preceded by an even number of backslashes (`\\alpha` is a line
    /// break followed by the letters "alpha", not the command `\alpha`).
    static func startsControlSequence(_ text: NSString, backslashAt index: Int) -> Bool {
        var count = 0
        var cursor = index - 1
        while cursor >= 0, text.character(at: cursor) == backslash {
            count += 1
            cursor -= 1
        }
        return count.isMultiple(of: 2)
    }

    /// The control word being typed: from its backslash up to `location`
    /// (`\alp|` → the range of `\alp`; a lone `\|` → just the backslash).
    static func commandPrefix(in text: NSString, before location: Int) -> NSRange? {
        guard location <= text.length else { return nil }
        let lettersStart = runStart(in: text, before: location, where: isLetter)
        let slash = lettersStart - 1
        guard slash >= 0, text.character(at: slash) == backslash,
              startsControlSequence(text, backslashAt: slash)
        else { return nil }
        return NSRange(location: slash, length: location - slash)
    }

    /// The letters (no backslash) ending at `location` — the prefix an
    /// explicit ⌃Space request filters by.
    static func wordPrefix(in text: NSString, before location: Int) -> NSRange {
        let start = runStart(in: text, before: location, where: isLetter)
        return NSRange(location: start, length: location - start)
    }

    /// The caret is inside the first brace argument of a command:
    /// `\begin{ma|`, `\end{|`, `\mathbb{R|`. Returns the command's name and
    /// the range of the argument text typed so far (after the `{`).
    static func braceArgument(in text: NSString, before location: Int) -> (command: String, range: NSRange)? {
        guard location <= text.length else { return nil }
        let argumentStart = runStart(in: text, before: location) { isLetter($0) || $0 == star }
        let brace = argumentStart - 1
        guard brace >= 1, text.character(at: brace) == openBrace else { return nil }
        let nameStart = runStart(in: text, before: brace, where: isLetter)
        let slash = nameStart - 1
        guard nameStart < brace, slash >= 0, text.character(at: slash) == backslash,
              startsControlSequence(text, backslashAt: slash)
        else { return nil }
        let name = text.substring(with: NSRange(location: nameStart, length: brace - nameStart))
        return (name, NSRange(location: argumentStart, length: location - argumentStart))
    }

    /// True when the character at `location` is a `}` — typically the
    /// closing half of an auto-inserted brace pair.
    static func closingBraceFollows(in text: NSString, at location: Int) -> Bool {
        location < text.length && text.character(at: location) == closeBrace
    }

    private static let environmentPattern = try! NSRegularExpression(pattern: #"\\(begin|end)\s*\{([A-Za-z*]+)\}"#)

    /// Environments opened in `range` and not yet closed there, innermost
    /// (nearest the end of the range) last.
    ///
    /// A stray `\end{x}` that matches nothing open is ignored; one that
    /// closes an outer environment also closes everything opened inside it,
    /// which is how a user who forgot an inner `\end` would read it too.
    static func unclosedEnvironments(in text: NSString, range: NSRange) -> [String] {
        var stack: [String] = []
        environmentPattern.enumerateMatches(in: text as String, range: range) { match, _, _ in
            guard let match, startsControlSequence(text, backslashAt: match.range.location) else { return }
            let keyword = text.substring(with: match.range(at: 1))
            let name = text.substring(with: match.range(at: 2))
            if keyword == "begin" {
                stack.append(name)
            } else if let index = stack.lastIndex(of: name) {
                stack.removeSubrange(index...)
            }
        }
        return stack
    }
}

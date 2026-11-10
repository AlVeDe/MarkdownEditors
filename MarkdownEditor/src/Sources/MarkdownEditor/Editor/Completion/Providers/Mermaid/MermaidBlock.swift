import Foundation

/// The ` ```mermaid ` fence around the caret, split into lines.
///
/// The provider finds the fence itself instead of asking the highlighter:
/// the highlighter only answers "am I in mermaid?", but completion needs the
/// whole diagram (its type line and every identifier defined so far), and
/// scanning a few lines up and down is cheap.
struct MermaidBlock: Equatable {
    /// The lines between the fences, without line terminators.
    var lines: [String]
    /// Index into `lines` of the line holding the caret.
    var caretLine: Int
    /// The caret line's text before the caret.
    var caretPrefix: String
    /// The caret line's text after the caret.
    var caretSuffix: String

    /// Safety net so a runaway scan in a huge document stays cheap.
    private static let maxLines = 10_000

    /// Finds the mermaid fence enclosing `location`, or nil when the caret is
    /// not between an opening ` ```mermaid ` and its closing fence (or sits on
    /// one of the fence lines itself).
    static func find(in text: NSString, at location: Int) -> MermaidBlock? {
        let location = min(max(0, location), text.length)
        let caretRange = text.lineRange(for: NSRange(location: location, length: 0))
        let caretLineText = line(text, caretRange)
        if Fence(caretLineText) != nil { return nil }

        // Upwards to the opening fence. Any other fence on the way means the
        // caret is outside a mermaid block (that fence closes or opens
        // something else).
        var above: [String] = []
        var start = caretRange.location
        var opening: Fence?
        while start > 0, above.count < maxLines {
            let range = text.lineRange(for: NSRange(location: start - 1, length: 0))
            let candidate = line(text, range)
            if let fence = Fence(candidate) {
                guard fence.isMermaid else { return nil }
                opening = fence
                break
            }
            above.append(candidate)
            start = range.location
        }
        guard let opening else { return nil }

        // Downwards to the closing fence (or the end of the document, which
        // CommonMark treats as closing an unterminated fence).
        var below: [String] = []
        var next = NSMaxRange(caretRange)
        while next < text.length, below.count < maxLines {
            let range = text.lineRange(for: NSRange(location: next, length: 0))
            let candidate = line(text, range)
            if let fence = Fence(candidate), fence.closes(opening) { break }
            below.append(candidate)
            next = NSMaxRange(range)
        }

        let column = location - caretRange.location
        let caretNS = caretLineText as NSString
        let split = min(column, caretNS.length)
        return MermaidBlock(
            lines: above.reversed() + [caretLineText] + below,
            caretLine: above.count,
            caretPrefix: caretNS.substring(to: split),
            caretSuffix: caretNS.substring(from: split)
        )
    }

    private static func line(_ text: NSString, _ range: NSRange) -> String {
        var line = text.substring(with: range)
        while let last = line.last, last == "\n" || last == "\r" || last == "\r\n" { line.removeLast() }
        return line
    }

    /// A CommonMark fence line: up to three spaces, then three or more
    /// backticks or tildes, then an optional info string.
    struct Fence {
        var marker: Character
        var count: Int
        var info: String

        init?(_ line: String) {
            let indent = line.prefix { $0 == " " }.count
            guard indent <= 3 else { return nil }
            let rest = line.dropFirst(indent)
            guard let first = rest.first, first == "`" || first == "~" else { return nil }
            let run = rest.prefix { $0 == first }.count
            guard run >= 3 else { return nil }
            marker = first
            count = run
            info = rest.dropFirst(run).trimmingCharacters(in: .whitespaces)
        }

        var isMermaid: Bool {
            info.split(whereSeparator: { $0 == " " || $0 == "\t" }).first?.lowercased() == "mermaid"
        }

        /// A closing fence uses the same character, at least as many of
        /// them, and carries no info string.
        func closes(_ opening: Fence) -> Bool {
            marker == opening.marker && count >= opening.count && info.isEmpty
        }
    }
}

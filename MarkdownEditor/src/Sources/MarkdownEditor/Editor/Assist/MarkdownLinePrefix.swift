import Foundation

/// The structural prefix of one Markdown source line: indentation, blockquote
/// markers, a list marker and a task checkbox — everything Return continues
/// and the list commands toggle.
///
/// Parsed by hand rather than with a regex because it runs on every Return
/// and Tab, and because the pieces are needed separately (a quoted list item
/// keeps its `> ` when the list ends).
struct MarkdownLinePrefix: Equatable {
    enum ListMarker: Equatable {
        /// `-`, `*` or `+`.
        case bullet(Character)
        /// `1.` or `1)`.
        case ordered(number: Int, delimiter: Character)
    }

    /// Leading spaces and tabs.
    var indent: String = ""
    /// Blockquote markers including their spaces, e.g. `"> > "`.
    var quote: String = ""
    var marker: ListMarker?
    /// Whitespace between the list marker and the content (or checkbox).
    var markerSpacing: String = ""
    /// The checkbox state character (`" "`, `"x"` or `"X"`) of a task item.
    var task: Character?
    /// Whitespace after the checkbox.
    var taskSpacing: String = ""
    /// The text after the whole prefix.
    var content: String = ""

    var isListItem: Bool { marker != nil }
    var isTask: Bool { task != nil }
    var isQuote: Bool { !quote.isEmpty }

    /// The marker text itself (`-`, `12.`), without spacing.
    var markerText: String {
        switch marker {
        case .bullet(let character): String(character)
        case .ordered(let number, let delimiter): "\(number)\(delimiter)"
        case nil: ""
        }
    }

    /// The task box text (`[ ]`), empty for non-tasks.
    var taskText: String {
        task.map { "[\($0)]" } ?? ""
    }

    /// Everything before `content`.
    var prefix: String {
        indent + quote + markerText + markerSpacing + taskText + taskSpacing
    }

    /// UTF-16 length of `prefix` (all prefix characters are ASCII or
    /// whitespace, but stay honest about the unit).
    var prefixLength: Int { (prefix as NSString).length }

    /// The prefix the next line gets when Return continues this one: same
    /// indentation and quote, next number, unchecked box.
    var continuation: String {
        var next = indent + quote
        switch marker {
        case .bullet(let character): next += String(character)
        case .ordered(let number, let delimiter): next += "\(number + 1)\(delimiter)"
        case nil: return next
        }
        next += markerSpacing.isEmpty ? " " : markerSpacing
        if task != nil { next += "[ ]" + (taskSpacing.isEmpty ? " " : taskSpacing) }
        return next
    }

    init(line: String) {
        var rest = Substring(line)

        let indentEnd = rest.firstIndex { $0 != " " && $0 != "\t" } ?? rest.endIndex
        indent = String(rest[..<indentEnd])
        rest = rest[indentEnd...]

        // Blockquote: `>` optionally followed by one space, repeated.
        while rest.first == ">" {
            var piece = ">"
            rest = rest.dropFirst()
            if rest.first == " " || rest.first == "\t" {
                piece.append(rest.first!)
                rest = rest.dropFirst()
            }
            quote += piece
        }

        // List marker: must be followed by whitespace (so `**bold**`, `---`
        // and `1.5` are not list items).
        var afterMarker = rest
        var parsedMarker: ListMarker?
        if let first = rest.first, "-*+".contains(first) {
            afterMarker = rest.dropFirst()
            parsedMarker = .bullet(first)
        } else {
            let digits = rest.prefix { $0.isASCII && $0.isNumber }
            if (1...9).contains(digits.count),
               let delimiter = rest.dropFirst(digits.count).first, delimiter == "." || delimiter == ")",
               let number = Int(digits) {
                afterMarker = rest.dropFirst(digits.count + 1)
                parsedMarker = .ordered(number: number, delimiter: delimiter)
            }
        }
        if let parsedMarker, let next = afterMarker.first, next == " " || next == "\t" {
            marker = parsedMarker
            let spacingEnd = afterMarker.firstIndex { $0 != " " && $0 != "\t" } ?? afterMarker.endIndex
            markerSpacing = String(afterMarker[..<spacingEnd])
            rest = afterMarker[spacingEnd...]

            // Task checkbox `[ ]`, `[x]`: followed by whitespace or the end.
            let chars = Array(rest.prefix(4))
            if chars.count >= 3, chars[0] == "[", chars[2] == "]", " xX".contains(chars[1]),
               chars.count == 3 || chars[3] == " " || chars[3] == "\t" {
                task = chars[1]
                rest = rest.dropFirst(3)
                let taskSpacingEnd = rest.firstIndex { $0 != " " && $0 != "\t" } ?? rest.endIndex
                taskSpacing = String(rest[..<taskSpacingEnd])
                rest = rest[taskSpacingEnd...]
            }
        }
        content = String(rest)
    }
}

/// Cheap structural checks that do not depend on the highlighter.
enum MarkdownSource {
    /// True when the line opens or closes a fenced code block.
    static func isFenceLine(_ line: some StringProtocol) -> Bool {
        let trimmed = line.drop { $0 == " " }
        return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    /// True when `location` is inside a fenced code block or on one of its
    /// fence lines.
    ///
    /// A linear scan from the top. The highlighter answers this properly via
    /// `EditorController.context(at:)`; this fallback keeps list continuation
    /// and auto-pairs out of code even while the highlighter does not track
    /// fences, and costs microseconds for documents of normal size.
    static func isInFencedCode(_ text: NSString, at location: Int) -> Bool {
        let location = min(location, text.length)
        let currentLine = text.lineRange(for: NSRange(location: location, length: 0))
        var inside = false
        var index = 0
        while index < currentLine.location {
            let line = text.lineRange(for: NSRange(location: index, length: 0))
            if isFenceLine(text.substring(with: line)) { inside.toggle() }
            index = NSMaxRange(line)
        }
        return inside || isFenceLine(text.substring(with: currentLine))
    }
}

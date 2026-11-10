import Foundation

/// A parsed snippet: the plain text to insert plus where its tab stops are.
///
/// Syntax (a small subset of the TextMate / VS Code snippet grammar, which is
/// what completion providers write in `CompletionItem.insertText`):
///
/// - `$1`, `${1}`        an empty tab stop
/// - `${1:default}`      a tab stop pre-filled with `default` (selected when
///                       reached, so typing replaces it)
/// - `$0`, `${0}`        where the caret ends up; without one, the end of
///                       the inserted text
/// - `\$` → `$`, `\\` → `\`, and inside a default `\}` → `}`
///
/// Anything else is literal — notably a backslash before any other character
/// (`\frac` stays `\frac`, which keeps LaTeX snippets readable) and a `$` that
/// is not followed by a digit or `{digit` (so `$$` math fences need no
/// escaping). Nested placeholders are not supported; a `$` inside a default
/// is literal.
struct Snippet: Equatable {
    struct Placeholder: Equatable {
        /// The tab-stop number; 0 is the final caret position.
        var index: Int
        /// UTF-16 range within `text`.
        var range: NSRange
    }

    /// The text with all placeholder syntax removed and defaults filled in.
    var text: String
    /// In the order they appear in the text. The same index may appear more
    /// than once (a mirrored placeholder).
    var placeholders: [Placeholder]

    /// True when there is at least one numbered (non-zero) tab stop, i.e.
    /// inserting it needs a snippet session for Tab navigation.
    var hasTabStops: Bool { placeholders.contains { $0.index > 0 } }

    /// The tab-stop indices in navigation order: 1, 2, 3, … and 0 last.
    var tabStopOrder: [Int] {
        let numbered = Set(placeholders.map(\.index)).filter { $0 > 0 }.sorted()
        return numbered + [0]
    }

    /// Parses `source`. `indentation` is appended after every newline so a
    /// multi-line snippet keeps the indentation of the line it is inserted on
    /// (the provider writes it as if inserted at column 0).
    init(parsing source: String, indentation: String = "") {
        var output = ""
        var outputLength = 0 // UTF-16 length of `output`, kept incrementally
        var placeholders: [Placeholder] = []
        let chars = Array(source)
        var i = 0

        func append(_ c: Character) {
            output.append(c)
            outputLength += c.utf16.count
            if c == "\n" || c == "\r\n" {
                output += indentation
                outputLength += indentation.utf16.count
            }
        }

        /// Reads a run of ASCII digits starting at `j`.
        func digits(from j: Int) -> (value: Int, end: Int)? {
            var end = j
            while end < chars.count, chars[end].isASCII, chars[end].isNumber { end += 1 }
            guard end > j, let value = Int(String(chars[j..<end])) else { return nil }
            return (value, end)
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, chars[i + 1] == "$" || chars[i + 1] == "\\" {
                append(chars[i + 1])
                i += 2
                continue
            }
            if c == "$", i + 1 < chars.count {
                // `$1`
                if let (index, end) = digits(from: i + 1) {
                    placeholders.append(Placeholder(index: index, range: NSRange(location: outputLength, length: 0)))
                    i = end
                    continue
                }
                // `${1}` or `${1:default}`
                if chars[i + 1] == "{", let (index, end) = digits(from: i + 2), end < chars.count,
                   chars[end] == "}" || chars[end] == ":" {
                    let start = outputLength
                    var j = end
                    var closed = chars[end] == "}"
                    if !closed {
                        j += 1 // skip ':'
                        let startOutput = output
                        let startLength = outputLength
                        while j < chars.count {
                            let d = chars[j]
                            if d == "\\", j + 1 < chars.count, "$\\}".contains(chars[j + 1]) {
                                append(chars[j + 1])
                                j += 2
                            } else if d == "}" {
                                closed = true
                                break
                            } else {
                                append(d)
                                j += 1
                            }
                        }
                        if !closed {
                            // Unterminated: treat the whole thing as literal text.
                            output = startOutput
                            outputLength = startLength
                            append(c)
                            i += 1
                            continue
                        }
                    }
                    placeholders.append(Placeholder(index: index, range: NSRange(location: start, length: outputLength - start)))
                    i = j + 1
                    continue
                }
            }
            append(c)
            i += 1
        }
        self.text = output
        self.placeholders = placeholders
    }
}

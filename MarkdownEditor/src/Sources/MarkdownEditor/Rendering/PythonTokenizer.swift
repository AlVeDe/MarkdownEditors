/// Minimal Python lexer: `#` comments, single- and triple-quoted strings
/// (with `r`/`b`/`f`/`u` prefixes), numbers, keywords, and decorators
/// (colored via the preprocessor kind).
struct PythonTokenizer: LanguageTokenizer {
    private static let keywords: Set<String> = [
        "False", "None", "True", "and", "as", "assert", "async", "await",
        "break", "class", "continue", "def", "del", "elif", "else", "except",
        "finally", "for", "from", "global", "if", "import", "in", "is",
        "lambda", "match", "nonlocal", "not", "or", "pass", "raise", "return",
        "self", "try", "while", "with", "yield"
    ]

    func tokenize(_ code: String) -> [Token] {
        var builder = TokenBuilder()
        let chars = Array(code)
        let count = chars.count
        var i = 0
        var atLineStart = true

        while i < count {
            let c = chars[i]

            if c == "\n" {
                builder.plain(c)
                atLineStart = true
                i += 1
                continue
            }
            if c == " " || c == "\t" {
                builder.plain(c)
                i += 1
                continue
            }

            if c == "#" {
                let start = i
                while i < count && chars[i] != "\n" { i += 1 }
                builder.emit(.comment, String(chars[start..<i]))
                atLineStart = false
                continue
            }

            // Decorators: @name or @module.name at the start of a line.
            if atLineStart && c == "@" {
                var j = i + 1
                while j < count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == ".") {
                    j += 1
                }
                builder.emit(.preprocessor, String(chars[i..<j]))
                i = j
                atLineStart = false
                continue
            }
            atLineStart = false

            if c == "'" || c == "\"" {
                i = scanString(chars, from: i, prefixStart: i, into: &builder)
                continue
            }

            if c.isLetter || c == "_" {
                var j = i
                while j < count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") {
                    j += 1
                }
                let word = String(chars[i..<j])
                // String prefixes like r"...", f'...', rb"...".
                if word.count <= 2,
                   word.lowercased().allSatisfy({ "rbfu".contains($0) }),
                   j < count, chars[j] == "'" || chars[j] == "\"" {
                    i = scanString(chars, from: j, prefixStart: i, into: &builder)
                    continue
                }
                if Self.keywords.contains(word) {
                    builder.emit(.keyword, word)
                } else {
                    builder.plain(word)
                }
                i = j
                continue
            }

            if c.isNumber {
                var j = i
                while j < count && (chars[j].isHexDigit || "xXoObB._eEjJ".contains(chars[j])) {
                    j += 1
                }
                builder.emit(.number, String(chars[i..<j]))
                i = j
                continue
            }

            builder.plain(c)
            i += 1
        }
        return builder.finish()
    }

    /// Scans a string starting at the quote at `from`; the emitted token
    /// starts at `prefixStart` so string prefixes are colored too.
    /// Returns the index just past the string.
    private func scanString(
        _ chars: [Character],
        from quoteIndex: Int,
        prefixStart: Int,
        into builder: inout TokenBuilder
    ) -> Int {
        let count = chars.count
        let quote = chars[quoteIndex]
        let isTriple = quoteIndex + 2 < count
            && chars[quoteIndex + 1] == quote
            && chars[quoteIndex + 2] == quote

        var j = quoteIndex + (isTriple ? 3 : 1)
        while j < count {
            let ch = chars[j]
            if ch == "\\" {
                j += 2
                continue
            }
            if isTriple {
                if ch == quote && j + 2 < count + 1 && j + 1 < count && chars[j + 1] == quote && j + 2 < count && chars[j + 2] == quote {
                    j += 3
                    break
                }
            } else {
                if ch == quote {
                    j += 1
                    break
                }
                if ch == "\n" { break }
            }
            j += 1
        }
        let end = min(j, count)
        builder.emit(.string, String(chars[prefixStart..<end]))
        return end
    }
}

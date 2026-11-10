/// Minimal JavaScript lexer: keywords, `'`/`"`/template strings, comments and
/// numbers. Serves as the base for `TypeScriptTokenizer` via `extraKeywords`.
/// Approximate by design — no regex literals, no `${}` interpolation holes.
struct JavaScriptTokenizer: LanguageTokenizer {
    private static let baseKeywords: Set<String> = [
        "break", "case", "catch", "class", "const", "continue", "debugger",
        "default", "delete", "do", "else", "export", "extends", "finally",
        "for", "function", "if", "import", "in", "instanceof", "let", "new",
        "of", "return", "static", "super", "switch", "this", "throw", "try",
        "typeof", "var", "void", "while", "with", "yield", "async", "await",
        "get", "set", "true", "false", "null", "undefined", "NaN"
    ]

    private let keywords: Set<String>

    init(extraKeywords: Set<String> = []) {
        keywords = Self.baseKeywords.union(extraKeywords)
    }

    func tokenize(_ code: String) -> [Token] {
        var builder = TokenBuilder()
        let chars = Array(code)
        let count = chars.count
        var i = 0

        while i < count {
            let c = chars[i]

            if c == "/" && i + 1 < count && chars[i + 1] == "/" {
                let start = i
                while i < count && chars[i] != "\n" { i += 1 }
                builder.emit(.comment, String(chars[start..<i]))
                continue
            }
            if c == "/" && i + 1 < count && chars[i + 1] == "*" {
                let start = i
                i += 2
                while i < count && !(chars[i] == "*" && i + 1 < count && chars[i + 1] == "/") {
                    i += 1
                }
                i = min(i + 2, count)
                builder.emit(.comment, String(chars[start..<i]))
                continue
            }

            // Template literals may span lines; ${} holes are not split out.
            if c == "'" || c == "\"" || c == "`" {
                let start = i
                var j = i + 1
                while j < count {
                    let ch = chars[j]
                    if ch == "\\" {
                        j += 2
                        continue
                    }
                    if ch == c {
                        j += 1
                        break
                    }
                    if ch == "\n" && c != "`" { break }
                    j += 1
                }
                builder.emit(.string, String(chars[start..<min(j, count)]))
                i = min(j, count)
                continue
            }

            if c.isNumber {
                var j = i
                while j < count && (chars[j].isHexDigit || "xXoObBn._eE".contains(chars[j])) {
                    j += 1
                }
                builder.emit(.number, String(chars[i..<j]))
                i = j
                continue
            }

            if c.isLetter || c == "_" || c == "$" {
                var j = i
                while j < count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "$") {
                    j += 1
                }
                let word = String(chars[i..<j])
                if keywords.contains(word) {
                    builder.emit(.keyword, word)
                } else {
                    builder.plain(word)
                }
                i = j
                continue
            }

            builder.plain(c)
            i += 1
        }
        return builder.finish()
    }
}

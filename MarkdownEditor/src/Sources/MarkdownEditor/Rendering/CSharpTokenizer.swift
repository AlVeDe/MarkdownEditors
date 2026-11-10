/// Deliberately small hand-written C# lexer: keywords, strings (incl. `@`/`$`
/// prefixed), comments (`//`, `/* */`, `///`), numbers and preprocessor
/// directives. Approximate by design — no interpolation holes, no raw
/// string literals.
struct CSharpTokenizer: LanguageTokenizer {
    private static let keywords: Set<String> = [
        "abstract", "as", "base", "bool", "break", "byte", "case", "catch",
        "char", "checked", "class", "const", "continue", "decimal", "default",
        "delegate", "do", "double", "else", "enum", "event", "explicit",
        "extern", "false", "finally", "fixed", "float", "for", "foreach",
        "goto", "if", "implicit", "in", "int", "interface", "internal", "is",
        "lock", "long", "namespace", "new", "null", "object", "operator",
        "out", "override", "params", "private", "protected", "public",
        "readonly", "record", "ref", "required", "return", "sbyte", "sealed",
        "short", "sizeof", "stackalloc", "static", "string", "struct",
        "switch", "this", "throw", "true", "try", "typeof", "uint", "ulong",
        "unchecked", "unsafe", "ushort", "using", "var", "virtual", "void",
        "volatile", "while", "async", "await", "dynamic", "get", "global",
        "init", "nameof", "partial", "set", "value", "when", "where", "yield"
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

            // #region, #if, #pragma, … — only at the start of a line.
            if atLineStart && c == "#" {
                let start = i
                while i < count && chars[i] != "\n" { i += 1 }
                builder.emit(.preprocessor, String(chars[start..<i]))
                atLineStart = false
                continue
            }
            atLineStart = false

            // Line comments, including /// doc comments.
            if c == "/" && i + 1 < count && chars[i + 1] == "/" {
                let start = i
                while i < count && chars[i] != "\n" { i += 1 }
                builder.emit(.comment, String(chars[start..<i]))
                continue
            }
            // Block comments.
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

            // @"verbatim", $"interpolated", $@"both" — and @identifiers.
            if c == "@" || c == "$" {
                var j = i
                var verbatim = false
                while j < count && (chars[j] == "@" || chars[j] == "$") {
                    if chars[j] == "@" { verbatim = true }
                    j += 1
                }
                if j < count && chars[j] == "\"" {
                    let end = scanString(chars, quoteIndex: j, verbatim: verbatim)
                    builder.emit(.string, String(chars[i..<end]))
                    i = end
                    continue
                }
                if c == "@" && j < count && (chars[j].isLetter || chars[j] == "_") {
                    var k = j
                    while k < count && (chars[k].isLetter || chars[k].isNumber || chars[k] == "_") {
                        k += 1
                    }
                    builder.plain(String(chars[i..<k]))
                    i = k
                    continue
                }
                builder.plain(c)
                i += 1
                continue
            }

            if c == "\"" {
                let end = scanString(chars, quoteIndex: i, verbatim: false)
                builder.emit(.string, String(chars[i..<end]))
                i = end
                continue
            }

            // Character literals.
            if c == "'" {
                var j = i + 1
                while j < count && chars[j] != "'" && chars[j] != "\n" {
                    if chars[j] == "\\" { j += 1 }
                    j += 1
                }
                j = min(j + 1, count)
                builder.emit(.string, String(chars[i..<j]))
                i = j
                continue
            }

            if c.isNumber {
                var j = i
                while j < count && (chars[j].isHexDigit || "xXbBoO._eEfFdDmMuUlL".contains(chars[j])) {
                    j += 1
                }
                builder.emit(.number, String(chars[i..<j]))
                i = j
                continue
            }

            if c.isLetter || c == "_" {
                var j = i
                while j < count && (chars[j].isLetter || chars[j].isNumber || chars[j] == "_") {
                    j += 1
                }
                let word = String(chars[i..<j])
                if Self.keywords.contains(word) {
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

    /// Returns the index just past the closing quote (or the end of input /
    /// line for unterminated strings). `quoteIndex` points at the opening `"`.
    private func scanString(_ chars: [Character], quoteIndex: Int, verbatim: Bool) -> Int {
        var j = quoteIndex + 1
        while j < chars.count {
            let ch = chars[j]
            if verbatim {
                if ch == "\"" {
                    if j + 1 < chars.count && chars[j + 1] == "\"" {
                        j += 2
                        continue
                    }
                    return j + 1
                }
            } else {
                if ch == "\\" {
                    j += 2
                    continue
                }
                if ch == "\"" { return j + 1 }
                if ch == "\n" { return j }
            }
            j += 1
        }
        return chars.count
    }
}

import Foundation

/// Turns the errors the preview page reports (by source line) into editor
/// diagnostics (by UTF-16 range), against the exact markdown that was
/// rendered.
enum PreviewDiagnostics {
    /// A mermaid diagram that failed to parse.
    struct DiagramError: Equatable {
        /// Line of the opening ` ```mermaid ` fence.
        var line: Int
        /// Line of the closing fence (0 if unknown).
        var endLine: Int
        var message: String
    }

    /// A formula MathJax could not typeset.
    struct FormulaError: Equatable {
        /// For display math the `$$` (or ` ```math `) line; for inline math
        /// the line of the block holding it.
        var line: Int
        var endLine: Int
        var isDisplay: Bool
        var tex: String
        var message: String
    }

    // MARK: Decoding the page's report

    /// Parses `updateContent`'s result (`{mermaid: [...], math: [...]}`).
    struct Report: Equatable {
        var diagrams: [DiagramError] = []
        var formulas: [FormulaError] = []
    }

    static func decode(_ result: Any?) -> Report {
        guard let report = result as? [String: Any] else { return Report() }
        func int(_ value: Any?) -> Int { (value as? NSNumber)?.intValue ?? 0 }

        let diagrams = (report["mermaid"] as? [[String: Any]] ?? []).map {
            DiagramError(line: int($0["line"]), endLine: int($0["endLine"]), message: $0["message"] as? String ?? "")
        }
        let formulas = (report["math"] as? [[String: Any]] ?? []).map {
            FormulaError(
                line: int($0["line"]),
                endLine: int($0["endLine"]),
                isDisplay: ($0["display"] as? NSNumber)?.boolValue ?? false,
                tex: $0["tex"] as? String ?? "",
                message: $0["message"] as? String ?? ""
            )
        }
        return Report(diagrams: diagrams, formulas: formulas)
    }

    // MARK: Mapping

    /// Underlines the diagram line the parser complains about ("Parse error
    /// on line N" counts from the first line inside the fence), else the
    /// fence's first content line.
    static func diagnostics(for errors: [DiagramError], in text: String) -> [EditorDiagnostic] {
        let lines = LineIndex(text)
        return errors.compactMap { error in
            guard error.line > 0 else { return nil }
            var target = error.line + 1
            if let reported = reportedLine(in: error.message) {
                let candidate = error.line + reported
                if error.endLine <= 0 || candidate < error.endLine { target = candidate }
            }
            guard let range = lines.range(ofLine: target) ?? lines.range(ofLine: error.line) else { return nil }
            return EditorDiagnostic(range: range, message: "Mermaid: " + summary(of: error.message))
        }
    }

    /// Display math: the formula's lines (the whole `$$ … $$` block).
    /// Inline math: the `$ … $` span when it can be found near the block's
    /// line, else that line.
    static func diagnostics(for errors: [FormulaError], in text: String) -> [EditorDiagnostic] {
        let lines = LineIndex(text)
        let nsText = text as NSString
        return errors.compactMap { error in
            guard error.line > 0, let first = lines.range(ofLine: error.line) else { return nil }
            let message = "LaTeX: " + error.message
            if error.isDisplay {
                let last = lines.range(ofLine: max(error.line, error.endLine)) ?? first
                return EditorDiagnostic(range: NSRange(location: first.location, length: NSMaxRange(last) - first.location), message: message)
            }
            if !error.tex.isEmpty {
                // Search a bounded window: a paragraph rarely spans more.
                let windowEnd = lines.range(ofLine: error.line + 50).map(NSMaxRange) ?? nsText.length
                let window = NSRange(location: first.location, length: windowEnd - first.location)
                let found = nsText.range(of: error.tex, options: [], range: window)
                if found.location != NSNotFound {
                    return EditorDiagnostic(range: found, message: message)
                }
            }
            return EditorDiagnostic(range: first, message: message)
        }
    }

    /// N from mermaid's "Parse error on line N:" / "Lexical error on line N."
    static func reportedLine(in message: String) -> Int? {
        guard let match = message.range(of: #"on line \d+"#, options: .regularExpression) else { return nil }
        return Int(message[match].dropFirst("on line ".count))
    }

    /// Mermaid's parse errors are multi-line (message, source excerpt, a
    /// `---^` pointer, "Expecting …"). The status bar has room for one line:
    /// the expectation if there is one, else the first line.
    static func summary(of message: String) -> String {
        let lines = message.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if let expecting = lines.last(where: { $0.hasPrefix("Expecting") }) {
            return expecting
        }
        return lines.first ?? message
    }
}

/// UTF-16 line ranges of a text (1-based lines, line terminators excluded).
struct LineIndex {
    private let text: NSString
    /// UTF-16 offset where each line starts.
    private var starts: [Int] = [0]

    init(_ string: String) {
        text = string as NSString
        let length = text.length
        var index = 0
        while index < length {
            let character = text.character(at: index)
            if character == 0x0A {
                starts.append(index + 1)
            } else if character == 0x0D {
                if index + 1 < length, text.character(at: index + 1) == 0x0A { index += 1 }
                starts.append(index + 1)
            }
            index += 1
        }
    }

    var lineCount: Int { starts.count }

    /// The range of 1-based `line` without its terminator; nil if out of range.
    func range(ofLine line: Int) -> NSRange? {
        guard line >= 1, line <= starts.count else { return nil }
        let start = starts[line - 1]
        var end = line < starts.count ? starts[line] : text.length
        while end > start, [0x0A, 0x0D].contains(text.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }
}

import AppKit

/// Formatting that Markdown itself has no syntax for: highlight, subscript
/// and superscript as inline HTML tags, and GitHub-style footnotes.
///
/// Tags rather than the `==mark==` / `~sub~` / `^sup^` dialects: those are
/// not portable, and `~x~` already means strikethrough in GitHub Flavored
/// Markdown. `<mark>`, `<sub>` and `<sup>` are valid CommonMark everywhere;
/// the preview renders them natively and the PDF renderer maps them to a
/// background color and a baseline shift.
extension EditorController {
    /// Wraps the selection in `<tag>…</tag>`, or unwraps it when the
    /// selection includes the tags or sits right between them. Without a
    /// selection, inserts an empty pair with the caret inside; repeating the
    /// command there removes the pair again.
    func toggleTagWrap(_ tag: String) {
        let open = "<\(tag)>", close = "</\(tag)>"
        let openLength = (open as NSString).length, closeLength = (close as NSString).length
        let text = string
        let range = selectedRange
        let selected = text.substring(with: range)

        // The selection includes the tags: `<mark>word</mark>`.
        if selected.hasPrefix(open), selected.hasSuffix(close), range.length >= openLength + closeLength {
            let inner = (selected as NSString).substring(
                with: NSRange(location: openLength, length: range.length - openLength - closeLength)
            )
            replaceCharacters(in: range, with: inner,
                              selecting: NSRange(location: range.location, length: (inner as NSString).length))
            return
        }

        // The tags sit right around the selection (or the caret).
        let before = NSRange(location: range.location - openLength, length: openLength)
        let after = NSRange(location: NSMaxRange(range), length: closeLength)
        if before.location >= 0, NSMaxRange(after) <= text.length,
           text.substring(with: before) == open, text.substring(with: after) == close {
            replaceCharacters(
                in: NSRange(location: before.location, length: NSMaxRange(after) - before.location),
                with: selected,
                selecting: NSRange(location: before.location, length: range.length)
            )
            return
        }

        replaceCharacters(in: range, with: open + selected + close,
                          selecting: NSRange(location: range.location + openLength, length: range.length))
    }

    /// Inserts `[^n]` after the selection — `n` one higher than the largest
    /// numeric footnote label in the document — and appends `[^n]: ` at the
    /// end of the document, where the caret goes so the note can be typed
    /// right away (as word processors jump to a new footnote).
    func insertFootnote() {
        let number = Self.nextFootnoteNumber(in: string as String)
        let reference = "[^\(number)]"
        let caret = NSMaxRange(selectedRange)
        replaceCharacters(in: NSRange(location: caret, length: 0), with: reference)

        let text = string as String
        var suffix = ""
        if !text.isEmpty, !text.hasSuffix("\n") { suffix += "\n" }
        // A blank line before the first definition, so it does not run into
        // the last paragraph; consecutive definitions stay together.
        let lastLine = text.split(separator: "\n", omittingEmptySubsequences: false)
            .last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
        if !lastLine.isEmpty, !Self.isFootnoteDefinition(String(lastLine)), !text.hasSuffix("\n\n") {
            suffix += "\n"
        }
        let definition = "[^\(number)]: "
        let end = (text as NSString).length
        replaceCharacters(
            in: NSRange(location: end, length: 0),
            with: suffix + definition,
            selecting: NSRange(location: end + (suffix as NSString).length + (definition as NSString).length, length: 0)
        )
    }

    static func nextFootnoteNumber(in text: String) -> Int {
        var highest = 0
        var rest = text[...]
        while let open = rest.range(of: "[^") {
            rest = rest[open.upperBound...]
            let digits = rest.prefix(while: \.isNumber)
            if !digits.isEmpty, rest.dropFirst(digits.count).first == "]", let value = Int(digits) {
                highest = max(highest, value)
            }
        }
        return highest + 1
    }

    static func isFootnoteDefinition(_ line: String) -> Bool {
        let trimmed = line.drop(while: { $0 == " " })
        guard trimmed.hasPrefix("[^"), let close = trimmed.firstIndex(of: "]") else { return false }
        return trimmed[trimmed.index(after: close)...].hasPrefix(":")
    }
}

import AppKit
import Observation

/// One heading in the outline.
struct OutlineHeading: Identifiable, Equatable, Sendable {
    /// Position in the outline (headings are re-parsed wholesale, so the
    /// index is a stable enough identity between two parses).
    var id: Int
    /// 1 … 6.
    var level: Int
    var title: String
    /// 1-based source line (for setext headings: the first text line).
    var line: Int
    /// UTF-16 offset of the start of that line.
    var location: Int
}

/// Extracts ATX (`# Title`) and setext (`Title` / `===`) headings.
///
/// A line scanner rather than a full CommonMark parse: the outline is
/// re-built after every typing pause, so it must be cheap, and the only
/// block structures that matter are the ones that make `#` or `---` *not*
/// a heading — fenced code, YAML front matter, indented code, HTML comments.
/// Pure and `nonisolated` so large documents can be parsed off the main
/// thread.
enum OutlineParser {
    nonisolated static func headings(in text: String) -> [OutlineHeading] {
        let string = text as NSString
        var headings: [OutlineHeading] = []

        var index = 0
        var lineNumber = 0
        var fence: (character: Character, count: Int)?
        var inFrontMatter = false
        var inComment = false
        // The paragraph a setext underline would turn into a heading.
        var paragraph: (lines: [String], line: Int, location: Int)?

        while index < string.length {
            let lineRange = string.lineRange(for: NSRange(location: index, length: 0))
            var contentsEnd = 0
            string.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: lineRange)
            let line = string.substring(with: NSRange(location: lineRange.location, length: contentsEnd - lineRange.location))
            let location = lineRange.location
            index = NSMaxRange(lineRange)
            lineNumber += 1

            // Front matter: `---` on the very first line up to `---`/`...`.
            if lineNumber == 1, line.trimmingTrailingWhitespace == "---" {
                inFrontMatter = true
                continue
            }
            if inFrontMatter {
                let trimmed = line.trimmingTrailingWhitespace
                if trimmed == "---" || trimmed == "..." { inFrontMatter = false }
                continue
            }

            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)

            // Fenced code.
            if let open = fence {
                if indent < 4, let close = fenceMarker(body), close.character == open.character,
                   close.count >= open.count, close.info.isEmpty {
                    fence = nil
                }
                continue
            }
            if indent < 4, let open = fenceMarker(body) {
                // A backtick fence's info string may not contain backticks.
                if open.character != "`" || !open.info.contains("`") {
                    fence = (open.character, open.count)
                    paragraph = nil
                    continue
                }
            }

            // HTML comments spanning lines.
            if inComment {
                if line.contains("-->") { inComment = false }
                continue
            }
            if indent < 4, body.hasPrefix("<!--") {
                if !body.contains("-->") { inComment = true }
                paragraph = nil
                continue
            }

            if line.allSatisfy(\.isWhitespace) {
                paragraph = nil
                continue
            }

            // Indented code (only when not continuing a paragraph).
            if indent >= 4 || line.hasPrefix("\t") {
                if paragraph == nil { continue }
                paragraph?.lines.append(String(line.drop { $0 == " " || $0 == "\t" }))
                continue
            }

            if let (level, title) = atxHeading(body) {
                headings.append(OutlineHeading(id: headings.count, level: level, title: title, line: lineNumber, location: location))
                paragraph = nil
                continue
            }

            if let level = setextLevel(body), let text = paragraph {
                let title = text.lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
                headings.append(OutlineHeading(id: headings.count, level: level, title: title, line: text.line, location: text.location))
                paragraph = nil
                continue
            }

            if startsNonParagraphBlock(body) {
                paragraph = nil
            } else if paragraph == nil {
                paragraph = ([String(body)], lineNumber, location)
            } else {
                paragraph?.lines.append(String(body))
            }
        }
        return headings
    }

    /// `(character, run length, info string)` for a fence line.
    private nonisolated static func fenceMarker(_ body: Substring) -> (character: Character, count: Int, info: String)? {
        guard let first = body.first, first == "`" || first == "~" else { return nil }
        let count = body.prefix { $0 == first }.count
        guard count >= 3 else { return nil }
        let info = body.dropFirst(count).trimmingCharacters(in: .whitespaces)
        return (first, count, info)
    }

    private nonisolated static func atxHeading(_ body: Substring) -> (Int, String)? {
        let level = body.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let rest = body.dropFirst(level)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        var title = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence: `## Title ##`.
        if let range = title.range(of: #"(^|[ \t])#+$"#, options: .regularExpression) {
            title = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (level, title)
    }

    private nonisolated static func setextLevel(_ body: Substring) -> Int? {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard let first = trimmed.first, first == "=" || first == "-" else { return nil }
        guard trimmed.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    /// Lines that start a block of their own and therefore cannot be (the
    /// start of) a setext heading's text: quotes, list items, thematic
    /// breaks, tables' delimiter rows are caught by the caller's order.
    private nonisolated static func startsNonParagraphBlock(_ body: Substring) -> Bool {
        if body.hasPrefix(">") { return true }
        if body.range(of: #"^([-*+]|\d{1,9}[.)])([ \t]|$)"#, options: .regularExpression) != nil { return true }
        // Thematic breaks: `***`, `___`, `- - -`.
        let compact = body.filter { !$0.isWhitespace }
        if compact.count >= 3, let first = compact.first, "*_-".contains(first), compact.allSatisfy({ $0 == first }) {
            return true
        }
        return false
    }

    /// Index of the heading whose section contains `location`: the last
    /// heading starting at or before it.
    nonisolated static func sectionIndex(for location: Int, in headings: [OutlineHeading]) -> Int? {
        var low = 0
        var high = headings.count
        while low < high {
            let mid = (low + high) / 2
            if headings[mid].location <= location { low = mid + 1 } else { high = mid }
        }
        return low == 0 ? nil : low - 1
    }
}

private extension StringProtocol {
    var trimmingTrailingWhitespace: String {
        var result = String(self)
        while let last = result.last, last == " " || last == "\t" { result.removeLast() }
        return result
    }
}

/// Live outline of one editor, for the sidebar.
///
/// Observes the text view through notifications instead of
/// `EditorController.onTextChange`, which is a single closure owned by
/// `DocumentSession`. Text changes are picked up from the text storage
/// (not `NSText.didChangeNotification`) so that `setText` — loading a
/// document, Revert — refreshes the outline too.
@MainActor
@Observable
final class OutlineModel {
    private(set) var headings: [OutlineHeading] = []
    /// Index into `headings` of the section containing the caret.
    private(set) var currentIndex: Int?

    /// Above this many UTF-16 units the parse runs on a background task.
    @ObservationIgnored var backgroundThreshold = 100_000
    @ObservationIgnored var debounce: Duration = .milliseconds(300)

    @ObservationIgnored private weak var editor: EditorController?
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []
    @ObservationIgnored private var parseTask: Task<Void, Never>?

    init(editor: EditorController) {
        self.editor = editor
        let center = NotificationCenter.default
        if let storage = editor.textView.textStorage {
            // `queue: nil` delivers synchronously, inside `processEditing`,
            // while `editedMask` still describes this edit; a queued block
            // would read it after the storage has already reset it.
            observers.append(center.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil
            ) { [weak self] notification in
                // Attribute-only edits (highlighting) don't change headings.
                nonisolated(unsafe) let storage = notification.object as? NSTextStorage
                guard storage?.editedMask.contains(.editedCharacters) == true else { return }
                MainActor.assumeIsolated {
                    self?.scheduleParse()
                }
            })
        }
        observers.append(center.addObserver(
            forName: NSTextView.didChangeSelectionNotification, object: editor.textView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateCurrent() }
        })
        parseNow()
    }

    isolated deinit {
        parseTask?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    /// Re-parses after the typing pause.
    func scheduleParse() {
        parseTask?.cancel()
        parseTask = Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            await self?.parse()
        }
    }

    /// Parses immediately on the main thread.
    func parseNow() {
        guard let editor else { return }
        apply(OutlineParser.headings(in: editor.textView.string))
    }

    private func parse() async {
        guard let editor else { return }
        let text = editor.textView.string
        if (text as NSString).length > backgroundThreshold {
            let result = await Task.detached(priority: .userInitiated) {
                OutlineParser.headings(in: text)
            }.value
            guard !Task.isCancelled else { return }
            apply(result)
        } else {
            apply(OutlineParser.headings(in: text))
        }
    }

    private func apply(_ result: [OutlineHeading]) {
        if result != headings { headings = result }
        updateCurrent()
    }

    private func updateCurrent() {
        guard let editor else { return }
        let index = OutlineParser.sectionIndex(for: editor.selectedRange.location, in: headings)
        if index != currentIndex { currentIndex = index }
    }

    /// The smallest heading level present, so the shallowest headings sit
    /// flush left even in documents that start at `##`.
    var minimumLevel: Int {
        headings.map(\.level).min() ?? 1
    }
}

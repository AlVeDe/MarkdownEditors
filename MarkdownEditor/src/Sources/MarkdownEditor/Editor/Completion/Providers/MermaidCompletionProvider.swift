import AppKit

/// IntelliSense inside ` ```mermaid ` fences.
///
/// - On the diagram's first line: the diagram types, each inserting a small
///   working template (the second word of `flowchart`/`graph`/`gitGraph`
///   gets the directions).
/// - Below it: the keywords and snippets of the detected type, plus the
///   identifiers the diagram already defines (ranked first, since referring
///   to an existing node is the most common edit).
/// - Right after arrow characters (`A --`): the type's edge operators.
///
/// Everything is derived from the text on each request; diagrams are small,
/// so there is no cache to keep in sync.
@MainActor
final class MermaidCompletionProvider: CompletionProvider {
    /// Arrows start with `-` (or `<`, `=`, `.`, `|` …); `-` and `>` are the
    /// characters that most often begin or extend one, so typing them
    /// re-opens the popup with the operator list.
    let triggerCharacters: Set<Character> = ["-", ">"]

    private enum Rank {
        static let identifier = 30
        static let keyword = 20
        static let midLineKeyword = 10
        static let common = 0
    }

    func completions(for request: CompletionRequest) -> CompletionResult? {
        guard request.context == .mermaid,
              let block = MermaidBlock.find(in: request.text, at: request.location) else { return nil }
        let prefix = Array(block.caretPrefix)
        if trimmedLeading(block.caretPrefix).hasPrefix("%%") { return nil }

        switch Self.headerPosition(block) {
        case .frontMatter:
            return nil
        case .beforeType:
            return wordResult(prefix, request, items: items(MermaidSyntax.common, kind: .snippet, rank: Rank.common))
        case .typeLine:
            return headerCompletions(prefix, request)
        case .body(let typeLine):
            guard let type = MermaidDiagramType(typeLine: block.lines[typeLine]) else {
                return wordResult(prefix, request, items: items(MermaidSyntax.common, kind: .snippet, rank: Rank.common))
            }
            return bodyCompletions(prefix, block: block, typeLine: typeLine, type: type, request: request)
        }
    }

    // MARK: Header

    enum HeaderPosition: Equatable {
        case frontMatter, beforeType, typeLine
        case body(typeLine: Int)
    }

    /// Where the caret is relative to the diagram's type line, which is the
    /// first line that is not blank, not a `%%` comment/directive and not
    /// part of a `---` front-matter config block.
    static func headerPosition(_ block: MermaidBlock) -> HeaderPosition {
        var index = 0
        let lines = block.lines
        while index < lines.count {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            if line == "---" && index == firstNonBlank(lines) {
                let close = lines[(index + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces) == "---" } ?? lines.count
                if block.caretLine >= index && block.caretLine <= close { return .frontMatter }
                index = close + 1
                continue
            }
            if line.isEmpty || line.hasPrefix("%%") { index += 1; continue }
            if block.caretLine < index { return .beforeType }
            return block.caretLine == index ? .typeLine : .body(typeLine: index)
        }
        return block.caretLine < lines.count ? .typeLine : .beforeType
    }

    private static func firstNonBlank(_ lines: [String]) -> Int? {
        lines.firstIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private func headerCompletions(_ prefix: [Character], _ request: CompletionRequest) -> CompletionResult? {
        let words = String(prefix).split(whereSeparator: { $0 == " " || $0 == "\t" })
        let endsInSpace = prefix.last.map { $0 == " " || $0 == "\t" } ?? false
        let wordIndex = words.count - (endsInSpace || words.isEmpty ? 0 : 1)
        if wordIndex == 0 {
            var list = items(MermaidDiagramType.templates, kind: .diagram, rank: Rank.keyword)
            list += items(MermaidSyntax.common, kind: .snippet, rank: Rank.common)
            return wordResult(prefix, request, items: list)
        }
        guard wordIndex == 1 else { return nil }
        switch String(words[0]) {
        case "flowchart", "graph", "flowchart-elk":
            return wordResult(prefix, request, items: items(MermaidDiagramType.directions, kind: .keyword, rank: Rank.keyword),
                              firstTokenOnly: false)
        case "gitGraph":
            return wordResult(prefix, request, items: items(MermaidDiagramType.gitGraphOrientations, kind: .keyword, rank: Rank.keyword),
                              firstTokenOnly: false)
        default:
            return nil
        }
    }

    // MARK: Body

    private func bodyCompletions(_ prefix: [Character], block: MermaidBlock, typeLine: Int,
                                 type: MermaidDiagramType, request: CompletionRequest) -> CompletionResult? {
        let keywords = MermaidSyntax.keywords(for: type)
        let hyphenated = keywords.map(\.label).filter { $0.contains("-") }

        if let length = Self.arrowRunLength(prefix, type: type, hyphenatedWords: hyphenated) {
            let range = NSRange(location: request.location - utf16Count(prefix.suffix(length)), length: utf16Count(prefix.suffix(length)))
            let list = items(MermaidSyntax.arrows(for: type), kind: .symbol, rank: Rank.keyword)
            return list.isEmpty ? nil : CompletionResult(replacementRange: range, items: list)
        }
        if Self.isInsideLabel(String(prefix), type: type) { return nil }

        let start = Self.wordStart(prefix, allowLeadingPunctuation: true)
        let word = prefix[start...]
        if !request.isExplicit && word.isEmpty { return nil }
        let before = Array(prefix[..<start])
        let beforeTrimmed = Array(String(before).trimmingCharacters(in: .whitespaces))

        // Names defined elsewhere in the diagram; the word being typed is cut
        // out of the caret line so it does not suggest itself.
        var body = Array(block.lines[(typeLine + 1)...])
        body[block.caretLine - typeLine - 1] = String(before) + block.caretSuffix
        let noun = MermaidIdentifiers.noun(for: type)
        let identifiers = MermaidIdentifiers.scan(body, type: type).map {
            CompletionItem(label: $0, detail: noun, kind: .identifier, insertText: $0, sortPriority: Rank.identifier)
        }

        var list: [CompletionItem]
        if beforeTrimmed.isEmpty {
            list = identifiers + items(keywords, rank: Rank.keyword) + items(MermaidSyntax.common, kind: .snippet, rank: Rank.common)
        } else if Self.followsEdge(beforeTrimmed, type: type) {
            list = identifiers
        } else if Self.lastWord(beforeTrimmed) == "direction" {
            list = items(MermaidDiagramType.directions, kind: .keyword, rank: Rank.keyword)
        } else {
            list = identifiers + items(keywords, rank: Rank.midLineKeyword)
        }
        guard !list.isEmpty else { return nil }
        let range = NSRange(location: request.location - utf16Count(word), length: utf16Count(word))
        return CompletionResult(replacementRange: range, items: list)
    }

    // MARK: Ranges

    /// Identifier characters, plus `-` between them (`stateDiagram-v2`,
    /// `cherry-pick`, `x-axis`), but never a `-` that follows another
    /// punctuation character, which belongs to an arrow.
    static func wordStart(_ chars: [Character], allowLeadingPunctuation: Bool) -> Int {
        var start = chars.count
        while start > 0 {
            let c = chars[start - 1]
            if MermaidIdentifiers.isIdentifierChar(c) { start -= 1; continue }
            if c == "-", start >= 2, MermaidIdentifiers.isIdentifierChar(chars[start - 2]),
               start == chars.count || MermaidIdentifiers.isIdentifierChar(chars[start]) {
                start -= 1
                continue
            }
            break
        }
        // `<<interface>>` and `%% comment` start with punctuation; include a
        // leading run of it when it begins the token.
        if allowLeadingPunctuation {
            var p = start
            while p > 0, chars[p - 1] == "<" || chars[p - 1] == "%" { p -= 1 }
            if p < start, p == 0 || chars[p - 1].isWhitespace { start = p }
        }
        return start
    }

    /// Length of the arrow being typed at the end of `chars`, or nil when the
    /// caret does not follow an arrow. An arrow needs something before it on
    /// the line (`A --`), so a line starting with `<<` or `}` is not one.
    static func arrowRunLength(_ chars: [Character], type: MermaidDiagramType, hyphenatedWords: [String] = []) -> Int? {
        guard !MermaidSyntax.arrows(for: type).isEmpty else { return nil }
        let punctuation: Set<Character> = type == .er ? ["-", "<", ">", ".", "=", "|", "*", ")", "~", "{", "}"]
                                                     : ["-", "<", ">", ".", "=", "|", "*", ")", "~"]
        // `cherry-`, `x-`: a hyphen continuing a keyword, not an arrow.
        if chars.last == "-" {
            var j = chars.count - 1
            while j > 0, MermaidIdentifiers.isIdentifierChar(chars[j - 1]) { j -= 1 }
            let word = String(chars[j...])
            if word.count > 1, hyphenatedWords.contains(where: { $0.hasPrefix(word) }) { return nil }
        }
        var i = chars.count
        while i > 0 {
            let c = chars[i - 1]
            if punctuation.contains(c) { i -= 1; continue }
            if c == "o" || c == "x" {
                // Arrow heads `--o`, `--x` and tails `o--o`, `x--x`.
                let leftIsArrow = i >= 2 && punctuation.contains(chars[i - 2])
                let rightIsArrow = i < chars.count && punctuation.contains(chars[i])
                let leftIsBoundary = i < 2 || chars[i - 2].isWhitespace
                if leftIsArrow || (rightIsArrow && leftIsBoundary) { i -= 1; continue }
            }
            break
        }
        let run = String(chars[i...])
        guard !run.isEmpty, chars[..<i].contains(where: { !$0.isWhitespace }) else { return nil }
        let isArrow = run.contains(where: { "-=<>".contains($0) }) || run.contains("..")
            || (type == .er && (run.hasPrefix("|") || run.hasPrefix("}")))
        return isArrow ? chars.count - i : nil
    }

    /// True when the text before the caret ends with an edge, so an
    /// identifier (the edge's target) is expected: `A -->`, `A -->|x|`,
    /// `A ->>+`, `A &`.
    static func followsEdge(_ chars: [Character], type: MermaidDiagramType) -> Bool {
        var chars = chars
        if chars.last == "&" { return true }
        if type == .flowchart, chars.last == "|", let open = chars.dropLast().lastIndex(of: "|") {
            chars = Array(chars[..<open])
            while chars.last?.isWhitespace == true { chars.removeLast() }
        }
        if type == .sequence, chars.last == "+" { chars.removeLast() }
        return arrowRunLength(chars, type: type) != nil
    }

    /// True inside a string, a node label (`A[te`) or an edge label, where
    /// suggestions would only get in the way.
    static func isInsideLabel(_ prefix: String, type: MermaidDiagramType) -> Bool {
        if prefix.count(where: { $0 == "\"" }) % 2 == 1 { return true }
        // Braces open blocks in class/state/ER diagrams but labels in flowcharts.
        let opens: Set<Character> = type == .flowchart ? ["[", "(", "{"] : ["[", "("]
        let closes: Set<Character> = type == .flowchart ? ["]", ")", "}"] : ["]", ")"]
        var depth = 0
        for c in prefix {
            if opens.contains(c) { depth += 1 } else if closes.contains(c) { depth = max(0, depth - 1) }
        }
        if depth > 0 { return true }
        if type == .flowchart, prefix.count(where: { $0 == "|" }) % 2 == 1 { return true }
        // Text after `:` is a free-form label in these diagrams.
        let freeTextAfterColon: Set<MermaidDiagramType> = [.sequence, .state, .classDiagram, .er, .journey, .timeline,
                                                            .pie, .quadrant, .packet, .treemap, .requirement]
        return freeTextAfterColon.contains(type) && prefix.contains(":")
    }

    // MARK: Helpers

    /// Completes the word before the caret with `items`. With
    /// `firstTokenOnly` the word must be the line's first token (header
    /// keywords are meaningless further right).
    private func wordResult(_ prefix: [Character], _ request: CompletionRequest, items: [CompletionItem],
                            firstTokenOnly: Bool = true) -> CompletionResult? {
        let start = Self.wordStart(prefix, allowLeadingPunctuation: true)
        let word = prefix[start...]
        if !request.isExplicit && word.isEmpty { return nil }
        if firstTokenOnly, prefix[..<start].contains(where: { !$0.isWhitespace }) { return nil }
        let length = utf16Count(word)
        return CompletionResult(replacementRange: NSRange(location: request.location - length, length: length), items: items)
    }

    private func items(_ entries: [MermaidEntry], kind: CompletionItemKind? = nil, rank: Int) -> [CompletionItem] {
        entries.map {
            CompletionItem(label: $0.label, detail: $0.detail, documentation: $0.doc,
                           kind: kind ?? ($0.isSnippet ? .snippet : .keyword),
                           insertText: $0.insert, sortPriority: rank)
        }
    }

    private static func lastWord(_ chars: [Character]) -> String {
        String(chars.reversed().prefix { !$0.isWhitespace }.reversed())
    }

    private func trimmedLeading(_ s: String) -> Substring {
        s.drop { $0 == " " || $0 == "\t" }
    }

    private func utf16Count<S: Sequence<Character>>(_ chars: S) -> Int {
        String(chars).utf16.count
    }
}

import Foundation

/// The parts of a Markdown document that completions point *into*: headings
/// (for `](#anchor)` links) and reference definitions (for `[text][label]`).
///
/// Building it is one linear pass over the text. That is cheap even for a
/// 10k-line document, but completion re-queries on every keystroke, so the
/// provider keeps the last index and only rebuilds when the text changed.
struct MarkdownDocumentIndex: Sendable {
    struct Heading: Equatable, Sendable {
        /// Heading text with inline markup removed, as shown in the list.
        var title: String
        /// 1…6.
        var level: Int
        /// GitHub-style anchor, already de-duplicated (`intro`, `intro-1`, …).
        var anchor: String
    }

    struct Reference: Equatable, Sendable {
        var label: String
        var destination: String
    }

    var headings: [Heading] = []
    var references: [Reference] = []

    init(text: String) {
        var slugger = AnchorSlugger()
        var seenReferences = Set<String>()
        var fence: (marker: Character, count: Int)?
        var inFrontMatter = false
        /// The previous line if it could be the text of a setext heading
        /// (`Title` followed by `===` or `---`).
        var setextCandidate: String?

        var lineNumber = 0
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            defer { lineNumber += 1 }
            let line = rawLine.hasSuffix("\r") ? rawLine.dropLast() : rawLine
            let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
            let indent = line.count - trimmed.count

            // Front matter is YAML, not Markdown: its `---` delimiters must
            // not turn the title line into a setext heading.
            if lineNumber == 0, trimmed == "---" { inFrontMatter = true; continue }
            if inFrontMatter {
                if trimmed == "---" || trimmed == "..." { inFrontMatter = false }
                continue
            }

            // Headings and definitions inside fenced code are just code.
            if let open = fence {
                if let close = Self.fenceMarker(trimmed), close.marker == open.marker,
                   close.count >= open.count,
                   trimmed.drop(while: { $0 == open.marker }).allSatisfy(\.isWhitespace) {
                    fence = nil
                }
                continue
            }
            if indent <= 3, let open = Self.fenceMarker(trimmed) {
                fence = open
                setextCandidate = nil
                continue
            }

            guard indent <= 3 else { setextCandidate = nil; continue }

            if let (level, title) = Self.atxHeading(trimmed) {
                headings.append(Heading(title: title, level: level, anchor: slugger.anchor(for: title)))
                setextCandidate = nil
                continue
            }

            if let candidate = setextCandidate, let level = Self.setextLevel(trimmed) {
                let title = Self.plainText(candidate)
                headings.append(Heading(title: title, level: level, anchor: slugger.anchor(for: title)))
                setextCandidate = nil
                continue
            }

            if let reference = Self.referenceDefinition(trimmed) {
                // Per CommonMark the first definition of a label wins.
                if seenReferences.insert(reference.label.lowercased()).inserted {
                    references.append(reference)
                }
                setextCandidate = nil
                continue
            }

            setextCandidate = Self.canBeSetextText(trimmed) ? String(trimmed) : nil
        }
    }

    // MARK: Line classification

    private static func fenceMarker(_ line: Substring) -> (marker: Character, count: Int)? {
        guard let first = line.first, first == "`" || first == "~" else { return nil }
        let count = line.prefix(while: { $0 == first }).count
        return count >= 3 ? (first, count) : nil
    }

    private static func atxHeading(_ line: Substring) -> (Int, String)? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes) else { return nil }
        var rest = line.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " || rest.first == "\t" else { return nil }
        rest = rest.drop(while: { $0 == " " || $0 == "\t" })
        // Optional closing sequence: `## Title ##`.
        var body = String(rest).trimmingCharacters(in: .whitespaces)
        if let range = body.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            body = String(body[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (hashes, plainText(body))
    }

    private static func setextLevel(_ line: Substring) -> Int? {
        let body = line.trimmingCharacters(in: .whitespaces)
        guard let first = body.first, first == "=" || first == "-" else { return nil }
        guard body.allSatisfy({ $0 == first }) else { return nil }
        return first == "=" ? 1 : 2
    }

    /// Paragraph text only; list items, quotes, tables and HTML followed by
    /// `---` are a thematic break, not a heading, in practice.
    private static func canBeSetextText(_ line: Substring) -> Bool {
        guard let first = line.first else { return false }
        if "-*+>|<".contains(first) { return false }
        if first.isNumber, line.range(of: #"^\d+[.)](\s|$)"#, options: .regularExpression) != nil { return false }
        return true
    }

    private static func referenceDefinition(_ line: Substring) -> Reference? {
        guard line.first == "[", line.dropFirst().first != "^",
              let close = line.firstIndex(of: "]") else { return nil }
        let label = line[line.index(after: line.startIndex)..<close]
        let afterClose = line[line.index(after: close)...]
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty, afterClose.first == ":" else { return nil }
        let destination = afterClose.dropFirst().trimmingCharacters(in: .whitespaces)
            .split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
        return Reference(label: String(label), destination: destination)
    }

    /// What GitHub renders: link text instead of `[text](url)`, image alt
    /// text, no emphasis or code markers. Punctuation is dropped later by
    /// the slugger anyway; this mainly keeps URLs out of anchors and labels.
    static func plainText(_ markdown: String) -> String {
        var text = markdown
        text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"!?\[([^\]]*)\]\[[^\]]*\]"#, with: "$1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(\*\*|__|\*|`|~~)"#, with: "", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
    }
}

/// GitHub's heading-anchor algorithm: lowercase, drop everything that is not
/// a letter, digit, space, `-` or `_`, turn spaces into `-`, and suffix
/// repeats with `-1`, `-2`, … so every anchor in the document is unique.
struct AnchorSlugger: Sendable {
    private var used: [String: Int] = [:]

    static func slug(_ text: String) -> String {
        var result = ""
        for character in text.lowercased() {
            if character == " " {
                result.append("-")
            } else if character == "-" || character == "_" || character.isLetter || character.isNumber {
                result.append(character)
            }
        }
        return result
    }

    mutating func anchor(for text: String) -> String {
        let base = Self.slug(text)
        guard let count = used[base] else {
            used[base] = 1
            return base
        }
        // `a`, `a`, `a-1` must give `a`, `a-1`, `a-1-1`: keep counting until
        // the suffixed name is itself unused.
        var n = count
        var candidate = "\(base)-\(n)"
        while used[candidate] != nil {
            n += 1
            candidate = "\(base)-\(n)"
        }
        used[base] = n + 1
        used[candidate] = 1
        return candidate
    }
}

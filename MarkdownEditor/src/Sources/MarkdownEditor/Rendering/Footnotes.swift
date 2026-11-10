import Foundation

/// GitHub-style footnotes for the preview and the PDF.
///
/// ```
/// A claim.[^1]
///
/// [^1]: The source, with *Markdown* inside.
///     An indented line continues the note.
/// ```
///
/// swift-markdown has no footnote nodes, so this is a source rewrite before
/// parsing, next to `MathBlocks`' `$$` rewrite:
///
/// - each definition's lines become **empty lines**, so every other line
///   keeps its number (scroll sync and diagnostics map by line);
/// - each reference becomes `<sup class="footnote-ref"><a …>n</a></sup>`,
///   numbered by first use — inline HTML that the preview shows as a link
///   and the PDF renderer as a superscript number;
/// - the notes are appended after a rule as an ordered list inside a
///   `<section class="footnotes">`, each with a back link.
///
/// References without a definition stay as typed, like on GitHub; so do
/// definitions nobody references (they are dropped from the output). Fenced
/// code and inline code are left alone.
enum Footnotes {
    struct Note: Equatable {
        var label: String
        var text: String
    }

    static func rewrite(_ markdown: String) -> String {
        // Cheap bail-out: every keystroke passes here.
        guard markdown.contains("[^") else { return markdown }

        var lines = markdown.components(separatedBy: "\n")
        let definitions = extractDefinitions(&lines)
        guard !definitions.isEmpty else { return markdown }

        var numbers: [String: Int] = [:]
        var order: [String] = []
        var inFence: (character: Character, length: Int)?
        for index in lines.indices {
            if let fence = inFence {
                if closesFence(lines[index], fence) { inFence = nil }
                continue
            }
            if let fence = opensFence(lines[index]) {
                inFence = fence
                continue
            }
            lines[index] = replacingReferences(in: lines[index], definitions: definitions) { label in
                if let number = numbers[label] { return (number, false) }
                order.append(label)
                numbers[label] = order.count
                return (order.count, true)
            }
        }
        guard !order.isEmpty else { return lines.joined(separator: "\n") }

        var notes = ["", "---", "", "<section class=\"footnotes\">", ""]
        for (offset, label) in order.enumerated() {
            let number = offset + 1
            let body = (definitions[label] ?? "")
                // Continuation lines are list-item content: indent them.
                .replacingOccurrences(of: "\n", with: "\n    ")
            notes.append("\(number). <span id=\"fn-\(number)\"></span>\(body) <a href=\"#fnref-\(number)\" class=\"footnote-back\">↩</a>")
        }
        notes += ["", "</section>", ""]
        return lines.joined(separator: "\n") + "\n" + notes.joined(separator: "\n")
    }

    // MARK: Definitions

    /// Removes `[^label]: text` definitions (plus indented continuation
    /// lines) by blanking them, and returns label → note text.
    private static func extractDefinitions(_ lines: inout [String]) -> [String: String] {
        var definitions: [String: String] = [:]
        var inFence: (character: Character, length: Int)?
        var index = 0
        while index < lines.count {
            let line = lines[index]
            if let fence = inFence {
                if closesFence(line, fence) { inFence = nil }
                index += 1
                continue
            }
            if let fence = opensFence(line) {
                inFence = fence
                index += 1
                continue
            }
            guard let (label, first) = definition(in: line) else {
                index += 1
                continue
            }
            var body = [first]
            lines[index] = ""
            index += 1
            // Continuation: indented lines, possibly after blank lines.
            while index < lines.count {
                if isIndented(lines[index]) {
                    body.append(lines[index].trimmingCharacters(in: .whitespaces))
                    lines[index] = ""
                    index += 1
                } else if lines[index].trimmingCharacters(in: .whitespaces).isEmpty,
                          index + 1 < lines.count, isIndented(lines[index + 1]) {
                    body.append("")
                    index += 1
                } else {
                    break
                }
            }
            // The first definition of a label wins, as for link references.
            if definitions[label] == nil {
                definitions[label] = body.joined(separator: "\n")
            }
        }
        return definitions
    }

    /// `[^label]: text` with at most three spaces of indentation.
    static func definition(in line: String) -> (label: String, text: String)? {
        let indent = line.prefix(while: { $0 == " " })
        guard indent.count <= 3 else { return nil }
        let rest = line.dropFirst(indent.count)
        guard rest.hasPrefix("[^"), let close = rest.firstIndex(of: "]") else { return nil }
        let label = rest[rest.index(rest.startIndex, offsetBy: 2)..<close]
        guard !label.isEmpty, !label.contains(where: \.isWhitespace) else { return nil }
        let afterClose = rest[rest.index(after: close)...]
        guard afterClose.hasPrefix(":") else { return nil }
        return (String(label), afterClose.dropFirst().trimmingCharacters(in: .whitespaces))
    }

    private static func isIndented(_ line: String) -> Bool {
        line.hasPrefix("    ") || line.hasPrefix("\t")
    }

    // MARK: References

    /// Replaces `[^label]` with a superscript link, skipping inline code
    /// spans. `number` returns the footnote number and whether this is the
    /// first reference (only that one carries the back link's anchor).
    private static func replacingReferences(
        in line: String,
        definitions: [String: String],
        number: (String) -> (Int, Bool)
    ) -> String {
        guard line.contains("[^") else { return line }
        let characters = Array(line)
        var output = ""
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "`" {
                // Copy a whole code span verbatim.
                var run = 0
                while index + run < characters.count, characters[index + run] == "`" { run += 1 }
                if let end = closingBackticks(characters, from: index + run, length: run) {
                    output += String(characters[index..<end + run])
                    index = end + run
                } else {
                    output += String(characters[index..<index + run])
                    index += run
                }
                continue
            }
            if character == "[", index + 1 < characters.count, characters[index + 1] == "^",
               let close = characters[(index + 2)...].firstIndex(of: "]") {
                let label = String(characters[(index + 2)..<close])
                let followedByColon = close + 1 < characters.count && characters[close + 1] == ":"
                if !label.isEmpty, definitions[label] != nil, !followedByColon {
                    let (n, isFirst) = number(label)
                    let anchor = isFirst ? " id=\"fnref-\(n)\"" : ""
                    output += "<sup class=\"footnote-ref\"><a href=\"#fn-\(n)\"\(anchor)>\(n)</a></sup>"
                    index = close + 1
                    continue
                }
            }
            output.append(character)
            index += 1
        }
        return output
    }

    private static func closingBackticks(_ characters: [Character], from start: Int, length: Int) -> Int? {
        var index = start
        while index < characters.count {
            if characters[index] == "`" {
                var run = 0
                while index + run < characters.count, characters[index + run] == "`" { run += 1 }
                if run == length { return index }
                index += run
            } else {
                index += 1
            }
        }
        return nil
    }

    // MARK: Fences

    private static func opensFence(_ line: String) -> (character: Character, length: Int)? {
        let trimmed = line.drop(while: { $0 == " " })
        guard line.count - trimmed.count <= 3, let first = trimmed.first, first == "`" || first == "~" else { return nil }
        let length = trimmed.prefix(while: { $0 == first }).count
        return length >= 3 ? (first, length) : nil
    }

    private static func closesFence(_ line: String, _ fence: (character: Character, length: Int)) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= fence.length && trimmed.allSatisfy { $0 == fence.character }
    }
}

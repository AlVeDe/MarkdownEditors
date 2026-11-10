import Foundation

/// Extracts the names a diagram already defines (node ids, participants,
/// classes, states, entities, branches) so completion can offer them where an
/// identifier is expected.
///
/// These are line-based heuristics, not a parser: Mermaid's grammars are
/// large and a half-typed diagram rarely parses anyway. Missing a name is
/// harmless; inventing one from label text is what the scanners try hardest
/// to avoid, so labels, strings and comments are stripped first.
enum MermaidIdentifiers {
    /// Names in first-appearance order, without duplicates. `lines` are the
    /// diagram's body lines (after the type line).
    static func scan(_ lines: [String], type: MermaidDiagramType) -> [String] {
        var names = OrderedNames()
        switch type {
        case .flowchart: flowchart(lines, into: &names)
        case .sequence: sequence(lines, into: &names)
        case .classDiagram: classDiagram(lines, into: &names)
        case .state: state(lines, into: &names)
        case .er: er(lines, into: &names)
        case .gitGraph: gitGraph(lines, into: &names)
        default: break
        }
        return names.list
    }

    /// What one identifier is, for the grey detail text.
    static func noun(for type: MermaidDiagramType) -> String {
        switch type {
        case .flowchart: "node"
        case .sequence: "participant"
        case .classDiagram: "class"
        case .state: "state"
        case .er: "entity"
        case .gitGraph: "branch"
        default: "identifier"
        }
    }

    // MARK: Flowchart

    private static let flowchartSkip: Set<String> = ["classDef", "class", "style", "linkStyle", "click", "direction", "end"]
    /// `A -- text --> B`, `A == text ==> B`, `A -. text .-> B`: the text
    /// between the two halves of the arrow is a label, not a node.
    private static let edgeText = regex(#"(?<![-=.<])(--|==|-\.)\s+[^\s\-=.>|][^|]*?\s+(-->|---|==>|===|\.->|-\.-|--[ox]|==[ox])"#)
    private static let quoted = regex(#""[^"]*""#)
    private static let pipeLabel = regex(#"\|[^|]*\|"#)

    private static func flowchart(_ lines: [String], into names: inout OrderedNames) {
        for raw in lines {
            var line = stripComment(raw).trimmingCharacters(in: .whitespaces)
            let first = firstWord(line)
            if flowchartSkip.contains(first) { continue }
            if first == "subgraph" {
                // `subgraph id [Title]` or `subgraph id`: edges may target the id.
                let rest = line.dropFirst("subgraph".count).trimmingCharacters(in: .whitespaces)
                let id = String(rest.prefix(while: isIdentifierChar))
                let after = rest.dropFirst(id.count).trimmingCharacters(in: .whitespaces)
                if !id.isEmpty, after.isEmpty || after.hasPrefix("[") { names.add(id) }
                continue
            }
            line = replace(edgeText, in: line, with: " --> ")
            line = replace(quoted, in: line, with: "\"\"")
            line = replace(pipeLabel, in: line, with: " ")
            tokenizeFlowchart(line, into: &names)
        }
    }

    /// Walks a flowchart statement, collecting identifier tokens and skipping
    /// over shape brackets (whose content is label text).
    private static func tokenizeFlowchart(_ line: String, into names: inout OrderedNames) {
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if isIdentifierChar(c) {
                let start = i
                while i < chars.count, isIdentifierChar(chars[i]) { i += 1 }
                let word = String(chars[start..<i])
                let next: Character? = i < chars.count ? chars[i] : nil
                let previous: Character? = start > 0 ? chars[start - 1] : nil
                // `e1@-->` names an edge; `A:::cls` applies a class.
                let isEdgeID = next == "@" && (i + 1 >= chars.count || chars[i + 1] != "{")
                let isClassName = start >= 3 && String(chars[start - 3..<start]) == ":::"
                // The `o`/`x` of `--o`, `--x`, `o--o`, `x--x`.
                let isArrowEnd = (word == "o" || word == "x")
                    && ("-=.".contains(previous ?? " ") || "-=.<".contains(next ?? " "))
                if !isEdgeID, !isClassName, !isArrowEnd { names.add(word) }
                if next == ">" {
                    // `id>flag text]`: skip to the closing bracket.
                    while i < chars.count, chars[i] != "]" { i += 1 }
                    i += 1
                }
                continue
            }
            if "[({".contains(c) {
                var depth = 0
                repeat {
                    if "[({".contains(chars[i]) { depth += 1 } else if "])}".contains(chars[i]) { depth -= 1 }
                    i += 1
                } while i < chars.count && depth > 0
                continue
            }
            i += 1
        }
    }

    // MARK: Sequence

    private static let participant = regex(#"^\s*(?:create\s+)?(?:participant|actor)\s+([^\s@]+)"#)
    private static let message = regex(#"^\s*([^\s:+\-<>,]+)\s*(?:<<)?--?(?:>>|>|x|\))\s*[+\-]?\s*([^\s:+\-,][^\s:,]*)\s*:"#)

    private static func sequence(_ lines: [String], into names: inout OrderedNames) {
        for raw in lines {
            let line = stripComment(raw)
            if let m = firstMatch(participant, line) { names.add(m[0]); continue }
            if let m = firstMatch(message, line) { names.add(m[0]); names.add(m[1]) }
        }
    }

    // MARK: Class

    private static let classDecl = regex(#"^\s*class\s+([A-Za-z0-9_]+)"#)
    private static let annotated = regex(#"^\s*<<[^>]*>>\s*([A-Za-z0-9_]+)"#)
    private static let classRelation = regex(#"([A-Za-z0-9_]+)(?:~[^~]*~)?\s*(?:"[^"]*")?\s*(?:<\||\*|o|<)?(?:--|\.\.)(?:\|>|>|\*|o)?\s*(?:"[^"]*")?\s*([A-Za-z0-9_]+)"#)
    private static let classMember = regex(#"^\s*([A-Za-z0-9_]+)\s*:"#)

    private static func classDiagram(_ lines: [String], into names: inout OrderedNames) {
        var depth = 0
        for raw in lines {
            let line = stripComment(raw)
            let wasInside = depth > 0
            depth = max(0, depth + line.count(where: { $0 == "{" }) - line.count(where: { $0 == "}" }))
            if firstWord(line) == "namespace" { continue }
            if let m = firstMatch(classDecl, line) { names.add(m[0]); continue }
            // Member lines inside `class X { … }` are not names; `namespace`
            // bodies are, but they only hold `class` lines handled above.
            if wasInside { continue }
            if let m = firstMatch(annotated, line) { names.add(m[0]); continue }
            if let m = firstMatch(classRelation, line) { names.add(m[0]); names.add(m[1]); continue }
            if let m = firstMatch(classMember, line) { names.add(m[0]) }
        }
    }

    // MARK: State

    private static let stateAs = regex(#"^\s*state\s+"[^"]*"\s+as\s+([A-Za-z0-9_]+)"#)
    private static let stateDecl = regex(#"^\s*state\s+([A-Za-z0-9_]+)"#)
    private static let transition = regex(#"([A-Za-z0-9_]+|\[\*\])\s*-->\s*([A-Za-z0-9_]+|\[\*\])"#)
    private static let stateDescription = regex(#"^\s*([A-Za-z0-9_]+)\s*:"#)
    private static let stateSkip: Set<String> = ["note", "classDef", "class", "direction", "end", "style"]

    private static func state(_ lines: [String], into names: inout OrderedNames) {
        var inNote = false
        for raw in lines {
            let line = stripComment(raw)
            let first = firstWord(line)
            if inNote { if first == "end" { inNote = false }; continue }
            if first == "note" { inNote = !line.contains(":"); continue }
            if stateSkip.contains(first) { continue }
            if let m = firstMatch(stateAs, line) ?? firstMatch(stateDecl, line) { names.add(m[0]); continue }
            if let m = firstMatch(transition, line) {
                for name in m where name != "[*]" { names.add(name) }
                continue
            }
            if let m = firstMatch(stateDescription, line) { names.add(m[0]) }
        }
    }

    // MARK: ER

    private static let erRelation = regex(#"^\s*([A-Za-z0-9_\-]+)\s*(?:\|o|\|\||\}o|\}\|)(?:--|\.\.)(?:o\||\|\||o\{|\|\{)\s*([A-Za-z0-9_\-]+)"#)
    private static let erEntity = regex(#"^\s*([A-Za-z0-9_\-]+)\s*(?:\[[^\]]*\])?\s*(?:\{.*)?$"#)

    private static func er(_ lines: [String], into names: inout OrderedNames) {
        var depth = 0
        for raw in lines {
            let line = stripComment(raw)
            // Relationship lines contain `{` as crow's feet, not as a block.
            if depth == 0, let m = firstMatch(erRelation, line) { names.add(m[0]); names.add(m[1]); continue }
            let wasInside = depth > 0
            depth = max(0, depth + line.count(where: { $0 == "{" }) - line.count(where: { $0 == "}" }))
            if wasInside { continue } // attribute lines
            if let m = firstMatch(erEntity, line), m[0] != "direction" { names.add(m[0]) }
        }
    }

    // MARK: gitGraph

    private static let branchRef = regex(#"^\s*(?:branch|checkout|switch|merge)\s+(?:"([^"]+)"|([^\s"]+))"#)

    private static func gitGraph(_ lines: [String], into names: inout OrderedNames) {
        names.add("main")
        for raw in lines {
            if let m = firstMatch(branchRef, stripComment(raw)) { names.add(m[0].isEmpty ? m[1] : m[0]) }
        }
    }

    // MARK: Helpers

    struct OrderedNames {
        private(set) var list: [String] = []
        private var seen: Set<String> = []
        mutating func add(_ name: String) {
            guard !name.isEmpty, seen.insert(name).inserted else { return }
            list.append(name)
        }
    }

    static func isIdentifierChar(_ c: Character) -> Bool {
        c == "_" || c.isLetter || c.isNumber
    }

    private static func regex(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(pattern: pattern)
    }

    private static func stripComment(_ line: String) -> String {
        guard let range = line.range(of: "%%") else { return line }
        return String(line[..<range.lowerBound])
    }

    private static func firstWord(_ line: String) -> String {
        String(line.drop(while: { $0 == " " || $0 == "\t" }).prefix(while: { $0 != " " && $0 != "\t" }))
    }

    private static func replace(_ re: NSRegularExpression?, in line: String, with template: String) -> String {
        guard let re else { return line }
        return re.stringByReplacingMatches(in: line, range: NSRange(location: 0, length: (line as NSString).length),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: template))
    }

    /// The capture groups of the first match (unmatched groups as "").
    private static func firstMatch(_ re: NSRegularExpression?, _ line: String) -> [String]? {
        let ns = line as NSString
        guard let re, let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
}

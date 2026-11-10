import Foundation

/// One row of a Mermaid completion table. Kept separate from
/// `CompletionItem` so the tables stay compact and the provider decides kind
/// and ranking by where the entry is offered.
struct MermaidEntry: Sendable {
    var label: String
    var insert: String
    var detail: String
    var doc: String

    init(_ label: String, _ insert: String, _ detail: String, _ doc: String = "") {
        self.label = label
        self.insert = insert
        self.detail = detail
        self.doc = doc
    }

    /// True when `insert` is more than the label itself (placeholders or
    /// multiple lines), which makes it a snippet rather than a keyword.
    var isSnippet: Bool { insert.contains("$") || insert.contains("\n") }
}

/// The diagram kinds Mermaid 11.16 (the version bundled in
/// `Resources/mermaid.min.js`) understands, as far as completion supports
/// them. Every header here is accepted by that version's detectors.
enum MermaidDiagramType: String, CaseIterable, Sendable {
    case flowchart, sequence, classDiagram, state, er, journey, gantt, pie
    case quadrant, requirement, gitGraph, mindmap, timeline, sankey, xychart
    case block, packet, architecture, kanban, radar, treemap

    /// Header keywords Mermaid accepts for each type (aliases included), so
    /// a document written by hand with e.g. `graph` or `stateDiagram` is
    /// still recognized.
    private static let headers: [String: MermaidDiagramType] = [
        "flowchart": .flowchart, "graph": .flowchart, "flowchart-elk": .flowchart,
        "sequenceDiagram": .sequence,
        "classDiagram": .classDiagram, "classDiagram-v2": .classDiagram,
        "stateDiagram": .state, "stateDiagram-v2": .state,
        "erDiagram": .er, "journey": .journey, "gantt": .gantt, "pie": .pie,
        "quadrantChart": .quadrant, "requirementDiagram": .requirement,
        "gitGraph": .gitGraph, "mindmap": .mindmap, "timeline": .timeline,
        "sankey-beta": .sankey, "sankey": .sankey,
        "xychart-beta": .xychart, "xychart": .xychart,
        "block-beta": .block, "block": .block,
        "packet-beta": .packet, "packet": .packet,
        "architecture-beta": .architecture,
        "kanban": .kanban, "radar-beta": .radar,
        "treemap-beta": .treemap, "treemap": .treemap,
    ]

    /// The type named by a diagram's first line (`flowchart LR`,
    /// `gitGraph:` …), or nil when the line names no known type.
    init?(typeLine: String) {
        let word = typeLine.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == ":" }).first
        guard let word, let type = Self.headers[String(word)] else { return nil }
        self = type
    }

    /// Items for the header line: one ready-to-render template per type.
    /// Templates avoid repeating a placeholder number, since mirrored
    /// placeholders are not part of the snippet contract.
    static let templates: [MermaidEntry] = [
        MermaidEntry("flowchart", "flowchart ${1:TD}\n\tA[${2:Start}] --> B{${3:Decision}}\n\tB -->|Yes| C[${4:Done}]\n\tB -->|No| D[${5:Retry}]$0",
                     "flowchart", "Nodes connected by edges. Direction TD/TB (top-down), BT, LR or RL."),
        MermaidEntry("graph", "graph ${1:LR}\n\tA[${2:Start}] --> B[${3:End}]$0",
                     "flowchart (classic)", "The original keyword for flowcharts; same syntax as `flowchart`."),
        MermaidEntry("sequenceDiagram", "sequenceDiagram\n\tparticipant A as ${1:Alice}\n\tparticipant B as ${2:Bob}\n\tA->>B: ${3:Hello}\n\tB-->>A: ${4:Hi}$0",
                     "sequence diagram", "Messages exchanged between participants over time."),
        MermaidEntry("classDiagram", "classDiagram\n\tclass Animal {\n\t\t+${1:String} ${2:name}\n\t\t+${3:speak}() void\n\t}\n\tAnimal <|-- ${4:Dog}$0",
                     "class diagram", "UML classes with members and relationships."),
        MermaidEntry("stateDiagram-v2", "stateDiagram-v2\n\t[*] --> Idle\n\tIdle --> Running : ${1:start}\n\tRunning --> Idle : ${2:stop}\n\tRunning --> [*]$0",
                     "state diagram", "States and transitions; [*] is the start or end state."),
        MermaidEntry("erDiagram", "erDiagram\n\tCUSTOMER ||--o{ ORDER : ${1:places}\n\tCUSTOMER {\n\t\tstring ${2:name}\n\t}\n\tORDER {\n\t\tint ${3:id} PK\n\t}$0",
                     "entity relationship", "Entities with attributes and crow's-foot relationships."),
        MermaidEntry("journey", "journey\n\ttitle ${1:My working day}\n\tsection ${2:Go to work}\n\t\t${3:Make tea}: ${4:5}: ${5:Me}$0",
                     "user journey", "Tasks per section, each with a score 1–5 and the actors involved."),
        MermaidEntry("gantt", "gantt\n\ttitle ${1:Project}\n\tdateFormat YYYY-MM-DD\n\tsection ${2:Phase 1}\n\t\t${3:Design} :a1, ${4:2026-01-01}, ${5:7d}\n\t\t${6:Build} :after a1, ${7:10d}$0",
                     "gantt chart", "Tasks on a timeline, grouped into sections."),
        MermaidEntry("pie", "pie title ${1:Pets}\n\t\"${2:Dogs}\" : ${3:40}\n\t\"${4:Cats}\" : ${5:35}$0",
                     "pie chart", "Slices given as \"label\" : value. Add showData to print the values."),
        MermaidEntry("quadrantChart", "quadrantChart\n\ttitle ${1:Reach and engagement}\n\tx-axis ${2:Low Reach} --> ${3:High Reach}\n\ty-axis ${4:Low Engagement} --> ${5:High Engagement}\n\tquadrant-1 ${6:Expand}\n\tquadrant-2 ${7:Promote}\n\tquadrant-3 ${8:Re-evaluate}\n\tquadrant-4 ${9:Improve}\n\t${10:Campaign A}: [${11:0.3}, ${12:0.6}]$0",
                     "quadrant chart", "Points plotted on two axes split into four quadrants; coordinates 0–1."),
        MermaidEntry("requirementDiagram", "requirementDiagram\n\trequirement test_req {\n\t\tid: 1\n\t\ttext: ${1:the test text}\n\t\trisk: ${2:high}\n\t\tverifymethod: ${3:test}\n\t}\n\telement test_entity {\n\t\ttype: ${4:simulation}\n\t}\n\ttest_entity - satisfies -> test_req$0",
                     "requirement diagram", "SysML requirements, elements and their relationships."),
        MermaidEntry("gitGraph", "gitGraph\n\tcommit\n\tbranch develop\n\tcheckout develop\n\tcommit id: \"${1:feature}\"\n\tcheckout main\n\tmerge develop$0",
                     "git graph", "Commits, branches and merges. The default branch is main."),
        MermaidEntry("mindmap", "mindmap\n\troot((${1:Topic}))\n\t\t${2:Idea A}\n\t\t\t${3:Detail}\n\t\t${4:Idea B}$0",
                     "mind map", "A tree defined by indentation; the first node is the root."),
        MermaidEntry("timeline", "timeline\n\ttitle ${1:History}\n\t${2:2025} : ${3:Event}\n\t${4:2026} : ${5:Event}$0",
                     "timeline", "Time periods, each with one or more events."),
        MermaidEntry("sankey-beta", "sankey-beta\n\n${1:Source},${2:Target},${3:10}$0",
                     "sankey (beta)", "Flows as CSV rows: source,target,value."),
        MermaidEntry("xychart-beta", "xychart-beta\n\ttitle \"${1:Sales}\"\n\tx-axis [${2:jan, feb, mar}]\n\ty-axis \"${3:Revenue}\" 0 --> ${4:100}\n\tbar [${5:30, 60, 90}]\n\tline [${6:30, 60, 90}]$0",
                     "xy chart (beta)", "Bar and line series over a categorical or numeric x-axis."),
        MermaidEntry("block-beta", "block-beta\n\tcolumns ${1:3}\n\t${2:a} ${3:b} ${4:c}$0",
                     "block diagram (beta)", "Blocks laid out in columns, with full control over placement."),
        MermaidEntry("packet-beta", "packet-beta\n\t0-15: \"${1:Source Port}\"\n\t16-31: \"${2:Destination Port}\"$0",
                     "packet (beta)", "Bit ranges of a network packet."),
        MermaidEntry("architecture-beta", "architecture-beta\n\tgroup api(cloud)[${1:API}]\n\tservice db(database)[${2:Database}] in api\n\tservice server(server)[${3:Server}] in api\n\tdb:L -- R:server$0",
                     "architecture (beta)", "Services and groups connected at their sides (L, R, T, B)."),
        MermaidEntry("kanban", "kanban\n\ttodo[${1:Todo}]\n\t\tt1[${2:Write docs}]\n\tdone[${3:Done}]$0",
                     "kanban board", "Columns with indented task cards."),
        MermaidEntry("radar-beta", "radar-beta\n\taxis a[\"${1:A}\"], b[\"${2:B}\"], c[\"${3:C}\"]\n\tcurve x[\"${4:Series}\"]{${5:1, 2, 3}}$0",
                     "radar chart (beta)", "Curves plotted over several axes."),
        MermaidEntry("treemap-beta", "treemap-beta\n\t\"${1:Root}\"\n\t\t\"${2:Leaf A}\": ${3:10}\n\t\t\"${4:Leaf B}\": ${5:20}$0",
                     "treemap (beta)", "Nested rectangles sized by value, nesting by indentation."),
    ]

    /// Directions accepted after `flowchart`/`graph` and by `direction`.
    static let directions: [MermaidEntry] = [
        MermaidEntry("TD", "TD", "top down"), MermaidEntry("TB", "TB", "top to bottom"),
        MermaidEntry("BT", "BT", "bottom to top"), MermaidEntry("LR", "LR", "left to right"),
        MermaidEntry("RL", "RL", "right to left"),
    ]

    /// Orientation options after `gitGraph` (the colon is required there).
    static let gitGraphOrientations: [MermaidEntry] = [
        MermaidEntry("LR:", "LR:", "left to right"), MermaidEntry("TB:", "TB:", "top to bottom"),
        MermaidEntry("BT:", "BT:", "bottom to top"),
    ]
}

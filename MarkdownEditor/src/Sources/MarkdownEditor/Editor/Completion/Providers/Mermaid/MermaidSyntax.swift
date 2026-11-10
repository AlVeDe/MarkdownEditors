import Foundation

/// Keyword, snippet and arrow tables per diagram type. Only syntax that the
/// bundled Mermaid 11.16 renders is listed.
enum MermaidSyntax {
    private typealias E = MermaidEntry

    /// Valid in every diagram type.
    static let common: [MermaidEntry] = [
        E("%%{init}%%", "%%{init: {\"theme\": \"${1:default}\"}}%%", "init directive",
          "Per-diagram configuration. Themes: default, dark, forest, neutral, base."),
        E("%% comment", "%% ${1:comment}", "comment", "A line starting with %% is ignored."),
        E("accTitle", "accTitle: ${1:title}", "accessibility title", "Title read by screen readers."),
        E("accDescr", "accDescr: ${1:description}", "accessibility description", "Description read by screen readers."),
        E("accDescr { }", "accDescr {\n\t${1:description}\n}", "multi-line description"),
    ]

    static func keywords(for type: MermaidDiagramType) -> [MermaidEntry] {
        switch type {
        case .flowchart: flowchart
        case .sequence: sequence
        case .classDiagram: classDiagram
        case .state: state
        case .er: er
        case .gantt: gantt
        case .pie: pie
        case .gitGraph: gitGraph
        case .mindmap: mindmap
        case .timeline: timeline
        case .journey: journey
        case .quadrant: quadrant
        case .requirement: requirement
        case .xychart: xychart
        case .sankey: [E("row", "${1:Source},${2:Target},${3:10}", "flow", "One flow: source,target,value.")]
        case .block: block
        case .packet: [E("field", "${1:0}-${2:15}: \"${3:Field}\"", "bit range")]
        case .architecture: architecture
        case .kanban: [E("card", "${1:id}[${2:Task}]", "card"),
                       E("@{ }", "@{ assigned: '${1:name}', priority: '${2:High}' }", "card metadata")]
        case .radar: [E("axis", "axis ${1:a}[\"${2:A}\"]", "axis"), E("curve", "curve ${1:c}[\"${2:Series}\"]{${3:1, 2, 3}}", "curve"),
                      E("max", "max ${1:10}", "scale maximum"), E("min", "min ${1:0}", "scale minimum")]
        case .treemap: [E("leaf", "\"${1:Leaf}\": ${2:10}", "leaf with value"), E("section", "\"${1:Section}\"", "parent node")]
        }
    }

    /// Edge operators; offered when the caret follows arrow characters.
    static func arrows(for type: MermaidDiagramType) -> [MermaidEntry] {
        switch type {
        case .flowchart: flowchartArrows
        case .sequence: sequenceArrows
        case .classDiagram: classArrows
        case .state: [E("-->", "-->", "transition")]
        case .er: erArrows
        case .requirement: [E("- satisfies ->", "- ${1:satisfies} -> ", "relationship",
                              "contains, copies, derives, satisfies, verifies, refines, traces")]
        case .block, .quadrant, .xychart: [E("-->", "-->", "arrow")]
        case .architecture: [E("--", "--", "edge"), E("-->", "-->", "edge with arrow"), E("<-->", "<-->", "bidirectional")]
        default: []
        }
    }

    // MARK: Flowchart

    private static let flowchart: [MermaidEntry] = [
        E("subgraph", "subgraph ${1:title}\n\t$0\nend", "group nodes", "A titled box around nodes; may contain `direction`."),
        E("end", "end", "close subgraph"),
        E("direction", "direction ${1:LR}", "subgraph direction", "TB, TD, BT, LR or RL."),
        E("id[text]", "${1:id}[${2:text}]", "rectangle"),
        E("id(text)", "${1:id}(${2:text})", "rounded rectangle"),
        E("id([text])", "${1:id}([${2:text}])", "stadium"),
        E("id[[text]]", "${1:id}[[${2:text}]]", "subroutine"),
        E("id[(text)]", "${1:id}[(${2:text})]", "cylinder / database"),
        E("id((text))", "${1:id}((${2:text}))", "circle"),
        E("id{text}", "${1:id}{${2:text}}", "rhombus / decision"),
        E("id{{text}}", "${1:id}{{${2:text}}}", "hexagon"),
        E("id>text]", "${1:id}>${2:text}]", "asymmetric / flag"),
        E("id[/text/]", "${1:id}[/${2:text}/]", "parallelogram"),
        E("id@{ shape }", "${1:id}@{ shape: ${2:rounded}, label: \"${3:text}\" }", "v11 shape syntax",
          "Expanded shapes: rect, rounded, stadium, diamond, hex, cyl, circle, doc, notch-rect, …"),
        E("classDef", "classDef ${1:name} fill:${2:#f9f},stroke:${3:#333}", "define style class"),
        E("class", "class ${1:nodeId} ${2:className}", "apply style class", "Comma-separate several node ids."),
        E("style", "style ${1:nodeId} fill:${2:#f9f},stroke:${3:#333},stroke-width:${4:2px}", "style one node"),
        E("linkStyle", "linkStyle ${1:0} stroke:${2:#f66},stroke-width:${3:2px}", "style an edge", "Edges are numbered from 0 in order of definition; `default` styles all."),
        E("click", "click ${1:nodeId} href \"${2:https://}\" \"${3:tooltip}\"", "link a node"),
    ]

    private static let flowchartArrows: [MermaidEntry] = [
        E("-->", "-->", "arrow"), E("---", "---", "open link"),
        E("-.->", "-.->", "dotted arrow"), E("-.-", "-.-", "dotted link"),
        E("==>", "==>", "thick arrow"), E("===", "===", "thick link"),
        E("-->|text|", "-->|${1:text}| ", "arrow with label"),
        E("-- text -->", "-- ${1:text} --> ", "arrow with label"),
        E("--o", "--o", "circle end"), E("--x", "--x", "cross end"),
        E("<-->", "<-->", "bidirectional"), E("o--o", "o--o", "circle both ends"), E("x--x", "x--x", "cross both ends"),
        E("~~~", "~~~", "invisible link", "Influences layout without drawing a line."),
    ]

    // MARK: Sequence

    private static let sequence: [MermaidEntry] = [
        E("participant", "participant ${1:A}", "declare participant", "Declaring fixes the order of participants."),
        E("participant as", "participant ${1:A} as ${2:Alice}", "participant with alias"),
        E("actor", "actor ${1:A}", "declare actor", "Like a participant, drawn as a stick figure."),
        E("actor as", "actor ${1:A} as ${2:Alice}", "actor with alias"),
        E("create participant", "create participant ${1:B}", "create on message"),
        E("destroy", "destroy ${1:B}", "destroy after message"),
        E("Note right of", "Note right of ${1:A}: ${2:text}", "note"),
        E("Note left of", "Note left of ${1:A}: ${2:text}", "note"),
        E("Note over", "Note over ${1:A},${2:B}: ${3:text}", "note spanning participants"),
        E("loop", "loop ${1:Every minute}\n\t$0\nend", "loop block"),
        E("alt", "alt ${1:condition}\n\t$2\nelse ${3:otherwise}\n\t$0\nend", "alternatives"),
        E("else", "else ${1:condition}", "alternative branch"),
        E("opt", "opt ${1:condition}\n\t$0\nend", "optional block"),
        E("par", "par ${1:first}\n\t$2\nand ${3:second}\n\t$0\nend", "parallel block"),
        E("and", "and ${1:label}", "parallel branch"),
        E("critical", "critical ${1:action}\n\t$2\noption ${3:failure}\n\t$0\nend", "critical region"),
        E("option", "option ${1:label}", "critical alternative"),
        E("break", "break ${1:condition}\n\t$0\nend", "break out of sequence"),
        E("rect", "rect rgb(${1:191, 223, 255})\n\t$0\nend", "highlight background"),
        E("box", "box ${1:Aqua} ${2:Group}\n\tparticipant $0\nend", "group participants"),
        E("activate", "activate ${1:A}", "start activation"),
        E("deactivate", "deactivate ${1:A}", "end activation"),
        E("autonumber", "autonumber", "number messages"),
        E("title", "title ${1:Title}", "diagram title"),
        E("message", "${1:A}->>${2:B}: ${3:message}", "message"),
        E("end", "end", "close block"),
    ]

    private static let sequenceArrows: [MermaidEntry] = [
        E("->>", "->>", "solid arrow"), E("-->>", "-->>", "dotted arrow"),
        E("->", "->", "solid line, no head"), E("-->", "-->", "dotted line, no head"),
        E("-x", "-x", "solid, cross end"), E("--x", "--x", "dotted, cross end"),
        E("-)", "-)", "solid, async"), E("--)", "--)", "dotted, async"),
        E("<<->>", "<<->>", "solid bidirectional"), E("<<-->>", "<<-->>", "dotted bidirectional"),
        E("->>+", "->>+", "message and activate target"), E("-->>-", "-->>-", "reply and deactivate sender"),
    ]

    // MARK: Class

    private static let classDiagram: [MermaidEntry] = [
        E("class", "class ${1:Name}", "declare class"),
        E("class { }", "class ${1:Name} {\n\t+${2:String} ${3:field}\n\t+${4:method}() ${5:void}\n}", "class with members",
          "Visibility: + public, - private, # protected, ~ package. Suffix $ static, * abstract."),
        E("class~T~", "class ${1:Name}~${2:T}~", "generic class"),
        E("<<interface>>", "<<interface>>", "annotation"), E("<<abstract>>", "<<abstract>>", "annotation"),
        E("<<enumeration>>", "<<enumeration>>", "annotation"), E("<<service>>", "<<service>>", "annotation"),
        E("member", "${1:Name} : +${2:method}()", "add member"),
        E("relation", "${1:A} \"${2:1}\" --> \"${3:*}\" ${4:B} : ${5:label}", "relation with cardinality",
          "Cardinality: 1, 0..1, 1..*, *, n, 0..n, 1..n."),
        E("namespace", "namespace ${1:Name} {\n\t$0\n}", "group classes"),
        E("note", "note \"${1:text}\"", "diagram note"),
        E("note for", "note for ${1:Name} \"${2:text}\"", "class note"),
        E("direction", "direction ${1:RL}", "layout direction"),
        E("classDef", "classDef ${1:name} fill:${2:#f9f},stroke:${3:#333}", "define style class"),
        E("style", "style ${1:Name} fill:${2:#f9f}", "style one class"),
        E("link", "link ${1:Name} \"${2:https://}\" \"${3:tooltip}\"", "link a class"),
    ]

    private static let classArrows: [MermaidEntry] = [
        E("<|--", "<|--", "inheritance"), E("*--", "*--", "composition"), E("o--", "o--", "aggregation"),
        E("-->", "-->", "association"), E("..>", "..>", "dependency"), E("..|>", "..|>", "realization"),
        E("<|..", "<|..", "realization (reversed)"), E("--", "--", "link (solid)"), E("..", "..", "link (dashed)"),
    ]

    // MARK: State

    private static let state: [MermaidEntry] = [
        E("[*]", "[*]", "start / end state"),
        E("[*] -->", "[*] --> ${1:State}", "start transition"),
        E("--> [*]", "${1:State} --> [*]", "end transition"),
        E("transition", "${1:A} --> ${2:B} : ${3:event}", "labelled transition"),
        E("state as", "state \"${1:description}\" as ${2:S1}", "state with description"),
        E("description", "${1:S1} : ${2:description}", "state description"),
        E("state { }", "state ${1:Composite} {\n\t$0\n}", "composite state"),
        E("<<fork>>", "state ${1:fork_state} <<fork>>", "fork"),
        E("<<join>>", "state ${1:join_state} <<join>>", "join"),
        E("<<choice>>", "state ${1:choice} <<choice>>", "choice"),
        E("note", "note right of ${1:State}\n\t${2:text}\nend note", "multi-line note"),
        E("note :", "note left of ${1:State} : ${2:text}", "one-line note"),
        E("--", "--", "concurrency separator", "Separates concurrent regions inside a composite state."),
        E("direction", "direction ${1:LR}", "layout direction"),
        E("classDef", "classDef ${1:name} fill:${2:#f9f},stroke:${3:#333}", "define style class"),
        E("class", "class ${1:State} ${2:className}", "apply style class"),
    ]

    // MARK: ER

    private static let er: [MermaidEntry] = [
        E("entity { }", "${1:ENTITY} {\n\t${2:string} ${3:name} ${4:PK}\n}", "entity with attributes", "Attribute keys: PK, FK, UK; a trailing \"comment\" is allowed."),
        E("attribute", "${1:string} ${2:name}", "attribute"),
        E("relationship", "${1:CUSTOMER} ||--o{ ${2:ORDER} : ${3:places}", "relationship",
          "Cardinality: |o zero or one, || exactly one, }o zero or more, }| one or more. -- identifying, .. non-identifying."),
        E("PK", "PK", "primary key"), E("FK", "FK", "foreign key"), E("UK", "UK", "unique key"),
    ]

    private static let erArrows: [MermaidEntry] = [
        E("||--||", "||--||", "one to one"), E("||--o{", "||--o{", "one to zero or more"),
        E("||--|{", "||--|{", "one to one or more"), E("|o--o{", "|o--o{", "zero or one to zero or more"),
        E("}o--o{", "}o--o{", "many to many"), E("|o--o|", "|o--o|", "zero or one to zero or one"),
        E("||..o{", "||..o{", "one to zero or more (non-identifying)"), E("}|..|{", "}|..|{", "one or more to one or more (non-identifying)"),
    ]

    // MARK: Gantt

    private static let gantt: [MermaidEntry] = [
        E("title", "title ${1:Title}", "chart title"),
        E("dateFormat", "dateFormat ${1:YYYY-MM-DD}", "input date format"),
        E("axisFormat", "axisFormat ${1:%Y-%m-%d}", "axis label format", "d3 time format, e.g. %d.%m or %b %e."),
        E("tickInterval", "tickInterval ${1:1week}", "axis tick interval"),
        E("section", "section ${1:Section}", "group tasks"),
        E("task", "${1:Task} :${2:a1}, ${3:2026-01-01}, ${4:3d}", "task with id, start and duration"),
        E("task after", "${1:Task} :${2:a2}, after ${3:a1}, ${4:3d}", "task starting after another"),
        E("milestone", "${1:Milestone} :milestone, ${2:m1}, ${3:2026-01-01}, 0d", "milestone"),
        E("after", "after ${1:a1}", "start after task"),
        E("crit", "crit", "critical task tag"), E("done", "done", "completed task tag"),
        E("active", "active", "active task tag"),
        E("excludes", "excludes ${1:weekends}", "skip dates", "weekends, weekday names or dates."),
        E("weekend", "weekend ${1:friday}", "first weekend day"),
        E("todayMarker", "todayMarker ${1:off}", "today line", "off, or CSS such as stroke-width:5px."),
        E("inclusiveEndDates", "inclusiveEndDates", "end dates are inclusive"),
    ]

    private static let pie: [MermaidEntry] = [
        E("slice", "\"${1:label}\" : ${2:42}", "slice"),
        E("showData", "showData", "print values"),
        E("title", "title ${1:Title}", "chart title"),
    ]

    // MARK: Git

    private static let gitGraph: [MermaidEntry] = [
        E("commit", "commit", "commit"),
        E("commit id", "commit id: \"${1:id}\"", "commit with id"),
        E("commit tag", "commit id: \"${1:id}\" tag: \"${2:v1.0}\"", "tagged commit"),
        E("commit type", "commit type: ${1:HIGHLIGHT}", "commit style", "NORMAL, REVERSE or HIGHLIGHT."),
        E("branch", "branch ${1:feature}", "create and check out a branch"),
        E("branch order", "branch ${1:feature} order: ${2:1}", "branch with lane order"),
        E("checkout", "checkout ${1:main}", "switch branch"),
        E("switch", "switch ${1:main}", "switch branch"),
        E("merge", "merge ${1:feature}", "merge into current branch"),
        E("merge tag", "merge ${1:feature} id: \"${2:id}\" tag: \"${3:v1.0}\"", "merge with options"),
        E("cherry-pick", "cherry-pick id: \"${1:id}\"", "cherry-pick a commit"),
    ]

    // MARK: Others

    private static let mindmap: [MermaidEntry] = [
        E("root((circle))", "root((${1:Topic}))", "circle"),
        E("id[square]", "${1:id}[${2:text}]", "square"),
        E("id(rounded)", "${1:id}(${2:text})", "rounded square"),
        E("id))bang((", "${1:id}))${2:text}((", "bang"),
        E("id)cloud(", "${1:id})${2:text}(", "cloud"),
        E("id{{hexagon}}", "${1:id}{{${2:text}}}", "hexagon"),
        E("::icon", "::icon(${1:fa fa-book})", "node icon"),
        E(":::class", ":::${1:className}", "node class"),
    ]

    private static let timeline: [MermaidEntry] = [
        E("title", "title ${1:Title}", "timeline title"),
        E("section", "section ${1:Era}", "group periods"),
        E("period", "${1:2026} : ${2:Event}", "period with event"),
        E(": event", ": ${1:Event}", "another event for the period above"),
    ]

    private static let journey: [MermaidEntry] = [
        E("title", "title ${1:Title}", "journey title"),
        E("section", "section ${1:Section}", "group tasks"),
        E("task", "${1:Task}: ${2:5}: ${3:Me}", "task: score (1–5): actors"),
    ]

    private static let quadrant: [MermaidEntry] = [
        E("title", "title ${1:Title}", "chart title"),
        E("x-axis", "x-axis ${1:Low} --> ${2:High}", "x axis labels"),
        E("y-axis", "y-axis ${1:Low} --> ${2:High}", "y axis labels"),
        E("quadrant-1", "quadrant-1 ${1:Label}", "top right"), E("quadrant-2", "quadrant-2 ${1:Label}", "top left"),
        E("quadrant-3", "quadrant-3 ${1:Label}", "bottom left"), E("quadrant-4", "quadrant-4 ${1:Label}", "bottom right"),
        E("point", "${1:Point}: [${2:0.5}, ${3:0.5}]", "data point"),
    ]

    private static let requirement: [MermaidEntry] = ["requirement", "functionalRequirement", "interfaceRequirement",
                                                       "performanceRequirement", "physicalRequirement", "designConstraint"].map {
        E($0, "\($0) ${1:name} {\n\tid: ${2:1}\n\ttext: ${3:text}\n\trisk: ${4:medium}\n\tverifymethod: ${5:test}\n}", "requirement",
          "risk: low, medium, high. verifymethod: analysis, inspection, test, demonstration.")
    } + [
        E("element", "element ${1:name} {\n\ttype: ${2:simulation}\n\tdocref: ${3:ref}\n}", "element"),
        E("relationship", "${1:a} - ${2:satisfies} -> ${3:b}", "relationship",
          "contains, copies, derives, satisfies, verifies, refines, traces"),
    ]

    private static let xychart: [MermaidEntry] = [
        E("title", "title \"${1:Title}\"", "chart title"),
        E("x-axis", "x-axis [${1:a, b, c}]", "categorical x axis"),
        E("x-axis range", "x-axis \"${1:label}\" ${2:0} --> ${3:100}", "numeric x axis"),
        E("y-axis", "y-axis \"${1:label}\" ${2:0} --> ${3:100}", "y axis"),
        E("bar", "bar [${1:1, 2, 3}]", "bar series"), E("line", "line [${1:1, 2, 3}]", "line series"),
    ]

    private static let block: [MermaidEntry] = [
        E("columns", "columns ${1:3}", "column count"),
        E("block", "block:${1:group}:${2:2}\n\t$0\nend", "nested block"),
        E("space", "space", "empty cell"),
        E("id[\"text\"]", "${1:id}[\"${2:text}\"]", "block with label"),
        E("end", "end", "close block"),
    ]

    private static let architecture: [MermaidEntry] = [
        E("group", "group ${1:id}(${2:cloud})[${3:Title}]", "group"),
        E("service", "service ${1:id}(${2:server})[${3:Title}]", "service", "Icons: cloud, database, disk, internet, server."),
        E("service in", "service ${1:id}(${2:server})[${3:Title}] in ${4:group}", "service inside group"),
        E("junction", "junction ${1:id}", "junction"),
        E("edge", "${1:a}:${2:R} -- ${3:L}:${4:b}", "edge between sides"),
    ]
}

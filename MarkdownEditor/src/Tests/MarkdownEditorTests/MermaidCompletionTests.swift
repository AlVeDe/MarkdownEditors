import AppKit
import Testing
@testable import MarkdownEditor

@MainActor
struct MermaidCompletionTests {
    /// Runs the provider on `source`, where `‸` marks the caret.
    private func complete(_ source: String, context: EditorContext = .mermaid, explicit: Bool = false) -> (result: CompletionResult?, text: NSString) {
        let caret = (source as NSString).range(of: "‸").location
        let text = source.replacingOccurrences(of: "‸", with: "") as NSString
        let request = CompletionRequest(text: text, location: caret, context: context, documentURL: nil, isExplicit: explicit)
        return (MermaidCompletionProvider().completions(for: request), text)
    }

    private func replaced(_ source: String, explicit: Bool = false) -> String? {
        let (result, text) = complete(source, explicit: explicit)
        return result.map { text.substring(with: $0.replacementRange) }
    }

    private func labels(_ source: String, explicit: Bool = false) -> [String] {
        complete(source, explicit: explicit).result?.items.map(\.label) ?? []
    }

    /// Identifier labels, in rank order as the provider produced them.
    private func identifiers(_ source: String) -> [String] {
        complete(source, explicit: true).result?.items.filter { $0.kind == .identifier }.map(\.label) ?? []
    }

    // MARK: Scope

    @Test func nilOutsideMermaid() {
        #expect(complete("```mermaid\nflow‸\n```", context: .markdown).result == nil)
        #expect(complete("```mermaid\nflow‸\n```", context: .codeBlock(language: "swift")).result == nil)
        // Context says mermaid but no fence encloses the caret.
        #expect(complete("```python\nflow‸\n```").result == nil)
        #expect(complete("```mermaid\ngraph\n```\ntext‸").result == nil)
        // On a fence line itself.
        #expect(complete("```mermaid‸\n```").result == nil)
    }

    @Test func fenceExtent() {
        let text = "intro\n~~~~ Mermaid\nflowchart LR\n  A --> B\n~~~\nstill inside\n~~~~\nafter" as NSString
        let block = MermaidBlock.find(in: text, at: text.range(of: "B").location + 1)
        #expect(block?.lines == ["flowchart LR", "  A --> B", "~~~", "still inside"])
        #expect(block?.caretLine == 1)
        #expect(block?.caretPrefix == "  A --> B")
    }

    // MARK: Type line

    @Test func typeDetection() {
        #expect(MermaidDiagramType(typeLine: "flowchart TD") == .flowchart)
        #expect(MermaidDiagramType(typeLine: "graph LR") == .flowchart)
        #expect(MermaidDiagramType(typeLine: "sequenceDiagram") == .sequence)
        #expect(MermaidDiagramType(typeLine: "stateDiagram-v2") == .state)
        #expect(MermaidDiagramType(typeLine: "  erDiagram") == .er)
        #expect(MermaidDiagramType(typeLine: "gitGraph:") == .gitGraph)
        #expect(MermaidDiagramType(typeLine: "pie title Pets") == .pie)
        #expect(MermaidDiagramType(typeLine: "xychart-beta") == .xychart)
        #expect(MermaidDiagramType(typeLine: "flowchartish") == nil)
    }

    @Test func firstLineOffersDiagramTypes() {
        let items = labels("```mermaid\n‸\n```", explicit: true)
        for type in ["flowchart", "graph", "sequenceDiagram", "classDiagram", "stateDiagram-v2", "erDiagram", "journey",
                     "gantt", "pie", "quadrantChart", "requirementDiagram", "gitGraph", "mindmap", "timeline",
                     "sankey-beta", "xychart-beta", "block-beta"] {
            #expect(items.contains(type), "missing \(type)")
        }
        #expect(items.contains("%%{init}%%"))
        let flowchart = complete("```mermaid\nflo‸\n```").result?.items.first { $0.label == "flowchart" }
        #expect(flowchart?.kind == .diagram)
        #expect(flowchart?.insertText.hasPrefix("flowchart ${1:TD}\n") == true)
        #expect(flowchart?.documentation.isEmpty == false)
    }

    @Test func typeLineIsFoundPastCommentsAndFrontMatter() {
        #expect(labels("```mermaid\n---\ntitle: X\n---\n%% note\nseq‸\n```").contains("sequenceDiagram"))
        #expect(complete("```mermaid\n---\nti‸\n---\n```").result == nil)
        #expect(replaced("```mermaid\nstateDiagram-‸\n```") == "stateDiagram-")
    }

    @Test func directionsAfterFlowchart() {
        #expect(labels("```mermaid\nflowchart L‸\n```") == ["TD", "TB", "BT", "LR", "RL"])
        #expect(replaced("```mermaid\nflowchart L‸\n```") == "L")
        #expect(labels("```mermaid\ngitGraph ‸\n```", explicit: true).contains("LR:"))
        #expect(complete("```mermaid\nsequenceDiagram x‸\n```").result == nil)
    }

    // MARK: Keywords

    @Test func keywordsDependOnType() {
        let flow = labels("```mermaid\nflowchart TD\n‸\n```", explicit: true)
        let seq = labels("```mermaid\nsequenceDiagram\n‸\n```", explicit: true)
        #expect(flow.contains("subgraph") && flow.contains("classDef") && flow.contains("id{{text}}"))
        #expect(!flow.contains("participant"))
        #expect(seq.contains("participant") && seq.contains("loop") && seq.contains("autonumber"))
        #expect(!seq.contains("subgraph"))
        #expect(seq.contains("accTitle") && flow.contains("%% comment"))
        #expect(labels("```mermaid\ngantt\n‸\n```", explicit: true).contains("dateFormat"))
        #expect(labels("```mermaid\ngitGraph\n‸\n```", explicit: true).contains("cherry-pick"))
        let subgraph = complete("```mermaid\nflowchart TD\nsub‸\n```").result?.items.first { $0.label == "subgraph" }
        #expect(subgraph?.insertText == "subgraph ${1:title}\n\t$0\nend")
        #expect(subgraph?.kind == .snippet)
    }

    @Test func noPopupInsideLabelsAndComments() {
        #expect(complete("```mermaid\nflowchart TD\nA[Sta‸\n```").result == nil)
        #expect(complete("```mermaid\nflowchart TD\nA -->|ye‸\n```").result == nil)
        #expect(complete("```mermaid\nsequenceDiagram\nA->>B: hel‸\n```").result == nil)
        #expect(complete("```mermaid\nflowchart TD\n%% com‸\n```").result == nil)
    }

    // MARK: Arrows and ranges

    @Test func arrowReplacementRanges() {
        #expect(replaced("```mermaid\nflowchart TD\nA --‸\n```") == "--")
        #expect(replaced("```mermaid\nflowchart TD\nA-.‸\n```") == "-.")
        #expect(replaced("```mermaid\nflowchart TD\nA --o‸\n```") == "--o")
        #expect(replaced("```mermaid\nsequenceDiagram\nAlice-)‸\n```") == "-)")
        #expect(replaced("```mermaid\nclassDiagram\nA <|‸\n```") == "<|")
        #expect(replaced("```mermaid\nerDiagram\nCUSTOMER |‸\n```") == "|")
        let seq = labels("```mermaid\nsequenceDiagram\nAlice-‸\n```")
        #expect(seq.contains("->>") && seq.contains("--)") && !seq.contains("==>"))
        let flow = labels("```mermaid\nflowchart TD\nA -‸\n```")
        #expect(flow.contains("==>") && flow.contains("-.->") && !flow.contains("->>"))
        #expect(labels("```mermaid\nerDiagram\nA }‸\n```").contains("}o--o{"))
    }

    @Test func wordReplacementRanges() {
        #expect(replaced("```mermaid\nflowchart TD\n  sub‸\n```") == "sub")
        #expect(replaced("```mermaid\ngitGraph\ncherry-‸\n```") == "cherry-")
        #expect(replaced("```mermaid\ngitGraph\ncherry-pi‸\n```") == "cherry-pi")
        #expect(replaced("```mermaid\nclassDiagram\n<<inter‸\n```") == "<<inter")
        #expect(replaced("```mermaid\nflowchart TD\nA-->B‸\n```") == "B")
        #expect(replaced("```mermaid\nflowchart TD\n‸\n```", explicit: true) == "")
        // A hyphen at line start or a lone `<<` is not an arrow.
        #expect(complete("```mermaid\nflowchart TD\n-‸\n```").result == nil)
    }

    // MARK: Identifiers

    @Test func flowchartIdentifiers() {
        let source = """
        ```mermaid
        flowchart TD
            start([Begin here]) --> check{Is it ok?}
            check -->|yes| done[(Store)]
            check -- retry later --> start
            done --o archive & trash
            subgraph group1 [Group]
                inner>flag text]
            end
            classDef hot fill:#f00
            class done hot
            check --> ‸
        ```
        """
        #expect(identifiers(source) == ["start", "check", "done", "archive", "trash", "group1", "inner"])
        // Identifiers rank above keywords after an arrow and at line start.
        let items = complete(source, explicit: true).result?.items ?? []
        #expect(items.allSatisfy { $0.kind == .identifier })
        let lineStart = complete(source.replacingOccurrences(of: "check --> ‸", with: "‸"), explicit: true).result?.items ?? []
        let topIdentifier = lineStart.filter { $0.kind == .identifier }.map(\.sortPriority).min() ?? 0
        let topKeyword = lineStart.filter { $0.kind != .identifier }.map(\.sortPriority).max() ?? 0
        #expect(topIdentifier > topKeyword)
    }

    @Test func identifierBeingTypedIsNotSuggested() {
        #expect(identifiers("```mermaid\nflowchart TD\nA --> B\nB --> Ne‸\n```") == ["A", "B"])
    }

    @Test func sequenceIdentifiers() {
        let source = """
        ```mermaid
        sequenceDiagram
            participant A as Alice
            actor Bob
            A->>Bob: Hi
            Bob-->>+Carol: forward
            Carol--)Dave: async
            Note over A,Bob: text
            ‸
        ```
        """
        #expect(identifiers(source) == ["A", "Bob", "Carol", "Dave"])
    }

    @Test func classIdentifiers() {
        let source = """
        ```mermaid
        classDiagram
            class Animal {
                +String name
                +speak() void
            }
            Animal <|-- Dog
            Owner "1" --> "*" Dog : owns
            Duck : +swim()
            class Shape~T~
            ‸
        ```
        """
        #expect(identifiers(source) == ["Animal", "Dog", "Owner", "Duck", "Shape"])
    }

    @Test func stateIdentifiers() {
        let source = """
        ```mermaid
        stateDiagram-v2
            [*] --> Idle
            Idle --> Running : start
            state "Waiting for input" as Waiting
            state Busy {
                Inner : description
            }
            note right of Idle
                Not a state
            end note
            state fork1 <<fork>>
            ‸
        ```
        """
        #expect(identifiers(source) == ["Idle", "Running", "Waiting", "Busy", "Inner", "fork1"])
    }

    @Test func erIdentifiers() {
        let source = """
        ```mermaid
        erDiagram
            CUSTOMER ||--o{ ORDER : places
            ORDER ||--|{ LINE-ITEM : contains
            PRODUCT {
                string name
                float price
            }
            ‸
        ```
        """
        #expect(identifiers(source) == ["CUSTOMER", "ORDER", "LINE-ITEM", "PRODUCT"])
    }

    @Test func gitGraphBranches() {
        let source = """
        ```mermaid
        gitGraph
            commit
            branch develop
            checkout develop
            commit id: "x"
            branch "feature/login" order: 2
            checkout main
            merge develop
            checkout ‸
        ```
        """
        #expect(identifiers(source) == ["main", "develop", "feature/login"])
    }
}

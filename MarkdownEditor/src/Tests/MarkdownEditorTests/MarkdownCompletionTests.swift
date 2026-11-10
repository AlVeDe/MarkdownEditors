import AppKit
import Testing
@testable import MarkdownEditor

@MainActor
struct MarkdownCompletionTests {
    /// Builds a request with the caret at the `|` marker in `source`.
    private func request(_ source: String, context: EditorContext = .markdown,
                         documentURL: URL? = nil, explicit: Bool = false) -> CompletionRequest {
        let marker = (source as NSString).range(of: "|")
        let text = (source as NSString).replacingCharacters(in: marker, with: "") as NSString
        return CompletionRequest(text: text, location: marker.location, context: context,
                                 documentURL: documentURL, isExplicit: explicit)
    }

    private func complete(_ source: String, context: EditorContext = .markdown,
                          documentURL: URL? = nil, explicit: Bool = false) -> CompletionResult? {
        MarkdownCompletionProvider().completions(for: request(source, context: context, documentURL: documentURL, explicit: explicit))
    }

    // MARK: Anchors

    @Test func anchorSlugs() {
        #expect(AnchorSlugger.slug("Hello, World!") == "hello-world")
        #expect(AnchorSlugger.slug("C# & .NET 8") == "c--net-8")
        #expect(AnchorSlugger.slug("snake_case and-dash") == "snake_case-and-dash")
        #expect(AnchorSlugger.slug("Über Größe") == "über-größe")
    }

    @Test func duplicateAnchorsGetSuffixes() {
        var slugger = AnchorSlugger()
        #expect(slugger.anchor(for: "Intro") == "intro")
        #expect(slugger.anchor(for: "Intro") == "intro-1")
        #expect(slugger.anchor(for: "Intro") == "intro-2")
        #expect(slugger.anchor(for: "Intro 1") == "intro-1-1")
    }

    @Test func indexFindsHeadingsOutsideCodeAndFrontMatter() {
        let index = MarkdownDocumentIndex(text: """
        ---
        title: Doc
        ---
        # Title ##
        ## Usage
        ```
        # not a heading
        ```
        Setext Heading
        --------------
        ## Usage
        ### [Link](https://example.com) and `code`
        - item
        ---
        """)
        #expect(index.headings.map(\.anchor) == ["title", "usage", "setext-heading", "usage-1", "link-and-code"])
        #expect(index.headings.map(\.level) == [1, 2, 2, 2, 3])
        #expect(index.headings[4].title == "Link and code")
    }

    @Test func headingAnchorCompletion() throws {
        let result = try #require(complete("# Getting Started\n## Setup\n## Setup\n\nSee [setup](#se|"))
        #expect(result.items.map(\.insertText) == ["getting-started", "setup", "setup-1"])
        #expect(result.items.map(\.detail) == ["H1", "H2", "H2"])
        #expect(result.items[1].label == "Setup")
        #expect(result.items.allSatisfy { $0.kind == .heading })
        let text = "# Getting Started\n## Setup\n## Setup\n\nSee [setup](#se" as NSString
        #expect(result.replacementRange == NSRange(location: text.length - 2, length: 2))
    }

    @Test func anchorCacheFollowsTextChanges() throws {
        let provider = MarkdownCompletionProvider()
        let first = try #require(provider.completions(for: request("# One\n[x](#|")))
        #expect(first.items.map(\.insertText) == ["one"])
        let second = try #require(provider.completions(for: request("# Two\n[x](#|")))
        #expect(second.items.map(\.insertText) == ["two"])
    }

    // MARK: References

    @Test func referenceLabels() throws {
        let doc = "Read [the docs][d|\n\n[docs]: https://example.com/docs\n[Spec]: spec.md \"Title\"\n[^1]: footnote\n"
        let result = try #require(complete(doc))
        #expect(result.items.map(\.label) == ["docs", "Spec"])
        #expect(result.items[0].detail == "https://example.com/docs")
        #expect(result.items[1].detail == "spec.md")
        #expect(result.replacementRange == NSRange(location: 16, length: 1))

        let shortcut = try #require(complete("See [|\n\n[docs]: x\n"))
        #expect(shortcut.items.map(\.label) == ["docs"])
        #expect(shortcut.replacementRange == NSRange(location: 5, length: 0))
    }

    @Test func noReferencesForTaskCheckboxOrWithoutDefinitions() {
        #expect(complete("- [|\n\n[docs]: x\n") == nil)
        #expect(complete("See [|") == nil)
    }

    // MARK: File paths

    private func makeTempTree() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("mdcomp-\(UUID().uuidString)")
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("img/sub"), withIntermediateDirectories: true)
        for path in ["doc.md", "notes.md", "my file.txt", ".hidden", "img/logo.png", "img/readme.txt", "img/sub/deep.svg"] {
            try Data().write(to: root.appendingPathComponent(path))
        }
        return root
    }

    @Test func listsFilesNextToDocument() throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = root.appendingPathComponent("doc.md")

        let result = try #require(complete("[a](|", documentURL: doc))
        #expect(Set(result.items.map(\.label)) == ["img/", "notes.md", "my file.txt"])
        #expect(result.items.first { $0.label == "my file.txt" }?.insertText == "my%20file.txt")
        #expect(result.items.first { $0.label == "img/" }?.insertText == "img/")
        #expect(result.replacementRange == NSRange(location: 4, length: 0))
    }

    @Test func listsSubdirectoryAndPrefersImages() throws {
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let doc = root.appendingPathComponent("doc.md")

        let result = try #require(complete("Logo: ![x](img/lo|", documentURL: doc))
        #expect(Set(result.items.map(\.label)) == ["logo.png", "readme.txt", "sub/"])
        let priorities = Dictionary(uniqueKeysWithValues: result.items.map { ($0.label, $0.sortPriority) })
        #expect(priorities["logo.png"]! > priorities["sub/"]!)
        #expect(priorities["sub/"]! > priorities["readme.txt"]!)
        // Only the name after the last slash is replaced.
        #expect(result.replacementRange == NSRange(location: 15, length: 2))
    }

    @Test func pathsNeedDocumentURL() throws {
        #expect(complete("[a](|") == nil)
        let root = try makeTempTree()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(complete("[a](https:|", documentURL: root.appendingPathComponent("doc.md")) == nil)
        #expect(complete("[a](missing/|", documentURL: root.appendingPathComponent("doc.md")) == nil)
    }

    // MARK: Fence languages

    @Test func fenceLanguages() throws {
        let result = try #require(complete("Text\n```py|", context: .fenceInfo))
        #expect(result.replacementRange == NSRange(location: 8, length: 2))
        let byName = Dictionary(uniqueKeysWithValues: result.items.map { ($0.label, $0) })
        #expect(byName["python"]?.detail == "highlighted")
        #expect(byName["mermaid"]?.detail == "diagram")
        #expect(byName["math"]?.detail == "formula")
        #expect(byName["json"]?.detail == "")
        #expect(byName["csharp"]!.sortPriority > byName["json"]!.sortPriority)
        #expect(result.items.allSatisfy { $0.kind == .language })

        let empty = try #require(complete("  ~~~~|", context: .fenceInfo))
        #expect(empty.replacementRange == NSRange(location: 6, length: 0))
        #expect(complete("```python extra|", context: .fenceInfo) == nil)
    }

    // MARK: Snippets

    @Test func snippetsAtLineStart() throws {
        let result = try #require(complete("Intro\n  ta|"))
        #expect(result.items.map(\.label).sorted() == ["table", "task"])
        #expect(result.replacementRange == NSRange(location: 8, length: 2))
        #expect(result.items.allSatisfy { $0.kind == .snippet && !$0.documentation.isEmpty })

        let math = try #require(complete("ma|"))
        #expect(math.items.first?.insertText.hasPrefix("\\$\\$\n") == true)
        let heading = try #require(complete("x\nh3|"))
        #expect(heading.items.map(\.insertText) == ["### ${1:Heading}$0"])
    }

    @Test func snippetsNeedPrefixUnlessExplicit() throws {
        #expect(complete("t|") == nil)
        #expect(complete("Table|") == nil)        // prose, capitalized
        #expect(complete("Some ta|") == nil)      // not at line start
        #expect(complete("zz|") == nil)
        #expect(complete("|") == nil)

        let all = try #require(complete("x\n|", explicit: true))
        #expect(all.items.contains { $0.label == "table" })
        #expect(!all.items.contains { $0.label == "frontmatter" })
        let first = try #require(complete("|", explicit: true))
        #expect(first.items.contains { $0.label == "frontmatter" && $0.insertText == "---\ntitle: ${1}\n---\n$0" })
        #expect(try #require(complete("fr|")).items.map(\.label) == ["frontmatter"])
        #expect(complete("x\nfr|") == nil)
    }

    // MARK: Contexts

    @Test func nilOutsideMarkdownContexts() {
        let contexts: [EditorContext] = [.inlineCode, .codeBlock(language: "swift"), .inlineMath,
                                         .displayMath, .mermaid, .frontMatter, .htmlComment]
        for context in contexts {
            #expect(complete("ta|", context: context, explicit: true) == nil)
            #expect(complete("# A\n[x](#|", context: context) == nil)
        }
    }

    @Test func triggerCharacters() {
        #expect(MarkdownCompletionProvider().triggerCharacters == ["#", "(", "[", "/", "`"])
    }
}

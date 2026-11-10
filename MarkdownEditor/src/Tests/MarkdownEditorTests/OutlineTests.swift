import AppKit
import Testing
@testable import MarkdownEditor

@MainActor
struct OutlineTests {
    private func summary(_ text: String) -> [String] {
        OutlineParser.headings(in: text).map { "\($0.level):\($0.title)@\($0.line)" }
    }

    @Test func atxHeadings() {
        let text = """
        # One
        text
        ## Two ##
        ###No space is not a heading
        ####### seven hashes neither
           ### Indented three
            # four spaces is code

        ######
        """
        #expect(summary(text) == ["1:One@1", "2:Two@3", "3:Indented three@6", "6:@9"])
    }

    @Test func setextHeadings() {
        let text = """
        Title
        =====

        Multi
        line
        ---

        - list item
        ---

        ---
        """
        #expect(summary(text) == ["1:Title@1", "2:Multi line@4"])
    }

    @Test func skipsFencesFrontMatterAndComments() {
        let text = """
        ---
        title: # not a heading
        ---
        # Real
        ```swift
        # comment in code
        ```
        ~~~~
        # still code
        ```
        ~~~~
        <!--
        # commented out
        -->
        ## After
        """
        #expect(summary(text) == ["1:Real@4", "2:After@15"])
    }

    @Test func locationsAndCurrentSection() {
        let text = "intro\n# A\nbody\n## B\nmore\n"
        let headings = OutlineParser.headings(in: text)
        #expect(headings.map(\.location) == [6, 15])
        #expect(OutlineParser.sectionIndex(for: 0, in: headings) == nil)
        #expect(OutlineParser.sectionIndex(for: 6, in: headings) == 0)
        #expect(OutlineParser.sectionIndex(for: 12, in: headings) == 0)
        #expect(OutlineParser.sectionIndex(for: 20, in: headings) == 1)
    }

    @Test func modelFollowsEditor() async throws {
        let editor = EditorController(settings: EditorSettings(defaults: UserDefaults(suiteName: "tests-outline")!))
        editor.setText("# A\ntext\n## B\n")
        let model = OutlineModel(editor: editor)
        model.debounce = .milliseconds(10)
        #expect(model.headings.map(\.title) == ["A", "B"])

        editor.selectedRange = NSRange(location: 10, length: 0)
        #expect(model.currentIndex == 1)

        editor.replaceCharacters(in: NSRange(location: 0, length: 0), with: "# Zero\n")
        // Poll instead of one fixed sleep: other suites run on the main
        // actor in parallel (the highlighter's performance tests hold it for
        // seconds), so the debounced refresh can run much later than its
        // nominal delay. Passing runs return as soon as it lands.
        let deadline = ContinuousClock.now + .seconds(15)
        while model.headings.count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.headings.map(\.title) == ["Zero", "A", "B"])
    }
}

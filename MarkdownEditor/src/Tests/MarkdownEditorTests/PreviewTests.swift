import AppKit
import Markdown
import Testing
import WebKit
@testable import MarkdownEditor

// MARK: - Line map

@MainActor
struct LineMapTests {
    /// `data-line` values of the elements with the given tag, in order.
    private func lines(of tag: String, in html: String) -> [Int] {
        let pattern = "<\(tag)(?=[\\s>])[^>]*?data-line=\"(\\d+)\""
        let regex = try! NSRegularExpression(pattern: pattern)
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).flatMap { Int(html[$0]) }
        }
    }

    private func render(_ markdown: String) -> String {
        let parsed = MathBlocks.parseMapped(markdown)
        return HtmlRenderer.render(parsed.document, lineMap: parsed.lineMap)
    }

    @Test func identityWithoutDisplayMath() {
        let result = MathBlocks.preprocessMapped("a\n\nb")
        #expect(result.lineMap == .identity)
        #expect(result.lineMap.originalLine(3) == 3)
    }

    @Test func singleLineBlockGrowsButMapsBack() {
        let markdown = "Intro\n\n$$ x^2 $$\n\nAfter\n"
        let result = MathBlocks.preprocessMapped(markdown)
        #expect(result.text.components(separatedBy: "\n").count == 8) // 3 lines became 5... +2
        // Every output line maps to the line it came from.
        #expect(result.lineMap.origins == [1, 2, 3, 3, 3, 4, 5, 6])

        let html = render(markdown)
        #expect(lines(of: "p", in: html) == [1, 5])
        #expect(lines(of: "div", in: html) == [3])
        #expect(html.contains("data-end-line=\"3\""))
    }

    @Test func multiLineBlocksMapBack() {
        let markdown = """
        # Title

        $$
        a = b
        $$

        $$ c
        + d $$

        Text

        $$ e = f $$
        - item
        """
        let html = render(markdown)
        #expect(lines(of: "h1", in: html) == [1])
        #expect(lines(of: "div", in: html) == [3, 7, 12])
        #expect(lines(of: "p", in: html) == [10])
        #expect(lines(of: "ul", in: html) == [13])
        #expect(lines(of: "li", in: html) == [13])
        #expect(html.contains("data-line=\"3\" data-end-line=\"5\""))
        #expect(html.contains("data-line=\"7\" data-end-line=\"8\""))
    }

    @Test func fencesAndUnterminatedMathStayPut() {
        let markdown = "```\n$$ not math $$\n```\n\n$$ x $$\n\n$$ open\n\nlast"
        let html = render(markdown)
        #expect(lines(of: "pre", in: html) == [1])
        #expect(lines(of: "div", in: html) == [5])
        #expect(lines(of: "p", in: html) == [7, 9])
    }
}

// MARK: - HtmlRenderer attributes

@MainActor
struct HtmlRendererAttributeTests {
    private func render(_ markdown: String) -> String {
        let parsed = MathBlocks.parseMapped(markdown)
        return HtmlRenderer.render(parsed.document, lineMap: parsed.lineMap)
    }

    private func hashes(_ html: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "data-hash=\"([0-9a-z]+)\"")
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap {
            Range($0.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    @Test func blocksCarryLines() {
        let html = render("""
        # H

        > quote

        ```mermaid
        graph TD; A-->B
        ```

        | a | b |
        |---|---|
        | 1 | 2 |

        ---

        1. one
        2. two
        """)
        #expect(html.contains("<h1 data-hash="))
        #expect(html.contains("data-line=\"1\">H</h1>"))
        #expect(html.contains("<blockquote data-hash=\"") && html.contains("<p data-line=\"3\">quote</p>"))
        #expect(html.contains("class=\"mermaid\"") && html.contains("data-line=\"5\" data-end-line=\"7\""))
        #expect(html.contains("<tr data-line=\"9\">") && html.contains("<tr data-line=\"11\">"))
        #expect(html.contains("data-line=\"13\" />"))
        #expect(html.contains("<li data-line=\"16\">two</li>"))
    }

    @Test func everyTopLevelBlockHasAHash() {
        let html = render("a\n\nb\n\n- c\n")
        #expect(hashes(html).count == 3)
    }

    @Test func hashIgnoresLineNumbersButNotContent() {
        let before = hashes(render("para one\n\n```mermaid\ngraph TD; A-->B\n```\n"))
        let shifted = hashes(render("\n\n\npara one\n\n```mermaid\ngraph TD; A-->B\n```\n"))
        let edited = hashes(render("para two\n\n```mermaid\ngraph TD; A-->B\n```\n"))
        #expect(before == shifted)
        #expect(before[0] != edited[0])
        #expect(before[1] == edited[1])
    }

    @Test func relativeImagesPointAtTheDocumentScheme() {
        let document = Document(parsing: "![a](<images/a b.png>) ![b](https://x.org/b.png) ![c](/abs.png)")
        let html = HtmlRenderer.render(document, imageBase: DocumentFileSchemeHandler.base)
        #expect(html.contains("src=\"docfile://document/images/a%20b.png\""))
        #expect(html.contains("src=\"https://x.org/b.png\""))
        #expect(html.contains("src=\"/abs.png\""))
        #expect(HtmlRenderer.isRelativePath("a/b:c.png"))
        #expect(!HtmlRenderer.isRelativePath("data:image/png;base64,xx"))
    }
}

// MARK: - Diagnostics mapping

@MainActor
struct PreviewDiagnosticsTests {
    let text = "Intro\n\n```mermaid\ngraph TD\n  A-->\n```\n\nSee $\\frac{a}$ here\n\n$$\n\\bad{x}\n$$\n"

    @Test func lineIndexRanges() {
        let index = LineIndex("ab\r\ncd\n\nef")
        #expect(index.lineCount == 4)
        #expect(index.range(ofLine: 1) == NSRange(location: 0, length: 2))
        #expect(index.range(ofLine: 2) == NSRange(location: 4, length: 2))
        #expect(index.range(ofLine: 3) == NSRange(location: 7, length: 0))
        #expect(index.range(ofLine: 4) == NSRange(location: 8, length: 2))
        #expect(index.range(ofLine: 5) == nil)
    }

    @Test func mermaidErrorLineIsRelativeToTheFence() {
        let message = "Parse error on line 2:\ngraph TD  A-->\n-----------^\nExpecting 'AMP', 'ALPHA', got 'EOF'"
        let diagnostics = PreviewDiagnostics.diagnostics(
            for: [.init(line: 3, endLine: 6, message: message)],
            in: text
        )
        let nsText = text as NSString
        #expect(diagnostics.count == 1)
        #expect(nsText.substring(with: diagnostics[0].range) == "  A-->")
        #expect(diagnostics[0].message == "Mermaid: Expecting 'AMP', 'ALPHA', got 'EOF'")
    }

    @Test func mermaidErrorWithoutLineFallsBackToFirstContentLine() {
        let diagnostics = PreviewDiagnostics.diagnostics(
            for: [.init(line: 3, endLine: 6, message: "No diagram type detected")],
            in: text
        )
        #expect((text as NSString).substring(with: diagnostics[0].range) == "graph TD")
        // An out-of-fence line number is not trusted either.
        let outside = PreviewDiagnostics.diagnostics(
            for: [.init(line: 3, endLine: 6, message: "Parse error on line 9:")],
            in: text
        )
        #expect((text as NSString).substring(with: outside[0].range) == "graph TD")
    }

    @Test func mathErrorsMapToFormulaRanges() {
        let diagnostics = PreviewDiagnostics.diagnostics(
            for: [
                .init(line: 8, endLine: 0, isDisplay: false, tex: "\\frac{a}", message: "Missing argument"),
                .init(line: 10, endLine: 12, isDisplay: true, tex: "\\bad{x}", message: "Undefined control sequence")
            ],
            in: text
        )
        let nsText = text as NSString
        #expect(nsText.substring(with: diagnostics[0].range) == "\\frac{a}")
        #expect(diagnostics[0].message == "LaTeX: Missing argument")
        #expect(nsText.substring(with: diagnostics[1].range) == "$$\n\\bad{x}\n$$")
    }

    @Test func decodesThePageReport() {
        let report = PreviewDiagnostics.decode([
            "mermaid": [["line": 3, "endLine": 6, "message": "m"]],
            "math": [["line": 8, "endLine": 0, "display": false, "tex": "x", "message": "e"]]
        ])
        #expect(report.diagrams == [.init(line: 3, endLine: 6, message: "m")])
        #expect(report.formulas == [.init(line: 8, endLine: 0, isDisplay: false, tex: "x", message: "e")])
    }
}

// MARK: - docfile:// scheme

@MainActor
struct DocumentFileSchemeTests {
    @Test func resolvesInsideTheFolderOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("docfile-\(UUID().uuidString)")
        let images = root.appendingPathComponent("images")
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: images.appendingPathComponent("a b.png"))
        try Data([2]).write(to: root.deletingLastPathComponent().appendingPathComponent("secret-\(root.lastPathComponent)"))
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent().appendingPathComponent("secret-\(root.lastPathComponent)")) }
        // A symlink pointing out of the folder.
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))

        func resolve(_ string: String) -> URL? {
            DocumentFileSchemeHandler.resolve(URL(string: string)!, root: root)
        }
        #expect(resolve("docfile://document/images/a%20b.png")?.lastPathComponent == "a b.png")
        #expect(resolve("docfile://document/../secret-\(root.lastPathComponent)") == nil)
        #expect(resolve("docfile://document/images/..%2F..%2Fsecret-\(root.lastPathComponent)") == nil)
        #expect(resolve("docfile://document/images/%2E%2E/%2E%2E/etc/passwd") == nil)
        #expect(resolve("docfile://document/escape/hosts") == nil)
        #expect(resolve("docfile://document/") == nil)
        #expect(resolve("appassets://document/images/a%20b.png") == nil)
        #expect(DocumentFileSchemeHandler.resolve(URL(string: "docfile://document/images/a%20b.png")!, root: nil) == nil)
    }
}

// MARK: - Live page (WKWebView)

@MainActor
struct PreviewPageTests {
    /// Polls `condition` while the main run loop keeps WebKit going.
    private func waitUntil(timeout: Duration = .seconds(30), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now > deadline { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private func makeLoadedPreview() async throws -> PreviewController {
        let preview = PreviewController()
        let loaded = await waitUntil { preview.isShellLoaded }
        try #require(loaded, "the preview shell did not load")
        return preview
    }

    /// Updates the preview and waits until the page applied it.
    private func update(_ preview: PreviewController, _ markdown: String) async throws {
        var applied = false
        preview.onUpdateApplied = { applied = true }
        preview.update(markdown: markdown)
        let done = await waitUntil { applied }
        try #require(done, "the update was not applied")
    }

    private func evaluate(_ preview: PreviewController, _ js: String) async throws -> Any? {
        try await preview.webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
    }

    @Test func updatesKeepUnchangedNodes() async throws {
        let preview = try await makeLoadedPreview()
        try await update(preview, "first\n\nsecond\n\n$$ x^2 $$\n")
        _ = try await evaluate(preview, """
        const content = document.getElementById('content');
        Array.from(content.children).forEach(function (el, i) { el.__marker = 'm' + i; });
        """)
        // Edit the second paragraph and push the formula down by two lines.
        try await update(preview, "first\n\nsecond, edited\n\n\n\n$$ x^2 $$\n")
        let result = try await evaluate(preview, """
        const content = document.getElementById('content');
        return Array.from(content.children).map(function (el) {
            return [el.__marker || '', el.getAttribute('data-line'), el.querySelector('svg') ? 'svg' : ''];
        });
        """) as? [[Any]]
        let rows = try #require(result)
        #expect(rows.count == 3)
        #expect(rows[0][0] as? String == "m0")       // kept
        #expect(rows[1][0] as? String == "")         // replaced
        #expect(rows[2][0] as? String == "m2")       // kept, with its typeset SVG
        #expect(rows[2][1] as? String == "7")        // and its new line
        #expect(rows[2][2] as? String == "svg")
    }

    @Test func coalescesQueuedUpdates() async throws {
        let preview = try await makeLoadedPreview()
        var applied = 0
        preview.onUpdateApplied = { applied += 1 }
        for index in 1...20 { preview.update(markdown: "version \(index)") }
        let settled = await waitUntil { applied >= 2 }
        #expect(settled)
        try? await Task.sleep(for: .milliseconds(300))
        #expect(applied == 2) // the first one in flight, then only the newest
        let text = try await evaluate(preview, "return document.getElementById('content').textContent.trim()") as? String
        #expect(text == "version 20")
    }

    @Test func reportsMermaidAndMathErrors() async throws {
        let preview = try await makeLoadedPreview()
        var reported: [String: [EditorDiagnostic]] = [:]
        preview.onDiagnostics = { diagnostics, source in reported[source] = diagnostics }
        let markdown = "Intro\n\n```mermaid\ngraph TD\n  A--> -->\n```\n\nok $\\frac{1}{2}$\n\n$$ \\frac{1} $$\n"
        try await update(preview, markdown)
        let nsText = markdown as NSString

        let mermaid = try #require(reported["mermaid"])
        #expect(mermaid.count == 1)
        if let first = mermaid.first {
            #expect(nsText.substring(with: first.range) == "  A--> -->")
            #expect(first.message.hasPrefix("Mermaid: "))
        }
        let math = try #require(reported["mathjax"])
        #expect(math.count == 1)
        if let first = math.first {
            #expect(nsText.substring(with: first.range) == "$$ \\frac{1} $$")
        }

        // Fixing the errors clears them.
        try await update(preview, "Intro\n\n```mermaid\ngraph TD\n  A-->B\n```\n")
        #expect(reported["mermaid"]?.isEmpty == true)
        #expect(reported["mathjax"]?.isEmpty == true)
    }

    @Test func appearanceChangeRerendersDiagrams() async throws {
        let preview = try await makeLoadedPreview()
        preview.webView.appearance = NSAppearance(named: .aqua)
        try await update(preview, "```mermaid\ngraph TD\n  A-->B\n```\n")
        _ = try await evaluate(preview, "document.querySelector('pre.mermaid svg').__old = true;")
        preview.webView.appearance = NSAppearance(named: .darkAqua)
        var rerendered = false
        let done = await waitUntil(timeout: .seconds(10)) {
            Task { @MainActor in
                let value = try? await evaluate(preview, """
                const svg = document.querySelector('pre.mermaid svg');
                return !!svg && !svg.__old;
                """) as? Bool
                rerendered = value ?? false
            }
            return rerendered
        }
        #expect(done)
    }

    @Test func scrollSyncInterpolatesBetweenBlocks() async throws {
        let preview = try await makeLoadedPreview()
        preview.webView.frame = NSRect(x: 0, y: 0, width: 600, height: 300)
        let markdown = (1...60).map { "Paragraph \($0)" }.joined(separator: "\n\n")
        try await update(preview, markdown)
        let result = try await evaluate(preview, """
        const target = document.querySelector('[data-line="41"]');
        const next = document.querySelector('[data-line="43"]');
        scrollToSourceLine(42, '', true);
        const middle = document.scrollingElement.scrollTop;
        scrollToSourceLine(41, '', true);
        const exact = document.scrollingElement.scrollTop;
        const expected = target.getBoundingClientRect().top + exact;
        const expectedNext = next.getBoundingClientRect().top + exact;
        scrollToSourceLine(1, 'top', true);
        const top = document.scrollingElement.scrollTop;
        return [exact, expected, middle, (expected + expectedNext) / 2, top];
        """) as? [NSNumber]
        let values = try #require(result).map(\.doubleValue)
        #expect(abs(values[0] - values[1]) < 1)
        #expect(abs(values[2] - values[3]) < 1)
        #expect(values[4] == 0)
    }

    @Test func servesImagesFromTheDocumentFolder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("docimg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("images"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let image = NSImage(size: NSSize(width: 7, height: 5), flipped: false) { rect in
            NSColor.red.setFill()
            rect.fill()
            return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        try png.write(to: root.appendingPathComponent("images/dot.png"))

        let preview = try await makeLoadedPreview()
        preview.documentURL = root.appendingPathComponent("doc.md")
        try await update(preview, "![dot](images/dot.png)")
        let width = try await evaluate(preview, """
        const img = document.querySelector('img');
        if (!img.complete) { await new Promise(function (resolve) { img.onload = resolve; img.onerror = resolve; }); }
        return img.naturalWidth;
        """) as? NSNumber
        #expect(width?.intValue == 7)
    }
}

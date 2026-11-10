# Markdown Demo Application (macOS) — Specification & Walkthrough

A native macOS (SwiftUI, Swift 6) demo application that shows how to use
Apple's [swift-markdown](https://github.com/swiftlang/swift-markdown) library
to parse and render Markdown — once with a **standard HTML renderer** and once
with a **custom renderer** that produces a native SwiftUI document view,
including syntax highlighting for Swift, C#, JavaScript, TypeScript and Python code
examples. Markdown files can be loaded from disk and exported to PDF via a
third custom renderer built on Core Graphics / Core Text — with colored code,
embedded mermaid diagrams and typeset LaTeX formulas; ` ```mermaid ` blocks
are rendered as diagrams in the HTML preview via a bundled mermaid.js, and
`$$ … $$` blocks as well as validated inline `$ … $` spans are typeset as
mathematics via a bundled MathJax.

This is the macOS/SwiftUI counterpart of the WPF/.NET demo described in
`MarkdigDemo-Spec.md`. The functionality is identical; every Windows-specific
building block is replaced by its native Apple equivalent:

| WPF / .NET version | macOS / Swift version |
| --- | --- |
| Markdig (Markdown engine) | swift-markdown (Apple, cmark-gfm based) |
| WebView2 (HTML preview) | WKWebView (WebKit) |
| WPF `FlowDocument` (native view) | SwiftUI view tree + `AttributedString` |
| QuestPDF (PDF export) | Core Graphics `CGPDFContext` + Core Text |
| `OpenFileDialog` | `NSOpenPanel` / `.fileImporter` |
| `SaveFileDialog` | `NSSavePanel` |
| `DispatcherTimer` debounce | Swift Concurrency `Task.sleep` debounce |
| WebView2 virtual host mapping | `WKURLSchemeHandler` (custom scheme) |

---

## 1. Background: What is Markdown?

Markdown is a lightweight markup language created in 2004 by John Gruber (with
Aaron Swartz). Its goal is text that is **readable as plain text** while still
carrying enough structure to be converted to HTML: `# heading`, `**bold**`,
`*italic*`, `- list item`, `[link](url)`, and fenced code blocks delimited by
three backticks.

Because the original 2004 description left many edge cases undefined,
implementations diverged. Two standardization efforts fixed that:

- **CommonMark** (2014) — a rigorous, unambiguous specification of core
  Markdown with a full test suite. It defines exactly how nested emphasis,
  lists, HTML fragments etc. must be parsed.
- **GitHub Flavored Markdown (GFM)** — CommonMark plus extensions that
  developers use daily: pipe tables, strikethrough (`~~text~~`), task lists,
  and autolinks.

A Markdown processor typically works in two phases:

1. **Parsing** — the text is converted into an *abstract syntax tree* (AST):
   a tree of block elements (headings, paragraphs, lists, code blocks, quotes)
   whose leaves contain inline elements (literal text, emphasis, links,
   inline code).
2. **Rendering** — a renderer walks that tree and emits output. HTML is the
   classic target, but because the AST is output-agnostic, anything can be
   generated: plain text, PDF — or, as in this demo, a native SwiftUI view.

## 2. Background: What is swift-markdown?

[swift-markdown](https://github.com/swiftlang/swift-markdown) is Apple's
official Swift library for parsing Markdown, built on the reference
`cmark-gfm` C library (it powers DocC, Apple's documentation compiler):

- **CommonMark compliant** with the GFM extensions (pipe tables,
  strikethrough, task lists, autolinks) enabled out of the box.
- **Exposed AST**: `Document(parsing: text)` returns a `Document` — a tree of
  `Markup` nodes (`Heading`, `Paragraph`, `CodeBlock`, `Table`, `Emphasis`,
  `Link`, …) you can walk or transform yourself.
- **Visitor pattern**: the `MarkupVisitor` protocol (generic over its result
  type) and `MarkupWalker` are the intended way to build renderers — one
  `visit…` method per AST node type, exactly analogous to Markdig's
  `ObjectRenderers`. `MarkupRewriter` supports tree transformations.

The one-liner most people start with:

```swift
let document = Document(parsing: "# Hello **swift-markdown**!")
print(document.debugDescription())   // dump the AST
```

Unlike Markdig, swift-markdown ships no full-featured HTML renderer — which is
a feature for this demo: writing the HTML renderer as a `MarkupVisitor` is the
same exercise as writing the native and PDF renderers, so the app contains
**three sibling renderers over one AST**.

## 3. The demo application

### 3.1 What you see

The main window is split in two:

| Area | Content |
| --- | --- |
| Left pane | An editable `TextEditor` (monospaced) with the Markdown source (preloaded from the bundled `Sample.md`) |
| Toolbar | **Open file…** and **Export PDF…** buttons |
| Right pane, tab 1 | **HTML preview** — the HTML renderer's output shown in a `WKWebView` |
| Right pane, tab 2 | **Raw HTML output** — the exact HTML string the renderer produced |
| Right pane, tab 3 | **Native SwiftUI** — a view tree built by the custom renderer, no HTML involved |

Typing in the editor re-renders all three views live (debounced to 300 ms).
**Open file…** loads a `.md`/`.markdown` file from disk into the editor
(which re-renders all tabs); **Export PDF…** saves the current editor content
as a PDF rendered by the Core Graphics renderer.
Code blocks in registered languages (C#, JavaScript, TypeScript, Python) are
syntax-highlighted in the HTML preview **and** in the native SwiftUI view,
using one shared tokenizer per language.

### 3.2 Project layout

```
src/
  MarkdownEditor/
    Package.swift                        SwiftPM executable target, macOS 15+,
                                         depends on swift-markdown
    Sources/MarkdownEditor/
      MarkdownEditorApp.swift              @main App, WindowGroup, activation policy
      ContentView.swift                  HSplitView: editor + TabView layout
      DocumentModel.swift                @Observable model: text, debounce,
                                         render orchestration, open/export actions
      WebView.swift                      NSViewRepresentable wrapper for WKWebView,
                                         scheme handler, SVG->PNG harvesting
                                         (mermaid diagrams and LaTeX formulas)
      Resources/
        Sample.md                        Demo document loaded at startup
        mermaid.min.js                   Bundled mermaid.js (v11) for the HTML preview
        tex-svg-full.js                  Bundled MathJax 3 (TeX -> SVG, all TeX
                                         packages) for LaTeX formulas
      Rendering/
        MathBlocks.swift                 `$$ … $$` -> ` ```math ` fences (pre-parse),
                                         plus the shared `parse` entry point
        InlineMath.swift                 `$ … $` -> carrier nodes (post-parse),
                                         incl. the LaTeX validity check
        SyntaxHighlighting.swift         LanguageTokenizer protocol + language registry
        CSharpTokenizer.swift            Minimal C# lexer -> (kind, text) tokens
        JavaScriptTokenizer.swift        JavaScript lexer (base for TypeScript)
        TypeScriptTokenizer.swift        JavaScript lexer + TS type keywords
        PythonTokenizer.swift            Python lexer (# comments, triple quotes)
        HtmlRenderer.swift               MarkupVisitor: AST -> HTML fragment,
                                         highlighted code blocks, mermaid and
                                         math fences
        HtmlPageRenderer.swift           Wraps the fragment in a CSS page
        MarkupContentView.swift          Custom AST -> SwiftUI view renderer
        PdfDocumentRenderer.swift        Custom AST -> PDF renderer (Core Text)
        PdfExporter.swift                PDF export entry point (CGPDFContext setup)
spec/
  MarkdownEditor-macOS-Spec.md             This document
```

Dependencies: **swift-markdown** (the only external package). WebKit, AppKit,
SwiftUI, Core Graphics and Core Text are system frameworks — no license
concerns and no third-party PDF engine needed.

### 3.3 Step-by-step: how it works

**Step 1 — Parse the Markdown into an AST** (`DocumentModel.swift`)

```swift
let document = Document(parsing: markdown)
```

`document` is the syntax tree. The app parses **once** per edit and feeds the
same tree to all renderers, which is the whole point of the AST-based design.
(swift-markdown needs no pipeline object — the GFM extensions are enabled by
default; parse options like `.parseBlockDirectives` exist but are not needed
here.)

**Step 2 — Standard rendering: AST → HTML** (`HtmlRenderer.swift`)

The HTML renderer is a `MarkupVisitor` with one `visit…` method per node
type — the Swift equivalent of Markdig's `ObjectRenderers` collection:

```swift
struct HtmlRenderer: MarkupVisitor {
    mutating func visitHeading(_ heading: Heading) -> Void { ... }
    mutating func visitParagraph(_ p: Paragraph) -> Void { ... }
    mutating func visitCodeBlock(_ code: CodeBlock) -> Void { ... }
    // ... emphasis, links, tables, task lists, HTML passthrough ...
}
```

`visitCodeBlock` takes over all code blocks: blocks fenced with `csharp` are
emitted as `<span class="tok-keyword">…</span>` runs; ` ```mermaid ` fences
become `<pre class="mermaid">`; ` ```math ` fences become `<div class="math">`;
everything else is escaped plain text. This
demonstrates the renderer-per-node extension point — the code block handling
is customized while the rest of the renderer stays a straight CommonMark→HTML
mapping.

The fragment is then wrapped in a small HTML page with embedded CSS
(GitHub-like styling plus Xcode-like token colors, honoring
`prefers-color-scheme`) and pushed to the `WKWebView` via
`loadHTMLString(_:baseURL:)`. The unwrapped fragment is what the
"Raw HTML output" tab shows.

**Step 3 — Custom rendering: AST → SwiftUI views** (`MarkupContentView.swift`)

The native renderer walks the block-level AST and builds a SwiftUI view tree;
inline content is folded into `AttributedString` values rendered by `Text`:

| swift-markdown AST node | SwiftUI element |
| --- | --- |
| `Heading` | `Text` with level-based font size, bottom `Divider` for h1/h2 |
| `Paragraph` | `Text` from an `AttributedString` built by an inline visitor |
| `BlockQuote` | `VStack` with a leading border overlay and secondary foreground |
| `OrderedList` / `UnorderedList` / `ListItem` | `Grid`/`VStack` rows with `1.`/`•` markers, task-list checkboxes via SF Symbols |
| `CodeBlock` | Monospaced `Text` on a gray background; registered languages get colored `AttributedString` runs |
| `Table` (GFM) | SwiftUI `Grid` with borders and bold header row |
| `ThematicBreak` | `Divider` |
| `Emphasis` / `Strong` / `Strikethrough` | `AttributedString` with italic / bold / `strikethroughStyle` |
| `InlineCode` | Monospaced run with background color |
| `Link` | `.link` attribute — opens the default browser; `Image` nodes become a placeholder |

The whole document sits in a `ScrollView` with `.textSelection(.enabled)`.
Nothing HTML-related is involved — this is Markdown rendered directly into
SwiftUI's own view and attributed-string model, which means native text
selection, Dynamic Type, and automatic light/dark appearance.

**Step 4 — syntax highlighting** (`CSharpTokenizer.swift`, `SyntaxHighlighting.swift`)

A deliberately small hand-written C# lexer splits code into tokens: keywords,
strings (incl. `@`/`$` prefixed), comments (`//`, `/* */`, `///`), numbers,
and preprocessor directives. It returns `(TokenKind, String)` pairs and knows
nothing about output formats — the HTML renderer maps kinds to CSS classes,
the SwiftUI renderer to `AttributedString` foreground colors, the PDF
renderer to Core Text foreground colors. One tokenizer, three outputs.

Languages are pluggable: `SyntaxHighlighting` maps fence info strings to
`LanguageTokenizer` implementations. All three renderers look their tokenizer
up there, so adding a language means writing one tokenizer type and one
`register` call — it is then colored in the HTML preview, the SwiftUI view
and the PDF export alike. Registered out of the box:

| Language | Aliases | Tokenizer |
| --- | --- | --- |
| C# | `csharp`, `cs`, `c#` | `CSharpTokenizer` |
| JavaScript | `javascript`, `js`, `jsx` | `JavaScriptTokenizer` |
| TypeScript | `typescript`, `ts`, `tsx` | `TypeScriptTokenizer` (JS + type keywords) |
| Python | `python`, `py` | `PythonTokenizer` (`#` comments, triple-quoted strings, decorators via the preprocessor color) |

**Step 5 — Live updates** (`DocumentModel.swift`)

The model is `@Observable`; the editor binds to its `text` property. Every
change cancels a pending render `Task` and starts a new one that first does
`try await Task.sleep(for: .milliseconds(300))` — cancellation on the next
keystroke gives the classic debounce, so rendering only happens when typing
pauses. Rendering runs on the main actor; parsing and HTML generation are
fast enough that no background hop is needed for a demo.

**Step 6 — Loading Markdown files**

The **Open file…** toolbar button shows an `NSOpenPanel` (allowed content
types: `.md`/`.markdown` via `UTType`) and loads the chosen file into the
model. No extra render plumbing is needed: setting `model.text` fires the
same observation → debounce → render path as typing, so all three tabs update
automatically. The window title shows the loaded file name
(`.navigationTitle`); read failures (missing permissions, encoding) are
reported in an alert.

**Step 7 — PDF export** (`PdfExporter.swift`, `PdfDocumentRenderer.swift`)

The **Export PDF…** button shows an `NSSavePanel`, parses the editor text and
hands the AST to `PdfDocumentRenderer` — a third custom renderer for the same
syntax tree (HTML, SwiftUI, PDF), built on **Core Graphics + Core Text**
(`CGContext(consumer:mediaBox:)` creating a `CGPDFContext`):

- A4 pages, 2 cm margins, a page-number footer (`1 / 3`).
- Each block is converted to an `NSAttributedString` and laid out with a
  `CTFramesetter`; when a block does not fit the remaining page height, a new
  PDF page is started. The block/inline mapping mirrors `MarkupContentView`:
  headings with a size ladder and h1/h2 underlines, quotes with a left
  border, nested lists, bordered tables with header styling, hyperlinks
  (real, clickable PDF link annotations), inline code on a gray background.
- **Code blocks are syntax-highlighted**: languages registered in
  `SyntaxHighlighting` are tokenized and emitted as attributed runs with
  `.foregroundColor`, using the same colors as the HTML preview's CSS.
- **Mermaid blocks become images**: before rendering, the model harvests the
  already-rendered diagrams from the WKWebView preview — each SVG is
  serialized, drawn onto a canvas at 2x resolution and read back as a PNG
  data URL (`harvestMermaidPNGs()`, using `callAsyncJavaScript`). The PNGs
  are passed to the renderer in document order and drawn with
  `CGContext.draw(_:in:)`; if harvesting fails (preview not ready, render
  error), the diagram source is printed as a code box instead.

An alternative one-liner worth knowing: `WKWebView.createPDF(configuration:)`
prints the preview page pixel-identically (colors and diagrams included) but
gives up the custom layout control — this demo deliberately takes the
custom-renderer route. Everything used here is a system framework; there is
no third-party PDF license to manage.

**Step 8 — Mermaid diagrams**

Code blocks fenced with ` ```mermaid ` are turned into diagrams by
[mermaid.js](https://mermaid.js.org/), which needs a browser engine and
therefore runs inside the WKWebView preview:

- `HtmlRenderer` emits mermaid fences as `<pre class="mermaid">` (mermaid's
  default selector) instead of `<pre><code>`.
- `HtmlPageRenderer` loads the bundled `mermaid.min.js` and calls
  `mermaid.initialize({ startOnLoad: true, securityLevel: 'strict',
  suppressErrorRendering: true, htmlLabels: false })`. Error rendering is
  suppressed so that half-typed diagrams (the debounce re-renders while
  typing) don't flash error graphics; `htmlLabels: false` keeps labels as
  plain SVG `<text>` so the PDF export can rasterize the diagrams onto a
  canvas without tainting it.
- Rather than inlining the ~3.5 MB script into every page, the app registers
  a `WKURLSchemeHandler` for a custom `appassets://` scheme on the
  `WKWebViewConfiguration` — the page then loads
  `appassets://local/mermaid.min.js`, which the handler serves straight from
  `Bundle.module`, no internet required. This is the WebKit equivalent of
  WebView2's virtual host mapping.
- The native SwiftUI view shows a placeholder (note + diagram source); the
  PDF export embeds the diagrams as PNGs harvested from the preview (see
  Step 7).

**Step 9 — LaTeX formulas**

Display mathematics delimited by `$$` is typeset by
[MathJax](https://www.mathjax.org/). swift-markdown is a CommonMark/GFM
parser and has no math extension, so the feature is built entirely out of
pieces that already exist:

- `MathBlocks.preprocess(_:)` rewrites every `$$ … $$` block into a
  ` ```math ` fenced code block **before** parsing. From that point on a
  formula is an ordinary `CodeBlock` in the AST, so all three renderers reach
  it through the same `visitCodeBlock` / `renderBlock` path they already use
  for mermaid — no second parser, no AST surgery. The rewrite skips anything
  inside a code fence (so a ` ```markdown ` block documenting `$$` survives)
  and leaves an unterminated `$$` alone.
- `HtmlRenderer` emits the fence as `<div class="math">$$ … $$</div>`.
- `HtmlPageRenderer` configures MathJax **before** loading it:
  `displayMath: [['$$','$$']]` with `inlineMath: []` (only display math is
  supported, so a `$5` price in prose is never mistaken for a formula),
  `tags: 'none'` (no automatic numbering; an explicit `\tag{…}` still
  renders), and `ignoreHtmlClass: 'markdown-body'` /
  `processHtmlClass: 'math'`, which confine the delimiter scan to the math
  divs. `svg: { fontCache: 'local' }` is essential for the PDF path: it keeps
  each formula's glyph definitions inside its own `<svg>` instead of a
  page-global one, so a harvested formula is self-contained.
- The ~2.2 MB `tex-svg-full.js` is served through the same `appassets://`
  scheme handler as mermaid.js. The *full* build bundles every TeX package,
  so MathJax never falls back to loading extensions from a CDN — the app
  stays fully offline.
- The native SwiftUI view shows a placeholder (note + formula source), like
  mermaid. The PDF export rasterizes the rendered formulas out of the preview
  with the shared `harvestSVGPNGs` helper, forcing the ink to black (the PDF
  is always on white, even when the preview is in dark mode) and scaling each
  image by `bodyFont.pointSize / 15` so a formula keeps the same size
  relative to the surrounding text as it has in the preview.
- MathJax skips a formula it cannot parse without aborting the ones after it;
  the untypeset source stays visible in the preview (in monospace) and the
  PDF prints it as a code block, so nothing silently disappears.

**Step 10 — Inline formulas**

An inline formula sits *inside* a paragraph, so the fenced-code trick of
Step 9 does not apply. `InlineMath` instead rewrites the **parsed AST**: every
`Text` node is split into the prose around a formula and an `InlineCode` node
carrying the TeX behind a sentinel prefix. Rewriting the tree rather than the
source means inline code (`` `$PATH` ``), link destinations and raw HTML are
skipped for free — the parser has already told them apart from running text.

`$` is an everyday character, so a candidate must clear two independent gates
before it becomes a formula:

1. **Delimiter rules**, as in Pandoc: the opening `$` is not followed by
   whitespace, the closing `$` is not preceded by whitespace and not followed
   by a digit, and no `$` appears in between. This alone keeps
   `$5 and $10 net` prose.
2. **Structural LaTeX validity** (`InlineMath.isValidLatex`): balanced braces,
   `\left`/`\right` and `\begin`/`\end` environments, well-formed control
   sequences, sub/superscripts with an argument, and no character that only
   means something outside math mode (`%`, `#`, a bare `&`). Unknown macros
   pass deliberately — a macro allow-list would need maintaining and would
   reject valid documents.

The check is structural, not semantic, so `$5$` and `$Preis$` are accepted:
both are valid LaTeX. That is a deliberate choice — guessing *intent* from a
valid expression produces more surprises than it prevents, and the delimiter
rules already cover the common currency case.

Each gate is enforced once, in Swift, before any renderer sees the document —
so the preview, the native view and the PDF always agree on what is a formula.
MathJax is then told to look for `\(…\)` inline (not `$…$`), which is exactly
what `HtmlRenderer` emits for a carrier node.

The PDF is the interesting part: Core Text has no concept of an embedded
image. Each formula becomes a zero-ink U+FFFC run whose width, ascent and
descent are reported by a `CTRunDelegate`, so Core Text reserves exactly the
right box on the line and grows the line height for a tall formula. After
`CTFrameDraw`, `drawInlineMath` walks the frame's runs and draws the harvested
picture into each placeholder's rectangle — which, because the delegate
supplied the descent, already sits on the text baseline. Every `CTFrameDraw`
site has to make that call: paragraphs and headings go through `drawText`,
table cells lay out their own frames.

Sizes come from the harvester in **em of the surrounding text** rather than in
pixels (`HarvestedSVG`), because the preview renders at 15 px and the PDF at
11 pt: multiplying by the current font's point size keeps a formula in
proportion wherever it lands, including inside a heading.

### 3.4 Building and running

```
cd src/MarkdownEditor
swift run MarkdownEditor
```

Requirements: macOS 15 (Sequoia) or later, Xcode 16+ / Swift 6 toolchain.
The package can also be opened directly in Xcode (`open Package.swift`) and
run from there. `MarkdownEditorApp` sets
`NSApplication.shared.setActivationPolicy(.regular)` and activates itself so
the window comes to the front even when launched from the terminal via
`swift run`.

### 3.5 Things to try

1. Type in the left pane and watch all three tabs update.
2. Compare tab 1 (HTML) and tab 3 (SwiftUI) — same AST, different targets.
3. Look at tab 2 to see exactly what the HTML renderer emits, including the
   `<span class="tok-…">` runs from the custom code block handling.
4. Change ` ```csharp ` to ` ``` ` in the sample and watch the highlighting
   disappear in both views.
5. Add a pipe table or `~~strikethrough~~` — these work because
   swift-markdown enables the GFM extensions by default.
6. Load one of your own Markdown files via **Open file…**.
7. Export the document via **Export PDF…** and compare the PDF layout with
   the HTML and SwiftUI tabs — three renderers, one source.
8. Edit the ` ```mermaid ` block in the sample (add a node or an arrow) and
   watch the diagram redraw in the HTML preview.
9. Edit a `$$ … $$` block (try `\frac{a}{b}` or `\begin{pmatrix}…`) and watch
   the formula re-typeset; export the PDF to see the same formula embedded
   there.
10. Write `$x^2$` mid-sentence and watch it typeset inline; then write
    `$5 and $10` and watch it stay prose. Break a formula (`$\frac{a}{b$`) and
    it falls back to literal text — the validity check runs before any
    renderer sees it.
11. Switch macOS between light and dark mode — the HTML preview
    (`prefers-color-scheme`) and the SwiftUI view both follow along. The
    formulas follow the foreground color in the preview but are always black
    in the PDF.

## 4. Limitations (by design, it's a demo)

- The tokenizers are approximate: no string-interpolation holes, no raw
  string literals (`"""`), no regex literals (JS), no contextual type-name
  coloring.
- Raw HTML embedded in Markdown is rendered in the HTML view but skipped by
  the SwiftUI renderer.
- Images are shown as placeholders in the SwiftUI view.
- Formulas in the PDF are images harvested from the preview: they are not
  selectable text, and (like mermaid diagrams) they need the HTML Preview tab
  to have rendered first. Without a harvested image the TeX source is printed
  instead, so a formula never silently disappears.
- The native SwiftUI view shows formula *source*, not typeset mathematics —
  typesetting needs the TeX engine that lives in the WebKit preview.
- Inline math is decided on the AST, by which point CommonMark has already
  consumed a `\$` escape. To keep a dollar pair literal, use a code span.
- C#, JavaScript, TypeScript and Python ship with tokenizers; other fence
  languages render as plain monospace until a tokenizer is registered in
  `SyntaxHighlighting`.
- Mermaid diagrams in the PDF depend on the WKWebView preview: they are
  harvested from the rendered page, so exporting before the preview finished
  (or when a diagram has syntax errors) falls back to printing the diagram
  source as a code block.
- The PDF renderer skips raw HTML and renders markdown images as
  placeholders, like the SwiftUI view.
- Long code blocks and tables in the PDF are paginated per block, not split
  mid-block; a block taller than one page is clipped.
- Built as a SwiftPM executable for CLI-friendliness; a sandboxed,
  signed `.app` bundle would need an Xcode app target (the code is unchanged).

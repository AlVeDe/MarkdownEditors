# Markdig Demo Application — Specification & Walkthrough

A WPF (.NET 10) demo application that shows how to use the
[Markdig](https://github.com/xoofx/markdig) library to parse and render
Markdown — once with Markdig's **standard HTML renderer** and once with a
**custom renderer** that produces a native WPF `FlowDocument`, including
syntax highlighting for C#, JavaScript, TypeScript and Python code examples.
Markdown files can be loaded from
disk and exported to PDF via a third custom renderer built on QuestPDF —
with colored code and embedded mermaid diagrams; ` ```mermaid ` blocks are
rendered as diagrams in the HTML preview via a bundled mermaid.js.

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
   generated: plain text, PDF — or, as in this demo, a WPF `FlowDocument`.

## 2. Background: What is Markdig?

[Markdig](https://github.com/xoofx/markdig) (by Alexandre Mutel) is the de
facto standard Markdown processor for .NET:

- **CommonMark compliant**, fast, and allocation-friendly.
- **Extensible pipeline**: features are opt-in extensions.
  `new MarkdownPipelineBuilder().UseAdvancedExtensions().Build()` enables the
  most common ones (pipe tables, strikethrough, autolinks, task lists, …).
- **Exposed AST**: `Markdown.Parse(text, pipeline)` returns a
  `MarkdownDocument` you can walk or transform yourself.
- **Pluggable renderers**: the built-in `HtmlRenderer` holds a collection of
  `ObjectRenderers` (one per AST node type). You can replace any of them or
  write a completely new renderer for a different output format.

The one-liner most people start with:

```csharp
string html = Markdown.ToHtml("# Hello **Markdig**!", pipeline);
```

## 3. The demo application

### 3.1 What you see

The main window is split in two:

| Area | Content |
| --- | --- |
| Left pane | An editable `TextBox` with the Markdown source (preloaded from `Samples/Sample.md`) |
| Left pane header | **Open file…** and **Export PDF…** buttons |
| Right pane, tab 1 | **HTML preview** — the standard renderer's HTML shown in a WebView2 (Edge) control |
| Right pane, tab 2 | **Raw HTML output** — the exact HTML string Markdig produced |
| Right pane, tab 3 | **Native WPF** — a `FlowDocument` built by the custom renderer, no HTML involved |

Typing in the editor re-renders all three views live (debounced to 300 ms).
**Open file…** loads a `.md`/`.markdown` file from disk into the editor
(which re-renders all tabs); **Export PDF…** saves the current editor content
as a PDF rendered by QuestPDF.
Code blocks in registered languages (C#, JavaScript, TypeScript, Python) are
syntax-highlighted in the HTML preview **and** in the native WPF view, using
one shared tokenizer per language.

### 3.2 Project layout

```
src/
  MarkdigDemo.slnx                     Solution file (.NET 10 slnx format)
  MarkdigDemo/
    MarkdigDemo.csproj                 net10.0-windows, UseWPF, 3 NuGet packages
    MainWindow.xaml                    Editor + GridSplitter + TabControl layout
    MainWindow.xaml.cs                 Pipeline setup, debounce, render orchestration,
                                       open-file and export-PDF button handlers
    Samples/Sample.md                  Demo document loaded at startup
    Assets/mermaid.min.js              Bundled mermaid.js (v11) for the HTML preview
    Rendering/
      SyntaxHighlighting.cs            ILanguageTokenizer + language registry
      CSharpTokenizer.cs               Minimal C# lexer -> (kind, text) tokens
      JavaScriptTokenizer.cs           JavaScript lexer (base for TypeScript)
      TypeScriptTokenizer.cs           JavaScript lexer + TS type keywords
      PythonTokenizer.cs               Python lexer (# comments, triple quotes)
      HighlightedCodeBlockRenderer.cs  Plug-in for the standard HTML renderer
      HtmlPageRenderer.cs              Runs HtmlRenderer, wraps result in CSS page
      FlowDocumentRenderer.cs          Custom AST -> WPF FlowDocument renderer
      PdfDocumentRenderer.cs           Custom AST -> QuestPDF document renderer
      PdfExporter.cs                   PDF export entry point (license, GeneratePdf)
spec/
  MarkdigDemo-Spec.md                  This document
```

NuGet packages used: **Markdig** (markdown engine),
**Microsoft.Web.WebView2** (modern Edge-based HTML preview control), and
**QuestPDF** (PDF layout engine used by the custom PDF renderer).

### 3.3 Step-by-step: how it works

**Step 1 — Build the pipeline once** (`MainWindow.xaml.cs`)

```csharp
_pipeline = new MarkdownPipelineBuilder()
    .UseAdvancedExtensions()   // tables, strikethrough, autolinks, ...
    .Build();
```

The pipeline is immutable and thread-safe; the app creates it once and reuses
it for every render.

**Step 2 — Parse the Markdown into an AST**

```csharp
var document = Markdown.Parse(markdown, _pipeline);
```

`document` is a `MarkdownDocument` — the syntax tree. The app parses **once**
and feeds the same tree to both renderers, which is the whole point of the
AST-based design.

**Step 3 — Standard rendering: AST → HTML** (`HtmlPageRenderer.cs`)

Instead of calling the `Markdown.ToHtml` shortcut, the demo sets the
`HtmlRenderer` up explicitly so it can customize it:

```csharp
var renderer = new HtmlRenderer(writer);
pipeline.Setup(renderer);                                    // attach extensions
renderer.ObjectRenderers.RemoveAll(r => r is CodeBlockRenderer);
renderer.ObjectRenderers.Add(new HighlightedCodeBlockRenderer());
renderer.Render(document);
```

`HighlightedCodeBlockRenderer` (a `HtmlObjectRenderer<CodeBlock>`) takes over
all code blocks: blocks fenced with `csharp` are emitted as
`<span class="tok-keyword">…</span>` runs; everything else is escaped plain
text. This demonstrates the intended Markdig extension point — replacing one
object renderer while the rest of the standard pipeline stays untouched.

The fragment is then wrapped in a small HTML page with embedded CSS
(GitHub-like styling plus Visual-Studio-like token colors) and pushed to the
WebView2 control via `NavigateToString`. The unwrapped fragment is what the
"Raw HTML output" tab shows.

**Step 4 — Custom rendering: AST → FlowDocument** (`FlowDocumentRenderer.cs`)

The custom renderer is a plain class with a `switch` over the AST node types:

| Markdig AST node | WPF FlowDocument element |
| --- | --- |
| `HeadingBlock` | `Paragraph` with level-based font size, bottom border for h1/h2 |
| `ParagraphBlock` | `Paragraph` |
| `QuoteBlock` | `Section` with a left border and muted foreground |
| `ListBlock` / `ListItemBlock` | `List` / `ListItem` (decimal or disc markers) |
| `FencedCodeBlock` / `CodeBlock` | `Paragraph` in Consolas on a gray background; C# gets colored `Run`s |
| `Markdig.Extensions.Tables.Table` | `System.Windows.Documents.Table` with borders and header styling |
| `ThematicBreakBlock` | Border-only `Paragraph` (horizontal rule) |
| `EmphasisInline` | `Bold`, `Italic`, or strikethrough `Span` (checks `DelimiterChar`/`Count`) |
| `CodeInline` | Consolas `Run` with background |
| `LinkInline` | `Hyperlink` that opens the default browser; images become a placeholder |

Nothing HTML-related is involved — this is Markdown rendered directly into
WPF's own document model, which means real WPF text selection, styling and
layout.

**Step 5 — syntax highlighting** (`CSharpTokenizer.cs`, `SyntaxHighlighting.cs`)

A deliberately small hand-written C# lexer splits code into tokens: keywords,
strings (incl. `@`/`$` prefixed), comments (`//`, `/* */`, `///`), numbers,
and preprocessor directives. It returns `(TokenKind, string)` pairs and knows
nothing about output formats — the HTML renderer maps kinds to CSS classes,
the FlowDocument renderer to `Brush`es, the PDF renderer to font colors. One
tokenizer, three outputs.

Languages are pluggable: `SyntaxHighlighting` maps fence info strings to
`ILanguageTokenizer` implementations. All three renderers look their
tokenizer up there, so adding a language means writing one tokenizer class
and one `Register` call — it is then colored in the HTML preview, the WPF
view and the PDF export alike. Registered out of the box:

| Language | Aliases | Tokenizer |
| --- | --- | --- |
| C# | `csharp`, `cs`, `c#` | `CSharpTokenizer` |
| JavaScript | `javascript`, `js`, `jsx` | `JavaScriptTokenizer` |
| TypeScript | `typescript`, `ts`, `tsx` | `TypeScriptTokenizer` (JS + type keywords) |
| Python | `python`, `py` | `PythonTokenizer` (`#` comments, triple-quoted strings, decorators via the preprocessor color) |

**Step 6 — Live updates**

`TextChanged` on the editor starts a 300 ms `DispatcherTimer`; each keystroke
restarts it, so rendering only happens when typing pauses (debouncing). The
WebView2 control is initialized asynchronously (`EnsureCoreWebView2Async`)
with a user-data folder under `%TEMP%`, and the first render runs after that
completes.

**Step 7 — Loading Markdown files**

The **Open file…** button shows an `OpenFileDialog` filtered to
`*.md;*.markdown` and loads the chosen file into the editor. No extra render
plumbing is needed: setting `EditorBox.Text` fires the same
`TextChanged` → debounce → render path as typing, so all three tabs update
automatically. The window title shows the loaded file name; read failures
(locked file, missing permissions) are reported in a message box.

**Step 8 — PDF export** (`PdfExporter.cs`, `PdfDocumentRenderer.cs`)

The **Export PDF…** button parses the editor text with the shared pipeline
and hands the AST to `PdfDocumentRenderer` — a third custom renderer for the
same syntax tree (HTML, FlowDocument, PDF), built on
[QuestPDF](https://www.questpdf.com/) (community license, set once in
`PdfExporter`'s static constructor):

- A4 pages, 2 cm margins, a page-number footer (`1 / 3`).
- The block/inline mapping mirrors `FlowDocumentRenderer`: headings with a
  size ladder and h1/h2 underlines, quotes with a left border, nested lists,
  bordered tables with header styling, hyperlinks, inline code on a gray
  background.
- **Code blocks are syntax-highlighted**: languages registered in
  `SyntaxHighlighting` are tokenized and emitted as QuestPDF text spans with
  `.FontColor(...)`, using the same colors as the HTML preview's CSS.
- **Mermaid blocks become images**: before rendering, `MainWindow` harvests
  the already-rendered diagrams from the WebView2 preview — each SVG is
  serialized, drawn onto a canvas at 2x resolution and read back as a PNG
  data URL (`HarvestMermaidPngsAsync`). The PNGs are passed to the renderer
  in document order; if harvesting fails (preview not ready, render error),
  the diagram source is printed as a code box instead.

An alternative one-liner worth knowing: `CoreWebView2.PrintToPdfAsync` prints
the preview page pixel-identically (colors and diagrams included) but gives
up QuestPDF's layout control — this demo deliberately takes the
custom-renderer route.

QuestPDF's community license is free for individuals and companies below the
QuestPDF revenue threshold (currently 1 M USD annual revenue); larger
commercial use requires a paid license.

**Step 9 — Mermaid diagrams**

Code blocks fenced with ` ```mermaid ` are turned into diagrams by
[mermaid.js](https://mermaid.js.org/), which needs a browser engine and
therefore runs inside the WebView2 preview:

- `HighlightedCodeBlockRenderer` emits mermaid fences as
  `<pre class="mermaid">` (mermaid's default selector) instead of
  `<pre><code>`.
- `WrapInPage` loads the bundled `Assets/mermaid.min.js` and calls
  `mermaid.initialize({ startOnLoad: true, securityLevel: 'strict',
  suppressErrorRendering: true, htmlLabels: false })`. Error rendering is
  suppressed so that half-typed diagrams (the debounce re-renders while
  typing) don't flash error graphics; `htmlLabels: false` keeps labels as
  plain SVG `<text>` so the PDF export can rasterize the diagrams onto a
  canvas without tainting it.
- Because `NavigateToString` caps pages at 2 MB, the ~3.5 MB script cannot be
  inlined. Instead `MainWindow` registers a WebView2 **virtual host**:
  `SetVirtualHostNameToFolderMapping("appassets.local", <app>/Assets, Allow)`
  — the page then loads `https://appassets.local/mermaid.min.js` straight
  from disk, no internet required.
- The native WPF view shows a placeholder (note + diagram source); the PDF
  export embeds the diagrams as PNGs harvested from the preview (see Step 8).

### 3.4 Building and running

```
cd src
dotnet build MarkdigDemo.slnx
dotnet run --project MarkdigDemo
```

Requirements: .NET 10 SDK, Windows, and the WebView2 Runtime (preinstalled on
Windows 11 / current Windows 10).

### 3.5 Things to try

1. Type in the left pane and watch all three tabs update.
2. Compare tab 1 (HTML) and tab 3 (FlowDocument) — same AST, different targets.
3. Look at tab 2 to see exactly what the standard renderer emits, including
   the `<span class="tok-…">` runs from the custom code block renderer.
4. Change ` ```csharp ` to ` ``` ` in the sample and watch the highlighting
   disappear in both views.
5. Add a pipe table or `~~strikethrough~~` — these work because of
   `UseAdvancedExtensions()`.
6. Load one of your own Markdown files via **Open file…**.
7. Export the document via **Export PDF…** and compare the PDF layout with
   the HTML and FlowDocument tabs — three renderers, one source.
8. Edit the ` ```mermaid ` block in the sample (add a node or an arrow) and
   watch the diagram redraw in the HTML preview.

## 4. Limitations (by design, it's a demo)

- The tokenizers are approximate: no string-interpolation holes, no raw
  string literals (`"""`), no regex literals (JS), no contextual type-name
  coloring.
- Raw HTML embedded in Markdown is rendered in the HTML view but skipped by
  the FlowDocument renderer.
- Images are shown as placeholders in the FlowDocument view.
- C#, JavaScript, TypeScript and Python ship with tokenizers; other fence
  languages render as plain monospace until a tokenizer is registered in
  `SyntaxHighlighting`.
- Mermaid diagrams in the PDF depend on the WebView2 preview: they are
  harvested from the rendered page, so exporting before the preview finished
  (or when a diagram has syntax errors) falls back to printing the diagram
  source as a code block.
- The PDF renderer skips raw HTML and renders markdown images as
  placeholders, like the FlowDocument view.

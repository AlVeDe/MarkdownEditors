# MarkdownEditor (macOS)

A native macOS (SwiftUI + AppKit, Swift 6) Markdown editor. Markdown is parsed
with Apple's [swift-markdown](https://github.com/swiftlang/swift-markdown)
and rendered two ways:

1. **HTML** in a live `WKWebView` preview (mermaid diagrams via bundled
   mermaid.js, LaTeX formulas via bundled MathJax), exportable as a
   standalone HTML file
2. **PDF** via Core Graphics / Core Text (**Export as PDF…**), with the same
   syntax-highlighted code colors as the preview, and mermaid diagrams and
   typeset formulas embedded as images harvested from the preview

The source pane is a full code editor (TextKit 1 `NSTextView`): Markdown
syntax highlighting, line numbers, find & replace, list continuation,
formatting commands, table alignment, IntelliSense for Markdown, LaTeX and
mermaid with live error markers, and a formula preview at the caret.

Code fenced as C#, JavaScript, TypeScript or Python is syntax-highlighted in
the editor, the preview and the PDF by one shared tokenizer per language.

## Math

**Display formulas** are delimited by `$$` at the start of a line:

```
$$
E = mc^2
$$
```

Before parsing, such a block is rewritten into a ` ```math ` fenced code block
(`MathBlocks.swift`), so a formula travels through the AST as an ordinary code
block and every renderer handles it on the path it already uses for mermaid.

**Inline formulas** are written between single `$`, anywhere in running text,
including headings and table cells:

```
sei $x \in \mathbb{R}$ die $n$-te Komponente
```

`$` is an everyday character in prose, so a candidate has to clear two gates
before it becomes a formula (`InlineMath.swift`):

1. **Delimiter rules**, as in Pandoc — the opening `$` is not followed by a
   space, the closing `$` is not preceded by one and not followed by a digit,
   and no `$` sits in between. This is what keeps `$5 and $10 net` prose.
2. **Structural LaTeX validity** — balanced braces, `\left`/`\right` and
   environments, well-formed control sequences, sub/superscripts that have an
   argument, no TeX comment (`%`) or parameter (`#`) character. Unknown macros
   pass: there is no macro list to fall out of date.

Anything that fails either gate stays exactly as typed. The check is
structural, not semantic, so `$5$` and `$Preis$` *do* become math (both are
valid LaTeX) — a lone `$5` without a closing partner does not.

The rewrite happens on the parsed AST, so inline code (`` `$PATH` ``), link
destinations and raw HTML are skipped for free.

MathJax (TeX → SVG, bundled in full so nothing is fetched from a CDN) typesets
both kinds in the preview and the PDF.
Equations are not auto-numbered; write `\tag{1}` for an explicit number.

## Requirements

- macOS 15 (Sequoia) or later
- Xcode 16+ (Swift 6). The Command Line Tools alone are not enough: SwiftUI's
  macros (`@State`, `@Entry`, …) ship with Xcode. The scripts below pick
  Xcode's toolchain automatically; for plain `swift build` / `swift test`,
  prefix `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` when
  `xcode-select -p` points at the Command Line Tools.

## Run

The app is a **document app** (`DocumentGroup`): macOS learns from its
`Info.plist` which files it opens, so it has to run as an `.app` bundle — a
bare `swift run` binary cannot open or save documents.

```
cd src/MarkdownEditor
Packaging/run.sh                # builds dist/debug/MarkdownEditor.app and starts it
Packaging/run.sh notes.md       # … and opens a file
```

Tests:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

In Xcode (`xed .` in `src/MarkdownEditor`) the package builds and its tests
run; to try document handling, run the bundle from `Packaging/run.sh`.

## Build an installable app (DMG)

```
cd src/MarkdownEditor
Packaging/build-dmg.sh          # optional argument: version, default 1.0
```

This builds a release binary, assembles `dist/release/MarkdownEditor.app` (with
`Packaging/Info.plist` and `Packaging/AppIcon.icns`), signs it ad hoc and
packs it into `dist/MarkdownEditor-<version>.dmg`. Open the DMG and drag
**MarkdownEditor** onto **Applications**. The app registers itself as an editor
for `.md` / `.markdown` files.

The app is not notarized. A DMG built on the same Mac opens without
complaint; copied to another Mac, the first launch needs right-click ▸
**Open** (or `xattr -dr com.apple.quarantine /Applications/MarkdownEditor.app`).

The icon is drawn in code; to change it, edit `Packaging/make-icon.swift`
and regenerate:

```
swift Packaging/make-icon.swift /tmp/AppIcon.iconset
iconutil -c icns /tmp/AppIcon.iconset -o Packaging/AppIcon.icns
```

## Using the app

**Documents.** Save / Duplicate / Revert work as in any Mac document app,
with autosave and Versions. File ▸ Open…, Open Recent, a double-click in
Finder or a drop on the Dock icon load the file **into the current window**
(the outgoing file is saved first); only File ▸ New opens another window.
An untitled document with unsaved text is never replaced — then the file
gets a window of its own. Help ▸ Open Sample Document opens a copy of the
bundled sample.

**View.** The toolbar's segmented control (or View ▸ ⌥⌘1 / ⌥⌘2 / ⌥⌘3)
switches between editor only, editor and preview, and preview only; View ▸
Split chooses side by side or stacked. The preview updates in place while you
type (no reload, scroll position kept) and follows the editor's scrolling
(View ▸ Synchronize Scrolling). The outline sidebar (toolbar button or ⌃⌘S)
lists the headings; click one to jump there.

**Formatting** (Format menu and toolbar; the toolbar is customizable via
View ▸ Customize Toolbar…):

| Action | Shortcut | Action | Shortcut |
| --- | --- | --- | --- |
| Bold | ⌘B | Link | ⌘K |
| Italic | ⌘I | Image | ⌃⌘I |
| Strikethrough | ⇧⌘X | Quote | ⌥⌘' |
| Inline code | ⌃` | Bulleted / numbered / task list | ⇧⌘8 / ⇧⌘7 / ⇧⌘9 |
| Heading 1–6 | ⌘1 … ⌘6 | Toggle task | ⌃⌘X |
| Paragraph | ⌃⌘0 | Code block | ⌥⌘K |
| Math | ⌃⌘M | Table | ⌥⇧⌘T |
| Indent / outdent | ⌘] / ⌘[ | Highlight | ⇧⌘H |
| Superscript | ⌃⌘= | Subscript | ⌃⌘- |
| Footnote | ⌃⌥⌘F | Horizontal rule | (toolbar / menu) |

Applying a wrapper (bold, italic, …) to already-wrapped text removes it.
Markdown has no portable syntax for highlight, subscript and superscript
(`~x~` already means strikethrough in GFM), so they are written as the HTML
tags `<mark>`, `<sub>` and `<sup>` — valid CommonMark, shown by the preview,
the PDF and GitHub alike. **Footnote** inserts `[^n]` at the caret and a
`[^n]: ` definition at the end of the document (GitHub syntax); the preview
and the PDF number footnotes by first use and list them at the end.

The toolbar starts with Open, Save and Export PDF on the far left.

**Editing.** Return continues lists, task lists and quotes (and ends them on
an empty item); numbered lists renumber themselves after Return, moving,
duplicating or deleting lines and indenting (Settings ▸ Editor, or
Format ▸ Renumber List by hand); Tab / ⇧Tab indent and outdent; brackets, quotes and
backticks close in pairs and wrap a selection. In a table, Tab aligns the
columns and moves to the next cell. Pasting or dropping an image into a saved
document copies it to `<document>.assets/` and inserts the link. Edit ▸
Lines: move up / down (⌃⌘↑ / ⌃⌘↓), duplicate (⇧⌘D), delete (⌃⇧K), join (⌃J),
toggle comment (⌘/). Find & replace (⌘F / ⌥⌘F), Use Selection for Find (⌘E),
Go to Line (⌘L).

**IntelliSense.** Suggestions open while typing (or with ⌥⎋ / ⌃Space):

- *Markdown*: heading anchors after `](#`, reference labels, file paths after
  `](` / `![](`, fence languages after ```` ``` ````, block snippets such as
  `table`, `code`, `mermaid`, `math`, `details`.
- *LaTeX* (inside `$…$` / `$$…$$`): ~450 commands after `\`, environments
  after `\begin{` (with the matching `\end{…}`), letters for `\mathbb{` and
  friends. While the caret is in a formula, a small panel shows it typeset.
- *Mermaid* (inside a ```` ```mermaid ```` fence): diagram types with
  templates, the keywords and arrows of the current diagram type, and the
  node ids / participants already defined.

Snippets have placeholders: Tab jumps to the next, ⇧Tab to the previous.
Errors that MathJax or mermaid report in the preview are underlined in the
editor; the message appears in the status bar.

**Export.** File ▸ Export as PDF… (⌥⌘E) saves an A4 PDF (2 cm margins,
`page / total` footer, colored code blocks, clickable links, and mermaid
diagrams and formulas exactly as shown in the preview — let the preview
finish rendering first; they are harvested from it). File ▸ Export as HTML…
(⇧⌘E) saves the preview as one standalone `.html` file with diagrams and
formulas inline as SVG. File ▸ Print… (⌘P) prints the preview.

**Settings** (⌘,): font, tab width, spaces vs. tabs, line wrapping, line
numbers, invisibles, current-line highlight, auto-pairs, smart quotes, spell
checking, automatic completions, default view mode, split orientation, sync
scrolling.

## Architecture

```
Sources/MarkdownEditor/
  App/          app entry (DocumentGroup), menus (File/Edit/View/Format/Help)
  Document/     MarkdownDocument (the file), DocumentSession (one window)
  Editor/       EditorController + MarkdownTextView (TextKit 1), line-number
                ruler, settings, EditorExtensionPoints (the plug-in contracts)
    Highlighting/  incremental Markdown highlighter, also answers "context at
                   caret" (prose, code, inline/display math, mermaid, …)
    Assist/        list/indent/pair assistance, format actions, line ops,
                   table formatter, image paste/drop
    Completion/    popup, fuzzy ranking, snippet sessions; Providers/ for
                   Markdown, LaTeX (catalog in Resources/latex-commands.json)
                   and mermaid
    MathPreview/   formula preview panel at the caret
  Preview/      PreviewController: shell page + incremental updates, scroll
                sync, render diagnostics, docfile:// for relative images
  Rendering/    HtmlRenderer, MathBlocks/InlineMath, tokenizers, PDF renderer
  UI/           document window, toolbars, status bar, outline, settings
```

Everything language-specific plugs into the editor through the protocols in
`EditorExtensionPoints.swift` (`EditorHighlighter`, `EditorInputHandler`,
`CompletionProvider`, `EditorDiagnostic`); `EditorFeatures.swift` wires them
up.

## Notes

- The PDF's mermaid and formula images require the HTML preview to have
  rendered the document. Formulas are drawn in black in the PDF regardless of
  the preview's appearance.
- YAML front matter at the top of a file is ignored by the preview and PDF.
- Because inline math is decided on the AST, a `\$` escape is already gone by
  then: to keep a dollar pair literal, put it in a `` ` `` code span.
- Built as a SwiftPM executable; `Packaging/make-app.sh` wraps it in an `.app`
  bundle. A sandboxed, notarized build would need an Xcode app target and a
  Developer ID — the code is unchanged.

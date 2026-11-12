# MarkdownEditors

Two desktop Markdown editors that offer the same features. One is a native
macOS app written in Swift. The other is a Rust/Tauri port that runs on
Windows, Linux and macOS.

Both editors have:

- A code editor with Markdown syntax highlighting, line numbers, find &
  replace, list continuation and renumbering, table alignment, formatting
  commands and line operations
- IntelliSense for **Markdown** (heading anchors, file paths, fence
  languages, snippets), **LaTeX** (about 450 commands and environments) and
  **mermaid** (diagram types, keywords, node ids)
- A live HTML preview with **mermaid** diagrams and **LaTeX** math (`$…$`
  inline and `$$…$$` display, typeset by a bundled MathJax). Nothing is loaded
  from a CDN.
- Syntax highlighting for C#, JavaScript, TypeScript and Python code blocks in
  the editor, the preview and the PDF
- An outline sidebar, scroll sync, footnotes, and image paste/drop into a
  `<document>.assets/` folder
- Export to **PDF** and to a single standalone **HTML** file

## Repository layout

| Folder | Contents |
| --- | --- |
| [`MarkdownEditor/`](MarkdownEditor/src/README.md) | Native macOS app (Swift 6, SwiftUI + AppKit) |
| [`MarkdownEditorRust/`](MarkdownEditorRust/src/README.md) | Cross-platform port (Rust, Tauri 2) |
| [`spec/`](spec) | Specifications and walkthroughs |
| [`.github/workflows/`](.github/workflows/rust-app.yml) | CI workflow that builds the Rust app on all three platforms |

---

## MarkdownEditor (macOS, Swift)

A native macOS document app built with SwiftUI and AppKit. The editor uses a
TextKit 1 `NSTextView`. It parses Markdown with Apple's
[swift-markdown](https://github.com/swiftlang/swift-markdown) and renders it in
two ways:

1. **HTML** in a live `WKWebView` preview
2. **PDF** with Core Graphics and Core Text. The mermaid diagrams and
   formulas in the PDF are copied as images from the preview.

**Requirements:** macOS 15 (Sequoia) or later, Xcode 16 or later (Swift 6).

```sh
cd MarkdownEditor/src
Packaging/run.sh                 # build the debug .app and start it
Packaging/run.sh notes.md        # ...and open a file
Packaging/build-dmg.sh 1.0       # build an installable DMG
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The app must run as an `.app` bundle to open and save documents. A plain
`swift run` doesn't work for this.

Source layout (`MarkdownEditor/src/Sources/MarkdownEditor`):

```
App/          app entry, menus
Document/     document model and per-window session
Editor/       text view, highlighting, editing assistance, completion, math preview
Preview/      WKWebView preview, scroll sync, render diagnostics
Rendering/    HTML renderer, math rewriting, code tokenizers, PDF renderer
UI/           window, toolbars, outline, settings
Resources/    sample document, mermaid.js, MathJax, LaTeX command catalog
```

See [MarkdownEditor/src/README.md](MarkdownEditor/src/README.md) for the
full feature list and keyboard shortcuts.

---

## MarkdownEditorRust (Windows / Linux / macOS)

A port of the macOS app to Rust, using [Tauri 2](https://tauri.app). All program
logic is in Rust. The UI runs in the system web view: WebView2 on Windows,
WebKitGTK on Linux and WKWebView on macOS.

The Cargo workspace is in `MarkdownEditorRust/src` and has two crates:

| Crate | Folder | Purpose |
| --- | --- | --- |
| `mdcore` | `src/core` | Platform-independent, unit-tested logic. Includes rendering (comrak, HTML, PDF via `pdf-writer`), highlighting, editing commands, completion and outline. |
| `markdown-editor` | `src/app` | Tauri shell (windows, native menus, dialogs, file access) and the web front end in `ui/` |

**Requirements:** Rust (stable). Windows needs the WebView2 runtime and the
MSVC Build Tools. Linux needs the WebKitGTK 4.1 development packages.

```sh
cd MarkdownEditorRust/src
cargo test -p mdcore                                       # core tests
cargo run -p markdown-editor -- notes.md                   # run (debug)
cargo run -p mdcore --example render_pdf -- in.md out.pdf  # render a PDF from the command line
cargo install tauri-cli --version "^2" --locked
cd app && cargo tauri build                                # build installers
```

`cargo tauri build` creates `.msi` and NSIS `.exe` installers on Windows,
`.deb`, `.rpm` and `.AppImage` packages on Linux, and an `.app` and `.dmg` on
macOS.

How it differs from the macOS version:

- The editor is a `<textarea>` over a highlighted backdrop.
- The PDF uses the standard PDF fonts and is limited to Windows-1252 text.
- There is no autosave, Versions or Open Recent.
- Find & replace has its own search bar.

For details, see:

- [MarkdownEditorRust/src/README.md](MarkdownEditorRust/src/README.md):
  architecture and the full list of differences
- [MarkdownEditorRust/BUILD.md](MarkdownEditorRust/BUILD.md): build steps for
  each platform and troubleshooting

> **Note:** `.github/workflows/rust-app.yml` still points to the old path
> `src/MarkdownEditorRust`. Change it to `MarkdownEditorRust/src` before you
> use it.

---

## Specifications (`spec/`)

- **`MarkdigDemo-Spec.md`**: specification and walkthrough of a WPF (.NET 10)
  demo that uses [Markdig](https://github.com/xoofx/markdig). It renders
  Markdown to HTML, to a native WPF `FlowDocument` and to PDF (QuestPDF).
  This demo's code is not in this repository.
- **`MarkdownEditor-macOS-Spec.md`**: the macOS/SwiftUI version of the same
  demo, based on swift-markdown, WKWebView and Core Graphics. It also
  explains which macOS part replaces each WPF part.

## License

[MIT](LICENSE) © 2026 AlVeDe

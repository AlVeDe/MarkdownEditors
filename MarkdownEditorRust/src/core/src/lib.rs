//! Platform-independent core of MarkdownEditor.
//!
//! Everything that does not need a window lives here, so it builds and is
//! tested on Windows, Linux and macOS alike: Markdown parsing and the HTML /
//! PDF renderers, the editor's syntax highlighter, the editing assists
//! (lists, tables, formatting, line operations), IntelliSense providers and
//! the outline. The Tauri app (`app/`) is a thin shell around it.

pub mod api;
pub mod completion;
pub mod editor;
pub mod highlight;
pub mod math_locator;
pub mod outline;
pub mod render;
pub mod text;

/// The document shown on first launch.
pub const SAMPLE_MARKDOWN: &str = include_str!("Sample.md");

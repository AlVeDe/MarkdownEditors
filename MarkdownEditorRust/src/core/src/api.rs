//! The serializable surface the front end talks to (through Tauri
//! commands). Each function takes the editor's text as the front end has it
//! and returns plain data, so the app layer stays a thin adapter and all of
//! this is testable without a window.

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::completion::{self, snippet, Entry, ListModel};
use crate::editor::format::FormatAction;
use crate::editor::{EditOutcome, Editor, Settings};
use crate::highlight::{self, Decoration, EditorContext, RenderOptions};
use crate::math_locator::{self, MathFormula};
use crate::outline::{self, OutlineHeading};
use crate::render::diagnostics::{self, Diagnostic, Report};
use crate::render::{ast, html};
use crate::text::{line_count, Range, Text};

/// An editing command from a key, menu or toolbar.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "command", rename_all = "camelCase")]
pub enum EditCommand {
    /// Return. Tables first, then lists and quotes.
    Newline,
    /// Tab. Tables first, then list indent / indent unit.
    Tab,
    Backtab,
    DeleteBackward,
    /// One typed character (auto-pairs, wrapping the selection).
    InsertText { text: String },
    Format {
        #[serde(flatten)]
        action: FormatAction,
        #[serde(default)]
        clipboard: Option<String>,
    },
    MoveLinesUp,
    MoveLinesDown,
    DuplicateLines,
    DeleteLines,
    JoinLines,
    ToggleLineComment,
    SelectLines,
    RenumberList,
    FormatTable,
    /// Pasted image (PNG bytes, base64) at the selection.
    PasteImage { png_base64: String, document_path: Option<PathBuf> },
    /// Dropped or pasted files at `location`.
    InsertFiles { paths: Vec<PathBuf>, document_path: Option<PathBuf>, location: Option<usize> },
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EditResponse {
    /// False when the command did not apply (the key keeps its default).
    pub handled: bool,
    pub outcome: Option<EditOutcome>,
    /// A message for the user (e.g. "Save the document first…").
    pub message: Option<String>,
}

impl EditResponse {
    pub fn unhandled() -> Self {
        EditResponse { handled: false, outcome: None, message: None }
    }
}

pub fn edit(text: &str, selection: Range, settings: &Settings, command: EditCommand) -> EditResponse {
    let mut e = Editor::new(text, selection, settings);
    let handled = match command {
        EditCommand::Newline => e.table_insert_newline() || e.insert_newline(),
        EditCommand::Tab => e.table_move_to_cell(true) || e.insert_tab(),
        EditCommand::Backtab => e.table_move_to_cell(false) || e.insert_backtab(),
        EditCommand::DeleteBackward => e.delete_backward(),
        EditCommand::InsertText { text } => e.insert_text(&text),
        EditCommand::Format { action, clipboard } => {
            e.perform(&action, clipboard.as_deref());
            true
        }
        EditCommand::MoveLinesUp => {
            e.move_lines_up();
            true
        }
        EditCommand::MoveLinesDown => {
            e.move_lines_down();
            true
        }
        EditCommand::DuplicateLines => {
            e.duplicate_lines();
            true
        }
        EditCommand::DeleteLines => {
            e.delete_lines();
            true
        }
        EditCommand::JoinLines => {
            e.join_lines();
            true
        }
        EditCommand::ToggleLineComment => {
            e.toggle_line_comment();
            true
        }
        EditCommand::SelectLines => {
            e.select_lines();
            true
        }
        EditCommand::RenumberList => {
            e.renumber_ordered_list_at_selection();
            true
        }
        EditCommand::FormatTable => {
            let location = e.selection.location;
            e.format_table(location)
        }
        EditCommand::PasteImage { png_base64, document_path } => {
            use base64::Engine;
            let Ok(png) = base64::engine::general_purpose::STANDARD.decode(png_base64) else {
                return EditResponse::unhandled();
            };
            if let Err(err) = e.insert_image_data(&png, document_path.as_deref()) {
                return EditResponse { handled: true, outcome: None, message: Some(err.to_string()) };
            }
            true
        }
        EditCommand::InsertFiles { paths, document_path, location } => {
            let range = match location {
                Some(l) => Range::new(l.min(e.text.len()), 0),
                None => e.selection,
            };
            if let Err(err) = e.insert_file_links(&paths, document_path.as_deref(), range) {
                return EditResponse { handled: true, outcome: None, message: Some(err.to_string()) };
            }
            true
        }
    };
    if !handled {
        return EditResponse::unhandled();
    }
    EditResponse { handled: true, outcome: Some(e.finish()), message: None }
}

// MARK: Preview

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Rendered {
    pub html: String,
    pub line_count: usize,
}

/// The preview fragment for `markdown`; relative images resolve against
/// `image_base` (the document-folder URL), if any.
pub fn render_preview(markdown: &str, image_base: Option<&str>) -> Rendered {
    let (doc, map) = ast::parse_mapped(markdown);
    Rendered { html: html::render(&doc, &map, image_base), line_count: line_count(markdown) }
}

/// Maps the preview's error report to editor diagnostics.
pub fn preview_diagnostics(report: &Report, markdown: &str) -> Vec<Diagnostic> {
    let mut all = diagnostics::diagram_diagnostics(&report.mermaid, markdown);
    all.extend(diagnostics::formula_diagnostics(&report.math, markdown));
    all.sort_by_key(|d| d.range.location);
    all
}

// MARK: Editor display

pub fn highlight_lines(text: &str, decorations: &[Decoration], options: &RenderOptions) -> Vec<String> {
    highlight::render_lines(&Text::new(text).u, decorations, options)
}

pub fn context_at(text: &str, location: usize) -> EditorContext {
    highlight::context_at(&Text::new(text).u, location)
}

pub fn formula_at(text: &str, location: usize) -> Option<(MathFormula, String)> {
    let t = Text::new(text);
    let f = math_locator::formula_at(&t, location)?;
    let tex = f.tex(&t);
    Some((f, tex))
}

pub fn outline(text: &str) -> Vec<OutlineHeading> {
    outline::headings(text)
}

#[derive(Debug, Clone, Serialize)]
pub struct Statistics {
    pub words: usize,
    pub characters: usize,
}

pub fn statistics(text: &str) -> Statistics {
    let mut words = 0;
    let mut in_word = false;
    for c in text.chars() {
        let w = c.is_alphanumeric();
        if w && !in_word {
            words += 1;
        }
        in_word = w;
    }
    Statistics { words, characters: text.chars().count() }
}

// MARK: Completion

/// The popup state the front end shows.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CompletionView {
    pub anchor: usize,
    pub entries: Vec<Entry>,
    pub selected: usize,
}

/// One window's completion session (the open popup's model).
#[derive(Default)]
pub struct CompletionSession {
    model: Option<ListModel>,
}

impl CompletionSession {
    pub fn view(&self) -> Option<CompletionView> {
        let m = self.model.as_ref()?;
        Some(CompletionView { anchor: m.anchor, entries: m.entries.iter().take(200).cloned().collect(), selected: m.selected_index })
    }

    /// Asks the providers (typing a trigger or word character, or Ctrl+Space).
    pub fn open(&mut self, text: &str, caret: usize, explicit: bool, document: Option<PathBuf>) -> Option<CompletionView> {
        self.model = completion::query(&Text::new(text), caret, explicit, document);
        self.view()
    }

    /// Re-filters for the text between the anchor and the caret; closes
    /// when the caret left that range or nothing matches.
    pub fn refilter(&mut self, text: &str, caret: usize) -> Option<CompletionView> {
        let t = Text::new(text);
        let m = self.model.as_mut()?;
        if caret < m.anchor || caret > t.len() {
            self.model = None;
            return None;
        }
        let typed = t.substring(Range::new(m.anchor, caret - m.anchor));
        if typed.contains(['\n', '\r']) {
            self.model = None;
            return None;
        }
        if typed != m.query {
            m.filter(&typed);
        }
        if m.is_empty() {
            self.model = None;
            return None;
        }
        self.view()
    }

    pub fn move_selection(&mut self, delta: isize, wrapping: bool) -> Option<CompletionView> {
        self.model.as_mut()?.move_selection(delta, wrapping);
        self.view()
    }

    pub fn select(&mut self, index: usize) -> Option<CompletionView> {
        let m = self.model.as_mut()?;
        if index < m.entries.len() {
            m.selected_index = index;
        }
        self.view()
    }

    pub fn close(&mut self) {
        self.model = None;
    }

    /// Accepts the selected item: the snippet insertion to apply.
    pub fn accept(&mut self, text: &str, caret: usize) -> Option<snippet::SnippetInsertion> {
        let m = self.model.take()?;
        let item = m.selected_item()?.clone();
        let t = Text::new(text);
        let range = m.replacement_range(caret);
        if range.end() > t.len() {
            return None;
        }
        Some(snippet::plan_insertion(&t, &item.insert_text, range))
    }
}

pub fn trigger_characters() -> Vec<char> {
    completion::trigger_characters()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn return_continues_numbered_list() {
        let s = Settings::default();
        let text = "1. a\n2. b";
        let r = edit(text, Range::new(4, 0), &s, EditCommand::Newline);
        let o = r.outcome.unwrap();
        let e = o.edit.unwrap();
        let mut t = Text::new(text);
        t.replace(e.range, &e.text);
        assert_eq!(t.to_string(), "1. a\n2. \n3. b");
        assert_eq!(o.selection, Range::new(8, 0));
    }

    #[test]
    fn latex_completion_session() {
        let mut s = CompletionSession::default();
        let text = "$\\alp$";
        let view = s.open(text, 5, false, None).unwrap();
        assert_eq!(view.entries[0].item.label, "\\alpha");
        let ins = s.accept(text, 5).unwrap();
        assert_eq!(ins.text, "\\alpha");
        assert_eq!(ins.range, Range::new(1, 4));
    }

    #[test]
    fn format_bold_toggles() {
        let s = Settings::default();
        let r = edit("word", Range::new(0, 4), &s, serde_json::from_str(r#"{"command":"format","action":"bold"}"#).unwrap());
        let e = r.outcome.unwrap().edit.unwrap();
        assert_eq!(e.text, "**word**");
    }
}

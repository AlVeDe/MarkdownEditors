//! Editing commands on a UTF-16 buffer.
//!
//! The front end's `<textarea>` owns the text; for a command it sends the
//! text and selection here, the command edits an [`Editor`] buffer (possibly
//! several replacements, e.g. a new list item plus renumbering), and
//! [`Editor::finish`] condenses the result into **one** replacement of the
//! original text plus the new selection. The front end applies that as a
//! single native edit, so every command is exactly one undo step — the same
//! contract the original's `replaceCharacters` / `performEdit` gave.

pub mod assistant;
pub mod format;
pub mod image_paste;
pub mod inline_tags;
pub mod lines;
pub mod prefix;
pub mod renumber;
pub mod settings;
pub mod table;
pub mod table_formatter;

use serde::Serialize;

use crate::highlight::{self, EditorContext};
use crate::text::{Range, Text};
pub use settings::Settings;

/// A buffer being edited by one command.
pub struct Editor<'s> {
    pub text: Text,
    pub selection: Range,
    pub settings: &'s Settings,
    original: Vec<u16>,
    original_selection: Range,
    /// The command could not run (e.g. move up on the first line).
    pub beep: bool,
}

/// What a command did, in coordinates of the text it was given.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct EditOutcome {
    /// The single replacement to apply, if the text changed.
    pub edit: Option<Replacement>,
    /// The selection afterwards (in the new text).
    pub selection: Range,
    pub beep: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Replacement {
    pub range: Range,
    pub text: String,
}

impl<'s> Editor<'s> {
    pub fn new(text: &str, selection: Range, settings: &'s Settings) -> Self {
        Self::from_text(Text::new(text), selection, settings)
    }

    pub fn from_text(text: Text, selection: Range, settings: &'s Settings) -> Self {
        let len = text.len();
        let selection = Range::new(selection.location.min(len), selection.length.min(len - selection.location.min(len)));
        Editor { original: text.u.clone(), original_selection: selection, text, selection, settings, beep: false }
    }

    /// The live text.
    pub fn string(&self) -> &Text {
        &self.text
    }

    pub fn context(&self, location: usize) -> EditorContext {
        highlight::context_at(&self.text.u, location)
    }

    /// Replaces `range` with `replacement`. `selecting` is the selection
    /// afterwards in coordinates of the new text; `None` places the caret
    /// after the replacement.
    pub fn replace_characters(&mut self, range: Range, replacement: &str, selecting: Option<Range>) -> bool {
        let range = Range::new(range.location.min(self.text.len()), range.length.min(self.text.len() - range.location.min(self.text.len())));
        let inserted = self.text.replace(range, replacement);
        self.selection = selecting.unwrap_or(Range::new(inserted.end(), 0));
        true
    }

    /// Whether anything changed.
    pub fn changed(&self) -> bool {
        self.text.u != self.original || self.selection != self.original_selection
    }

    /// The whole command as one replacement of the original text.
    pub fn finish(self) -> EditOutcome {
        let old = &self.original;
        let new = &self.text.u;
        let edit = if old == new {
            None
        } else {
            let mut prefix = 0;
            while prefix < old.len() && prefix < new.len() && old[prefix] == new[prefix] {
                prefix += 1;
            }
            let mut suffix = 0;
            while suffix < old.len() - prefix
                && suffix < new.len() - prefix
                && old[old.len() - 1 - suffix] == new[new.len() - 1 - suffix]
            {
                suffix += 1;
            }
            // Don't split a surrogate pair.
            while prefix > 0 && prefix < old.len() && (0xDC00..0xE000).contains(&old[prefix]) {
                prefix -= 1;
            }
            Some(Replacement {
                range: Range::new(prefix, old.len() - prefix - suffix),
                text: String::from_utf16_lossy(&new[prefix..new.len() - suffix]),
            })
        };
        EditOutcome { edit, selection: self.selection, beep: self.beep }
    }

    /// The document's lines (without terminators) and each line's start.
    pub fn line_table(&self) -> (Vec<String>, Vec<usize>) {
        let s = self.text.to_string();
        let lines: Vec<String> = s.split('\n').map(str::to_string).collect();
        let mut starts = Vec::with_capacity(lines.len());
        let mut offset = 0;
        for line in &lines {
            starts.push(offset);
            offset += line.encode_utf16().count() + 1;
        }
        (lines, starts)
    }
}

pub(crate) fn line_index_of(location: usize, starts: &[usize]) -> usize {
    starts.iter().rposition(|&s| s <= location).unwrap_or(0)
}

pub(crate) fn u16len(s: &str) -> usize {
    s.encode_utf16().count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finish_appends_at_end() {
        let settings = Settings::default();
        let mut e = Editor::new("ab", Range::new(2, 0), &settings);
        e.replace_characters(Range::new(2, 0), "\nc", None);
        assert_eq!(e.finish().edit.unwrap(), Replacement { range: Range::new(2, 0), text: "\nc".into() });
    }

    #[test]
    fn finish_condenses_edits() {
        let settings = Settings::default();
        let mut e = Editor::new("abc\ndef", Range::new(0, 0), &settings);
        e.replace_characters(Range::new(4, 0), "X", None);
        e.replace_characters(Range::new(0, 1), "Y", Some(Range::new(1, 0)));
        let out = e.finish();
        assert_eq!(out.edit.unwrap(), Replacement { range: Range::new(0, 4), text: "Ybc\nX".into() });
    }
}

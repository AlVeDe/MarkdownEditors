//! Formatting Markdown has no syntax for: highlight, subscript and
//! superscript as inline HTML tags, and GitHub-style footnotes.
//!
//! Tags rather than the `==mark==` / `~sub~` / `^sup^` dialects: those are
//! not portable, and `~x~` already means strikethrough in GFM.

use super::{u16len, Editor};
use crate::text::{utf16, Range};

impl Editor<'_> {
    /// Wraps the selection in `<tag>…</tag>`, or unwraps it when the
    /// selection includes the tags or sits right between them.
    pub fn toggle_tag_wrap(&mut self, tag: &str) {
        let open = format!("<{tag}>");
        let close = format!("</{tag}>");
        let (ol, cl) = (u16len(&open), u16len(&close));
        let range = self.selection;
        let selected = self.text.substring(range);
        if selected.starts_with(&open) && selected.ends_with(&close) && range.length >= ol + cl {
            let units = utf16(&selected);
            let inner = String::from_utf16_lossy(&units[ol..units.len() - cl]);
            let len = u16len(&inner);
            self.replace_characters(range, &inner, Some(Range::new(range.location, len)));
            return;
        }
        if range.location >= ol && range.end() + cl <= self.text.len() {
            let before = Range::new(range.location - ol, ol);
            let after = Range::new(range.end(), cl);
            if self.text.substring(before) == open && self.text.substring(after) == close {
                self.replace_characters(
                    Range::new(before.location, after.end() - before.location),
                    &selected,
                    Some(Range::new(before.location, range.length)),
                );
                return;
            }
        }
        self.replace_characters(
            range,
            &format!("{open}{selected}{close}"),
            Some(Range::new(range.location + ol, range.length)),
        );
    }

    /// Inserts `[^n]` after the selection and appends `[^n]: ` at the end of
    /// the document, where the caret goes.
    pub fn insert_footnote(&mut self) {
        let number = next_footnote_number(&self.text.to_string());
        let reference = format!("[^{number}]");
        let caret = self.selection.end();
        self.replace_characters(Range::new(caret, 0), &reference, None);

        let text = self.text.to_string();
        let mut suffix = String::new();
        if !text.is_empty() && !text.ends_with('\n') {
            suffix.push('\n');
        }
        let last_line = text.split('\n').rev().find(|l| !l.trim_matches(|c| c == ' ' || c == '\t').is_empty()).unwrap_or("");
        if !last_line.is_empty() && !is_footnote_definition(last_line) && !text.ends_with("\n\n") {
            suffix.push('\n');
        }
        let definition = format!("[^{number}]: ");
        let end = self.text.len();
        let selection = Range::new(end + u16len(&suffix) + u16len(&definition), 0);
        self.replace_characters(Range::new(end, 0), &format!("{suffix}{definition}"), Some(selection));
    }
}

pub fn next_footnote_number(text: &str) -> usize {
    let mut highest = 0;
    let mut rest = text;
    while let Some(open) = rest.find("[^") {
        rest = &rest[open + 2..];
        let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
        if !digits.is_empty() && rest[digits.len()..].starts_with(']') {
            if let Ok(v) = digits.parse::<usize>() {
                highest = highest.max(v);
            }
        }
    }
    highest + 1
}

pub fn is_footnote_definition(line: &str) -> bool {
    let trimmed = line.trim_start_matches(' ');
    let Some(rest) = trimmed.strip_prefix("[^") else { return false };
    let Some(close) = rest.find(']') else { return false };
    rest[close + 1..].starts_with(':')
}

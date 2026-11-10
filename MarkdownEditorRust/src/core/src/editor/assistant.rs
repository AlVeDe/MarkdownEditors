//! Editing help while typing Markdown: list continuation on Return,
//! indentation on Tab / Shift-Tab, auto-closing pairs and wrapping the
//! selection in emphasis markers.
//!
//! Each function returns `true` when it handled the key (and made its edit
//! on the buffer); `false` lets the text area do its default.

use super::prefix::{is_in_fenced_code, LinePrefix, ListMarker};
use super::Editor;
use crate::highlight::EditorContext;
use crate::text::Range;

/// Characters that open a pair when typed without a selection.
const PAIRS: &[(char, char)] = &[('(', ')'), ('[', ']'), ('{', '}'), ('"', '"'), ('`', '`')];
/// Characters that wrap a selection instead of replacing it.
const WRAPPERS: &[(char, char)] =
    &[('*', '*'), ('_', '_'), ('~', '~'), ('`', '`'), ('(', ')'), ('[', ']'), ('"', '"'), ('$', '$')];

fn pair_of(c: char) -> Option<char> {
    PAIRS.iter().find(|p| p.0 == c).map(|p| p.1)
}

fn wrapper_of(c: char) -> Option<char> {
    WRAPPERS.iter().find(|p| p.0 == c).map(|p| p.1)
}

impl Editor<'_> {
    /// True where Markdown assistance must stay out: code blocks, front
    /// matter, comments.
    fn is_code(&self, location: usize) -> bool {
        match self.context(location) {
            EditorContext::CodeBlock(_)
            | EditorContext::FenceInfo
            | EditorContext::Mermaid
            | EditorContext::FrontMatter
            | EditorContext::HtmlComment => true,
            _ => is_in_fenced_code(&self.text, location),
        }
    }

    fn char_at(&self, location: usize) -> Option<char> {
        if location >= self.text.len() {
            return None;
        }
        let u = self.text.u[location];
        if (0xD800..0xDC00).contains(&u) && location + 1 < self.text.len() {
            return char::decode_utf16([u, self.text.u[location + 1]]).next()?.ok();
        }
        char::from_u32(u as u32)
    }

    fn char_before(&self, location: usize) -> Option<char> {
        if location == 0 {
            return None;
        }
        let u = self.text.u[location - 1];
        if (0xDC00..0xE000).contains(&u) && location >= 2 {
            return char::decode_utf16([self.text.u[location - 2], u]).next()?.ok();
        }
        char::from_u32(u as u32)
    }

    /// Return: continues lists and quotes, ends them on an empty item, and
    /// keeps the indentation of plain lines and code.
    pub fn insert_newline(&mut self) -> bool {
        let selection = self.selection;
        let (line_start, line_end, _) = self.text.line_bounds(selection.location);
        let line = self.text.substring(Range::new(line_start, line_end - line_start));
        let column = selection.location - line_start;
        let parsed = LinePrefix::parse(&line);
        let in_code = self.is_code(selection.location);

        if !in_code && (parsed.is_list_item() || parsed.is_quote()) && column < parsed.prefix_length() {
            return false;
        }
        if in_code || (!parsed.is_list_item() && !parsed.is_quote()) {
            if parsed.indent.is_empty() {
                return false;
            }
            let indent: String = parsed.indent.chars().take(column).collect();
            return self.replace_characters(selection, &format!("\n{indent}"), None);
        }

        let is_empty_item = parsed.content.trim_matches(|c| c == ' ' || c == '\t').is_empty() && selection.end() >= line_end;
        if is_empty_item {
            let remaining = if parsed.is_list_item() {
                format!("{}{}", parsed.indent, parsed.quote)
            } else {
                parsed.indent.clone()
            };
            let trimmed = remaining.trim_end().to_string();
            let range = Range::new(line_start, line_end - line_start);
            if !matches!(parsed.marker, Some(ListMarker::Ordered { .. })) {
                return self.replace_characters(range, &trimmed, None);
            }
            let line_range = self.text.line_range(selection.location);
            return self.perform_list_edit(line_range, false, false, |e| e.replace_characters(range, &trimmed, None));
        }

        let Some(ListMarker::Ordered { delimiter, .. }) = parsed.marker else {
            return self.replace_characters(selection, &format!("\n{}", parsed.continuation()), None);
        };
        let mut continued = parsed.clone();
        if self.continues_all_ones_list(selection.location) {
            continued.marker = Some(ListMarker::Ordered { number: 0, delimiter });
        }
        let line_range = self.text.line_range(selection.location);
        let insertion = format!("\n{}", continued.continuation());
        self.perform_list_edit(line_range, false, false, |e| e.replace_characters(selection, &insertion, None))
    }

    fn is_multi_line_selection(&self, selection: Range) -> bool {
        selection.length > 0 && self.lines_in(self.line_block(selection)).0.len() > 1
    }

    fn current_line_prefix(&self) -> LinePrefix {
        let block = self.line_block(Range::new(self.selection.location, 0));
        LinePrefix::parse(&self.lines_in(block).0[0])
    }

    /// Tab: indent a multi-line selection or a list item, else insert one
    /// indentation unit.
    pub fn insert_tab(&mut self) -> bool {
        let selection = self.selection;
        let unit = self.settings.indent_unit();
        if self.is_multi_line_selection(selection) || (!self.is_code(selection.location) && self.current_line_prefix().is_list_item()) {
            self.perform_list_edit(selection, false, true, |e| e.indent_lines(&unit));
            return true;
        }
        self.replace_characters(selection, &unit, None)
    }

    /// Shift-Tab outdents the selected lines or the current line.
    pub fn insert_backtab(&mut self) -> bool {
        let selection = self.selection;
        let width = self.settings.tab_width;
        self.perform_list_edit(selection, false, true, |e| e.outdent_lines(width));
        true
    }

    /// Typed text: wraps a selection, overtypes a closing character or
    /// inserts a pair.
    pub fn insert_text(&mut self, typed: &str) -> bool {
        let mut chars = typed.chars();
        let (Some(c), None) = (chars.next(), chars.next()) else { return false };
        let range = self.selection;
        if self.settings.smart_quotes && (c == '"' || c == '\'') && self.smart_quote(c, range) {
            return true;
        }
        if !self.settings.auto_pairs {
            return false;
        }
        self.auto_pair(c, range)
    }

    /// Typographic quotes in prose (never in code or math): opening after
    /// whitespace or an opening bracket, closing (or apostrophe) otherwise.
    fn smart_quote(&mut self, c: char, range: Range) -> bool {
        if self.is_code(range.location) {
            return false;
        }
        match self.context(range.location) {
            EditorContext::InlineCode | EditorContext::InlineMath | EditorContext::DisplayMath => return false,
            _ => {}
        }
        let previous = self.char_before(range.location);
        let opening = previous.is_none_or(|p| p.is_whitespace() || "([{<\u{2014}\u{2013}\u{2018}\u{201C}".contains(p));
        let quote = match (c, opening) {
            ('"', true) => '\u{201C}',
            ('"', false) => '\u{201D}',
            (_, true) => '\u{2018}',
            _ => '\u{2019}',
        };
        self.replace_characters(range, &quote.to_string(), None)
    }

    fn auto_pair(&mut self, typed: char, range: Range) -> bool {
        if self.is_code(range.location) {
            return false;
        }
        if range.length > 0 {
            if self.context(range.location) == EditorContext::InlineCode {
                return false;
            }
            let Some(closing) = wrapper_of(typed) else { return false };
            let selected = self.text.substring(range);
            return self.replace_characters(
                range,
                &format!("{typed}{selected}{closing}"),
                Some(Range::new(range.location + 1, range.length)),
            );
        }
        let next = self.char_at(range.location);
        let previous = self.char_before(range.location);
        if PAIRS.iter().any(|p| p.1 == typed) && next == Some(typed) {
            self.selection = Range::new(range.location + 1, 0);
            return true;
        }
        if self.context(range.location) == EditorContext::InlineCode {
            return false;
        }
        let Some(closing) = pair_of(typed) else { return false };
        if typed == '"' || typed == '`' {
            if previous.is_some_and(|p| p.is_alphanumeric() || p == '_') {
                return false;
            }
            if typed == '`' && previous == Some('`') {
                return false;
            }
        }
        if let Some(next) = next {
            if !(next.is_whitespace() || ")]}".contains(next)) {
                return false;
            }
        }
        self.replace_characters(range, &format!("{typed}{closing}"), Some(Range::new(range.location + 1, 0)))
    }

    /// Backspace between an empty pair `(|)` deletes both halves.
    pub fn delete_backward(&mut self) -> bool {
        if !self.settings.auto_pairs {
            return false;
        }
        let selection = self.selection;
        if selection.length != 0 || selection.location == 0 {
            return false;
        }
        let Some(previous) = self.char_before(selection.location) else { return false };
        let Some(closing) = pair_of(previous) else { return false };
        if self.char_at(selection.location) != Some(closing) || self.is_code(selection.location) {
            return false;
        }
        self.replace_characters(Range::new(selection.location - 1, 2), "", None)
    }
}

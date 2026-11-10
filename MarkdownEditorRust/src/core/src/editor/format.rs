//! Markdown formatting commands, shared by the Format menu and the
//! formatting toolbar.
//!
//! Inline wrappers (bold, italic, strikethrough, code, inline math) toggle:
//! they unwrap when the selection includes the markers or sits right between
//! them. Without a selection they insert an empty pair and put the caret
//! between. Block actions (headings, quote, lists, tasks) work on every line
//! touched by the selection; fences (code, display math, mermaid) wrap those
//! whole lines, or insert an empty block on an empty line.

use std::collections::{BTreeMap, BTreeSet};

use serde::Deserialize;

use super::prefix::{is_fence_line, LinePrefix, ListMarker};
use super::{u16len, Editor};
use crate::text::Range;

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(tag = "action", rename_all = "camelCase")]
pub enum FormatAction {
    Bold,
    Italic,
    Strikethrough,
    Highlight,
    SubscriptText,
    SuperscriptText,
    Footnote,
    InlineCode,
    Heading { level: usize },
    Paragraph,
    Link,
    Image,
    Quote,
    BulletList,
    NumberedList,
    TaskList,
    ToggleTask,
    CodeBlock { language: Option<String> },
    Table { rows: usize, columns: usize },
    HorizontalRule,
    InlineMath,
    DisplayMath,
    Mermaid,
    Indent,
    Outdent,
}

fn is_ws(c: char) -> bool {
    c == ' ' || c == '\t'
}

fn trim_ws(s: &str) -> &str {
    s.trim_matches(is_ws)
}

impl Editor<'_> {
    /// Runs `action`; `clipboard` is the clipboard's text (for links).
    pub fn perform(&mut self, action: &FormatAction, clipboard: Option<&str>) {
        match action {
            FormatAction::Bold => self.toggle_inline_wrap("**"),
            FormatAction::Italic => self.toggle_inline_wrap("*"),
            FormatAction::Strikethrough => self.toggle_inline_wrap("~~"),
            FormatAction::Highlight => self.toggle_tag_wrap("mark"),
            FormatAction::SubscriptText => self.toggle_tag_wrap("sub"),
            FormatAction::SuperscriptText => self.toggle_tag_wrap("sup"),
            FormatAction::Footnote => self.insert_footnote(),
            FormatAction::InlineMath => self.toggle_inline_wrap("$"),
            FormatAction::InlineCode => self.toggle_inline_code(),
            FormatAction::Heading { level } => self.set_heading((*level).clamp(1, 6)),
            FormatAction::Paragraph => self.set_heading(0),
            FormatAction::Link => self.insert_link(false, clipboard),
            FormatAction::Image => self.insert_link(true, clipboard),
            FormatAction::Quote => self.toggle_quote(),
            FormatAction::BulletList => self.toggle_bullets(),
            FormatAction::NumberedList => {
                let sel = self.selection;
                self.perform_list_edit(sel, false, false, |e| e.toggle_numbers());
            }
            FormatAction::TaskList => self.toggle_task_list(),
            FormatAction::ToggleTask => self.toggle_task_checkboxes(),
            FormatAction::CodeBlock { language } => self.toggle_code_fence(language.as_deref()),
            FormatAction::Table { rows, columns } => self.insert_table(*rows, *columns),
            FormatAction::HorizontalRule => self.insert_block("---", None),
            FormatAction::DisplayMath => self.toggle_display_math(),
            FormatAction::Mermaid => self.toggle_mermaid(),
            FormatAction::Indent => {
                let sel = self.selection;
                let unit = self.settings.indent_unit();
                self.perform_list_edit(sel, false, true, |e| e.indent_lines(&unit));
            }
            FormatAction::Outdent => {
                let sel = self.selection;
                let width = self.settings.tab_width;
                self.perform_list_edit(sel, false, true, |e| e.outdent_lines(width));
            }
        }
    }

    // MARK: Inline wrappers

    /// The selection without leading and trailing whitespace.
    fn trimmed_selection(&self) -> Range {
        let mut r = self.selection;
        let is_space = |i: usize| char::from_u32(self.text.u[i] as u32).is_some_and(char::is_whitespace);
        while r.length > 0 && is_space(r.location) {
            r.location += 1;
            r.length -= 1;
        }
        while r.length > 0 && is_space(r.end() - 1) {
            r.length -= 1;
        }
        if r.length == 0 {
            self.selection
        } else {
            r
        }
    }

    fn run_of(&self, unit: u16, location: usize, backwards: bool) -> usize {
        let mut count = 0;
        if backwards {
            let mut i = location;
            while i > 0 && self.text.u[i - 1] == unit {
                count += 1;
                i -= 1;
            }
        } else {
            let mut i = location;
            while i < self.text.len() && self.text.u[i] == unit {
                count += 1;
                i += 1;
            }
        }
        count
    }

    fn marker_applied(marker: &str, run: usize) -> bool {
        match marker {
            "*" => run % 2 == 1,
            "$" => run == 1,
            _ => run >= marker.len(),
        }
    }

    fn toggle_inline_wrap(&mut self, marker: &str) {
        let range = self.trimmed_selection();
        let selected = self.text.substring(range);
        let ml = marker.len();
        let unit = marker.as_bytes()[0] as u16;
        if range.length >= 2 * ml {
            let inner: Vec<u16> = selected.encode_utf16().collect();
            let lead = inner.iter().take_while(|&&u| u == unit).count();
            let mut trail = 0;
            while trail < inner.len() - lead && inner[inner.len() - 1 - trail] == unit {
                trail += 1;
            }
            if lead < inner.len() && Self::marker_applied(marker, lead.min(trail)) {
                let unwrapped = String::from_utf16_lossy(&inner[ml..inner.len() - ml]);
                let len = u16len(&unwrapped);
                self.replace_characters(range, &unwrapped, Some(Range::new(range.location, len)));
                return;
            }
        }
        let before = self.run_of(unit, range.location, true);
        let after = self.run_of(unit, range.end(), false);
        if Self::marker_applied(marker, before.min(after)) {
            self.replace_characters(
                Range::new(range.location - ml, range.length + 2 * ml),
                &selected,
                Some(Range::new(range.location - ml, range.length)),
            );
            return;
        }
        self.replace_characters(
            range,
            &format!("{marker}{selected}{marker}"),
            Some(Range::new(range.location + ml, range.length)),
        );
    }

    fn toggle_inline_code(&mut self) {
        let range = self.trimmed_selection();
        let selected = self.text.substring(range);
        let lead = selected.chars().take_while(|&c| c == '`').count();
        let trail = selected.chars().rev().take_while(|&c| c == '`').count();
        if lead > 0 && lead == trail && selected.chars().count() > 2 * lead {
            let mut inner = selected[lead..selected.len() - trail].to_string();
            if inner.chars().count() >= 2 && inner.starts_with(' ') && inner.ends_with(' ') {
                inner = inner[1..inner.len() - 1].to_string();
            }
            let len = u16len(&inner);
            self.replace_characters(range, &inner, Some(Range::new(range.location, len)));
            return;
        }
        let before = self.run_of(0x60, range.location, true);
        let after = self.run_of(0x60, range.end(), false);
        if before > 0 && before == after {
            self.replace_characters(
                Range::new(range.location - before, range.length + 2 * before),
                &selected,
                Some(Range::new(range.location - before, range.length)),
            );
            return;
        }
        let (mut longest, mut current) = (0, 0);
        for c in selected.chars() {
            current = if c == '`' { current + 1 } else { 0 };
            longest = longest.max(current);
        }
        let fence = "`".repeat(longest + 1);
        let pad = if selected.starts_with('`') || selected.ends_with('`') { " " } else { "" };
        let opening = format!("{fence}{pad}");
        self.replace_characters(
            range,
            &format!("{opening}{selected}{pad}{fence}"),
            Some(Range::new(range.location + u16len(&opening), range.length)),
        );
    }

    // MARK: Links

    fn clipboard_url(clipboard: Option<&str>) -> Option<String> {
        let raw = clipboard?.trim();
        if raw.is_empty() || raw.chars().any(char::is_whitespace) {
            return None;
        }
        let scheme = raw.split(':').next()?.to_lowercase();
        if raw.contains(':') && ["http", "https", "mailto", "ftp", "file"].contains(&scheme.as_str()) {
            Some(raw.to_string())
        } else {
            None
        }
    }

    fn insert_link(&mut self, is_image: bool, clipboard: Option<&str>) {
        let range = self.trimmed_selection();
        let mut label = self.text.substring(range);
        if label.is_empty() {
            label = if is_image { "alt text" } else { "link text" }.to_string();
        }
        let url = Self::clipboard_url(clipboard);
        let target = url.clone().unwrap_or_else(|| if is_image { "path" } else { "url" }.to_string());
        let bang = if is_image { "!" } else { "" };
        let replacement = format!("{bang}[{label}]({target})");
        let label_start = range.location + bang.len() + 1;
        let label_len = u16len(&label);
        let selection = if url.is_some() {
            Range::new(label_start, label_len)
        } else {
            Range::new(label_start + label_len + 2, u16len(&target))
        };
        self.replace_characters(range, &replacement, Some(selection));
    }

    // MARK: Line prefixes

    fn relevant_line_indexes(lines: &[String]) -> BTreeSet<usize> {
        let non_empty: BTreeSet<usize> = (0..lines.len()).filter(|&i| !trim_ws(&lines[i]).is_empty()).collect();
        if non_empty.is_empty() {
            (0..lines.len()).collect()
        } else {
            non_empty
        }
    }

    fn selected_lines(&self) -> Vec<String> {
        self.lines_in(self.line_block(self.selection)).0
    }

    fn set_heading(&mut self, level: usize) {
        let relevant = Self::relevant_line_indexes(&self.selected_lines());
        self.transform_selected_lines(|line, index| {
            if !relevant.contains(&index) {
                return line.to_string();
            }
            let hashes = line.chars().take_while(|&c| c == '#').count();
            let mut body = line;
            let mut existing = 0;
            if (1..=6).contains(&hashes) && line[hashes..].chars().next().is_none_or(is_ws) {
                existing = hashes;
                body = line[hashes..].trim_start_matches(is_ws);
            }
            if level == 0 || level == existing {
                return body.to_string();
            }
            format!("{} {}", "#".repeat(level), body)
        });
    }

    fn toggle_quote(&mut self) {
        let lines = self.selected_lines();
        let relevant = Self::relevant_line_indexes(&lines);
        let all_quoted = relevant.iter().all(|&i| LinePrefix::parse(&lines[i]).is_quote());
        self.transform_selected_lines(|line, index| {
            if all_quoted {
                if !relevant.contains(&index) {
                    return line.to_string();
                }
                let indent_len = line.len() - line.trim_start_matches(is_ws).len();
                let mut rest = line[indent_len..].get(1..).unwrap_or("");
                if rest.starts_with(' ') {
                    rest = &rest[1..];
                }
                return format!("{}{}", &line[..indent_len], rest);
            }
            if line.is_empty() {
                return if relevant.contains(&index) { "> ".into() } else { ">".into() };
            }
            format!("> {line}")
        });
    }

    fn toggle_list(&mut self, matches: impl Fn(&LinePrefix) -> bool, make_prefix: impl Fn(&LinePrefix, usize) -> String) {
        let lines = self.selected_lines();
        let relevant = Self::relevant_line_indexes(&lines);
        let all_match = relevant.iter().all(|&i| matches(&LinePrefix::parse(&lines[i])));
        let ordinals: BTreeMap<usize, usize> = relevant.iter().enumerate().map(|(o, &i)| (i, o + 1)).collect();
        self.transform_selected_lines(|line, index| {
            let Some(&ordinal) = ordinals.get(&index) else { return line.to_string() };
            let p = LinePrefix::parse(line);
            if all_match {
                return format!("{}{}{}", p.indent, p.quote, p.content);
            }
            format!("{}{}{}{}", p.indent, p.quote, make_prefix(&p, ordinal), p.content)
        });
    }

    fn toggle_bullets(&mut self) {
        self.toggle_list(|p| matches!(p.marker, Some(ListMarker::Bullet(_))) && !p.is_task(), |_, _| "- ".into());
    }

    fn toggle_numbers(&mut self) {
        self.toggle_list(
            |p| matches!(p.marker, Some(ListMarker::Ordered { .. })) && !p.is_task(),
            |_, ordinal| format!("{ordinal}. "),
        );
    }

    fn toggle_task_list(&mut self) {
        self.toggle_list(
            |p| p.is_task(),
            |p, _| {
                let bx = p.task.map(|t| format!("[{t}] ")).unwrap_or_else(|| "[ ] ".into());
                if let Some(ListMarker::Bullet(c)) = p.marker {
                    return format!("{c} {bx}");
                }
                format!("- {bx}")
            },
        );
    }

    fn toggle_task_checkboxes(&mut self) {
        let lines = self.selected_lines();
        let relevant = Self::relevant_line_indexes(&lines);
        let tasks: Vec<LinePrefix> =
            relevant.iter().map(|&i| LinePrefix::parse(&lines[i])).filter(|p| p.is_task()).collect();
        let all_checked = !tasks.is_empty() && tasks.iter().all(|p| p.task != Some(' '));
        self.transform_selected_lines(|line, index| {
            if !relevant.contains(&index) {
                return line.to_string();
            }
            let mut p = LinePrefix::parse(line);
            if p.is_task() {
                p.task = Some(if all_checked { ' ' } else { 'x' });
            } else if p.is_list_item() {
                p.task = Some(' ');
                p.task_spacing = " ".into();
            } else {
                return format!("{}{}- [ ] {}", p.indent, p.quote, p.content);
            }
            format!("{}{}", p.prefix(), p.content)
        });
    }

    // MARK: Blocks

    fn toggle_fence(
        &mut self,
        open: &str,
        close: &str,
        is_opening: impl Fn(&str) -> bool,
        empty_body: &str,
        caret: Option<Box<dyn Fn(&str) -> Range>>,
    ) {
        let mut block = self.line_block(self.selection);
        let (mut block_lines, mut has_terminator) = self.lines_in(block);
        if block_lines.len() == 1 && is_opening(&block_lines[0]) {
            let mut next = block.end();
            while next < self.text.len() {
                let line = self.text.line_range(next);
                let is_close = trim_ws(&self.lines_in(line).0[0]) == close;
                next = line.end();
                if is_close {
                    block = Range::new(block.location, line.end() - block.location);
                    (block_lines, has_terminator) = self.lines_in(block);
                    break;
                }
                if line.length == 0 {
                    break;
                }
            }
        }
        let terminator = if has_terminator { "\n" } else { "" };
        if block_lines.len() >= 2 && is_opening(&block_lines[0]) && trim_ws(&block_lines[block_lines.len() - 1]) == close {
            let inner = block_lines[1..block_lines.len() - 1].join("\n");
            let len = u16len(&inner);
            self.replace_characters(block, &format!("{inner}{terminator}"), Some(Range::new(block.location, len)));
            return;
        }
        let is_empty = block_lines.iter().all(|l| trim_ws(l).is_empty());
        let body = if is_empty { empty_body.to_string() } else { block_lines.join("\n") };
        let replacement = format!("{open}\n{body}\n{close}{terminator}");
        let body_range = Range::new(block.location + u16len(open) + 1, u16len(&body));
        let selection = match caret {
            Some(f) => {
                let r = f(&body);
                Range::new(block.location + r.location, r.length)
            }
            None => body_range,
        };
        self.replace_characters(block, &replacement, Some(selection));
    }

    fn toggle_code_fence(&mut self, language: Option<&str>) {
        let language = language.unwrap_or("").to_string();
        let len = u16len(&language);
        self.toggle_fence(
            &format!("```{language}"),
            "```",
            is_fence_line,
            "",
            Some(Box::new(move |_| Range::new(3, len))),
        );
    }

    fn toggle_display_math(&mut self) {
        self.toggle_fence("$$", "$$", |l| trim_ws(l).starts_with("$$"), "", None);
    }

    fn toggle_mermaid(&mut self) {
        let open = "```mermaid";
        let stub = "flowchart TD\n    ";
        let selection_is_empty = self.selected_lines().iter().all(|l| trim_ws(l).is_empty());
        let caret: Option<Box<dyn Fn(&str) -> Range>> = if selection_is_empty {
            let at = u16len(open) + 1 + u16len(stub);
            Some(Box::new(move |_| Range::new(at, 0)))
        } else {
            None
        };
        self.toggle_fence(open, "```", is_fence_line, stub, caret);
    }

    /// Inserts a block on its own line: replaces the current line when it is
    /// blank, otherwise goes below it after an empty line.
    pub fn insert_block(&mut self, block: &str, selecting: Option<Range>) {
        let caret = self.selection;
        let line = self.line_block(Range::new(caret.end(), 0));
        let content = self.lines_in(line).0[0].clone();
        let content_range = Range::new(line.location, u16len(&content));
        let block_len = u16len(block);
        let (range, replacement, block_start) = if trim_ws(&content).is_empty() {
            (content_range, block.to_string(), content_range.location)
        } else {
            (Range::new(content_range.end(), 0), format!("\n\n{block}"), content_range.end() + 2)
        };
        let selection = selecting
            .map(|s| Range::new(block_start + s.location, s.length))
            .unwrap_or(Range::new(block_start + block_len, 0));
        self.replace_characters(range, &replacement, Some(selection));
    }

    fn insert_table(&mut self, rows: usize, columns: usize) {
        let columns = columns.max(1);
        let rows = rows.max(1);
        let headers: Vec<String> = (1..=columns).map(|i| format!("Column {i}")).collect();
        let widths: Vec<usize> = headers.iter().map(|h| h.chars().count()).collect();
        let header = format!("| {} |", headers.join(" | "));
        let separator = format!("| {} |", widths.iter().map(|&w| "-".repeat(w)).collect::<Vec<_>>().join(" | "));
        let empty = format!("| {} |", widths.iter().map(|&w| " ".repeat(w)).collect::<Vec<_>>().join(" | "));
        let mut all = vec![header, separator];
        all.extend(std::iter::repeat_n(empty, rows));
        let len = u16len(&headers[0]);
        self.insert_block(&all.join("\n"), Some(Range::new(2, len)));
    }
}

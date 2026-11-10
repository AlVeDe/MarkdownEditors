//! Aligns GFM tables and navigates them like a spreadsheet.
//!
//! - Tab / Shift-Tab: re-align the whole table, then select the next /
//!   previous cell. Tab in the last cell appends an empty row.
//! - Return at the end of the last row: append an empty row. Return on an
//!   empty last row: remove it and leave the table.

use super::table::{cell_at, is_delimiter_row, looks_like_row, MarkdownTable};
use super::{u16len, Editor};
use crate::highlight::EditorContext;
use crate::text::Range;

pub struct Located {
    pub range: Range,
    pub table: MarkdownTable,
    pub lines: Vec<String>,
    pub line_ending: String,
    pub row: usize,
    pub column: usize,
    pub offset_in_content: usize,
}

impl Editor<'_> {
    fn contents_range(&self, line_range: Range) -> Range {
        let (s, c, _) = self.text.line_bounds(line_range.location);
        Range::new(s, c - s)
    }

    fn is_row_line(&self, range: Range) -> bool {
        let text = self.text.substring(self.contents_range(range));
        !text.chars().all(char::is_whitespace) && looks_like_row(&text)
    }

    /// Finds the GFM table containing `location`, if any.
    pub fn locate_table(&self, location: usize) -> Option<Located> {
        let len = self.text.len();
        if len == 0 || location > len {
            return None;
        }
        if let EditorContext::CodeBlock(_) = self.context(location) {
            return None;
        }
        let caret_line = self.text.line_range(location.min(len));
        if !self.is_row_line(caret_line) {
            return None;
        }
        let mut line_ranges = vec![caret_line];
        let mut caret_index = 0;
        while line_ranges[0].location > 0 {
            let previous = self.text.line_range(line_ranges[0].location - 1);
            if !self.is_row_line(previous) {
                break;
            }
            line_ranges.insert(0, previous);
            caret_index += 1;
        }
        while line_ranges[line_ranges.len() - 1].end() < len {
            let next = self.text.line_range(line_ranges[line_ranges.len() - 1].end());
            if !self.is_row_line(next) {
                break;
            }
            line_ranges.push(next);
        }
        let lines: Vec<String> = line_ranges.iter().map(|&r| self.text.substring(self.contents_range(r))).collect();
        let mut delimiter_index = None;
        for index in 1..lines.len().max(1) {
            if index - 1 <= caret_index && is_delimiter_row(&lines[index]) {
                delimiter_index = Some(index);
            }
        }
        let first = delimiter_index? - 1;
        let table_lines: Vec<String> = lines[first..].to_vec();
        let table = MarkdownTable::parse(&table_lines)?;
        let start = line_ranges[first].location;
        if self.is_inside_fence(start) {
            return None;
        }
        let end = self.contents_range(line_ranges[line_ranges.len() - 1]).end();
        let first_range = line_ranges[first];
        let first_contents = self.contents_range(first_range);
        let terminator = self.text.substring(Range::new(first_contents.end(), first_range.end() - first_contents.end()));
        let row = caret_index - first;
        let (column, offset_in_content) = cell_at(location - line_ranges[caret_index].location, &lines[caret_index]);
        Some(Located {
            range: Range::new(start, end - start),
            column: column.min(table.column_count().max(1) - 1),
            table,
            lines: table_lines,
            line_ending: if terminator.is_empty() { "\n".into() } else { terminator },
            row,
            offset_in_content,
        })
    }

    fn is_inside_fence(&self, location: usize) -> bool {
        let mut open: Option<(char, usize)> = None;
        let mut index = 0;
        while index < location {
            let line_range = self.text.line_range(index);
            if line_range.end() == index {
                break;
            }
            index = line_range.end();
            let line = self.text.substring(line_range);
            let indent = line.chars().take_while(|&c| c == ' ').count();
            if indent >= 4 {
                continue;
            }
            let body = &line[indent..];
            let Some(first) = body.chars().next().filter(|&c| c == '`' || c == '~') else { continue };
            let count = body.chars().take_while(|&c| c == first).count();
            if count < 3 {
                continue;
            }
            if let Some(fence) = open {
                if fence.0 == first && count >= fence.1 && body[count..].chars().all(char::is_whitespace) {
                    open = None;
                }
            } else {
                open = Some((first, count));
            }
        }
        open.is_some()
    }

    /// Re-aligns the table at `location` keeping the caret in its cell.
    pub fn format_table(&mut self, location: usize) -> bool {
        let Some(located) = self.locate_table(location) else { return false };
        let (text, cells) = located.table.formatted(&located.line_ending);
        let cell = cells[located.row][located.column];
        let caret = located.range.location + cell.location + located.offset_in_content.min(cell.length);
        self.apply_table(&text, &located, Range::new(caret, 0));
        true
    }

    /// Tab / Shift-Tab inside a table.
    pub fn table_move_to_cell(&mut self, forward: bool) -> bool {
        let Some(located) = self.locate_table(self.selection.location) else { return false };
        let mut table = located.table.clone();
        let columns = table.column_count().max(1);
        let mut row = if located.row == 1 { 0 } else { located.row };
        let mut column = located.column;
        if forward {
            if column + 1 < columns {
                column += 1;
            } else {
                row = if row == 0 { 2 } else { row + 1 };
                column = 0;
                if row >= table.line_count() {
                    table.rows.push(vec![String::new(); columns]);
                }
            }
        } else if column > 0 {
            column -= 1;
        } else if row > 0 {
            row = if row == 2 { 0 } else { row - 1 };
            column = columns - 1;
        }
        let (text, cells) = table.formatted(&located.line_ending);
        let cell = cells[row][column];
        self.apply_table(&text, &located, Range::new(located.range.location + cell.location, cell.length));
        true
    }

    /// Return inside a table.
    pub fn table_insert_newline(&mut self) -> bool {
        let selection = self.selection;
        if selection.length != 0 {
            return false;
        }
        let Some(located) = self.locate_table(selection.location) else { return false };
        let is_last_row = located.row == located.table.line_count() - 1;
        if located.row < 2 || !is_last_row {
            return false;
        }
        let line = located.lines[located.row].clone();
        let cells = located.table.rows[located.row - 2].clone();
        let mut table = located.table.clone();
        if cells.iter().all(String::is_empty) {
            table.rows.pop();
            let (text, _) = table.formatted(&located.line_ending);
            let replacement = format!("{text}{}", located.line_ending);
            let caret = located.range.location + u16len(&replacement);
            self.apply_table(&replacement, &located, Range::new(caret, 0));
            return true;
        }
        let line_start = self.text.line_range(selection.location).location;
        let trimmed_len = u16len(line.trim_end());
        if selection.location - line_start < trimmed_len {
            return false;
        }
        table.rows.push(vec![String::new(); table.column_count().max(1)]);
        let (text, ranges) = table.formatted(&located.line_ending);
        let cell = ranges[table.line_count() - 1][0];
        self.apply_table(&text, &located, Range::new(located.range.location + cell.location, 0));
        true
    }

    fn apply_table(&mut self, text: &str, located: &Located, selection: Range) {
        if self.text.substring(located.range) == text {
            self.selection = selection;
        } else {
            self.replace_characters(located.range, text, Some(selection));
        }
    }
}

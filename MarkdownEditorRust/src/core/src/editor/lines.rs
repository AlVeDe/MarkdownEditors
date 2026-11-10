//! Line-oriented editing: the building block for indentation, list and
//! heading toggles, and the Lines menu (move, duplicate, delete, join,
//! comment, select). Move, duplicate and delete renumber an ordered list they
//! touch within the same command.

use super::{u16len, Editor};
use crate::text::Range;

fn union(a: Range, b: Range) -> Range {
    let start = a.location.min(b.location);
    let end = a.end().max(b.end());
    Range::new(start, end - start)
}

impl Editor<'_> {
    /// The full lines (including terminators) touched by `range`. A
    /// multi-line selection ending at the very start of a line does not
    /// include that line.
    pub fn line_block(&self, range: Range) -> Range {
        let text = &self.text;
        let mut end = range.end();
        if range.length > 0 && end > range.location && end <= text.len() && text.at(end - 1) == 0x0A {
            end -= 1;
        }
        let first = text.line_range(range.location);
        let last = text.line_range(range.location.max(end));
        union(first, last)
    }

    /// A line block split into lines without terminators, and whether the
    /// block ended with a newline.
    pub fn lines_in(&self, block: Range) -> (Vec<String>, bool) {
        let mut content = self.text.substring(block);
        let has_terminator = content.ends_with('\n');
        if has_terminator {
            content.pop();
        }
        (content.split('\n').map(str::to_string).collect(), has_terminator)
    }

    /// Rewrites each line of the selection's line block with `transform`.
    /// The selection is mapped line by line: a position keeps its column
    /// shifted by the line's change in length, clamped to the line.
    pub fn transform_selected_lines(&mut self, mut transform: impl FnMut(&str, usize) -> String) -> bool {
        let selection = self.selection;
        let block = self.line_block(selection);
        let (old, has_terminator) = self.lines_in(block);
        let new: Vec<String> = old.iter().enumerate().map(|(i, l)| transform(l, i)).collect();
        if new == old {
            return false;
        }
        let starts = |lines: &[String]| {
            let mut result = vec![];
            let mut offset = 0;
            for l in lines {
                result.push(offset);
                offset += u16len(l) + 1;
            }
            result
        };
        let old_starts = starts(&old);
        let new_starts = starts(&new);
        let map = |location: usize, keeps_line_start: bool| {
            let offset = location - block.location;
            let index = old_starts.iter().rposition(|&s| s <= offset).unwrap_or(0);
            let column = offset - old_starts[index];
            let delta = u16len(&new[index]) as isize - u16len(&old[index]) as isize;
            let new_column = if keeps_line_start && column == 0 {
                0
            } else {
                ((column as isize + delta).max(0) as usize).min(u16len(&new[index]))
            };
            block.location + new_starts[index] + new_column
        };
        let start = map(selection.location, selection.length > 0);
        let end = if selection.length == 0 { start } else { map(selection.end(), false) };
        let replacement = new.join("\n") + if has_terminator { "\n" } else { "" };
        self.replace_characters(block, &replacement, Some(Range::new(start, end.saturating_sub(start))))
    }

    /// Indents every line of the selection by `unit`. Empty lines stay empty
    /// in a multi-line selection.
    pub fn indent_lines(&mut self, unit: &str) {
        let multi = self.lines_in(self.line_block(self.selection)).0.len() > 1;
        self.transform_selected_lines(|line, _| if multi && line.is_empty() { line.to_string() } else { format!("{unit}{line}") });
    }

    pub fn outdent_lines(&mut self, width: usize) {
        self.transform_selected_lines(|line, _| removing_indent_step(line, width));
    }

    pub fn move_lines_up(&mut self) {
        let selection = self.selection;
        let block = self.line_block(selection);
        if block.location == 0 {
            self.beep = true;
            return;
        }
        let previous = self.text.line_range(block.location - 1);
        let combined = union(previous, block);
        let (block_lines, has_terminator) = self.lines_in(block);
        let previous_line = self.lines_in(previous).0[0].clone();
        let replacement = format!("{}\n{}{}", block_lines.join("\n"), previous_line, if has_terminator { "\n" } else { "" });
        let offset = selection.location - block.location;
        self.perform_list_edit(combined, true, false, |e| {
            e.replace_characters(combined, &replacement, Some(Range::new(combined.location + offset, selection.length)))
        });
    }

    pub fn move_lines_down(&mut self) {
        let selection = self.selection;
        let block = self.line_block(selection);
        if block.end() >= self.text.len() {
            self.beep = true;
            return;
        }
        let next = self.text.line_range(block.end());
        let combined = union(block, next);
        let block_lines = self.lines_in(block).0;
        let (next_lines, has_terminator) = self.lines_in(next);
        let next_line = next_lines[0].clone();
        let replacement = format!("{}\n{}{}", next_line, block_lines.join("\n"), if has_terminator { "\n" } else { "" });
        let offset = selection.location - block.location;
        let shift = u16len(&next_line) + 1;
        self.perform_list_edit(combined, true, false, |e| {
            e.replace_characters(combined, &replacement, Some(Range::new(combined.location + shift + offset, selection.length)))
        });
    }

    pub fn duplicate_lines(&mut self) {
        let selection = self.selection;
        let block = self.line_block(selection);
        let (block_lines, has_terminator) = self.lines_in(block);
        let content = block_lines.join("\n");
        let shift = u16len(&content) + 1;
        let insertion = if has_terminator { format!("{content}\n") } else { format!("\n{content}") };
        self.perform_list_edit(block, true, false, |e| {
            e.replace_characters(
                Range::new(block.end(), 0),
                &insertion,
                Some(Range::new(selection.location + shift, selection.length)),
            )
        });
    }

    pub fn delete_lines(&mut self) {
        let mut block = self.line_block(self.selection);
        let mut caret = block.location;
        if !self.lines_in(block).1 && block.location > 0 {
            block.location -= 1;
            block.length += 1;
            caret = self.text.line_range(block.location).location;
        }
        if block.length == 0 {
            return;
        }
        self.perform_list_edit(block, true, false, |e| e.replace_characters(block, "", Some(Range::new(caret, 0))));
    }

    /// Joins the selected lines (or the current line and the next) with
    /// single spaces, dropping the joined lines' indentation.
    pub fn join_lines(&mut self) {
        let selection = self.selection;
        let mut block = self.line_block(selection);
        let mut lines = self.lines_in(block);
        if lines.0.len() == 1 {
            if block.end() >= self.text.len() {
                self.beep = true;
                return;
            }
            block = union(block, self.text.line_range(block.end()));
            lines = self.lines_in(block);
        }
        let mut joined = lines.0[0].trim_end().to_string();
        let mut caret = u16len(&joined);
        for line in lines.0.iter().skip(1) {
            let trimmed = line.trim_matches(|c| c == ' ' || c == '\t');
            if trimmed.is_empty() {
                continue;
            }
            caret = u16len(&joined);
            if !joined.is_empty() {
                joined.push(' ');
            }
            joined.push_str(trimmed);
        }
        let replacement = joined + if lines.1 { "\n" } else { "" };
        self.replace_characters(block, &replacement, Some(Range::new(block.location + caret, 0)));
    }

    /// Wraps the selected lines in `<!-- … -->`, or unwraps them.
    pub fn toggle_line_comment(&mut self) {
        let block = self.line_block(self.selection);
        let block_lines = self.lines_in(block).0;
        let first = block_lines[0].clone();
        let last = block_lines[block_lines.len() - 1].clone();
        let indent: String = first.chars().take_while(|&c| c == ' ' || c == '\t').collect();
        let first_body = &first[indent.len()..];
        let is_commented = first_body.starts_with("<!--") && last.trim_matches(|c| c == ' ' || c == '\t').ends_with("-->");
        let count = block_lines.len();
        self.transform_selected_lines(|line, index| {
            let mut line = line.to_string();
            let (is_first, is_last) = (index == 0, index == count - 1);
            if is_commented {
                if is_first {
                    let mut body = &line[indent.len()..];
                    body = body.get(4..).unwrap_or("");
                    if body.starts_with(' ') {
                        body = &body[1..];
                    }
                    line = format!("{indent}{body}");
                }
                if is_last {
                    if let Some(pos) = line.rfind("-->") {
                        let mut head = &line[..pos];
                        if head.ends_with(' ') {
                            head = &head[..head.len() - 1];
                        }
                        line = format!("{head}{}", &line[pos + 3..]);
                    }
                }
            } else {
                if is_first {
                    line = format!("{indent}<!-- {}", &line[indent.len()..]);
                }
                if is_last {
                    line.push_str(" -->");
                }
            }
            line
        });
    }

    /// Selects the whole current line(s); when whole lines are already
    /// selected, extends by the next line.
    pub fn select_lines(&mut self) {
        let selection = self.selection;
        let mut block = self.line_block(selection);
        if block == selection && block.end() < self.text.len() {
            block = union(block, self.text.line_range(block.end()));
        }
        self.selection = block;
    }
}

pub fn removing_indent_step(line: &str, width: usize) -> String {
    if let Some(rest) = line.strip_prefix('\t') {
        return rest.to_string();
    }
    let spaces = line.chars().take_while(|&c| c == ' ').count();
    line[spaces.min(width.max(1))..].to_string()
}

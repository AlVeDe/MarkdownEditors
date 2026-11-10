//! The structural prefix of one Markdown source line: indentation,
//! blockquote markers, a list marker and a task checkbox — everything Return
//! continues and the list commands toggle.

use crate::text::Text;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ListMarker {
    /// `-`, `*` or `+`.
    Bullet(char),
    /// `1.` or `1)`.
    Ordered { number: usize, delimiter: char },
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct LinePrefix {
    pub indent: String,
    /// Blockquote markers including their spaces, e.g. `"> > "`.
    pub quote: String,
    pub marker: Option<ListMarker>,
    pub marker_spacing: String,
    /// The checkbox state character (`' '`, `'x'` or `'X'`).
    pub task: Option<char>,
    pub task_spacing: String,
    /// The text after the whole prefix.
    pub content: String,
}

fn is_ws(c: char) -> bool {
    c == ' ' || c == '\t'
}

impl LinePrefix {
    pub fn parse(line: &str) -> Self {
        let mut p = LinePrefix::default();
        let mut rest = line;
        let indent_end = rest.find(|c: char| !is_ws(c)).unwrap_or(rest.len());
        p.indent = rest[..indent_end].to_string();
        rest = &rest[indent_end..];

        while rest.starts_with('>') {
            let mut piece = String::from(">");
            rest = &rest[1..];
            if let Some(c) = rest.chars().next().filter(|&c| is_ws(c)) {
                piece.push(c);
                rest = &rest[1..];
            }
            p.quote.push_str(&piece);
        }

        let mut after_marker = rest;
        let mut parsed = None;
        if let Some(first) = rest.chars().next().filter(|c| "-*+".contains(*c)) {
            after_marker = &rest[1..];
            parsed = Some(ListMarker::Bullet(first));
        } else {
            let digits = rest.chars().take_while(|c| c.is_ascii_digit()).count();
            if (1..=9).contains(&digits) {
                if let Some(delimiter) = rest[digits..].chars().next().filter(|&c| c == '.' || c == ')') {
                    if let Ok(number) = rest[..digits].parse() {
                        after_marker = &rest[digits + 1..];
                        parsed = Some(ListMarker::Ordered { number, delimiter });
                    }
                }
            }
        }
        if let Some(marker) = parsed {
            if after_marker.chars().next().is_some_and(is_ws) {
                p.marker = Some(marker);
                let spacing_end = after_marker.find(|c: char| !is_ws(c)).unwrap_or(after_marker.len());
                p.marker_spacing = after_marker[..spacing_end].to_string();
                rest = &after_marker[spacing_end..];
                let chars: Vec<char> = rest.chars().take(4).collect();
                if chars.len() >= 3
                    && chars[0] == '['
                    && chars[2] == ']'
                    && " xX".contains(chars[1])
                    && (chars.len() == 3 || is_ws(chars[3]))
                {
                    p.task = Some(chars[1]);
                    rest = &rest[3..];
                    let end = rest.find(|c: char| !is_ws(c)).unwrap_or(rest.len());
                    p.task_spacing = rest[..end].to_string();
                    rest = &rest[end..];
                }
            }
        }
        p.content = rest.to_string();
        p
    }

    pub fn is_list_item(&self) -> bool {
        self.marker.is_some()
    }
    pub fn is_task(&self) -> bool {
        self.task.is_some()
    }
    pub fn is_quote(&self) -> bool {
        !self.quote.is_empty()
    }

    pub fn marker_text(&self) -> String {
        match self.marker {
            Some(ListMarker::Bullet(c)) => c.to_string(),
            Some(ListMarker::Ordered { number, delimiter }) => format!("{number}{delimiter}"),
            None => String::new(),
        }
    }

    pub fn task_text(&self) -> String {
        self.task.map(|t| format!("[{t}]")).unwrap_or_default()
    }

    /// Everything before `content`.
    pub fn prefix(&self) -> String {
        format!(
            "{}{}{}{}{}{}",
            self.indent,
            self.quote,
            self.marker_text(),
            self.marker_spacing,
            self.task_text(),
            self.task_spacing
        )
    }

    pub fn prefix_length(&self) -> usize {
        self.prefix().encode_utf16().count()
    }

    /// The prefix the next line gets when Return continues this one.
    pub fn continuation(&self) -> String {
        let mut next = format!("{}{}", self.indent, self.quote);
        match self.marker {
            Some(ListMarker::Bullet(c)) => next.push(c),
            Some(ListMarker::Ordered { number, delimiter }) => next.push_str(&format!("{}{delimiter}", number + 1)),
            None => return next,
        }
        next.push_str(if self.marker_spacing.is_empty() { " " } else { &self.marker_spacing });
        if self.task.is_some() {
            next.push_str("[ ]");
            next.push_str(if self.task_spacing.is_empty() { " " } else { &self.task_spacing });
        }
        next
    }
}

/// True when the line opens or closes a fenced code block.
pub fn is_fence_line(line: &str) -> bool {
    let trimmed = line.trim_start_matches(' ');
    trimmed.starts_with("```") || trimmed.starts_with("~~~")
}

/// True when `location` is inside a fenced code block or on a fence line
/// (a linear fallback that does not need the highlighter).
pub fn is_in_fenced_code(text: &Text, location: usize) -> bool {
    let location = location.min(text.len());
    let current = text.line_range(location);
    let mut inside = false;
    let mut index = 0;
    while index < current.location {
        let line = text.line_range(index);
        if is_fence_line(&text.substring(line)) {
            inside = !inside;
        }
        if line.end() == index {
            break;
        }
        index = line.end();
    }
    inside || is_fence_line(&text.substring(current))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_task_item() {
        let p = LinePrefix::parse("  > 3. [x] done");
        assert_eq!(p.indent, "  ");
        assert_eq!(p.quote, "> ");
        assert_eq!(p.marker, Some(ListMarker::Ordered { number: 3, delimiter: '.' }));
        assert_eq!(p.task, Some('x'));
        assert_eq!(p.content, "done");
        assert_eq!(p.continuation(), "  > 4. [ ] ");
    }

    #[test]
    fn bold_is_not_a_list() {
        assert!(!LinePrefix::parse("**bold**").is_list_item());
        assert!(!LinePrefix::parse("1.5").is_list_item());
    }
}

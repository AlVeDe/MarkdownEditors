//! Normalizes LaTeX display math (`$$ … $$`) into ` ```math ` fenced code
//! blocks *before* the document is parsed.
//!
//! A CommonMark/GFM parser knows nothing about LaTeX — a `$$ … $$` block would
//! otherwise arrive as an ordinary paragraph full of literal dollar signs.
//! Rewriting it into a fence with the `math` language means every renderer
//! sees a plain code block and treats formulas exactly the way it treats
//! ` ```mermaid ` fences.
//!
//! An unterminated `$$` is left untouched, so a stray dollar pair never eats
//! the rest of the document.

use super::footnotes;

/// The fence language formulas are normalized to.
pub const LANGUAGE: &str = "math";
const DELIMITER: &str = "$$";

/// Maps 1-based line numbers of the text the parser saw back to the 1-based
/// line numbers of the text the author typed.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct LineMap {
    /// `origins[i]` is the original line of parsed line `i + 1`; empty for
    /// the identity map.
    pub origins: Vec<usize>,
}

impl LineMap {
    pub fn identity() -> Self {
        LineMap { origins: Vec::new() }
    }

    /// The original line of a parsed `line`. Lines past the end continue
    /// linearly.
    pub fn original_line(&self, line: usize) -> usize {
        if self.origins.is_empty() || line < 1 {
            return line;
        }
        if line <= self.origins.len() {
            return self.origins[line - 1];
        }
        self.origins[self.origins.len() - 1] + (line - self.origins.len())
    }
}

pub(crate) fn trim_ws(s: &str) -> &str {
    s.trim_matches(|c: char| c == ' ' || c == '\t')
}

fn leading_spaces(line: &str) -> usize {
    line.chars().take_while(|&c| c == ' ').count()
}

pub fn preprocess(markdown: &str) -> String {
    preprocess_mapped(markdown).0
}

/// The rewrite plus its line map.
pub fn preprocess_mapped(markdown: &str) -> (String, LineMap) {
    // Footnotes first: they only blank lines and append after the end, so
    // the math line map still points at the editor's lines.
    let markdown = footnotes::rewrite(&blanking_front_matter(markdown));
    if !markdown.contains(DELIMITER) {
        return (markdown, LineMap::identity());
    }

    let lines: Vec<&str> = markdown.split('\n').collect();
    let mut output: Vec<String> = Vec::with_capacity(lines.len());
    let mut origins: Vec<usize> = Vec::with_capacity(lines.len());
    let mut open_fence: Option<(char, usize)> = None;
    let mut index = 0;

    while index < lines.len() {
        let line = lines[index];
        if let Some(fence) = open_fence {
            output.push(line.to_string());
            origins.push(index);
            if closes_fence(line, fence) {
                open_fence = None;
            }
            index += 1;
            continue;
        }
        if let Some(fence) = opens_fence(line) {
            output.push(line.to_string());
            origins.push(index);
            open_fence = Some(fence);
            index += 1;
            continue;
        }
        if let Some((body, next)) = math_block(&lines, index) {
            let fence = fence_for(body.iter().map(|b| b.0.as_str()));
            output.push(format!("{fence}{LANGUAGE}"));
            origins.push(index);
            for (text, origin) in body {
                output.push(text);
                origins.push(origin);
            }
            output.push(fence);
            origins.push(next - 1);
            index = next;
            continue;
        }
        output.push(line.to_string());
        origins.push(index);
        index += 1;
    }

    (output.join("\n"), LineMap { origins: origins.into_iter().map(|o| o + 1).collect() })
}

/// YAML front matter (`---` on the very first line … `---` or `...`) is
/// metadata, not content. Each of its lines is replaced by an empty line, so
/// every line number after it stays the same.
pub fn blanking_front_matter(markdown: &str) -> String {
    if !markdown.starts_with("---") {
        return markdown.to_string();
    }
    let mut lines: Vec<&str> = markdown.split('\n').collect();
    if trim_ws(lines[0]) != "---" {
        return markdown.to_string();
    }
    let Some(end) = (1..lines.len()).find(|&i| {
        let l = trim_ws(lines[i]);
        l == "---" || l == "..."
    }) else {
        return markdown.to_string();
    };
    for line in lines.iter_mut().take(end + 1) {
        *line = "";
    }
    lines.join("\n")
}

/// Matches a display-math block starting on `lines[start]`, returning its TeX
/// body (with origin line indices) and the index after the closing delimiter.
fn math_block(lines: &[&str], start: usize) -> Option<(Vec<(String, usize)>, usize)> {
    let first = lines[start];
    if leading_spaces(first) >= 4 {
        return None;
    }
    let opener = trim_ws(first);
    if !opener.starts_with(DELIMITER) {
        return None;
    }
    let after_opener = &opener[DELIMITER.len()..];
    if after_opener.ends_with(DELIMITER) && after_opener.chars().count() > DELIMITER.len() {
        let body = trim_ws(&after_opener[..after_opener.len() - DELIMITER.len()]);
        let body = if body.is_empty() { vec![] } else { vec![(body.to_string(), start)] };
        return Some((body, start + 1));
    }
    let mut body = Vec::new();
    let inline_start = trim_ws(after_opener);
    if !inline_start.is_empty() {
        body.push((inline_start.to_string(), start));
    }
    let mut index = start + 1;
    while index < lines.len() {
        let trimmed = trim_ws(lines[index]);
        if trimmed == DELIMITER {
            return Some((body, index + 1));
        }
        if let Some(tail) = trimmed.strip_suffix(DELIMITER) {
            let tail = trim_ws(tail);
            if !tail.is_empty() {
                body.push((tail.to_string(), index));
            }
            return Some((body, index + 1));
        }
        body.push((lines[index].to_string(), index));
        index += 1;
    }
    None
}

/// A backtick fence long enough to survive any backtick run in the formula.
fn fence_for<'a>(body: impl Iterator<Item = &'a str>) -> String {
    let mut longest = 0;
    for line in body {
        let mut run = 0;
        for c in line.chars() {
            run = if c == '`' { run + 1 } else { 0 };
            longest = longest.max(run);
        }
    }
    "`".repeat(3.max(longest + 1))
}

fn opens_fence(line: &str) -> Option<(char, usize)> {
    if leading_spaces(line) >= 4 {
        return None;
    }
    let trimmed = trim_ws(line);
    for ch in ['`', '~'] {
        let run = trimmed.chars().take_while(|&c| c == ch).count();
        if run >= 3 {
            return Some((ch, run));
        }
    }
    None
}

fn closes_fence(line: &str, fence: (char, usize)) -> bool {
    if leading_spaces(line) >= 4 {
        return false;
    }
    let trimmed = trim_ws(line);
    let run = trimmed.chars().take_while(|&c| c == fence.0).count();
    run >= fence.1 && run == trimmed.chars().count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rewrites_block() {
        let (text, map) = preprocess_mapped("a\n$$ x $$\nb");
        assert_eq!(text, "a\n```math\nx\n```\nb");
        assert_eq!(map.original_line(5), 3);
    }

    #[test]
    fn leaves_unterminated() {
        assert_eq!(preprocess("$$\nx"), "$$\nx");
    }

    #[test]
    fn skips_fences() {
        let src = "```\n$$ x $$\n```";
        assert_eq!(preprocess(src), src);
    }
}

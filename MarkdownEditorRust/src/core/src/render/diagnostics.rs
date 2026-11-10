//! Turns the errors the preview page reports (by source line) into editor
//! diagnostics (by UTF-16 range), against the exact markdown that was
//! rendered.

use serde::{Deserialize, Serialize};

use crate::text::{utf16, LineIndex, Range, Text};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Diagnostic {
    pub range: Range,
    pub message: String,
}

/// A mermaid diagram that failed to parse.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct DiagramError {
    pub line: usize,
    pub end_line: usize,
    pub message: String,
}

/// A formula MathJax could not typeset.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct FormulaError {
    pub line: usize,
    pub end_line: usize,
    pub display: bool,
    pub tex: String,
    pub message: String,
}

/// `updateContent`'s result: `{mermaid: [...], math: [...]}`.
#[derive(Debug, Clone, PartialEq, Eq, Default, Deserialize)]
#[serde(default)]
pub struct Report {
    pub mermaid: Vec<DiagramError>,
    pub math: Vec<FormulaError>,
}

/// Underlines the diagram line the parser complains about ("Parse error on
/// line N" counts from the first line inside the fence), else the fence's
/// first content line.
pub fn diagram_diagnostics(errors: &[DiagramError], text: &str) -> Vec<Diagnostic> {
    let u = utf16(text);
    let lines = LineIndex::new(&u);
    errors
        .iter()
        .filter_map(|e| {
            if e.line == 0 {
                return None;
            }
            let mut target = e.line + 1;
            if let Some(reported) = reported_line(&e.message) {
                let candidate = e.line + reported;
                if e.end_line == 0 || candidate < e.end_line {
                    target = candidate;
                }
            }
            let range = lines.range_of_line(target).or_else(|| lines.range_of_line(e.line))?;
            Some(Diagnostic { range, message: format!("Mermaid: {}", summary(&e.message)) })
        })
        .collect()
}

/// Display math: the formula's lines. Inline math: the `$ … $` span when it
/// can be found near the block's line, else that line.
pub fn formula_diagnostics(errors: &[FormulaError], text: &str) -> Vec<Diagnostic> {
    let t = Text::new(text);
    let lines = LineIndex::new(&t.u);
    errors
        .iter()
        .filter_map(|e| {
            if e.line == 0 {
                return None;
            }
            let first = lines.range_of_line(e.line)?;
            let message = format!("LaTeX: {}", e.message);
            if e.display {
                let last = lines.range_of_line(e.line.max(e.end_line)).unwrap_or(first);
                return Some(Diagnostic { range: Range::new(first.location, last.end() - first.location), message });
            }
            if !e.tex.is_empty() {
                let window_end = lines.range_of_line(e.line + 50).map(|r| r.end()).unwrap_or(t.len());
                let window = Range::new(first.location, window_end - first.location);
                if let Some(found) = t.find(&utf16(&e.tex), window) {
                    return Some(Diagnostic { range: found, message });
                }
            }
            Some(Diagnostic { range: first, message })
        })
        .collect()
}

/// N from mermaid's "Parse error on line N:" / "Lexical error on line N.".
pub fn reported_line(message: &str) -> Option<usize> {
    let idx = message.find("on line ")?;
    let digits: String = message[idx + 8..].chars().take_while(|c| c.is_ascii_digit()).collect();
    digits.parse().ok()
}

/// One line of a multi-line mermaid error: the expectation if there is one,
/// else the first line.
pub fn summary(message: &str) -> String {
    let lines: Vec<&str> = message.lines().map(|l| l.trim()).collect();
    if let Some(exp) = lines.iter().rev().find(|l| l.starts_with("Expecting")) {
        return exp.to_string();
    }
    lines.first().map(|s| s.to_string()).unwrap_or_else(|| message.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mermaid_line() {
        let text = "a\n```mermaid\ngraph TD\nA--B\n```";
        let d = diagram_diagnostics(
            &[DiagramError { line: 2, end_line: 5, message: "Parse error on line 2:\n...\nExpecting 'X'".into() }],
            text,
        );
        assert_eq!(d[0].range, Range::new(22, 4));
        assert_eq!(d[0].message, "Mermaid: Expecting 'X'");
    }

    #[test]
    fn inline_formula_span() {
        let text = "x\nsee $\\frac{a$ here";
        let d = formula_diagnostics(
            &[FormulaError { line: 2, end_line: 0, display: false, tex: "\\frac{a".into(), message: "bad".into() }],
            text,
        );
        assert_eq!(d[0].range, Range::new(7, 7));
    }
}

//! IntelliSense for LaTeX inside `$ … $` and `$$ … $$`.
//!
//! 1. `\alp|` — a control word is being typed: every catalog command plus
//!    the `\begin{…}` environment snippets.
//! 2. `\begin{ma|`, `\end{|`, `\mathbb{R|` — inside the brace argument:
//!    environment names, the environments still open, or the letters A–Z.
//! 3. Ctrl+Space with no backslash — the everyday commands and environments.

use std::sync::OnceLock;

use serde::Deserialize;

use super::{CompletionItem, CompletionRequest, CompletionResult, ItemKind, Provider};
use crate::math_locator;
use crate::text::{Range, Text};

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LatexCommand {
    pub name: String,
    pub insert_text: String,
    pub category: String,
    pub description: String,
    pub glyph: Option<String>,
    pub label: Option<String>,
    pub requires: Option<String>,
    pub priority: Option<i32>,
}

impl LatexCommand {
    pub fn display_label(&self) -> String {
        self.label.clone().unwrap_or_else(|| format!("\\{}", self.name))
    }
    pub fn is_symbol(&self) -> bool {
        self.glyph.is_some() && self.insert_text == format!("\\{}", self.name)
    }
}

#[derive(Debug, Clone, Deserialize, PartialEq, Eq)]
pub struct LatexEnvironment {
    pub name: String,
    pub description: String,
    pub argument: Option<String>,
}

impl LatexEnvironment {
    fn body_placeholder(&self) -> usize {
        if self.argument.is_none() {
            1
        } else {
            2
        }
    }

    /// Completes `\begin{` + typed prefix: the rest of the name, the
    /// argument, an indented body line and the matching `\end{…}`.
    pub fn begin_snippet(&self, closing_brace_follows: bool) -> String {
        let body = format!(
            "}}{}\n\t${{{}}}\n\\end{{{}",
            self.argument.as_deref().unwrap_or(""),
            self.body_placeholder(),
            self.name
        );
        format!("{}{}{}", self.name, body, if closing_brace_follows { "" } else { "}" })
    }

    pub fn full_snippet(&self) -> String {
        format!("\\begin{{{}", self.begin_snippet(false))
    }
}

#[derive(Debug, Clone, Deserialize)]
pub struct LatexCatalog {
    pub commands: Vec<LatexCommand>,
    pub environments: Vec<LatexEnvironment>,
}

impl LatexCatalog {
    pub fn shared() -> &'static LatexCatalog {
        static C: OnceLock<LatexCatalog> = OnceLock::new();
        C.get_or_init(|| {
            serde_json::from_str(include_str!("../latex-commands.json"))
                .unwrap_or(LatexCatalog { commands: vec![], environments: vec![] })
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LetterFont {
    Mathbb,
    Mathcal,
    Mathscr,
    Mathfrak,
}

impl LetterFont {
    pub fn from_command(c: &str) -> Option<Self> {
        Some(match c {
            "mathbb" => LetterFont::Mathbb,
            "mathcal" => LetterFont::Mathcal,
            "mathscr" => LetterFont::Mathscr,
            "mathfrak" => LetterFont::Mathfrak,
            _ => return None,
        })
    }

    fn common_letters(self) -> &'static [char] {
        match self {
            LetterFont::Mathbb => &['R', 'N', 'Z', 'Q', 'C'],
            LetterFont::Mathcal => &['O', 'L', 'F'],
            _ => &[],
        }
    }

    /// The Unicode character rendering `letter` in this font.
    pub fn glyph(self, letter: char) -> Option<char> {
        if !letter.is_ascii_uppercase() {
            return None;
        }
        let (base, exceptions): (u32, &[(char, u32)]) = match self {
            LetterFont::Mathbb => (
                0x1D538,
                &[('C', 0x2102), ('H', 0x210D), ('N', 0x2115), ('P', 0x2119), ('Q', 0x211A), ('R', 0x211D), ('Z', 0x2124)],
            ),
            LetterFont::Mathcal | LetterFont::Mathscr => (
                0x1D49C,
                &[
                    ('B', 0x212C),
                    ('E', 0x2130),
                    ('F', 0x2131),
                    ('H', 0x210B),
                    ('I', 0x2110),
                    ('L', 0x2112),
                    ('M', 0x2133),
                    ('R', 0x211B),
                ],
            ),
            LetterFont::Mathfrak => (0x1D504, &[('C', 0x212D), ('H', 0x210C), ('I', 0x2111), ('R', 0x211C), ('Z', 0x2128)]),
        };
        let value = exceptions
            .iter()
            .find(|e| e.0 == letter)
            .map(|e| e.1)
            .unwrap_or(base + (letter as u32 - 'A' as u32));
        char::from_u32(value)
    }
}

// MARK: - Source scanner

pub fn is_letter(u: u16) -> bool {
    (0x41..=0x5A).contains(&u) || (0x61..=0x7A).contains(&u)
}

fn run_start(text: &Text, location: usize, pred: impl Fn(u16) -> bool) -> usize {
    let mut start = location;
    while start > 0 && pred(text.at(start - 1)) {
        start -= 1;
    }
    start
}

pub fn starts_control_sequence(text: &Text, backslash: usize) -> bool {
    let mut count = 0;
    let mut i = backslash;
    while i > 0 && text.at(i - 1) == b'\\' as u16 {
        count += 1;
        i -= 1;
    }
    count % 2 == 0
}

/// The control word being typed, from its backslash up to `location`.
pub fn command_prefix(text: &Text, location: usize) -> Option<Range> {
    if location > text.len() {
        return None;
    }
    let letters = run_start(text, location, is_letter);
    if letters == 0 {
        return None;
    }
    let slash = letters - 1;
    if text.at(slash) != b'\\' as u16 || !starts_control_sequence(text, slash) {
        return None;
    }
    Some(Range::new(slash, location - slash))
}

pub fn word_prefix(text: &Text, location: usize) -> Range {
    let start = run_start(text, location, is_letter);
    Range::new(start, location - start)
}

/// The caret is inside the first brace argument of a command.
pub fn brace_argument(text: &Text, location: usize) -> Option<(String, Range)> {
    if location > text.len() {
        return None;
    }
    let arg_start = run_start(text, location, |u| is_letter(u) || u == b'*' as u16);
    if arg_start < 2 {
        return None;
    }
    let brace = arg_start - 1;
    if text.at(brace) != b'{' as u16 {
        return None;
    }
    let name_start = run_start(text, brace, is_letter);
    if name_start >= brace || name_start == 0 {
        return None;
    }
    let slash = name_start - 1;
    if text.at(slash) != b'\\' as u16 || !starts_control_sequence(text, slash) {
        return None;
    }
    let name = text.substring(Range::new(name_start, brace - name_start));
    Some((name, Range::new(arg_start, location - arg_start)))
}

pub fn closing_brace_follows(text: &Text, location: usize) -> bool {
    location < text.len() && text.at(location) == b'}' as u16
}

/// Environments opened in `range` and not yet closed, innermost last.
pub fn unclosed_environments(text: &Text, range: Range) -> Vec<String> {
    let u = &text.u;
    let mut stack: Vec<String> = vec![];
    let mut i = range.location;
    let end = range.end().min(u.len());
    while i < end {
        if u[i] == b'\\' as u16 && starts_control_sequence(text, i) {
            let rest = String::from_utf16_lossy(&u[i + 1..end]);
            let keyword = if rest.starts_with("begin") {
                Some("begin")
            } else if rest.starts_with("end") {
                Some("end")
            } else {
                None
            };
            if let Some(kw) = keyword {
                let after = rest[kw.len()..].trim_start();
                if let Some(arg) = after.strip_prefix('{') {
                    if let Some(close) = arg.find('}') {
                        let name = &arg[..close];
                        if !name.is_empty() && name.chars().all(|c| c.is_ascii_alphabetic() || c == '*') {
                            if kw == "begin" {
                                stack.push(name.to_string());
                            } else if let Some(idx) = stack.iter().rposition(|n| n == name) {
                                stack.truncate(idx);
                            }
                            let whitespace = rest[kw.len()..rest.len() - after.len()].encode_utf16().count();
                            // The name is ASCII, so its byte length is its UTF-16 length.
                            i += 1 + kw.len() + whitespace + 1 + close + 1;
                            continue;
                        }
                    }
                }
            }
        }
        i += 1;
    }
    stack
}

// MARK: - Provider

pub struct LatexProvider {
    catalog: &'static LatexCatalog,
}

impl LatexProvider {
    pub fn new() -> Self {
        LatexProvider { catalog: LatexCatalog::shared() }
    }

    fn item(command: &LatexCommand) -> CompletionItem {
        let mut documentation = command.description.clone();
        if let Some(package) = &command.requires {
            documentation.push_str(&format!("\n\nFrom the MathJax “{package}” extension (bundled)."));
        }
        let detail = match &command.glyph {
            Some(g) => format!("{g}  {}", command.category),
            None => command.category.clone(),
        };
        CompletionItem::new(
            command.display_label(),
            if command.is_symbol() { ItemKind::Symbol } else { ItemKind::Command },
            command.insert_text.clone(),
        )
        .detail(detail)
        .doc(documentation)
        .filter(command.name.clone())
        .priority(command.priority.unwrap_or(0))
    }

    fn command_items(&self) -> Vec<CompletionItem> {
        self.catalog.commands.iter().map(Self::item).collect()
    }

    fn begin_items(&self) -> Vec<CompletionItem> {
        self.catalog
            .environments
            .iter()
            .map(|e| {
                CompletionItem::new(format!("\\begin{{{}}}", e.name), ItemKind::Environment, e.full_snippet())
                    .detail("Environment")
                    .doc(e.description.clone())
                    .filter(format!("begin{{{}}}", e.name))
            })
            .collect()
    }

    fn common_items(&self) -> Vec<CompletionItem> {
        self.catalog.commands.iter().filter(|c| c.priority.unwrap_or(0) > 0).map(Self::item).collect()
    }

    fn argument_completions(&self, command: &str, range: Range, request: &CompletionRequest) -> Option<CompletionResult> {
        let brace_follows = closing_brace_follows(request.text, request.location);
        let close = if brace_follows { "" } else { "}" };
        match command {
            "begin" => {
                let items = self
                    .catalog
                    .environments
                    .iter()
                    .map(|e| {
                        CompletionItem::new(e.name.clone(), ItemKind::Environment, e.begin_snippet(brace_follows))
                            .detail("Environment")
                            .doc(e.description.clone())
                            .filter(e.name.clone())
                    })
                    .collect();
                Some(CompletionResult { replacement_range: range, items })
            }
            "end" => {
                let open = open_environments(request.text, range.location);
                let mut items: Vec<CompletionItem> = open
                    .iter()
                    .rev()
                    .enumerate()
                    .map(|(index, name)| {
                        CompletionItem::new(name.clone(), ItemKind::Environment, format!("{name}{close}"))
                            .detail("Open environment")
                            .doc(format!("Closes the \\begin{{{name}}} above."))
                            .filter(name.clone())
                            .priority(100 - index as i32)
                    })
                    .collect();
                items.extend(self.catalog.environments.iter().filter(|e| !open.contains(&e.name)).map(|e| {
                    CompletionItem::new(e.name.clone(), ItemKind::Environment, format!("{}{close}", e.name))
                        .detail("Environment")
                        .doc(e.description.clone())
                        .filter(e.name.clone())
                }));
                Some(CompletionResult { replacement_range: range, items })
            }
            _ => {
                let font = LetterFont::from_command(command)?;
                let items = ('A'..='Z')
                    .map(|letter| {
                        CompletionItem::new(letter.to_string(), ItemKind::Symbol, format!("{letter}{close}"))
                            .detail(font.glyph(letter).map(String::from).unwrap_or_default())
                            .doc(format!("\\{command}{{{letter}}}"))
                            .filter(letter.to_string())
                            .priority(if font.common_letters().contains(&letter) { 10 } else { 0 })
                    })
                    .collect();
                Some(CompletionResult { replacement_range: range, items })
            }
        }
    }
}

impl Default for LatexProvider {
    fn default() -> Self {
        Self::new()
    }
}

fn open_environments(text: &Text, location: usize) -> Vec<String> {
    let start = match math_locator::formula_at(text, location) {
        Some(f) => f.content_range.location,
        None => paragraph_start(text, location),
    };
    unclosed_environments(text, Range::new(start, location.saturating_sub(start)))
}

fn paragraph_start(text: &Text, location: usize) -> usize {
    let mut line_start = text.line_range(location).location;
    while line_start > 0 {
        let previous = text.line_range(line_start - 1);
        if text.substring(previous).trim().is_empty() {
            break;
        }
        line_start = previous.location;
    }
    line_start
}

impl Provider for LatexProvider {
    fn trigger_characters(&self) -> &'static [char] {
        &['\\', '{']
    }

    fn completions(&self, request: &CompletionRequest) -> Option<CompletionResult> {
        if !request.context.is_math() {
            return None;
        }
        let text = request.text;
        let location = request.location;
        if location > text.len() {
            return None;
        }
        if let Some((command, range)) = brace_argument(text, location) {
            if let Some(result) = self.argument_completions(&command, range, request) {
                return Some(result);
            }
        }
        if let Some(prefix) = command_prefix(text, location) {
            let mut items = self.command_items();
            items.extend(self.begin_items());
            return Some(CompletionResult { replacement_range: prefix, items });
        }
        if request.is_explicit {
            let mut items = self.common_items();
            items.extend(self.begin_items());
            return Some(CompletionResult { replacement_range: word_prefix(text, location), items });
        }
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_loads() {
        let c = LatexCatalog::shared();
        assert!(c.commands.len() > 400);
        assert!(c.environments.iter().any(|e| e.name == "pmatrix"));
    }

    #[test]
    fn environments_stack() {
        let t = Text::new("\\begin{a}\\begin{b}\\end{b}\\begin{c}");
        assert_eq!(unclosed_environments(&t, Range::new(0, t.len())), vec!["a", "c"]);
    }

    #[test]
    fn mathbb_glyphs() {
        assert_eq!(LetterFont::Mathbb.glyph('R'), Some('ℝ'));
        assert_eq!(LetterFont::Mathbb.glyph('A'), Some('𝔸'));
    }
}

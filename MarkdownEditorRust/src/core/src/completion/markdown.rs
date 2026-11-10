//! Completions for Markdown prose and fence info strings. Looks at the
//! current line up to the caret, most specific first:
//!
//! 1. `](#part`        → heading anchors of this document
//! 2. `](path` `![](…` → files next to the document
//! 3. `[text][part`, `[part` → reference-link labels defined in the document
//! 4. `word` alone at the start of a line → block snippets

use std::collections::{HashMap, HashSet};
use std::fs;
use std::sync::OnceLock;

use fancy_regex::{Captures, Regex};

use super::{CompletionItem, CompletionRequest, CompletionResult, ItemKind, Provider};
use crate::highlight::EditorContext;
use crate::text::Range;

struct Patterns {
    anchor_target: Regex,
    link_destination: Regex,
    full_reference: Regex,
    shortcut_reference: Regex,
    task_checkbox: Regex,
    line_start_word: Regex,
    fence_opening: Regex,
}

fn patterns() -> &'static Patterns {
    static P: OnceLock<Patterns> = OnceLock::new();
    P.get_or_init(|| Patterns {
        anchor_target: Regex::new(r#"\]\(#([^\s)#]*)$"#).unwrap(),
        link_destination: Regex::new(r#"(!?)\[(?:[^\[\]]|\[[^\]]*\])*\]\(([^\s)#"<>]*)$"#).unwrap(),
        full_reference: Regex::new(r#"\[[^\]]*\]\[([^\[\]]*)$"#).unwrap(),
        shortcut_reference: Regex::new(r#"(?<![\]!\\])\[([^\[\]()^][^\[\]()]*|)$"#).unwrap(),
        task_checkbox: Regex::new(r#"^\s*(?:[-*+]|\d+[.)])\s+\[[^\]]*$"#).unwrap(),
        line_start_word: Regex::new(r#"^[ \t]*([A-Za-z0-9]*)$"#).unwrap(),
        fence_opening: Regex::new(r#"^[ \t]*(?:`{3,}|~{3,})[ \t]*([^\s`]*)$"#).unwrap(),
    })
}

fn captures<'t>(re: &Regex, s: &'t str) -> Option<Captures<'t>> {
    re.captures(s).ok().flatten()
}

/// UTF-16 range of capture `i` within `s`.
fn group_range(s: &str, caps: &Captures, i: usize) -> Range {
    match caps.get(i) {
        Some(m) => Range::new(s[..m.start()].encode_utf16().count(), m.as_str().encode_utf16().count()),
        None => Range::new(0, 0),
    }
}

pub struct MarkdownSnippet {
    pub name: String,
    pub detail: &'static str,
    pub documentation: String,
    pub body: String,
    pub first_line_only: bool,
}

pub fn snippets() -> &'static [MarkdownSnippet] {
    static S: OnceLock<Vec<MarkdownSnippet>> = OnceLock::new();
    S.get_or_init(|| {
        let s = |name: &str, detail: &'static str, doc: &str, body: &str| MarkdownSnippet {
            name: name.into(),
            detail,
            documentation: doc.into(),
            body: body.into(),
            first_line_only: false,
        };
        let mut list = vec![
            s("table", "GFM table", "A table with three columns and two rows. Tab moves between cells.",
              "| ${1:Column 1} | ${2:Column 2} | ${3:Column 3} |\n| --- | --- | --- |\n| ${4} | ${5} | ${6} |\n| ${7} | ${8} | ${9} |\n$0"),
            s("code", "fenced code block", "A fenced code block. Type the language first (csharp, javascript, typescript and python are highlighted).",
              "```${1:language}\n$0\n```"),
            s("mermaid", "diagram", "A Mermaid diagram, rendered in the preview. Starts with a top-down flowchart.",
              "```mermaid\nflowchart TD\n    ${1:A}[${2:Start}] --> ${3:B}[${4:End}]\n```\n$0"),
            s("math", "display formula", "A display math block rendered with LaTeX syntax.", "\\$\\$\n${1:E = mc^2}\n\\$\\$\n$0"),
            s("task", "task list item", "An unchecked task list item. Type x between the brackets to check it.", "- [ ] ${1:task}$0"),
            s("link", "inline link", "An inline link: link text in brackets, then the URL or file path in parentheses.", "[${1:text}](${2:url})$0"),
            s("image", "image", "An image: alt text (for accessibility) in brackets, then the image path or URL in parentheses.", "![${1:alt}](${2:path})$0"),
            s("quote", "block quote", "A block quote. Continue the quote by starting the next line with >.", "> ${1:quote}$0"),
            s("hr", "horizontal rule", "A thematic break (horizontal line). Leave a blank line above it, or the line above becomes a heading.", "---\n$0"),
            s("details", "collapsible section", "An HTML <details> element: the summary is always visible, the content is shown when expanded.",
              "<details>\n<summary>${1:Summary}</summary>\n\n${2:Content}\n\n</details>\n$0"),
            s("footnote", "footnote definition", "A footnote definition. Reference it in the text with [^label].", "[^${1:1}]: ${2:Footnote text}$0"),
            MarkdownSnippet {
                name: "frontmatter".into(),
                detail: "YAML front matter",
                documentation: "YAML metadata at the top of the document, between --- lines.".into(),
                body: "---\ntitle: ${1}\n---\n$0".into(),
                first_line_only: true,
            },
        ];
        for level in 1..=6 {
            let hashes = "#".repeat(level);
            list.push(MarkdownSnippet {
                name: format!("h{level}"),
                detail: ["", "heading 1", "heading 2", "heading 3", "heading 4", "heading 5", "heading 6"][level],
                documentation: format!("A level-{level} heading ({hashes} Title)."),
                body: format!("{hashes} ${{1:Heading}}$0"),
                first_line_only: false,
            });
        }
        list
    })
}

/// Languages offered after an opening fence, with what the app does.
pub fn languages() -> Vec<(&'static str, &'static str)> {
    let mut list = vec![
        ("csharp", "highlighted"),
        ("javascript", "highlighted"),
        ("typescript", "highlighted"),
        ("python", "highlighted"),
        ("mermaid", "diagram"),
        ("math", "formula"),
    ];
    for name in [
        "json", "swift", "bash", "sh", "zsh", "html", "css", "scss", "yaml", "toml", "xml", "sql", "c", "cpp", "objc",
        "java", "kotlin", "go", "rust", "ruby", "php", "powershell", "dockerfile", "makefile", "diff", "markdown",
        "graphql", "ini", "plaintext", "text",
    ] {
        list.push((name, ""));
    }
    list
}

// MARK: - Document index

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Heading {
    pub title: String,
    pub level: usize,
    pub anchor: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Reference {
    pub label: String,
    pub destination: String,
}

#[derive(Debug, Default)]
pub struct DocumentIndex {
    pub headings: Vec<Heading>,
    pub references: Vec<Reference>,
}

/// GitHub's heading-anchor algorithm with de-duplication.
#[derive(Default)]
pub struct AnchorSlugger {
    used: HashMap<String, usize>,
}

impl AnchorSlugger {
    pub fn slug(text: &str) -> String {
        text.to_lowercase()
            .chars()
            .filter_map(|c| match c {
                ' ' => Some('-'),
                '-' | '_' => Some(c),
                c if c.is_alphanumeric() => Some(c),
                _ => None,
            })
            .collect()
    }

    pub fn anchor(&mut self, text: &str) -> String {
        let base = Self::slug(text);
        let Some(&count) = self.used.get(&base) else {
            self.used.insert(base.clone(), 1);
            return base;
        };
        let mut n = count;
        let mut candidate = format!("{base}-{n}");
        while self.used.contains_key(&candidate) {
            n += 1;
            candidate = format!("{base}-{n}");
        }
        self.used.insert(base, n + 1);
        self.used.insert(candidate.clone(), 1);
        candidate
    }
}

fn plain_text_regexes() -> &'static [(Regex, &'static str); 4] {
    static R: OnceLock<[(Regex, &'static str); 4]> = OnceLock::new();
    R.get_or_init(|| {
        [
            (Regex::new(r#"!?\[([^\]]*)\]\([^)]*\)"#).unwrap(), "$1"),
            (Regex::new(r#"!?\[([^\]]*)\]\[[^\]]*\]"#).unwrap(), "$1"),
            (Regex::new(r#"<[^>]+>"#).unwrap(), ""),
            (Regex::new(r#"(\*\*|__|\*|`|~~)"#).unwrap(), ""),
        ]
    })
}

/// Heading text without markup, as GitHub shows it.
pub fn plain_text(markdown: &str) -> String {
    let mut text = markdown.to_string();
    for (re, rep) in plain_text_regexes() {
        text = re.replace_all(&text, *rep).into_owned();
    }
    text.trim_matches([' ', '\t']).to_string()
}

fn fence_marker(line: &str) -> Option<(char, usize)> {
    let first = line.chars().next().filter(|&c| c == '`' || c == '~')?;
    let count = line.chars().take_while(|&c| c == first).count();
    (count >= 3).then_some((first, count))
}

fn atx_heading(line: &str) -> Option<(usize, String)> {
    let hashes = line.chars().take_while(|&c| c == '#').count();
    if !(1..=6).contains(&hashes) {
        return None;
    }
    let rest = &line[hashes..];
    if !(rest.is_empty() || rest.starts_with(' ') || rest.starts_with('\t')) {
        return None;
    }
    let mut body = rest.trim_matches([' ', '\t']).to_string();
    // Optional closing sequence: `## Title ##`.
    let trailing = body.chars().rev().take_while(|&c| c == '#').count();
    if trailing > 0 {
        let cut = body.len() - trailing;
        if cut == 0 || body[..cut].ends_with([' ', '\t']) {
            body = body[..cut].trim_matches([' ', '\t']).to_string();
        }
    }
    Some((hashes, plain_text(&body)))
}

fn setext_level(line: &str) -> Option<usize> {
    let body = line.trim_matches([' ', '\t']);
    let first = body.chars().next().filter(|&c| c == '=' || c == '-')?;
    body.chars().all(|c| c == first).then_some(if first == '=' { 1 } else { 2 })
}

fn can_be_setext_text(line: &str) -> bool {
    let Some(first) = line.chars().next() else { return false };
    if "-*+>|<".contains(first) {
        return false;
    }
    if first.is_ascii_digit() {
        let digits = line.chars().take_while(|c| c.is_ascii_digit()).count();
        let rest = &line[digits..];
        if (rest.starts_with('.') || rest.starts_with(')')) && rest[1..].chars().next().is_none_or(char::is_whitespace) {
            return false;
        }
    }
    true
}

fn reference_definition(line: &str) -> Option<Reference> {
    let rest = line.strip_prefix('[')?;
    if rest.starts_with('^') {
        return None;
    }
    let close = rest.find(']')?;
    let label = &rest[..close];
    let after = rest[close + 1..].strip_prefix(':')?;
    if label.trim_matches([' ', '\t']).is_empty() {
        return None;
    }
    let destination = after.trim_matches([' ', '\t']).split(' ').next().unwrap_or("").to_string();
    Some(Reference { label: label.to_string(), destination })
}

impl DocumentIndex {
    pub fn new(text: &str) -> Self {
        let mut index = DocumentIndex::default();
        let mut slugger = AnchorSlugger::default();
        let mut seen = HashSet::new();
        let mut fence: Option<(char, usize)> = None;
        let mut in_front_matter = false;
        let mut setext_candidate: Option<String> = None;
        for (line_number, raw) in text.split('\n').enumerate() {
            let line = raw.strip_suffix('\r').unwrap_or(raw);
            let trimmed = line.trim_start_matches([' ', '\t']);
            let indent = line.chars().count() - trimmed.chars().count();
            if line_number == 0 && trimmed == "---" {
                in_front_matter = true;
                continue;
            }
            if in_front_matter {
                if trimmed == "---" || trimmed == "..." {
                    in_front_matter = false;
                }
                continue;
            }
            if let Some(open) = fence {
                if let Some(close) = fence_marker(trimmed) {
                    if close.0 == open.0
                        && close.1 >= open.1
                        && trimmed.trim_start_matches(open.0).chars().all(char::is_whitespace)
                    {
                        fence = None;
                    }
                }
                continue;
            }
            if indent <= 3 {
                if let Some(open) = fence_marker(trimmed) {
                    fence = Some(open);
                    setext_candidate = None;
                    continue;
                }
            }
            if indent > 3 {
                setext_candidate = None;
                continue;
            }
            if let Some((level, title)) = atx_heading(trimmed) {
                let anchor = slugger.anchor(&title);
                index.headings.push(Heading { title, level, anchor });
                setext_candidate = None;
                continue;
            }
            if let (Some(candidate), Some(level)) = (&setext_candidate, setext_level(trimmed)) {
                let title = plain_text(candidate);
                let anchor = slugger.anchor(&title);
                index.headings.push(Heading { title, level, anchor });
                setext_candidate = None;
                continue;
            }
            if let Some(reference) = reference_definition(trimmed) {
                if seen.insert(reference.label.to_lowercase()) {
                    index.references.push(reference);
                }
                setext_candidate = None;
                continue;
            }
            setext_candidate = can_be_setext_text(trimmed).then(|| trimmed.to_string());
        }
        index
    }
}

// MARK: - Provider

pub struct MarkdownProvider;

const IMAGE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "gif", "svg", "webp"];

pub fn encode_path_component(name: &str) -> String {
    let mut out = String::new();
    for c in name.chars() {
        match c {
            ' ' => out.push_str("%20"),
            '(' => out.push_str("%28"),
            ')' => out.push_str("%29"),
            '<' => out.push_str("%3C"),
            '>' => out.push_str("%3E"),
            _ => out.push(c),
        }
    }
    out
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(v) = u8::from_str_radix(&s[i + 1..i + 3], 16) {
                out.push(v);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8(out).unwrap_or_else(|_| s.to_string())
}

impl MarkdownProvider {
    fn fence_languages(prefix: &str, line_start: usize) -> Option<CompletionResult> {
        let caps = captures(&patterns().fence_opening, prefix)?;
        let partial = group_range(prefix, &caps, 1);
        let items = languages()
            .into_iter()
            .enumerate()
            .map(|(offset, (name, support))| {
                let doc = match support {
                    "highlighted" => "Syntax-highlighted in the preview and exports.",
                    "diagram" => "Rendered as a Mermaid diagram in the preview.",
                    "formula" => "Rendered as a display formula (LaTeX syntax).",
                    _ => "Shown as plain code; the language is kept as a label.",
                };
                CompletionItem::new(name, ItemKind::Language, name)
                    .detail(support)
                    .doc(doc)
                    .priority((if support.is_empty() { 0 } else { 100 }) - offset as i32)
            })
            .collect();
        Some(CompletionResult { replacement_range: Range::new(line_start + partial.location, partial.length), items })
    }

    fn heading_anchors(prefix: &str, line_start: usize, text: &str) -> Option<CompletionResult> {
        let caps = captures(&patterns().anchor_target, prefix)?;
        let partial = group_range(prefix, &caps, 1);
        let headings = DocumentIndex::new(text).headings;
        if headings.is_empty() {
            return None;
        }
        let items = headings
            .iter()
            .enumerate()
            .map(|(offset, h)| {
                let label = if h.title.is_empty() { format!("#{}", h.anchor) } else { h.title.clone() };
                CompletionItem::new(label, ItemKind::Heading, h.anchor.clone())
                    .detail(format!("H{}", h.level))
                    .doc(format!("#{}", h.anchor))
                    .filter(h.anchor.clone())
                    .priority(-(offset as i32))
            })
            .collect();
        Some(CompletionResult { replacement_range: Range::new(line_start + partial.location, partial.length), items })
    }

    fn reference_labels(prefix: &str, line_start: usize, text: &str) -> Option<CompletionResult> {
        let p = patterns();
        let caps = match captures(&p.full_reference, prefix) {
            Some(c) => c,
            None => {
                let c = captures(&p.shortcut_reference, prefix)?;
                if captures(&p.task_checkbox, prefix).is_some() {
                    return None;
                }
                c
            }
        };
        let references = DocumentIndex::new(text).references;
        if references.is_empty() {
            return None;
        }
        let partial = group_range(prefix, &caps, 1);
        let items = references
            .iter()
            .map(|r| {
                CompletionItem::new(r.label.clone(), ItemKind::Reference, r.label.clone())
                    .detail(r.destination.clone())
                    .doc(format!("[{}]: {}", r.label, r.destination))
            })
            .collect();
        Some(CompletionResult { replacement_range: Range::new(line_start + partial.location, partial.length), items })
    }

    fn file_paths(prefix: &str, caps: &Captures, line_start: usize, request: &CompletionRequest) -> Option<CompletionResult> {
        let document = request.document_path.as_ref()?;
        let is_image = caps.get(1).is_some_and(|m| !m.as_str().is_empty());
        let path_range = group_range(prefix, caps, 2);
        let typed = caps.get(2).map(|m| m.as_str()).unwrap_or("");
        if typed.contains(':') || typed.starts_with('/') {
            return None;
        }
        let directory_part = typed.rfind('/').map(|i| &typed[..=i]).unwrap_or("");
        let name_part_len = typed.encode_utf16().count() - directory_part.encode_utf16().count();
        let base = document.parent()?;
        let decoded = percent_decode(directory_part);
        let directory = if decoded.is_empty() { base.to_path_buf() } else { base.join(&decoded) };
        let entries = fs::read_dir(&directory).ok()?;
        let mut items: Vec<CompletionItem> = entries
            .filter_map(|e| e.ok())
            .filter_map(|entry| {
                let name = entry.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') {
                    return None;
                }
                let path = entry.path();
                if path == *document {
                    return None;
                }
                let is_dir = entry.file_type().map(|t| t.is_dir()).unwrap_or(false);
                let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
                let is_image_file = IMAGE_EXTENSIONS.contains(&ext.as_str());
                let priority = if is_image {
                    if is_image_file {
                        20
                    } else if is_dir {
                        10
                    } else {
                        0
                    }
                } else if is_dir {
                    10
                } else {
                    0
                };
                Some(
                    CompletionItem::new(
                        if is_dir { format!("{name}/") } else { name.clone() },
                        ItemKind::File,
                        format!("{}{}", encode_path_component(&name), if is_dir { "/" } else { "" }),
                    )
                    .detail(if is_dir {
                        "folder".to_string()
                    } else if is_image_file {
                        "image".to_string()
                    } else {
                        ext
                    })
                    .doc(format!("{decoded}{name}"))
                    .filter(name)
                    .priority(priority),
                )
            })
            .collect();
        if items.is_empty() {
            return None;
        }
        items.sort_by_key(|i| i.label.to_lowercase());
        Some(CompletionResult {
            replacement_range: Range::new(line_start + path_range.end() - name_part_len, name_part_len),
            items,
        })
    }

    fn block_snippets(prefix: &str, line_start: usize, explicit: bool) -> Option<CompletionResult> {
        let caps = captures(&patterns().line_start_word, prefix)?;
        let word_range = group_range(prefix, &caps, 1);
        let word = caps.get(1).map(|m| m.as_str()).unwrap_or("");
        let first_line = line_start == 0;
        let available = snippets().iter().filter(|s| !s.first_line_only || first_line);
        let offered: Vec<&MarkdownSnippet> = if explicit {
            if word.is_empty() {
                available.collect()
            } else {
                let lower = word.to_lowercase();
                available.filter(|s| s.name.starts_with(&lower)).collect()
            }
        } else {
            if word.chars().count() < 2 {
                return None;
            }
            available.filter(|s| s.name.starts_with(word)).collect()
        };
        if offered.is_empty() {
            return None;
        }
        let items = offered
            .iter()
            .map(|s| {
                CompletionItem::new(s.name.clone(), ItemKind::Snippet, s.body.clone())
                    .detail(s.detail)
                    .doc(s.documentation.clone())
            })
            .collect();
        Some(CompletionResult { replacement_range: Range::new(line_start + word_range.location, word_range.length), items })
    }
}

impl Provider for MarkdownProvider {
    fn trigger_characters(&self) -> &'static [char] {
        &['#', '(', '[', '/', '`']
    }

    fn completions(&self, request: &CompletionRequest) -> Option<CompletionResult> {
        let text = request.text;
        let location = request.location.min(text.len());
        let line_start = text.line_range(location).location;
        let prefix = text.substring(Range::new(line_start, location - line_start));
        match request.context {
            EditorContext::FenceInfo => Self::fence_languages(&prefix, line_start),
            EditorContext::Markdown => {
                let full = text.to_string();
                if let Some(r) = Self::heading_anchors(&prefix, line_start, &full) {
                    return Some(r);
                }
                if let Some(caps) = captures(&patterns().link_destination, &prefix) {
                    return Self::file_paths(&prefix, &caps, line_start, request);
                }
                if let Some(r) = Self::reference_labels(&prefix, line_start, &full) {
                    return Some(r);
                }
                Self::block_snippets(&prefix, line_start, request.is_explicit)
            }
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn anchors_are_github_style() {
        let index = DocumentIndex::new("# Intro\n## Intro\nTitle\n===\n[ref]: http://x \"t\"\n```\n# not\n```");
        let anchors: Vec<&str> = index.headings.iter().map(|h| h.anchor.as_str()).collect();
        assert_eq!(anchors, vec!["intro", "intro-1", "title"]);
        assert_eq!(index.references[0], Reference { label: "ref".into(), destination: "http://x".into() });
    }

    #[test]
    fn plain_text_strips_links() {
        assert_eq!(plain_text("A [link](http://x) and **bold**"), "A link and bold");
    }
}

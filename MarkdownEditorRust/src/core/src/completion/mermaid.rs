//! IntelliSense inside ` ```mermaid ` fences.
//!
//! - On the diagram's first line: the diagram types, each inserting a small
//!   working template.
//! - Below it: the keywords and snippets of the detected type, plus the
//!   identifiers the diagram already defines (ranked first).
//! - Right after arrow characters (`A --`): the type's edge operators.
//!
//! The keyword tables live in `mermaid-syntax.json` (only syntax the bundled
//! Mermaid 11 renders).

use std::collections::{HashMap, HashSet};
use std::sync::OnceLock;

use fancy_regex::Regex;
use serde::Deserialize;

use super::{CompletionItem, CompletionRequest, CompletionResult, ItemKind, Provider};
use crate::highlight::EditorContext;
use crate::text::{Range, Text};

#[derive(Debug, Clone, Deserialize)]
pub struct MermaidEntry {
    pub label: String,
    pub insert: String,
    pub detail: String,
    pub doc: String,
}

impl MermaidEntry {
    fn is_snippet(&self) -> bool {
        self.insert.contains('$') || self.insert.contains('\n')
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SyntaxTables {
    common: Vec<MermaidEntry>,
    keywords: HashMap<String, Vec<MermaidEntry>>,
    arrows: HashMap<String, Vec<MermaidEntry>>,
    templates: Vec<MermaidEntry>,
    directions: Vec<MermaidEntry>,
    git_graph_orientations: Vec<MermaidEntry>,
}

fn tables() -> &'static SyntaxTables {
    static T: OnceLock<SyntaxTables> = OnceLock::new();
    T.get_or_init(|| serde_json::from_str(include_str!("../mermaid-syntax.json")).expect("mermaid-syntax.json"))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum DiagramType {
    Flowchart,
    Sequence,
    ClassDiagram,
    State,
    Er,
    Journey,
    Gantt,
    Pie,
    Quadrant,
    Requirement,
    GitGraph,
    Mindmap,
    Timeline,
    Sankey,
    Xychart,
    Block,
    Packet,
    Architecture,
    Kanban,
    Radar,
    Treemap,
}

impl DiagramType {
    pub fn raw(self) -> &'static str {
        use DiagramType::*;
        match self {
            Flowchart => "flowchart",
            Sequence => "sequence",
            ClassDiagram => "classDiagram",
            State => "state",
            Er => "er",
            Journey => "journey",
            Gantt => "gantt",
            Pie => "pie",
            Quadrant => "quadrant",
            Requirement => "requirement",
            GitGraph => "gitGraph",
            Mindmap => "mindmap",
            Timeline => "timeline",
            Sankey => "sankey",
            Xychart => "xychart",
            Block => "block",
            Packet => "packet",
            Architecture => "architecture",
            Kanban => "kanban",
            Radar => "radar",
            Treemap => "treemap",
        }
    }

    /// The type named by a diagram's first line.
    pub fn from_type_line(line: &str) -> Option<Self> {
        use DiagramType::*;
        let word = line.split(|c| c == ' ' || c == '\t' || c == ':').find(|s| !s.is_empty())?;
        Some(match word {
            "flowchart" | "graph" | "flowchart-elk" => Flowchart,
            "sequenceDiagram" => Sequence,
            "classDiagram" | "classDiagram-v2" => ClassDiagram,
            "stateDiagram" | "stateDiagram-v2" => State,
            "erDiagram" => Er,
            "journey" => Journey,
            "gantt" => Gantt,
            "pie" => Pie,
            "quadrantChart" => Quadrant,
            "requirementDiagram" => Requirement,
            "gitGraph" => GitGraph,
            "mindmap" => Mindmap,
            "timeline" => Timeline,
            "sankey-beta" | "sankey" => Sankey,
            "xychart-beta" | "xychart" => Xychart,
            "block-beta" | "block" => Block,
            "packet-beta" | "packet" => Packet,
            "architecture-beta" => Architecture,
            "kanban" => Kanban,
            "radar-beta" => Radar,
            "treemap-beta" | "treemap" => Treemap,
            _ => return None,
        })
    }

    fn keywords(self) -> &'static [MermaidEntry] {
        tables().keywords.get(self.raw()).map(|v| v.as_slice()).unwrap_or(&[])
    }

    fn arrows(self) -> &'static [MermaidEntry] {
        tables().arrows.get(self.raw()).map(|v| v.as_slice()).unwrap_or(&[])
    }
}

// MARK: - Block

/// The ` ```mermaid ` fence around the caret, split into lines.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MermaidBlock {
    pub lines: Vec<String>,
    pub caret_line: usize,
    pub caret_prefix: String,
    pub caret_suffix: String,
}

struct Fence {
    marker: char,
    count: usize,
    info: String,
}

impl Fence {
    fn parse(line: &str) -> Option<Fence> {
        let indent = line.chars().take_while(|&c| c == ' ').count();
        if indent > 3 {
            return None;
        }
        let rest = &line[indent..];
        let first = rest.chars().next().filter(|&c| c == '`' || c == '~')?;
        let run = rest.chars().take_while(|&c| c == first).count();
        if run < 3 {
            return None;
        }
        Some(Fence { marker: first, count: run, info: rest[run..].trim_matches(|c| c == ' ' || c == '\t').to_string() })
    }
    fn is_mermaid(&self) -> bool {
        self.info.split([' ', '\t']).next().is_some_and(|w| w.to_lowercase() == "mermaid")
    }
    fn closes(&self, opening: &Fence) -> bool {
        self.marker == opening.marker && self.count >= opening.count && self.info.is_empty()
    }
}

const MAX_LINES: usize = 10_000;

impl MermaidBlock {
    pub fn find(text: &Text, location: usize) -> Option<MermaidBlock> {
        let location = location.min(text.len());
        let caret_range = text.line_range(location);
        let line_text = |r: Range| text.substring(r).trim_end_matches(['\n', '\r']).to_string();
        let caret_line_text = line_text(caret_range);
        if Fence::parse(&caret_line_text).is_some() {
            return None;
        }
        let mut above = vec![];
        let mut start = caret_range.location;
        let mut opening = None;
        while start > 0 && above.len() < MAX_LINES {
            let range = text.line_range(start - 1);
            let candidate = line_text(range);
            if let Some(f) = Fence::parse(&candidate) {
                if !f.is_mermaid() {
                    return None;
                }
                opening = Some(f);
                break;
            }
            above.push(candidate);
            start = range.location;
        }
        let opening = opening?;
        let mut below = vec![];
        let mut next = caret_range.end();
        while next < text.len() && below.len() < MAX_LINES {
            let range = text.line_range(next);
            let candidate = line_text(range);
            if Fence::parse(&candidate).is_some_and(|f| f.closes(&opening)) {
                break;
            }
            below.push(candidate);
            if range.end() <= next {
                break;
            }
            next = range.end();
        }
        let caret_units: Vec<u16> = caret_line_text.encode_utf16().collect();
        let split = (location - caret_range.location).min(caret_units.len());
        let caret_line = above.len();
        above.reverse();
        above.push(caret_line_text);
        above.extend(below);
        Some(MermaidBlock {
            lines: above,
            caret_line,
            caret_prefix: String::from_utf16_lossy(&caret_units[..split]),
            caret_suffix: String::from_utf16_lossy(&caret_units[split..]),
        })
    }
}

// MARK: - Identifiers

pub fn is_identifier_char(c: char) -> bool {
    c == '_' || c.is_alphabetic() || c.is_numeric()
}

#[derive(Default)]
struct OrderedNames {
    list: Vec<String>,
    seen: HashSet<String>,
}

impl OrderedNames {
    fn add(&mut self, name: &str) {
        if !name.is_empty() && self.seen.insert(name.to_string()) {
            self.list.push(name.to_string());
        }
    }
}

fn re(pattern: &str) -> Regex {
    Regex::new(pattern).expect("valid regex")
}

struct Patterns {
    edge_text: Regex,
    quoted: Regex,
    pipe_label: Regex,
    participant: Regex,
    message: Regex,
    class_decl: Regex,
    annotated: Regex,
    class_relation: Regex,
    class_member: Regex,
    state_as: Regex,
    state_decl: Regex,
    transition: Regex,
    state_description: Regex,
    er_relation: Regex,
    er_entity: Regex,
    branch_ref: Regex,
}

fn patterns() -> &'static Patterns {
    static P: OnceLock<Patterns> = OnceLock::new();
    P.get_or_init(|| Patterns {
        edge_text: re(r#"(?<![-=.<])(--|==|-\.)\s+[^\s\-=.>|][^|]*?\s+(-->|---|==>|===|\.->|-\.-|--[ox]|==[ox])"#),
        quoted: re(r#""[^"]*""#),
        pipe_label: re(r#"\|[^|]*\|"#),
        participant: re(r#"^\s*(?:create\s+)?(?:participant|actor)\s+([^\s@]+)"#),
        message: re(r#"^\s*([^\s:+\-<>,]+)\s*(?:<<)?--?(?:>>|>|x|\))\s*[+\-]?\s*([^\s:+\-,][^\s:,]*)\s*:"#),
        class_decl: re(r#"^\s*class\s+([A-Za-z0-9_]+)"#),
        annotated: re(r#"^\s*<<[^>]*>>\s*([A-Za-z0-9_]+)"#),
        class_relation: re(
            r#"([A-Za-z0-9_]+)(?:~[^~]*~)?\s*(?:"[^"]*")?\s*(?:<\||\*|o|<)?(?:--|\.\.)(?:\|>|>|\*|o)?\s*(?:"[^"]*")?\s*([A-Za-z0-9_]+)"#,
        ),
        class_member: re(r#"^\s*([A-Za-z0-9_]+)\s*:"#),
        state_as: re(r#"^\s*state\s+"[^"]*"\s+as\s+([A-Za-z0-9_]+)"#),
        state_decl: re(r#"^\s*state\s+([A-Za-z0-9_]+)"#),
        transition: re(r#"([A-Za-z0-9_]+|\[\*\])\s*-->\s*([A-Za-z0-9_]+|\[\*\])"#),
        state_description: re(r#"^\s*([A-Za-z0-9_]+)\s*:"#),
        er_relation: re(
            r#"^\s*([A-Za-z0-9_\-]+)\s*(?:\|o|\|\||\}o|\}\|)(?:--|\.\.)(?:o\||\|\||o\{|\|\{)\s*([A-Za-z0-9_\-]+)"#,
        ),
        er_entity: re(r#"^\s*([A-Za-z0-9_\-]+)\s*(?:\[[^\]]*\])?\s*(?:\{.*)?$"#),
        branch_ref: re(r#"^\s*(?:branch|checkout|switch|merge)\s+(?:"([^"]+)"|([^\s"]+))"#),
    })
}

fn first_match(re: &Regex, line: &str) -> Option<Vec<String>> {
    let caps = re.captures(line).ok()??;
    Some((1..caps.len()).map(|i| caps.get(i).map(|m| m.as_str().to_string()).unwrap_or_default()).collect())
}

fn strip_comment(line: &str) -> &str {
    line.find("%%").map(|i| &line[..i]).unwrap_or(line)
}

fn first_word(line: &str) -> &str {
    line.trim_start_matches([' ', '\t']).split([' ', '\t']).next().unwrap_or("")
}

fn count_char(s: &str, c: char) -> i32 {
    s.chars().filter(|&x| x == c).count() as i32
}

/// Names a diagram already defines, in first-appearance order.
pub fn scan_identifiers(lines: &[String], ty: DiagramType) -> Vec<String> {
    let mut names = OrderedNames::default();
    let p = patterns();
    match ty {
        DiagramType::Flowchart => {
            let skip = ["classDef", "class", "style", "linkStyle", "click", "direction", "end"];
            for raw in lines {
                let mut line = strip_comment(raw).trim_matches([' ', '\t']).to_string();
                let first = first_word(&line).to_string();
                if skip.contains(&first.as_str()) {
                    continue;
                }
                if first == "subgraph" {
                    let rest = line["subgraph".len()..].trim_matches([' ', '\t']);
                    let id: String = rest.chars().take_while(|&c| is_identifier_char(c)).collect();
                    let after = rest[id.len()..].trim_matches([' ', '\t']);
                    if !id.is_empty() && (after.is_empty() || after.starts_with('[')) {
                        names.add(&id);
                    }
                    continue;
                }
                line = p.edge_text.replace_all(&line, " --> ").into_owned();
                line = p.quoted.replace_all(&line, "\"\"").into_owned();
                line = p.pipe_label.replace_all(&line, " ").into_owned();
                tokenize_flowchart(&line, &mut names);
            }
        }
        DiagramType::Sequence => {
            for raw in lines {
                let line = strip_comment(raw);
                if let Some(m) = first_match(&p.participant, line) {
                    names.add(&m[0]);
                    continue;
                }
                if let Some(m) = first_match(&p.message, line) {
                    names.add(&m[0]);
                    names.add(&m[1]);
                }
            }
        }
        DiagramType::ClassDiagram => {
            let mut depth = 0;
            for raw in lines {
                let line = strip_comment(raw);
                let was_inside = depth > 0;
                depth = (depth + count_char(line, '{') - count_char(line, '}')).max(0);
                if first_word(line) == "namespace" {
                    continue;
                }
                if let Some(m) = first_match(&p.class_decl, line) {
                    names.add(&m[0]);
                    continue;
                }
                if was_inside {
                    continue;
                }
                if let Some(m) = first_match(&p.annotated, line) {
                    names.add(&m[0]);
                    continue;
                }
                if let Some(m) = first_match(&p.class_relation, line) {
                    names.add(&m[0]);
                    names.add(&m[1]);
                    continue;
                }
                if let Some(m) = first_match(&p.class_member, line) {
                    names.add(&m[0]);
                }
            }
        }
        DiagramType::State => {
            let skip = ["note", "classDef", "class", "direction", "end", "style"];
            let mut in_note = false;
            for raw in lines {
                let line = strip_comment(raw);
                let first = first_word(line);
                if in_note {
                    if first == "end" {
                        in_note = false;
                    }
                    continue;
                }
                if first == "note" {
                    in_note = !line.contains(':');
                    continue;
                }
                if skip.contains(&first) {
                    continue;
                }
                if let Some(m) = first_match(&p.state_as, line).or_else(|| first_match(&p.state_decl, line)) {
                    names.add(&m[0]);
                    continue;
                }
                if let Some(m) = first_match(&p.transition, line) {
                    for n in m.iter().filter(|n| n.as_str() != "[*]") {
                        names.add(n);
                    }
                    continue;
                }
                if let Some(m) = first_match(&p.state_description, line) {
                    names.add(&m[0]);
                }
            }
        }
        DiagramType::Er => {
            let mut depth = 0;
            for raw in lines {
                let line = strip_comment(raw);
                if depth == 0 {
                    if let Some(m) = first_match(&p.er_relation, line) {
                        names.add(&m[0]);
                        names.add(&m[1]);
                        continue;
                    }
                }
                let was_inside = depth > 0;
                depth = (depth + count_char(line, '{') - count_char(line, '}')).max(0);
                if was_inside {
                    continue;
                }
                if let Some(m) = first_match(&p.er_entity, line) {
                    if m[0] != "direction" {
                        names.add(&m[0]);
                    }
                }
            }
        }
        DiagramType::GitGraph => {
            names.add("main");
            for raw in lines {
                if let Some(m) = first_match(&p.branch_ref, strip_comment(raw)) {
                    names.add(if m[0].is_empty() { &m[1] } else { &m[0] });
                }
            }
        }
        _ => {}
    }
    names.list
}

fn tokenize_flowchart(line: &str, names: &mut OrderedNames) {
    let chars: Vec<char> = line.chars().collect();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if is_identifier_char(c) {
            let start = i;
            while i < chars.len() && is_identifier_char(chars[i]) {
                i += 1;
            }
            let word: String = chars[start..i].iter().collect();
            let next = chars.get(i).copied();
            let previous = if start > 0 { Some(chars[start - 1]) } else { None };
            let is_edge_id = next == Some('@') && (i + 1 >= chars.len() || chars[i + 1] != '{');
            let is_class_name = start >= 3 && chars[start - 3..start].iter().collect::<String>() == ":::";
            let is_arrow_end = (word == "o" || word == "x")
                && ("-=.".contains(previous.unwrap_or(' ')) || "-=.<".contains(next.unwrap_or(' ')));
            if !is_edge_id && !is_class_name && !is_arrow_end {
                names.add(&word);
            }
            if next == Some('>') {
                while i < chars.len() && chars[i] != ']' {
                    i += 1;
                }
                i += 1;
            }
            continue;
        }
        if "[({".contains(c) {
            let mut depth = 0;
            loop {
                if "[({".contains(chars[i]) {
                    depth += 1;
                } else if "])}".contains(chars[i]) {
                    depth -= 1;
                }
                i += 1;
                if !(i < chars.len() && depth > 0) {
                    break;
                }
            }
            continue;
        }
        i += 1;
    }
}

pub fn noun(ty: DiagramType) -> &'static str {
    match ty {
        DiagramType::Flowchart => "node",
        DiagramType::Sequence => "participant",
        DiagramType::ClassDiagram => "class",
        DiagramType::State => "state",
        DiagramType::Er => "entity",
        DiagramType::GitGraph => "branch",
        _ => "identifier",
    }
}

// MARK: - Provider

const RANK_IDENTIFIER: i32 = 30;
const RANK_KEYWORD: i32 = 20;
const RANK_MID_LINE: i32 = 10;
const RANK_COMMON: i32 = 0;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HeaderPosition {
    FrontMatter,
    BeforeType,
    TypeLine,
    Body(usize),
}

pub fn header_position(block: &MermaidBlock) -> HeaderPosition {
    let lines = &block.lines;
    let first_non_blank = lines.iter().position(|l| !l.trim_matches([' ', '\t']).is_empty());
    let mut index = 0;
    while index < lines.len() {
        let line = lines[index].trim_matches([' ', '\t']);
        if line == "---" && Some(index) == first_non_blank {
            let close = lines[index + 1..]
                .iter()
                .position(|l| l.trim_matches([' ', '\t']) == "---")
                .map(|p| p + index + 1)
                .unwrap_or(lines.len());
            if block.caret_line >= index && block.caret_line <= close {
                return HeaderPosition::FrontMatter;
            }
            index = close + 1;
            continue;
        }
        if line.is_empty() || line.starts_with("%%") {
            index += 1;
            continue;
        }
        if block.caret_line < index {
            return HeaderPosition::BeforeType;
        }
        return if block.caret_line == index { HeaderPosition::TypeLine } else { HeaderPosition::Body(index) };
    }
    if block.caret_line < lines.len() {
        HeaderPosition::TypeLine
    } else {
        HeaderPosition::BeforeType
    }
}

pub fn word_start(chars: &[char], allow_leading_punctuation: bool) -> usize {
    let mut start = chars.len();
    while start > 0 {
        let c = chars[start - 1];
        if is_identifier_char(c) {
            start -= 1;
            continue;
        }
        if c == '-'
            && start >= 2
            && is_identifier_char(chars[start - 2])
            && (start == chars.len() || is_identifier_char(chars[start]))
        {
            start -= 1;
            continue;
        }
        break;
    }
    if allow_leading_punctuation {
        let mut p = start;
        while p > 0 && (chars[p - 1] == '<' || chars[p - 1] == '%') {
            p -= 1;
        }
        if p < start && (p == 0 || chars[p - 1].is_whitespace()) {
            start = p;
        }
    }
    start
}

pub fn arrow_run_length(chars: &[char], ty: DiagramType, hyphenated: &[String]) -> Option<usize> {
    if ty.arrows().is_empty() {
        return None;
    }
    let punctuation: &[char] = if ty == DiagramType::Er {
        &['-', '<', '>', '.', '=', '|', '*', ')', '~', '{', '}']
    } else {
        &['-', '<', '>', '.', '=', '|', '*', ')', '~']
    };
    if chars.last() == Some(&'-') {
        let mut j = chars.len() - 1;
        while j > 0 && is_identifier_char(chars[j - 1]) {
            j -= 1;
        }
        let word: String = chars[j..].iter().collect();
        if word.chars().count() > 1 && hyphenated.iter().any(|h| h.starts_with(&word)) {
            return None;
        }
    }
    let mut i = chars.len();
    while i > 0 {
        let c = chars[i - 1];
        if punctuation.contains(&c) {
            i -= 1;
            continue;
        }
        if c == 'o' || c == 'x' {
            let left_is_arrow = i >= 2 && punctuation.contains(&chars[i - 2]);
            let right_is_arrow = i < chars.len() && punctuation.contains(&chars[i]);
            let left_is_boundary = i < 2 || chars[i - 2].is_whitespace();
            if left_is_arrow || (right_is_arrow && left_is_boundary) {
                i -= 1;
                continue;
            }
        }
        break;
    }
    let run: String = chars[i..].iter().collect();
    if run.is_empty() || !chars[..i].iter().any(|c| !c.is_whitespace()) {
        return None;
    }
    let is_arrow = run.chars().any(|c| "-=<>".contains(c))
        || run.contains("..")
        || (ty == DiagramType::Er && (run.starts_with('|') || run.starts_with('}')));
    is_arrow.then_some(chars.len() - i)
}

pub fn follows_edge(chars: &[char], ty: DiagramType) -> bool {
    let mut chars = chars.to_vec();
    if chars.last() == Some(&'&') {
        return true;
    }
    if ty == DiagramType::Flowchart && chars.last() == Some(&'|') {
        if let Some(open) = chars[..chars.len() - 1].iter().rposition(|&c| c == '|') {
            chars.truncate(open);
            while chars.last().is_some_and(|c| c.is_whitespace()) {
                chars.pop();
            }
        }
    }
    if ty == DiagramType::Sequence && chars.last() == Some(&'+') {
        chars.pop();
    }
    arrow_run_length(&chars, ty, &[]).is_some()
}

pub fn is_inside_label(prefix: &str, ty: DiagramType) -> bool {
    if count_char(prefix, '"') % 2 == 1 {
        return true;
    }
    let (opens, closes): (&[char], &[char]) =
        if ty == DiagramType::Flowchart { (&['[', '(', '{'], &[']', ')', '}']) } else { (&['[', '('], &[']', ')']) };
    let mut depth = 0i32;
    for c in prefix.chars() {
        if opens.contains(&c) {
            depth += 1;
        } else if closes.contains(&c) {
            depth = (depth - 1).max(0);
        }
    }
    if depth > 0 {
        return true;
    }
    if ty == DiagramType::Flowchart && count_char(prefix, '|') % 2 == 1 {
        return true;
    }
    use DiagramType::*;
    let free = [Sequence, State, ClassDiagram, Er, Journey, Timeline, Pie, Quadrant, Packet, Treemap, Requirement];
    free.contains(&ty) && prefix.contains(':')
}

fn utf16_count(chars: &[char]) -> usize {
    chars.iter().map(|c| c.len_utf16()).sum()
}

fn items(entries: &[MermaidEntry], kind: Option<ItemKind>, rank: i32) -> Vec<CompletionItem> {
    entries
        .iter()
        .map(|e| {
            CompletionItem::new(
                e.label.clone(),
                kind.unwrap_or(if e.is_snippet() { ItemKind::Snippet } else { ItemKind::Keyword }),
                e.insert.clone(),
            )
            .detail(e.detail.clone())
            .doc(e.doc.clone())
            .priority(rank)
        })
        .collect()
}

pub struct MermaidProvider;

impl MermaidProvider {
    fn word_result(
        prefix: &[char],
        request: &CompletionRequest,
        items: Vec<CompletionItem>,
        first_token_only: bool,
    ) -> Option<CompletionResult> {
        let start = word_start(prefix, true);
        let word = &prefix[start..];
        if !request.is_explicit && word.is_empty() {
            return None;
        }
        if first_token_only && prefix[..start].iter().any(|c| !c.is_whitespace()) {
            return None;
        }
        let len = utf16_count(word);
        Some(CompletionResult { replacement_range: Range::new(request.location - len, len), items })
    }

    fn header_completions(prefix: &[char], request: &CompletionRequest) -> Option<CompletionResult> {
        let s: String = prefix.iter().collect();
        let words: Vec<&str> = s.split([' ', '\t']).filter(|w| !w.is_empty()).collect();
        let ends_in_space = prefix.last().is_some_and(|&c| c == ' ' || c == '\t');
        let word_index = words.len() - if ends_in_space || words.is_empty() { 0 } else { 1 };
        let t = tables();
        if word_index == 0 {
            let mut list = items(&t.templates, Some(ItemKind::Diagram), RANK_KEYWORD);
            list.extend(items(&t.common, Some(ItemKind::Snippet), RANK_COMMON));
            return Self::word_result(prefix, request, list, true);
        }
        if word_index != 1 {
            return None;
        }
        match words[0] {
            "flowchart" | "graph" | "flowchart-elk" => {
                Self::word_result(prefix, request, items(&t.directions, Some(ItemKind::Keyword), RANK_KEYWORD), false)
            }
            "gitGraph" => Self::word_result(
                prefix,
                request,
                items(&t.git_graph_orientations, Some(ItemKind::Keyword), RANK_KEYWORD),
                false,
            ),
            _ => None,
        }
    }

    fn body_completions(
        prefix: &[char],
        block: &MermaidBlock,
        type_line: usize,
        ty: DiagramType,
        request: &CompletionRequest,
    ) -> Option<CompletionResult> {
        let keywords = ty.keywords();
        let hyphenated: Vec<String> = keywords.iter().map(|k| k.label.clone()).filter(|l| l.contains('-')).collect();
        if let Some(length) = arrow_run_length(prefix, ty, &hyphenated) {
            let len = utf16_count(&prefix[prefix.len() - length..]);
            let list = items(ty.arrows(), Some(ItemKind::Symbol), RANK_KEYWORD);
            return (!list.is_empty())
                .then(|| CompletionResult { replacement_range: Range::new(request.location - len, len), items: list });
        }
        let prefix_str: String = prefix.iter().collect();
        if is_inside_label(&prefix_str, ty) {
            return None;
        }
        let start = word_start(prefix, true);
        let word = &prefix[start..];
        if !request.is_explicit && word.is_empty() {
            return None;
        }
        let before: String = prefix[..start].iter().collect();
        let before_trimmed: Vec<char> = before.trim_matches([' ', '\t']).chars().collect();
        let mut body: Vec<String> = block.lines[type_line + 1..].to_vec();
        let idx = block.caret_line - type_line - 1;
        body[idx] = format!("{before}{}", block.caret_suffix);
        let n = noun(ty);
        let identifiers: Vec<CompletionItem> = scan_identifiers(&body, ty)
            .into_iter()
            .map(|name| CompletionItem::new(name.clone(), ItemKind::Identifier, name).detail(n).priority(RANK_IDENTIFIER))
            .collect();
        let t = tables();
        let list: Vec<CompletionItem> = if before_trimmed.is_empty() {
            let mut l = identifiers;
            l.extend(items(keywords, None, RANK_KEYWORD));
            l.extend(items(&t.common, Some(ItemKind::Snippet), RANK_COMMON));
            l
        } else if follows_edge(&before_trimmed, ty) {
            identifiers
        } else if before_trimmed.iter().rev().take_while(|c| !c.is_whitespace()).collect::<Vec<_>>().iter().rev().copied().collect::<String>()
            == "direction"
        {
            items(&t.directions, Some(ItemKind::Keyword), RANK_KEYWORD)
        } else {
            let mut l = identifiers;
            l.extend(items(keywords, None, RANK_MID_LINE));
            l
        };
        if list.is_empty() {
            return None;
        }
        let len = utf16_count(word);
        Some(CompletionResult { replacement_range: Range::new(request.location - len, len), items: list })
    }
}

impl Provider for MermaidProvider {
    fn trigger_characters(&self) -> &'static [char] {
        &['-', '>']
    }

    fn completions(&self, request: &CompletionRequest) -> Option<CompletionResult> {
        if request.context != EditorContext::Mermaid {
            return None;
        }
        let block = MermaidBlock::find(request.text, request.location)?;
        let prefix: Vec<char> = block.caret_prefix.chars().collect();
        if block.caret_prefix.trim_start_matches([' ', '\t']).starts_with("%%") {
            return None;
        }
        let t = tables();
        match header_position(&block) {
            HeaderPosition::FrontMatter => None,
            HeaderPosition::BeforeType => {
                Self::word_result(&prefix, request, items(&t.common, Some(ItemKind::Snippet), RANK_COMMON), true)
            }
            HeaderPosition::TypeLine => Self::header_completions(&prefix, request),
            HeaderPosition::Body(type_line) => match DiagramType::from_type_line(&block.lines[type_line]) {
                None => Self::word_result(&prefix, request, items(&t.common, Some(ItemKind::Snippet), RANK_COMMON), true),
                Some(ty) => Self::body_completions(&prefix, &block, type_line, ty, request),
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn flowchart_identifiers() {
        let lines: Vec<String> = ["A[Start] --> B{Is it?}", "B -->|Yes| C[OK]", "C -- text --> D"].iter().map(|s| s.to_string()).collect();
        assert_eq!(scan_identifiers(&lines, DiagramType::Flowchart), vec!["A", "B", "C", "D"]);
    }

    #[test]
    fn block_and_tables() {
        let t = Text::new("```mermaid\nflowchart TD\nA --> \n```");
        let b = MermaidBlock::find(&t, 29).unwrap();
        assert_eq!(b.caret_line, 1);
        assert_eq!(header_position(&b), HeaderPosition::Body(0));
        assert!(!tables().templates.is_empty());
    }
}

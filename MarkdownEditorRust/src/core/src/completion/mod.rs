//! IntelliSense: completion items, fuzzy ranking, snippets, and the
//! providers for Markdown, LaTeX and mermaid.
//!
//! The popup itself is drawn by the front end; the list state
//! ([`ListModel`]) lives here so filtering and ranking are the same code the
//! tests exercise.

pub mod fuzzy;
pub mod latex;
pub mod markdown;
pub mod mermaid;
pub mod snippet;

use std::path::PathBuf;

use serde::{Deserialize, Serialize};

use crate::highlight::{self, EditorContext};
use crate::text::{Range, Text};
use fuzzy::Tier;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ItemKind {
    Keyword,
    Snippet,
    Command,
    Environment,
    Symbol,
    Heading,
    Reference,
    File,
    Language,
    Diagram,
    Identifier,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompletionItem {
    pub label: String,
    pub detail: String,
    pub documentation: String,
    pub kind: ItemKind,
    /// Replaces the replacement range; may contain snippet placeholders.
    pub insert_text: String,
    pub filter_text: Option<String>,
    pub sort_priority: i32,
}

impl CompletionItem {
    pub fn new(label: impl Into<String>, kind: ItemKind, insert_text: impl Into<String>) -> Self {
        CompletionItem {
            label: label.into(),
            detail: String::new(),
            documentation: String::new(),
            kind,
            insert_text: insert_text.into(),
            filter_text: None,
            sort_priority: 0,
        }
    }
    pub fn detail(mut self, d: impl Into<String>) -> Self {
        self.detail = d.into();
        self
    }
    pub fn doc(mut self, d: impl Into<String>) -> Self {
        self.documentation = d.into();
        self
    }
    pub fn filter(mut self, f: impl Into<String>) -> Self {
        self.filter_text = Some(f.into());
        self
    }
    pub fn priority(mut self, p: i32) -> Self {
        self.sort_priority = p;
        self
    }
}

pub struct CompletionRequest<'a> {
    pub text: &'a Text,
    pub location: usize,
    pub context: EditorContext,
    /// The saved document's path, for relative file paths.
    pub document_path: Option<PathBuf>,
    pub is_explicit: bool,
}

pub struct CompletionResult {
    pub replacement_range: Range,
    pub items: Vec<CompletionItem>,
}

pub trait Provider: Send + Sync {
    fn trigger_characters(&self) -> &'static [char];
    fn completions(&self, request: &CompletionRequest) -> Option<CompletionResult>;
}

/// The providers in the order they are asked.
pub fn providers() -> Vec<Box<dyn Provider>> {
    vec![
        Box::new(latex::LatexProvider::new()),
        Box::new(mermaid::MermaidProvider),
        Box::new(markdown::MarkdownProvider),
    ]
}

/// Every trigger character of every provider.
pub fn trigger_characters() -> Vec<char> {
    let mut all: Vec<char> = providers().iter().flat_map(|p| p.trigger_characters().iter().copied()).collect();
    all.sort();
    all.dedup();
    all
}

/// Characters that continue a word for auto-triggering.
pub fn is_word_character(c: char) -> bool {
    c.is_alphanumeric() || c == '-' || c == '_'
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub item: CompletionItem,
    #[serde(skip)]
    pub tier: Tier,
    /// Matched character offsets in `item.label`.
    pub label_highlights: Vec<usize>,
    #[serde(skip)]
    pub original_index: usize,
}

/// The popup's state without any UI.
#[derive(Debug, Clone)]
pub struct ListModel {
    pub items: Vec<CompletionItem>,
    /// Where the replaced text starts in the document.
    pub anchor: usize,
    /// Characters of the original range after the caret.
    pub trailing_length: usize,
    pub query: String,
    pub entries: Vec<Entry>,
    pub selected_index: usize,
}

impl ListModel {
    pub fn new(result: CompletionResult, caret: usize) -> Self {
        ListModel {
            items: result.items,
            anchor: result.replacement_range.location,
            trailing_length: result.replacement_range.end().saturating_sub(caret),
            query: String::new(),
            entries: vec![],
            selected_index: 0,
        }
    }

    pub fn selected_item(&self) -> Option<&CompletionItem> {
        self.entries.get(self.selected_index).map(|e| &e.item)
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    pub fn replacement_range(&self, caret: usize) -> Range {
        Range::new(self.anchor, caret.saturating_sub(self.anchor) + self.trailing_length)
    }

    /// Re-filters and re-ranks for `query`; keeps the selection only for a
    /// re-filter with the same query.
    pub fn filter(&mut self, query: &str) {
        let previous = self.selected_item().cloned();
        let changed = query != self.query;
        self.query = query.to_string();
        self.entries = self
            .items
            .iter()
            .enumerate()
            .filter_map(|(index, item)| {
                let filter_text = item.filter_text.as_deref().unwrap_or(&item.label);
                // LaTeX items filter by the bare name while the typed query
                // starts at the backslash: `\al` must match `alpha`.
                let m = fuzzy::match_query(query, filter_text).or_else(|| {
                    let bare = query.strip_prefix('\\')?;
                    (!filter_text.starts_with('\\')).then(|| fuzzy::match_query(bare, filter_text)).flatten()
                })?;
                let highlights = if filter_text == item.label {
                    m.matched_indices
                } else {
                    fuzzy::match_query(query, &item.label).map(|m| m.matched_indices).unwrap_or_default()
                };
                Some(Entry { item: item.clone(), tier: m.tier, label_highlights: highlights, original_index: index })
            })
            .collect();
        self.entries.sort_by(|a, b| {
            b.tier
                .cmp(&a.tier)
                .then(b.item.sort_priority.cmp(&a.item.sort_priority))
                .then(a.item.label.chars().count().cmp(&b.item.label.chars().count()))
                .then(a.original_index.cmp(&b.original_index))
        });
        self.selected_index = 0;
        if !changed {
            if let Some(prev) = previous {
                if let Some(i) = self.entries.iter().position(|e| e.item == prev) {
                    self.selected_index = i;
                }
            }
        }
    }

    pub fn move_selection(&mut self, delta: isize, wrapping: bool) {
        if self.entries.is_empty() {
            return;
        }
        let n = self.entries.len() as isize;
        let i = self.selected_index as isize + delta;
        self.selected_index = if wrapping { i.rem_euclid(n) } else { i.clamp(0, n - 1) } as usize;
    }
}

/// Asks the providers in order; the first non-empty result is returned as a
/// filtered model.
pub fn query(text: &Text, caret: usize, explicit: bool, document_path: Option<PathBuf>) -> Option<ListModel> {
    if caret > text.len() {
        return None;
    }
    let context = highlight::context_at(&text.u, caret);
    let request = CompletionRequest { text, location: caret, context, document_path, is_explicit: explicit };
    for provider in providers() {
        let Some(result) = provider.completions(&request) else { continue };
        if result.items.is_empty() {
            continue;
        }
        let range = result.replacement_range;
        if !(range.location <= caret && range.end() >= caret && range.end() <= text.len()) {
            continue;
        }
        let mut model = ListModel::new(result, caret);
        model.filter(&text.substring(Range::new(range.location, caret - range.location)));
        if model.is_empty() {
            continue;
        }
        return Some(model);
    }
    None
}

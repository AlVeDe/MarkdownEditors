//! App-wide editor preferences, persisted as JSON in the platform's config
//! directory by the app. Field names are camelCase in JSON so the front end
//! can use the same object.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum ViewMode {
    Editor,
    #[default]
    Split,
    Preview,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum SplitOrientation {
    #[default]
    SideBySide,
    Stacked,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Settings {
    /// Empty means the platform's monospaced font.
    pub font_name: String,
    pub font_size: f64,
    pub tab_width: usize,
    pub indent_with_spaces: bool,
    pub wraps_lines: bool,
    pub shows_line_numbers: bool,
    pub shows_invisibles: bool,
    pub highlights_current_line: bool,
    pub shows_status_bar: bool,
    pub auto_pairs: bool,
    /// Renumber ordered lists after list edits (Return, line moves, Tab…).
    pub renumbers_lists: bool,
    pub smart_quotes: bool,
    pub spell_checking: bool,
    pub shows_completions: bool,
    pub sync_scrolling: bool,
    pub default_view_mode: ViewMode,
    pub split_orientation: SplitOrientation,
    pub shows_outline: bool,
    pub shows_toolbar: bool,
}

impl Settings {
    pub const MIN_FONT_SIZE: f64 = 8.0;
    pub const MAX_FONT_SIZE: f64 = 40.0;
    pub const DEFAULT_FONT_SIZE: f64 = 13.0;

    /// One indentation step as inserted by Tab.
    pub fn indent_unit(&self) -> String {
        if self.indent_with_spaces {
            " ".repeat(self.tab_width.max(1))
        } else {
            "\t".into()
        }
    }
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            font_name: String::new(),
            font_size: Self::DEFAULT_FONT_SIZE,
            tab_width: 4,
            indent_with_spaces: true,
            wraps_lines: true,
            shows_line_numbers: true,
            shows_invisibles: false,
            highlights_current_line: true,
            shows_status_bar: true,
            auto_pairs: true,
            renumbers_lists: true,
            smart_quotes: false,
            spell_checking: false,
            shows_completions: true,
            sync_scrolling: true,
            default_view_mode: ViewMode::Split,
            split_orientation: SplitOrientation::SideBySide,
            shows_outline: false,
            shows_toolbar: true,
        }
    }
}

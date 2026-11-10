//! The native menu bar: File, Edit, Format, View, Window, Help.
//!
//! Document commands are forwarded to the focused window's front end as a
//! `menu` event carrying the item id; preferences toggled from the View menu
//! are applied here (they are app-wide) and broadcast to every window.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use mdcore::editor::settings::SplitOrientation;
use mdcore::editor::Settings;
use tauri::menu::{
    AboutMetadata, CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu, SubmenuBuilder,
};
use tauri::{AppHandle, Emitter, Manager, Wry};

use crate::{focused_window, AppState};

const MAC: bool = cfg!(target_os = "macos");

/// An accelerator with a macOS-specific variant (macOS uses ⌃⌘ chords that
/// other platforms spell with Ctrl+Alt).
fn acc(mac: &'static str, other: &'static str) -> Option<&'static str> {
    Some(if MAC { mac } else { other })
}

fn checks() -> &'static Mutex<HashMap<&'static str, CheckMenuItem<Wry>>> {
    static C: OnceLock<Mutex<HashMap<&'static str, CheckMenuItem<Wry>>>> = OnceLock::new();
    C.get_or_init(|| Mutex::new(HashMap::new()))
}

fn item(app: &AppHandle, id: &str, title: &str, accelerator: Option<&str>) -> tauri::Result<MenuItem<Wry>> {
    MenuItem::with_id(app, id, title, true, accelerator)
}

fn check(app: &AppHandle, id: &'static str, title: &str, on: bool, accelerator: Option<&str>) -> tauri::Result<CheckMenuItem<Wry>> {
    let c = CheckMenuItem::with_id(app, id, title, true, on, accelerator)?;
    checks().lock().unwrap().insert(id, c.clone());
    Ok(c)
}

pub fn build(app: &AppHandle, settings: &Settings) -> tauri::Result<Menu<Wry>> {
    let menu = Menu::new(app)?;

    if MAC {
        let about = PredefinedMenuItem::about(
            app,
            Some("About MarkdownEditor"),
            Some(AboutMetadata {
                name: Some("MarkdownEditor".into()),
                version: Some(env!("CARGO_PKG_VERSION").into()),
                comments: Some("A Markdown editor with live preview.".into()),
                ..Default::default()
            }),
        )?;
        let app_menu = SubmenuBuilder::new(app, "MarkdownEditor")
            .item(&about)
            .separator()
            .item(&item(app, "settings", "Settings…", Some("Cmd+,"))?)
            .separator()
            .item(&PredefinedMenuItem::services(app, None)?)
            .separator()
            .item(&PredefinedMenuItem::hide(app, None)?)
            .item(&PredefinedMenuItem::hide_others(app, None)?)
            .item(&PredefinedMenuItem::show_all(app, None)?)
            .separator()
            .item(&item(app, "quit", "Quit MarkdownEditor", Some("Cmd+Q"))?)
            .build()?;
        menu.append(&app_menu)?;
    }

    // File
    let mut file = SubmenuBuilder::new(app, "File")
        .item(&item(app, "new", "New", Some("CmdOrCtrl+N"))?)
        .item(&item(app, "open", "Open…", Some("CmdOrCtrl+O"))?)
        .separator()
        .item(&item(app, "close", "Close Window", Some("CmdOrCtrl+W"))?)
        .item(&item(app, "save", "Save", Some("CmdOrCtrl+S"))?)
        .item(&item(app, "save_as", "Save As…", Some("Shift+CmdOrCtrl+S"))?)
        .separator()
        .item(&item(app, "export_pdf", "Export as PDF…", Some("Alt+CmdOrCtrl+E"))?)
        .item(&item(app, "export_html", "Export as HTML…", Some("Shift+CmdOrCtrl+E"))?)
        .separator()
        .item(&item(app, "print", "Print…", Some("CmdOrCtrl+P"))?);
    if !MAC {
        file = file
            .separator()
            .item(&item(app, "settings", "Settings…", Some("Ctrl+,"))?)
            .separator()
            .item(&item(app, "quit", "Quit", Some("Ctrl+Q"))?);
    }
    menu.append(&file.build()?)?;

    // Edit
    let lines = SubmenuBuilder::new(app, "Lines")
        .item(&item(app, "move_lines_up", "Move Line Up", acc("Ctrl+Cmd+Up", "Alt+Up"))?)
        .item(&item(app, "move_lines_down", "Move Line Down", acc("Ctrl+Cmd+Down", "Alt+Down"))?)
        .item(&item(app, "duplicate_lines", "Duplicate Line", Some("Shift+CmdOrCtrl+D"))?)
        .item(&item(app, "delete_lines", "Delete Line", Some("Ctrl+Shift+K"))?)
        .item(&item(app, "join_lines", "Join Lines", Some("Ctrl+J"))?)
        .separator()
        .item(&item(app, "toggle_line_comment", "Toggle Comment", Some("CmdOrCtrl+/"))?)
        .item(&item(app, "select_lines", "Select Line", None)?)
        .build()?;
    let mut edit = SubmenuBuilder::new(app, "Edit");
    if MAC {
        edit = edit.item(&PredefinedMenuItem::undo(app, None)?).item(&PredefinedMenuItem::redo(app, None)?);
    } else {
        // The text area handles Ctrl+Z / Ctrl+Y itself; these mirror it.
        edit = edit.item(&item(app, "undo", "Undo", None)?).item(&item(app, "redo", "Redo", None)?);
    }
    edit = edit
        .separator()
        .item(&PredefinedMenuItem::cut(app, None)?)
        .item(&PredefinedMenuItem::copy(app, None)?)
        .item(&PredefinedMenuItem::paste(app, None)?)
        .item(&PredefinedMenuItem::select_all(app, None)?)
        .separator()
        .item(&item(app, "find", "Find…", Some("CmdOrCtrl+F"))?)
        .item(&item(app, "find_replace", "Find and Replace…", Some(if MAC { "Alt+Cmd+F" } else { "Ctrl+H" }))?)
        .item(&item(app, "find_next", "Find Next", Some(if MAC { "Cmd+G" } else { "F3" }))?)
        .item(&item(app, "find_previous", "Find Previous", Some(if MAC { "Shift+Cmd+G" } else { "Shift+F3" }))?)
        .item(&item(app, "find_selection", "Use Selection for Find", Some("CmdOrCtrl+E"))?)
        .separator()
        .item(&item(app, "go_to_line", "Go to Line…", Some(if MAC { "Cmd+L" } else { "Ctrl+G" }))?)
        .item(&item(app, "show_completions", "Show Completions", Some(if MAC { "Alt+Escape" } else { "Ctrl+Space" }))?)
        .separator()
        .item(&lines);
    menu.append(&edit.build()?)?;

    // Format
    let code_languages = SubmenuBuilder::new(app, "Code Block Language")
        .item(&item(app, "fmt:codeBlock:csharp", "C#", None)?)
        .item(&item(app, "fmt:codeBlock:javascript", "JavaScript", None)?)
        .item(&item(app, "fmt:codeBlock:typescript", "TypeScript", None)?)
        .item(&item(app, "fmt:codeBlock:python", "Python", None)?)
        .build()?;
    let mut table_sizes = SubmenuBuilder::new(app, "Insert Table of Size");
    for (c, r) in [(2, 2), (3, 2), (3, 3), (4, 3), (4, 4), (5, 4)] {
        table_sizes = table_sizes.item(&item(app, &format!("fmt:table:{r}:{c}"), &format!("{c} × {r}"), None)?);
    }
    let mut format = SubmenuBuilder::new(app, "Format")
        .item(&item(app, "fmt:bold", "Bold", Some("CmdOrCtrl+B"))?)
        .item(&item(app, "fmt:italic", "Italic", Some("CmdOrCtrl+I"))?)
        .item(&item(app, "fmt:strikethrough", "Strikethrough", Some("Shift+CmdOrCtrl+X"))?)
        .item(&item(app, "fmt:highlight", "Highlight", Some("Shift+CmdOrCtrl+H"))?)
        .item(&item(app, "fmt:inlineCode", "Inline Code", Some("Ctrl+`"))?)
        .item(&item(app, "fmt:superscriptText", "Superscript", acc("Ctrl+Cmd+=", "Ctrl+Alt+="))?)
        .item(&item(app, "fmt:subscriptText", "Subscript", acc("Ctrl+Cmd+-", "Ctrl+Alt+-"))?)
        .separator();
    for level in 1..=6 {
        let accel: &'static str = ["", "CmdOrCtrl+1", "CmdOrCtrl+2", "CmdOrCtrl+3", "CmdOrCtrl+4", "CmdOrCtrl+5", "CmdOrCtrl+6"][level];
        format = format.item(&item(app, &format!("fmt:heading:{level}"), &format!("Heading {level}"), Some(accel))?);
    }
    format = format
        .item(&item(app, "fmt:paragraph", "Paragraph", acc("Ctrl+Cmd+0", "Ctrl+Alt+0"))?)
        .separator()
        .item(&item(app, "fmt:link", "Link", Some("CmdOrCtrl+K"))?)
        .item(&item(app, "fmt:image", "Image", acc("Ctrl+Cmd+I", "Ctrl+Alt+I"))?)
        .item(&item(app, "fmt:footnote", "Footnote", acc("Alt+Ctrl+Cmd+F", "Ctrl+Alt+Shift+F"))?)
        .separator()
        .item(&item(app, "fmt:quote", "Quote", Some("Alt+CmdOrCtrl+'"))?)
        .item(&item(app, "fmt:bulletList", "Bulleted List", Some("Shift+CmdOrCtrl+8"))?)
        .item(&item(app, "fmt:numberedList", "Numbered List", Some("Shift+CmdOrCtrl+7"))?)
        .item(&item(app, "fmt:taskList", "Task List", Some("Shift+CmdOrCtrl+9"))?)
        .item(&item(app, "fmt:toggleTask", "Toggle Task", acc("Ctrl+Cmd+X", "Ctrl+Alt+X"))?)
        .item(&item(app, "renumber_list", "Renumber List", None)?)
        .separator()
        .item(&item(app, "fmt:codeBlock", "Code Block", Some("Alt+CmdOrCtrl+K"))?)
        .item(&code_languages)
        .item(&item(app, "fmt:table:2:3", "Insert Table", Some("Alt+Shift+CmdOrCtrl+T"))?)
        .item(&table_sizes.build()?)
        .item(&item(app, "format_table", "Align Table", None)?)
        .item(&item(app, "fmt:horizontalRule", "Horizontal Rule", None)?)
        .item(&item(app, "fmt:inlineMath", "Inline Math", acc("Ctrl+Cmd+M", "Ctrl+Alt+M"))?)
        .item(&item(app, "fmt:displayMath", "Display Math", None)?)
        .item(&item(app, "fmt:mermaid", "Mermaid Diagram", None)?)
        .separator()
        .item(&item(app, "fmt:indent", "Indent", Some("CmdOrCtrl+]"))?)
        .item(&item(app, "fmt:outdent", "Outdent", Some("CmdOrCtrl+["))?);
    menu.append(&format.build()?)?;

    // View
    let split = SubmenuBuilder::new(app, "Split")
        .item(&check(app, "split_side", "Side by Side", settings.split_orientation == SplitOrientation::SideBySide, None)?)
        .item(&check(app, "split_stacked", "Stacked", settings.split_orientation == SplitOrientation::Stacked, None)?)
        .build()?;
    let view = SubmenuBuilder::new(app, "View")
        .item(&item(app, "view:editor", "Editor Only", Some("Alt+CmdOrCtrl+1"))?)
        .item(&item(app, "view:split", "Editor and Preview", Some("Alt+CmdOrCtrl+2"))?)
        .item(&item(app, "view:preview", "Preview Only", Some("Alt+CmdOrCtrl+3"))?)
        .item(&split)
        .item(&check(app, "sync_scrolling", "Synchronize Scrolling", settings.sync_scrolling, None)?)
        .item(&item(app, "toggle_outline", "Show/Hide Outline", acc("Ctrl+Cmd+S", "Ctrl+Alt+S"))?)
        .item(&check(app, "shows_toolbar", "Show Toolbar", settings.shows_toolbar, None)?)
        .separator()
        .item(&check(app, "shows_line_numbers", "Show Line Numbers", settings.shows_line_numbers, None)?)
        .item(&check(app, "wraps_lines", "Wrap Lines", settings.wraps_lines, None)?)
        .item(&check(app, "shows_invisibles", "Show Invisibles", settings.shows_invisibles, None)?)
        .item(&check(app, "highlights_current_line", "Highlight Current Line", settings.highlights_current_line, None)?)
        .item(&check(app, "shows_status_bar", "Show Status Bar", settings.shows_status_bar, None)?)
        .separator()
        .item(&item(app, "zoom_in", "Bigger", Some("CmdOrCtrl+="))?)
        .item(&item(app, "zoom_out", "Smaller", Some("CmdOrCtrl+-"))?)
        .item(&item(app, "zoom_reset", "Actual Size", Some("CmdOrCtrl+0"))?)
        .build()?;
    menu.append(&view)?;

    if MAC {
        let window = SubmenuBuilder::new(app, "Window")
            .item(&PredefinedMenuItem::minimize(app, None)?)
            .item(&PredefinedMenuItem::maximize(app, Some("Zoom"))?)
            .separator()
            .item(&PredefinedMenuItem::fullscreen(app, None)?)
            .build()?;
        menu.append(&window)?;
    }

    let help: Submenu<Wry> = SubmenuBuilder::new(app, "Help")
        .item(&item(app, "open_sample", "Open Sample Document", None)?)
        .item(&item(app, "markdown_guide", "Markdown Reference (CommonMark)", None)?)
        .build()?;
    menu.append(&help)?;
    Ok(menu)
}

/// Updates the View menu's check marks after a settings change.
pub fn sync_check_items(_app: &AppHandle, s: &Settings) {
    let checks = checks().lock().unwrap();
    let set = |id: &str, on: bool| {
        if let Some(c) = checks.get(id) {
            let _ = c.set_checked(on);
        }
    };
    set("split_side", s.split_orientation == SplitOrientation::SideBySide);
    set("split_stacked", s.split_orientation == SplitOrientation::Stacked);
    set("sync_scrolling", s.sync_scrolling);
    set("shows_toolbar", s.shows_toolbar);
    set("shows_line_numbers", s.shows_line_numbers);
    set("wraps_lines", s.wraps_lines);
    set("shows_invisibles", s.shows_invisibles);
    set("highlights_current_line", s.highlights_current_line);
    set("shows_status_bar", s.shows_status_bar);
}

fn update_settings(app: &AppHandle, f: impl FnOnce(&mut Settings)) {
    let state = app.state::<AppState>();
    let settings = {
        let mut s = state.settings.lock().unwrap();
        f(&mut s);
        s.clone()
    };
    crate::store_settings(&settings);
    sync_check_items(app, &settings);
    let _ = app.emit("settings-changed", settings);
}

pub fn handle(app: &AppHandle, id: &str) {
    match id {
        "new" => {
            let _ = crate::open_window(app, None, None);
        }
        "quit" => {
            // Let every window ask about unsaved changes; the app exits
            // when the last one has closed.
            crate::QUITTING.store(true, std::sync::atomic::Ordering::SeqCst);
            let windows = app.webview_windows();
            if windows.is_empty() {
                app.exit(0);
            }
            for w in windows.values() {
                let _ = w.emit_to(w.label(), "menu", "close");
            }
        }
        "open_sample" => {
            let _ = crate::sample_document(app.clone());
        }
        "markdown_guide" => {
            let _ = crate::open_url(app.clone(), "https://commonmark.org/help/".into());
        }
        "split_side" => update_settings(app, |s| s.split_orientation = SplitOrientation::SideBySide),
        "split_stacked" => update_settings(app, |s| s.split_orientation = SplitOrientation::Stacked),
        "sync_scrolling" => update_settings(app, |s| s.sync_scrolling = !s.sync_scrolling),
        "shows_toolbar" => update_settings(app, |s| s.shows_toolbar = !s.shows_toolbar),
        "shows_line_numbers" => update_settings(app, |s| s.shows_line_numbers = !s.shows_line_numbers),
        "wraps_lines" => update_settings(app, |s| s.wraps_lines = !s.wraps_lines),
        "shows_invisibles" => update_settings(app, |s| s.shows_invisibles = !s.shows_invisibles),
        "highlights_current_line" => update_settings(app, |s| s.highlights_current_line = !s.highlights_current_line),
        "shows_status_bar" => update_settings(app, |s| s.shows_status_bar = !s.shows_status_bar),
        "zoom_in" => update_settings(app, |s| s.font_size = (s.font_size + 1.0).min(Settings::MAX_FONT_SIZE)),
        "zoom_out" => update_settings(app, |s| s.font_size = (s.font_size - 1.0).max(Settings::MIN_FONT_SIZE)),
        "zoom_reset" => update_settings(app, |s| s.font_size = Settings::DEFAULT_FONT_SIZE),
        _ => {
            if let Some(window) = focused_window(app) {
                let _ = window.emit_to(window.label(), "menu", id.to_string());
            }
        }
    }
}

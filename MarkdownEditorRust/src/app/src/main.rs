//! MarkdownEditor — the desktop shell.
//!
//! A thin Tauri layer around `mdcore`: every document window is a web view
//! running the editor front end (`ui/`), which calls the commands below for
//! everything that is not drawing — parsing, highlighting, editing commands,
//! completion, outline, exports and file I/O. Windows, menus and dialogs are
//! native on Windows, Linux and macOS.

#![cfg_attr(all(not(debug_assertions), target_os = "windows"), windows_subsystem = "windows")]

mod menu;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Mutex;

use mdcore::api::{self, CompletionSession, CompletionView, EditCommand, EditResponse, Rendered, Statistics};
use mdcore::completion::snippet::SnippetInsertion;
use mdcore::editor::Settings;
use mdcore::highlight::{Decoration, EditorContext, RenderOptions};
use mdcore::math_locator::MathFormula;
use mdcore::outline::OutlineHeading;
use mdcore::render::diagnostics::{Diagnostic, Report};
use mdcore::render::pdf::{self, Harvested};
use mdcore::text::Range;
use serde::Serialize;
use tauri::http::{Response, StatusCode};
use tauri::{AppHandle, Emitter, Manager, RunEvent, State, WebviewUrl, WebviewWindow, WebviewWindowBuilder, WindowEvent};
use tauri_plugin_clipboard_manager::ClipboardExt;
use tauri_plugin_dialog::{DialogExt, MessageDialogButtons, MessageDialogKind, MessageDialogResult};
use tauri_plugin_opener::OpenerExt;

// MARK: - State

/// What the shell knows about one document window.
#[derive(Default)]
struct WindowDoc {
    path: Option<PathBuf>,
    dirty: bool,
    /// Text to load when the window's front end asks (`window_init`).
    pending: Option<String>,
}

/// Set by Quit: exit once the last window has closed.
static QUITTING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

#[derive(Default)]
struct AppState {
    windows: Mutex<HashMap<String, WindowDoc>>,
    completions: Mutex<HashMap<String, CompletionSession>>,
    settings: Mutex<Settings>,
    counter: AtomicUsize,
}

fn settings_path() -> Option<PathBuf> {
    dirs::config_dir().map(|d| d.join("MarkdownEditor").join("settings.json"))
}

fn load_settings() -> Settings {
    settings_path()
        .and_then(|p| std::fs::read_to_string(p).ok())
        .and_then(|s| serde_json::from_str(&s).ok())
        .unwrap_or_default()
}

fn store_settings(settings: &Settings) {
    if let Some(path) = settings_path() {
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_string_pretty(settings) {
            let _ = std::fs::write(path, json);
        }
    }
}

fn err(e: impl std::fmt::Display) -> String {
    e.to_string()
}

// MARK: - Windows

/// Opens a new document window, optionally with a file.
fn open_window(app: &AppHandle, path: Option<PathBuf>, text: Option<String>) -> tauri::Result<WebviewWindow> {
    let state = app.state::<AppState>();
    let n = state.counter.fetch_add(1, Ordering::SeqCst) + 1;
    let label = format!("doc-{n}");
    state.windows.lock().unwrap().insert(label.clone(), WindowDoc { path: path.clone(), dirty: false, pending: text });
    let title = path
        .as_ref()
        .and_then(|p| p.file_name())
        .map(|n| n.to_string_lossy().into_owned())
        .unwrap_or_else(|| "Untitled".into());
    let mut builder = WebviewWindowBuilder::new(app, &label, WebviewUrl::App("index.html".into()))
        .title(title)
        .inner_size(1280.0, 840.0)
        .min_inner_size(520.0, 320.0);
    // macOS: a unified title bar. The web view draws to the top edge, the
    // toolbar doubles as the title bar (drag region, document title) and
    // the traffic lights sit centered in it.
    #[cfg(target_os = "macos")]
    {
        builder = builder
            .title_bar_style(tauri::TitleBarStyle::Overlay)
            .hidden_title(true)
            .traffic_light_position(tauri::LogicalPosition::new(18.0, 26.0));
    }
    // Cascade new windows a little.
    if n > 1 {
        let offset = ((n - 1) % 8) as f64 * 26.0;
        builder = builder.position(80.0 + offset, 60.0 + offset);
    }
    let window = builder.build()?;
    Ok(window)
}

/// The focused document window (or any, as a fallback).
fn focused_window(app: &AppHandle) -> Option<WebviewWindow> {
    let windows = app.webview_windows();
    windows
        .values()
        .find(|w| w.is_focused().unwrap_or(false))
        .cloned()
        .or_else(|| windows.values().next().cloned())
}

fn read_markdown(path: &Path) -> Result<String, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("“{}” could not be opened: {e}", path.display()))?;
    let text = String::from_utf8(bytes).map_err(|_| format!("“{}” is not a UTF-8 text file.", path.display()))?;
    // Normalize line endings: the editor works with \n.
    Ok(text.replace("\r\n", "\n"))
}

/// Opens files from the OS (Finder, command line): into the frontmost
/// window when it holds an unedited untitled document, else new windows.
fn open_paths(app: &AppHandle, paths: Vec<PathBuf>) {
    for path in paths {
        if let Some(window) = focused_window(app) {
            let replaceable = {
                let state = app.state::<AppState>();
                let windows = state.windows.lock().unwrap();
                windows.get(window.label()).is_some_and(|d| d.path.is_none() && !d.dirty)
            };
            if replaceable {
                let _ = window.emit("open-path", path.to_string_lossy().to_string());
                continue;
            }
        }
        match read_markdown(&path) {
            Ok(text) => {
                let _ = open_window(app, Some(path), Some(text));
            }
            Err(message) => {
                app.dialog().message(message).kind(MessageDialogKind::Error).show(|_| {});
            }
        }
    }
}

// MARK: - Commands: documents

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct InitPayload {
    path: Option<String>,
    text: String,
    settings: Settings,
    trigger_characters: Vec<char>,
    preview_shell: String,
    preview_css: String,
    mathjax_config: String,
    platform: &'static str,
}

#[tauri::command]
fn window_init(window: WebviewWindow, state: State<AppState>) -> InitPayload {
    let mut windows = state.windows.lock().unwrap();
    let doc = windows.entry(window.label().to_string()).or_default();
    let text = doc.pending.take().unwrap_or_default();
    InitPayload {
        path: doc.path.as_ref().map(|p| p.to_string_lossy().into_owned()),
        text,
        settings: state.settings.lock().unwrap().clone(),
        trigger_characters: api::trigger_characters(),
        preview_shell: mdcore::render::page::shell(),
        preview_css: mdcore::render::page::css(),
        mathjax_config: mdcore::render::page::MATHJAX_CONFIG.to_string(),
        platform: std::env::consts::OS,
    }
}

/// Front-end diagnostics (errors, warnings) on the terminal.
#[tauri::command]
fn log(window: WebviewWindow, level: String, message: String) {
    eprintln!("[{}] {level}: {message}", window.label());
}

#[tauri::command]
fn get_settings(state: State<AppState>) -> Settings {
    state.settings.lock().unwrap().clone()
}

#[tauri::command]
fn set_settings(app: AppHandle, state: State<AppState>, settings: Settings) {
    *state.settings.lock().unwrap() = settings.clone();
    store_settings(&settings);
    menu::sync_check_items(&app, &settings);
    let _ = app.emit("settings-changed", settings);
}

#[tauri::command]
fn reset_settings(app: AppHandle, state: State<AppState>) -> Settings {
    let settings = Settings::default();
    set_settings(app, state, settings.clone());
    settings
}

#[tauri::command]
fn set_document_state(window: WebviewWindow, state: State<AppState>, dirty: bool) {
    let mut windows = state.windows.lock().unwrap();
    let doc = windows.entry(window.label().to_string()).or_default();
    doc.dirty = dirty;
}

/// File ▸ Open…: the path the user picked.
#[tauri::command]
async fn pick_open_file(app: AppHandle) -> Option<String> {
    app.dialog()
        .file()
        .add_filter("Markdown", &["md", "markdown", "mdown", "mkd", "txt"])
        .blocking_pick_file()
        .and_then(|p| p.into_path().ok())
        .map(|p| p.to_string_lossy().into_owned())
}

#[derive(Serialize)]
struct LoadedFile {
    path: String,
    text: String,
}

/// Loads a file into the calling window (the front end decided that the
/// window's document may be replaced).
#[tauri::command]
fn load_file(window: WebviewWindow, state: State<AppState>, path: String) -> Result<LoadedFile, String> {
    let p = PathBuf::from(&path);
    let text = read_markdown(&p)?;
    let mut windows = state.windows.lock().unwrap();
    let doc = windows.entry(window.label().to_string()).or_default();
    doc.path = Some(p);
    doc.dirty = false;
    Ok(LoadedFile { path, text })
}

#[tauri::command]
fn open_in_new_window(app: AppHandle, path: Option<String>) -> Result<(), String> {
    match path {
        Some(path) => {
            let p = PathBuf::from(&path);
            let text = read_markdown(&p)?;
            open_window(&app, Some(p), Some(text)).map_err(err)?;
        }
        None => {
            open_window(&app, None, None).map_err(err)?;
        }
    }
    Ok(())
}

/// Saves `text`; asks for a location for an untitled document or Save As.
/// Returns the saved path, or `None` when the user cancelled.
#[tauri::command]
async fn save_document(
    app: AppHandle,
    window: WebviewWindow,
    state: State<'_, AppState>,
    text: String,
    save_as: bool,
) -> Result<Option<String>, String> {
    let current = state.windows.lock().unwrap().get(window.label()).and_then(|d| d.path.clone());
    let path = match (&current, save_as) {
        (Some(p), false) => p.clone(),
        _ => {
            let name = current
                .as_ref()
                .and_then(|p| p.file_name())
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_else(|| "Untitled.md".into());
            let mut dialog = app.dialog().file().add_filter("Markdown", &["md", "markdown"]).set_file_name(name);
            if let Some(dir) = current.as_ref().and_then(|p| p.parent()) {
                dialog = dialog.set_directory(dir);
            }
            match dialog.blocking_save_file().and_then(|p| p.into_path().ok()) {
                Some(p) => p,
                None => return Ok(None),
            }
        }
    };
    std::fs::write(&path, text.as_bytes()).map_err(|e| format!("“{}” could not be saved: {e}", path.display()))?;
    let mut windows = state.windows.lock().unwrap();
    let doc = windows.entry(window.label().to_string()).or_default();
    doc.path = Some(path.clone());
    doc.dirty = false;
    Ok(Some(path.to_string_lossy().into_owned()))
}

/// "Do you want to save the changes…?" — `save`, `discard` or `cancel`.
#[tauri::command]
async fn ask_save_changes(app: AppHandle, window: WebviewWindow, name: String) -> String {
    let result = app
        .dialog()
        .message("Your changes will be lost if you don’t save them.")
        .title(format!("Do you want to save the changes made to “{name}”?"))
        .kind(MessageDialogKind::Warning)
        .parent(&window)
        .buttons(MessageDialogButtons::YesNoCancelCustom("Save".into(), "Don’t Save".into(), "Cancel".into()))
        .blocking_show_with_result();
    match result {
        MessageDialogResult::Yes => "save".into(),
        MessageDialogResult::No => "discard".into(),
        MessageDialogResult::Custom(label) if label == "Save" => "save".into(),
        MessageDialogResult::Custom(label) if label.starts_with("Don") => "discard".into(),
        _ => "cancel".into(),
    }
}

#[tauri::command]
async fn show_message(app: AppHandle, window: WebviewWindow, title: String, message: String, error: bool) {
    app.dialog()
        .message(message)
        .title(title)
        .kind(if error { MessageDialogKind::Error } else { MessageDialogKind::Info })
        .parent(&window)
        .blocking_show();
}

/// Closes the calling window for real (after the front end handled unsaved
/// changes).
#[tauri::command]
fn close_window(window: WebviewWindow, state: State<AppState>) {
    state.windows.lock().unwrap().remove(window.label());
    state.completions.lock().unwrap().remove(window.label());
    let _ = window.destroy();
}

/// The user cancelled closing a window with unsaved changes: a pending
/// Quit is cancelled too.
#[tauri::command]
fn cancel_quit() {
    QUITTING.store(false, Ordering::SeqCst);
}

#[tauri::command]
fn sample_document(app: AppHandle) -> Result<(), String> {
    let path = std::env::temp_dir().join("Sample.md");
    std::fs::write(&path, mdcore::SAMPLE_MARKDOWN).map_err(err)?;
    open_paths(&app, vec![path]);
    Ok(())
}

#[tauri::command]
async fn read_clipboard_text(app: AppHandle) -> Option<String> {
    app.clipboard().read_text().ok()
}

#[tauri::command]
fn open_url(app: AppHandle, url: String) -> Result<(), String> {
    let lower = url.to_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") || lower.starts_with("mailto:") {
        app.opener().open_url(url, None::<&str>).map_err(err)?;
    }
    Ok(())
}

// MARK: - Commands: rendering and editing

#[tauri::command]
fn render_preview(text: String, image_base: Option<String>) -> Rendered {
    api::render_preview(&text, image_base.as_deref())
}

#[tauri::command]
fn preview_diagnostics(report: Report, text: String) -> Vec<Diagnostic> {
    api::preview_diagnostics(&report, &text)
}

#[tauri::command]
fn highlight(text: String, decorations: Vec<Decoration>, options: RenderOptions) -> Vec<String> {
    api::highlight_lines(&text, &decorations, &options)
}

#[tauri::command]
fn edit(state: State<AppState>, text: String, selection: Range, command: EditCommand) -> EditResponse {
    let settings = state.settings.lock().unwrap().clone();
    // A bug in a command must not take the window down: report "not
    // handled" and let the key do its default.
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| api::edit(&text, selection, &settings, command)))
        .unwrap_or_else(|_| {
            eprintln!("edit command panicked");
            EditResponse::unhandled()
        })
}

#[tauri::command]
fn context_at(text: String, location: usize) -> EditorContext {
    api::context_at(&text, location)
}

#[derive(Serialize)]
struct FormulaPayload {
    formula: MathFormula,
    tex: String,
}

#[tauri::command]
fn formula_at(text: String, location: usize) -> Option<FormulaPayload> {
    api::formula_at(&text, location).map(|(formula, tex)| FormulaPayload { formula, tex })
}

#[tauri::command]
fn outline(text: String) -> Vec<OutlineHeading> {
    api::outline(&text)
}

#[tauri::command]
fn statistics(text: String) -> Statistics {
    api::statistics(&text)
}

// MARK: - Commands: completion

fn document_path(state: &AppState, label: &str) -> Option<PathBuf> {
    state.windows.lock().unwrap().get(label).and_then(|d| d.path.clone())
}

#[tauri::command]
fn completion_open(window: WebviewWindow, state: State<AppState>, text: String, caret: usize, explicit: bool) -> Option<CompletionView> {
    let path = document_path(&state, window.label());
    let mut all = state.completions.lock().unwrap();
    all.entry(window.label().to_string()).or_default().open(&text, caret, explicit, path)
}

#[tauri::command]
fn completion_refilter(window: WebviewWindow, state: State<AppState>, text: String, caret: usize) -> Option<CompletionView> {
    let mut all = state.completions.lock().unwrap();
    all.entry(window.label().to_string()).or_default().refilter(&text, caret)
}

#[tauri::command]
fn completion_move(window: WebviewWindow, state: State<AppState>, delta: isize, wrapping: bool) -> Option<CompletionView> {
    let mut all = state.completions.lock().unwrap();
    all.entry(window.label().to_string()).or_default().move_selection(delta, wrapping)
}

#[tauri::command]
fn completion_select(window: WebviewWindow, state: State<AppState>, index: usize) -> Option<CompletionView> {
    let mut all = state.completions.lock().unwrap();
    all.entry(window.label().to_string()).or_default().select(index)
}

#[tauri::command]
fn completion_close(window: WebviewWindow, state: State<AppState>) {
    if let Some(s) = state.completions.lock().unwrap().get_mut(window.label()) {
        s.close();
    }
}

#[tauri::command]
fn completion_accept(window: WebviewWindow, state: State<AppState>, text: String, caret: usize) -> Option<SnippetInsertion> {
    let mut all = state.completions.lock().unwrap();
    all.entry(window.label().to_string()).or_default().accept(&text, caret)
}

// MARK: - Commands: export

fn base_name(state: &AppState, label: &str) -> String {
    document_path(state, label)
        .and_then(|p| p.file_stem().map(|s| s.to_string_lossy().into_owned()))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Untitled".into())
}

fn ask_export_path(app: &AppHandle, state: &AppState, label: &str, ext: &str, filter: &str) -> Option<PathBuf> {
    let mut dialog =
        app.dialog().file().add_filter(filter, &[ext]).set_file_name(format!("{}.{ext}", base_name(state, label)));
    if let Some(dir) = document_path(state, label).as_ref().and_then(|p| p.parent().map(Path::to_path_buf)) {
        dialog = dialog.set_directory(dir);
    }
    dialog.blocking_save_file().and_then(|p| p.into_path().ok())
}

/// File ▸ Export as PDF…: `mermaid` / `display_math` / `inline_math` are
/// the images harvested from the preview, in document order.
#[tauri::command]
async fn export_pdf(
    app: AppHandle,
    window: WebviewWindow,
    state: State<'_, AppState>,
    text: String,
    mermaid: Vec<Option<Harvested>>,
    display_math: Vec<Option<Harvested>>,
    inline_math: Vec<Option<Harvested>>,
) -> Result<bool, String> {
    let Some(path) = ask_export_path(&app, &state, window.label(), "pdf", "PDF") else { return Ok(false) };
    let bytes = pdf::export(&text, &mermaid, &display_math, &inline_math);
    std::fs::write(&path, bytes).map_err(|e| format!("PDF export failed: {e}"))?;
    Ok(true)
}

/// File ▸ Export as HTML…: `body` is the preview's rendered content
/// (diagrams and formulas inline as SVG).
#[tauri::command]
async fn export_html(app: AppHandle, window: WebviewWindow, state: State<'_, AppState>, body: String) -> Result<bool, String> {
    let Some(path) = ask_export_path(&app, &state, window.label(), "html", "HTML") else { return Ok(false) };
    let title = base_name(&state, window.label());
    let page = mdcore::render::page::standalone_page(&title, &body);
    std::fs::write(&path, page).map_err(|e| format!("HTML export failed: {e}"))?;
    Ok(true)
}

#[tauri::command]
fn print_window(window: WebviewWindow) -> Result<(), String> {
    window.print().map_err(err)
}

// MARK: - docfile:// (images next to the document)

fn mime_for(path: &Path) -> &'static str {
    match path.extension().and_then(|e| e.to_str()).map(|e| e.to_lowercase()).as_deref() {
        Some("png") => "image/png",
        Some("jpg" | "jpeg") => "image/jpeg",
        Some("gif") => "image/gif",
        Some("svg") => "image/svg+xml",
        Some("webp") => "image/webp",
        Some("bmp") => "image/bmp",
        Some("ico") => "image/x-icon",
        Some("avif") => "image/avif",
        Some("pdf") => "application/pdf",
        _ => "application/octet-stream",
    }
}

/// Serves files from the folder of the window's document, so relative image
/// paths work in the preview. Requests outside that folder tree are refused.
fn serve_docfile(app: &AppHandle, label: &str, uri_path: &str) -> Response<Vec<u8>> {
    let not_found = || Response::builder().status(StatusCode::NOT_FOUND).body(Vec::new()).unwrap();
    let root = {
        let state = app.state::<AppState>();
        let windows = state.windows.lock().unwrap();
        windows.get(label).and_then(|d| d.path.as_ref()).and_then(|p| p.parent().map(Path::to_path_buf))
    };
    let Some(root) = root else { return not_found() };
    let decoded = percent_encoding::percent_decode_str(uri_path.trim_start_matches('/')).decode_utf8_lossy().into_owned();
    let Ok(root) = root.canonicalize() else { return not_found() };
    let Ok(file) = root.join(decoded).canonicalize() else { return not_found() };
    if !file.starts_with(&root) {
        return Response::builder().status(StatusCode::FORBIDDEN).body(Vec::new()).unwrap();
    }
    match std::fs::read(&file) {
        Ok(bytes) => Response::builder()
            .status(StatusCode::OK)
            .header("Content-Type", mime_for(&file))
            .header("Access-Control-Allow-Origin", "*")
            .body(bytes)
            .unwrap(),
        Err(_) => not_found(),
    }
}

// MARK: - Main

fn main() {
    let settings = load_settings();
    let app = tauri::Builder::default()
        .plugin(tauri_plugin_dialog::init())
        .plugin(tauri_plugin_opener::init())
        .plugin(tauri_plugin_clipboard_manager::init())
        .manage(AppState { settings: Mutex::new(settings), ..Default::default() })
        .register_uri_scheme_protocol("docfile", |ctx, request| {
            serve_docfile(ctx.app_handle(), ctx.webview_label(), request.uri().path())
        })
        .menu(|app| menu::build(app, &load_settings()))
        .on_menu_event(|app, event| menu::handle(app, event.id().as_ref()))
        .on_window_event(|window, event| {
            if let WindowEvent::Destroyed = event {
                let app = window.app_handle();
                app.state::<AppState>().windows.lock().unwrap().remove(window.label());
                if QUITTING.load(Ordering::SeqCst) && app.webview_windows().is_empty() {
                    app.exit(0);
                }
            }
            if let WindowEvent::CloseRequested { api, .. } = event {
                let state = window.state::<AppState>();
                let dirty = state.windows.lock().unwrap().get(window.label()).is_some_and(|d| d.dirty);
                if dirty {
                    api.prevent_close();
                    let _ = window.emit_to(window.label(), "close-requested", ());
                } else {
                    state.windows.lock().unwrap().remove(window.label());
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            window_init,
            log,
            get_settings,
            set_settings,
            reset_settings,
            set_document_state,
            pick_open_file,
            load_file,
            open_in_new_window,
            save_document,
            ask_save_changes,
            show_message,
            close_window,
            cancel_quit,
            sample_document,
            read_clipboard_text,
            open_url,
            render_preview,
            preview_diagnostics,
            highlight,
            edit,
            context_at,
            formula_at,
            outline,
            statistics,
            completion_open,
            completion_refilter,
            completion_move,
            completion_select,
            completion_close,
            completion_accept,
            export_pdf,
            export_html,
            print_window,
        ])
        .setup(|app| {
            // Files passed on the command line (Windows/Linux file
            // associations, or `markdown-editor notes.md`).
            let paths: Vec<PathBuf> = std::env::args_os()
                .skip(1)
                .map(PathBuf::from)
                .filter(|p| p.is_file())
                .collect();
            let handle = app.handle().clone();
            if paths.is_empty() {
                // On macOS, files opened from Finder arrive as `Opened` events
                // right after launch; give them a moment before showing an
                // empty window.
                #[cfg(target_os = "macos")]
                {
                    std::thread::spawn(move || {
                        std::thread::sleep(std::time::Duration::from_millis(350));
                        let h = handle.clone();
                        let _ = handle.run_on_main_thread(move || {
                            if h.webview_windows().is_empty() {
                                let _ = open_window(&h, None, None);
                            }
                        });
                    });
                }
                #[cfg(not(target_os = "macos"))]
                open_window(&handle, None, None)?;
            } else {
                for path in paths {
                    match read_markdown(&path) {
                        Ok(text) => {
                            open_window(&handle, Some(path), Some(text))?;
                        }
                        Err(_) => {
                            open_window(&handle, None, None)?;
                        }
                    }
                }
            }
            Ok(())
        })
        .build(tauri::generate_context!())
        .expect("error while building MarkdownEditor");

    app.run(|app, event| match event {
        #[cfg(target_os = "macos")]
        RunEvent::Opened { urls } => {
            let paths = urls.into_iter().filter_map(|u| u.to_file_path().ok()).collect();
            open_paths(app, paths);
        }
        #[cfg(target_os = "macos")]
        RunEvent::Reopen { has_visible_windows: false, .. } => {
            let _ = open_window(app, None, None);
        }
        RunEvent::ExitRequested { api, code, .. } => {
            // Closing the last window quits on Windows/Linux; on macOS the
            // app stays in the Dock like other document apps.
            if code.is_none() && cfg!(target_os = "macos") && !QUITTING.load(Ordering::SeqCst) {
                api.prevent_exit();
            }
        }
        _ => {
            let _ = app;
        }
    });
}

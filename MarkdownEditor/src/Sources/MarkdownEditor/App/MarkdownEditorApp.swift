import AppKit
import SwiftUI

/// Brings the app to the front when launched from a terminal, where the
/// process would otherwise stay behind the terminal window.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Open… / Open Recent / Finder load into the current window.
        DocumentReplacement.install()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

@main
struct MarkdownEditorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        DocumentGroup(newDocument: { MarkdownDocument() }) { file in
            DocumentWindow(document: file.document, fileURL: file.fileURL)
        }
        .defaultSize(width: 1280, height: 840)
        .commands {
            TextEditingCommands()
            FileCommands()
            EditCommands()
            FormatCommands()
            ViewCommands()
            HelpCommands()
        }

        Settings {
            SettingsView()
        }
    }
}

/// Export and print, added to the File menu that `DocumentGroup` provides
/// (New, Open, Open Recent, Close, Save, Duplicate, Rename, Revert…).
struct FileCommands: Commands {
    @FocusedValue(\.documentSession) private var session

    var body: some Commands {
        CommandGroup(replacing: .importExport) {
            Button("Export as PDF…") {
                Task { await session?.exportPDF() }
            }
            // ⌘E stays "Use Selection for Find", as everywhere on macOS.
            .keyboardShortcut("e", modifiers: [.command, .option])
            .disabled(session == nil)

            Button("Export as HTML…") {
                Task { await session?.exportHTML() }
            }
            .keyboardShortcut("e", modifiers: [.command, .shift])
            .disabled(session == nil)
        }

        CommandGroup(replacing: .printItem) {
            Button("Print…") {
                session?.printPreview()
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(session == nil)
        }
    }
}

/// Go to Line, below Find in the Edit menu.
struct EditCommands: Commands {
    @FocusedValue(\.documentSession) private var session

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Go to Line…") {
                session?.isShowingGoToLine = true
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(session == nil)

            // ⌥⎋ is the standard "complete" key in Mac text views; ⌃Space
            // (handled by the editor) is often taken by the input-source
            // switcher, so the menu item offers the reliable one.
            Button("Show Completions") {
                session?.editor.showCompletions()
            }
            .keyboardShortcut(.escape, modifiers: .option)
            .disabled(session == nil)
        }
    }
}

/// View modes, split orientation, editor display toggles and zoom.
struct ViewCommands: Commands {
    @FocusedValue(\.documentSession) private var session
    private var settings = EditorSettings.shared

    var body: some Commands {
        CommandGroup(before: .toolbar) {
            ForEach(Array(ViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Toggle(mode.title, isOn: Binding(
                    get: { session?.viewMode == mode },
                    set: { if $0 { session?.viewMode = mode } }
                ))
                .keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option])
                .disabled(session == nil)
            }

            Picker("Split", selection: Binding(
                get: { settings.splitOrientation },
                set: { settings.splitOrientation = $0 }
            )) {
                ForEach(SplitOrientation.allCases) { Text($0.title).tag($0) }
            }

            Toggle("Synchronize Scrolling", isOn: Binding(
                get: { settings.syncScrolling },
                set: { settings.syncScrolling = $0 }
            ))

            Toggle("Show Outline", isOn: Binding(
                get: { session?.showsOutline ?? false },
                set: { session?.showsOutline = $0 }
            ))
            .keyboardShortcut("s", modifiers: [.command, .control])
            .disabled(session == nil)

            Divider()

            Toggle("Show Line Numbers", isOn: Binding(
                get: { settings.showsLineNumbers }, set: { settings.showsLineNumbers = $0 }
            ))
            Toggle("Wrap Lines", isOn: Binding(
                get: { settings.wrapsLines }, set: { settings.wrapsLines = $0 }
            ))
            Toggle("Show Invisibles", isOn: Binding(
                get: { settings.showsInvisibles }, set: { settings.showsInvisibles = $0 }
            ))
            Toggle("Highlight Current Line", isOn: Binding(
                get: { settings.highlightsCurrentLine }, set: { settings.highlightsCurrentLine = $0 }
            ))
            Toggle("Show Status Bar", isOn: Binding(
                get: { settings.showsStatusBar }, set: { settings.showsStatusBar = $0 }
            ))

            Divider()

            Button("Bigger") { settings.zoomIn() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Smaller") { settings.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("Actual Size") { settings.resetZoom() }
                .keyboardShortcut("0", modifiers: .command)

            Divider()
        }
    }
}

struct HelpCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .help) {
            Button("Open Sample Document") {
                openSample()
            }
        }
    }

    /// Opens a copy of the bundled sample, so edits never touch the bundle.
    @MainActor
    private func openSample() {
        guard let source = Bundle.resources.url(forResource: "Sample", withExtension: "md") else { return }
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Sample.md")
        try? FileManager.default.removeItem(at: copy)
        do {
            try FileManager.default.copyItem(at: source, to: copy)
        } catch {
            return
        }
        NSDocumentController.shared.openDocument(withContentsOf: copy, display: true) { _, _, _ in }
    }
}

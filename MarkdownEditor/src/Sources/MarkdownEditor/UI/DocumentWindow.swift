import SwiftUI

/// One document window: outline sidebar, editor and/or preview, status bar
/// and toolbar.
struct DocumentWindow: View {
    let document: MarkdownDocument
    let fileURL: URL?

    @Environment(\.undoManager) private var undoManager
    /// `@StateObject` because its initial value is an autoclosure evaluated
    /// once per window; `@State`'s is evaluated on every init of this view,
    /// which would build (and throw away) a whole editor and web view each
    /// time SwiftUI re-creates the struct.
    @StateObject private var holder = SessionHolder()
    private var session: DocumentSession { holder.session }
    private var settings = EditorSettings.shared

    init(document: MarkdownDocument, fileURL: URL?) {
        self.document = document
        self.fileURL = fileURL
    }

    var body: some View {
        @Bindable var session = session

        // A plain split view rather than NavigationSplitView: combined with a
        // customizable toolbar (`toolbar(id:)`), NavigationSplitView sends
        // AppKit into an endless layout loop as soon as a second document
        // window opens ("more Layout Window passes than there are views").
        HSplitView {
            if session.showsOutline {
                OutlineSidebar(session: session)
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 400)
            }
            VStack(spacing: 0) {
                panes
                if settings.showsStatusBar {
                    Divider()
                    StatusBar(session: session)
                }
            }
            .layoutPriority(1)
        }
        .frame(minWidth: 720, minHeight: 480)
        // The id is part of the key under which AppKit stores a customized
        // toolbar; it changes when the default set of items changes, so
        // existing users see the new items.
        .toolbar(id: "document.v2") {
            FileToolbar(session: session)
            FormattingToolbar(session: session)
            DocumentToolbar(session: session)
        }
        .focusedSceneValue(\.documentSession, session)
        .onAppear {
            session.attach(document: document, undoManager: undoManager, fileURL: fileURL)
        }
        .onChange(of: ObjectIdentifier(document)) {
            session.attach(document: document, undoManager: undoManager, fileURL: fileURL)
        }
        .onChange(of: fileURL) {
            session.setFileURL(fileURL)
        }
        .onChange(of: undoManager) {
            session.editor.undoManager = undoManager
        }
        .onReceive(document.$text) { text in
            session.documentTextDidChange(text)
        }
        .alert("Error", isPresented: $session.isPresentingError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage)
        }
        .sheet(isPresented: $session.isShowingGoToLine) {
            GoToLineSheet(session: session)
        }
    }

    @ViewBuilder
    private var panes: some View {
        let editor = HostedView(view: session.editor.scrollView)
            .frame(minWidth: 280, maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)
        let preview = HostedView(view: session.preview.webView)
            .frame(minWidth: 280, maxWidth: .infinity, minHeight: 160, maxHeight: .infinity)

        switch session.viewMode {
        case .editor:
            editor
        case .preview:
            preview
        case .split:
            if settings.splitOrientation == .sideBySide {
                HSplitView { editor; preview }
            } else {
                VSplitView { editor; preview }
            }
        }
    }
}

/// Keeps the window's `DocumentSession` alive for the window's lifetime.
final class SessionHolder: ObservableObject {
    let session: DocumentSession

    @MainActor init() {
        session = DocumentSession()
    }
}

/// File commands at the far left: open, save, export PDF.
struct FileToolbar: CustomizableToolbarContent {
    let session: DocumentSession

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "file.open", placement: .navigation) {
            Button {
                // Goes through DocumentReplacement: loads into this window.
                NSDocumentController.shared.openDocument(nil)
            } label: {
                Label("Open", systemImage: "folder")
            }
            .help("Open a Markdown file in this window (⌘O)")
        }

        ToolbarItem(id: "file.save", placement: .navigation) {
            Button {
                // The window's NSDocument (owned by DocumentGroup) is in the
                // responder chain; it handles Save / Save As for untitled.
                NSApp.sendAction(#selector(NSDocument.save(_:)), to: nil, from: nil)
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .help("Save the document (⌘S)")
        }

        ToolbarItem(id: "file.exportPDF", placement: .navigation) {
            Button {
                Task { await session.exportPDF() }
            } label: {
                Label("Export PDF", systemImage: "doc.text.image")
            }
            .help("Export the document as PDF (⌥⌘E)")
        }
    }
}

/// Document-level toolbar items: outline, view mode switch, HTML export.
struct DocumentToolbar: CustomizableToolbarContent {
    let session: DocumentSession

    var body: some CustomizableToolbarContent {
        ToolbarItem(id: "outline", placement: .navigation) {
            Toggle(isOn: Binding(get: { session.showsOutline }, set: { session.showsOutline = $0 })) {
                Label("Outline", systemImage: "sidebar.left")
            }
            .help("Show or hide the outline (⌃⌘S)")
        }

        ToolbarItem(id: "viewMode", placement: .primaryAction) {
            Picker("View", selection: Binding(get: { session.viewMode }, set: { session.viewMode = $0 })) {
                ForEach(ViewMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelStyle(.iconOnly)
            .help("Editor only (⌥⌘1) · Editor and preview (⌥⌘2) · Preview only (⌥⌘3)")
        }

        ToolbarItem(id: "exportHTML", placement: .primaryAction) {
            Button {
                Task { await session.exportHTML() }
            } label: {
                Label("Export HTML", systemImage: "doc.richtext")
            }
            .help("Save the preview as a standalone HTML file (⇧⌘E)")
        }

        ToolbarItem(id: "print", placement: .primaryAction, showsByDefault: false) {
            Button {
                session.printPreview()
            } label: {
                Label("Print", systemImage: "printer")
            }
            .help("Print the preview (⌘P)")
        }
    }
}

/// Caret position, counts and the diagnostic under the caret.
struct StatusBar: View {
    let session: DocumentSession

    var body: some View {
        HStack(spacing: 14) {
            if let message = session.diagnosticMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(message)
            }
            Spacer(minLength: 8)
            Text("Ln \(session.caretLine), Col \(session.caretColumn)")
                .onTapGesture { session.isShowingGoToLine = true }
                .help("Go to Line… (⌘L)")
            Text("\(session.wordCount) words")
            Text("\(session.characterCount) characters")
        }
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .frame(height: 22)
        .background(.bar)
    }
}

struct GoToLineSheet: View {
    let session: DocumentSession
    @Environment(\.dismiss) private var dismiss
    @State private var line = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Go to Line").font(.headline)
            TextField("Line number", text: $line)
                .frame(width: 220)
                .onSubmit(go)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: go)
                    .keyboardShortcut(.defaultAction)
                    .disabled(Int(line.trimmingCharacters(in: .whitespaces)) == nil)
            }
        }
        .padding(20)
        .onAppear { line = String(session.caretLine) }
    }

    private func go() {
        guard let number = Int(line.trimmingCharacters(in: .whitespaces)) else { return }
        dismiss()
        if session.viewMode == .preview { session.viewMode = .split }
        session.editor.goToLine(number)
    }
}

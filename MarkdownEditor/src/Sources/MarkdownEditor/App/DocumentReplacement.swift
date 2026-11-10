import AppKit
import ObjectiveC

/// Opens documents into the current window instead of a new one.
///
/// A classic document app gives every opened file its own window. Here,
/// File ▸ Open…, Open Recent, files handed over by Finder and files dropped on
/// the Dock icon replace the document of the frontmost window; only
/// File ▸ New creates a window.
///
/// The swap uses `NSDocument.revert(toContentsOf:ofType:)`, which reads the
/// other file into the *same* document object and window and points it at the
/// new URL — the window, its editor and its preview stay where they are.
///
/// A new window is still opened when replacing would lose work or make no
/// sense:
/// - there is no document window yet,
/// - the frontmost document is untitled and has unsaved changes (it has no
///   file to autosave into),
/// - saving the outgoing document failed.
/// A file that is already open just brings its window forward.
///
/// ## Why method swizzling
/// All of those paths end in one method,
/// `NSDocumentController.openDocument(withContentsOf:display:completionHandler:)`.
/// The usual way to change it — a `NSDocumentController` subclass created
/// before anyone asks for `.shared` — is not available: SwiftUI's
/// `DocumentGroup` installs its own private controller class first and
/// crashes at launch when it finds a different one. So the method is
/// exchanged on SwiftUI's controller class at launch instead; if that ever
/// fails, the app simply keeps the standard one-window-per-document behavior.
@MainActor
enum DocumentReplacement {
    private static var isInstalled = false

    /// Call from `applicationWillFinishLaunching`, after SwiftUI has created
    /// its document controller and before files are opened.
    static func install() {
        guard !isInstalled else { return }
        let controllerClass: AnyClass = type(of: NSDocumentController.shared)
        let originalSelector = #selector(NSDocumentController.openDocument(withContentsOf:display:completionHandler:))
        let replacementSelector = #selector(NSDocumentController.md_openDocument(withContentsOf:display:completionHandler:))
        guard let original = class_getInstanceMethod(controllerClass, originalSelector),
              let replacement = class_getInstanceMethod(NSDocumentController.self, replacementSelector)
        else { return }

        // Give the controller class its own entry for the original selector
        // (it may only inherit it), then swap: afterwards the original
        // selector runs our code and the replacement selector runs the
        // original implementation.
        if class_addMethod(controllerClass, originalSelector,
                           method_getImplementation(replacement), method_getTypeEncoding(replacement)) {
            class_replaceMethod(controllerClass, replacementSelector,
                                method_getImplementation(original), method_getTypeEncoding(original))
        } else {
            method_exchangeImplementations(original, replacement)
        }
        isInstalled = true
    }

    /// The document whose window the file should go into, or nil when a new
    /// window is the right call.
    static func replaceableDocument(in controller: NSDocumentController) -> NSDocument? {
        let document = controller.currentDocument
            ?? NSApp.mainWindow.flatMap { controller.document(for: $0) }
            ?? NSApp.orderedWindows.lazy.compactMap { controller.document(for: $0) }.first
        guard let document else { return nil }
        if document.fileURL == nil && document.isDocumentEdited {
            return nil
        }
        return document
    }

    /// Writes pending edits of a saved document to its file.
    static func saveIfNeeded(_ document: NSDocument, completion: @escaping @MainActor (Bool) -> Void) {
        guard document.isDocumentEdited, document.fileURL != nil else {
            completion(true)
            return
        }
        document.autosave(withImplicitCancellability: false) { error in
            Task { @MainActor in completion(error == nil) }
        }
    }
}

extension NSDocumentController {
    /// Exchanged with `openDocument(withContentsOf:display:completionHandler:)`
    /// by `DocumentReplacement.install()`. Inside, calling this method again
    /// runs the *original* implementation.
    @objc func md_openDocument(
        withContentsOf url: URL,
        display displayDocument: Bool,
        completionHandler: @escaping (NSDocument?, Bool, (any Error)?) -> Void
    ) {
        if let existing = document(for: url) {
            if displayDocument { existing.showWindows() }
            completionHandler(existing, true, nil)
            return
        }
        guard let target = DocumentReplacement.replaceableDocument(in: self) else {
            md_openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
            return
        }

        DocumentReplacement.saveIfNeeded(target) { [self] saved in
            guard saved else {
                // Keep the unsaved document; open the file in a new window.
                md_openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler)
                return
            }
            do {
                let type = try typeForContents(of: url)
                try target.revert(toContentsOf: url, ofType: type)
                // Undo must not step back into the previous file's text.
                target.undoManager?.removeAllActions()
                noteNewRecentDocument(target)
                if displayDocument { target.showWindows() }
                completionHandler(target, false, nil)
            } catch {
                completionHandler(nil, false, error)
            }
        }
    }
}

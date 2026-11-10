import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// John Gruber's Markdown type, as declared by most Markdown apps.
    /// Imported in `Packaging/Info.plist` so the app can open `.md` files.
    static let markdown = UTType(importedAs: "net.daringfireball.markdown", conformingTo: .plainText)
}

/// The file on disk: nothing but the Markdown source.
///
/// A `ReferenceFileDocument` (rather than a value `FileDocument`) so the
/// editor can mutate it in place; SwiftUI's `DocumentGroup` puts an
/// `NSDocument` behind it, which brings autosave, Versions, Revert, the
/// "Edited" title, tabs and Open Recent. The document counts as edited
/// whenever an undo action is registered on its undo manager — the editor
/// routes `NSTextView`'s undo into exactly that manager (see
/// `EditorController.undoManager`).
final class MarkdownDocument: ReferenceFileDocument, @unchecked Sendable {
    // `@unchecked Sendable`: `text` is only touched on the main actor, except
    // for `snapshot`, which SwiftUI also calls on the main actor; the
    // snapshot (a value) is what crosses to the background writer.

    static let readableContentTypes: [UTType] = [.markdown, .plainText]
    static let writableContentTypes: [UTType] = [.markdown]

    /// The source text as last pushed by the editor. The editor's text
    /// storage is the live copy while typing; it writes back here on every
    /// change so a save always sees the current text.
    @Published var text: String

    init(text: String = "") {
        self.text = text
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let string = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
        else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        text = string
    }

    func snapshot(contentType: UTType) throws -> String {
        text
    }

    func fileWrapper(snapshot: String, configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(snapshot.utf8))
    }
}

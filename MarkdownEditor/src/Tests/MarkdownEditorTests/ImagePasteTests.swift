import AppKit
import Testing
@testable import MarkdownEditor

@MainActor
struct ImagePasteTests {
    private let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("image-paste-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func makeEditor(documentURL: URL?) -> (EditorController, ImagePasteHandler, [String]) {
        let editor = EditorController(settings: EditorSettings(defaults: UserDefaults(suiteName: "tests-image")!))
        editor.documentURL = documentURL
        let handler = ImagePasteHandler(editor: editor)
        handler.now = { Date(timeIntervalSince1970: 1_700_000_000) }
        handler.presentMessage = { message in Issue.record("Unexpected message: \(message)") }
        return (editor, handler, [])
    }

    private func pngData() -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    private func pasteboard() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: .init("test-\(UUID())"))
        pasteboard.clearContents()
        return pasteboard
    }

    private func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func pastedImageDataIsSavedAndLinked() throws {
        let documentURL = folder.appendingPathComponent("My Notes.md")
        let (editor, handler, _) = makeEditor(documentURL: documentURL)
        editor.setText("ab")
        editor.selectedRange = NSRange(location: 1, length: 0)

        let board = pasteboard()
        board.setData(pngData(), forType: .tiff)  // screenshots arrive as TIFF too
        #expect(handler.textView(editor.textView, paste: board))

        let name = "image-\(timestamp()).png"
        let file = folder.appendingPathComponent("My Notes.assets").appendingPathComponent(name)
        #expect(FileManager.default.fileExists(atPath: file.path))
        let written = try Data(contentsOf: file)
        #expect(written.starts(with: [0x89, 0x50, 0x4E, 0x47]))
        #expect(editor.textView.string == "a![](My%20Notes.assets/\(name))b")
        // Caret between the brackets for typing the alt text.
        #expect(editor.selectedRange == NSRange(location: 3, length: 0))

        // A second paste in the same second gets a unique name.
        board.clearContents()
        board.setData(pngData(), forType: .png)
        #expect(handler.textView(editor.textView, paste: board))
        #expect(editor.textView.string.contains("image-\(timestamp())-1.png"))
    }

    @Test func plainTextIsNotConsumed() {
        let (editor, handler, _) = makeEditor(documentURL: folder.appendingPathComponent("doc.md"))
        let board = pasteboard()
        board.setString("hello", forType: .string)
        #expect(!handler.textView(editor.textView, paste: board))

        // Text plus a picture of it (Word, Excel): text wins.
        board.clearContents()
        board.setString("cell", forType: .string)
        board.setData(pngData(), forType: .png)
        #expect(!handler.textView(editor.textView, paste: board))
        #expect(editor.textView.string.isEmpty)
    }

    @Test func untitledDocumentAsksToSave() {
        let (editor, handler, _) = makeEditor(documentURL: nil)
        var messages: [String] = []
        handler.presentMessage = { messages.append($0) }
        let board = pasteboard()
        board.setData(pngData(), forType: .png)
        #expect(handler.textView(editor.textView, paste: board))
        #expect(messages == ["Save the document first to paste images"])
        #expect(editor.textView.string.isEmpty)
    }

    @Test func droppedFilesAreCopiedOrLinked() throws {
        let documentURL = folder.appendingPathComponent("docs/readme.md")
        try FileManager.default.createDirectory(at: documentURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        // Outside image: copied into the assets folder.
        let outside = folder.appendingPathComponent("photo one.png")
        try pngData().write(to: outside)
        // Inside image: linked in place.
        let inside = folder.appendingPathComponent("docs/img/logo.png")
        try FileManager.default.createDirectory(at: inside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData().write(to: inside)
        // Other file: plain link, not copied.
        let pdf = folder.appendingPathComponent("spec.pdf")
        try Data("%PDF".utf8).write(to: pdf)

        let (editor, handler, _) = makeEditor(documentURL: documentURL)
        let board = pasteboard()
        board.writeObjects([outside as NSURL, inside as NSURL, pdf as NSURL])
        #expect(handler.textView(editor.textView, drop: board, at: 0))

        #expect(editor.textView.string == """
        ![photo one](readme.assets/photo%20one.png)
        ![logo](img/logo.png)
        [spec.pdf](../spec.pdf)
        """)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("docs/readme.assets/photo one.png").path))
        #expect(!FileManager.default.fileExists(atPath: folder.appendingPathComponent("docs/readme.assets/spec.pdf").path))
    }

    @Test func pastingNonImageFilesFallsBack() throws {
        let file = folder.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: file)
        let (editor, handler, _) = makeEditor(documentURL: folder.appendingPathComponent("doc.md"))
        let board = pasteboard()
        board.writeObjects([file as NSURL])
        #expect(!handler.textView(editor.textView, paste: board))
    }

    @Test func relativePaths() {
        let base = URL(fileURLWithPath: "/Users/me/Notes")
        #expect(ImagePasteHandler.relativePath(from: base, to: URL(fileURLWithPath: "/Users/me/Notes/a.png")) == "a.png")
        #expect(ImagePasteHandler.relativePath(from: base, to: URL(fileURLWithPath: "/Users/me/Notes/sub/dir/a.png")) == "sub/dir/a.png")
        #expect(ImagePasteHandler.relativePath(from: base, to: URL(fileURLWithPath: "/Users/me/Pictures/a b.png")) == "../Pictures/a b.png")
        #expect(ImagePasteHandler.relativePath(from: base, to: URL(fileURLWithPath: "/tmp/x/y.png")) == "../../../tmp/x/y.png")
        #expect(ImagePasteHandler.markdownPath("../My Pics/a (1).png") == "../My%20Pics/a%20%281%29.png")
        #expect(ImagePasteHandler.isFile(URL(fileURLWithPath: "/Users/me/Notes/x/a.png"), inside: base))
        #expect(!ImagePasteHandler.isFile(URL(fileURLWithPath: "/Users/me/NotesOld/a.png"), inside: base))
    }
}

@MainActor
struct SettingsTests {
    @Test func resetToDefaults() {
        let defaults = UserDefaults(suiteName: "tests-settings-\(UUID())")!
        let settings = EditorSettings(defaults: defaults)
        settings.fontName = "Menlo-Regular"
        settings.fontSize = 20
        settings.tabWidth = 2
        settings.showsStatusBar = false
        settings.defaultViewMode = .preview
        settings.resetToDefaults()
        #expect(settings.fontName.isEmpty)
        #expect(settings.fontSize == EditorSettings.defaultFontSize)
        #expect(settings.tabWidth == 4)
        #expect(settings.showsStatusBar)
        #expect(settings.defaultViewMode == .split)
        // Persisted: a fresh instance reads the defaults back.
        #expect(EditorSettings(defaults: defaults).tabWidth == 4)
    }

    @Test func monospacedFontScanFindsOnlyFixedPitch() {
        let families = MonospacedFontFamily.scan()
        #expect(families.contains { $0.name == "Menlo" })
        #expect(!families.contains { $0.name == "Helvetica" })
        for family in families.prefix(5) {
            #expect(NSFont(name: family.fontName, size: 12)?.isFixedPitch == true)
        }
    }
}

import AppKit
import UniformTypeIdentifiers

/// Pasted or dropped images and files become Markdown links.
///
/// - Image *data* (a screenshot on the clipboard, an image dragged out of a
///   browser) is written as PNG into `<doc>.assets/` next to the document
///   and linked relatively. That needs a saved document.
/// - Image *files* outside the document's folder are copied into the same
///   assets folder; files already inside the folder tree are linked in
///   place, so moving the folder keeps the links working.
/// - Other dropped files get a plain `[name](path)` link, never a copy.
///
/// Plain text on the pasteboard always wins: rich sources (Word, Excel,
/// web pages) put a picture of the selection next to the text, and the
/// user wants the text.
@MainActor
final class ImagePasteHandler: EditorInputHandler {
    let priority = 40
    private weak var editor: EditorController?

    /// Shows a message to the user; a sheet on the editor's window by
    /// default. Replaceable for tests.
    var presentMessage: (String) -> Void
    /// Clock for file names; replaceable for tests.
    var now: () -> Date = Date.init

    init(editor: EditorController) {
        self.editor = editor
        presentMessage = { [weak editor] message in
            let alert = NSAlert()
            alert.messageText = message
            alert.informativeText = "Images are stored in a folder next to the document, so it needs a location."
            alert.alertStyle = .informational
            if let window = editor?.textView.window {
                alert.beginSheetModal(for: window)
            } else {
                alert.runModal()
            }
        }
    }

    // MARK: EditorInputHandler

    func textView(_ textView: MarkdownTextView, paste pasteboard: NSPasteboard) -> Bool {
        guard let editor else { return false }
        let files = Self.fileURLs(on: pasteboard)
        if !files.isEmpty {
            // Pasting files only makes sense for images; anything else falls
            // back to pasting their names as text.
            guard files.allSatisfy(Self.isImageFile) else { return false }
            return insertLinks(for: files, at: editor.selectedRange)
        }
        if pasteboard.availableType(from: [.string]) != nil { return false }
        guard let data = Self.imageData(on: pasteboard) else { return false }
        return insertImage(data, at: editor.selectedRange)
    }

    func textView(_ textView: MarkdownTextView, drop pasteboard: NSPasteboard, at location: Int) -> Bool {
        guard let editor else { return false }
        let range = NSRange(location: min(location, editor.string.length), length: 0)
        let files = Self.fileURLs(on: pasteboard)
        if !files.isEmpty {
            return insertLinks(for: files, at: range)
        }
        // Text dragged within the editor (or from elsewhere) moves as text.
        if pasteboard.availableType(from: [.string]) != nil { return false }
        guard let data = Self.imageData(on: pasteboard) else { return false }
        return insertImage(data, at: range)
    }

    // MARK: Inserting

    private func insertImage(_ data: Data, at range: NSRange) -> Bool {
        guard let editor else { return false }
        guard let documentURL = editor.documentURL else {
            presentMessage("Save the document first to paste images")
            return true
        }
        do {
            let file = try Self.writePNG(data, for: documentURL, date: now())
            let path = Self.markdownPath(Self.relativePath(from: documentURL.deletingLastPathComponent(), to: file))
            insert(images: [(alt: "", path: path)], links: [], at: range)
        } catch {
            presentMessage("The image could not be saved: \(error.localizedDescription)")
        }
        return true
    }

    private func insertLinks(for files: [URL], at range: NSRange) -> Bool {
        guard let editor else { return false }
        let documentURL = editor.documentURL
        var images: [(alt: String, path: String)] = []
        var links: [(name: String, path: String)] = []
        do {
            for file in files {
                if Self.isImageFile(file) {
                    let target = try documentURL.map { try Self.imageFileForLinking(file, documentURL: $0) } ?? file
                    images.append((Self.escapeLinkText(file.deletingPathExtension().lastPathComponent), link(to: target, from: documentURL)))
                } else {
                    links.append((file.lastPathComponent, link(to: file, from: documentURL)))
                }
            }
        } catch {
            presentMessage("The image could not be copied: \(error.localizedDescription)")
            return true
        }
        insert(images: images, links: links, at: range)
        return true
    }

    /// Relative to the document when saved, else an absolute `file://` URL.
    private func link(to file: URL, from documentURL: URL?) -> String {
        guard let documentURL else { return file.standardizedFileURL.absoluteString }
        return Self.markdownPath(Self.relativePath(from: documentURL.deletingLastPathComponent(), to: file))
    }

    /// One undoable insertion. A single image gets its alt text selected
    /// (so typing replaces it); several items go one per line with the
    /// caret after them.
    private func insert(images: [(alt: String, path: String)], links: [(name: String, path: String)], at range: NSRange) {
        guard let editor else { return }
        let items = images.map { "![\($0.alt)](\($0.path))" }
            + links.map { "[\(Self.escapeLinkText($0.name))](\($0.path))" }
        guard !items.isEmpty else { return }
        let text = items.joined(separator: "\n")
        var selection: NSRange?
        if items.count == 1, let image = images.first {
            selection = NSRange(location: range.location + 2, length: (image.alt as NSString).length)
        }
        editor.replaceCharacters(in: range, with: text, selecting: selection,
                                 actionName: images.isEmpty ? "Insert Link" : "Insert Image")
    }

    // MARK: Pasteboard

    static let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff, NSPasteboard.PasteboardType(UTType.jpeg.identifier)]

    static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        (pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    static func imageData(on pasteboard: NSPasteboard) -> Data? {
        guard let type = pasteboard.availableType(from: imageTypes) else { return nil }
        return pasteboard.data(forType: type)
    }

    static func isImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image)
    }

    // MARK: Files

    /// `<doc dir>/<doc base name>.assets`
    static func assetsFolder(for documentURL: URL) -> URL {
        let base = documentURL.deletingPathExtension().lastPathComponent
        return documentURL.deletingLastPathComponent().appendingPathComponent(base + ".assets", isDirectory: true)
    }

    /// Converts image data (PNG, TIFF, JPEG…) to PNG and writes it as
    /// `image-<yyyyMMdd-HHmmss>[-n].png` into the assets folder.
    static func writePNG(_ data: Data, for documentURL: URL, date: Date) throws -> URL {
        let png: Data
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            png = data
        } else if let rep = NSBitmapImageRep(data: data), let converted = rep.representation(using: .png, properties: [:]) {
            png = converted
        } else {
            throw CocoaError(.fileWriteInapplicableStringEncoding, userInfo: [NSLocalizedDescriptionKey: "Unsupported image data."])
        }
        let folder = assetsFolder(for: documentURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let file = uniqueURL(in: folder, base: "image-" + formatter.string(from: date), extension: "png")
        try png.write(to: file, options: .withoutOverwriting)
        return file
    }

    /// The file a link should point at: the original when it already lives
    /// in the document's folder tree, else a copy in the assets folder.
    static func imageFileForLinking(_ file: URL, documentURL: URL) throws -> URL {
        let directory = documentURL.deletingLastPathComponent()
        if isFile(file, inside: directory) { return file }
        let folder = assetsFolder(for: documentURL)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let target = uniqueURL(in: folder, base: file.deletingPathExtension().lastPathComponent, extension: file.pathExtension)
        try FileManager.default.copyItem(at: file, to: target)
        return target
    }

    /// `base.ext`, or `base-1.ext`, `base-2.ext`… whichever does not exist.
    static func uniqueURL(in folder: URL, base: String, extension ext: String) -> URL {
        func url(_ name: String) -> URL {
            ext.isEmpty ? folder.appendingPathComponent(name) : folder.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var candidate = url(base)
        var counter = 1
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = url("\(base)-\(counter)")
            counter += 1
        }
        return candidate
    }

    static func isFile(_ file: URL, inside directory: URL) -> Bool {
        let fileComponents = canonicalComponents(file)
        let directoryComponents = canonicalComponents(directory)
        return fileComponents.count > directoryComponents.count
            && Array(fileComponents.prefix(directoryComponents.count)) == directoryComponents
    }

    /// POSIX path from `directory` to `file`, with `..` for parents.
    static func relativePath(from directory: URL, to file: URL) -> String {
        let from = canonicalComponents(directory)
        let to = canonicalComponents(file)
        var common = 0
        while common < from.count, common < to.count, from[common] == to[common] { common += 1 }
        let ups = Array(repeating: "..", count: from.count - common)
        return (ups + to[common...]).joined(separator: "/")
    }

    /// Path components with symlinks resolved (`/var` → `/private/var`), so
    /// two spellings of one folder compare equal. A file that does not exist
    /// yet is resolved through its parent.
    private static func canonicalComponents(_ url: URL) -> [String] {
        let standardized = url.standardizedFileURL
        let parent = standardized.deletingLastPathComponent().resolvingSymlinksInPath()
        let resolved = FileManager.default.fileExists(atPath: standardized.path)
            ? standardized.resolvingSymlinksInPath()
            : parent.appendingPathComponent(standardized.lastPathComponent)
        return resolved.pathComponents.filter { $0 != "/" }
    }

    /// Percent-encodes what would break a Markdown link destination:
    /// spaces, parentheses, angle brackets and `%` itself.
    static func markdownPath(_ path: String) -> String {
        var result = ""
        for character in path {
            switch character {
            case "%": result += "%25"
            case " ": result += "%20"
            case "(": result += "%28"
            case ")": result += "%29"
            case "<": result += "%3C"
            case ">": result += "%3E"
            default: result.append(character)
            }
        }
        return result
    }

    private static func escapeLinkText(_ text: String) -> String {
        text.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
    }
}

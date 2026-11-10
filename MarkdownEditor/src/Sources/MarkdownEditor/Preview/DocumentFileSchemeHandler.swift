import Foundation
import UniformTypeIdentifiers
import WebKit

/// Serves files from the saved document's folder under `docfile://document/`,
/// so `![](images/a.png)` shows in the preview.
///
/// The preview page lives on the `appassets://` origin, which cannot reach
/// `file://` URLs; and pointing WebKit at the folder with file read access
/// would expose far more than the images. Instead `HtmlRenderer` rewrites
/// relative image sources onto this scheme, and the handler resolves them
/// **read-only and strictly inside** `rootDirectory`: `..` and `.` path
/// components are refused outright, and the resolved path (symlinks
/// followed) must still lie below the folder.
@MainActor
final class DocumentFileSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "docfile"
    /// What relative image sources are prefixed with.
    nonisolated static let base = "\(scheme)://document/"

    /// The document's folder; nil (untitled document) serves nothing.
    var rootDirectory: URL?

    /// The file `url` refers to, or nil when it is not a plain path inside
    /// `root`.
    nonisolated static func resolve(_ url: URL, root: URL?) -> URL? {
        guard let root, url.scheme == scheme else { return nil }
        // `url.path` is percent-decoded, so an encoded `..%2F` is split and
        // refused just like a literal one.
        let components = url.path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              !components.contains(where: { $0 == ".." || $0 == "." || $0.contains("\0") })
        else { return nil }

        var file = root
        for component in components {
            file.appendPathComponent(String(component))
        }
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        let resolved = file.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/") else { return nil }
        return resolved
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url,
              let fileURL = Self.resolve(url, root: rootDirectory),
              let data = try? Data(contentsOf: fileURL)
        else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mimeType = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        let response = URLResponse(
            url: url,
            mimeType: mimeType,
            expectedContentLength: data.count,
            textEncodingName: nil
        )
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}

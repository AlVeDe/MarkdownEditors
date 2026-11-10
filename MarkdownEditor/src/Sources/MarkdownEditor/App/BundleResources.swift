import Foundation

extension Bundle {
    /// The bundle holding the app's resources (Sample.md, mermaid.js, MathJax).
    ///
    /// SwiftPM's `Bundle.module` only looks for its resource bundle next to
    /// the executable's bundle root, which is right for `swift run` but not
    /// for the packaged `.app`: there the bundle has to live in
    /// `Contents/Resources`, because anything in the app's root breaks its
    /// code signature. Look there first, then fall back to `Bundle.module`.
    static let resources: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("MarkdownEditor_MarkdownEditor.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}

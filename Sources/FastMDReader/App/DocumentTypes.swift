import Foundation
import UniformTypeIdentifiers

/// The ONE list of file kinds this app opens itself. Three places have to agree — the open panel's
/// filter, the click-a-link handler, and `CFBundleDocumentTypes` in Info.plist — and when they
/// drift the symptom is silent (a file the panel offers opens in TextEdit instead). The first two
/// read this type; Info.plist can't, so any change here must be mirrored there in the same commit.
enum DocumentTypes {
    /// Markdown, rendered.
    static let markdownExtensions = ["md", "markdown", "mdown", "mkd", "mdtext"]

    /// Text we display verbatim (see PlainTextRenderer). Deliberately a fixed list rather than
    /// "anything that decodes as UTF-8": offering to open a .swift or .json is a promise this app
    /// doesn't keep — it has no syntax view for them, and the file's real editor is a better answer.
    static let plainTextExtensions = ["txt", "text", "csv", "tsv", "log", "conf", "cfg", "ini", "env"]

    static func opensInApp(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return markdownExtensions.contains(e) || plainTextExtensions.contains(e)
    }

    /// Content types for the Open panel's filter.
    static var openPanelTypes: [UTType] {
        var types: [UTType] = []
        if let pub = UTType("public.markdown") { types.append(pub) }
        if let md = UTType("net.daringfireball.markdown") { types.append(md) }
        types.append(contentsOf: [.plainText, .commaSeparatedText, .tabSeparatedText, .log, .text])
        // Extensions the system may not map to any of the above (.env, .conf) — added explicitly so
        // the panel doesn't grey out a file this app can genuinely open.
        types.append(contentsOf: plainTextExtensions.compactMap {
            UTType(filenameExtension: $0, conformingTo: .plainText)
        })
        return types
    }
}

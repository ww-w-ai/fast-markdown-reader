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

    /// Office formats, read-only (see invariants 22 and CLAUDE.md S4). `.rtf` was surveyed and
    /// dropped (see the roadmap's Revision 2 — AppKit's RTF reader loses structure and images
    /// outright); `.odt` gained a reader in R3, so it belongs here now.
    static let officeExtensions = ["docx", "odt"]

    static func opensInApp(_ ext: String) -> Bool {
        let e = ext.lowercased()
        return markdownExtensions.contains(e) || plainTextExtensions.contains(e) || officeExtensions.contains(e)
    }

    /// The 3-way fork every render/edit decision is made from — see `DocumentKind`.
    static func kind(forExtension ext: String) -> DocumentKind {
        let e = ext.lowercased()
        if markdownExtensions.contains(e) { return .markdown }
        if officeExtensions.contains(e) { return .office }
        return .plainText
    }

    /// The ONE place that decides which parser owns which office extension. `MarkdownDocument`'s
    /// `read(from:)` and `reloadDocument` both call this rather than hard-coding a reader —
    /// hard-coding `DocxReader` at each call site is exactly how `.odt` shipped unreachable: it was
    /// registered here and in Info.plist (making the file reachable to the APP), but every read
    /// path still said `DocxReader.read` unconditionally (nothing made the bytes reachable to
    /// `OdtReader`). An extension that's in `officeExtensions` but has no case below is a
    /// programmer error, not a malformed file — it throws rather than silently guessing Word.
    static func readOffice(_ archive: ZipArchive, extension ext: String) throws -> [OfficeBlock] {
        switch ext.lowercased() {
        case "docx": return try DocxReader.read(archive)
        case "odt": return try OdtReader.read(archive)
        default:
            throw NSError(domain: "ai.ww-w.fast-md-reader", code: 3, userInfo: [
                NSLocalizedDescriptionKey: "\".\(ext)\" is registered as an office format but has no reader.",
            ])
        }
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
        types.append(contentsOf: officeExtensions.compactMap { UTType(filenameExtension: $0) })
        return types
    }
}

/// What kind of document is open — the fork every render/edit decision is made from.
/// Replaces a bare `isPlainText` boolean, which was really "not markdown": a `.docx` satisfied it,
/// which is exactly what routed office bytes into `PlainTextRenderer` before this existed (see
/// CLAUDE.md invariant list, S4 amendment A).
enum DocumentKind {
    case markdown
    case plainText
    /// Word/ODF/RTF, rendered read-only through `Render/Office`. No `srcRange` is ever emitted for
    /// these (see the S4 audit in the roadmap) — the edit surface is gated shut by kind, not by a
    /// synthetic source range.
    case office
}

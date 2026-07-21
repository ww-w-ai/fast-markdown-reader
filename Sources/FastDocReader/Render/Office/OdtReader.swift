import Foundation
import CoreGraphics
import AppKit

/// `.odt` bytes → `[OfficeBlock]`. An ODT is a ZIP holding `content.xml` (the body, required) and
/// optionally `styles.xml` — this reader consults BOTH for `text:list-style` (bullet vs number per
/// level) and text-formatting styles, because LibreOffice sometimes defines a list style used by the
/// body in `styles.xml` rather than `content.xml`'s own `office:automatic-styles`. Sibling of
/// `DocxReader`, deliberately shaped the same way (same XML-tree approach, same error type, same
/// span-reassembly, same unresolvable-image convention) so two office readers don't diverge for no
/// reason — but the underlying markup is different enough that nothing is shared code, only shape.
enum OdtReader: OfficeDocumentReader {
    enum ReadError: Swift.Error, Equatable, LocalizedError {
        /// `content.xml` is missing from the archive. Returning an empty document here would look
        /// like a genuinely blank file — the worst failure mode for a reader — so this throws.
        case missingContentXML
        /// A required XML part did not parse (malformed XML). Named by its archive path so the
        /// error is actionable.
        case malformedXML(String)

        var errorDescription: String? {
            switch self {
            case .missingContentXML:
                return "This .odt file has no content.xml — it may be corrupt."
            case .malformedXML(let part):
                return "\"\(part)\" could not be parsed as XML."
            }
        }
    }

    /// This reader emits `.image` blocks — PARSING only. Resolving an emitted id to actual pixels
    /// (reading the archive entry, drawing a placeholder for an unresolvable one) is a later
    /// sprint's job, exactly as in `DocxReader`.
    static func read(_ archive: ZipArchive) throws -> [OfficeBlock] {
        guard archive.contains("content.xml") else { throw ReadError.missingContentXML }
        guard let contentRoot = try? buildTree(archive.data(for: "content.xml")) else {
            throw ReadError.malformedXML("content.xml")
        }
        // `styles.xml` is optional and, when present, is a SECOND place list/text styles can live
        // — a document-level style declared once and reused is exactly what a writer would do, so
        // both parts are searched and merged (content.xml wins on a name collision, since it is
        // the part the body actually renders under).
        var styleRoots = [contentRoot]
        if archive.contains("styles.xml"), let data = try? archive.data(for: "styles.xml"),
           let stylesRoot = try? buildTree(data) {
            styleRoots.append(stylesRoot)
        }
        var listStyles: [String: [Int: Bool]] = [:]
        var fontFaces: [String: String] = [:]
        var textStyleDecls: [String: TextStyleDecl] = [:]
        var paragraphStyleDecls: [String: ParagraphStyleDecl] = [:]
        var tableCellStyleDecls: [String: TableCellStyleDecl] = [:]
        var tableColumnStyleDecls: [String: TableColumnStyleDecl] = [:]
        for root in styleRoots.reversed() {
            listStyles.merge(parseListStyles(from: root)) { existing, _ in existing }
            fontFaces.merge(parseFontFaceDecls(from: root)) { existing, _ in existing }
            textStyleDecls.merge(parseTextStyleDecls(from: root, fontFaces: fontFaces)) { existing, _ in existing }
            paragraphStyleDecls.merge(parseParagraphStyleDecls(from: root)) { existing, _ in existing }
            tableCellStyleDecls.merge(parseTableCellStyleDecls(from: root)) { existing, _ in existing }
            tableColumnStyleDecls.merge(parseTableColumnStyleDecls(from: root)) { existing, _ in existing }
        }
        // Resolve every style NAME once, up front, into its final (inheritance-flattened) value —
        // every call site below keeps reading a plain `[String: TextStyle]`/`[String:
        // ResolvedParagraphStyle]`/`[String: TableCellStyle]` exactly as before this sprint, so
        // `style:parent-style-name` chains (see `resolveTextStyle`/`resolveParagraphStyle`/
        // `resolveTableCellStyle`, each cycle-guarded) are invisible to every consumer past this
        // point — resolving once here, rather than at every lookup, is also what keeps a malformed
        // document's cycle guard from doing repeated work for the same name.
        let textStyles: [String: TextStyle] = Dictionary(
            uniqueKeysWithValues: textStyleDecls.keys.map { ($0, resolveTextStyle($0, decls: textStyleDecls)) })
        let paragraphStyles: [String: ResolvedParagraphStyle] = Dictionary(
            uniqueKeysWithValues: paragraphStyleDecls.keys.map { ($0, resolveParagraphStyle($0, decls: paragraphStyleDecls)) })
        let tableCellStyles: [String: TableCellStyle] = Dictionary(
            uniqueKeysWithValues: tableCellStyleDecls.keys.map { ($0, resolveTableCellStyle($0, decls: tableCellStyleDecls)) })
        let tableColumnStyles: [String: TableColumnStyle] = Dictionary(
            uniqueKeysWithValues: tableColumnStyleDecls.keys.map { ($0, resolveTableColumnStyle($0, decls: tableColumnStyleDecls)) })
        let styles = ParsedStyles(
            listStyles: listStyles, textStyles: textStyles, paragraphStyles: paragraphStyles,
            tableCellStyles: tableCellStyles, tableColumnStyles: tableColumnStyles)
        guard let body = contentRoot.firstDescendant("office:text") else { return [] }
        // ODF footnotes AND endnotes are the SAME element (`text:note`, told apart only by
        // `text:note-class`), sitting INLINE at the citation point with the note's own marker
        // (`text:note-citation`) and full body (`text:note-body`) as children of that one element —
        // unlike docx, which keeps the body in a wholly separate part. `NoteCollector` is filled in
        // by `collectSpans`'s `text:note` case DURING the one real body walk (not a separate
        // up-front pass): when that walk meets a `text:note`, it emits the marker inline and records
        // `(marker, body)` on the collector rather than recursing into the body — that recursion
        // skip is the detachment that keeps the note's text from being spliced into the citing
        // sentence. Once the body walk finishes, the collector holds every note in citation order,
        // ready to be rendered — once, here, at the document's end.
        let notes = NoteCollector()
        let bodyBlocks = parseBody(body, styles: styles, archive: archive, notes: notes)
        let noteBlocks = buildNoteBlocks(notes.entries, styles: styles, archive: archive)
        return bodyBlocks + noteBlocks
    }

    /// The document's own default BODY paragraph size, in points — ODF states this in
    /// `style:default-style` (the family-wide fallback every paragraph without its own explicit
    /// size ultimately falls back to, family `"paragraph"`)'s `style:text-properties/fo:font-size`.
    /// A SEPARATE entry point from `read()` rather than a second return value: `read()`'s signature
    /// (`[OfficeBlock]`) is a call-site contract `DocumentTypes.readOffice`/`MarkdownDocument` depend
    /// on. Reached ONLY through `DocumentTypes.officeDefaultBodyFontSize`, never called directly by
    /// `MarkdownDocument` — see `DocumentTypes.officeReaderType`'s doc for why. `11` — the same
    /// default `OfficeTextBuilder.build` itself falls back to — is returned when the document
    /// declares no `style:default-style` at all, or one with no font size.
    static func documentDefaultBodyFontSize(_ archive: ZipArchive) -> CGFloat {
        guard archive.contains("content.xml"),
              let contentData = try? archive.data(for: "content.xml"),
              let contentRoot = try? buildTree(contentData)
        else { return 11 }
        var roots = [contentRoot]
        if archive.contains("styles.xml"), let data = try? archive.data(for: "styles.xml"),
           let stylesRoot = try? buildTree(data) {
            roots.append(stylesRoot)
        }
        // `styles.xml` is where Writer actually puts `style:default-style` in real documents — search
        // it FIRST (unlike every other style table in this file, which lets content.xml win on a
        // name collision: `style:default-style` isn't a named style two parts could disagree about,
        // there is only ever one, so "first part that declares one" is the only meaningful order).
        for root in roots.reversed() {
            if let size = parseDefaultParagraphFontSize(from: root) { return size }
        }
        return 11
    }

    // MARK: Footnotes / endnotes — text:note (told apart by text:note-class, but rendered identically)

    /// Accumulates `(marker, body)` for every `text:note` the real body walk encounters, in citation
    /// order, plus the running counter `collectSpans` falls back to when a note has no
    /// `text:note-citation` of its own (malformed — ODF requires one, but this reader never crashes
    /// on a broken document). A class, not a struct, because `collectSpans` and its callers thread
    /// it through several layers (paragraphs, list items, table cells) purely to mutate one shared
    /// list — value semantics would silently fork it at every call boundary.
    private final class NoteCollector {
        var fallbackCounter = 1
        var entries: [(marker: String, body: XMLNode)] = []
    }

    /// `text:note-citation`'s own character-data children ARE the marker Word/LibreOffice actually
    /// displays ("1", "i", …, whatever the note's numbering style produced) — read verbatim, never
    /// recomputed, so this reader never has to know footnote vs. endnote numbering schemes (unlike
    /// docx's `w:footnoteReference`, which carries no number of its own — see `DocxReader`). Missing
    /// entirely (malformed) yields an empty string, which the caller (`collectSpans`'s `text:note`
    /// case) falls back to `NoteCollector.fallbackCounter` for, rather than showing a blank marker.
    private static func noteCitationText(_ note: XMLNode) -> String {
        guard let citation = note.child("text:note-citation") else { return "" }
        return citation.children.filter { $0.name == "#text" }.map(\.text).joined()
    }

    /// Turns each note's body into ordinary blocks — reusing `parseBody` itself, since
    /// `text:note-body`'s children (`text:p`/`text:h`/`text:list`/`table:table`) are exactly the
    /// shape `office:text`'s own children are — appended in citation order at the document's end,
    /// each prefixed with the SAME marker span rendered at the citation point, so a reader can match
    /// one back to the other. See `DocxReader.collectNoteBlocks`/`prependingMarker` for the mirrored
    /// docx-side logic (kept format-specific rather than shared, per the roadmap's own call: the
    /// EXTRACTION differs per format, only the output shape is one-to-one).
    private static func buildNoteBlocks(
        _ noteEntries: [(marker: String, body: XMLNode)], styles: ParsedStyles, archive: ZipArchive
    ) -> [OfficeBlock] {
        noteEntries.flatMap { entry -> [OfficeBlock] in
            // A footnote/endnote body cannot itself contain another `text:note` in any real
            // document (ODF disallows it), so a note-body-local `NoteCollector` here only ever
            // guards against a malformed file recursing forever — it is discarded, never merged
            // back into the outer one.
            var blocks = parseBody(entry.body, styles: styles, archive: archive, notes: NoteCollector())
            let marker = Span(text: entry.marker, superscript: true)
            if let first = blocks.first, let markedFirst = prependingMarker(marker, to: first) {
                blocks[0] = markedFirst
            } else {
                // Empty note body, or one that opens with a table/image — neither has a `[Span]` to
                // splice into, so the marker becomes its own small leading paragraph instead of
                // being silently dropped.
                blocks.insert(.paragraph(spans: [marker]), at: 0)
            }
            return blocks
        }
    }

    /// Word stores a literal `w:tab` inside the note body itself, between the auto-numbered mark
    /// and the text (its own footnote-paragraph template fakes a hanging indent that way) — so a
    /// docx note body's OWN first span already starts with `"\t"`, read verbatim like any other
    /// tab in the document. ODF has no such element (its hanging indent is a paragraph-style
    /// property, not a character), and since the marker prepended here is OUR OWN construct, not
    /// something the file gave us, the number would otherwise run straight into the first word —
    /// `"1The first note body text."` reads as a typo, and a reader comparing the two formats'
    /// output would see them disagree over one document for no reason a user could point to. A
    /// synthetic tab span, plain (not superscript, not part of the marker itself), closes that gap
    /// and matches what docx already shows.
    private static let noteMarkerSeparator = Span(text: "\t")

    /// `nil` for `.table`/`.image` — there is no `[Span]` inside either to prepend into.
    private static func prependingMarker(_ marker: Span, to block: OfficeBlock) -> OfficeBlock? {
        switch block {
        case .paragraph(let spans, let rtl, let alignment, let tabStops):
            return .paragraph(spans: [marker, noteMarkerSeparator] + spans, rtl: rtl, alignment: alignment,
                              tabStops: tabStops)
        case .heading(let level, let spans, let rtl, let alignment, let tabStops):
            return .heading(level: level, spans: [marker, noteMarkerSeparator] + spans, rtl: rtl,
                            alignment: alignment, tabStops: tabStops)
        case .listItem(let level, let ordered, let spans, let itemMarker, let rtl, let alignment, let tabStops):
            return .listItem(level: level, ordered: ordered, spans: [marker, noteMarkerSeparator] + spans,
                              marker: itemMarker, rtl: rtl, alignment: alignment, tabStops: tabStops)
        case .table, .image, .unsupportedGraphic, .formula: return nil
        }
    }

    // MARK: Every style family this reader resolves, bundled for one-parameter threading

    /// Everything `parseBody`/`parseList`/`collectCellBlocks` need from `content.xml` +
    /// `styles.xml`'s style tables, already merged AND inheritance-resolved (see `read()`) — bundled
    /// into one value so adding this sprint's two NEW families (table-cell, table-column) didn't mean
    /// growing every recursive helper's parameter list by two more names apiece. `listStyles`/
    /// `textStyles`/`paragraphStyles` existed before this sprint as separate parameters; nothing about
    /// their OWN shape changed, only that they now travel together.
    private struct ParsedStyles {
        var listStyles: [String: [Int: Bool]]
        var textStyles: [String: TextStyle]
        var paragraphStyles: [String: ResolvedParagraphStyle]
        var tableCellStyles: [String: TableCellStyle]
        var tableColumnStyles: [String: TableColumnStyle]
    }

    // MARK: Text (span) styles — automatic-styles → bold/italic/underline/color/highlight/size/family

    private struct TextStyle: Equatable {
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
        var superscript = false
        var subscripted = false
        /// `Span.textColor`/`Span.highlightColor`/`Span.fontSize`/`Span.fontName` — see those fields'
        /// own doc comments in `OfficeBlock.swift` for exactly how `OfficeTextBuilder` treats each
        /// once it reaches a `Span`. `nil` means the style (after inheritance) never said — never a
        /// literal black/zero/system-default value, same "absent stays unspecified" rule every other
        /// property in this file already follows.
        var textColor: NSColor? = nil
        var highlightColor: NSColor? = nil
        var fontSize: CGFloat? = nil
        var fontName: String? = nil
    }

    /// The RAW, per-style, NOT-YET-INHERITED declaration a single `style:style` element (family
    /// `"text"`) makes — every field is an `Optional` (unlike `TextStyle`'s own `Bool`s, which default
    /// `false`) precisely so `resolveTextStyle` can tell "this style says OFF" apart from "this style
    /// says nothing, ask the parent" while walking `parent` — see `resolveTextStyle`'s doc comment.
    private struct TextStyleDecl {
        var bold: Bool? = nil
        var italic: Bool? = nil
        var underline: Bool? = nil
        var strikethrough: Bool? = nil
        var superscript: Bool? = nil
        var subscripted: Bool? = nil
        var textColor: NSColor? = nil
        var highlightColor: NSColor? = nil
        var fontSize: CGFloat? = nil
        var fontName: String? = nil
        /// `style:parent-style-name` — the style this one is based on, resolved by `resolveTextStyle`.
        var parent: String? = nil
    }

    /// Only `style:family="text"` styles are read — ODF reuses `style:style` for paragraph, table,
    /// table-cell, graphic and text styles alike, all distinguished by `style:family`; picking up
    /// the wrong family would collide names (a paragraph style and a text style can share a name).
    /// A style with no `style:text-properties` at all, or one that declares none of the
    /// properties this reader understands, is simply absent from the map — `collectSpans` reads
    /// that as "no formatting", never a crash. `fontFaces` (already merged from both parts by the
    /// time this runs — see `read()`) resolves `style:font-name`'s indirection through
    /// `office:font-face-decls`; `fo:font-family` (rarer, but legal directly on `style:text-
    /// properties`) is read as a literal name with no such indirection.
    private static func parseTextStyleDecls(from root: XMLNode, fontFaces: [String: String]) -> [String: TextStyleDecl] {
        var map: [String: TextStyleDecl] = [:]
        for styleNode in root.allDescendants("style:style") where styleNode.attributes["style:family"] == "text" {
            guard let name = styleNode.attributes["style:name"] else { continue }
            var decl = TextStyleDecl()
            decl.parent = styleNode.attributes["style:parent-style-name"]
            if let props = styleNode.child("style:text-properties") {
                if let weight = props.attributes["fo:font-weight"] { decl.bold = weight == "bold" }
                if let style = props.attributes["fo:font-style"] { decl.italic = style == "italic" }
                if let underline = props.attributes["style:text-underline-style"] { decl.underline = underline != "none" }
                if let strike = props.attributes["style:text-line-through-style"] { decl.strikethrough = strike != "none" }
                // `style:text-position` is `"<super|sub> <percentage>"` (e.g. `"super 58%"`) — only
                // the leading keyword decides which axis; the percentage is a font-scale hint this
                // viewer doesn't reproduce (same "skip presentation fidelity" call as everywhere else).
                if let position = props.attributes["style:text-position"] {
                    decl.superscript = position.hasPrefix("super")
                    decl.subscripted = position.hasPrefix("sub")
                }
                if let color = props.attributes["fo:color"] { decl.textColor = parseODFColor(color) }
                if let bg = props.attributes["fo:background-color"] { decl.highlightColor = parseODFColor(bg) }
                // `fo:font-size` is almost always an absolute length ("12pt") in a real document —
                // `parseLength` handles that. A PERCENTAGE ("150%", relative to the parent style's own
                // size) is a real, legal ODF value this reader does NOT resolve: `parseLength` has no
                // "%" suffix in its table and `Double("150%")` itself fails to parse, so it naturally
                // returns `nil` — read as "no size specified" rather than a wrong literal number. That
                // is a deliberate skip, not an oversight (see this sprint's own report).
                if let size = props.attributes["fo:font-size"] { decl.fontSize = parseLength(size) }
                if let fontName = props.attributes["style:font-name"] {
                    decl.fontName = fontFaces[fontName] ?? fontName
                } else if let family = props.attributes["fo:font-family"] {
                    decl.fontName = family
                }
            }
            map[name] = decl
        }
        return map
    }

    /// `office:font-face-decls > style:font-face` — the indirection `style:font-name` points through:
    /// a `style:text-properties/@style:font-name` is a REFERENCE (`style:font-face/@style:name`), not
    /// the literal family name itself, which lives on that SAME element's `svg:font-family`. Searched
    /// the same "anywhere below root" way every other style table in this file is, since a font-face
    /// declaration can live in either part exactly like a style can.
    private static func parseFontFaceDecls(from root: XMLNode) -> [String: String] {
        var map: [String: String] = [:]
        for face in root.allDescendants("style:font-face") {
            guard let name = face.attributes["style:name"], let family = face.attributes["svg:font-family"] else { continue }
            map[name] = family
        }
        return map
    }

    /// Resolves one text style's `style:parent-style-name` chain into a final `TextStyle` — the
    /// NEAREST declaration of each field wins (the style itself, else its parent, else its
    /// grandparent, …), exactly the way `DocxReader.resolvedOutlineLevel` walks `w:basedOn`. A name
    /// already visited during THIS walk means a cycle in a malformed document (`A` based on `B` based
    /// on `A`) — the walk stops there rather than looping forever, same guard, same reasoning. A field
    /// never declared anywhere in the chain keeps `TextStyle`'s own default (`false`/`nil`).
    private static func resolveTextStyle(_ styleName: String, decls: [String: TextStyleDecl]) -> TextStyle {
        var result = TextStyle()
        var have = (bold: false, italic: false, underline: false, strike: false, sup: false, sub: false,
                    color: false, highlight: false, size: false, font: false)
        var currentName: String? = styleName
        var visited = Set<String>()
        while let name = currentName {
            guard !visited.contains(name) else { break }
            visited.insert(name)
            guard let decl = decls[name] else { break }
            if !have.bold, let v = decl.bold { result.bold = v; have.bold = true }
            if !have.italic, let v = decl.italic { result.italic = v; have.italic = true }
            if !have.underline, let v = decl.underline { result.underline = v; have.underline = true }
            if !have.strike, let v = decl.strikethrough { result.strikethrough = v; have.strike = true }
            if !have.sup, let v = decl.superscript { result.superscript = v; have.sup = true }
            if !have.sub, let v = decl.subscripted { result.subscripted = v; have.sub = true }
            if !have.color, let v = decl.textColor { result.textColor = v; have.color = true }
            if !have.highlight, let v = decl.highlightColor { result.highlightColor = v; have.highlight = true }
            if !have.size, let v = decl.fontSize { result.fontSize = v; have.size = true }
            if !have.font, let v = decl.fontName { result.fontName = v; have.font = true }
            currentName = decl.parent
        }
        return result
    }

    // MARK: List styles — style name → (0-based level → ordered?)

    /// ODF numbers list levels 1-based (`text:level="1"` is the outermost) — converted to the
    /// 0-based nesting depth `OfficeBlock.listItem.level` already uses, so `isOrdered` never has to
    /// re-derive the offset. A level with neither a number nor a bullet child (an image-marker
    /// level, rare but legal) is simply absent, which `isOrdered` reads as unresolvable → bullet.
    private static func parseListStyles(from root: XMLNode) -> [String: [Int: Bool]] {
        var map: [String: [Int: Bool]] = [:]
        for listStyle in root.allDescendants("text:list-style") {
            guard let name = listStyle.attributes["style:name"] else { continue }
            var levels: [Int: Bool] = [:]
            for levelStyle in listStyle.children {
                guard let levelString = levelStyle.attributes["text:level"], let level = Int(levelString) else { continue }
                switch levelStyle.name {
                case "text:list-level-style-number": levels[level - 1] = true
                case "text:list-level-style-bullet": levels[level - 1] = false
                default: continue
                }
            }
            map[name] = levels
        }
        return map
    }

    /// Unresolvable input — no style name on the list at all, a style name absent from the table,
    /// or a level the style doesn't declare — defaults to unordered (a bullet), never ordered: an
    /// unstyled list is a faithful reading, a fabricated "1. 2. 3." is not (same reasoning as
    /// `DocxReader.isOrdered`).
    private static func isOrdered(styleName: String?, level: Int, listStyles: [String: [Int: Bool]]) -> Bool {
        guard let styleName, let ordered = listStyles[styleName]?[level] else { return false }
        return ordered
    }

    /// This reader never supplies `OfficeBlock.listItem`'s `marker` — every `.listItem(...)` built
    /// below leaves it at its default `nil`, an explicit decision, not an oversight: teaching an
    /// ODF list style's number-format element (`text:list-level-style-number`'s own `style:num-
    /// format`/`style:num-prefix`/`style:num-suffix`, ODF's rough equivalent of docx's `w:lvlText`)
    /// the same restart/override semantics `DocxReader` now implements is out of this sprint's
    /// scope. `OfficeTextBuilder`'s own counter-based fallback (unchanged) is what ODF lists still
    /// render through, exactly as before this sprint.

    // MARK: Paragraph styles — outline level, writing direction, alignment, tab stops

    private struct ResolvedParagraphStyle {
        var outlineLevel: Int? = nil
        var rtl = false
        var alignment: NSTextAlignment? = nil
        var tabStops: [CGFloat] = []
    }

    /// The RAW, not-yet-inherited declaration of one `style:style` element, family `"paragraph"`.
    /// `alignmentRaw` stays the FILE's literal `fo:text-align` string (`"start"`/`"end"`/`"left"`/…)
    /// through resolution — `start`/`end` can only become a real `NSTextAlignment` once the CHAIN's
    /// resolved `rtl` is known (see `resolveParagraphStyle`), so converting eagerly per-declaration
    /// would risk resolving against the wrong (this style's OWN, not yet inherited) writing mode.
    private struct ParagraphStyleDecl {
        var outlineLevel: Int? = nil
        var rtl: Bool? = nil
        var alignmentRaw: String? = nil
        var tabStops: [CGFloat] = []
        var parent: String? = nil
    }

    /// A `text:p` isn't the only way ODF marks a heading — Writer also lets a PARAGRAPH STYLE itself
    /// declare `style:default-outline-level` (an attribute directly on `style:style`, family
    /// `"paragraph"`), so a paragraph styled that way is a heading even though its element name is
    /// the plain `text:p` an ordinary paragraph uses. Only `style:family="paragraph"` styles are
    /// read, mirroring `parseTextStyleDecls`'s own family filter — `style:style` is reused across
    /// several families, and a text/graphic style can share a name with a paragraph style.
    ///
    /// `style:writing-mode` (docx's `w:bidi` equivalent) — only the literal value `"rl-tb"`
    /// (right-to-left, top-to-bottom, the value Writer's own toggle produces) reads as RTL; every
    /// other value (`lr-tb`, `tb-rl`, `page`, …) reads as an EXPLICIT "not RTL" (`false`, not
    /// unspecified — see `resolveParagraphStyle`'s `have.rtl` guard, which is why this is `Bool?` and
    /// not folded into "absent = false").
    ///
    /// `fo:text-align`/`style:tab-stops` are this sprint's own additions — read straight off
    /// `style:paragraph-properties`, the same element `style:writing-mode` already lives on.
    private static func parseParagraphStyleDecls(from root: XMLNode) -> [String: ParagraphStyleDecl] {
        var map: [String: ParagraphStyleDecl] = [:]
        for styleNode in root.allDescendants("style:style") where styleNode.attributes["style:family"] == "paragraph" {
            guard let name = styleNode.attributes["style:name"] else { continue }
            var decl = ParagraphStyleDecl()
            decl.parent = styleNode.attributes["style:parent-style-name"]
            if let levelString = styleNode.attributes["style:default-outline-level"], let level = Int(levelString) {
                decl.outlineLevel = level
            }
            if let props = styleNode.child("style:paragraph-properties") {
                if let mode = props.attributes["style:writing-mode"] { decl.rtl = mode == "rl-tb" }
                decl.alignmentRaw = props.attributes["fo:text-align"]
                if let tabStopsNode = props.child("style:tab-stops") {
                    decl.tabStops = tabStopsNode.children
                        .filter { $0.name == "style:tab-stop" }
                        .compactMap { $0.attributes["style:position"].flatMap(parseLength) }
                }
            }
            map[name] = decl
        }
        return map
    }

    /// Resolves one paragraph style's `style:parent-style-name` chain — same nearest-declaration-wins,
    /// cycle-guarded walk `resolveTextStyle` uses, just over this family's own four fields. `rtl` is
    /// resolved BEFORE `alignmentRaw` is turned into a real `NSTextAlignment`, because a `"start"`/
    /// `"end"` value can only be read against a writing direction once one is known — `resolveAlignment`
    /// (see below) is what does that conversion, called once here after the walk finishes rather than
    /// per-level during it, so it always sees the CHAIN's final resolved `rtl`, not one ancestor's own.
    private static func resolveParagraphStyle(_ styleName: String, decls: [String: ParagraphStyleDecl]) -> ResolvedParagraphStyle {
        var result = ResolvedParagraphStyle()
        var alignmentRaw: String? = nil
        var have = (outline: false, rtl: false, align: false, tabs: false)
        var currentName: String? = styleName
        var visited = Set<String>()
        while let name = currentName {
            guard !visited.contains(name) else { break }
            visited.insert(name)
            guard let decl = decls[name] else { break }
            if !have.outline, let v = decl.outlineLevel { result.outlineLevel = v; have.outline = true }
            if !have.rtl, let v = decl.rtl { result.rtl = v; have.rtl = true }
            if !have.align, let v = decl.alignmentRaw { alignmentRaw = v; have.align = true }
            if !have.tabs, !decl.tabStops.isEmpty { result.tabStops = decl.tabStops; have.tabs = true }
            currentName = decl.parent
        }
        result.alignment = resolveAlignment(alignmentRaw, rtl: result.rtl)
        return result
    }

    /// `fo:text-align`'s `"start"`/`"end"` are WRITING-DIRECTION-RELATIVE (ODF 1.3 §20.339) — which
    /// edge they mean depends on the paragraph's own base direction, exactly the way CSS's
    /// `text-align: start` does. Resolving them HERE, into a real `NSTextAlignment`, rather than
    /// passing `"start"`/`"end"` through unresolved, is what lets the result WIN over `OfficeBlock`'s
    /// own `rtl`-implies-alignment default (see its doc comment: "an EXPLICIT `alignment` always
    /// wins") — `OfficeTextBuilder` only ever sees a concrete `NSTextAlignment` or `nil`, never a
    /// direction-relative keyword it would have to reinterpret itself. `left`/`right`/`center`/
    /// `justify` are direction-independent and pass through literally; an unrecognised or absent value
    /// returns `nil` (unspecified — same "absent stays unspecified" rule as everywhere else).
    private static func resolveAlignment(_ raw: String?, rtl: Bool) -> NSTextAlignment? {
        switch raw {
        case "left": return .left
        case "right": return .right
        case "center", "centre": return .center
        case "justify": return .justified
        case "start": return rtl ? .right : .left
        case "end": return rtl ? .left : .right
        default: return nil
        }
    }

    // MARK: Table-cell styles — background, border (S15: previously unparsed family)

    private struct TableCellStyle: Equatable {
        var backgroundColor: NSColor? = nil
        var borderColor: NSColor? = nil
        var borderWidth: CGFloat? = nil
    }

    private struct TableCellStyleDecl {
        var backgroundColor: NSColor? = nil
        var borderColor: NSColor? = nil
        var borderWidth: CGFloat? = nil
        var parent: String? = nil
    }

    /// `style:family="table-cell"` — one of the two families `oss-delta-odt.md`'s audit found this
    /// reader never parsed AT ALL before this sprint (the other is `table-column`, just below). Reads
    /// straight onto `Cell.backgroundColor`/`borderColor`/`borderWidth` (`OfficeBlock.swift`'s own
    /// fields, unused by this reader until now) — see `parseODFBorder` for why only ONE side's
    /// color/width survives even though ODF can state all four independently (`Cell`'s own documented
    /// scope: one uniform border, not a four-sided model).
    private static func parseTableCellStyleDecls(from root: XMLNode) -> [String: TableCellStyleDecl] {
        var map: [String: TableCellStyleDecl] = [:]
        for styleNode in root.allDescendants("style:style") where styleNode.attributes["style:family"] == "table-cell" {
            guard let name = styleNode.attributes["style:name"] else { continue }
            var decl = TableCellStyleDecl()
            decl.parent = styleNode.attributes["style:parent-style-name"]
            if let props = styleNode.child("style:table-cell-properties") {
                if let bg = props.attributes["fo:background-color"] { decl.backgroundColor = parseODFColor(bg) }
                let border = parseODFBorder(props)
                decl.borderColor = border.color
                decl.borderWidth = border.width
            }
            map[name] = decl
        }
        return map
    }

    /// Same nearest-declaration-wins, cycle-guarded walk as `resolveTextStyle`/`resolveParagraphStyle`
    /// — a table-cell style basing itself on another via `style:parent-style-name` is legal ODF even
    /// though real documents rarely bother, so the mechanism is implemented for real rather than
    /// assumed unreachable.
    private static func resolveTableCellStyle(_ styleName: String, decls: [String: TableCellStyleDecl]) -> TableCellStyle {
        var result = TableCellStyle()
        var have = (bg: false, borderColor: false, borderWidth: false)
        var currentName: String? = styleName
        var visited = Set<String>()
        while let name = currentName {
            guard !visited.contains(name) else { break }
            visited.insert(name)
            guard let decl = decls[name] else { break }
            if !have.bg, let v = decl.backgroundColor { result.backgroundColor = v; have.bg = true }
            if !have.borderColor, let v = decl.borderColor { result.borderColor = v; have.borderColor = true }
            if !have.borderWidth, let v = decl.borderWidth { result.borderWidth = v; have.borderWidth = true }
            currentName = decl.parent
        }
        return result
    }

    // MARK: Table-column styles — declared width (S15: previously unparsed family AND element)

    private struct TableColumnStyle: Equatable {
        var width: CGFloat? = nil
    }

    private struct TableColumnStyleDecl {
        var width: CGFloat? = nil
        var parent: String? = nil
    }

    /// `style:family="table-column"` — `oss-delta-odt.md`'s audit found `table:table-column` itself
    /// (the ELEMENT, not just this style family) referenced nowhere in this file at all before this
    /// sprint; `parseColumnWidths` (below, called from `parseTable`) is the new caller that walks the
    /// element, this function resolves the style it points at.
    private static func parseTableColumnStyleDecls(from root: XMLNode) -> [String: TableColumnStyleDecl] {
        var map: [String: TableColumnStyleDecl] = [:]
        for styleNode in root.allDescendants("style:style") where styleNode.attributes["style:family"] == "table-column" {
            guard let name = styleNode.attributes["style:name"] else { continue }
            var decl = TableColumnStyleDecl()
            decl.parent = styleNode.attributes["style:parent-style-name"]
            if let width = styleNode.child("style:table-column-properties")?.attributes["style:column-width"] {
                decl.width = parseLength(width)
            }
            map[name] = decl
        }
        return map
    }

    private static func resolveTableColumnStyle(_ styleName: String, decls: [String: TableColumnStyleDecl]) -> TableColumnStyle {
        var result = TableColumnStyle()
        var currentName: String? = styleName
        var visited = Set<String>()
        while let name = currentName {
            guard !visited.contains(name) else { break }
            visited.insert(name)
            guard let decl = decls[name] else { break }
            if result.width == nil, let v = decl.width { result.width = v }
            currentName = decl.parent
        }
        return result
    }

    // MARK: Document default body size — style:default-style, family "paragraph"

    /// `style:default-style` (family `"paragraph"`) is ODF's document-wide fallback — every paragraph
    /// this reader never gave its own explicit size ultimately falls back to it. Deliberately its own
    /// small function rather than folded into `parseParagraphStyleDecls`: `style:default-style` is a
    /// SIBLING element of `style:style`, not a `style:style` node itself (no `style:family` attribute,
    /// no name, exactly one per document), so it needs its own, narrower search.
    private static func parseDefaultParagraphFontSize(from root: XMLNode) -> CGFloat? {
        guard let defaultStyle = root.allDescendants("style:default-style")
            .first(where: { $0.attributes["style:family"] == "paragraph" }),
            let sizeString = defaultStyle.child("style:text-properties")?.attributes["fo:font-size"]
        else { return nil }
        return parseLength(sizeString)
    }

    // MARK: content.xml — office:text → blocks

    /// Guards `parseBody`'s generic recursion (see the `default` case below) against a hostile
    /// file nesting wrappers arbitrarily deep — a real ODF document never approaches this, so the
    /// cap only ever bites on pathological input, where dropping the excess is the safe outcome.
    private static let maxBodyRecursionDepth = 64

    private static func parseBody(
        _ text: XMLNode, styles: ParsedStyles, archive: ZipArchive, notes: NoteCollector, depth: Int = 0
    ) -> [OfficeBlock] {
        var blocks: [OfficeBlock] = []
        for child in text.children {
            switch child.name {
            case "text:h":
                let rawLevel = Int(child.attributes["text:outline-level"] ?? "") ?? 1
                let level = min(max(rawLevel, 1), 6)
                let resolved = resolvedStyle(child.attributes["text:style-name"], styles: styles)
                blocks.append(contentsOf: paragraphLikeBlocks(
                    child, make: { .heading(level: level, spans: $0, rtl: resolved.rtl, alignment: resolved.alignment,
                                             tabStops: resolved.tabStops) },
                    styles: styles, archive: archive, notes: notes))
            case "text:p":
                // A `text:p` whose OWN paragraph style declares `style:default-outline-level` is a
                // heading too — Writer produces this shape routinely — resolved on the same 1-based
                // scale `text:outline-level` already uses, so it's clamped identically.
                let styleName = child.attributes["text:style-name"]
                let resolved = resolvedStyle(styleName, styles: styles)
                if let rawLevel = resolved.outlineLevel {
                    let level = min(max(rawLevel, 1), 6)
                    blocks.append(contentsOf: paragraphLikeBlocks(
                        child, make: { .heading(level: level, spans: $0, rtl: resolved.rtl, alignment: resolved.alignment,
                                                 tabStops: resolved.tabStops) },
                        styles: styles, archive: archive, notes: notes))
                } else {
                    blocks.append(contentsOf: paragraphLikeBlocks(
                        child, make: { .paragraph(spans: $0, rtl: resolved.rtl, alignment: resolved.alignment,
                                                   tabStops: resolved.tabStops) },
                        styles: styles, archive: archive, notes: notes))
                }
            case "text:hidden-paragraph":
                // Verified against OASIS ODF 1.3 schema (element text:hidden-paragraph):
                // text:condition is REQUIRED, text:is-hidden is OPTIONAL (text:boolean), content
                // model is mixed content (same as text:p — spans directly, no wrapped text:p
                // child). We deliberately do not evaluate text:condition (see below).
                // ODF's PARAGRAPH-level "show under a condition" field — same content model as
                // `text:p` (spec: same child elements). `text:is-hidden` is the file's OWN
                // LAST-COMPUTED display state; this reader never evaluates `text:condition`
                // itself (that would need the variable/field engine this project doesn't
                // implement). Hide ONLY on an explicit "true" — an absent or "false" attribute
                // SHOWS the content, per this project's governing rule that losing the author's
                // words is the unforgivable failure, an unknown state is not grounds to hide.
                if child.attributes["text:is-hidden"] != "true" {
                    let resolved = resolvedStyle(child.attributes["text:style-name"], styles: styles)
                    blocks.append(contentsOf: paragraphLikeBlocks(
                        child, make: { .paragraph(spans: $0, rtl: resolved.rtl, alignment: resolved.alignment,
                                                   tabStops: resolved.tabStops) },
                        styles: styles, archive: archive, notes: notes))
                }
            case "text:numbered-paragraph":
                // A single numbered/lettered paragraph carrying its OWN `text:list-id`/
                // `text:style-name`/`text:list-level` directly, with no enclosing `text:list`/
                // `text:list-item` pair (legal clause templates, DOCX→ODT converters). Its
                // `text:style-name` names a LIST style exactly like `text:list`'s own attribute —
                // reuse `isOrdered` rather than re-deriving the ordered/bullet rule. ODF's
                // `text:list-level` is 1-based; `OfficeBlock.listItem.level` is 0-based.
                let styleName = child.attributes["text:style-name"]
                let rawLevel = Int(child.attributes["text:list-level"] ?? "") ?? 1
                let level = max(rawLevel - 1, 0)
                let ordered = isOrdered(styleName: styleName, level: level, listStyles: styles.listStyles)
                for item in child.children where item.name == "text:p" {
                    // The item's OWN `text:p` style-name (paragraph formatting), not the enclosing
                    // `text:numbered-paragraph`'s (which names its LIST style, a different lookup
                    // table entirely).
                    let resolved = resolvedStyle(item.attributes["text:style-name"], styles: styles)
                    blocks.append(contentsOf: paragraphLikeBlocks(
                        item, make: { .listItem(level: level, ordered: ordered, spans: $0, rtl: resolved.rtl,
                                                 alignment: resolved.alignment, tabStops: resolved.tabStops) },
                        styles: styles, archive: archive, notes: notes))
                }
            case "text:list":
                blocks.append(contentsOf: parseList(
                    child, level: 0, inheritedStyleName: nil, styles: styles, archive: archive, notes: notes))
            case "table:table":
                blocks.append(parseTable(child, styles: styles, archive: archive, notes: notes))
            case "office:annotation", "text:tracked-changes", "text:sequence-decls", "text:variable-decls",
                 "text:user-field-decls", "office:forms", "office:scripts":
                // Deliberate exclusions — dropped ON PURPOSE, not by omission (see the permissive
                // `default` below):
                //  - `office:annotation`: review comments — out of scope by design, no comment UI.
                //  - `text:tracked-changes`: the DELETED-content stash. A deletion is a single,
                //    empty `<text:change/>` point marker inline (walked as a no-op by
                //    `collectSpans`'s permissive default), while its actual payload lives in a
                //    `<text:changed-region>` inside THIS sibling element — never inline between two
                //    markers. Excluding it is what keeps a tracked deletion from rendering as live
                //    text; now that the switch below recurses into everything else, this exclusion
                //    is LOAD-BEARING rather than an accident of a closed switch.
                //  - `text:sequence-decls` / `text:variable-decls` / `text:user-field-decls`:
                //    numbering/variable SCHEME declarations, no visible body text of their own.
                //  - `office:forms` / `office:scripts`: form-control / macro definitions, not
                //    document prose.
                continue
            default:
                // Any other wrapper this switch doesn't specifically name — `text:section`, the
                // seven index/TOC elements (`text:table-of-content`, `text:illustration-index`,
                // `text:table-index`, `text:object-index`, `text:user-index`,
                // `text:alphabetical-index`, `text:bibliography`) and their `*-source`/`*-body`
                // children, `text:page-sequence`/`text:page`, or a future ODF wrapper this reader
                // has never seen — is DESCENDED INTO rather than dropped whole, so a document built
                // entirely from templated sections/TOCs isn't silently emptied. A `*-source`
                // config child recurses too but contributes nothing (it has no `text:p`/`text:h`/
                // `text:list`/`table:table` children of its own), which is harmless, not a special
                // case to guard against.
                guard depth < maxBodyRecursionDepth else { continue }
                blocks.append(contentsOf: parseBody(child, styles: styles, archive: archive, notes: notes, depth: depth + 1))
            }
        }
        return blocks
    }

    /// One paragraph-style lookup, resolved — the same `ResolvedParagraphStyle` every `text:h`/
    /// `text:p`/`text:hidden-paragraph`/`text:numbered-paragraph`/list-item case above needs, pulled
    /// into one place so each case reads `resolved.rtl`/`resolved.alignment`/`resolved.tabStops`/
    /// `resolved.outlineLevel` instead of four separate dictionary lookups (the shape every one of
    /// those call sites had before this sprint, ONE field at a time). An absent/unresolvable style
    /// name returns the all-`nil`/`false`/empty default, exactly what the four separate lookups
    /// already returned for the same input.
    private static func resolvedStyle(_ styleName: String?, styles: ParsedStyles) -> ResolvedParagraphStyle {
        guard let styleName else { return ResolvedParagraphStyle() }
        return styles.paragraphStyles[styleName] ?? ResolvedParagraphStyle()
    }

    /// A heading or paragraph normally contributes exactly one text block, but one carrying an
    /// image contributes that text block (if it has any spans) FOLLOWED BY the image block(s), in
    /// source order — mirroring `DocxReader.parseParagraph`. A paragraph that is ONLY a picture
    /// (no spans at all — LibreOffice puts an image-only paragraph with no other text) contributes
    /// no empty text block, so callers never see a phantom `.paragraph(spans: [])` standing in for
    /// a picture.
    private static func paragraphLikeBlocks(
        _ node: XMLNode, make: ([Span]) -> OfficeBlock, styles: ParsedStyles, archive: ZipArchive, notes: NoteCollector
    ) -> [OfficeBlock] {
        let spans = collectSpans(in: node, style: TextStyle(), textStyles: styles.textStyles, notes: notes)
        let images = collectImages(in: node, archive: archive)
        let textBoxes = collectTextBoxBlocks(in: node, textStyles: styles.textStyles, notes: notes)
        var blocks: [OfficeBlock] = []
        if !(spans.isEmpty && !(images.isEmpty && textBoxes.isEmpty)) { blocks.append(make(spans)) }
        blocks.append(contentsOf: images)
        blocks.append(contentsOf: textBoxes)
        return blocks
    }

    // MARK: Lists — text:list > text:list-item > text:p, nested by nesting text:list

    /// Walks one list's items. Each item may hold ordinary paragraph content (`text:p`) and/or a
    /// nested list (`text:list`, recursing at `level + 1`) — ODF allows either or both. A nested
    /// list with no `text:style-name` of its own inherits the ENCLOSING list's style name (Writer
    /// commonly leaves it unstated for a plain continuation), rather than falling straight to
    /// unordered, which would wrongly flip a nested bullet under a numbered list to a bullet purely
    /// because the inner element omitted a redundant attribute.
    private static func parseList(
        _ list: XMLNode, level: Int, inheritedStyleName: String?, styles: ParsedStyles, archive: ZipArchive,
        notes: NoteCollector
    ) -> [OfficeBlock] {
        let styleName = list.attributes["text:style-name"] ?? inheritedStyleName
        let ordered = isOrdered(styleName: styleName, level: level, listStyles: styles.listStyles)
        var blocks: [OfficeBlock] = []
        for item in list.children where item.name == "text:list-item" {
            for child in item.children {
                switch child.name {
                case "text:p":
                    // The item's OWN paragraph style-name, not the enclosing LIST's — same
                    // distinction `text:numbered-paragraph` above draws.
                    let resolved = resolvedStyle(child.attributes["text:style-name"], styles: styles)
                    blocks.append(contentsOf: paragraphLikeBlocks(
                        child, make: { .listItem(level: level, ordered: ordered, spans: $0, rtl: resolved.rtl,
                                                  alignment: resolved.alignment, tabStops: resolved.tabStops) },
                        styles: styles, archive: archive, notes: notes))
                case "text:list":
                    blocks.append(contentsOf: parseList(
                        child, level: level + 1, inheritedStyleName: styleName, styles: styles, archive: archive,
                        notes: notes))
                default:
                    continue
                }
            }
        }
        return blocks
    }

    // MARK: Tables — table:table > table:table-row > table:table-cell

    /// `table:table-header-rows` is a WRAPPER element around the leading header rows, not a
    /// per-row flag the way docx's `w:tblHeader` is — its absence (this fixture has none) means
    /// `headerRows == 0`, never a guess of 1 (`OfficeBlock.table`'s own contract: an un-styled
    /// table is a faithful rendering, a wrongly-bolded row is not).
    private static func parseTable(_ table: XMLNode, styles: ParsedStyles, archive: ZipArchive, notes: NoteCollector) -> OfficeBlock {
        let columnWidths = parseColumnWidths(table, tableColumnStyles: styles.tableColumnStyles)
        var rows: [[Cell]] = []
        var headerRows = 0
        for child in table.children {
            switch child.name {
            case "table:table-header-rows":
                let expanded = child.children.filter { $0.name == "table:table-row" }
                    .flatMap { expandRow($0, columnWidths: columnWidths, styles: styles, archive: archive, notes: notes) }
                headerRows += expanded.count
                rows.append(contentsOf: expanded)
            case "table:table-row":
                rows.append(contentsOf: expandRow(child, columnWidths: columnWidths, styles: styles, archive: archive, notes: notes))
            default:
                continue
            }
        }
        return .table(rows: rows, headerRows: headerRows)
    }

    /// `table:table-column` — the ELEMENT `oss-delta-odt.md`'s audit found referenced nowhere in this
    /// file at all — declares one or more (via `table:number-columns-repeated`) columns' worth of
    /// declared width, IN SOURCE ORDER, as DIRECT children of `table:table` (siblings of the
    /// `table:table-row`s, not inside them). Returns one entry PER COLUMN (repeats expanded, mirroring
    /// `expandRow`'s own cell/row repeat expansion), `nil` where a column has no `table:style-name` or
    /// an unresolvable one — so the result's INDEX is a column position, directly usable by
    /// `expandRow`'s own running column counter.
    private static func parseColumnWidths(_ table: XMLNode, tableColumnStyles: [String: TableColumnStyle]) -> [CGFloat?] {
        var widths: [CGFloat?] = []
        for child in table.children where child.name == "table:table-column" {
            let width = child.attributes["table:style-name"].flatMap { tableColumnStyles[$0]?.width }
            let repeated = Int(child.attributes["table:number-columns-repeated"] ?? "") ?? 1
            widths.append(contentsOf: Array(repeating: width, count: repeated))
        }
        return widths
    }

    /// ODF collapses runs of identical adjacent cells/rows into one element carrying a
    /// `table:number-columns-repeated`/`table:number-rows-repeated` count — ignoring it silently
    /// loses columns (a 5-column table where 3 empty trailing cells were collapsed into one would
    /// come back as 3 columns). Both expansions happen here, once, rather than at every caller.
    ///
    /// `table:covered-table-cell` is ODF's OWN merge convention — the opposite of docx's `vMerge`
    /// (research-odt.md §1): the ORIGIN cell of a merge carries `table:number-columns-spanned` /
    /// `table:number-rows-spanned` directly, and EVERY covered position (horizontal or vertical)
    /// gets an explicit `<table:covered-table-cell/>` placeholder in that row's own XML — there is
    /// no cross-row bookkeeping to do, each row already states its own covered positions. Dropping
    /// those placeholders (contributing zero `Cell`s) is therefore correct on its own: what's left
    /// is exactly `OfficeBlock.table`'s anchor-only shape, spans/repeats notwithstanding.
    ///
    /// `columnWidths` (this sprint's own addition) is read positionally — a running `columnIndex`
    /// starts at 0 for the row and advances past EVERY column a cell (or a dropped covered-cell)
    /// occupies, so an anchor's OWN width comes from `columnWidths[columnIndex]` at the moment it's
    /// reached, before the index advances past it. A `table:covered-table-cell` still advances the
    /// index by its own (possibly repeated) column count even though it contributes no `Cell` —
    /// skipping that would misalign every width to its right.
    private static func expandRow(_ row: XMLNode, columnWidths: [CGFloat?], styles: ParsedStyles, archive: ZipArchive,
                                   notes: NoteCollector) -> [[Cell]] {
        let rowRepeat = Int(row.attributes["table:number-rows-repeated"] ?? "") ?? 1
        var cells: [Cell] = []
        var columnIndex = 0
        for child in row.children {
            switch child.name {
            case "table:table-cell":
                let blocks = collectCellBlocks(child, styles: styles, archive: archive, notes: notes)
                let rowSpan = Int(child.attributes["table:number-rows-spanned"] ?? "") ?? 1
                let colSpan = Int(child.attributes["table:number-columns-spanned"] ?? "") ?? 1
                let colRepeat = Int(child.attributes["table:number-columns-repeated"] ?? "") ?? 1
                let cellStyle = child.attributes["table:style-name"].flatMap { styles.tableCellStyles[$0] }
                // Each REPEAT instance advances the column index by exactly ONE — its own start
                // column — never by `colSpan`: the ADDITIONAL columns a span covers are accounted
                // for by the `table:covered-table-cell` element(s) that follow it in THIS row (see
                // the `case` below), not by this cell's own element. Advancing by `colSpan` here
                // would double-count those columns once more when the covered-cell(s) are reached,
                // shifting every width to the right of a horizontal merge by one column too many
                // (caught by `testColumnWidthAlignsCorrectlyAcrossAColumnSpan`'s own mutation check).
                for _ in 0..<colRepeat {
                    let width = columnIndex < columnWidths.count ? columnWidths[columnIndex] : nil
                    cells.append(Cell(
                        blocks: blocks, rowSpan: rowSpan, colSpan: colSpan, backgroundColor: cellStyle?.backgroundColor,
                        borderColor: cellStyle?.borderColor, borderWidth: cellStyle?.borderWidth, width: width))
                    columnIndex += 1
                }
            case "table:covered-table-cell":
                // Contributes no `Cell` (see the doc comment above) but still occupies its own
                // column position(s) — whether it is standing in for the REST of a horizontal span
                // (same row as its anchor) or for a vertical span's continuation (a later row, no
                // anchor of its own in THIS row at all), it is exactly one more column than the
                // element itself would otherwise account for — the running index must still move
                // past it, once per repeat.
                let repeated = Int(child.attributes["table:number-columns-repeated"] ?? "") ?? 1
                columnIndex += repeated
            default:
                continue
            }
        }
        return Array(repeating: cells, count: rowRepeat)
    }

    /// A text/heading/list block with no spans at all — used only to filter a cell's OWN
    /// placeholder-empty paragraph (`<text:p/>`, the shape a genuinely blank cell always carries)
    /// out of what it contributes; an image or table block is never "empty" in this sense and
    /// always passes through. Mirrors `DocxReader.isEmptyTextBlock` exactly.
    private static func isEmptyTextBlock(_ block: OfficeBlock) -> Bool {
        switch block {
        case .paragraph(let spans, _, _, _), .heading(_, let spans, _, _, _), .listItem(_, _, let spans, _, _, _, _):
            return spans.isEmpty
        case .table, .image, .unsupportedGraphic, .formula:
            return false
        }
    }

    /// A cell's content, built from the SAME per-block classification `parseBody` gives the
    /// document — a paragraph, a heading, a list item, an image — via `paragraphLikeBlocks`/
    /// `parseList`, rather than a second, cell-only walk that only ever knew how to collect plain
    /// text. This is what closes gap-list rows 6 and 7: before this sprint a cell held nothing but
    /// `[Span]`, so an image or a bulleted/numbered list inside a `<table:table-cell>` had nowhere
    /// to go and was silently skipped.
    ///
    /// ODT has no per-numId counter STATE to decide a scope for (unlike `DocxReader`'s
    /// `ListNumberingState`) — `isOrdered` is a pure function of a list style's name/level, and this
    /// reader never resolves real marker TEXT for an ODF list (`OfficeBlock.listItem.marker` stays
    /// `nil` here exactly as it does in the body, see the note above `isOrdered`); `OfficeTextBuilder`
    /// counts a cell's list items the same way it already counts the body's, so nothing extra is
    /// threaded through here for numbering to "continue" — there is no reader-level counter to share.
    ///
    /// A nested `<table:table>` is still FLATTENED to a single `.paragraph` of spans
    /// (`flattenNestedTable`/`collectCellSpans`, unchanged), never a real nested `.table` block — the
    /// same depth-1 shortcut the body's own top-level table already uses, and this sprint's brief is
    /// explicit that it must not change. An empty paragraph is filtered with the SAME
    /// `isEmptyTextBlock` check above: a truly empty cell must produce no block at all, never a
    /// phantom `.paragraph(spans: [])` standing in for "nothing here".
    private static func collectCellBlocks(_ cell: XMLNode, styles: ParsedStyles, archive: ZipArchive, notes: NoteCollector) -> [OfficeBlock] {
        var blocks: [OfficeBlock] = []
        for child in cell.children {
            switch child.name {
            case "text:h":
                let rawLevel = Int(child.attributes["text:outline-level"] ?? "") ?? 1
                let level = min(max(rawLevel, 1), 6)
                let resolved = resolvedStyle(child.attributes["text:style-name"], styles: styles)
                blocks.append(contentsOf: paragraphLikeBlocks(
                    child, make: { .heading(level: level, spans: $0, rtl: resolved.rtl, alignment: resolved.alignment,
                                             tabStops: resolved.tabStops) },
                    styles: styles, archive: archive, notes: notes))
            case "text:p":
                let styleName = child.attributes["text:style-name"]
                let resolved = resolvedStyle(styleName, styles: styles)
                if let rawLevel = resolved.outlineLevel {
                    let level = min(max(rawLevel, 1), 6)
                    blocks.append(contentsOf: paragraphLikeBlocks(
                        child, make: { .heading(level: level, spans: $0, rtl: resolved.rtl, alignment: resolved.alignment,
                                                 tabStops: resolved.tabStops) },
                        styles: styles, archive: archive, notes: notes))
                } else {
                    blocks.append(contentsOf: paragraphLikeBlocks(
                        child, make: { .paragraph(spans: $0, rtl: resolved.rtl, alignment: resolved.alignment,
                                                   tabStops: resolved.tabStops) },
                        styles: styles, archive: archive, notes: notes))
                }
            case "text:list":
                blocks.append(contentsOf: parseList(
                    child, level: 0, inheritedStyleName: nil, styles: styles, archive: archive, notes: notes))
            case "table:table":
                let spans = flattenNestedTable(child, textStyles: styles.textStyles, notes: notes)
                if !spans.isEmpty { blocks.append(.paragraph(spans: spans)) }
            default:
                continue
            }
        }
        return blocks.filter { !isEmptyTextBlock($0) }
    }

    /// A cell's content as plain spans, no block structure — used ONLY by `flattenNestedTable`,
    /// which deliberately squashes a nested table's grid down to text (`Cell` has no room for a
    /// second, real nested `.table` block). `collectCellBlocks` above is what a table's OWN cells
    /// go through now; this stays exactly as it was for the flatten-only path.
    private static func collectCellSpans(_ cell: XMLNode, textStyles: [String: TextStyle], notes: NoteCollector) -> [Span] {
        var spans: [Span] = []
        for child in cell.children {
            switch child.name {
            case "text:p", "text:h":
                spans.append(contentsOf: collectSpans(in: child, style: TextStyle(), textStyles: textStyles, notes: notes))
            case "table:table":
                spans.append(contentsOf: flattenNestedTable(child, textStyles: textStyles, notes: notes))
            default:
                continue
            }
        }
        return spans
    }

    /// Flattens a nested table's cells into one run of spans — a tab between cells, a newline after
    /// each non-empty row — so a reader glancing at the flattened text can still tell where one cell
    /// ended and the next began, even though the grid itself is gone. Recurses through
    /// `collectCellSpans`, so a table nested inside a nested table also survives (no depth cap is
    /// enforced; real documents don't go more than one or two levels, per the research survey).
    private static func flattenNestedTable(_ table: XMLNode, textStyles: [String: TextStyle], notes: NoteCollector) -> [Span] {
        let rows = table.children.flatMap { node -> [XMLNode] in
            if node.name == "table:table-header-rows" { return node.children.filter { $0.name == "table:table-row" } }
            if node.name == "table:table-row" { return [node] }
            return []
        }
        var spans: [Span] = []
        for row in rows {
            var rowHasContent = false
            for cell in row.children where cell.name == "table:table-cell" {
                let cellSpans = collectCellSpans(cell, textStyles: textStyles, notes: notes)
                guard !cellSpans.isEmpty else { continue }
                if rowHasContent { spans.append(Span(text: "\t")) }
                spans.append(contentsOf: cellSpans)
                rowHasContent = true
            }
            if rowHasContent { spans.append(Span(text: "\n")) }
        }
        return spans
    }

    // MARK: Images — draw:frame > draw:image

    /// `svg:width`/`svg:height` on the FRAME (not the image) is the declared, authoritative drawn
    /// size — same reasoning as amendment D in the roadmap: a raster placed at a given frame size
    /// is displayed there regardless of its pixel dimensions. Every `draw:frame` with a
    /// `draw:image` child anywhere below `node` is collected, not just a direct child, since a
    /// frame can itself be wrapped (e.g. inside `draw:text-box`) — mirrors `DocxReader`'s
    /// `allDescendants("a:blip")` walk for the same reason: an image must never be dropped just
    /// because of an intermediate wrapper this reader doesn't specifically name.
    private static func collectImages(in node: XMLNode, archive: ZipArchive) -> [OfficeBlock] {
        var frames: [XMLNode] = []
        // A hand-rolled walk, not `allDescendants("draw:frame")` — a `text:note` sitting inside this
        // paragraph (the citation) carries its OWN body, parsed and rendered separately by
        // `buildNoteBlocks`; searching blindly into it here would pull an image that belongs to the
        // FOOTNOTE into the citing paragraph's own image list, duplicating it in the wrong place.
        func walk(_ node: XMLNode) {
            for child in node.children {
                if child.name == "text:note" { continue }
                if child.name == "draw:frame" { frames.append(child) }
                walk(child)
            }
        }
        walk(node)
        return frames.compactMap { frame in
            guard let image = frame.child("draw:image") else { return nil }
            let width = frame.attributes["svg:width"].flatMap(parseLength)
            let height = frame.attributes["svg:height"].flatMap(parseLength)
            let size = CGSize(width: width ?? unresolvedFrameSize.width, height: height ?? unresolvedFrameSize.height)
            return .image(id: resolveImageId(href: image.attributes["xlink:href"], archive: archive), size: size)
        }
    }

    /// A `draw:frame` wrapping a `draw:text-box` (and carrying no `draw:image` — that combination
    /// is an ordinary picture, handled by `collectImages`) contributes its own text-box content
    /// instead of nothing. Mirrors `DocxReader.textBoxBlocks`'s scope exactly, per this project's
    /// own rule that the two readers stay parallel rather than diverging for no reason: only the
    /// text box's own `text:p`/`text:h` paragraphs (no nested lists/tables — docx's fallback never
    /// chased those either), with an empty one (LibreOffice leaves a placeholder paragraph in an
    /// otherwise-untyped shape) dropped rather than shown as a phantom blank line.
    private static func collectTextBoxBlocks(
        in node: XMLNode, textStyles: [String: TextStyle], notes: NoteCollector
    ) -> [OfficeBlock] {
        var textBoxes: [XMLNode] = []
        func walk(_ node: XMLNode) {
            for child in node.children {
                if child.name == "text:note" { continue } // belongs to the footnote, not this paragraph
                if child.name == "draw:frame", child.child("draw:image") == nil,
                   let textBox = child.child("draw:text-box") {
                    textBoxes.append(textBox)
                    continue // don't also descend into the text box's own contents from here
                }
                walk(child)
            }
        }
        walk(node)
        var blocks: [OfficeBlock] = []
        for textBox in textBoxes {
            for child in textBox.children {
                switch child.name {
                case "text:h":
                    let rawLevel = Int(child.attributes["text:outline-level"] ?? "") ?? 1
                    let level = min(max(rawLevel, 1), 6)
                    let spans = collectSpans(in: child, style: TextStyle(), textStyles: textStyles, notes: notes)
                    guard !spans.isEmpty else { continue }
                    blocks.append(.heading(level: level, spans: spans))
                case "text:p":
                    let spans = collectSpans(in: child, style: TextStyle(), textStyles: textStyles, notes: notes)
                    guard !spans.isEmpty else { continue }
                    blocks.append(.paragraph(spans: spans))
                default:
                    continue
                }
            }
        }
        return blocks
    }

    /// A best-defensible non-zero fallback for a frame whose `svg:width`/`svg:height` is missing or
    /// doesn't parse — invariant 1 applies here exactly as it does to `DocxReader`'s VML fallback:
    /// never reserve a zero/collapsed area.
    private static let unresolvedFrameSize = CGSize(width: 72, height: 72)

    /// An `xlink:href` resolves to the archive entry path when it names a real entry (the ordinary
    /// case: `"Pictures/…"`, an embedded image) — anything else this reader can't hand pixels for
    /// (no href at all, or a linked/external href that never was extracted into the archive, e.g.
    /// an absolute `file:///…`) resolves to a clearly-marked, non-archive-shaped id. Mirrors
    /// `DocxReader.resolveId`, prefixed `"odt-"` rather than `"docx-"` since the two formats'
    /// unresolvable ids are never compared against each other — only ever matched by prefix within
    /// their own reader's caller.
    private static func resolveImageId(href: String?, archive: ZipArchive) -> String {
        guard let href else { return unresolvableId("no-href") }
        guard archive.contains(href) else { return unresolvableId(href) }
        return href
    }

    private static func unresolvableId(_ reason: String) -> String { "odt-unresolvable:\(reason)" }

    /// A CSS-like length (`"7.938cm"`, `"1in"`, a bare `"72"`) → points. Longest-suffix-first is
    /// unnecessary here (no unit is a prefix of another), kept in a table for the same
    /// self-evident-order-independence reason as `DocxReader.parseCSSLikeLength`. A bare number
    /// (no unit) is treated as points, ODF's own convention for `style:*-margin`/similar unmarked
    /// lengths elsewhere in the format.
    private static func parseLength(_ raw: String) -> CGFloat? {
        let pointsPerUnit: [(suffix: String, factor: Double)] = [
            ("cm", 72 / 2.54), ("mm", 72 / 25.4), ("in", 72), ("pc", 12), ("pt", 1), ("px", 0.75),
        ]
        for (suffix, factor) in pointsPerUnit where raw.hasSuffix(suffix) {
            guard let number = Double(raw.dropLast(suffix.count)) else { return nil }
            return CGFloat(number * factor)
        }
        guard let number = Double(raw) else { return nil }
        return CGFloat(number)
    }

    /// ODF's `color` datatype (`fo:color`, `fo:background-color`'s non-`"transparent"` form) is
    /// ALWAYS `"#RRGGBB"` — never a CSS colour name, never `0x`-prefixed, never carrying alpha (ODF
    /// 1.3 §18.3.2). `"transparent"` — `fo:background-color`'s other legal value, meaning "no
    /// highlight" — returns `nil`, exactly like an absent attribute, never black: see `Span
    /// .highlightColor`'s own doc for why "no mark" must never become a literal colour.
    private static func parseODFColor(_ raw: String) -> NSColor? {
        guard raw != "transparent", raw.hasPrefix("#"), raw.count == 7, let value = UInt32(raw.dropFirst(), radix: 16)
        else { return nil }
        return NSColor(
            deviceRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// ODF's border shorthand is `"<width-length> <line-style> <color>"` (e.g. `"0.06pt solid
    /// #000000"`, the same three-token shape CSS borders use) — `fo:border` sets all four sides at
    /// once, `fo:border-top`/`-bottom`/`-left`/`-right` set one side each. `Cell`'s own vocabulary is
    /// ONE uniform colour/width, not a real four-sided model (`OfficeBlock.swift`'s own doc comment on
    /// `Cell.borderColor`/`borderWidth`), so the first side declared wins — `fo:border` is checked
    /// first (the common, symmetric case), then each individual side, so an asymmetric border (only
    /// `fo:border-top` set, no `fo:border` shorthand) still contributes something rather than nothing.
    /// The middle token being `"none"`/`"hidden"` means no border on that side, read the same as the
    /// attribute being absent entirely.
    private static func parseODFBorder(_ props: XMLNode) -> (color: NSColor?, width: CGFloat?) {
        for key in ["fo:border", "fo:border-top", "fo:border-bottom", "fo:border-left", "fo:border-right"] {
            guard let raw = props.attributes[key] else { continue }
            let tokens = raw.split(separator: " ").map(String.init)
            if tokens.count >= 2, tokens[1] == "none" || tokens[1] == "hidden" { continue }
            let width = tokens.first.flatMap(parseLength)
            let color = tokens.last.flatMap(parseODFColor)
            if width != nil || color != nil { return (color, width) }
        }
        return (nil, nil)
    }

    // MARK: Spans — text:span/text:a/text:s/text:tab/text:line-break, in document order

    /// Walks `node`'s children strictly in document order (see `XMLNode`/`#text` below — unlike a
    /// plain "attributes + children" tree, character data is threaded in as ordered pseudo-children
    /// so `"before "` / `<text:span>bold</text:span>` / `" after"` reassemble in the right order,
    /// which a tree that only concatenates trailing text per element cannot do). `style` is the
    /// formatting in effect for any bare text reached at this level; a `text:span` resolves ITS
    /// OWN style from `text:style-name` (falling back to the inherited `style` when the name is
    /// absent or unresolvable — text is never dropped for want of a style) and passes that down to
    /// its own children, so nesting narrows rather than resets formatting. `link` is threaded
    /// alongside but separately from `style`, because a hyperlink target comes from `text:a`'s own
    /// `xlink:href` attribute, not from any named style — it narrows the same way (a `text:a` with
    /// no `xlink:href` at all just carries the enclosing link, if any, rather than losing it).
    private static func collectSpans(
        in node: XMLNode, style: TextStyle, textStyles: [String: TextStyle], notes: NoteCollector
    ) -> [Span] {
        var spans: [Span] = []
        // Same role as `DocxReader.collectSpans`'s `pendingBookmarks`: names collected from
        // `text:bookmark`/`text:bookmark-start` since the last span, attached to the next real
        // content. ODF has no known equivalent of Word's auto-inserted `_GoBack`, so nothing is
        // filtered here.
        var pendingBookmarks: [String] = []
        func appendMerging(_ text: String, _ style: TextStyle, _ link: String?) {
            guard !text.isEmpty else { return }
            var bookmarks: [String] = []
            if !pendingBookmarks.isEmpty {
                bookmarks = pendingBookmarks
                pendingBookmarks = []
            }
            guard bookmarks.isEmpty else {
                spans.append(Span(
                    text: text, bold: style.bold, italic: style.italic, underline: style.underline, link: link,
                    strikethrough: style.strikethrough, superscript: style.superscript, subscripted: style.subscripted,
                    bookmarks: bookmarks, textColor: style.textColor, highlightColor: style.highlightColor,
                    fontSize: style.fontSize, fontName: style.fontName))
                return
            }
            // A bookmarked span is never EXTENDED by trailing text either — see the matching guard
            // in `DocxReader.collectSpans`. `textColor`/`highlightColor`/`fontSize`/`fontName` (this
            // sprint's own additions) join the same equality check — two runs that only differ in,
            // say, colour must stay two separate `Span`s, or the second run's colour would silently
            // win for the whole merged range.
            if let last = spans.last, last.bookmarks.isEmpty, last.bold == style.bold, last.italic == style.italic, last.underline == style.underline,
               last.strikethrough == style.strikethrough, last.superscript == style.superscript,
               last.subscripted == style.subscripted, last.link == link, last.textColor == style.textColor,
               last.highlightColor == style.highlightColor, last.fontSize == style.fontSize, last.fontName == style.fontName {
                spans[spans.count - 1].text += text
            } else {
                spans.append(Span(
                    text: text, bold: style.bold, italic: style.italic, underline: style.underline, link: link,
                    strikethrough: style.strikethrough, superscript: style.superscript, subscripted: style.subscripted,
                    textColor: style.textColor, highlightColor: style.highlightColor, fontSize: style.fontSize,
                    fontName: style.fontName))
            }
        }
        func walk(_ node: XMLNode, style: TextStyle, link: String?) {
            for child in node.children {
                switch child.name {
                case "#text":
                    appendMerging(child.text, style, link)
                case "text:span":
                    let childStyle = child.attributes["text:style-name"].flatMap { textStyles[$0] } ?? style
                    walk(child, style: childStyle, link: link)
                case "text:a":
                    let href = child.attributes["xlink:href"] ?? link
                    walk(child, style: style, link: href)
                case "text:s":
                    let count = child.attributes["text:c"].flatMap(Int.init) ?? 1
                    appendMerging(String(repeating: " ", count: count), style, link)
                case "text:tab":
                    appendMerging("\t", style, link)
                case "text:line-break":
                    appendMerging("\n", style, link)
                case "draw:frame":
                    continue // images are collected separately by `collectImages`
                case "text:note":
                    // The citation's own marker (`text:note-citation`'s literal text — never
                    // recomputed for a well-formed note, see `noteCitationText`) is emitted right
                    // here as a superscript span, exactly where Word/LibreOffice draw it. A note
                    // missing `text:note-citation` entirely (malformed — ODF requires one) falls
                    // back to `notes.fallbackCounter`, a plain sequential count in citation order,
                    // rather than showing a blank marker or crashing.
                    //
                    // `text:note-body` — the note's full text — is deliberately NOT walked from
                    // here: doing so would splice the footnote's own sentence(s) into the middle of
                    // the CITING paragraph, which is precisely the corruption `read()`'s
                    // `buildNoteBlocks` exists to avoid. A note with no `text:note-body` at all
                    // (also malformed) contributes nothing to `notes.entries` — its marker still
                    // shows here, honestly, but there is no body text to fabricate. That body, when
                    // present, is rendered once, detached, at the document's end instead.
                    let citation = noteCitationText(child)
                    let marker: String
                    if citation.isEmpty {
                        marker = "\(notes.fallbackCounter)"
                        notes.fallbackCounter += 1
                    } else {
                        marker = citation
                    }
                    if let body = child.child("text:note-body") {
                        notes.entries.append((marker, body))
                    }
                    var markerStyle = TextStyle()
                    markerStyle.superscript = true
                    appendMerging(marker, markerStyle, link)
                case "text:hidden-text":
                    // Verified against OASIS ODF 1.3 schema (element text:hidden-text):
                    // text:condition and text:string-value are REQUIRED, text:is-hidden is
                    // OPTIONAL (text:boolean) — used as an empty field in practice.
                    // ODF's RUN-level "show under a condition" field. Unlike `text:hidden-paragraph`
                    // (which wraps ordinary content), this is an EMPTY field element — its display
                    // text is CACHED in `text:string-value` (ODF's standard "field caches its last-
                    // computed text as an attribute" convention, ODF 1.3 Part 3 §7.2), not held as
                    // child nodes. `text:is-hidden` is the file's own last-computed state; hide only
                    // on an explicit "true", exactly the same rule as `text:hidden-paragraph`.
                    if child.attributes["text:is-hidden"] != "true" {
                        appendMerging(child.attributes["text:string-value"] ?? "", style, link)
                    }
                case "text:conditional-text":
                    // Verified against OASIS ODF 1.3 schema (element text:conditional-text):
                    // text:condition, text:string-value-if-true, text:string-value-if-false are
                    // REQUIRED; text:current-value is OPTIONAL (text:boolean) — used as an empty
                    // field in practice.
                    // ODF's "one of two alternative texts, selected by a formula" field — also an
                    // EMPTY element. `text:current-value` records which branch the formula last
                    // evaluated to; this reader trusts that recorded state rather than evaluating
                    // `text:condition` itself. Absent `text:current-value` reads as "false" (ODF's
                    // own default for the attribute), matching `text:string-value-if-false`.
                    let showTrueBranch = child.attributes["text:current-value"] == "true"
                    let text = showTrueBranch
                        ? (child.attributes["text:string-value-if-true"] ?? "")
                        : (child.attributes["text:string-value-if-false"] ?? "")
                    appendMerging(text, style, link)
                case "text:bookmark-start", "text:bookmark":
                    // `text:bookmark` (a zero-length, point bookmark — the common case for a
                    // cross-reference target) and `text:bookmark-start` (the open end of a ranged
                    // bookmark) both carry the target name the SAME way: `text:name`. Recorded here,
                    // never rendered as text — see `Span.bookmarks`.
                    if let name = child.attributes["text:name"] { pendingBookmarks.append(name) }
                    continue
                case "text:bookmark-end", "office:annotation",
                     "office:annotation-end", "text:soft-page-break":
                    continue // markers with no renderable text of their own
                default:
                    // Anything else this switch doesn't specifically name is descended into rather
                    // than skipped, so text is never lost just because ODF wrapped it in something
                    // unanticipated — same permissive-recursion reasoning as `DocxReader.collectSpans`.
                    walk(child, style: style, link: link)
                }
            }
        }
        walk(node, style: style, link: nil)
        return spans
    }

    // MARK: Generic XML tree — text threaded in as ordered `"#text"` pseudo-children

    private static func buildTree(_ data: Data) throws -> XMLNode {
        let delegate = XMLTreeBuilder()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw ReadError.malformedXML("xml")
        }
        return root
    }
}

/// A minimal DOM, like `DocxReader`'s own, but with one deliberate difference: character data
/// becomes an ordinary child node named `"#text"` instead of accumulating in a separate `text`
/// property on its parent. ODF paragraphs mix bare text and elements constantly
/// (`"before "<text:span>bold</text:span>" after"`), and a parent-level `text` string that simply
/// concatenates everything the parser hands it — regardless of when a child element started or
/// ended — cannot preserve that interleaving. Ordering it as children does, at the cost of a few
/// `"#text"` checks in `OdtReader.collectSpans`.
private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var children: [XMLNode] = []
    /// Only meaningful on a `"#text"` node — the character data itself.
    var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// First direct child with this name, or nil.
    func child(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }

    /// First match anywhere below this node, depth-first in document order.
    func firstDescendant(_ name: String) -> XMLNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.firstDescendant(name) { return found }
        }
        return nil
    }

    /// EVERY match anywhere below this node, in document order — used where a style table must
    /// find every `text:list-style`/`style:style` regardless of which wrapper element holds it.
    func allDescendants(_ name: String) -> [XMLNode] {
        var result: [XMLNode] = []
        for child in children {
            if child.name == name { result.append(child) }
            result.append(contentsOf: child.allDescendants(name))
        }
        return result
    }
}

private final class XMLTreeBuilder: NSObject, XMLParserDelegate {
    var root: XMLNode?
    private var stack: [XMLNode] = []

    func parser(
        _ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
        qualifiedName qName: String?, attributes attributeDict: [String: String]
    ) {
        let node = XMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    /// Character data is appended into the CURRENT top-of-stack element as a `"#text"` pseudo-child
    /// — merged into the last child if it is already one (the parser can call this more than once
    /// for a single run of text), so mixed content keeps its real order without producing a run of
    /// adjacent one-character `"#text"` nodes.
    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard let parent = stack.last else { return }
        if let last = parent.children.last, last.name == "#text" {
            last.text += string
        } else {
            let textNode = XMLNode(name: "#text", attributes: [:])
            textNode.text = string
            parent.children.append(textNode)
        }
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        stack.removeLast()
    }
}

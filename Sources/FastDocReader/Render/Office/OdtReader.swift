import Foundation
import CoreGraphics

/// `.odt` bytes → `[OfficeBlock]`. An ODT is a ZIP holding `content.xml` (the body, required) and
/// optionally `styles.xml` — this reader consults BOTH for `text:list-style` (bullet vs number per
/// level) and text-formatting styles, because LibreOffice sometimes defines a list style used by the
/// body in `styles.xml` rather than `content.xml`'s own `office:automatic-styles`. Sibling of
/// `DocxReader`, deliberately shaped the same way (same XML-tree approach, same error type, same
/// span-reassembly, same unresolvable-image convention) so two office readers don't diverge for no
/// reason — but the underlying markup is different enough that nothing is shared code, only shape.
enum OdtReader {
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
        var textStyles: [String: TextStyle] = [:]
        for root in styleRoots.reversed() {
            listStyles.merge(parseListStyles(from: root)) { existing, _ in existing }
            textStyles.merge(parseTextStyles(from: root)) { existing, _ in existing }
        }
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
        let bodyBlocks = parseBody(body, listStyles: listStyles, textStyles: textStyles, archive: archive, notes: notes)
        let noteBlocks = buildNoteBlocks(notes.entries, listStyles: listStyles, textStyles: textStyles, archive: archive)
        return bodyBlocks + noteBlocks
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
        _ noteEntries: [(marker: String, body: XMLNode)], listStyles: [String: [Int: Bool]],
        textStyles: [String: TextStyle], archive: ZipArchive
    ) -> [OfficeBlock] {
        noteEntries.flatMap { entry -> [OfficeBlock] in
            // A footnote/endnote body cannot itself contain another `text:note` in any real
            // document (ODF disallows it), so a note-body-local `NoteCollector` here only ever
            // guards against a malformed file recursing forever — it is discarded, never merged
            // back into the outer one.
            var blocks = parseBody(entry.body, listStyles: listStyles, textStyles: textStyles, archive: archive, notes: NoteCollector())
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
        case .paragraph(let spans): return .paragraph(spans: [marker, noteMarkerSeparator] + spans)
        case .heading(let level, let spans): return .heading(level: level, spans: [marker, noteMarkerSeparator] + spans)
        case .listItem(let level, let ordered, let spans):
            return .listItem(level: level, ordered: ordered, spans: [marker, noteMarkerSeparator] + spans)
        case .table, .image: return nil
        }
    }

    // MARK: Text (span) styles — automatic-styles → bold/italic/underline

    private struct TextStyle: Equatable {
        var bold = false
        var italic = false
        var underline = false
        var strikethrough = false
        var superscript = false
        var subscripted = false
    }

    /// Only `style:family="text"` styles are read — ODF reuses `style:style` for paragraph, table,
    /// table-cell, graphic and text styles alike, all distinguished by `style:family`; picking up
    /// the wrong family would collide names (a paragraph style and a text style can share a name).
    /// A style with no `style:text-properties` at all, or one that declares none of the
    /// properties this reader understands, is simply absent from the map — `collectSpans` reads
    /// that as "no formatting", never a crash.
    private static func parseTextStyles(from root: XMLNode) -> [String: TextStyle] {
        var map: [String: TextStyle] = [:]
        for styleNode in root.allDescendants("style:style") where styleNode.attributes["style:family"] == "text" {
            guard let name = styleNode.attributes["style:name"], let props = styleNode.child("style:text-properties")
            else { continue }
            var style = TextStyle()
            style.bold = props.attributes["fo:font-weight"] == "bold"
            style.italic = props.attributes["fo:font-style"] == "italic"
            if let underline = props.attributes["style:text-underline-style"] { style.underline = underline != "none" }
            if let strike = props.attributes["style:text-line-through-style"] { style.strikethrough = strike != "none" }
            // `style:text-position` is `"<super|sub> <percentage>"` (e.g. `"super 58%"`) — only the
            // leading keyword decides which axis; the percentage is a font-scale hint this viewer
            // doesn't reproduce (same "skip presentation fidelity" call as everywhere else).
            if let position = props.attributes["style:text-position"] {
                style.superscript = position.hasPrefix("super")
                style.subscripted = position.hasPrefix("sub")
            }
            map[name] = style
        }
        return map
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

    // MARK: content.xml — office:text → blocks

    private static func parseBody(
        _ text: XMLNode, listStyles: [String: [Int: Bool]], textStyles: [String: TextStyle], archive: ZipArchive,
        notes: NoteCollector
    ) -> [OfficeBlock] {
        var blocks: [OfficeBlock] = []
        for child in text.children {
            switch child.name {
            case "text:h":
                let rawLevel = Int(child.attributes["text:outline-level"] ?? "") ?? 1
                let level = min(max(rawLevel, 1), 6)
                blocks.append(contentsOf: paragraphLikeBlocks(
                    child, make: { .heading(level: level, spans: $0) }, textStyles: textStyles, archive: archive,
                    notes: notes))
            case "text:p":
                blocks.append(contentsOf: paragraphLikeBlocks(
                    child, make: { .paragraph(spans: $0) }, textStyles: textStyles, archive: archive, notes: notes))
            case "text:list":
                blocks.append(contentsOf: parseList(
                    child, level: 0, inheritedStyleName: nil, listStyles: listStyles, textStyles: textStyles,
                    archive: archive, notes: notes))
            case "table:table":
                blocks.append(parseTable(child, textStyles: textStyles, notes: notes))
            default:
                // e.g. `text:sequence-decls`, `office:scripts` reached via a broader search — not
                // a block. `office:text`'s own children never include those, but this stays
                // defensive against a producer that nests differently.
                continue
            }
        }
        return blocks
    }

    /// A heading or paragraph normally contributes exactly one text block, but one carrying an
    /// image contributes that text block (if it has any spans) FOLLOWED BY the image block(s), in
    /// source order — mirroring `DocxReader.parseParagraph`. A paragraph that is ONLY a picture
    /// (no spans at all — LibreOffice puts an image-only paragraph with no other text) contributes
    /// no empty text block, so callers never see a phantom `.paragraph(spans: [])` standing in for
    /// a picture.
    private static func paragraphLikeBlocks(
        _ node: XMLNode, make: ([Span]) -> OfficeBlock, textStyles: [String: TextStyle], archive: ZipArchive,
        notes: NoteCollector
    ) -> [OfficeBlock] {
        let spans = collectSpans(in: node, style: TextStyle(), textStyles: textStyles, notes: notes)
        let images = collectImages(in: node, archive: archive)
        var blocks: [OfficeBlock] = []
        if !(spans.isEmpty && !images.isEmpty) { blocks.append(make(spans)) }
        blocks.append(contentsOf: images)
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
        _ list: XMLNode, level: Int, inheritedStyleName: String?, listStyles: [String: [Int: Bool]],
        textStyles: [String: TextStyle], archive: ZipArchive, notes: NoteCollector
    ) -> [OfficeBlock] {
        let styleName = list.attributes["text:style-name"] ?? inheritedStyleName
        let ordered = isOrdered(styleName: styleName, level: level, listStyles: listStyles)
        var blocks: [OfficeBlock] = []
        for item in list.children where item.name == "text:list-item" {
            for child in item.children {
                switch child.name {
                case "text:p":
                    blocks.append(contentsOf: paragraphLikeBlocks(
                        child, make: { .listItem(level: level, ordered: ordered, spans: $0) },
                        textStyles: textStyles, archive: archive, notes: notes))
                case "text:list":
                    blocks.append(contentsOf: parseList(
                        child, level: level + 1, inheritedStyleName: styleName, listStyles: listStyles,
                        textStyles: textStyles, archive: archive, notes: notes))
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
    private static func parseTable(_ table: XMLNode, textStyles: [String: TextStyle], notes: NoteCollector) -> OfficeBlock {
        var rows: [[Cell]] = []
        var headerRows = 0
        for child in table.children {
            switch child.name {
            case "table:table-header-rows":
                let expanded = child.children.filter { $0.name == "table:table-row" }
                    .flatMap { expandRow($0, textStyles: textStyles, notes: notes) }
                headerRows += expanded.count
                rows.append(contentsOf: expanded)
            case "table:table-row":
                rows.append(contentsOf: expandRow(child, textStyles: textStyles, notes: notes))
            default:
                continue
            }
        }
        return .table(rows: rows, headerRows: headerRows)
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
    private static func expandRow(_ row: XMLNode, textStyles: [String: TextStyle], notes: NoteCollector) -> [[Cell]] {
        let rowRepeat = Int(row.attributes["table:number-rows-repeated"] ?? "") ?? 1
        var cells: [Cell] = []
        for cell in row.children where cell.name == "table:table-cell" {
            let spans = collectCellSpans(cell, textStyles: textStyles, notes: notes)
            let rowSpan = Int(cell.attributes["table:number-rows-spanned"] ?? "") ?? 1
            let colSpan = Int(cell.attributes["table:number-columns-spanned"] ?? "") ?? 1
            let colRepeat = Int(cell.attributes["table:number-columns-repeated"] ?? "") ?? 1
            cells.append(contentsOf: Array(repeating: Cell(spans: spans, rowSpan: rowSpan, colSpan: colSpan), count: colRepeat))
        }
        // `table:covered-table-cell` elements are read only to confirm they exist (and can carry
        // their own `number-columns-repeated`, e.g. a 3-wide covered run compressed to one element)
        // — neither contributes a `Cell`, so nothing further happens with them here.
        return Array(repeating: cells, count: rowRepeat)
    }

    /// A cell's content: its own paragraphs/headings, PLUS — when ODF nests a full
    /// `<table:table>` directly inside a `<table:table-cell>` — that inner table's text, flattened
    /// to spans. `Cell` has no case for a nested `.table` block (research-odt.md §4 sanctions this
    /// as a legitimate depth-1 shortcut for a flat block viewer: the grid disappears, but no text
    /// does — "skip presentation fidelity freely, never content").
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
        func appendMerging(_ text: String, _ style: TextStyle, _ link: String?) {
            guard !text.isEmpty else { return }
            if let last = spans.last, last.bold == style.bold, last.italic == style.italic, last.underline == style.underline,
               last.strikethrough == style.strikethrough, last.superscript == style.superscript,
               last.subscripted == style.subscripted, last.link == link {
                spans[spans.count - 1].text += text
            } else {
                spans.append(Span(
                    text: text, bold: style.bold, italic: style.italic, underline: style.underline, link: link,
                    strikethrough: style.strikethrough, superscript: style.superscript, subscripted: style.subscripted))
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
                case "text:bookmark-start", "text:bookmark-end", "text:bookmark", "office:annotation",
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

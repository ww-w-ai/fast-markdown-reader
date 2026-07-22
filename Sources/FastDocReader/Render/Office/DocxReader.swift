import Foundation
import CoreGraphics
import AppKit

/// `.docx` bytes → `[OfficeBlock]`. Word's own container is three XML parts inside the ZIP
/// `ZipArchive` already knows how to open: `word/document.xml` (the body, required), and two
/// optional ones this reader consults to resolve what the body only references by id —
/// `word/styles.xml` (a paragraph style's `w:outlineLvl`, which is what actually makes it a
/// heading) and `word/numbering.xml` (whether a list level is a bullet or a number). Neither
/// being absent is an error — Word omits `numbering.xml` from documents with no lists at all —
/// so both fall back to an empty table and the body still parses.
enum DocxReader: OfficeDocumentReader {
    enum ReadError: Swift.Error, Equatable, LocalizedError {
        /// `word/document.xml` is missing from the archive. Returning an empty document here
        /// would look like a genuinely blank file — the worst failure mode for a reader — so
        /// this throws instead.
        case missingDocumentXML
        /// A required XML part did not parse (malformed XML). Named by its archive path so the
        /// error is actionable.
        case malformedXML(String)

        var errorDescription: String? {
            switch self {
            case .missingDocumentXML:
                return "This .docx file has no word/document.xml — it may be corrupt."
            case .malformedXML(let part):
                return "\"\(part)\" could not be parsed as XML."
            }
        }
    }

    /// This reader emits `.image` blocks (see `collectImages`) — PARSING only. Resolving an
    /// emitted id to actual pixels (reading the archive entry, drawing a placeholder for an
    /// unresolvable one) is a later sprint's job.
    static func read(_ archive: ZipArchive) throws -> [OfficeBlock] {
        guard archive.contains("word/document.xml") else { throw ReadError.missingDocumentXML }
        guard let documentRoot = try? buildTree(archive.data(for: "word/document.xml")) else {
            throw ReadError.malformedXML("word/document.xml")
        }
        let themeColors = parseThemeColors(from: archive)
        let styleInfo = parseStyles(from: archive, themeColors: themeColors)
        let numbering = parseNumbering(from: archive)
        let relationships = parseRelationships(from: archive)
        guard let body = documentRoot.child("w:body") else { return [] }
        // Footnote/endnote numbering is resolved BEFORE the body is walked for real: Word doesn't
        // stamp an explicit display number on `w:footnoteReference`/`w:endnoteReference` (unlike
        // ODF's `text:note-citation`, which literally contains its own marker text) — the number is
        // purely positional, so it has to come from a first pass over the whole body in document
        // order, footnotes and endnotes counted separately (each is its own sequence in Word, both
        // starting at 1). This is "auto-number", not "invented" — it's the same number Word itself
        // would display.
        let (footnoteNumberById, endnoteNumberById, citationOrder) = numberNoteReferences(in: body)
        let notes = NoteNumbering(footnote: footnoteNumberById, endnote: endnoteNumberById)
        // ONE numbering-counter state for the whole read() call — body, then footnotes, then
        // endnotes, all walked from here in that order — because a numId's counters belong to the
        // numId, not to which of those three regions a paragraph happens to sit in (see
        // `ListNumberingState`).
        let listState = ListNumberingState()
        let bodyBlocks = parseBody(
            body, styleInfo: styleInfo, numbering: numbering, relationships: relationships, notes: notes,
            listState: listState)
        let footnoteBodies = parseNoteBodies(from: archive, part: "word/footnotes.xml", noteElementName: "w:footnote")
        let endnoteBodies = parseNoteBodies(from: archive, part: "word/endnotes.xml", noteElementName: "w:endnote")
        let noteBlocks = collectNoteBlocks(
            citationOrder: citationOrder, footnoteBodies: footnoteBodies, endnoteBodies: endnoteBodies,
            styleInfo: styleInfo, numbering: numbering, relationships: relationships, notes: notes,
            listState: listState)
        return bodyBlocks + noteBlocks
    }

    /// The source document's own default BODY run size, in points — `word/styles.xml`'s
    /// `w:docDefaults/w:rPrDefault/w:rPr/w:sz` (HALF-points), or Word's own fallback of 11pt when
    /// the document declares none at all (no `word/styles.xml`, no `w:docDefaults`, or no `w:sz`
    /// inside it). This is the OTHER half of `OfficeTextBuilder.build`'s font-size model — see its
    /// `documentDefaultFontSize` parameter's own doc. Named (and shaped) to match `OfficeDocumentReader`
    /// exactly, and reached ONLY through `DocumentTypes.officeDefaultBodyFontSize` — see that file for
    /// why a second, direct call site would risk the same reader/extension divergence invariant 29
    /// records.
    static func documentDefaultBodyFontSize(_ archive: ZipArchive) -> CGFloat {
        guard archive.contains("word/styles.xml"),
              let data = try? archive.data(for: "word/styles.xml"),
              let root = try? buildTree(data),
              let szVal = root.child("w:docDefaults")?.child("w:rPrDefault")?.child("w:rPr")?.child("w:sz")?.attributes["w:val"],
              let half = Double(szVal)
        else { return 11 }
        return CGFloat(half / 2)
    }

    // MARK: Footnotes / endnotes

    /// `word/footnotes.xml` (and the identically-shaped `word/endnotes.xml`) is a flat list of
    /// `w:footnote`/`w:endnote` elements keyed by `w:id`, each holding ordinary `w:p` paragraphs —
    /// the note's actual author-written text. Two ids are reserved and carry NO real content:
    /// `w:type="separator"` and `w:type="continuationSeparator"` are the little horizontal rule
    /// Word draws above notes on a page (and its continuation), present in essentially every real
    /// `.docx` whether or not the document has a single real footnote. Filtering by `w:type` (not
    /// by id, e.g. "ids ≤ 0 are boilerplate") is the only reliable signal — a document's real notes
    /// happen to start at id 1 in practice, but nothing in the spec guarantees that, while the type
    /// attribute is exactly what Word itself uses to tell them apart. A note with no `w:type` at all
    /// is real content, never boilerplate.
    private static func parseNoteBodies(from archive: ZipArchive, part: String, noteElementName: String) -> [String: XMLNode] {
        guard archive.contains(part), let data = try? archive.data(for: part), let root = try? buildTree(data)
        else { return [:] }
        var map: [String: XMLNode] = [:]
        for note in root.children where note.name == noteElementName {
            guard let id = note.attributes["w:id"] else { continue }
            let type = note.attributes["w:type"]
            guard type != "separator", type != "continuationSeparator" else { continue }
            map[id] = note
        }
        return map
    }

    private enum NoteKind { case footnote, endnote }

    /// Number → the marker rendered at both the citation point and the note body it points to.
    /// Separate maps because footnotes and endnotes are separate numbering sequences in Word (both
    /// commonly start at 1) — collapsing them into one counter would make a document's second
    /// footnote and its first endnote fight over "2".
    private struct NoteNumbering {
        var footnote: [String: Int] = [:]
        var endnote: [String: Int] = [:]
    }

    /// One recursive walk of the ENTIRE body — not two separate searches — so the two kinds of
    /// reference come back in one true document order regardless of how they're nested (inside a
    /// table cell, a text box, a grouped drawing, an `w:sdt` wrapper …); interleaving them correctly
    /// only matters for `citationOrder` (what gets appended at the end, and in what sequence), since
    /// footnotes and endnotes are numbered independently of each other. A repeated reference to the
    /// SAME id (unusual, but not forbidden) reuses the number already assigned instead of adding a
    /// second entry to `citationOrder` — the note body is only appended once.
    private static func numberNoteReferences(
        in body: XMLNode
    ) -> (footnote: [String: Int], endnote: [String: Int], citationOrder: [(kind: NoteKind, id: String, number: Int)]) {
        var footnoteNumberById: [String: Int] = [:]
        var endnoteNumberById: [String: Int] = [:]
        var citationOrder: [(kind: NoteKind, id: String, number: Int)] = []
        // Deliberately NOT a `switch`-with-`default: continue` — a footnote/endnote reference is
        // nested INSIDE a run (`w:r`), which is nested inside a paragraph, which may itself be
        // nested inside a table cell, a text box, an `w:sdt` wrapper, … `continue`-ing out of a
        // switch's default case would skip recursing into every one of those non-matching wrappers,
        // silently missing every reference not sitting at the top level. Every node is walked
        // unconditionally; matching is a plain check alongside that walk, not a branch that gates it.
        func walk(_ node: XMLNode) {
            for child in node.children {
                if child.name == "w:footnoteReference", let id = child.attributes["w:id"], footnoteNumberById[id] == nil {
                    let number = footnoteNumberById.count + 1
                    footnoteNumberById[id] = number
                    citationOrder.append((.footnote, id, number))
                } else if child.name == "w:endnoteReference", let id = child.attributes["w:id"], endnoteNumberById[id] == nil {
                    let number = endnoteNumberById.count + 1
                    endnoteNumberById[id] = number
                    citationOrder.append((.endnote, id, number))
                }
                walk(child)
            }
        }
        walk(body)
        return (footnoteNumberById, endnoteNumberById, citationOrder)
    }

    /// Turns each cited note into ordinary blocks, appended in citation order at document's end —
    /// never inlined at the reference point (see the sprint brief: Word keeps them visually
    /// separated). Reuses `parseBodyChild` for the note's own paragraphs/tables, exactly the same
    /// walk the document body itself gets, rather than a second flattener. A note whose id doesn't
    /// resolve to any real part (a malformed/edited document) contributes nothing — its marker still
    /// appears at the citation point, honestly showing "something was cited here", but there is no
    /// text to fabricate for it.
    private static func collectNoteBlocks(
        citationOrder: [(kind: NoteKind, id: String, number: Int)], footnoteBodies: [String: XMLNode],
        endnoteBodies: [String: XMLNode], styleInfo: StyleInfo, numbering: NumberingInfo,
        relationships: Relationships, notes: NoteNumbering, listState: ListNumberingState
    ) -> [OfficeBlock] {
        citationOrder.flatMap { entry -> [OfficeBlock] in
            let noteElement = entry.kind == .footnote ? footnoteBodies[entry.id] : endnoteBodies[entry.id]
            guard let noteElement else { return [] }
            var blocks = noteElement.children.flatMap {
                parseBodyChild(
                    $0, styleInfo: styleInfo, numbering: numbering, relationships: relationships,
                    notes: notes, listState: listState)
            }
            // Never fabricated — this is the SAME marker text emitted at the citation point
            // (`collectSpans`'s `w:footnoteReference`/`w:endnoteReference` case), so a reader can
            // visually match a note back to where it was cited.
            let marker = Span(text: "\(entry.number)", superscript: true)
            if let first = blocks.first, let markedFirst = prependingMarker(marker, to: first) {
                blocks[0] = markedFirst
            } else {
                // Empty note body, or one that opens with a table/image — neither has anywhere to
                // splice a span into, so the marker becomes its own small leading paragraph instead
                // of being silently dropped.
                blocks.insert(.paragraph(spans: [marker]), at: 0)
            }
            return blocks
        }
    }

    /// `nil` for `.table`/`.image` — there is no `[Span]` inside either to prepend into — so the
    /// caller falls back to a standalone marker paragraph instead.
    private static func prependingMarker(_ marker: Span, to block: OfficeBlock) -> OfficeBlock? {
        switch block {
        case .paragraph(let spans, let rtl, let alignment, let tabStops, let format):
            return .paragraph(spans: [marker] + spans, rtl: rtl, alignment: alignment, tabStops: tabStops, format: format)
        case .heading(let level, let spans, let rtl, let alignment, let tabStops, let format):
            return .heading(level: level, spans: [marker] + spans, rtl: rtl, alignment: alignment, tabStops: tabStops, format: format)
        case .listItem(let level, let ordered, let spans, let itemMarker, let rtl, let alignment, let tabStops, let format):
            return .listItem(level: level, ordered: ordered, spans: [marker] + spans, marker: itemMarker, rtl: rtl,
                              alignment: alignment, tabStops: tabStops, format: format)
        case .table, .image, .unsupportedGraphic, .formula: return nil
        }
    }

    // MARK: styles.xml — styleId → outlineLvl (+ basedOn chain)

    /// A style's NAME is not a safe signal — a localized Word install renames "Heading1" to
    /// something like 제목 1, but a style's ID is NOT localized: a Korean, Japanese or German Word
    /// install still writes `w:styleId="Heading2"` even though the NAME it shows the user differs.
    /// That is what makes mechanism (b) below safe to use — matching the id, never the name.
    /// A style's own run formatting — `w:rPr` on a `w:style`, resolved to the SAME literal shape
    /// `Span` itself carries (colour already resolved against the theme, size already in points),
    /// so `resolvedColor`/`resolvedFontSize`/… never have to re-resolve anything once they find an
    /// entry here. `nil` per field means that field, specifically, wasn't set at this style — the
    /// caller's chain walk keeps climbing `basedOn` for THAT field alone, not the whole struct.
    private struct RunStyleProps {
        var color: NSColor?
        var highlight: NSColor?
        var fontSize: CGFloat?
        var fontName: String?
    }

    /// A style's own paragraph formatting relevant to this sprint — `w:jc`/`w:tabs` off a
    /// `w:style`'s `w:pPr`. `tabStops == nil` means this style declared none (keep climbing);
    /// an EXPLICIT empty list never occurs from `parseTabStops` (see its own doc), so there is no
    /// "explicitly no tabs" state to lose by using `nil` for both meanings.
    private struct ParaStyleProps {
        var alignment: NSTextAlignment?
        var tabStops: [CGFloat]?
    }

    private struct StyleInfo {
        /// styleId → its OWN declared `w:outlineLvl`, only for styles that declare one at all
        /// (most custom styles, and many built-in `HeadingN` styles that instead rely on their id —
        /// see `builtInHeadingLevel`).
        var outlineLevels: [String: Int] = [:]
        /// styleId → the styleId it's `w:basedOn`, for styles that declare one.
        var basedOn: [String: String] = [:]
        /// styleId → its own `w:rPr`, only for styles that set at least one of the four fields.
        var runProps: [String: RunStyleProps] = [:]
        /// styleId → its own `w:pPr`'s `w:jc`/`w:tabs`, only for styles that set at least one.
        var paraProps: [String: ParaStyleProps] = [:]
        /// The document's theme colour scheme (`word/theme/theme1.xml`), keyed by scheme slot name
        /// (`"dk1"`, `"accent1"`, …) — carried ON `StyleInfo` rather than threaded as its own
        /// parameter through every function that already takes `styleInfo`, since every one of
        /// those call sites needs it for exactly the same reason (resolving a run's `w:themeColor`)
        /// this struct's OWN `runProps` were already resolved against it. Empty when
        /// `word/theme/theme1.xml` is absent or malformed — every theme-colour lookup then simply
        /// misses, degrading to "no colour" (`resolvedColorElement`), never a crash.
        var themeColors: [String: NSColor] = [:]
    }

    /// Reads every per-style signal this reader now resolves through the `w:basedOn` chain:
    /// `resolvedOutlineLevel`'s pair (`w:outlineLvl`, `w:basedOn`), plus this sprint's own run
    /// (`RunStyleProps`) and paragraph (`ParaStyleProps`) formatting. `themeColors` is resolved
    /// ONCE by the caller (`read`) and passed in so a style's own `w:color/@w:themeColor` resolves
    /// to the same literal every direct-run lookup does. A style declaring none of these is simply
    /// absent from every map — `resolvedOutlineLevel`'s existing "not a heading" reading, and the
    /// new resolvers' "keep climbing" reading, both already treat absence that way.
    private static func parseStyles(from archive: ZipArchive, themeColors: [String: NSColor]) -> StyleInfo {
        // `themeColors` must survive even when `word/styles.xml` itself is absent — a direct RUN
        // can carry a `w:themeColor` with no style involved at all, and that lookup goes through
        // THIS `StyleInfo`'s `themeColors` field (see `buildSpan`). An early `StyleInfo()` here,
        // discarding the parameter, was a real bug this sprint caught: it silently dropped every
        // theme colour in any document with no styles part.
        var info = StyleInfo()
        info.themeColors = themeColors
        guard archive.contains("word/styles.xml"),
              let data = try? archive.data(for: "word/styles.xml"),
              let root = try? buildTree(data)
        else { return info }
        for style in root.children where style.name == "w:style" {
            guard let id = style.attributes["w:styleId"] else { continue }
            if let val = style.child("w:pPr")?.child("w:outlineLvl")?.attributes["w:val"], let level = Int(val) {
                info.outlineLevels[id] = level
            }
            if let parent = style.child("w:basedOn")?.attributes["w:val"] {
                info.basedOn[id] = parent
            }
            let runProps = parseRunStyleProps(style.child("w:rPr"), themeColors: themeColors)
            if runProps.color != nil || runProps.highlight != nil || runProps.fontSize != nil || runProps.fontName != nil {
                info.runProps[id] = runProps
            }
            let paraProps = parseParaStyleProps(style.child("w:pPr"))
            if paraProps.alignment != nil || paraProps.tabStops != nil {
                info.paraProps[id] = paraProps
            }
        }
        return info
    }

    /// One style's (or one run's own) `w:rPr`, reduced to the four fields this sprint resolves —
    /// shared by `parseStyles` (a style's `w:rPr`) and `buildSpan` (a run's direct `w:rPr`), so a
    /// literal-colour hex, a themeColor reference, a half-point size and an `w:rFonts` choice are
    /// each read exactly once, the same way, regardless of which level of the chain they came from.
    private static func parseRunStyleProps(_ rPr: XMLNode?, themeColors: [String: NSColor]) -> RunStyleProps {
        var props = RunStyleProps()
        props.color = resolvedColorElement(rPr?.child("w:color"), themeColors: themeColors)
        if let val = rPr?.child("w:highlight")?.attributes["w:val"] {
            props.highlight = highlightColor(named: val)
        }
        if let szVal = rPr?.child("w:sz")?.attributes["w:val"], let half = Double(szVal) {
            props.fontSize = CGFloat(half / 2)
        }
        // `w:rFonts` carries separate attributes for Latin (`w:ascii`), East Asian (`w:eastAsia`),
        // complex-script (`w:cs`) and a "high ANSI" fallback (`w:hAnsi`) text — Word substitutes
        // whichever applies per RUN OF CHARACTERS within the same text, something this reader's
        // single `Span.fontName` has no room to express. `w:ascii` is read as the representative
        // choice: it is the font Word itself falls back to for any character its other three
        // attributes don't specifically claim, i.e. the document's "default" declared font, and by
        // far the most common case (plain Latin body text) has ONLY `w:ascii`/`w:hAnsi` set to the
        // same value anyway. `w:hAnsi` is the fallback when `w:ascii` is absent (Word requires at
        // least one of the two on any `w:rFonts` that names a Latin font at all).
        if let rFonts = rPr?.child("w:rFonts") {
            props.fontName = rFonts.attributes["w:ascii"] ?? rFonts.attributes["w:hAnsi"]
        }
        return props
    }

    /// One style's (or one paragraph's own) `w:pPr`, reduced to `w:jc`/`w:tabs` — shared by
    /// `parseStyles` and `parseParagraph`'s direct-`pPr` read, the same way `parseRunStyleProps` is.
    private static func parseParaStyleProps(_ pPr: XMLNode?) -> ParaStyleProps {
        var props = ParaStyleProps()
        if let val = pPr?.child("w:jc")?.attributes["w:val"] {
            props.alignment = alignmentFromJc(val)
        }
        if let tabsNode = pPr?.child("w:tabs") {
            let stops = parseTabStops(tabsNode)
            if !stops.isEmpty { props.tabStops = stops }
        }
        return props
    }

    /// `w:jc`'s values per ECMA-376 §17.18.44 (`ST_Jc`): `"both"`/`"distribute"` are Word's two
    /// justify-both-edges variants (this reader doesn't distinguish letter-spacing distribution
    /// from ordinary justification — `NSTextAlignment` has no third option), `"start"`/`"end"` are
    /// the writing-direction-relative synonyms for `"left"`/`"right"` newer Word versions also
    /// emit. Anything else (`"center"` aside, every value here) that ISN'T one of these seven is
    /// left unresolved (`nil`) — the paragraph then falls back to whatever `rtl`/the theme's own
    /// default decides, exactly as an absent `w:jc` already does.
    private static func alignmentFromJc(_ val: String) -> NSTextAlignment? {
        switch val {
        case "left", "start": return .left
        case "right", "end": return .right
        case "center": return .center
        case "both", "distribute": return .justified
        default: return nil
        }
    }

    /// `w:tabs`'s own `w:tab` children, each `w:pos` in TWIPS (Word's unit here, 20ths of a point —
    /// the SAME unit `w:tblW`/`w:tcW` use, see `cellWidth`) converted to points. A `w:val="clear"`
    /// entry REMOVES an inherited stop at that position rather than adding one of its own — this
    /// reader has no per-position merge against an ancestor's stops to remove FROM (an inherited
    /// list is taken or left whole, never spliced — see `ParaStyleProps`'s doc), so a `clear` entry
    /// is simply skipped rather than emitted as a phantom stop at that position. A `w:tab` missing
    /// `w:pos` entirely (malformed) is skipped the same way — there is no position to place it at.
    private static func parseTabStops(_ tabsNode: XMLNode) -> [CGFloat] {
        tabsNode.children.compactMap { tab -> CGFloat? in
            guard tab.name == "w:tab", tab.attributes["w:val"] != "clear" else { return nil }
            guard let posStr = tab.attributes["w:pos"], let pos = Double(posStr) else { return nil }
            return CGFloat(pos / 20)
        }
    }

    /// Walks a style's `w:basedOn` chain (cycle-guarded exactly like `resolvedOutlineLevel`, whose
    /// walk this generalizes) trying `resolve` at each style in turn: the NEAREST style that has an
    /// answer wins, and a style with no answer for THIS property is transparent — the walk keeps
    /// climbing past it rather than stopping. This is what makes "direct run wins over style, style
    /// wins over its ancestors" hold per-PROPERTY, not per-style: a style can set `w:sz` and leave
    /// colour to ITS ancestor, and this walk still finds the ancestor's colour.
    private static func walkStyleChain<T>(_ pStyleId: String?, styleInfo: StyleInfo, resolve: (String) -> T?) -> T? {
        guard var currentId = pStyleId else { return nil }
        var visited = Set<String>()
        while true {
            guard !visited.contains(currentId) else { return nil }
            visited.insert(currentId)
            if let value = resolve(currentId) { return value }
            guard let parent = styleInfo.basedOn[currentId] else { return nil }
            currentId = parent
        }
    }

    private static func resolvedColor(pStyleId: String?, styleInfo: StyleInfo) -> NSColor? {
        walkStyleChain(pStyleId, styleInfo: styleInfo) { styleInfo.runProps[$0]?.color }
    }

    private static func resolvedHighlight(pStyleId: String?, styleInfo: StyleInfo) -> NSColor? {
        walkStyleChain(pStyleId, styleInfo: styleInfo) { styleInfo.runProps[$0]?.highlight }
    }

    private static func resolvedFontSize(pStyleId: String?, styleInfo: StyleInfo) -> CGFloat? {
        walkStyleChain(pStyleId, styleInfo: styleInfo) { styleInfo.runProps[$0]?.fontSize }
    }

    private static func resolvedFontName(pStyleId: String?, styleInfo: StyleInfo) -> String? {
        walkStyleChain(pStyleId, styleInfo: styleInfo) { styleInfo.runProps[$0]?.fontName }
    }

    private static func resolvedAlignment(pStyleId: String?, styleInfo: StyleInfo) -> NSTextAlignment? {
        walkStyleChain(pStyleId, styleInfo: styleInfo) { styleInfo.paraProps[$0]?.alignment }
    }

    private static func resolvedTabStops(pStyleId: String?, styleInfo: StyleInfo) -> [CGFloat]? {
        walkStyleChain(pStyleId, styleInfo: styleInfo) { styleInfo.paraProps[$0]?.tabStops }
    }

    // MARK: word/theme/theme1.xml — theme colour scheme

    /// `word/theme/theme1.xml`'s `a:clrScheme` names twelve fixed slots (`a:dk1`, `a:lt1`, `a:dk2`,
    /// `a:lt2`, `a:accent1`…`a:accent6`, `a:hlink`, `a:folHlink`), each holding either a literal
    /// `a:srgbClr/@val` or a `a:sysClr` (a named system colour, e.g. `"windowText"`) whose
    /// `@lastClr` attribute is Office's own cached literal RGB for it — read here exactly like
    /// `a:srgbClr`'s `val`, since that cached value is what Word itself actually painted with.
    /// Absent or malformed (no `word/theme/theme1.xml` at all, or one without `a:clrScheme`)
    /// degrades to an empty table, never a crash — every `w:themeColor` lookup against it then
    /// simply misses, same as a document with no theme colours ever declared.
    private static func parseThemeColors(from archive: ZipArchive) -> [String: NSColor] {
        guard archive.contains("word/theme/theme1.xml"),
              let data = try? archive.data(for: "word/theme/theme1.xml"),
              let root = try? buildTree(data),
              let clrScheme = root.firstDescendant("a:clrScheme")
        else { return [:] }
        var colors: [String: NSColor] = [:]
        for slot in clrScheme.children where slot.name.hasPrefix("a:") {
            let key = String(slot.name.dropFirst(2))
            if let hex = slot.child("a:srgbClr")?.attributes["val"], let color = colorFromHex(hex) {
                colors[key] = color
            } else if let hex = slot.child("a:sysClr")?.attributes["lastClr"], let color = colorFromHex(hex) {
                colors[key] = color
            }
        }
        return colors
    }

    /// `w:themeColor`'s enumeration (ECMA-376 §17.18.98, `ST_ThemeColor`) names TEN colour roles —
    /// `"dark1"`/`"light1"`/`"dark2"`/`"light2"` AND the semantically-named `"text1"`/
    /// `"background1"`/`"text2"`/`"background2"` are two spellings for the SAME four scheme slots
    /// (`dk1`/`lt1`/`dk2`/`lt2`) — plus `"accent1"`…`"accent6"` (spelled identically to their
    /// scheme slot names, so no translation needed) and `"hyperlink"`/`"followedHyperlink"` (the
    /// scheme's `hlink`/`folHlink`, abbreviated). `nil` for anything else (there is nothing else in
    /// the enumeration, but a malformed document could carry a stray value) — the caller then finds
    /// no colour, same as a `w:themeColor` slot the theme part itself never defined.
    private static func themeSlotName(for themeColor: String) -> String? {
        switch themeColor {
        case "dark1", "text1": return "dk1"
        case "light1", "background1": return "lt1"
        case "dark2", "text2": return "dk2"
        case "light2", "background2": return "lt2"
        case "accent1", "accent2", "accent3", "accent4", "accent5", "accent6": return themeColor
        case "hyperlink": return "hlink"
        case "followedHyperlink": return "folHlink"
        default: return nil
        }
    }

    /// A `w:color` element (a run's own `w:rPr/w:color`, or a style's), resolved to a literal —
    /// EITHER its literal `w:val` hex, OR — measured at 10% of the real corpus, a mechanism worth
    /// doing properly rather than approximating — a `w:themeColor` reference resolved against
    /// `themeColors`. `w:val="auto"` (Word's own "let the reader decide" sentinel) and an
    /// unresolvable `w:themeColor` (an unrecognized slot name, or a theme part that doesn't define
    /// it) both mean exactly what no `w:color` at all means — `nil`, "the theme's own text colour
    /// decides" — never a fabricated black. `w:themeColor` wins when BOTH are present (Word always
    /// writes a literal `w:val` alongside a `w:themeColor` as an older-reader fallback — the two are
    /// never in real conflict, but the theme reference is the author's actual intent).
    ///
    /// `w:themeTint`/`w:themeShade` (a lightened/darkened variant of the resolved slot) are read off
    /// the element by callers that want them but DELIBERATELY IGNORED here — see this sprint's
    /// return report. Applying them correctly is a luminance-space transform (ECMA-376's own
    /// algorithm operates in HSL, not a flat per-channel blend), and getting that wrong would be
    /// worse than the brief's own explicitly offered fallback: resolve the base slot colour, as
    /// authored, and leave it there.
    private static func resolvedColorElement(_ colorNode: XMLNode?, themeColors: [String: NSColor]) -> NSColor? {
        guard let colorNode else { return nil }
        if let themeColor = colorNode.attributes["w:themeColor"], let slot = themeSlotName(for: themeColor) {
            if let resolved = themeColors[slot] { return resolved }
        }
        guard let val = colorNode.attributes["w:val"], val.lowercased() != "auto" else { return nil }
        return colorFromHex(val)
    }

    /// `w:highlight`'s value (ECMA-376 §17.18.40, `ST_HighlightColor`) is a NAME from a fixed
    /// 17-entry enumeration, not a hex value — unlike `w:color`/`w:shd`, which are always literal
    /// or theme-relative. The sixteen real colours' RGB equivalents below are the standard values
    /// every Open XML implementation (Word itself, the published Open XML SDK enumeration) assigns
    /// to these exact names — read FROM the spec's own enumeration semantics, not copied out of
    /// another project's lookup table (this project's licence rule forbids that; see
    /// `mappedSymbolCharacter`'s doc for the same reasoning applied to `w:sym`). `"none"` and
    /// anything unrecognized both return `nil` — no highlight — never a guessed colour.
    private static func highlightColor(named name: String) -> NSColor? {
        let hex: String?
        switch name {
        case "black": hex = "000000"
        case "blue": hex = "0000FF"
        case "cyan": hex = "00FFFF"
        case "darkBlue": hex = "00008B"
        case "darkCyan": hex = "008B8B"
        case "darkGray": hex = "A9A9A9"
        case "darkGreen": hex = "006400"
        case "darkMagenta": hex = "8B008B"
        case "darkRed": hex = "8B0000"
        case "darkYellow": hex = "808000"
        case "green": hex = "00FF00"
        case "lightGray": hex = "D3D3D3"
        case "magenta": hex = "FF00FF"
        case "red": hex = "FF0000"
        case "white": hex = "FFFFFF"
        case "yellow": hex = "FFFF00"
        default: hex = nil // "none", or anything unrecognized.
        }
        return hex.flatMap(colorFromHex)
    }

    /// A bare 6-digit `RRGGBB` hex string (docx never emits alpha in `w:val`/`w:fill`/`@lastClr`) →
    /// `NSColor`. `nil` for anything that isn't exactly 6 hex digits (a malformed document, or —
    /// for `w:fill` specifically — the literal string `"auto"`, already filtered by every caller
    /// before it reaches here).
    private static func colorFromHex(_ hex: String) -> NSColor? {
        var digits = hex
        if digits.hasPrefix("#") { digits.removeFirst() }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return NSColor(
            srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    /// Mechanism (b): a built-in heading style's id IS its heading level — `Heading1`…`Heading9`,
    /// compared case-insensitively (Word has written both `Heading1` and `heading1` over the years)
    /// against ONLY these nine ASCII ids, never against a style's (localized) name. Returns the same
    /// 0-based scale `w:outlineLvl` uses (`Heading1` → 0), so callers treat it identically to an
    /// explicit `outlineLvl`.
    private static func builtInHeadingLevel(styleId: String) -> Int? {
        let lower = styleId.lowercased()
        guard lower.hasPrefix("heading") else { return nil }
        guard let digit = Int(lower.dropFirst("heading".count)), (1...9).contains(digit) else { return nil }
        return digit - 1
    }

    /// Resolves a paragraph style's outline level by walking its `w:basedOn` chain: at each style,
    /// an explicit `w:outlineLvl` wins; failing that, the style's own id being a built-in `HeadingN`
    /// counts as that level (this is what makes a CUSTOM style based on `Heading2` — which itself
    /// usually carries no `w:outlineLvl` of its own, mechanism (b)'s whole premise — resolve to
    /// level 1 without needing its own declaration); failing both, the walk continues to the
    /// `w:basedOn` parent. A style id revisited during the walk means a cycle in a malformed
    /// document — the walk stops and reports "not a heading" rather than looping forever.
    private static func resolvedOutlineLevel(pStyleId: String?, styleInfo: StyleInfo) -> Int? {
        guard var currentId = pStyleId else { return nil }
        var visited = Set<String>()
        while true {
            guard !visited.contains(currentId) else { return nil }
            visited.insert(currentId)
            if let level = styleInfo.outlineLevels[currentId] { return level }
            if let level = builtInHeadingLevel(styleId: currentId) { return level }
            guard let parent = styleInfo.basedOn[currentId] else { return nil }
            currentId = parent
        }
    }

    /// `outlineLvl` 0–8 are real heading levels; 9 is what Word gives its own `TOCHeading` style
    /// and must NOT be treated as a heading (it would otherwise put a table-of-contents label at
    /// sidebar depth 10) — that guard applies whether the level came from the paragraph's own
    /// `w:pPr/w:outlineLvl` (checked first — an author can mark a single paragraph as a heading with
    /// no style at all) or from its style, INCLUDING one inherited through `w:basedOn`. The emitted
    /// level is clamped to 1–6 — the vocabulary `OfficeBlock` offers — so an `outlineLvl` of 6, 7 or
    /// 8 all render as level 6 rather than being refused.
    private static func headingLevel(pPr: XMLNode?, pStyleId: String?, styleInfo: StyleInfo) -> Int? {
        if let ownVal = pPr?.child("w:outlineLvl")?.attributes["w:val"], let ownLevel = Int(ownVal), ownLevel <= 8 {
            return min(ownLevel + 1, 6)
        }
        guard let level = resolvedOutlineLevel(pStyleId: pStyleId, styleInfo: styleInfo), level <= 8 else { return nil }
        return min(level + 1, 6)
    }

    // MARK: numbering.xml — numId → abstractNumId → level → format/text/start, with per-numId overrides

    /// One level's numbering definition, whether it came from `w:abstractNum` directly or replaced
    /// wholesale by a `w:num`'s `w:lvlOverride/w:lvl` (same element shape either way — see
    /// `parseLevel`). `lvlText` is the raw `"%1.%2."`-style pattern this level substitutes counters
    /// into; `nil` when the source never declared one (rare, but not an error — `numberedListInfo`
    /// falls back to `OfficeTextBuilder`'s own counting in that case, same as an unresolvable
    /// numId). `start` defaults to 1 — Word omits `w:start` whenever a level simply starts there.
    private struct AbstractLevel {
        var numFmt: String
        var lvlText: String?
        var start: Int
        /// Word's "legal numbering" toggle (`w:isLgl`): when set, EVERY substituted sub-level in
        /// this level's `lvlText` displays as plain Arabic digits regardless of that sub-level's
        /// OWN `w:numFmt` — the convention real contracts use so `1.a.i` still shows as `1.1.1`.
        var isLgl: Bool
    }

    /// A single level's per-numId override, from `w:num/w:lvlOverride`: `startOverride` resets
    /// where that level's counter begins (`w:startOverride`), `lvlReplacement` replaces the WHOLE
    /// level definition for this numId only (`w:lvlOverride/w:lvl`) — Word allows either, both, or
    /// neither on the same `w:lvlOverride` element.
    private struct NumOverride {
        var startOverride: Int?
        var lvlReplacement: AbstractLevel?
    }

    private struct NumberingInfo {
        var abstractNumIdByNumId: [String: String] = [:]
        var abstractLevelsById: [String: [Int: AbstractLevel]] = [:]
        var numIdLevelOverrides: [String: [Int: NumOverride]] = [:]
    }

    /// Parses BOTH `w:abstractNum` (the shared level definitions) and each `w:num`'s own
    /// `w:lvlOverride`s (a per-list exception to those shared definitions — a start value reset,
    /// or an entirely different level) — reading only `w:numFmt` as the old version of this
    /// function did would tell a bullet from a number apart but throws away everything
    /// `numberedListInfo` now needs to compute the actual marker text and honour overrides.
    private static func parseNumbering(from archive: ZipArchive) -> NumberingInfo {
        guard archive.contains("word/numbering.xml"),
              let data = try? archive.data(for: "word/numbering.xml"),
              let root = try? buildTree(data)
        else { return NumberingInfo() }
        var info = NumberingInfo()
        for child in root.children {
            switch child.name {
            case "w:abstractNum":
                guard let abstractId = child.attributes["w:abstractNumId"] else { continue }
                var levels: [Int: AbstractLevel] = [:]
                for lvl in child.children where lvl.name == "w:lvl" {
                    guard let ilvlString = lvl.attributes["w:ilvl"], let ilvl = Int(ilvlString) else { continue }
                    if let level = parseLevel(lvl) { levels[ilvl] = level }
                }
                info.abstractLevelsById[abstractId] = levels
            case "w:num":
                guard let numId = child.attributes["w:numId"],
                      let abstractRef = child.child("w:abstractNumId")?.attributes["w:val"]
                else { continue }
                info.abstractNumIdByNumId[numId] = abstractRef
                var overrides: [Int: NumOverride] = [:]
                for lvlOverride in child.children where lvlOverride.name == "w:lvlOverride" {
                    guard let ilvlString = lvlOverride.attributes["w:ilvl"], let ilvl = Int(ilvlString) else { continue }
                    var override = NumOverride()
                    if let startVal = lvlOverride.child("w:startOverride")?.attributes["w:val"], let start = Int(startVal) {
                        override.startOverride = start
                    }
                    if let lvlNode = lvlOverride.child("w:lvl") {
                        override.lvlReplacement = parseLevel(lvlNode)
                    }
                    if override.startOverride != nil || override.lvlReplacement != nil {
                        overrides[ilvl] = override
                    }
                }
                if !overrides.isEmpty { info.numIdLevelOverrides[numId] = overrides }
            default:
                continue
            }
        }
        return info
    }

    /// A level missing `w:numFmt` entirely is not returned — there is nothing to classify it by,
    /// and the caller's existing "unresolvable" fallback (never fabricate a number) already covers
    /// that. `w:start`'s absence means 1, not "no start" — Word only writes the element when the
    /// level starts somewhere else.
    private static func parseLevel(_ lvl: XMLNode) -> AbstractLevel? {
        guard let fmt = lvl.child("w:numFmt")?.attributes["w:val"] else { return nil }
        let lvlText = lvl.child("w:lvlText")?.attributes["w:val"]
        let start = lvl.child("w:start")?.attributes["w:val"].flatMap(Int.init) ?? 1
        return AbstractLevel(numFmt: fmt, lvlText: lvlText, start: start, isLgl: lvl.child("w:isLgl") != nil)
    }

    /// Resolves one `(numId, ilvl)` to its effective definition: the abstract level, with any
    /// `w:lvlOverride` for THIS numId layered on top (a full replacement first, since Word treats
    /// `w:lvlOverride/w:lvl` as swapping the entire level; then `w:startOverride`, which can apply
    /// even without a replacement — resetting where a shared, unmodified level starts for just
    /// this one list). `nil` when the numId itself doesn't resolve to any abstract definition, or
    /// that abstract definition never declared this level at all.
    private static func resolvedLevel(numId: String, ilvl: Int, info: NumberingInfo) -> AbstractLevel? {
        guard let abstractId = info.abstractNumIdByNumId[numId] else { return nil }
        var level = info.abstractLevelsById[abstractId]?[ilvl]
        if let override = info.numIdLevelOverrides[numId]?[ilvl] {
            if let replacement = override.lvlReplacement { level = replacement }
            if let startOverride = override.startOverride { level?.start = startOverride }
        }
        return level
    }

    /// Per-`(numId, level)` running counts — a numbering definition's counters belong to the numId
    /// (Word continues them across whatever body content intervenes between two paragraphs that
    /// share one), never to where in the document a paragraph happens to sit, so this is a
    /// REFERENCE shared across the whole `read()` call (body, then footnotes, then endnotes, all
    /// walked from one `read()`) rather than a value threaded through every function's parameters
    /// with `inout`.
    private struct ListCounterKey: Hashable { let numId: String; let level: Int }
    private final class ListNumberingState { var counters: [ListCounterKey: Int] = [:] }

    /// Clears every counter for this numId at `level` and DEEPER — used both when a
    /// shallower-or-equal ordered item breaks a deeper run (deeper only: `from: ilvl + 1`) and
    /// when a `bullet`/`none` item at `ilvl` breaks any ordered run AT that level too (self and
    /// deeper: `from: ilvl`). Scoped to `numId` alone — an unrelated list sharing the same `ilvl`
    /// must never see its counters disturbed by this one.
    private static func clearCounters(numId: String, from level: Int, state: ListNumberingState) {
        for key in state.counters.keys where key.numId == numId && key.level >= level {
            state.counters.removeValue(forKey: key)
        }
    }

    /// The reader's own resolved rendering info for one numbered paragraph: `ordered` still drives
    /// `OfficeTextBuilder`'s indentation/bullet fallback (see `OfficeBlock.listItem`), `marker` is
    /// this item's pre-formatted display text when the source's numbering resolves that far. The
    /// OUTER `nil` means `numId="0"` — Word's own sentinel for "this paragraph carries `w:numPr`
    /// but is explicitly NOT numbered" — the caller must emit a plain `.paragraph`, never a
    /// `.listItem`, for that case.
    private static func numberedListInfo(
        numId: String?, ilvl: Int, info: NumberingInfo, state: ListNumberingState
    ) -> (ordered: Bool, marker: String?)? {
        guard let numId else { return (false, nil) }
        guard numId != "0" else { return nil }
        // Unresolvable numId, or a level the abstract definition never declared — today's
        // pre-sprint fallback: never fabricate a number, but the paragraph is still a list item
        // (same reasoning the removed `isOrdered` carried).
        guard let level = resolvedLevel(numId: numId, ilvl: ilvl, info: info) else { return (false, nil) }
        switch level.numFmt {
        case "bullet":
            clearCounters(numId: numId, from: ilvl, state: state)
            return (false, nil)
        case "none":
            // A real numbering level that simply displays nothing — distinct from `bullet`
            // (which `OfficeTextBuilder` draws its own glyph for): passing `""` (not `nil`) tells
            // the builder "render this marker verbatim", i.e. nothing, rather than falling back to
            // a bullet glyph the source never asked for.
            clearCounters(numId: numId, from: ilvl, state: state)
            return (false, "")
        default:
            break
        }
        clearCounters(numId: numId, from: ilvl + 1, state: state)
        let key = ListCounterKey(numId: numId, level: ilvl)
        let next = (state.counters[key] ?? (level.start - 1)) + 1
        state.counters[key] = next
        // No `w:lvlText` to substitute into — the level is still genuinely ordered, but this
        // reader has no way to compute display text for it; `nil` marker tells
        // `OfficeTextBuilder` to fall back to its own simple "N." counting for this item, exactly
        // as it did before this sprint.
        guard let lvlText = level.lvlText else { return (true, nil) }
        let marker = substituteLevelText(
            lvlText, numId: numId, currentLevel: ilvl, currentValue: next, isLgl: level.isLgl,
            info: info, state: state)
        return (true, marker)
    }

    /// Substitutes every `%1`…`%9` token in `lvlText` with that level's counter, formatted by
    /// EITHER that level's own `w:numFmt` (the common case — e.g. `%1` decimal, `%2` letters) OR,
    /// when the CURRENT level is `w:isLgl`, always as decimal (Word's legal-numbering override —
    /// see `AbstractLevel.isLgl`). The level being substituted (`refLevel`) is read from the
    /// counter STATE when it's the current level (the value just incremented by the caller) or
    /// when a shallower level has already been visited; a level never yet reached in this walk
    /// falls back to its own declared `start` — a document whose `lvlText` references a level
    /// that hasn't appeared yet is unusual, but showing that level's start value beats showing
    /// nothing.
    private static func substituteLevelText(
        _ lvlText: String, numId: String, currentLevel: Int, currentValue: Int, isLgl: Bool,
        info: NumberingInfo, state: ListNumberingState
    ) -> String {
        var result = lvlText
        for k in 1...9 {
            let token = "%\(k)"
            guard result.contains(token) else { continue }
            let refLevel = k - 1
            let value: Int
            if refLevel == currentLevel {
                value = currentValue
            } else if let existing = state.counters[ListCounterKey(numId: numId, level: refLevel)] {
                value = existing
            } else {
                value = resolvedLevel(numId: numId, ilvl: refLevel, info: info)?.start ?? 1
            }
            let format = isLgl ? "decimal" : (resolvedLevel(numId: numId, ilvl: refLevel, info: info)?.numFmt ?? "decimal")
            result = result.replacingOccurrences(of: token, with: formatNumber(value, format: format))
        }
        return result
    }

    /// Formats one counter value per Word's `w:numFmt`. Only the formats the sprint brief lists as
    /// actually occurring in real documents get their own case; anything else — an exotic or
    /// future format this reader doesn't specifically know — falls back to plain decimal rather
    /// than throwing or producing no text: a wrong-LOOKING number is honest about "something is
    /// numbered here", a missing one is not (the same posture `w:sym`'s ▯ placeholder takes for an
    /// unmappable glyph).
    private static func formatNumber(_ n: Int, format: String) -> String {
        switch format {
        case "decimalZero": return n >= 0 && n < 10 ? "0\(n)" : "\(n)"
        case "upperRoman": return romanNumeral(n)
        case "lowerRoman": return romanNumeral(n).lowercased()
        case "upperLetter": return letterSequence(n).uppercased()
        case "lowerLetter": return letterSequence(n)
        default: return "\(n)"
        }
    }

    private static func romanNumeral(_ n: Int) -> String {
        guard n > 0 else { return "\(n)" }
        let values: [(Int, String)] = [
            (1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"),
            (50, "L"), (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I"),
        ]
        var remainder = n
        var result = ""
        for (value, symbol) in values {
            while remainder >= value {
                result += symbol
                remainder -= value
            }
        }
        return result
    }

    /// Spreadsheet-column-style base-26 letters (1→a, 26→z, 27→aa, 28→ab, …) — Word's own
    /// `lowerLetter`/`upperLetter` numbering scheme. Lowercase; `formatNumber` uppercases it for
    /// `upperLetter`.
    private static func letterSequence(_ n: Int) -> String {
        guard n > 0 else { return "\(n)" }
        var remainder = n
        var letters = ""
        while remainder > 0 {
            let rem = (remainder - 1) % 26
            letters = String(UnicodeScalar(UInt8(97 + rem))) + letters
            remainder = (remainder - 1) / 26
        }
        return letters
    }

    // MARK: word/_rels/document.xml.rels — relationship id → target

    private struct Relationship {
        /// Embedded: the archive entry path (`"word/media/image1.png"`) `ZipArchive.data(for:)`
        /// can read directly. External: the raw `Target` (a `file:///…` URL) — never a path into
        /// THIS archive, since the bytes live outside it.
        let target: String
        let external: Bool
    }

    private struct Relationships {
        var byId: [String: Relationship] = [:]
    }

    /// Absent from an image-less document exactly like `styles.xml`/`numbering.xml` — falls back
    /// to an empty table, so every `r:embed`/`r:link` lookup below simply misses and the reader
    /// still produces `.image` blocks (marked unresolvable) instead of crashing.
    private static func parseRelationships(from archive: ZipArchive) -> Relationships {
        guard archive.contains("word/_rels/document.xml.rels"),
              let data = try? archive.data(for: "word/_rels/document.xml.rels"),
              let root = try? buildTree(data)
        else { return Relationships() }
        var rels = Relationships()
        for rel in root.children where rel.name == "Relationship" {
            guard let id = rel.attributes["Id"], let target = rel.attributes["Target"] else { continue }
            let external = rel.attributes["TargetMode"] == "External"
            // An embedded Target is package-relative to `word/` ("media/image1.png"); an external
            // Target is already a complete `file:///…`/`http://…` reference and must not be
            // rewritten into a path that looks like it lives in this archive.
            rels.byId[id] = Relationship(target: external ? target : "word/" + target, external: external)
        }
        return rels
    }

    // MARK: Images — w:drawing (DrawingML) and w:pict (legacy VML)

    /// Descends into `mc:AlternateContent` via `mc:Choice` ONLY, never `mc:Fallback` — the two
    /// are alternative renderings of the SAME content (modern DrawingML vs. legacy VML, for a
    /// reader that doesn't understand the newer one), not two pieces of content. Walking both is
    /// the classic bug here: it turns every picture — or text box — in a document that carries
    /// this construct into two. A standalone `w:pict` (no `mc:AlternateContent` wrapper at all —
    /// common in documents saved by, or round-tripped through, an older Word) is genuine content
    /// and IS collected.
    ///
    /// A `w:drawing`/`w:pict` that resolves to no picture at all is NOT automatically an image —
    /// an AutoShape/text-box group is common (a callout box, a decorative rule) and reserving
    /// image space with a broken-picture placeholder for one would tell the reader a picture
    /// failed to load when there never was one. Such a shape contributes its TEXT instead, if it
    /// has any (`w:txbxContent`); a chart or SmartArt diagram (no picture, no text either) gets
    /// `graphicPlaceholderBlock` instead of nothing at all — but only when `allowGraphicPlaceholder`
    /// says this is the right point in the walk to decide that (see below).
    ///
    /// `allowGraphicPlaceholder` exists because `mc:AlternateContent` needs three-way, not
    /// two-way, resolution — `mc:Choice` handled normally when it renders SOMETHING; failing that,
    /// `mc:Fallback` (Word's own already-rendered VML picture of the very chart/diagram `mc:Choice`
    /// couldn't be drawn from — reachable for the first time by this sprint); only when NEITHER
    /// yields anything does a placeholder get drawn. Recursing into `mc:Choice`/`mc:Fallback` with
    /// `allowGraphicPlaceholder: false` lets this same function do the picture-then-text resolution
    /// for each half without either one jumping ahead to a placeholder on its own — the
    /// `mc:AlternateContent` case below is the ONLY place that decides "neither half gave us
    /// anything, use the placeholder", exactly once per `mc:AlternateContent`, from the CHOICE
    /// half's own declared size (Word always duplicates `wp:extent` onto both halves, but Choice is
    /// the modern, up-to-date wrapper and is preferred for consistency with the "Choice wins" rule
    /// everywhere else in this function).
    private static func collectDrawingBlocks(
        in node: XMLNode, styleInfo: StyleInfo, numbering: NumberingInfo, relationships: Relationships,
        notes: NoteNumbering, listState: ListNumberingState, allowGraphicPlaceholder: Bool = true
    ) -> [OfficeBlock] {
        var blocks: [OfficeBlock] = []
        func walk(_ node: XMLNode) {
            for child in node.children {
                switch child.name {
                case "mc:AlternateContent":
                    guard let choice = child.child("mc:Choice") else { continue }
                    let choiceBlocks = collectDrawingBlocks(
                        in: choice, styleInfo: styleInfo, numbering: numbering, relationships: relationships,
                        notes: notes, listState: listState, allowGraphicPlaceholder: false)
                    if !choiceBlocks.isEmpty {
                        blocks.append(contentsOf: choiceBlocks)
                        continue
                    }
                    // Choice gave us nothing renderable (the chart/diagram case) — reach for the
                    // Fallback Word left for exactly this situation: an older reader's rendering,
                    // most often a `w:pict`/VML picture of the SAME chart/diagram, walked through
                    // the identical "w:pict" case below (so its own picture-vs-text resolution,
                    // and any relationship-id lookup, is reused unchanged, not reimplemented here).
                    let fallbackBlocks = child.child("mc:Fallback").map {
                        collectDrawingBlocks(
                            in: $0, styleInfo: styleInfo, numbering: numbering, relationships: relationships,
                            notes: notes, listState: listState, allowGraphicPlaceholder: false)
                    } ?? []
                    if !fallbackBlocks.isEmpty {
                        blocks.append(contentsOf: fallbackBlocks)
                    } else if allowGraphicPlaceholder,
                              let drawing = choice.firstDescendant("w:drawing"),
                              let placeholder = graphicPlaceholderBlock(for: drawing) {
                        blocks.append(placeholder)
                    }
                case "w:drawing":
                    let pictures = imageBlocks(fromDrawing: child, relationships: relationships)
                    if !pictures.isEmpty {
                        blocks.append(contentsOf: pictures)
                        continue
                    }
                    let text = textBoxBlocks(
                        in: child, styleInfo: styleInfo, numbering: numbering,
                        relationships: relationships, notes: notes, listState: listState)
                    if !text.isEmpty {
                        blocks.append(contentsOf: text)
                    } else if allowGraphicPlaceholder, let placeholder = graphicPlaceholderBlock(for: child) {
                        // A chart/diagram with no `mc:AlternateContent` wrapper at all (some
                        // producers emit one without the legacy-fallback ceremony) — there is no
                        // Fallback to try, so this is the placeholder's only chance to appear.
                        blocks.append(placeholder)
                    }
                case "w:pict":
                    if let block = imageBlock(fromPict: child, relationships: relationships) {
                        blocks.append(block)
                    } else {
                        blocks.append(contentsOf: textBoxBlocks(
                            in: child, styleInfo: styleInfo, numbering: numbering,
                            relationships: relationships, notes: notes, listState: listState))
                    }
                default:
                    walk(child)
                }
            }
        }
        walk(node)
        return blocks
    }

    /// Detects a `w:drawing` whose content is a chart or SmartArt diagram graphicFrame — DrawingML
    /// this reader has no vector renderer for. Neither has an `a:blip` (a picture) nor a
    /// `w:txbxContent` (typed caption text), so `imageBlocks`/`textBoxBlocks` both return empty and
    /// — absent this — the whole object vanishes with no trace at all (gap-list rows 11/12: every
    /// box, label and connector of a SmartArt diagram, or an entire embedded chart, silently gone).
    ///
    /// Detected by the DrawingML element the chart/diagram part is actually REFERENCED through —
    /// `c:chart` (a chart's `r:id` back to `word/charts/chartN.xml`) or `dgm:relIds` (a SmartArt
    /// diagram's `r:dm`/`r:lo`/`r:qs`/`r:cs` back to `word/diagrams/*.xml`) — never by
    /// `a:graphicData`'s `uri` string, which is a full schema URL this reader would otherwise have
    /// to string-match loosely for no real gain (the two element names are exact and unambiguous).
    /// Returns `nil` for anything else — an AutoShape/connector group with no picture and no typed
    /// text (already covered by `textBoxBlocks`'s own tests) is legitimately EMPTY, not a graphic
    /// this reader failed to render; placeholder-ing it would misreport "something is missing here"
    /// for a callout box the author genuinely left blank.
    private static func graphicPlaceholderBlock(for drawing: XMLNode) -> OfficeBlock? {
        let label: String
        if drawing.firstDescendant("c:chart") != nil {
            label = "Chart"
        } else if drawing.firstDescendant("dgm:relIds") != nil {
            label = "Diagram"
        } else {
            return nil
        }
        // Same element, same units, same conversion `imageBlocks` reads its own picture sizing
        // from — a chart/diagram graphicFrame carries `wp:extent` on the identical
        // `wp:inline`/`wp:anchor` wrapper a picture would.
        guard let extent = drawing.firstDescendant("wp:extent"),
              let cx = extent.attributes["cx"].flatMap(Double.init),
              let cy = extent.attributes["cy"].flatMap(Double.init)
        else { return nil }
        return .unsupportedGraphic(label: label, size: CGSize(width: emuToPoints(cx), height: emuToPoints(cy)))
    }

    /// A shape's caption/callout text lives in `w:txbxContent` (one or more, nested arbitrarily
    /// deep inside `wps:wsp`/`wpg:wgp`), each holding ordinary `w:p` paragraphs — reads them with
    /// the SAME paragraph classification as the document body (`parseParagraph`), so a heading or
    /// list style inside a text box is honoured exactly like one in the body. An empty paragraph
    /// here (Word leaves a placeholder `<w:p/>` in the text frame of an otherwise-empty AutoShape)
    /// is real content in the document BODY but not here — a shape with nothing typed into it has
    /// no text, and must produce no block; the body's own "empty paragraph = a blank line" reading
    /// does not apply to shape decoration.
    private static func textBoxBlocks(
        in node: XMLNode, styleInfo: StyleInfo, numbering: NumberingInfo, relationships: Relationships,
        notes: NoteNumbering, listState: ListNumberingState
    ) -> [OfficeBlock] {
        var blocks: [OfficeBlock] = []
        for txbx in node.allDescendants("w:txbxContent") {
            for p in txbx.children where p.name == "w:p" {
                let paragraphBlocks = parseParagraph(
                    p, styleInfo: styleInfo, numbering: numbering, relationships: relationships,
                    notes: notes, listState: listState)
                blocks.append(contentsOf: paragraphBlocks.filter { !isEmptyTextBlock($0) })
            }
        }
        return blocks
    }

    /// A text/heading/list block with no spans at all — used only to filter a text box's OWN
    /// placeholder-empty paragraph (see `textBoxBlocks`) out of what it contributes; an image or
    /// table block is never "empty" in this sense and always passes through.
    private static func isEmptyTextBlock(_ block: OfficeBlock) -> Bool {
        switch block {
        case .paragraph(let spans, _, _, _, _), .heading(_, let spans, _, _, _, _), .listItem(_, _, let spans, _, _, _, _, _):
            return spans.isEmpty
        case .table, .image, .unsupportedGraphic, .formula:
            return false
        }
    }

    /// `wp:extent` (EMU) is present on both an inline (`wp:inline`) and a floating (`wp:anchor`)
    /// drawing, so it's read by name rather than by which wrapper it's under. No `wp:extent` means
    /// this isn't a shape this reader understands sizing for — silently produces no block, same as
    /// a run with no text at all producing no span. An empty result here also means "not a
    /// picture" to the caller, which then looks for text instead — so this must return `[]`, never
    /// an unresolvable placeholder, when there is no `a:blip` anywhere inside.
    ///
    /// A `w:drawing` isn't always ONE picture — Word groups multiple pictures under a single
    /// `w:drawing` (`wpg:wgp`) routinely (e.g. two logos placed side by side), and EVERY `a:blip`
    /// found inside is a real, separate picture that must not be silently merged into one or
    /// dropped (measured on the real government-guide test file: a single `w:drawing` there
    /// groups exactly two `pic:pic` elements, two DISTINCT embedded pictures). A picture inside a
    /// group is positioned and sized in that group's own LOCAL child coordinate space, not EMU —
    /// `groupScale`/`collectGroupedPictures` chain the real transform (every nested group's own
    /// `ext ÷ chExt`) down to each picture rather than approximating with the group's outer box.
    private static func imageBlocks(fromDrawing drawing: XMLNode, relationships: Relationships) -> [OfficeBlock] {
        guard let extent = drawing.firstDescendant("wp:extent"),
              let cx = extent.attributes["cx"].flatMap(Double.init),
              let cy = extent.attributes["cy"].flatMap(Double.init)
        else { return [] }
        let wholeDrawingSize = CGSize(width: emuToPoints(cx), height: emuToPoints(cy))
        guard let outerGroup = drawing.firstDescendant("wpg:wgp") else {
            // No group — by far the common case, a single inline/floating picture whose own box
            // IS the drawing's `wp:extent`. (Still collects every `a:blip`, not just the first,
            // in case Word ever emits more than one ungrouped — no real file exercises that, but
            // nothing here assumes exactly one.)
            return drawing.allDescendants("a:blip").map { blip in
                .image(id: resolveId(relId: blip.attributes["r:embed"] ?? blip.attributes["r:link"], relationships: relationships),
                       size: wholeDrawingSize)
            }
        }
        var images: [OfficeBlock] = []
        let scale = groupScale(of: outerGroup) ?? AxisScale(x: 1, y: 1)
        collectGroupedPictures(in: outerGroup, scale: scale, fallbackSize: wholeDrawingSize,
                                relationships: relationships, into: &images)
        return images
    }

    /// The multiplier that converts a value expressed in THIS group's own child-coordinate units
    /// (`wpg:grpSpPr/a:xfrm`'s `chOff`/`chExt`) into the units its OWN `off`/`ext` are expressed
    /// in (its parent's child units, or real EMU at the outermost group) — i.e. one link in the
    /// nested-group transform chain. `nil` when the group carries no usable `a:xfrm` (missing, or
    /// a degenerate `chExt` of 0 on an axis) — the caller then chains through unchanged on that
    /// axis rather than dividing by zero, which is a defensible "no additional scaling known"
    /// reading, not a crash.
    private struct AxisScale { var x: Double; var y: Double }

    private static func groupScale(of group: XMLNode) -> AxisScale? {
        guard let xfrm = group.child("wpg:grpSpPr")?.child("a:xfrm"),
              let ext = xfrm.child("a:ext"), let chExt = xfrm.child("a:chExt"),
              let extCx = ext.attributes["cx"].flatMap(Double.init), let extCy = ext.attributes["cy"].flatMap(Double.init),
              let chExtCx = chExt.attributes["cx"].flatMap(Double.init), let chExtCy = chExt.attributes["cy"].flatMap(Double.init)
        else { return nil }
        return AxisScale(x: chExtCx == 0 ? 1 : extCx / chExtCx, y: chExtCy == 0 ? 1 : extCy / chExtCy)
    }

    /// Walks one group's DIRECT children: a nested `wpg:grpSp` multiplies `scale` by its OWN
    /// `groupScale` and recurses (chaining the transform one more level down before it reaches
    /// any picture inside it); a `pic:pic` is sized by its own `pic:spPr/a:xfrm/a:ext` — read as a
    /// PRECISE direct-child path, never a broad descendant search, because `a:blip/a:extLst/a:ext`
    /// is an unrelated extension-marker element that also happens to be named `a:ext` and sits
    /// EARLIER in the same picture (an unqualified search would silently grab attributes with no
    /// `cx`/`cy` and look like "no size" instead of the real one) — converted with the accumulated
    /// `scale`. A picture that (unusually) carries no own `a:xfrm/a:ext` falls back to
    /// `fallbackSize` (the whole drawing's `wp:extent`) rather than a zero. Anything else at this
    /// level (`wps:wsp` — a connecting line, a plain AutoShape with no picture) contributes no
    /// image; its text, if any, is handled separately by `textBoxBlocks`.
    private static func collectGroupedPictures(
        in group: XMLNode, scale: AxisScale, fallbackSize: CGSize, relationships: Relationships, into images: inout [OfficeBlock]
    ) {
        for child in group.children {
            switch child.name {
            case "wpg:grpSp":
                let nestedScale: AxisScale
                if let inner = groupScale(of: child) {
                    nestedScale = AxisScale(x: scale.x * inner.x, y: scale.y * inner.y)
                } else {
                    nestedScale = scale
                }
                collectGroupedPictures(in: child, scale: nestedScale, fallbackSize: fallbackSize,
                                        relationships: relationships, into: &images)
            case "pic:pic":
                guard let blip = child.firstDescendant("a:blip") else { continue }
                let relId = blip.attributes["r:embed"] ?? blip.attributes["r:link"]
                let ownExt = child.child("pic:spPr")?.child("a:xfrm")?.child("a:ext")
                let size: CGSize
                if let ownExt, let cx = ownExt.attributes["cx"].flatMap(Double.init), let cy = ownExt.attributes["cy"].flatMap(Double.init) {
                    size = CGSize(width: emuToPoints(cx * scale.x), height: emuToPoints(cy * scale.y))
                } else {
                    size = fallbackSize
                }
                images.append(.image(id: resolveId(relId: relId, relationships: relationships), size: size))
            default:
                continue
            }
        }
    }

    /// A best-defensible non-zero fallback for a VML shape whose `style` is missing or doesn't
    /// parse — invariant 1 (never reserve a zero/collapsed area) applies just as much to a legacy
    /// shape this reader can't size as to a not-yet-loaded markdown image. One inch square is
    /// arbitrary but visible and stable; there is no better signal available in that case.
    private static let unresolvedVMLSize = CGSize(width: 72, height: 72)

    /// Legacy VML: the image reference is `v:imagedata/@r:id` (note `r:id`, not `r:embed` —
    /// VML predates the DrawingML relationship-attribute convention), and the size lives on the
    /// enclosing shape's CSS-like `style` attribute (`v:shape`/`v:rect`/…) rather than a
    /// dedicated extent element, so it's found by attribute rather than by element name. A single
    /// `w:pict` CAN itself group several `v:imagedata` (mirroring the DrawingML case above), but
    /// that only happens here as the Fallback half of an `mc:AlternateContent` this reader never
    /// descends into (see `collectImages`) — a genuinely standalone multi-picture VML group is not
    /// exercised by either real test file, so only the first `v:imagedata` is read; a document that
    /// hits this would still get one correctly-sized picture, not a crash or a dropped block.
    private static func imageBlock(fromPict pict: XMLNode, relationships: Relationships) -> OfficeBlock? {
        guard let imagedata = pict.firstDescendant("v:imagedata") else { return nil }
        let styleNode = pict.firstDescendant(withAttribute: "style")
        let size = parseVMLStyleSize(styleNode?.attributes["style"]) ?? unresolvedVMLSize
        return .image(id: resolveId(relId: imagedata.attributes["r:id"], relationships: relationships), size: size)
    }

    /// A relationship id resolves to the archive entry path for an embedded image, to
    /// `"docx-unresolvable:…"` for anything this reader genuinely cannot hand pixels for (no id on
    /// the element at all, or an id that doesn't appear in `document.xml.rels` — a malformed/edited
    /// document), or to `"docx-external-link:…"` for a real, external (`r:link`) target — every one
    /// of these still returns a block, never nil, so a picture never silently vanishes from the
    /// block list. `MarkdownDocument`'s image loader treats the first prefix as "always show a
    /// sized placeholder, never attempt an archive lookup" and the second as "try the folder-grant
    /// path a blocked local image already has, using the raw target as the URL to resolve".
    private static func resolveId(relId: String?, relationships: Relationships) -> String {
        guard let relId else { return unresolvableId("no-relationship-id") }
        guard let rel = relationships.byId[relId] else { return unresolvableId(relId) }
        // A `r:link` (external target, `TargetMode="External"`) is a REAL, resolvable reference —
        // unlike the two cases above, this isn't a malformed document, just one whose pixels live
        // OUTSIDE this archive (under the sandbox, unreadable, and macOS never prompts — see
        // CLAUDE.md invariant 9). Marked with its OWN prefix, never `docx-unresolvable:`, so the
        // viewer can tell "this document points somewhere real, just can't reach it yet" apart
        // from "this reference doesn't resolve to anything at all" — only the former can offer the
        // SAME folder-grant placeholder a blocked markdown sibling image already gets
        // (`FolderAccess`/`needsAccessImage()` in `MarkdownDocument`), reused rather than a second
        // "broken image" convention invented for this one case.
        return rel.external ? externalLinkId(rel.target) : rel.target
    }

    private static func unresolvableId(_ reason: String) -> String { "docx-unresolvable:\(reason)" }

    /// A linked (not embedded) image's id — carries the RAW target exactly as
    /// `word/_rels/document.xml.rels` wrote it (a `file:///…` or `http(s)://…` URL), prefixed so
    /// `MarkdownDocument`'s image loader can route it to the folder-grant placeholder instead of
    /// the generic broken-image icon `docx-unresolvable:` ids fall back to.
    private static func externalLinkId(_ target: String) -> String { "docx-external-link:\(target)" }

    /// EMU (English Metric Units) is DrawingML's native length unit: 914400 per inch, 12700 per
    /// point (72 pt/inch × 12700 = 914400). Verified against the real test file: `cx="6400800"`
    /// (a 7-inch-wide picture) must yield exactly 504 pt.
    private static func emuToPoints(_ emu: Double) -> CGFloat { CGFloat(emu / 12700) }

    /// A `v:shape`-family `style` attribute is CSS-like declarations (`"width:7in;height:185.25pt"`),
    /// not real CSS — but `in`/`pt`/`px`/`cm`/`mm` behave like their CSS namesakes. A BARE number
    /// (no unit suffix, e.g. `width:1665`) is treated as points: that's Word's own convention for
    /// most unmarked VML dimensions, though a handful of older shapes instead use it as a drawing
    /// COORDINATE (relative to `coordsize`), which this does not attempt to detect — there is no
    /// reliable signal in the shape alone to tell the two apart, so the point-based reading is used
    /// as the best-defensible value rather than fabricating a zero.
    private static func parseVMLStyleSize(_ style: String?) -> CGSize? {
        guard let style else { return nil }
        var width: CGFloat?
        var height: CGFloat?
        for declaration in style.split(separator: ";") {
            let parts = declaration.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { continue }
            let property = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parseCSSLikeLength(parts[1].trimmingCharacters(in: .whitespaces))
            if property == "width" { width = value }
            if property == "height" { height = value }
        }
        guard let width, let height else { return nil }
        return CGSize(width: width, height: height)
    }

    private static func parseCSSLikeLength(_ raw: String) -> CGFloat? {
        // Longest-suffix-first: "in" isn't a prefix collision here, but this keeps the table
        // self-evidently order-independent if a two-letter unit is ever added.
        let pointsPerUnit: [(suffix: String, factor: Double)] = [
            ("in", 72), ("pt", 1), ("px", 0.75), ("cm", 72 / 2.54), ("mm", 72 / 25.4),
        ]
        for (suffix, factor) in pointsPerUnit where raw.hasSuffix(suffix) {
            guard let number = Double(raw.dropLast(suffix.count)) else { return nil }
            return CGFloat(number * factor)
        }
        // No unit suffix — see the point-based fallback note on the caller.
        guard let number = Double(raw) else { return nil }
        return CGFloat(number)
    }

    // MARK: word/document.xml — body → blocks

    private static func parseBody(
        _ body: XMLNode, styleInfo: StyleInfo, numbering: NumberingInfo, relationships: Relationships,
        notes: NoteNumbering, listState: ListNumberingState
    ) -> [OfficeBlock] {
        body.children.flatMap {
            parseBodyChild(
                $0, styleInfo: styleInfo, numbering: numbering, relationships: relationships, notes: notes,
                listState: listState)
        }
    }

    /// A body child is normally `w:p` or `w:tbl`. `w:sdt` (a content control / structured document
    /// tag) is UNWRAPPED here, never skipped — Word uses it to wrap a whole paragraph or table (a
    /// "click here to enter text" field, a repeating-section template) inside `w:sdtContent`, and a
    /// reader that treats the wrapper as opaque loses everything the author typed inside it, which
    /// is exactly the class of bug this sprint exists to close. Recurses so a content control
    /// nested inside another one is unwrapped all the way down; `w:sdtPr` (placeholder-text hints,
    /// a lock setting, …) is deliberately never read — the only thing needed from `w:sdt` is its
    /// content. Anything else at this level (the body's own trailing `w:sectPr`) is not a block.
    private static func parseBodyChild(
        _ child: XMLNode, styleInfo: StyleInfo, numbering: NumberingInfo, relationships: Relationships,
        notes: NoteNumbering, listState: ListNumberingState
    ) -> [OfficeBlock] {
        switch child.name {
        case "w:p":
            return parseParagraph(
                child, styleInfo: styleInfo, numbering: numbering, relationships: relationships,
                notes: notes, listState: listState)
        case "w:tbl":
            return [parseTable(
                child, styleInfo: styleInfo, numbering: numbering, relationships: relationships, notes: notes,
                listState: listState)]
        case "w:sdt":
            guard let content = child.child("w:sdtContent") else { return [] }
            return content.children.flatMap {
                parseBodyChild(
                    $0, styleInfo: styleInfo, numbering: numbering, relationships: relationships,
                    notes: notes, listState: listState)
            }
        default:
            return []
        }
    }

    /// A paragraph normally contributes exactly one block, but one carrying an image contributes
    /// its text block (if it has any text) FOLLOWED BY that image's block(s), in source order —
    /// never reordering the paragraph's own text to make room for the picture. A paragraph that
    /// carries ONLY a picture (spans empty, the common case: Word puts an image in a paragraph of
    /// its own) contributes no empty text block, so callers never see a phantom `.paragraph(spans: [])`
    /// standing in for a picture.
    private static func parseParagraph(
        _ p: XMLNode, styleInfo: StyleInfo, numbering: NumberingInfo, relationships: Relationships,
        notes: NoteNumbering, listState: ListNumberingState
    ) -> [OfficeBlock] {
        let pPr = p.child("w:pPr")
        // Read directly off THIS paragraph's own `w:pPr` — not resolved through the `w:basedOn`
        // style chain `resolvedOutlineLevel` walks for headings. Word's RTL-paragraph toggle writes
        // `w:bidi` onto the paragraph itself when applied from the UI; a style-level default that
        // ALSO needs the basedOn chain to reach it is a real possibility this reader doesn't yet
        // resolve — narrower than "wrong", but worth stating rather than silently assuming.
        let rtl = isOn(pPr, "w:bidi")
        // `pStyleId` is read here for `alignment`/`tabStops`' style-chain fallback below; `collectSpans`
        // reads its own copy off `p`'s `w:pPr` directly (see its doc) rather than receiving it as a
        // parameter, but it is the SAME value — both read the identical `w:pPr/w:pStyle` off the
        // identical paragraph node.
        let pStyleIdForAlignment = pPr?.child("w:pStyle")?.attributes["w:val"]
        // An EXPLICIT `w:jc` on this paragraph always wins; failing that, the style chain (S13's
        // `basedOn` walk, reused via `resolvedAlignment`) — never a hardcoded `.left`. This is what
        // must win over `rtl`'s own implicit edge (see `OfficeBlock`'s doc): `OfficeTextBuilder`
        // already gives an explicit `alignment` that precedence, so resolving it correctly here is
        // the whole of this reader's part of that contract.
        let alignment = pPr?.child("w:jc")?.attributes["w:val"].flatMap(alignmentFromJc)
            ?? resolvedAlignment(pStyleId: pStyleIdForAlignment, styleInfo: styleInfo)
        let tabStops: [CGFloat] = {
            if let tabsNode = pPr?.child("w:tabs") {
                let stops = parseTabStops(tabsNode)
                if !stops.isEmpty { return stops }
            }
            return resolvedTabStops(pStyleId: pStyleIdForAlignment, styleInfo: styleInfo) ?? []
        }()
        let spans = collectSpans(in: p, styleInfo: styleInfo, relationships: relationships, notes: notes)
        let drawingBlocks = collectDrawingBlocks(
            in: p, styleInfo: styleInfo, numbering: numbering, relationships: relationships,
            notes: notes, listState: listState)
        // A display equation (`m:oMathPara`) is collected separately from `spans`, not folded into
        // them — `collectSpans` deliberately SKIPS `m:oMathPara` (see its own switch) so its content
        // is never also flattened into plain text there; a bare inline `m:oMath` takes the opposite
        // path (degraded to a `Span` INSIDE `spans` by `collectSpans` itself), matching this
        // sprint's inline-vs-block decision (see `WebBlock`'s doc / `OfficeBlock.formula`'s doc).
        let formulaBlocks = collectFormulaBlocks(in: p)
        // Heading wins over list, even when the paragraph ALSO carries `w:numPr` — Word-authored
        // contracts routinely attach a multilevel list to their heading styles so "1. Definitions"
        // / "2.1 Interpretation" number themselves, and `outlineLvl` is the author's explicit
        // "this is a heading at level N"; `numPr` only says how it happens to be numbered. Word's
        // own navigation pane treats such a paragraph as a heading, not a list item, and the
        // heading level already carries the hierarchy a list level would have expressed. Losing
        // this precedence would drop every clause heading in such a document out of the outline
        // sidebar — silently, since parsing still "succeeds". `outlineLvl 9` is still not a
        // heading (see `headingLevel`), so that case correctly falls through to `.listItem` below.
        // A heading's own numPr counter is deliberately NOT advanced here — this reader doesn't
        // render a heading's list-derived number into its text at all, so touching `listState`
        // for it would only make an unrelated LATER list item at the same numId/level skip a
        // value it never visibly used.
        let pStyleId = pPr?.child("w:pStyle")?.attributes["w:val"]
        let textBlock: OfficeBlock?
        let skipEmptyText = spans.isEmpty && (!drawingBlocks.isEmpty || !formulaBlocks.isEmpty)
        if let level = headingLevel(pPr: pPr, pStyleId: pStyleId, styleInfo: styleInfo) {
            textBlock = skipEmptyText ? nil
                : .heading(level: level, spans: spans, rtl: rtl, alignment: alignment, tabStops: tabStops)
        } else if let numPr = pPr?.child("w:numPr") {
            let ilvl = Int(numPr.child("w:ilvl")?.attributes["w:val"] ?? "") ?? 0
            let numId = numPr.child("w:numId")?.attributes["w:val"]
            // `numberedListInfo` returns `nil` only for Word's `numId="0"` sentinel — "carries
            // `w:numPr` but is explicitly NOT numbered" — which reads as an ordinary paragraph,
            // never a list item.
            if let info = numberedListInfo(numId: numId, ilvl: ilvl, info: numbering, state: listState) {
                textBlock = skipEmptyText ? nil
                    : .listItem(level: ilvl, ordered: info.ordered, spans: spans, marker: info.marker, rtl: rtl,
                                alignment: alignment, tabStops: tabStops)
            } else {
                textBlock = skipEmptyText ? nil
                    : .paragraph(spans: spans, rtl: rtl, alignment: alignment, tabStops: tabStops)
            }
        } else {
            textBlock = skipEmptyText ? nil
                : .paragraph(spans: spans, rtl: rtl, alignment: alignment, tabStops: tabStops)
        }
        var blocks: [OfficeBlock] = []
        if let textBlock { blocks.append(textBlock) }
        blocks.append(contentsOf: drawingBlocks)
        blocks.append(contentsOf: formulaBlocks)
        return blocks
    }

    /// Finds every `m:oMathPara` (a display equation on its own line) anywhere inside a paragraph
    /// and translates each `m:oMath` it wraps into a `.formula` block — one block per equation, in
    /// document order. Deliberately shallow compared to `collectDrawingBlocks`: real documents put
    /// `m:oMathPara` directly as a `w:p` child, not buried inside `mc:AlternateContent`, but the
    /// generic `default: walk` still descends through anything unanticipated (a tracked-change
    /// wrapper, say) so an equation is never missed just because Word nested it one level deeper
    /// than expected. Does NOT recurse into `m:oMathPara` itself once found — its own children are
    /// exactly the `m:oMath` elements being collected, not further paragraph structure to walk.
    private static func collectFormulaBlocks(in node: XMLNode) -> [OfficeBlock] {
        var blocks: [OfficeBlock] = []
        func walk(_ node: XMLNode) {
            for child in node.children {
                if child.name == "m:oMathPara" {
                    for oMath in child.children where oMath.name == "m:oMath" {
                        blocks.append(formulaBlock(for: oMath))
                    }
                    continue
                }
                walk(child)
            }
        }
        walk(node)
        return blocks
    }

    /// One `m:oMath` → one `.formula` block, with the SAME never-nothing fallback ladder every
    /// other content type in this reader uses: real LaTeX shape when the translation produced any
    /// (`OmmlTranslator.latex` already degrades unrecognized sub-constructs to their own text, so
    /// this is usually non-empty even for equations this translator only partially understands);
    /// failing that, the equation's flattened text as an ordinary paragraph; failing THAT — an
    /// `m:oMath` with no `m:t` anywhere in it at all — a literal, honest placeholder rather than a
    /// block that renders as nothing (the brief's explicit requirement: "an equation with no
    /// translatable content at all still produces something visible").
    private static func formulaBlock(for oMath: XMLNode) -> OfficeBlock {
        let latex = OmmlTranslator.latex(for: oMath).trimmingCharacters(in: .whitespacesAndNewlines)
        if !latex.isEmpty { return .formula(latex: latex) }
        let text = OmmlTranslator.flattenText(oMath).trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty { return .paragraph(spans: [Span(text: text)]) }
        return .paragraph(spans: [Span(text: "[equation]")])
    }

    /// A grid position a row's own `<w:tc>` sequence doesn't literally cover — because `w:tcPr`
    /// carries an ANCHOR reference, not a grid coordinate — so this reader must derive each cell's
    /// starting grid column itself: walking a row's `<w:tc>` elements left to right, accumulating
    /// each one's own width (`w:gridSpan`, default 1) as it goes, is exactly that derivation. A
    /// well-formed row's cells always sum to the table's full grid width (a vertically-continuing
    /// cell still carries its own `<w:tc>` occupying its column, per spec), so this cumulative walk
    /// lands on the correct column even when two rows have a different NUMBER of `<w:tc>` (a
    /// horizontal merge changes how many `<w:tc>` a row needs without changing the grid it spans).
    private static func parseTable(
        _ tbl: XMLNode, styleInfo: StyleInfo, numbering: NumberingInfo, relationships: Relationships,
        notes: NoteNumbering, listState: ListNumberingState
    ) -> OfficeBlock {
        let rowNodes = tbl.children.filter { $0.name == "w:tr" }
        var rows: [[Cell]] = []
        // Grid column → where in `rows` its currently-open vertical-merge anchor lives, so a
        // `continue` cell several rows down can find the top cell and extend ITS `rowSpan` instead
        // of becoming a cell of its own.
        var openMerge: [Int: (row: Int, cell: Int)] = [:]
        for row in rowNodes {
            var rowCells: [Cell] = []
            var gridCol = 0
            for tc in row.children where tc.name == "w:tc" {
                let tcPr = tc.child("w:tcPr")
                let colSpan = tcPr?.child("w:gridSpan")?.attributes["w:val"].flatMap(Int.init) ?? 1
                let vMerge = tcPr?.child("w:vMerge")
                // `w:vMerge` present with NO `w:val` — not `val="restart"` — is Word's default for
                // "this cell continues the merge above", the #1 footgun measured on the real corpus
                // (13 of 16 vertical merges omit `w:val` entirely). Reading a bare `<w:vMerge/>` as
                // the start of a fresh merge is the single most common docx-reader bug there is.
                let continuesMerge = vMerge != nil && vMerge?.attributes["w:val"] != "restart"
                if continuesMerge {
                    // This cell's own paragraphs are read (`tc.children` below, if ever needed) but
                    // deliberately DISCARDED, never rendered — Word routinely leaves stale leftover
                    // text in a continue cell from before the merge existed, and showing it would
                    // draw a phantom extra line under a merged cell that visually has none. No cell
                    // is emitted for this grid position at all — it is covered, not empty.
                    if let anchor = openMerge[gridCol] {
                        rows[anchor.row][anchor.cell].rowSpan += 1
                    }
                    // No open merge at this column (a malformed/edited document) — there is nothing
                    // to extend, and a `continue` cell is never content of its own, so it is simply
                    // dropped rather than fabricated into a normal cell.
                } else {
                    let blocks = collectCellBlocks(
                        tc, styleInfo: styleInfo, numbering: numbering, relationships: relationships, notes: notes,
                        listState: listState)
                    let (borderColor, borderWidth) = cellBorder(tcPr)
                    rowCells.append(Cell(
                        blocks: blocks, rowSpan: 1, colSpan: colSpan,
                        backgroundColor: cellShading(tcPr), borderColor: borderColor, borderWidth: borderWidth,
                        width: cellWidth(tcPr)))
                    if vMerge != nil {
                        // `val="restart"` — the top of a genuine new vertical-merge chain; later
                        // `continue` cells at this column extend THIS cell's `rowSpan`.
                        openMerge[gridCol] = (rows.count, rowCells.count - 1)
                    } else {
                        // An ORDINARY cell with no `w:vMerge` element at all is not part of any
                        // merge and can never be extended — it must not become continuable just
                        // because a later (malformed) row has a stray `continue` at this column.
                        // It also ends whatever chain was open here before it.
                        openMerge.removeValue(forKey: gridCol)
                    }
                }
                gridCol += colSpan
            }
            rows.append(rowCells)
        }
        // Defensive clamp: an anchor's `rowSpan` can never claim more rows than the table actually
        // has left below it. This reader's own construction above can't overshoot (it only grows a
        // `rowSpan` once per genuinely-encountered `continue` row, and there can never be more of
        // those than real rows), but a malformed/hand-edited document is exactly the kind of input
        // that must never be trusted to size itself — the same posture as never trusting a ZIP
        // entry's declared size.
        for r in rows.indices {
            for c in rows[r].indices {
                rows[r][c].rowSpan = min(rows[r][c].rowSpan, rowNodes.count - r)
            }
        }
        // Leading run only — a header row can never follow an ordinary one, and the source is
        // trusted over any guess (an un-marked table defaults to `headerRows: 0`, never 1).
        var headerRows = 0
        for row in rowNodes {
            let isHeader = row.child("w:trPr")?.children.contains { $0.name == "w:tblHeader" } ?? false
            guard isHeader else { break }
            headerRows += 1
        }
        return .table(rows: rows, headerRows: headerRows)
    }

    /// A cell's own shading — `w:tcPr/w:shd/@w:fill`, a literal hex colour, or the string
    /// `"auto"`, Word's own "no fill" sentinel (the overwhelmingly common case — most cells carry
    /// an explicit `w:shd` with `fill="auto"` even when the author never touched shading at all,
    /// since Word writes it as part of the cell's resolved formatting). `"auto"` reads as `nil` —
    /// unshaded — exactly like an absent `w:shd` entirely, never as a fabricated colour.
    private static func cellShading(_ tcPr: XMLNode?) -> NSColor? {
        guard let fill = tcPr?.child("w:shd")?.attributes["w:fill"], fill.lowercased() != "auto" else { return nil }
        return colorFromHex(fill)
    }

    /// A cell's border, reduced to the ONE colour/width `Cell` has room for (see its own doc: a
    /// real per-edge model is out of this sprint's scope) — the first of `w:tcBorders`' four edges,
    /// checked top/left/bottom/right, that is actually drawn (`w:val` present and neither `"nil"`
    /// nor `"none"`, OOXML's two ways of saying "no border on this edge"). Real tables overwhelmingly
    /// border all four edges identically, so "the first drawn edge" and "the cell's border" agree in
    /// practice; a cell with genuinely mixed edges loses that distinction, honestly, rather than
    /// this reader inventing a fifth field nothing here would fill in consistently. `w:sz` is in
    /// EIGHTHS of a point (ECMA-376 §17.4.66) — divided by 8, not 2 (that's `w:sz`'s OTHER unit,
    /// half-points, used for run/paragraph mark sizes — the two `w:sz` attributes are unrelated
    /// despite sharing a name). `w:color="auto"` resolves to `nil` (theme decides), same as
    /// `w:fill`'s identical sentinel above.
    private static func cellBorder(_ tcPr: XMLNode?) -> (color: NSColor?, width: CGFloat?) {
        guard let borders = tcPr?.child("w:tcBorders") else { return (nil, nil) }
        for edge in ["w:top", "w:left", "w:bottom", "w:right"] {
            guard let e = borders.child(edge), let val = e.attributes["w:val"], val != "nil", val != "none" else { continue }
            let color = e.attributes["w:color"].flatMap { $0.lowercased() == "auto" ? nil : colorFromHex($0) }
            let width = e.attributes["w:sz"].flatMap(Double.init).map { CGFloat($0 / 8) }
            return (color, width)
        }
        return (nil, nil)
    }

    /// A cell's own declared column width — `w:tcPr/w:tcW`, whose `@w:type` names which of THREE
    /// unit systems `@w:w` is in (ECMA-376 §17.4.90, `ST_TblWidth`): `"dxa"` (twentieths of a
    /// point — the SAME twips `parseTabStops` converts), `"pct"` (fiftieths of a percent of the
    /// table's available width) or `"auto"` (no declared width at all, Word sizes the column
    /// itself). Only `"dxa"` is handled — it is both the common case in practice and the only one
    /// this reader can convert to an ABSOLUTE point value from the cell's own markup alone; `"pct"`
    /// would need the table's own resolved available width (from `w:tblPr/w:tblW` and the page's
    /// margins) to turn a percentage into points, which is real work this sprint's brief scopes
    /// out — skipped here, honestly, rather than guessed at. A `w:tcW` with no `@w:type` at all
    /// defaults to `"dxa"` per the same clause, which is why `nil`/`"dxa"` are treated alike.
    private static func cellWidth(_ tcPr: XMLNode?) -> CGFloat? {
        guard let tcW = tcPr?.child("w:tcW"), let wStr = tcW.attributes["w:w"], let value = Double(wStr) else { return nil }
        guard tcW.attributes["w:type"] == nil || tcW.attributes["w:type"] == "dxa" else { return nil }
        return CGFloat(value / 20)
    }

    /// A cell's content, built from the SAME per-block classification `parseParagraph` gives the
    /// body — a paragraph, a heading, a list item, an image — rather than a second, cell-only walk
    /// that only ever knew how to collect plain text. This is what closes gap-list rows 6 and 7:
    /// before this sprint a cell held nothing but `[Span]`, so an image or a numbered list item
    /// inside a `<w:tc>` had nowhere to go and was silently skipped.
    ///
    /// List numbering inside a cell shares the WHOLE document's `ListNumberingState` (the same
    /// instance `read()` threads through the body) rather than getting its own — a `w:numId`'s
    /// counters belong to the numId, not to whether the paragraph using it happens to sit inside a
    /// table cell, and Word itself continues a list's numbers across an intervening table exactly as
    /// it does across an ordinary paragraph. A numbered item inside a cell therefore continues the
    /// document's numbering, never restarts at 1.
    ///
    /// Three of the same places `collectCellSpans` already knew text could hide — `w:p`, `w:sdt`, a
    /// nested `w:tbl` — but a nested table is still FLATTENED to a single `.paragraph` of spans
    /// (`flattenNestedTable`/`collectCellSpans`, unchanged), never a real nested `.table` block: that
    /// was decided earlier and is enforced again by the renderer, and this sprint's brief is
    /// explicit that it must not change.
    ///
    /// An empty paragraph — Word's own placeholder for a cell the author left blank, or the stray
    /// `<w:p/>` a genuinely empty cell always carries (a `<w:tc>` is never bodiless in real OOXML) —
    /// is filtered out with the SAME `isEmptyTextBlock` check `textBoxBlocks` already uses: a truly
    /// empty cell must produce no block at all, never a phantom `.paragraph(spans: [])` standing in
    /// for "nothing here".
    private static func collectCellBlocks(
        _ tc: XMLNode, styleInfo: StyleInfo, numbering: NumberingInfo, relationships: Relationships,
        notes: NoteNumbering, listState: ListNumberingState
    ) -> [OfficeBlock] {
        var blocks: [OfficeBlock] = []
        for child in tc.children {
            switch child.name {
            case "w:p":
                blocks.append(contentsOf: parseParagraph(
                    child, styleInfo: styleInfo, numbering: numbering, relationships: relationships, notes: notes,
                    listState: listState))
            case "w:tbl":
                let spans = flattenNestedTable(child, styleInfo: styleInfo, relationships: relationships, notes: notes)
                if !spans.isEmpty { blocks.append(.paragraph(spans: spans)) }
            case "w:sdt":
                if let content = child.child("w:sdtContent") {
                    blocks.append(contentsOf: collectCellBlocks(
                        content, styleInfo: styleInfo, numbering: numbering, relationships: relationships,
                        notes: notes, listState: listState))
                }
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
    private static func collectCellSpans(_ tc: XMLNode, styleInfo: StyleInfo, relationships: Relationships, notes: NoteNumbering) -> [Span] {
        var spans: [Span] = []
        for child in tc.children {
            switch child.name {
            case "w:p":
                spans.append(contentsOf: collectSpans(in: child, styleInfo: styleInfo, relationships: relationships, notes: notes))
            case "w:tbl":
                spans.append(contentsOf: flattenNestedTable(child, styleInfo: styleInfo, relationships: relationships, notes: notes))
            case "w:sdt":
                if let content = child.child("w:sdtContent") {
                    spans.append(contentsOf: collectCellSpans(content, styleInfo: styleInfo, relationships: relationships, notes: notes))
                }
            default:
                continue
            }
        }
        return spans
    }

    /// Flattens a nested table's cells into one run of spans — a tab between cells, a newline
    /// after each non-empty row — so a reader glancing at the flattened text can still tell where
    /// one cell ended and the next began, even though the grid itself is gone. Recurses through
    /// `collectCellSpans`, so a table nested inside a nested table (and a content control inside
    /// THAT) also survives — no depth cap is enforced; real documents don't go more than one or
    /// two levels, per the research survey.
    private static func flattenNestedTable(_ table: XMLNode, styleInfo: StyleInfo, relationships: Relationships, notes: NoteNumbering) -> [Span] {
        var spans: [Span] = []
        for row in table.children where row.name == "w:tr" {
            var rowHasContent = false
            for cell in row.children where cell.name == "w:tc" {
                let cellSpans = collectCellSpans(cell, styleInfo: styleInfo, relationships: relationships, notes: notes)
                guard !cellSpans.isEmpty else { continue }
                if rowHasContent { spans.append(Span(text: "\t")) }
                spans.append(contentsOf: cellSpans)
                rowHasContent = true
            }
            if rowHasContent { spans.append(Span(text: "\n")) }
        }
        return spans
    }

    /// Walks a paragraph (or a table cell's paragraph) collecting `w:r` runs into `Span`s,
    /// merging consecutive runs that carry identical formatting into one — Word fragments a
    /// single sentence into several runs constantly (a spell-check pass, a single character
    /// pasted with different provenance), and without merging, that fragmentation would leak
    /// into the rendered text as spurious style boundaries.
    ///
    /// Recursion is deliberately permissive: any wrapper this switch doesn't specifically name
    /// (`w:ins`, `w:smartTag`, `w:customXml`, …) is descended into rather than skipped, so a
    /// run's visible text is never lost just because Word wrapped it in something unanticipated.
    /// Two wrappers get their OWN case rather than falling through to that generic descent:
    /// `w:hyperlink` carries the link target as an ATTRIBUTE (`r:id`/`w:anchor`), which the generic
    /// walk has nowhere to read, so every run underneath it is threaded through with that target;
    /// `w:sdt` (an inline content control) is unwrapped into its `w:sdtContent` only, so its
    /// `w:sdtPr` (placeholder-text hints, lock settings — never renderable content) is never
    /// mistaken for one. Only elements known to carry NO renderable body text of their own are
    /// pruned: paragraph/run properties (formatting only), deleted-content wrappers, empty
    /// markers, and section properties.
    private static func collectSpans(in node: XMLNode, styleInfo: StyleInfo, relationships: Relationships, notes: NoteNumbering) -> [Span] {
        // The paragraph's own style id, read off THIS node's `w:pPr` directly — every caller passes
        // the paragraph (`w:p`) itself as `node` (`parseParagraph`, `collectCellSpans`'s `w:p` case),
        // never a sub-element, so this is the same `w:pPr/w:pStyle` `parseParagraph` itself reads for
        // `headingLevel`/`alignment` — read again here rather than threaded as a separate parameter,
        // since every call site already has `node` in hand and nothing else about that lookup varies.
        let pStyleId = node.child("w:pPr")?.child("w:pStyle")?.attributes["w:val"]
        var spans: [Span] = []
        // Names collected from `w:bookmarkStart` since the last span was emitted, waiting for the
        // next real content to attach to (a bookmark almost always wraps its target rather than
        // standing alone) — see the `w:bookmarkStart` case in `walk` and the doc comment on
        // `Span.bookmarks`. `_GoBack` is filtered here, not recorded and never resolvable: Word
        // inserts it automatically (last-edit-location bookkeeping) into nearly every real
        // document, no hyperlink ever targets it, and recording it would force every span right
        // after one — text a user never asked to navigate to — out of the ordinary run-merging path.
        var pendingBookmarks: [String] = []
        func appendMerging(_ span: Span) {
            var span = span
            if !pendingBookmarks.isEmpty {
                span.bookmarks += pendingBookmarks
                pendingBookmarks = []
            }
            guard span.bookmarks.isEmpty else { spans.append(span); return }
            // A bookmarked span is also never EXTENDED by whatever comes right after it — merging
            // trailing text into it would grow the bookmark's rendered span past its real target,
            // the same boundary-smearing `Span.bookmarks`' doc comment warns against, just from the
            // other direction.
            if let last = spans.last, last.bookmarks.isEmpty, last.bold == span.bold, last.italic == span.italic,
               last.underline == span.underline, last.code == span.code, last.link == span.link,
               last.strikethrough == span.strikethrough, last.superscript == span.superscript,
               last.subscripted == span.subscripted, last.rtl == span.rtl {
                spans[spans.count - 1].text += span.text
            } else {
                spans.append(span)
            }
        }
        func walk(_ node: XMLNode, link: String?) {
            for child in node.children {
                switch child.name {
                // Tracked MOVES are a matched pair: `w:moveFrom` wraps the run(s) at the ORIGINAL
                // location and `w:moveTo` wraps the SAME run(s), verbatim, at the NEW location —
                // Word's move-tracking round-trip literally duplicates the moved text into two
                // places in `document.xml` and relies on the reader to keep only one.
                // `w:moveFrom` is excluded here, exactly like `w:del` right beside it: it is
                // content that is no longer at this location. `w:moveTo` is deliberately NOT
                // listed — it falls through to the permissive `default: walk` below and is kept,
                // exactly like `w:ins`. Before this fix NEITHER was excluded, so both locations
                // rendered — a 100%-reproducible text duplication on every tracked move, not a
                // degraded edge case. The empty boundary markers `w:moveFromRangeStart`/
                // `w:moveFromRangeEnd` (used when a move's extent doesn't align to paragraph
                // boundaries) carry no children of their own per spec, so excluding them changes
                // nothing today — listed anyway so this switch stays the complete, authoritative
                // record of "moved away" markers rather than relying on them being harmlessly
                // empty.
                case "w:pPr", "w:rPr", "w:del", "w:moveFrom", "w:moveFromRangeStart", "w:moveFromRangeEnd",
                     "w:bookmarkEnd", "w:proofErr",
                     "w:sectPr", "w:commentRangeStart", "w:commentRangeEnd", "w:commentReference":
                    continue
                // A bookmark's name is the target an in-document link (`w:anchor`) jumps to — see
                // `Span.bookmarks`/`hyperlinkTarget` below. `_GoBack` is Word's own auto-inserted
                // bookmark (nothing in a real document ever links to it) and is deliberately never
                // recorded — see the doc comment on `pendingBookmarks` above.
                case "w:bookmarkStart":
                    if let name = child.attributes["w:name"], name != "_GoBack" {
                        pendingBookmarks.append(name)
                    }
                    continue
                // A display equation — `collectFormulaBlocks` (called separately, once per
                // paragraph, from `parseParagraph`) already turns this into its OWN `.formula`
                // block; walking it here too would flatten its `m:t` runs a SECOND time into this
                // paragraph's ordinary text, duplicating the equation's symbols right next to its
                // proper rendering.
                case "m:oMathPara":
                    continue
                // A bare, INLINE equation (mixed into a sentence, or standing alone without the
                // `m:oMathPara` wrapper) — this sprint gives it no web-block placeholder (see
                // `WebBlock`'s doc: block-only, no inline mechanism), so it degrades to its own
                // text, IN PLACE, exactly where it sits among the surrounding runs — the sentence
                // stays intact rather than being broken into separate blocks for one symbol.
                case "m:oMath":
                    let text = OmmlTranslator.flattenText(child)
                    if !text.isEmpty { appendMerging(Span(text: text, link: link)) }
                case "w:hyperlink":
                    // A hyperlink whose target can't be resolved (no `r:id`/`w:anchor`, or a
                    // relationship id absent from `document.xml.rels`) still keeps its text — only
                    // the link itself is lost, never the content, so `target` falling through to
                    // the OUTER `link` (usually nil) rather than being forced is deliberate.
                    walk(child, link: hyperlinkTarget(child, relationships: relationships) ?? link)
                case "w:sdt":
                    if let content = child.child("w:sdtContent") { walk(content, link: link) }
                case "w:r":
                    // A footnote/endnote reference is a MARKER element nested inside the run
                    // (`<w:r><w:rPr>…</w:rPr><w:footnoteReference w:id="1"/></w:r>`), not text —
                    // `buildSpan` below has no `w:t` to read from such a run and would otherwise
                    // silently produce nothing, dropping the citation entirely. Emitted as its OWN
                    // superscript span carrying the pre-computed marker number (`notes`, resolved
                    // once for the whole document in `numberNoteReferences` before this walk ever
                    // ran) — the SAME number the corresponding note body is prefixed with in
                    // `collectNoteBlocks`, so a reader can match one to the other. An id that
                    // resolves to no number (present in `w:footnoteReference` but this document's
                    // body was never walked for numbering — can't happen from `read()`, but this
                    // guards a caller that reuses `collectSpans` some other way) contributes nothing
                    // rather than a bare, meaningless digit.
                    for refChild in child.children {
                        switch refChild.name {
                        case "w:footnoteReference":
                            if let id = refChild.attributes["w:id"], let number = notes.footnote[id] {
                                appendMerging(Span(text: "\(number)", link: link, superscript: true))
                            }
                        case "w:endnoteReference":
                            if let id = refChild.attributes["w:id"], let number = notes.endnote[id] {
                                appendMerging(Span(text: "\(number)", link: link, superscript: true))
                            }
                        default:
                            continue
                        }
                    }
                    if var span = buildSpan(from: child, styleInfo: styleInfo, pStyleId: pStyleId) {
                        span.link = link
                        appendMerging(span)
                    }
                default:
                    walk(child, link: link)
                }
            }
        }
        walk(node, link: nil)
        return spans
    }

    /// `r:id` resolves through the SAME relationship plumbing an embedded image's `r:embed` uses
    /// (`word/_rels/document.xml.rels`) — Word's hyperlink relationships are conventionally
    /// `TargetMode="External"`, so `Relationship.target` is already the raw URL, unmodified. An
    /// internal same-document link (e.g. a cross-reference to a heading) carries no `r:id` at all,
    /// only `w:anchor` naming a bookmark — turned into a `#`-prefixed fragment, the same convention
    /// markdown links already use for in-document anchors.
    ///
    /// PRECEDENCE, `r:id` present alongside `w:anchor`: `r:id` wins, `w:anchor` is ignored — per
    /// ECMA-376 Part 1 §17.16.22 (`CT_Hyperlink`), `id` is "the relationship id of the target of
    /// this hyperlink" and, when present, `anchor` names a location WITHIN that relationship's
    /// target (a bookmark inside the linked document), not a location in the current one. This
    /// reader has no way to jump inside an external target, so honouring `w:anchor` there would be
    /// wrong twice over — it would misread it as an in-document bookmark AND ignore the external
    /// target entirely. Dropping it and following `r:id` alone is the correct reading, not just the
    /// simpler one.
    private static func hyperlinkTarget(_ hyperlink: XMLNode, relationships: Relationships) -> String? {
        if let rId = hyperlink.attributes["r:id"] {
            return relationships.byId[rId]?.target
        }
        if let anchor = hyperlink.attributes["w:anchor"] {
            return "#" + anchor
        }
        return nil
    }

    /// `w:t` text is concatenated verbatim, including any leading/trailing spaces — `xml:space`
    /// is a hint to XML WRITERS about whether to preserve whitespace-only nodes; a parser already
    /// reports the literal characters present, so there is nothing extra to honour here (and
    /// nothing here trims). `w:br`/`w:tab` are not text but stand for one, so they are turned
    /// into `\n`/`\t` in place, and so do `w:noBreakHyphen`/`w:softHyphen`/`w:ptab` (U+2011, U+00AD,
    /// `\t` — the author's punctuation/whitespace, not formatting; dropping them silently deleted a
    /// real character). `w:sym` is a special-character reference (`w:font`+`w:char`, a
    /// code point in that FONT's own private encoding, e.g. Wingdings) with no `w:t` fallback at
    /// all — this reader has no way to map an arbitrary symbol-font code point to a real Unicode
    /// glyph, but silently emitting nothing would make the author's character disappear entirely
    /// (the one unforgivable failure this sprint exists to close), so it becomes a visible
    /// placeholder (▯) instead — wrong glyph, but honestly marked as "something was here", never
    /// mistaken for empty content. A run producing no text at all (formatting-only, or an empty
    /// bookmark anchor Word occasionally wraps in its own run) yields no span — the caller must
    /// never see a phantom empty one.
    /// A tiny, deliberately incomplete `w:char` → Unicode mapping — the ▯ fallback above stays the
    /// default for everything not listed here, and stays honest: a wrong-looking mark beats a
    /// silently vanished one, but a real glyph beats either when it can be cited with confidence.
    /// This project's licence rule forbids copying a lookup table out of another reader
    /// (LibreOffice/Calligra/pandoc are read-for-understanding only), so every entry here must
    /// trace to a source this project can actually name: Microsoft's own Wingdings-to-Unicode
    /// correspondence, also published by the Unicode Consortium as a vendor "best fit" mapping
    /// (`unicode.org/Public/MAPPINGS/VENDORS/MICSFT/SYMBOL/wingding.txt`), assigns the Private-Use-
    /// Area code point U+F0FC to the Wingdings glyph Word renders as a check mark and U+F0FB to the
    /// one it renders as a ballot X — Word's own "checked"/"crossed-out" marks for a legacy
    /// Wingdings-font checkbox, one of the categories the sprint brief asked for.
    ///
    /// Every OTHER category the brief named — bullet variants, arrows, telephone, envelope — is
    /// DELIBERATELY NOT mapped: without live access to the published Unicode/Microsoft charts to
    /// confirm their exact `w:char` code points, adding them would mean guessing, which the brief
    /// explicitly forbids. They keep the honest ▯ fallback; a future pass with the actual chart in
    /// hand can extend this table, never by copying another project's source.
    private static func mappedSymbolCharacter(font: String?, char: String?) -> String? {
        guard let font, font.caseInsensitiveCompare("Wingdings") == .orderedSame, let char else { return nil }
        switch char.uppercased() {
        case "F0FC": return "\u{2713}"   // check mark
        case "F0FB": return "\u{2717}"   // ballot X
        default: return nil
        }
    }

    private static func buildSpan(from run: XMLNode, styleInfo: StyleInfo, pStyleId: String?) -> Span? {
        var text = ""
        for child in run.children {
            switch child.name {
            case "w:t": text += child.text
            case "w:br": text += "\n"
            case "w:tab": text += "\t"
            case "w:sym": text += mappedSymbolCharacter(font: child.attributes["w:font"], char: child.attributes["w:char"]) ?? "▯"
            // A non-breaking hyphen/soft hyphen IS text (the author's punctuation choice, not
            // formatting), and a positioned tab (`w:ptab`) is whitespace like `w:tab` even though
            // this reader doesn't honour its absolute position — dropping any of the three silently
            // deleted the author's character (see the function doc above).
            case "w:noBreakHyphen": text += "\u{2011}"
            case "w:softHyphen": text += "\u{00AD}"
            case "w:ptab": text += "\t"
            default: continue
            }
        }
        guard !text.isEmpty else { return nil }
        let rPr = run.child("w:rPr")
        // `w:vanish` is Word's own "don't show this in Normal view" toggle on a run — the same
        // principle sprint S4 applied to ODT's hidden-text signals, kept consistent here: hide
        // only on the file's explicit say-so. It's also how Word marks index-entry/TOC-field
        // scaffolding, so honouring it removes clutter the author never intended to be read as
        // body text. Deliberately handles ONLY plain `w:vanish` — `w:specVanish` is a
        // DIFFERENT, style-level toggle ("hidden unless the paragraph mark itself says
        // otherwise") whose exact interaction with paragraph marks this reader cannot verify
        // with confidence from a run alone, so it is left unhandled rather than guessed at.
        if isOn(rPr, "w:vanish") { return nil }
        let vertAlign = rPr?.child("w:vertAlign")?.attributes["w:val"]
        // Direct run properties WIN over the paragraph's style chain — read straight off THIS run's
        // own `w:rPr` first, and only consult `resolvedColor`/`resolvedHighlight`/`resolvedFontSize`/
        // `resolvedFontName` (the `basedOn`-chain walk, S13's reused mechanism) when this run didn't
        // say. `styleInfo.themeColors` is threaded through `resolvedColorElement` so a THEME colour
        // on a direct run resolves to the identical literal a style-level one would.
        let directColor = resolvedColorElement(rPr?.child("w:color"), themeColors: styleInfo.themeColors)
        let color = directColor ?? resolvedColor(pStyleId: pStyleId, styleInfo: styleInfo)
        let directHighlight = rPr?.child("w:highlight")?.attributes["w:val"].flatMap(highlightColor(named:))
        let highlight = directHighlight ?? resolvedHighlight(pStyleId: pStyleId, styleInfo: styleInfo)
        let directFontSize: CGFloat? = rPr?.child("w:sz")?.attributes["w:val"].flatMap(Double.init).map { CGFloat($0 / 2) }
        let fontSize = directFontSize ?? resolvedFontSize(pStyleId: pStyleId, styleInfo: styleInfo)
        let directFontName = rPr?.child("w:rFonts").flatMap { $0.attributes["w:ascii"] ?? $0.attributes["w:hAnsi"] }
        let fontName = directFontName ?? resolvedFontName(pStyleId: pStyleId, styleInfo: styleInfo)
        return Span(
            text: text, bold: isOn(rPr, "w:b"), italic: isOn(rPr, "w:i"), underline: isOn(rPr, "w:u"),
            strikethrough: isOn(rPr, "w:strike"), superscript: vertAlign == "superscript",
            subscripted: vertAlign == "subscript", rtl: isOn(rPr, "w:rtl"),
            textColor: color, highlightColor: highlight, fontSize: fontSize, fontName: fontName)
    }

    /// A run-property toggle (`w:b`/`w:i`/`w:u`) is ON by its mere presence — UNLESS it carries
    /// `w:val="0"` or `w:val="false"`, which is Word's way of explicitly switching an inherited
    /// toggle back off. Treating `<w:b w:val="0"/>` as bold is a real, documented bug class.
    private static func isOn(_ rPr: XMLNode?, _ tag: String) -> Bool {
        guard let element = rPr?.child(tag) else { return false }
        guard let val = element.attributes["w:val"] else { return true }
        return val != "0" && val != "false"
    }

    // MARK: Generic XML tree

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

/// Translates one `m:oMath` node (OOXML's Office Math Markup Language) into the LaTeX the app's
/// existing formula engine already renders (`WebBlock.Engine.math`, KaTeX). Lives in THIS file
/// (not its own) because it walks `XMLNode`, which is deliberately `private` to this file to avoid
/// colliding with `OdtReader`'s own type of the same name — `OmmlTranslator` is `DocxReader`'s
/// caller-only helper, so file-private access is exactly the right shape, not a workaround.
///
/// Coverage is deliberately partial (the sprint brief is explicit: "do not attempt full OMML
/// coverage"). What IS covered: `m:r`/`m:t` (runs/text), `m:f` (fraction), `m:sSup`/`m:sSub`/
/// `m:sSubSup` (super/subscript), `m:rad` (radical), `m:d` (delimiters), `m:nary` (sum/product/
/// integral), `m:m`/`m:mr` (matrix), `m:func` (function application), `m:limLow`/`m:limUpp`
/// (limits), `m:bar` (over/underline), `m:acc` (accents), `m:groupChr` (over/underbrace),
/// `m:eqArr` (stacked equations).
///
/// The one rule every construct obeys: an element this translator does NOT specifically know how
/// to shape falls back to `flattenText` — its own `m:t` runs, concatenated — rather than producing
/// nothing. That fallback is the `default:` case of `translate(_:)`, not a case anyone has to
/// remember to add for a new/unhandled element, so it also covers constructs never named above
/// (`m:box`, `m:borderBox`, `m:phant`, …) automatically. Losing the author's SHAPE (no fraction
/// bar, no radical sign) is accepted; losing their SYMBOLS is not — see CLAUDE.md's standing rule
/// that content loss is this project's one unforgivable failure, layout loss is not.
private enum OmmlTranslator {
    /// The LaTeX for one `m:oMath` node — its direct children, translated and concatenated. Empty
    /// only when the equation carries no content at all (an empty `m:oMath`, or one whose only
    /// children are property elements) — the caller (`DocxReader.formulaBlock`) is responsible for
    /// turning THAT into something visible rather than emitting a formula block with nothing in it.
    static func latex(for oMath: XMLNode) -> String {
        translateChildren(oMath.children)
    }

    /// Every `m:t` found anywhere below `node`, depth-first, concatenated verbatim. The universal
    /// fallback (see the type doc) and also what `DocxReader.collectSpans` uses for a genuinely
    /// INLINE `m:oMath` (mixed into a sentence) that this sprint deliberately never turns into a
    /// web block at all — no inline placeholder mechanism exists yet (`WebBlock` is block-only).
    static func flattenText(_ node: XMLNode) -> String {
        var out = ""
        func walk(_ n: XMLNode) {
            if n.name == "m:t" { out += n.text; return }
            for c in n.children { walk(c) }
        }
        walk(node)
        return out
    }

    // MARK: - Dispatch

    private static func translateChildren(_ nodes: [XMLNode]) -> String {
        nodes.compactMap { translate($0) }.joined()
    }

    /// `nil` for property/formatting elements (`m:*Pr`) — they carry no equation content of their
    /// own and must contribute nothing, not even their (nonexistent) text; every other unrecognized
    /// element falls to `flattenText`, never to `nil`, so a real author symbol is never silently
    /// dropped just because this translator doesn't know its shape.
    private static func translate(_ node: XMLNode) -> String? {
        switch node.name {
        case let n where n.hasSuffix("Pr"): return nil
        case "m:r": return run(node)
        case "m:f": return fraction(node)
        case "m:sSup": return superscript(node)
        case "m:sSub": return subscriptTranslate(node)
        case "m:sSubSup": return subSup(node)
        case "m:rad": return radical(node)
        case "m:d": return delimiter(node)
        case "m:nary": return nary(node)
        case "m:m": return matrix(node)
        case "m:func": return funcApply(node)
        case "m:limLow": return limLow(node)
        case "m:limUpp": return limUpp(node)
        case "m:bar": return bar(node)
        case "m:acc": return accent(node)
        case "m:groupChr": return groupChr(node)
        case "m:eqArr": return eqArr(node)
        default:
            return flattenText(node)
        }
    }

    /// `m:r`'s only content is `m:t` (its `m:rPr`/`w:rPr` are formatting, skipped by the `Pr` rule
    /// above) — `flattenText` finds it regardless of exactly how deep it sits.
    private static func run(_ node: XMLNode) -> String { flattenText(node) }

    // MARK: - Structural constructs

    private static func fraction(_ node: XMLNode) -> String {
        let num = node.child("m:num").map { translateChildren($0.children) } ?? ""
        let den = node.child("m:den").map { translateChildren($0.children) } ?? ""
        return "\\frac{\(num)}{\(den)}"
    }

    private static func superscript(_ node: XMLNode) -> String {
        let base = element(node, "m:e")
        let sup = element(node, "m:sup")
        return "{\(base)}^{\(sup)}"
    }

    private static func subscriptTranslate(_ node: XMLNode) -> String {
        let base = element(node, "m:e")
        let sub = element(node, "m:sub")
        return "{\(base)}_{\(sub)}"
    }

    private static func subSup(_ node: XMLNode) -> String {
        let base = element(node, "m:e")
        let sub = element(node, "m:sub")
        let sup = element(node, "m:sup")
        return "{\(base)}_{\(sub)}^{\(sup)}"
    }

    /// A hidden degree (`m:radPr`'s `m:degHide` = "1") is Word's own square-root shorthand — the
    /// SOURCE says there is no degree to show, not that this translator lost one.
    private static func radical(_ node: XMLNode) -> String {
        let radicand = element(node, "m:e")
        let degHidden = propVal(node.child("m:radPr"), "m:degHide") == "1"
        let deg = node.child("m:deg").map { translateChildren($0.children) } ?? ""
        if degHidden || deg.trimmingCharacters(in: .whitespaces).isEmpty {
            return "\\sqrt{\(radicand)}"
        }
        return "\\sqrt[\(deg)]{\(radicand)}"
    }

    /// One or more `m:e` arguments wrapped in the delimiters the source declared (`m:begChr`/
    /// `m:endChr`, under `m:dPr`) — defaulting to `(`/`)`, Word's own default when a document omits
    /// them entirely (an EMPTY `m:val=""` is a real, different, deliberate choice — "no visible
    /// delimiter" — and is honoured as empty, not silently overridden back to parentheses).
    private static func delimiter(_ node: XMLNode) -> String {
        let dPr = node.child("m:dPr")
        let beg = propVal(dPr, "m:begChr") ?? "("
        let end = propVal(dPr, "m:endChr") ?? ")"
        let args = node.children.filter { $0.name == "m:e" }.map { translateChildren($0.children) }
        let inner = args.joined(separator: ", ")
        let left = beg.isEmpty ? "." : escapeDelimiter(beg)
        let right = end.isEmpty ? "." : escapeDelimiter(end)
        return "\\left\(left) \(inner) \\right\(right)"
    }

    private static func escapeDelimiter(_ c: String) -> String {
        switch c {
        case "{": return "\\{"
        case "}": return "\\}"
        case "|": return "|"
        default: return c
        }
    }

    /// The operator glyph (`m:naryPr`'s `m:chr`) maps to a handful of common LaTeX big-operator
    /// commands; anything else keeps the source glyph literally rather than guessing a command name
    /// for it — the SAME "don't invent, degrade honestly" posture the rest of this translator uses.
    private static func nary(_ node: XMLNode) -> String {
        let naryPr = node.child("m:naryPr")
        let chr = propVal(naryPr, "m:chr") ?? "\u{2211}"
        let cmd = naryCommand(chr)
        let subHidden = propVal(naryPr, "m:subHide") == "1"
        let supHidden = propVal(naryPr, "m:supHide") == "1"
        let sub = node.child("m:sub").map { translateChildren($0.children) } ?? ""
        let sup = node.child("m:sup").map { translateChildren($0.children) } ?? ""
        let operand = element(node, "m:e")
        var out = cmd
        if !subHidden, !sub.isEmpty { out += "_{\(sub)}" }
        if !supHidden, !sup.isEmpty { out += "^{\(sup)}" }
        return "\(out) \(operand)"
    }

    private static func naryCommand(_ chr: String) -> String {
        switch chr {
        case "\u{2211}": return "\\sum"          // ∑
        case "\u{220F}": return "\\prod"          // ∏
        case "\u{222B}": return "\\int"           // ∫
        case "\u{222C}": return "\\iint"          // ∬
        case "\u{222D}": return "\\iiint"         // ∭
        case "\u{222E}": return "\\oint"          // ∮
        case "\u{22C3}": return "\\bigcup"        // ⋃
        case "\u{22C2}": return "\\bigcap"        // ⋂
        default: return chr
        }
    }

    /// Every `m:mr` row's `m:e` cells, `&`-separated, rows `\\`-separated.
    private static func matrix(_ node: XMLNode) -> String {
        let rows = node.children.filter { $0.name == "m:mr" }.map { row -> String in
            row.children.filter { $0.name == "m:e" }
                .map { translateChildren($0.children) }
                .joined(separator: " & ")
        }
        return "\\begin{matrix} \(rows.joined(separator: " \\\\ ")) \\end{matrix}"
    }

    /// `m:fName` is itself OMML content (usually a plain run like "sin"), not a bare string
    /// attribute — translated the same way any other sub-expression is.
    private static func funcApply(_ node: XMLNode) -> String {
        let name = node.child("m:fName").map { translateChildren($0.children) } ?? ""
        let arg = element(node, "m:e")
        return "\(name)\\left(\(arg)\\right)"
    }

    private static func limLow(_ node: XMLNode) -> String {
        let base = element(node, "m:e")
        let lim = node.child("m:lim").map { translateChildren($0.children) } ?? ""
        return lim.isEmpty ? base : "\(base)_{\(lim)}"
    }

    private static func limUpp(_ node: XMLNode) -> String {
        let base = element(node, "m:e")
        let lim = node.child("m:lim").map { translateChildren($0.children) } ?? ""
        return lim.isEmpty ? base : "\(base)^{\(lim)}"
    }

    /// `m:barPr`'s `m:pos` (`"bot"` = underline, anything else, including absent, = overline —
    /// Word's own default for a bar with no `m:pos` at all).
    private static func bar(_ node: XMLNode) -> String {
        let pos = propVal(node.child("m:barPr"), "m:pos")
        let e = element(node, "m:e")
        return pos == "bot" ? "\\underline{\(e)}" : "\\overline{\(e)}"
    }

    /// The accent glyph (`m:accPr`'s `m:chr`) maps to a handful of common LaTeX accent commands;
    /// an unmapped glyph is kept literally alongside the base rather than dropped, same posture as
    /// `nary`'s unmapped operator.
    private static func accent(_ node: XMLNode) -> String {
        let chr = propVal(node.child("m:accPr"), "m:chr") ?? ""
        let e = element(node, "m:e")
        switch chr {
        case "\u{0302}": return "\\hat{\(e)}"           // combining circumflex
        case "\u{20D7}": return "\\vec{\(e)}"           // combining right arrow above
        case "\u{0307}": return "\\dot{\(e)}"           // combining dot above
        case "\u{0303}": return "\\tilde{\(e)}"         // combining tilde
        case "\u{0305}", "\u{0304}": return "\\bar{\(e)}" // combining overline / macron
        case "": return e
        default: return "\(e)\(chr)"
        }
    }

    /// The brace glyph + position (`m:groupChrPr`'s `m:chr`/`m:pos`) maps overbrace/underbrace;
    /// anything else keeps the source glyph, appended, rather than being silently dropped.
    private static func groupChr(_ node: XMLNode) -> String {
        let groupPr = node.child("m:groupChrPr")
        let chr = propVal(groupPr, "m:chr") ?? "\u{23DE}"
        let pos = propVal(groupPr, "m:pos") ?? "top"
        let e = element(node, "m:e")
        switch (chr, pos) {
        case ("\u{23DE}", "top"), ("\u{FE37}", "top"): return "\\overbrace{\(e)}"
        case ("\u{23DF}", "bot"), ("\u{FE38}", "bot"): return "\\underbrace{\(e)}"
        default: return pos == "bot" ? "\\underbrace{\(e)}" : "\\overbrace{\(e)}"
        }
    }

    /// Each `m:e` on its own line — LaTeX's `aligned` environment, `\\`-separated.
    private static func eqArr(_ node: XMLNode) -> String {
        let rows = node.children.filter { $0.name == "m:e" }.map { translateChildren($0.children) }
        return "\\begin{aligned} \(rows.joined(separator: " \\\\ ")) \\end{aligned}"
    }

    // MARK: - Small helpers

    /// The translated content of `node`'s FIRST child named `tag`, or empty text if absent —
    /// absence is common (`m:sub`/`m:sup`/`m:deg` are all individually optional per the OMML
    /// schema) and must degrade to an empty group, never a crash or a dropped construct.
    private static func element(_ node: XMLNode, _ tag: String) -> String {
        node.child(tag).map { translateChildren($0.children) } ?? ""
    }

    /// `pr?.child(tag)?.attributes["m:val"]` — the one shape every OMML property value takes
    /// (`<m:chr m:val="…"/>`, `<m:begChr m:val="…"/>`, …).
    private static func propVal(_ pr: XMLNode?, _ tag: String) -> String? {
        pr?.child(tag)?.attributes["m:val"]
    }
}

/// A minimal DOM: element name (the qualified name, e.g. `"w:p"` — namespace processing is left
/// off, so `XMLParser` hands that back directly instead of splitting prefix from URI), its
/// attributes, its element children in document order, and any character data that landed
/// directly inside it (only leaf elements like `w:t` ever have any).
///
/// A tree — not a flat event stream — because `DocxReader`'s job is inherently structural
/// (a table's rows nest cells which nest paragraphs which nest runs); re-deriving that nesting
/// from `XMLParser`'s start/end callbacks by hand for every element kind would be the same tree,
/// built once per caller instead of once here.
private final class XMLNode {
    let name: String
    let attributes: [String: String]
    var children: [XMLNode] = []
    var text: String = ""

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    /// First direct child with this name, or nil. Every lookup `DocxReader` needs (`w:pPr` on a
    /// paragraph, `w:outlineLvl` on `w:pPr`, …) is for a single expected child, never a list.
    func child(_ name: String) -> XMLNode? {
        children.first { $0.name == name }
    }

    /// First match anywhere below this node (depth-first, document order), for lookups where the
    /// exact nesting varies by producer — `wp:extent`/`a:blip` sit at a different depth inside an
    /// inline vs. a floating (`wp:anchor`) drawing, and pinning that depth would silently miss one
    /// of the two shapes.
    func firstDescendant(_ name: String) -> XMLNode? {
        for child in children {
            if child.name == name { return child }
            if let found = child.firstDescendant(name) { return found }
        }
        return nil
    }

    /// Same idea, keyed by attribute presence rather than element name — used to find the VML
    /// shape carrying a `style="width:…;height:…"` attribute without knowing whether it's a
    /// `v:shape`, `v:rect`, `v:roundrect`, ….
    func firstDescendant(withAttribute attribute: String) -> XMLNode? {
        for child in children {
            if child.attributes[attribute] != nil { return child }
            if let found = child.firstDescendant(withAttribute: attribute) { return found }
        }
        return nil
    }

    /// EVERY match anywhere below this node, in document order — unlike `firstDescendant`, used
    /// where stopping at the first would silently drop real content (a `w:drawing` grouping
    /// several pictures has one `a:blip` per picture, all of them real).
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

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        stack.last?.text += string
    }

    func parser(
        _ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?
    ) {
        stack.removeLast()
    }
}

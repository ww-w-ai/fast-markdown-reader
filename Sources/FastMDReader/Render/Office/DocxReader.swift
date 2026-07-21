import Foundation
import CoreGraphics

/// `.docx` bytes → `[OfficeBlock]`. Word's own container is three XML parts inside the ZIP
/// `ZipArchive` already knows how to open: `word/document.xml` (the body, required), and two
/// optional ones this reader consults to resolve what the body only references by id —
/// `word/styles.xml` (a paragraph style's `w:outlineLvl`, which is what actually makes it a
/// heading) and `word/numbering.xml` (whether a list level is a bullet or a number). Neither
/// being absent is an error — Word omits `numbering.xml` from documents with no lists at all —
/// so both fall back to an empty table and the body still parses.
enum DocxReader {
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
        let styleOutlineLevels = parseStyles(from: archive)
        let numbering = parseNumbering(from: archive)
        let relationships = parseRelationships(from: archive)
        guard let body = documentRoot.child("w:body") else { return [] }
        return parseBody(body, styleOutlineLevels: styleOutlineLevels, numbering: numbering, relationships: relationships)
    }

    // MARK: styles.xml — styleId → outlineLvl

    /// A style's NAME is not a safe signal — a localized Word install renames "Heading1" to
    /// something like 제목 1, but `w:outlineLvl` is written in every language. Only paragraph
    /// styles that declare one are recorded; everything else (including styles with no
    /// `w:outlineLvl` at all) is absent from the map, which `headingLevel` reads as "not a
    /// heading style".
    private static func parseStyles(from archive: ZipArchive) -> [String: Int] {
        guard archive.contains("word/styles.xml"),
              let data = try? archive.data(for: "word/styles.xml"),
              let root = try? buildTree(data)
        else { return [:] }
        var map: [String: Int] = [:]
        for style in root.children where style.name == "w:style" {
            guard let id = style.attributes["w:styleId"],
                  let val = style.child("w:pPr")?.child("w:outlineLvl")?.attributes["w:val"],
                  let level = Int(val)
            else { continue }
            map[id] = level
        }
        return map
    }

    /// `outlineLvl` 0–8 are real heading levels; 9 is what Word gives its own `TOCHeading` style
    /// and must NOT be treated as a heading (it would otherwise put a table-of-contents label at
    /// sidebar depth 10). The emitted level is clamped to 1–6 — the vocabulary `OfficeBlock`
    /// offers — so an `outlineLvl` of 6, 7 or 8 all render as level 6 rather than being refused.
    private static func headingLevel(pStyleId: String?, styleOutlineLevels: [String: Int]) -> Int? {
        guard let id = pStyleId, let level = styleOutlineLevels[id], level <= 8 else { return nil }
        return min(level + 1, 6)
    }

    // MARK: numbering.xml — numId → abstractNumId → level → numFmt

    private struct NumberingInfo {
        var abstractNumIdByNumId: [String: String] = [:]
        var levelFormatsByAbstractNumId: [String: [Int: String]] = [:]
    }

    /// Read only as far as telling a bullet from a number apart — the mapping a real list needs
    /// to be classified, not to be rendered (`OfficeTextBuilder` derives the actual "1. 2. 3."
    /// numbers from `level` + `ordered` alone; this reader never counts list items).
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
                var levels: [Int: String] = [:]
                for lvl in child.children where lvl.name == "w:lvl" {
                    guard let ilvlString = lvl.attributes["w:ilvl"], let ilvl = Int(ilvlString),
                          let fmt = lvl.child("w:numFmt")?.attributes["w:val"]
                    else { continue }
                    levels[ilvl] = fmt
                }
                info.levelFormatsByAbstractNumId[abstractId] = levels
            case "w:num":
                guard let numId = child.attributes["w:numId"],
                      let abstractRef = child.child("w:abstractNumId")?.attributes["w:val"]
                else { continue }
                info.abstractNumIdByNumId[numId] = abstractRef
            default:
                continue
            }
        }
        return info
    }

    /// Unresolvable input — no `numbering.xml` in the archive, or a `numId`/level it doesn't
    /// mention — defaults to unordered (a bullet), never ordered: an unnumbered document is a
    /// faithful reading, a fabricated "1. 2. 3." on plain bullets is not.
    private static func isOrdered(numId: String?, ilvl: Int, info: NumberingInfo) -> Bool {
        guard let numId,
              let abstractId = info.abstractNumIdByNumId[numId],
              let fmt = info.levelFormatsByAbstractNumId[abstractId]?[ilvl]
        else { return false }
        return fmt != "bullet"
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
    /// has any (`w:txbxContent`), and nothing at all if it has neither picture nor text.
    private static func collectDrawingBlocks(
        in node: XMLNode, styleOutlineLevels: [String: Int], numbering: NumberingInfo, relationships: Relationships
    ) -> [OfficeBlock] {
        var blocks: [OfficeBlock] = []
        func walk(_ node: XMLNode) {
            for child in node.children {
                switch child.name {
                case "mc:AlternateContent":
                    // `children.first` — if several `mc:Choice` were ever present, the first is
                    // Word's own preferred rendering.
                    if let choice = child.child("mc:Choice") { walk(choice) }
                case "w:drawing":
                    let pictures = imageBlocks(fromDrawing: child, relationships: relationships)
                    if !pictures.isEmpty {
                        blocks.append(contentsOf: pictures)
                    } else {
                        blocks.append(contentsOf: textBoxBlocks(
                            in: child, styleOutlineLevels: styleOutlineLevels, numbering: numbering,
                            relationships: relationships))
                    }
                case "w:pict":
                    if let block = imageBlock(fromPict: child, relationships: relationships) {
                        blocks.append(block)
                    } else {
                        blocks.append(contentsOf: textBoxBlocks(
                            in: child, styleOutlineLevels: styleOutlineLevels, numbering: numbering,
                            relationships: relationships))
                    }
                default:
                    walk(child)
                }
            }
        }
        walk(node)
        return blocks
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
        in node: XMLNode, styleOutlineLevels: [String: Int], numbering: NumberingInfo, relationships: Relationships
    ) -> [OfficeBlock] {
        var blocks: [OfficeBlock] = []
        for txbx in node.allDescendants("w:txbxContent") {
            for p in txbx.children where p.name == "w:p" {
                let paragraphBlocks = parseParagraph(
                    p, styleOutlineLevels: styleOutlineLevels, numbering: numbering, relationships: relationships)
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
        case .paragraph(let spans), .heading(_, let spans), .listItem(_, _, let spans):
            return spans.isEmpty
        case .table, .image:
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

    /// A relationship id resolves to the archive entry path for an embedded image, or to a
    /// clearly-marked, non-archive-shaped id (`"docx-unresolvable:…"`) for anything this reader
    /// cannot hand pixels for: no id on the element at all, an external (linked) target, or an id
    /// that doesn't appear in `document.xml.rels` at all (a malformed/edited document) — every one
    /// of these still returns a block, never nil, so a picture never silently vanishes from the
    /// block list. The later sprint that draws pixels is expected to treat this prefix as "always
    /// show a sized placeholder, never attempt an archive lookup".
    private static func resolveId(relId: String?, relationships: Relationships) -> String {
        guard let relId else { return unresolvableId("no-relationship-id") }
        guard let rel = relationships.byId[relId] else { return unresolvableId(relId) }
        return rel.external ? unresolvableId(rel.target) : rel.target
    }

    private static func unresolvableId(_ reason: String) -> String { "docx-unresolvable:\(reason)" }

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
        _ body: XMLNode, styleOutlineLevels: [String: Int], numbering: NumberingInfo, relationships: Relationships
    ) -> [OfficeBlock] {
        body.children.flatMap {
            parseBodyChild($0, styleOutlineLevels: styleOutlineLevels, numbering: numbering, relationships: relationships)
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
        _ child: XMLNode, styleOutlineLevels: [String: Int], numbering: NumberingInfo, relationships: Relationships
    ) -> [OfficeBlock] {
        switch child.name {
        case "w:p":
            return parseParagraph(
                child, styleOutlineLevels: styleOutlineLevels, numbering: numbering, relationships: relationships)
        case "w:tbl":
            return [parseTable(child, relationships: relationships)]
        case "w:sdt":
            guard let content = child.child("w:sdtContent") else { return [] }
            return content.children.flatMap {
                parseBodyChild($0, styleOutlineLevels: styleOutlineLevels, numbering: numbering, relationships: relationships)
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
        _ p: XMLNode, styleOutlineLevels: [String: Int], numbering: NumberingInfo, relationships: Relationships
    ) -> [OfficeBlock] {
        let pPr = p.child("w:pPr")
        let spans = collectSpans(in: p, relationships: relationships)
        let drawingBlocks = collectDrawingBlocks(
            in: p, styleOutlineLevels: styleOutlineLevels, numbering: numbering, relationships: relationships)
        // Heading wins over list, even when the paragraph ALSO carries `w:numPr` — Word-authored
        // contracts routinely attach a multilevel list to their heading styles so "1. Definitions"
        // / "2.1 Interpretation" number themselves, and `outlineLvl` is the author's explicit
        // "this is a heading at level N"; `numPr` only says how it happens to be numbered. Word's
        // own navigation pane treats such a paragraph as a heading, not a list item, and the
        // heading level already carries the hierarchy a list level would have expressed. Losing
        // this precedence would drop every clause heading in such a document out of the outline
        // sidebar — silently, since parsing still "succeeds". `outlineLvl 9` is still not a
        // heading (see `headingLevel`), so that case correctly falls through to `.listItem` below.
        let pStyleId = pPr?.child("w:pStyle")?.attributes["w:val"]
        let textBlock: OfficeBlock?
        let skipEmptyText = spans.isEmpty && !drawingBlocks.isEmpty
        if let level = headingLevel(pStyleId: pStyleId, styleOutlineLevels: styleOutlineLevels) {
            textBlock = skipEmptyText ? nil : .heading(level: level, spans: spans)
        } else if let numPr = pPr?.child("w:numPr") {
            let ilvl = Int(numPr.child("w:ilvl")?.attributes["w:val"] ?? "") ?? 0
            let numId = numPr.child("w:numId")?.attributes["w:val"]
            textBlock = skipEmptyText ? nil
                : .listItem(level: ilvl, ordered: isOrdered(numId: numId, ilvl: ilvl, info: numbering), spans: spans)
        } else {
            textBlock = skipEmptyText ? nil : .paragraph(spans: spans)
        }
        var blocks: [OfficeBlock] = []
        if let textBlock { blocks.append(textBlock) }
        blocks.append(contentsOf: drawingBlocks)
        return blocks
    }

    /// A grid position a row's own `<w:tc>` sequence doesn't literally cover — because `w:tcPr`
    /// carries an ANCHOR reference, not a grid coordinate — so this reader must derive each cell's
    /// starting grid column itself: walking a row's `<w:tc>` elements left to right, accumulating
    /// each one's own width (`w:gridSpan`, default 1) as it goes, is exactly that derivation. A
    /// well-formed row's cells always sum to the table's full grid width (a vertically-continuing
    /// cell still carries its own `<w:tc>` occupying its column, per spec), so this cumulative walk
    /// lands on the correct column even when two rows have a different NUMBER of `<w:tc>` (a
    /// horizontal merge changes how many `<w:tc>` a row needs without changing the grid it spans).
    private static func parseTable(_ tbl: XMLNode, relationships: Relationships) -> OfficeBlock {
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
                    let spans = collectCellSpans(tc, relationships: relationships)
                    rowCells.append(Cell(spans: spans, rowSpan: 1, colSpan: colSpan))
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

    /// A cell's content: its own paragraphs, PLUS the two places a naive reader silently drops
    /// real text from a `<w:tc>` — a `w:sdt` (content control) wrapping a paragraph (a form-field
    /// cell in a template table is a very common Word shape), and a full nested `<w:tbl>`. `Cell`
    /// has no case for a nested `.table` block, so a nested table's text is FLATTENED into spans
    /// (`flattenNestedTable`) rather than dropped — the grid disappears, the words in it do not.
    /// Deliberately mirrors `OdtReader.collectCellSpans`/`flattenNestedTable` exactly (same
    /// separator convention: a tab between cells, a newline after each non-empty row), so the two
    /// formats produce comparable output for the same shape rather than silently disagreeing.
    private static func collectCellSpans(_ tc: XMLNode, relationships: Relationships) -> [Span] {
        var spans: [Span] = []
        for child in tc.children {
            switch child.name {
            case "w:p":
                spans.append(contentsOf: collectSpans(in: child, relationships: relationships))
            case "w:tbl":
                spans.append(contentsOf: flattenNestedTable(child, relationships: relationships))
            case "w:sdt":
                if let content = child.child("w:sdtContent") {
                    spans.append(contentsOf: collectCellSpans(content, relationships: relationships))
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
    private static func flattenNestedTable(_ table: XMLNode, relationships: Relationships) -> [Span] {
        var spans: [Span] = []
        for row in table.children where row.name == "w:tr" {
            var rowHasContent = false
            for cell in row.children where cell.name == "w:tc" {
                let cellSpans = collectCellSpans(cell, relationships: relationships)
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
    private static func collectSpans(in node: XMLNode, relationships: Relationships) -> [Span] {
        var spans: [Span] = []
        func appendMerging(_ span: Span) {
            if let last = spans.last, last.bold == span.bold, last.italic == span.italic,
               last.underline == span.underline, last.code == span.code, last.link == span.link,
               last.strikethrough == span.strikethrough, last.superscript == span.superscript,
               last.subscripted == span.subscripted {
                spans[spans.count - 1].text += span.text
            } else {
                spans.append(span)
            }
        }
        func walk(_ node: XMLNode, link: String?) {
            for child in node.children {
                switch child.name {
                case "w:pPr", "w:rPr", "w:del", "w:bookmarkStart", "w:bookmarkEnd", "w:proofErr",
                     "w:sectPr", "w:commentRangeStart", "w:commentRangeEnd", "w:commentReference":
                    continue
                case "w:hyperlink":
                    // A hyperlink whose target can't be resolved (no `r:id`/`w:anchor`, or a
                    // relationship id absent from `document.xml.rels`) still keeps its text — only
                    // the link itself is lost, never the content, so `target` falling through to
                    // the OUTER `link` (usually nil) rather than being forced is deliberate.
                    walk(child, link: hyperlinkTarget(child, relationships: relationships) ?? link)
                case "w:sdt":
                    if let content = child.child("w:sdtContent") { walk(content, link: link) }
                case "w:r":
                    if var span = buildSpan(from: child) {
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
    /// into `\n`/`\t` in place. `w:sym` is a special-character reference (`w:font`+`w:char`, a
    /// code point in that FONT's own private encoding, e.g. Wingdings) with no `w:t` fallback at
    /// all — this reader has no way to map an arbitrary symbol-font code point to a real Unicode
    /// glyph, but silently emitting nothing would make the author's character disappear entirely
    /// (the one unforgivable failure this sprint exists to close), so it becomes a visible
    /// placeholder (▯) instead — wrong glyph, but honestly marked as "something was here", never
    /// mistaken for empty content. A run producing no text at all (formatting-only, or an empty
    /// bookmark anchor Word occasionally wraps in its own run) yields no span — the caller must
    /// never see a phantom empty one.
    private static func buildSpan(from run: XMLNode) -> Span? {
        var text = ""
        for child in run.children {
            switch child.name {
            case "w:t": text += child.text
            case "w:br": text += "\n"
            case "w:tab": text += "\t"
            case "w:sym": text += "▯"
            default: continue
            }
        }
        guard !text.isEmpty else { return nil }
        let rPr = run.child("w:rPr")
        let vertAlign = rPr?.child("w:vertAlign")?.attributes["w:val"]
        return Span(
            text: text, bold: isOn(rPr, "w:b"), italic: isOn(rPr, "w:i"), underline: isOn(rPr, "w:u"),
            strikethrough: isOn(rPr, "w:strike"), superscript: vertAlign == "superscript",
            subscripted: vertAlign == "subscript")
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

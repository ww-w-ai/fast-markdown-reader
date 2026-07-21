import AppKit

/// Turns a format-neutral `[OfficeBlock]` into styled `NSAttributedString`, the same way
/// `MarkdownRenderer` turns a parsed markdown tree into one and `PlainTextRenderer` turns raw text
/// into one. Every TOP-LEVEL block is exactly one navigation stop: it gets its own `MDAttr.blockId`
/// over its full rendered range (content + its one trailing separator), so gutter click / block
/// edit work here for free once a later sprint wires this into the document — see invariant 1's
/// sibling rule for images: a reserved layout size must never depend on whether pixels are loaded.
enum OfficeTextBuilder {
    /// `columnWidth` is the text column's width in points at build time (what `presizeKnownMedia`
    /// calls `maxWidth` for markdown) — defaulted huge so callers that don't care about wrapping
    /// (every test but the scaling one) get the declared size back untouched. A real caller
    /// (`MarkdownDocument.render(into:)`) always passes the reader's actual column width: office
    /// image sizing is decided HERE, once, at build time — never at load time (see `appendImage`).
    static func build(_ blocks: [OfficeBlock], theme: RenderTheme,
                      columnWidth: CGFloat = .greatestFiniteMagnitude) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var blockSeq = 0
        // Ordered-list numbering state, keyed by nesting level. Lives for the whole build() call
        // (not per-block) because the restart rule below needs to see across blocks.
        var orderedCounters: [Int: Int] = [:]

        func tagBlock(from start: Int) {
            let r = NSRange(location: start, length: result.length - start)
            guard r.length > 0 else { return }
            result.addAttribute(MDAttr.blockId, value: blockSeq, range: r)
            blockSeq += 1
        }

        for block in blocks {
            let start = result.length
            switch block {
            case let .heading(level, spans):
                result.append(spansAttributedString(spans, baseFont: theme.headingFont(level: level),
                                                     baseColor: theme.textColor, theme: theme))
                // Tagged BEFORE the trailing newline is appended, so a substring of this range is
                // exactly the heading's text — precisely what the outline sidebar reads
                // (`OutlinePanel.reload` trims and shows it verbatim).
                result.addAttribute(MDAttr.heading, value: level,
                                     range: NSRange(location: start, length: result.length - start))
                result.append(NSAttributedString(string: "\n"))
                result.addAttribute(.paragraphStyle, value: headingParagraphStyle(level: level, theme: theme),
                                     range: NSRange(location: start, length: result.length - start))

            case let .paragraph(spans):
                result.append(spansAttributedString(spans, baseFont: theme.bodyFont,
                                                     baseColor: theme.textColor, theme: theme))
                result.append(NSAttributedString(string: "\n"))
                result.addAttribute(.paragraphStyle, value: bodyParagraphStyle(theme: theme),
                                     range: NSRange(location: start, length: result.length - start))

            case let .listItem(level, ordered, spans, marker):
                appendListItem(level: level, ordered: ordered, spans: spans, marker: marker, into: result,
                                theme: theme, orderedCounters: &orderedCounters)

            case let .table(rows, headerRows):
                appendTable(rows, headerRows: headerRows, into: result, theme: theme)

            case let .image(id, size):
                appendImage(id: id, size: size, columnWidth: columnWidth, into: result)

            case let .unsupportedGraphic(label, size):
                appendUnsupportedGraphic(label: label, size: size, columnWidth: columnWidth, into: result)
            }
            tagBlock(from: start)
        }
        return result
    }

    // MARK: Spans → attributed runs

    /// Renders one block's spans against that block's base font/color. A `code` span overrides
    /// BOTH with the theme's inline-code styling and tags `MDAttr.inlineCode` — bold/italic/
    /// underline still layer on top of it (an office run can be monospaced AND bold at once,
    /// unlike a markdown code span, which never carries emphasis).
    ///
    /// NOT private: a later sprint's RTF reader re-themes spans it parsed itself rather than
    /// receiving as `OfficeBlock`, and needs this exact styling logic rather than a duplicate.
    static func spansAttributedString(_ spans: [Span], baseFont: NSFont, baseColor: NSColor,
                                      theme: RenderTheme) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for span in spans {
            var font = baseFont
            var color = baseColor
            var attrs: [NSAttributedString.Key: Any] = [:]
            if span.code {
                font = theme.codeFont
                color = theme.inlineCodeColor
                attrs[MDAttr.inlineCode] = true
            }
            var traits: NSFontDescriptor.SymbolicTraits = []
            if span.bold { traits.insert(.bold) }
            if span.italic { traits.insert(.italic) }
            if !traits.isEmpty { font = fontAdding(traits, to: font) }
            // Super/subscript shrink the font AND shift the baseline — `.superscript` alone isn't
            // interpreted by TextKit's own drawing, so it wouldn't actually render raised/lowered
            // here; a smaller font at an offset baseline is what makes it look right on screen.
            // `superscript`/`subscripted` are mutually exclusive in every real document, but if a
            // parser ever set both, superscript wins (checked first) rather than the two offsets
            // cancelling into something illegible.
            if span.superscript {
                let raised = font.pointSize * 0.35
                font = fontScaled(font, by: 0.7)
                attrs[.baselineOffset] = raised
            } else if span.subscripted {
                let lowered = -font.pointSize * 0.15
                font = fontScaled(font, by: 0.7)
                attrs[.baselineOffset] = lowered
            }
            attrs[.font] = font
            attrs[.foregroundColor] = color
            if span.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if span.strikethrough { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            // Same colour/underline treatment `MarkdownRenderer.inlineFragment`'s `Markdown.Link`
            // case uses — a link must look and behave identically whether it arrived via markdown
            // or an office hyperlink, not grow a second visual style.
            if let link = span.link, let url = URL(string: link) {
                attrs[.foregroundColor] = theme.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
                attrs[.link] = url
            }
            out.append(NSAttributedString(string: span.text, attributes: attrs))
        }
        return out
    }

    /// Adds symbolic traits while keeping the SAME family, so vertical metrics (ascent/descent)
    /// don't shift — an unrelated bold face would jitter the baseline under a fixed line height
    /// (same reasoning as `MarkdownRenderer.fontAdding`, duplicated here: that one is private to
    /// its file).
    private static func fontAdding(_ traits: NSFontDescriptor.SymbolicTraits, to font: NSFont) -> NSFont {
        let d = font.fontDescriptor.withSymbolicTraits(font.fontDescriptor.symbolicTraits.union(traits))
        return NSFont(descriptor: d, size: font.pointSize) ?? font
    }

    /// Same family, scaled point size — used for super/subscript, which shrink the glyph as well
    /// as shifting its baseline.
    private static func fontScaled(_ font: NSFont, by factor: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: (font.pointSize * factor).rounded()) ?? font
    }

    // MARK: Paragraph styles

    private static func bodyParagraphStyle(theme: RenderTheme) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let lh = (theme.baseFontSize * 1.45).rounded()
        p.minimumLineHeight = lh
        p.maximumLineHeight = lh
        p.paragraphSpacing = theme.baseFontSize * 0.9
        return p.copy() as! NSParagraphStyle
    }

    private static func headingParagraphStyle(level: Int, theme: RenderTheme) -> NSParagraphStyle {
        let b = theme.baseFontSize
        let p = NSMutableParagraphStyle()
        let lh = (theme.headingSize(level: level) * 1.25).rounded()
        p.minimumLineHeight = lh
        p.maximumLineHeight = lh
        p.paragraphSpacing = b * 0.4
        p.paragraphSpacingBefore = b * (level <= 2 ? 1.9 : 1.4)
        return p.copy() as! NSParagraphStyle
    }

    // MARK: Lists

    /// Bullet glyph per depth so nested levels read distinctly: • → ◦ → ▪ (then repeat) — same
    /// progression `MarkdownRenderer.bullet(_:)` uses.
    private static func bulletGlyph(_ level: Int) -> String {
        switch level % 3 {
        case 0:  return "•"
        case 1:  return "◦"
        default: return "▪"
        }
    }

    /// Hanging-indent paragraph style: marker at `markerX`, a tab pushes text to `textX`, and
    /// wrapped lines align at `textX` — so the item's first line and every wrap share one edge.
    private static func listParagraphStyle(markerX: CGFloat, textX: CGFloat, theme: RenderTheme) -> NSParagraphStyle {
        let p = NSMutableParagraphStyle()
        let lh = (theme.baseFontSize * 1.45).rounded()
        p.minimumLineHeight = lh
        p.maximumLineHeight = lh
        p.paragraphSpacing = theme.baseFontSize * 0.3
        p.firstLineHeadIndent = markerX
        p.headIndent = textX
        p.tabStops = [NSTextTab(textAlignment: .left, location: textX)]
        p.defaultTabInterval = textX
        return p.copy() as! NSParagraphStyle
    }

    /// Renders one list item and updates the per-level numbering state.
    ///
    /// Restart rule (the only stateful part of this file, and only when `marker` is `nil` — see
    /// below): any item at `level` clears the counters of every level DEEPER than it —
    /// a shallower-or-equal item breaks a deeper level's run, so that level restarts at 1 the next
    /// time it appears. A deeper level intervening does NOT clear a shallower level's own counter,
    /// so `1. / a. / b. / 2.` keeps counting `1, 2` at the outer level across the nested run. An
    /// UNORDERED item also clears its OWN level's counter, so a bullet breaks an ordered run at
    /// that same level too.
    ///
    /// `marker`, when supplied, is rendered VERBATIM and `orderedCounters` is left untouched —
    /// see `OfficeBlock.listItem`'s doc comment for why only the reader can compute real numbering
    /// text (continuation across paragraphs, `w:startOverride`, multi-level `%1.%2` formats). This
    /// builder's own counters are a fallback for when the source couldn't supply that text, not a
    /// second, competing numbering scheme — the two never mix for a single item.
    private static func appendListItem(level: Int, ordered: Bool, spans: [Span], marker suppliedMarker: String?,
                                       into result: NSMutableAttributedString, theme: RenderTheme,
                                       orderedCounters: inout [Int: Int]) {
        let marker: String
        if let suppliedMarker {
            marker = suppliedMarker + "\t"
        } else {
            // Snapshot the keys first — removing while iterating `.keys` directly mutates the same
            // storage the view is walking.
            for deeper in orderedCounters.keys.filter({ $0 > level }) {
                orderedCounters.removeValue(forKey: deeper)
            }
            if ordered {
                let n = (orderedCounters[level] ?? 0) + 1
                orderedCounters[level] = n
                marker = "\(n).\t"
            } else {
                orderedCounters.removeValue(forKey: level)
                marker = bulletGlyph(level) + "\t"
            }
        }

        let hang = theme.baseFontSize * 1.7
        let markerX = CGFloat(level) * hang
        let textX = CGFloat(level + 1) * hang
        let start = result.length
        result.append(NSAttributedString(string: marker,
            attributes: [.font: theme.bodyFont, .foregroundColor: theme.textColor]))
        result.append(spansAttributedString(spans, baseFont: theme.bodyFont, baseColor: theme.textColor, theme: theme))
        result.append(NSAttributedString(string: "\n"))
        result.addAttribute(.paragraphStyle, value: listParagraphStyle(markerX: markerX, textX: textX, theme: theme),
                            range: NSRange(location: start, length: result.length - start))
    }

    // MARK: Tables

    /// Real bordered grid via the shared `TableBlockBuilder` (also used by `MarkdownRenderer`'s
    /// GFM tables) — an office table now looks and behaves exactly like a markdown one, not a
    /// tab-stop approximation. `headerRows: 0` shades no row, because the source didn't say any
    /// row was a header (see `OfficeBlock.table`; guessing "row one" would misrepresent a
    /// headerless table). A cell shorter than the widest row leaves its trailing columns empty
    /// rather than collapsing the row.
    private static func appendTable(_ rows: [[Cell]], headerRows: Int, into result: NSMutableAttributedString,
                                    theme: RenderTheme) {
        guard rows.contains(where: { !$0.isEmpty }) else {
            result.append(NSAttributedString(string: "\n"))
            return
        }
        let headerFont = fontAdding(.bold, to: theme.bodyFont)
        let cellRows: [[TableBlockBuilder.CellContent]] = rows.enumerated().map { r, anchors in
            let isHeader = r < headerRows
            return anchors.map { cell in
                let content = cellContent(cell.blocks, baseFont: isHeader ? headerFont : theme.bodyFont, theme: theme)
                return TableBlockBuilder.CellContent(content: content, rowSpan: cell.rowSpan, columnSpan: cell.colSpan)
            }
        }
        result.append(TableBlockBuilder.build(rows: cellRows, headerRows: headerRows, theme: theme))
        result.append(NSAttributedString(string: "\n"))
    }

    /// Renders one cell's blocks. Deliberately NOT `build(_:theme:columnWidth:)` reused wholesale:
    /// that function ends every block with its own trailing `"\n"` PLUS a block-level paragraph
    /// style (heading/body line-height, paragraph spacing) sized for the full text column — inside
    /// a cell that fights `TableBlockBuilder`'s own paragraph style (`cellLH`, applied to the whole
    /// cell content afterwards) and would draw a spurious blank line under a single-paragraph cell.
    /// So the SEPARATOR is minimal here (a plain `"\n"` between blocks, none after the last) and no
    /// block gets its own `.paragraphStyle` — everything folds into the outer cell paragraph style.
    /// The single-block, single-paragraph case (the compatibility initialiser's shape) therefore
    /// renders BYTE-IDENTICAL to the pre-sprint `spansAttributedString(cell.spans, …)` call this
    /// replaces: no separator is ever emitted around a lone block.
    ///
    /// `.table` is handled by flattening rather than recursing into `appendTable`/
    /// `TableBlockBuilder` — a cell must never contain a REAL nested `NSTextTable` grid (the
    /// project's standing "nested tables flatten to text" decision, applied identically by both
    /// readers at parse time; this is the renderer's own backstop in case a `.table` block ever
    /// reaches a cell some other way).
    private static func cellContent(_ blocks: [OfficeBlock], baseFont: NSFont, theme: RenderTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, block) in blocks.enumerated() {
            switch block {
            case let .heading(level, spans):
                result.append(spansAttributedString(spans, baseFont: theme.headingFont(level: level),
                                                     baseColor: theme.textColor, theme: theme))
            case let .paragraph(spans):
                result.append(spansAttributedString(spans, baseFont: baseFont, baseColor: theme.textColor, theme: theme))
            case let .listItem(level, ordered, spans, marker):
                // Cell-local numbering state — a list embedded in one cell doesn't continue a
                // count begun in a sibling cell or at top level.
                var counters: [Int: Int] = [:]
                appendListItem(level: level, ordered: ordered, spans: spans, marker: marker, into: result,
                                theme: theme, orderedCounters: &counters)
                if result.length > 0, result.string.hasSuffix("\n") {
                    result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
                }
            case let .table(nestedRows, _):
                result.append(flattenTableToText(nestedRows, baseFont: baseFont, theme: theme))
            case let .image(id, size):
                appendImage(id: id, size: size, columnWidth: .greatestFiniteMagnitude, into: result)
                if result.length > 0, result.string.hasSuffix("\n") {
                    result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
                }
            case let .unsupportedGraphic(label, size):
                appendUnsupportedGraphic(label: label, size: size, columnWidth: .greatestFiniteMagnitude, into: result)
                if result.length > 0, result.string.hasSuffix("\n") {
                    result.deleteCharacters(in: NSRange(location: result.length - 1, length: 1))
                }
            }
            if index < blocks.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont]))
            }
        }
        return result
    }

    /// Flattens a nested table's cells into one run of text — a tab between cells, a newline after
    /// each non-empty row — so a reader glancing at the flattened text can still tell where one
    /// cell ended and the next began, even though the grid itself is gone. Mirrors the readers' own
    /// `flattenNestedTable` (applied when a `<w:tbl>`/`<table:table>` is found while COLLECTING a
    /// cell's spans, before a `Cell` even exists); this is the renderer-side twin for the case
    /// where a `.table` block reaches `cellContent` directly instead.
    private static func flattenTableToText(_ rows: [[Cell]], baseFont: NSFont, theme: RenderTheme) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for row in rows {
            var rowHasContent = false
            for cell in row {
                let text = cellContent(cell.blocks, baseFont: baseFont, theme: theme)
                guard text.length > 0 else { continue }
                if rowHasContent { result.append(NSAttributedString(string: "\t", attributes: [.font: baseFont])) }
                result.append(text)
                rowHasContent = true
            }
            if rowHasContent { result.append(NSAttributedString(string: "\n", attributes: [.font: baseFont])) }
        }
        return result
    }

    // MARK: Images

    /// Word DRAWS an image at its declared size regardless of the asset's own pixel dimensions (a
    /// 300px PNG placed at 225pt is ordinary), so — unlike a markdown image, whose true size is
    /// unknown until the bytes arrive — the declared size here is already authoritative. The only
    /// adjustment left is column-fitting: shrink proportionally if it's wider than the page. Doing
    /// that HERE, from the declared size alone, means `MarkdownDocument.reconcileMedia` never has
    /// to recompute a fit from real pixels for an office image — which matters, because
    /// recomputing on load is exactly the scroll-bar-jitter invariant 1 exists to prevent (an
    /// office image's pixel dimensions can legitimately disagree with its declared size).
    private static func fittedOfficeSize(_ declared: CGSize, columnWidth: CGFloat) -> CGSize {
        guard declared.width > columnWidth, declared.width > 0 else { return declared }
        let scale = columnWidth / declared.width
        return CGSize(width: columnWidth.rounded(), height: (declared.height * scale).rounded())
    }

    /// Reserves the (column-fitted) declared size via `SizedAttachmentCell`, image left `nil` —
    /// pixels arrive lazily via `MarkdownDocument.reconcileMedia`. This is invariant 1 of this
    /// codebase: the reserved layout size must NEVER depend on whether an image is loaded, or the
    /// scroll bar swings when it loads/purges.
    private static func appendImage(id: String, size: CGSize, columnWidth: CGFloat,
                                    into result: NSMutableAttributedString) {
        let fitted = fittedOfficeSize(size, columnWidth: columnWidth)
        let att = NSTextAttachment()
        att.bounds = NSRect(origin: .zero, size: fitted)
        att.attachmentCell = SizedAttachmentCell(reservedSize: fitted)
        let ph = NSMutableAttributedString(attachment: att)
        ph.addAttribute(MDAttr.image, value: id, range: NSRange(location: 0, length: ph.length))
        result.append(ph)
        result.append(NSAttributedString(string: "\n"))
    }

    /// A chart/SmartArt this reader could not resolve to any picture at all — reserves the SAME
    /// declared+column-fitted area `appendImage` would, drawn as a bordered, labelled frame
    /// SYNTHESIZED RIGHT HERE rather than left for `MarkdownDocument.reconcileMedia` to fill in
    /// later. Deliberately NOT built through `SizedAttachmentCell` the way `appendImage`'s
    /// reserved-but-unloaded state is (measured: `NSTextAttachment` drops a custom
    /// `attachmentCell` the moment `.image` is set — AppKit switches to its own bounds-based
    /// image layout at that point, the SAME mechanism `reconcileMedia`'s "pixels already loaded,
    /// just repaint" branch relies on) — so sizing here comes from `.bounds` alone, set once,
    /// alongside an `.image` that is never nil to begin with. Invariant 1 (reserved size must
    /// never depend on whether pixels are loaded) holds trivially: there is no "not yet loaded"
    /// state for this case at all, so nothing here can ever revise `.bounds` after the fact.
    /// `label` renders verbatim — the caller (`DocxReader`) already turned it into a word a reader
    /// understands ("Chart", "Diagram"), never an XML element name.
    private static func appendUnsupportedGraphic(label: String, size: CGSize, columnWidth: CGFloat,
                                                  into result: NSMutableAttributedString) {
        let fitted = fittedOfficeSize(size, columnWidth: columnWidth)
        let frame = NSImage(size: fitted, flipped: false) { rect in
            Palette.codeCardBg.setFill()
            rect.fill()
            Palette.codeCardBorder.setStroke()
            NSBezierPath(rect: rect.insetBy(dx: 0.5, dy: 0.5)).stroke()
            let text = "[\(label)]" as NSString
            let fontSize = max(9, min(14, rect.height * 0.18))
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: Palette.secondary,
            ]
            let textSize = text.size(withAttributes: attrs)
            let origin = NSPoint(x: (rect.width - textSize.width) / 2, y: (rect.height - textSize.height) / 2)
            text.draw(at: origin, withAttributes: attrs)
            return true
        }
        let att = NSTextAttachment()
        att.bounds = NSRect(origin: .zero, size: fitted)
        att.image = frame
        result.append(NSAttributedString(attachment: att))
        result.append(NSAttributedString(string: "\n"))
    }
}

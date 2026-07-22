import AppKit

/// The one place that builds a real bordered `NSTextTable` grid, shared by `MarkdownRenderer`
/// (GFM tables) and `OfficeTextBuilder` (Word/office tables) — a table looks and behaves the same
/// however the document reached it. Each caller renders its own cell content (markdown inline
/// spans vs office `Span`s) into an `NSAttributedString` first; this only lays those strings into
/// `NSTextTableBlock` cells with border, padding and header shading.
enum TableBlockBuilder {
    /// Upper bound on a single cell's row/column span. A span comes from a parsed file, so a corrupt
    /// or hostile document can claim any number; this keeps an absurd one from turning into that many
    /// loop iterations and set insertions. No real table comes near it.
    static let maxSpan = 512

    /// A guess for the reading column's width at BUILD time, when no real one exists yet — a
    /// table is built once at parse time, long before `DocumentWindowController` knows the actual
    /// window width. Matches the `NSTextContainer`'s own initial 600pt (`DocumentWindowController`'s
    /// `init`), so the FIRST paint (before `updateTextInset` runs its own
    /// `resizeTableColumns(toColumn:)`) is already close, not zero-width. Purely cosmetic: the real
    /// width always arrives on the very next layout pass, same as invariant 2's "measure everything,
    /// then lay out once" — this is that pass's harmless placeholder, not a second source of truth.
    static let initialColumnWidth: CGFloat = 600

    /// The reader's comfortable in-cell inset, and the FLOOR every cell's padding is held to (see the
    /// per-cell `cellPadding` below): markdown declares none and gets exactly this; docx/odt declare
    /// their own but never render below it, so a `fo:padding="0cm"` cell reads with room, not cramped.
    static let defaultCellPadding: CGFloat = 7

    /// One already-styled cell, plus how many rows/columns its `NSTextTableBlock` covers.
    /// `rowSpan`/`columnSpan` default to 1, so a caller with no merges (every markdown table, and
    /// an office table before its parser learns `w:gridSpan`/`w:vMerge`) builds these without ever
    /// mentioning them.
    struct CellContent {
        var content: NSAttributedString
        var rowSpan: Int = 1
        var columnSpan: Int = 1
        /// The cell's OWN shading/border/width, `nil`/`nil`/`nil`/`nil` meaning "use `build`'s
        /// existing theme defaults" (header shading, `Palette.tableBorder` at 1pt, auto column
        /// layout) exactly as before these fields existed — see `Cell`'s own doc comment in
        /// `OfficeBlock.swift` for the source-format reasoning; this struct only carries the
        /// already-decided values through to `NSTextTableBlock`.
        var backgroundColor: NSColor? = nil
        var borderColor: NSColor? = nil
        var borderWidth: CGFloat? = nil
        var width: CGFloat? = nil
        /// Mirrors `Cell.verticalAlignment` — `nil` leaves `NSTextTableBlock`'s already-`.top`
        /// vertical alignment untouched.
        var verticalAlignment: CellVAlign? = nil
        /// Mirrors `Cell.padding` — already resolved by the caller against any table default;
        /// `nil` means neither said anything, and `build` keeps its own pre-existing 7pt default.
        var padding: CGFloat? = nil
        /// The cell's shading/border RESOLVED from the table's named STYLE (`Cell.styleShading`/
        /// `.styleBorderColor`/`.styleBorderWidth` — P5), a LOWER-priority layer than the direct
        /// fields above and the table's own direct default (`tableShading`/`tableBorderColor`/
        /// `tableBorderWidth` on `build`) but a HIGHER-priority one than the theme default — see
        /// `build`'s resolution chain below.
        var styleShading: NSColor? = nil
        var styleBorderColor: NSColor? = nil
        var styleBorderWidth: CGFloat? = nil
    }

    /// - Parameters:
    ///   - rows: one entry per row, listing only that row's ANCHOR cells (the top-left corner of
    ///     each merge) left to right — a covered position (inside another cell's `rowSpan`/
    ///     `columnSpan`) is simply absent, not present-and-empty. A row with fewer VISIBLE columns
    ///     than the widest row just leaves its trailing columns empty, it does not shift or
    ///     collapse; the grid's total column count is derived below from every row's anchors and
    ///     their spans together, not from any single row's `count`.
    ///   - headerRows: how many LEADING rows are shaded/bold. `0` means none — a real contract can
    ///     be headerless, and shading row one anyway would misrepresent it (same reasoning
    ///     `OfficeTextBuilder.appendTable`'s doc comment gives for its own header handling).
    ///   - columnWidths: the SOURCE's own grid column widths (points, left-to-right), authoritative
    ///     over any per-cell `CellContent.width` — see `OfficeBlock.table`'s doc comment. Empty (the
    ///     default, and every markdown table) or a count that doesn't match the grid derived below
    ///     leaves this function's PRE-EXISTING per-cell/auto layout completely untouched; only a
    ///     usable grid switches a placed cell's width source from `CellContent.width` (absolute) to
    ///     a percentage of these ratios (see the per-placement loop below).
    ///   - tableBorderColor/tableBorderWidth/tableShading: the table's OWN default border/shading
    ///     (see `TableFormat`) — the MIDDLE layer of the resolution chain a placed cell now goes
    ///     through: its own value, then these table defaults, then (only if both are `nil`) this
    ///     function's pre-existing theme default. All three default to `nil`, so a caller that never
    ///     mentions them (every markdown table) renders BYTE-IDENTICAL to before these parameters
    ///     existed.
    static func build(rows: [[CellContent]], headerRows: Int, theme: RenderTheme,
                       columnWidths: [CGFloat] = [], tableBorderColor: NSColor? = nil,
                       tableBorderWidth: CGFloat? = nil, tableShading: NSColor? = nil) -> NSAttributedString {
        let result = NSMutableAttributedString()
        guard !rows.isEmpty else { return result }

        // Walk anchors in document order, placing each into the next column not already covered
        // by an EARLIER row's vertical span. `coveredByLaterRow[r]` collects the columns a span
        // starting above row `r` reaches into; only entries for rows AFTER the anchor's own row
        // are recorded here — within the anchor's own row, `col` is advanced directly by its
        // `columnSpan`, so nothing needs to be looked up for that row.
        struct Placement { let row: Int; let col: Int; let rowSpan: Int; let colSpan: Int; let cell: CellContent? }
        var placements: [Placement] = []
        var coveredByLaterRow: [Int: Set<Int>] = [:]
        var ncol = 0

        for (r, anchors) in rows.enumerated() {
            let covered = coveredByLaterRow[r] ?? []
            var col = 0
            for cell in anchors {
                // A span arrives from a parsed document, so it is untrusted: a file claiming a cell
                // spans a million rows would otherwise have us loop and allocate that many times.
                // Same posture as ZipArchive's declared-size cap — refuse the absurd, keep rendering.
                let rowSpan = min(max(1, cell.rowSpan), Self.maxSpan)
                let colSpan = min(max(1, cell.columnSpan), Self.maxSpan)
                while covered.contains(col) { col += 1 }
                placements.append(Placement(row: r, col: col, rowSpan: rowSpan, colSpan: colSpan, cell: cell))
                if rowSpan > 1 {
                    for laterRow in (r + 1)..<(r + rowSpan) {
                        coveredByLaterRow[laterRow, default: []].formUnion(col..<(col + colSpan))
                    }
                }
                col += colSpan
                ncol = max(ncol, col)
            }
        }
        guard ncol > 0 else { return result }

        // Normalise the source's grid widths to PERCENTAGES that sum to 100 — proportions of the
        // already-100%-wide table, not absolute sizes, so they must never be scaled by
        // `fontSizeScale` (unlike a font-derived size, invariant 24's zoom multiplies on top of
        // these, not into them) and never fed in as raw twips (that would be the exact landmine
        // `cellWidth`'s doc comment already warns about for absolute cell widths). Only used when
        // the grid actually matches this table's own derived column count — a mismatch (a
        // malformed/edited document) is treated exactly like "no grid known" rather than partially
        // applied to the wrong columns.
        var columnPercentages: [CGFloat] = []
        if columnWidths.count == ncol {
            let sum = columnWidths.reduce(0, +)
            if sum > 0 {
                columnPercentages = columnWidths.map { $0 / sum * 100 }
            }
        }

        // Pad the gaps. A row can carry fewer anchors than the grid is wide — which is exactly what a
        // vertically merged Word row looks like — and a position left with no block at all renders as
        // a hole in the border, not as an empty cell. Only genuinely UNOCCUPIED positions are padded:
        // a position covered by another cell's span is taken, not empty, and must stay untouched.
        var occupied: [Int: Set<Int>] = [:]
        for p in placements {
            for r in p.row..<(p.row + p.rowSpan) {
                occupied[r, default: []].formUnion(p.col..<(p.col + p.colSpan))
            }
        }
        for r in rows.indices {
            let taken = occupied[r] ?? []
            for c in 0..<ncol where !taken.contains(c) {
                placements.append(Placement(row: r, col: c, rowSpan: 1, colSpan: 1, cell: nil))
            }
        }
        // Reading order, so the laid-out cells follow the grid rather than the order they were found.
        placements.sort { ($0.row, $0.col) < ($1.row, $1.col) }

        let textTable = NSTextTable()
        textTable.numberOfColumns = ncol
        textTable.setContentWidth(100, type: .percentageValueType)
        let cellLH = (theme.baseFontSize * theme.codeLineHeightRatio).rounded()

        for placement in placements {
            let header = placement.row < headerRows
            let block = FixedWidthTableBlock(table: textTable, startingRow: placement.row, rowSpan: placement.rowSpan,
                                             startingColumn: placement.col, columnSpan: placement.colSpan)
            // An authored border/width/background on the ANCHOR cell wins over the table's own
            // default, which in turn wins over the theme default — a covered position
            // (`placement.cell == nil`, padding the grid) never has a cell OR table value to win
            // with, so it always gets the plain theme look. (`tableBorderColor`/`tableBorderWidth`/
            // `tableShading` are `nil` for every markdown table and any docx table with no
            // `w:tblPr` default, so this chain collapses to exactly the old two-step lookup then.)
            // Full chain, most to least specific: cell-direct > table-direct > table-STYLE
            // (`styleBorderColor`/`styleShading` — P5) > theme default.
            block.setBorderColor(placement.cell?.borderColor ?? tableBorderColor
                                  ?? placement.cell?.styleBorderColor ?? Palette.tableBorder)
            // Native border WIDTH is forced to 0 — AppKit draws a text block's native border from
            // its own PERCENTAGE-derived column edges, which is exactly what let a `gridSpan=3`
            // row's shared boundary land at a different x than a 4-single-cell row's (P11, the bug
            // this class exists to fix). `FixedWidthTableBlock.strokeWidth` carries the resolved
            // width instead, and `drawBackground` paints it from a RIGID absolute column edge that
            // can't float row to row. The colour above is still native — colour never floated, only
            // the column x position did, so only the drawing of the line itself needs replacing.
            let resolvedBorderWidth = placement.cell?.borderWidth ?? tableBorderWidth
                                        ?? placement.cell?.styleBorderWidth ?? 1
            block.setWidth(0, type: .absoluteValueType, for: .border)
            block.strokeWidth = resolvedBorderWidth
            // Top+left are always this cell's own; right/bottom are drawn only at the grid's outer
            // edge — the boundary BETWEEN two cells is then painted exactly once (by the cell to
            // its right/below), so it can never land at two different x/y values for two different
            // rows/columns the way two independent percentage-typed edges could.
            block.drawsRightEdge = (placement.col + placement.colSpan) >= ncol
            block.drawsBottomEdge = (placement.row + placement.rowSpan) >= rows.count
            // HORIZONTAL padding is forced to 0 and the text is inset by paragraph indent instead
            // (below). A cell's LEFT/RIGHT block padding is per-cell, so a merged row (fewer cells)
            // carries less total horizontal padding than a single-cell row, and `NSTextTable`
            // redistributes that mismatch — landing the SAME shared column boundary at a different x
            // per row (measured 28pt of drift for a gridSpan=3 row, plus 14pt WITHIN it). Zeroing
            // horizontal padding makes every cell's frame width its content width exactly, so column
            // seams become a pure cumulative sum identical for every row (rhwp's edge model) — the
            // real fix P11's absolute widths couldn't reach while padding still inflated the frame.
            // VERTICAL padding stays: top/bottom padding never touches an x edge, only breathing room.
            // A cell never renders TIGHTER than the reader's comfortable default, whatever the source
            // declared: an odt cell very commonly carries `fo:padding="0cm"` (and docx a small
            // `w:tcMar`), and honouring that verbatim packs the text against the borders — the "stacked
            // boxes"/"예전 docx" look. The document's OWN value wins only when it asks for MORE room, so
            // markdown, docx and odt tables share one comfortable floor instead of each passing a
            // different padding through. (Structural fidelity — columns, spans, borders — is untouched;
            // only the inner breathing room is unified.)
            let cellPadding = max(placement.cell?.padding ?? Self.defaultCellPadding, Self.defaultCellPadding)
            block.setWidth(0, type: .absoluteValueType, for: .padding, edge: .minX)
            block.setWidth(0, type: .absoluteValueType, for: .padding, edge: .maxX)
            block.setWidth(cellPadding, type: .absoluteValueType, for: .padding, edge: .minY)
            block.setWidth(cellPadding, type: .absoluteValueType, for: .padding, edge: .maxY)
            if let bg = placement.cell?.backgroundColor {
                block.backgroundColor = bg
            } else if let tableShading {
                block.backgroundColor = tableShading
            } else if let styleBg = placement.cell?.styleShading {
                block.backgroundColor = styleBg
            } else if header {
                block.backgroundColor = Palette.tableHeaderBg
            }
            // `nil` leaves AppKit's own already-`.top` default untouched — see
            // `Cell.verticalAlignment`'s doc comment for why there's no table-level default to fall
            // through to here (only a per-cell `w:vAlign` exists in the source spec).
            switch placement.cell?.verticalAlignment {
            case .top: block.verticalAlignment = .topAlignment
            case .center: block.verticalAlignment = .middleAlignment
            case .bottom: block.verticalAlignment = .bottomAlignment
            case nil: break
            }
            // P11: every column gets a FIXED FRACTION of the whole table's width, never a
            // percentage `NSTextTableBlock` resolves per row — a spanned cell gets the SUM of the
            // fractions of every grid column it covers (see `OfficeBlock.table`'s doc comment:
            // `rows[row].count` is not the column count once a span is wider than 1, so this must
            // sum `placement.colSpan` columns' fractions, not just read one). With no source grid
            // (every markdown table, and an office table before its parser learns `w:tblGrid`) each
            // column gets an EQUAL share, `colSpan / ncol` — the padding pass above already
            // guarantees every row's placements cover the grid's `ncol` columns exactly once, so
            // these fractions sum to 1 whether or not a real grid is known. This REPLACES the old
            // per-cell absolute `CellContent.width` path entirely: a table can't be sized by both a
            // grid-relative fraction and an independent per-cell absolute value at once, and mixing
            // the two is exactly the kind of row-to-row drift this class exists to remove.
            let fraction: CGFloat
            if !columnPercentages.isEmpty {
                let coveredCols = min(placement.col + placement.colSpan, columnPercentages.count)
                let pct = (placement.col..<max(placement.col, coveredCols))
                    .reduce(CGFloat(0)) { $0 + columnPercentages[$1] }
                fraction = pct / 100
            } else {
                fraction = CGFloat(placement.colSpan) / CGFloat(ncol)
            }
            block.columnFraction = fraction
            // `DocumentWindowController.resizeTableColumns(toColumn:)` re-sets this to the REAL
            // column on every display/resize (mirroring `reanchorFillMarginTabs`) — this initial
            // value only has to hold until that first pass runs.
            block.setContentWidth(fraction * Self.initialColumnWidth, type: .absoluteValueType)
            let content = NSMutableAttributedString()
            if let cell = placement.cell { content.append(cell.content) }
            let font = header ? NSFont.systemFont(ofSize: theme.baseFontSize, weight: .semibold) : theme.bodyFont
            content.append(NSAttributedString(string: "\n", attributes: [.font: font]))
            // Attach this cell's `NSTextTableBlock` + horizontal inset to EACH paragraph in the cell,
            // PRESERVING that paragraph's own spacing and line-height instead of flattening the whole
            // cell to one uniform style. A document whose body lives inside single-cell "box" tables (a
            // very common office layout — one bordered table per section, all its bullets inside) would
            // otherwise lose every paragraph gap and read as one dense block: the cell's own paragraphs
            // already carry the readability floor `bodyParagraphStyle` applied, and a uniform overwrite
            // discarded it. HORIZONTAL block padding stays 0 (column seams = pure cumulative sum, the
            // P11 fix); the `cellPadding` inset is ADDED to each paragraph's own indent so text clears
            // the border without moving the seam. A paragraph that declared NO line height (every
            // markdown cell) gets the cell's default `cellLH`; one that did (office body) keeps its own.
            // Merge per PARAGRAPH (not per paragraph-style run): each paragraph's `enclosing` range
            // includes its terminating "\n", so a paragraph and its terminator get ONE merged style —
            // a cell whose content is a single paragraph stays a single table-block run (the cell's own
            // trailing "\n", appended above with no style, is folded into that last paragraph here, not
            // split into a second run). Each paragraph takes its OWN leading style (spacing/line-height
            // preserved from `cellContent`) plus this cell's block + inset.
            let ns = content.string as NSString
            var mergedRuns: [(NSRange, NSParagraphStyle)] = []
            ns.enumerateSubstrings(in: NSRange(location: 0, length: content.length), options: .byParagraphs) {
                _, _, enclosing, _ in
                guard enclosing.length > 0 else { return }
                let existing = content.attribute(.paragraphStyle, at: enclosing.location,
                                                 effectiveRange: nil) as? NSParagraphStyle
                let ps = (existing?.mutableCopy() as? NSMutableParagraphStyle) ?? NSMutableParagraphStyle()
                ps.textBlocks = [block]
                if ps.minimumLineHeight == 0 && ps.maximumLineHeight == 0 {
                    ps.minimumLineHeight = cellLH
                    ps.maximumLineHeight = cellLH
                }
                ps.firstLineHeadIndent += cellPadding
                ps.headIndent += cellPadding
                ps.tailIndent -= cellPadding
                mergedRuns.append((enclosing, ps.copy() as! NSParagraphStyle))
            }
            for (range, ps) in mergedRuns { content.addAttribute(.paragraphStyle, value: ps, range: range) }
            result.append(content)
        }
        return result
    }
}

/// P11: a table cell whose CONTENT WIDTH is always a RIGID, ABSOLUTE point value — never a
/// percentage — and whose border is drawn BY HAND, one stroke per shared edge, instead of through
/// `NSTextTableBlock`'s own per-row border. Fixes the bug this sprint exists for: a
/// percentage-typed column floats independently per row (a uniform 4-column grid where one row
/// has a `gridSpan=3` merge lands that row's shared boundary at a slightly different x than a row
/// of 4 single cells), because `NSTextTable` resolves each row's percentages against that row's
/// own content on the fly. An absolute width can't float — every row asking for
/// `columnFraction * column` gets the exact same point value — so every row's boundary lines up.
///
/// `columnFraction` is set once at build time (`TableBlockBuilder.build`) and read every time
/// `DocumentWindowController.resizeTableColumns(toColumn:)` re-anchors the absolute width to the
/// CURRENT reading column (display, resize, sidebar toggle — the same cadence `reanchorFillMarginTabs`
/// already runs on), so a table stays rigid AND still fills/tracks the window.
final class FixedWidthTableBlock: NSTextTableBlock {
    /// This cell's fixed share of the table's total width: the SUM of the grid ratios of every
    /// column it spans, divided by the sum of every column's ratio — or, with no source grid at
    /// all (every markdown table), an equal share, `colSpan / ncol`. See `build`'s computation.
    var columnFraction: CGFloat = 0
    /// This cell's resolved border stroke width — the SAME resolution chain `build` already ran
    /// (cell-direct > table-direct > table-style > `1`), just drawn here instead of through
    /// `NSTextTableBlock`'s own native `.border` width, which `build` forces to `0` (see there).
    var strokeWidth: CGFloat = 1
    /// This cell owns the table's RIGHT edge — only the grid's last column draws it; every other
    /// column's right edge is the NEXT column's left edge (drawn once, by that column, below).
    var drawsRightEdge = false
    /// This cell owns the table's BOTTOM edge — only the grid's last row draws it, for the same
    /// reason `drawsRightEdge` doesn't: the boundary between two rows is the row BELOW's top.
    var drawsBottomEdge = false

    override func drawBackground(withFrame frameRect: NSRect, in controlView: NSView,
                                  characterRange charRange: NSRange, layoutManager: NSLayoutManager) {
        super.drawBackground(withFrame: frameRect, in: controlView, characterRange: charRange, layoutManager: layoutManager)
        guard strokeWidth > 0, let color = borderColor(for: .minY) else { return }
        // Snap to the backing pixel grid before filling — an unaligned stroke straddles two
        // physical pixels and reads thicker on one row than its rigid-width neighbour, which is
        // exactly the jaggedness a RIGID column width is supposed to remove.
        let s = controlView.backingAlignedRect(frameRect, options: .alignAllEdgesNearest)
        color.setFill()
        // The text view is FLIPPED (see invariant 14), so `minY` is the TOP edge, not the bottom.
        NSRect(x: s.minX, y: s.minY, width: s.width, height: strokeWidth).fill()             // top
        NSRect(x: s.minX, y: s.minY, width: strokeWidth, height: s.height).fill()             // left
        if drawsRightEdge {
            NSRect(x: s.maxX - strokeWidth, y: s.minY, width: strokeWidth, height: s.height).fill()
        }
        if drawsBottomEdge {
            NSRect(x: s.minX, y: s.maxY - strokeWidth, width: s.width, height: strokeWidth).fill()
        }
    }
}

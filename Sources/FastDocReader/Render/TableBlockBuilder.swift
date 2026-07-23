import AppKit

/// An `NSTextTable` that remembers its columns' PROPORTIONS (summing to 1) so the table can be
/// re-solved to ABSOLUTE integer point widths at whatever reading-column width the window currently
/// has. Percentage column widths are the wrong tool: `NSTextTable` recomputes them per row, so a
/// column boundary lands on a slightly different fractional pixel in a 4-cell row than in a
/// span-merged one — the "열이 살짝 어긋남" drift. Absolute widths, computed once as a cumulative sum of
/// rounded integer edges, put every row's column boundary at the SAME integer x by construction.
final class GridTextTable: NSTextTable {
    var columnProportions: [CGFloat] = []   // one per column, sums to 1
    /// Integer cumulative x-edges (ncol+1) at `width` — the shared grid every cell reads.
    func edges(forWidth width: CGFloat) -> [CGFloat] {
        var out: [CGFloat] = [0]
        var cum: CGFloat = 0
        for p in columnProportions { cum += p; out.append((width * cum).rounded()) }
        return out
    }
}

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

        // Lay the cells into a REAL `NSTextTable` so their text is part of the document — selectable,
        // copyable and searchable (a custom-drawn attachment, however crisply aligned, is a picture the
        // reader can't select, copy or ⌘F). Columns are pinned by PERCENTAGE of the table (one shared
        // proportion per column, spanned cells summing their columns'), so every row reads the same
        // column edge and the table tracks the window width natively — no custom relayout. The old
        // "per-row packing drifted a merged seam" was the reason for the earlier custom engine; giving
        // every cell in a column the identical percentage removes the per-row freedom that drifted.
        // Column PROPORTIONS (sum 1) — from the source's own grid, else equal. Kept on the table so a
        // resize can re-solve absolute widths; the table is first built at the placeholder width and
        // `resizeTables(in:toWidth:)` re-solves it to the real reading column on the next layout.
        let proportions: [CGFloat] = columnPercentages.isEmpty
            ? Array(repeating: 1 / CGFloat(ncol), count: ncol)
            : columnPercentages.map { $0 / 100 }
        let table = GridTextTable()
        table.numberOfColumns = ncol
        table.columnProportions = proportions
        table.collapsesBorders = true
        table.hidesEmptyCells = false
        let edges = table.edges(forWidth: Self.initialColumnWidth)

        for placement in placements {
            let header = placement.row < headerRows
            // cell-direct > table-direct > table-STYLE (P5) > theme default — unchanged resolution.
            let borderColor = placement.cell?.borderColor ?? tableBorderColor
                ?? placement.cell?.styleBorderColor ?? Palette.tableBorder
            let borderWidth = placement.cell?.borderWidth ?? tableBorderWidth
                ?? placement.cell?.styleBorderWidth ?? 1
            let background: NSColor?
            if let bg = placement.cell?.backgroundColor { background = bg }
            else if let tableShading { background = tableShading }
            else if let styleBg = placement.cell?.styleShading { background = styleBg }
            else if header { background = Palette.tableHeaderBg }
            else { background = nil }
            let padding = max(placement.cell?.padding ?? Self.defaultCellPadding, Self.defaultCellPadding)

            let block = NSTextTableBlock(table: table,
                                         startingRow: placement.row, rowSpan: placement.rowSpan,
                                         startingColumn: placement.col, columnSpan: placement.colSpan)
            block.setBorderColor(borderColor)
            block.setWidth(borderWidth, type: .absoluteValueType, for: .border)
            block.setWidth(padding, type: .absoluteValueType, for: .padding)
            // ABSOLUTE integer content width: the cell's integer span width minus its own padding and
            // borders, so every row's column boundary lands on the same integer x (no percentage drift).
            let cellWidth = edges[min(placement.col + placement.colSpan, ncol)] - edges[placement.col]
            block.setContentWidth(max(1, cellWidth - 2 * padding - 2 * borderWidth), type: .absoluteValueType)
            if let background { block.backgroundColor = background }
            switch placement.cell?.verticalAlignment ?? .top {
            case .top: block.verticalAlignment = .topAlignment
            case .center: block.verticalAlignment = .middleAlignment
            case .bottom: block.verticalAlignment = .bottomAlignment
            }

            // Each cell is one or more paragraphs carrying this block. Preserve the cell content's own
            // paragraph style (alignment/indent/spacing) and only graft the table block onto it.
            let cellStr = NSMutableAttributedString(attributedString: placement.cell?.content ?? NSAttributedString())
            if cellStr.length == 0 || !cellStr.string.hasSuffix("\n") {
                cellStr.append(NSAttributedString(string: "\n"))
            }
            let whole = NSRange(location: 0, length: cellStr.length)
            cellStr.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
                let ps = (value as? NSParagraphStyle)?.mutableCopy() as? NSMutableParagraphStyle
                    ?? NSMutableParagraphStyle()
                ps.textBlocks = [block]
                cellStr.addAttribute(.paragraphStyle, value: ps, range: range)
            }
            result.append(cellStr)
        }
        // A trailing paragraph with NO table block closes the table (else the next document content
        // would be pulled into the last cell). The caller's own following block usually does this, but
        // a table that ends the document needs its own terminator.
        result.append(NSAttributedString(string: "\n"))
        return result
    }

    /// Re-solve every `GridTextTable`'s cells to ABSOLUTE integer widths for the current reading-column
    /// `width`. Tables are built at a placeholder width (`initialColumnWidth`); this is the counterpart
    /// of the old custom engine's `relayout`, but far smaller — it just rewrites each cell block's
    /// content width from the table's stored proportions, then the layout manager reflows. Called from
    /// the window controller on first layout and every reflow (resize / sidebar toggle).
    static func resizeTables(in storage: NSTextStorage, toWidth width: CGFloat) {
        guard width > 0, storage.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
        var edgesByTable: [ObjectIdentifier: [CGFloat]] = [:]
        var touched: [NSRange] = []
        storage.enumerateAttribute(.paragraphStyle, in: whole) { value, range, _ in
            guard let ps = value as? NSParagraphStyle,
                  let block = ps.textBlocks.first as? NSTextTableBlock,
                  let table = block.table as? GridTextTable, !table.columnProportions.isEmpty else { return }
            let key = ObjectIdentifier(table)
            let edges = edgesByTable[key] ?? {
                let e = table.edges(forWidth: width); edgesByTable[key] = e; return e
            }()
            let ncol = table.numberOfColumns
            let c0 = min(block.startingColumn, ncol)
            let c1 = min(block.startingColumn + block.columnSpan, ncol)
            guard c1 > c0, c1 < edges.count else { return }
            let pad = block.width(for: .padding, edge: .minX)   // read back this cell's own padding
            let border = block.width(for: .border, edge: .minX)
            block.setContentWidth(max(1, edges[c1] - edges[c0] - 2 * pad - 2 * border), type: .absoluteValueType)
            touched.append(range)
        }
        // Widths changed on the shared block objects; nudge layout to pick them up.
        if !touched.isEmpty, let lm = storage.layoutManagers.first {
            for r in touched { lm.invalidateLayout(forCharacterRange: r, actualCharacterRange: nil) }
        }
    }
}

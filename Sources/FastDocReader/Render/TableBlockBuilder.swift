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

        // Build the custom-drawn table: ONE attachment carrying every placed cell. `NSTextTable` is
        // NOT used — `TableAttachmentCell` computes the column x-edges, row heights and border grid
        // itself, so a merged row's seam lands at the exact same x as a single-cell row's (rhwp's
        // shared cumulative-edge model), and the document's own border colour is honoured verbatim.
        let ratios: [CGFloat] = columnPercentages.isEmpty
            ? Array(repeating: 1 / CGFloat(ncol), count: ncol)
            : columnPercentages.map { $0 / 100 }
        var gridCells: [TableGridCell] = []
        gridCells.reserveCapacity(placements.count)
        for placement in placements {
            let header = placement.row < headerRows
            // cell-direct > table-direct > table-STYLE (P5) > theme default — the same chain the old
            // NSTextTable path resolved, now feeding the custom cell (a covered/padding position has
            // no cell value, so it collapses to the theme default border and no shading).
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
            // Padding floored to the reader's comfortable default (a `fo:padding="0cm"` cell reads
            // with room, not cramped) — applied by the geometry as the cell's inner inset, so the
            // NSTextTable-era horizontal-padding-vs-indent dance is gone entirely.
            let padding = max(placement.cell?.padding ?? Self.defaultCellPadding, Self.defaultCellPadding)
            gridCells.append(TableGridCell(
                content: placement.cell?.content ?? NSAttributedString(),
                row: placement.row, col: placement.col,
                rowSpan: placement.rowSpan, colSpan: placement.colSpan,
                background: background, border: TableBorder(color: borderColor, width: borderWidth),
                verticalAlignment: placement.cell?.verticalAlignment ?? .top, padding: padding))
        }
        let minRowHeight = (theme.baseFontSize * theme.codeLineHeightRatio).rounded() + 2 * Self.defaultCellPadding
        let attachment = NSTextAttachment()
        attachment.attachmentCell = TableAttachmentCell(
            cells: gridCells, ncol: ncol, nrow: rows.count, columnRatios: ratios,
            minRowHeight: minRowHeight, initialWidth: Self.initialColumnWidth)
        let out = NSMutableAttributedString(attachment: attachment)
        out.append(NSAttributedString(string: "\n"))
        return out
    }
}

import AppKit

/// ONE reused TextKit stack for measuring AND drawing table-cell content, shared by every cell of
/// every table. Both operations went through `NSAttributedString.boundingRect`/`.draw`, each of which
/// spins up and throws away a fresh layout per call and measured ~O(n²) in character count on rich
/// CJK cell content (a 1000-char cell: 53ms; its first 100 chars: 0.8ms). Reusing one NSLayoutManager
/// — set the string, lay out ONCE, read `usedRect` or `drawGlyphs` — is O(n) and 11× faster on that
/// same cell, which is what makes a big-table document reflow and repaint in tens of ms instead of
/// hundreds. Main-thread only: TextKit is not thread-safe, and every cell measure/draw already runs on
/// the main thread (reflow + view drawing). The stack holds one cell's content at a time; callers use
/// the result immediately, so there is no aliasing across cells.
enum CellText {
    private static let storage = NSTextStorage()
    private static let layout = NSLayoutManager()
    private static let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
    private static let setup: Void = {
        container.lineFragmentPadding = 0
        layout.usesFontLeading = true
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)
    }()

    /// Load one cell's content at a given inner width and lay it out once. Returns the laid-out glyph
    /// range so a caller can draw it without re-laying-out.
    @discardableResult
    private static func loadLaidOut(_ s: NSAttributedString, width: CGFloat) -> NSRange {
        _ = setup
        container.size = NSSize(width: max(1, width), height: CGFloat.greatestFiniteMagnitude)
        storage.setAttributedString(s)
        layout.ensureLayout(for: container)
        return layout.glyphRange(for: container)
    }

    /// Content height at a known inner width — the row-height input the table geometry needs.
    static func height(_ s: NSAttributedString, width: CGFloat) -> CGFloat {
        loadLaidOut(s, width: width)
        return ceil(layout.usedRect(for: container).height)
    }

    /// Draw one cell's content at `origin` (top-left, in the current — flipped — context), reusing the
    /// same O(n) layout the measurement used instead of `NSAttributedString.draw`'s per-call layout.
    static func draw(_ s: NSAttributedString, at origin: NSPoint, width: CGFloat) {
        let gr = loadLaidOut(s, width: width)
        layout.drawBackground(forGlyphRange: gr, at: origin)
        layout.drawGlyphs(forGlyphRange: gr, at: origin)
    }
}

/// One resolved border edge — colour + width. `nil` in an edge grid slot means "no line here".
struct TableBorder: Equatable {
    var color: NSColor
    var width: CGFloat
}

/// One placed cell of a custom-drawn table: its content, grid position/span, and appearance. Covered
/// grid positions (inside another cell's span) simply have NO `TableGridCell` — mirroring the readers'
/// own anchor-only model, so "skip covered cells" is automatic.
struct TableGridCell {
    var content: NSAttributedString
    var row: Int
    var col: Int
    var rowSpan: Int
    var colSpan: Int
    var background: NSColor?
    var border: TableBorder
    var verticalAlignment: CellVAlign
    var padding: CGFloat
}

/// The pure geometry of one table at a given width — every coordinate computed by us, NOT by
/// `NSTextTable`. This is the alignment guarantee: column x-edges are ONE cumulative-sum array every
/// row reads, so a merged row's shared boundary lands at the exact same x as a single-cell row's, by
/// construction (rhwp's `build_row_col_x`). Row heights come from measuring each cell's content;
/// borders resolve into a SHARED edge grid so a seam between two cells is one line, drawn once
/// (rhwp's `collect_cell_borders`/`render_edge_borders`). Split out from the drawing so the geometry
/// is unit-testable without a view.
struct TableGeometry {
    let columnEdges: [CGFloat]        // ncol+1 cumulative x boundaries, columnEdges[0] == 0
    let rowEdges: [CGFloat]           // nrow+1 cumulative y boundaries, rowEdges[0] == 0
    let contentHeights: [CGFloat]     // measured content height per cell, aligned to the cells array
    let hEdges: [[TableBorder?]]      // (nrow+1) × ncol — horizontal seam at [rowBoundary][col]
    let vEdges: [[TableBorder?]]      // (ncol+1) × nrow — vertical seam at [colBoundary][row]
    var size: NSSize { NSSize(width: columnEdges.last ?? 0, height: rowEdges.last ?? 0) }

    /// `measure(cell, innerWidth)` returns the content height for a cell laid at that inner width —
    /// injected so the geometry is testable with a stub while the real cell uses `NSLayoutManager`.
    /// `minRowHeight` floors an empty/zero row so the grid never collapses.
    static func solve(cells: [TableGridCell], ncol: Int, nrow: Int, columnRatios: [CGFloat],
                      width: CGFloat, minRowHeight: CGFloat,
                      measure: (TableGridCell, CGFloat) -> CGFloat) -> TableGeometry {
        // Column x-edges: cumulative sum of ratio*width. ONE array, shared by every row — the last
        // edge forced to exactly `width` so the right border is flush and rounding can't accumulate.
        var colX: [CGFloat] = [0]
        colX.reserveCapacity(ncol + 1)
        for c in 0..<ncol {
            let ratio = c < columnRatios.count ? columnRatios[c] : (1 / CGFloat(max(1, ncol)))
            colX.append(colX[c] + ratio * width)
        }
        if ncol > 0 { colX[ncol] = width }

        func innerWidth(_ cell: TableGridCell) -> CGFloat {
            let ec = min(cell.col + cell.colSpan, ncol)
            return max(1, colX[ec] - colX[cell.col] - 2 * cell.padding)
        }

        // Measure every cell's content once (cached in `heights`, returned for the draw pass).
        var heights = [CGFloat](repeating: 0, count: cells.count)
        for (i, cell) in cells.enumerated() { heights[i] = measure(cell, innerWidth(cell)) }

        // Row heights: a single-row cell sets its row to max(content+padding); a row-spanned cell
        // adds any deficit to the LAST row it covers (rhwp stage 2c) so its content always fits.
        var rowH = [CGFloat](repeating: 0, count: nrow)
        for (i, cell) in cells.enumerated() where cell.rowSpan <= 1 {
            rowH[cell.row] = max(rowH[cell.row], heights[i] + 2 * cell.padding)
        }
        for r in 0..<nrow where rowH[r] <= 0 { rowH[r] = minRowHeight }
        for (i, cell) in cells.enumerated() where cell.rowSpan > 1 {
            let need = heights[i] + 2 * cell.padding
            let end = min(cell.row + cell.rowSpan, nrow)
            let covered = (cell.row..<end).reduce(CGFloat(0)) { $0 + rowH[$1] }
            if need > covered, end > cell.row { rowH[end - 1] += need - covered }
        }
        var rowY: [CGFloat] = [0]
        rowY.reserveCapacity(nrow + 1)
        for r in 0..<nrow { rowY.append(rowY[r] + rowH[r]) }

        // Shared edge grid: each cell writes its 4 borders into the slots its edges cover; two
        // adjacent cells' shared seam collapses into one slot (the wider width wins the merge).
        var hEdges = Array(repeating: Array(repeating: TableBorder?.none, count: max(1, ncol)), count: nrow + 1)
        var vEdges = Array(repeating: Array(repeating: TableBorder?.none, count: nrow), count: ncol + 1)
        func mergePick(_ existing: TableBorder?, _ b: TableBorder) -> TableBorder {
            guard let existing else { return b }
            return b.width > existing.width ? b : existing
        }
        for cell in cells where cell.border.width > 0 {
            let ec = min(cell.col + cell.colSpan, ncol)
            let er = min(cell.row + cell.rowSpan, nrow)
            for c in cell.col..<ec {
                hEdges[cell.row][c] = mergePick(hEdges[cell.row][c], cell.border)   // top
                hEdges[er][c] = mergePick(hEdges[er][c], cell.border)               // bottom
            }
            for r in cell.row..<er {
                vEdges[cell.col][r] = mergePick(vEdges[cell.col][r], cell.border)   // left
                vEdges[ec][r] = mergePick(vEdges[ec][r], cell.border)               // right
            }
        }
        return TableGeometry(columnEdges: colX, rowEdges: rowY, contentHeights: heights,
                             hEdges: hEdges, vEdges: vEdges)
    }
}

/// A table drawn ENTIRELY by us — `NSTextTable` is never used. It sits in the text flow as one
/// attachment (mirroring `SizedAttachmentCell`: owns its own size, so lazy layout can't collapse it),
/// and paints its whole grid — backgrounds, cell content, and borders — from `TableGeometry`'s
/// self-computed coordinates. Because every row reads the SAME column x-edges, a merged row's seam
/// can never drift off a single-cell row's the way `NSTextTable`'s per-row cell packing let it. The
/// document's own border colour is honoured exactly (faint or black); only the ALIGNMENT is ours.
final class TableAttachmentCell: NSTextAttachmentCell {
    let cells: [TableGridCell]
    let ncol: Int
    let nrow: Int
    let columnRatios: [CGFloat]
    let minRowHeight: CGFloat
    private(set) var width: CGFloat = 0
    private var geometry: TableGeometry
    /// The width the current `geometry` was solved at. `relayout` at this same width is a no-op —
    /// re-solving re-measures every cell's whole content (hundreds of ms on a big-table document) for
    /// an identical answer. Reset to force a re-solve only when a cell's media size actually changed.
    private var solvedWidth: CGFloat = -1
    /// The grid rendered ONCE to an image at the current geometry, blitted on every redraw instead of
    /// re-laying-out each cell's content per frame (what made big-table docs crawl on scroll). Dropped
    /// whenever geometry changes (`relayout`).
    private var renderCache: NSImage?

    init(cells: [TableGridCell], ncol: Int, nrow: Int, columnRatios: [CGFloat],
         minRowHeight: CGFloat, initialWidth: CGFloat) {
        self.cells = cells
        self.ncol = max(1, ncol)
        self.nrow = max(1, nrow)
        self.columnRatios = columnRatios
        self.minRowHeight = minRowHeight
        self.geometry = TableGeometry(columnEdges: [0], rowEdges: [0], contentHeights: [],
                                      hEdges: [[]], vEdges: [[]])
        super.init()
        // A CHEAP placeholder geometry: real column edges + borders, but rows at `minRowHeight` with
        // NO content measured (measure returns 0). `cellSize()` is sane before the first real relayout,
        // yet the expensive per-cell layout is not paid here — it would be thrown away, because
        // `presizeKnownMedia` always re-solves at the true column width right after (measured: the
        // placeholder-width solve and the real-width solve were TWO full measurements per open). Leave
        // `solvedWidth` unset so that first real relayout actually measures.
        geometry = TableGeometry.solve(cells: cells, ncol: self.ncol, nrow: self.nrow,
                                       columnRatios: columnRatios, width: initialWidth,
                                       minRowHeight: minRowHeight, measure: { _, _ in 0 })
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// A cell's content height at a known inner width, via the shared reused TextKit stack.
    /// `NSAttributedString.boundingRect` measured ~O(n²) in character count on rich CJK cell content
    /// (a 1000-char legal paragraph: 53ms, vs 0.8ms for its first 100 chars — a 10× length for a 67×
    /// time), because it builds and tears down a throwaway layout every call. One reused NSLayoutManager
    /// laid out once is O(n): the SAME cell measured 4.6ms (11×), turning a 13-table document's reflow
    /// from ~750ms to ~60ms. See `CellText`.
    private func measuredHeight(_ cell: TableGridCell, innerWidth: CGFloat) -> CGFloat {
        CellText.height(cell.content, width: innerWidth)
    }

    /// Recompute geometry for a new reading-column width. Called on first layout and every reflow
    /// (resize / sidebar toggle), the same cadence the old `resizeTableColumns` ran on.
    func relayout(width: CGFloat, force: Bool = false) {
        guard width > 0 else { return }
        // Already solved at this width → reuse it. The per-cell content measurement `solve` does is
        // the whole cost here, and it depends only on the width, so re-solving the same width is pure
        // waste (measured: a redundant relayout cost as much as the first). `force` is for the one
        // caller that changes an input other than width — a cell's media size settling after load.
        if !force && width == solvedWidth { return }
        self.width = width
        solvedWidth = width
        renderCache = nil                          // geometry is moving → the cached render is stale
        geometry = TableGeometry.solve(
            cells: cells, ncol: ncol, nrow: nrow, columnRatios: columnRatios,
            width: width, minRowHeight: minRowHeight,
            measure: { [weak self] cell, iw in self?.measuredHeight(cell, innerWidth: iw) ?? 0 })
    }

    // MARK: Cell-internal media access
    // A table is ONE attachment in the top-level storage; its cells' content never enters that
    // storage, so the document's media passes (presize / prerender / reconcile) can't reach an
    // image or diagram sitting inside a cell. These accessors let those passes descend into the
    // cells — size the medium against the cell it lives in, and paint its pixels when the table is
    // on screen — the same up-front-size-then-lazy-paint discipline top-level media already gets.

    var cellCount: Int { cells.count }
    /// The content string of cell `i`. Its attachments are reference types, so a pass can fill an
    /// image's pixels (`att.image`) or a `SizedAttachmentCell.reservedSize` in place without
    /// replacing the (immutable) string; a size change is picked up by the next `relayout`.
    func cellContent(_ i: Int) -> NSAttributedString { cells[i].content }
    var cellContents: [NSAttributedString] { cells.map { $0.content } }
    /// The inner width cell `i` gets at the CURRENT geometry (its column-span width minus padding) —
    /// what a cell-internal image must be fitted to, mirroring how a top-level image fits the reading
    /// column. Zero before the first `relayout` (no column edges yet).
    func innerWidth(ofCell i: Int) -> CGFloat {
        guard i < cells.count, geometry.columnEdges.count == ncol + 1 else { return 0 }
        let cell = cells[i]
        let ec = min(cell.col + cell.colSpan, ncol)
        return max(1, geometry.columnEdges[ec] - geometry.columnEdges[cell.col] - 2 * cell.padding)
    }

    /// Drop the cached grid image so the next `draw` re-renders it. Called when a cell's media pixels
    /// change (loaded or purged by `reconcileMedia`) — the cache was rendered BEFORE those pixels
    /// existed, so without this the loaded image/diagram inside a cell would never appear (the blit
    /// keeps showing the pixel-less render). Paint-only: it touches no size/geometry (invariant 1).
    func invalidateRenderCache() { renderCache = nil }

    override func cellSize() -> NSSize { geometry.size }
    override func cellBaselineOffset() -> NSPoint { .zero }
    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(origin: .zero, size: geometry.size)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        // Re-laying out every cell's whole content on each redraw is what made big-table documents
        // crawl — ~750ms per redraw for a doc of 13 large cells, paid again on every scroll frame.
        // Render the grid ONCE into an image at the current geometry and blit that thereafter;
        // `relayout` drops the cache when the geometry moves. Falls back to live drawing if the
        // offscreen bitmap can't be made (e.g. a degenerate size).
        let scale = controlView?.window?.backingScaleFactor ?? 2
        if renderCache == nil { renderCache = renderGridImage(scale: scale) }
        if let img = renderCache {
            img.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1,
                     respectFlipped: true, hints: nil)
        } else {
            drawGrid(ox: cellFrame.minX, oy: cellFrame.minY, scale: scale)
        }
    }

    /// Render the whole grid once into an offscreen bitmap at `geometry.size`. Two things must BOTH
    /// hold, and the first was the bug: the drawing context must be y-DOWN (top-left origin, what
    /// `drawGrid` expects) AND must REPORT `isFlipped == true`. The rectangles (backgrounds, borders)
    /// only need the y-down CTM; but the cell CONTENT is drawn with
    /// `NSAttributedString.draw(…usesLineFragmentOrigin)`, which orients glyphs by the context's own
    /// `isFlipped` — so a y-down CTM over an `isFlipped == false` context (the previous version) drew
    /// the boxes right and the TEXT upside-down. The rects-only orientation test never saw it.
    /// `NSGraphicsContext(cgContext:flipped:)` lets us claim the flip WITHOUT lock-focus, which crashes
    /// headless (no window server) — so this stays unit-testable while matching the live flipped view.
    /// `respectFlipped: true` at blit time then places the upright raster correctly. `scale` draws in
    /// points and snaps border seams to the device grid.
    func renderGridImage(scale: CGFloat) -> NSImage? {
        let size = geometry.size
        guard size.width >= 1, size.height >= 1,
              let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)),
                pixelsHigh: Int(ceil(size.height * scale)), bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                bytesPerRow: 0, bitsPerPixel: 0),
              let base = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        rep.size = size
        let cg = base.cgContext
        cg.scaleBy(x: scale, y: scale)                                 // draw in points
        cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)  // top-left origin, y-down
        // Wrap the SAME transformed CGContext in one that reports flipped, so text lays out upright.
        let flipped = NSGraphicsContext(cgContext: cg, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = flipped
        drawGrid(ox: 0, oy: 0, scale: scale)
        NSGraphicsContext.restoreGraphicsState()
        let img = NSImage(size: size)
        img.addRepresentation(rep)
        return img
    }

    /// The grid drawing itself — backgrounds, cell content, borders — at origin (`ox`,`oy`) in a
    /// top-down coordinate space. Pulled out of `draw(withFrame:)` so it renders into the cached
    /// image (and stays available as a live fallback).
    func drawGrid(ox: CGFloat, oy: CGFloat, scale: CGFloat) {
        let colX = geometry.columnEdges, rowY = geometry.rowEdges, heights = geometry.contentHeights
        guard colX.count == ncol + 1, rowY.count == nrow + 1 else { return }

        // Backgrounds + content, so a shaded header's fill sits under its glyphs.
        for (i, cell) in cells.enumerated() {
            let ec = min(cell.col + cell.colSpan, ncol), er = min(cell.row + cell.rowSpan, nrow)
            let x = ox + colX[cell.col], w = colX[ec] - colX[cell.col]
            let y = oy + rowY[cell.row], h = rowY[er] - rowY[cell.row]
            if let bg = cell.background {
                bg.setFill(); NSRect(x: x, y: y, width: w, height: h).fill()
            }
            let innerW = max(1, w - 2 * cell.padding)
            let contentH = i < heights.count ? heights[i] : h
            let availH = h - 2 * cell.padding
            let dy: CGFloat
            switch cell.verticalAlignment {
            case .top: dy = 0
            case .center: dy = max(0, availH - contentH) / 2
            case .bottom: dy = max(0, availH - contentH)
            }
            CellText.draw(cell.content, at: NSPoint(x: x + cell.padding, y: y + cell.padding + dy),
                          width: innerW)
        }

        // Borders: each shared seam once, snapped to the device pixel grid so a thin line is crisp.
        func snap(_ v: CGFloat) -> CGFloat { (v * scale).rounded() / scale }
        for row in 0...nrow {
            for col in 0..<ncol {
                guard let b = geometry.hEdges[row][col] else { continue }
                b.color.setFill()
                NSRect(x: ox + colX[col], y: snap(oy + rowY[row]) - b.width / 2,
                       width: colX[col + 1] - colX[col], height: b.width).fill()
            }
        }
        for col in 0...ncol {
            for row in 0..<nrow {
                guard let b = geometry.vEdges[col][row] else { continue }
                b.color.setFill()
                NSRect(x: snap(ox + colX[col]) - b.width / 2, y: oy + rowY[row],
                       width: b.width, height: rowY[row + 1] - rowY[row]).fill()
            }
        }
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?,
                       characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}

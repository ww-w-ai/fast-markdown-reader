import XCTest
import AppKit
@testable import FastDocReader

/// Regression guard for the column-seam alignment fix (rhwp-informed): a merged row's shared column
/// boundary must land at the SAME x as a single-cell row's, so vertical grid lines never jag row to
/// row. The bug this pins: `NSTextTable` places a cell boundary at cumulative
/// (contentWidth + padding + border), so a `gridSpan` row (fewer cells → less total horizontal
/// padding) had `NSTextTable` redistribute the mismatch and float the shared seam — measured 28pt of
/// drift, plus 14pt WITHIN the merged row. The fix zeroes each cell's HORIZONTAL block padding (inset
/// moves to a paragraph indent), so every seam is a pure cumulative content-width sum, identical for
/// every row — rhwp's edge model, reached without leaving `NSTextTable`. Reintroducing horizontal
/// block padding brings the drift back and fails this test.
final class TableGridDriftProbeTests: XCTestCase {

    private func makeStack(columnWidth: CGFloat) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: columnWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        return (storage, layout, container)
    }

    private func cell(_ s: String, span: Int = 1) -> TableBlockBuilder.CellContent {
        var c = TableBlockBuilder.CellContent(
            content: NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 13)]))
        c.columnSpan = span
        return c
    }

    /// One rect per laid-out cell, reading order, via the SAME query the app uses to place a block.
    private func cellRects(_ storage: NSTextStorage, _ layout: NSLayoutManager) -> [NSRect] {
        layout.ensureLayout(for: layout.textContainers[0])
        var rects: [NSRect] = []
        storage.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: storage.length)) { val, range, _ in
            guard let ps = val as? NSParagraphStyle, let block = ps.textBlocks.first else { return }
            let g = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard g.length > 0 else { return }
            rects.append(layout.layoutRect(for: block, at: g.location, effectiveRange: nil))
        }
        return rects
    }

    /// A uniform 4-column grid: row 0 = four single cells, row 1 = [span-3, single]. The col2|col3
    /// seam exists in BOTH rows (row 0: right edge of cell 2; row 1: right edge of the span-3 cell,
    /// which is also the left edge of the trailing single). All three must coincide.
    func testMergedRowColumnSeamAlignsWithSingleCellRow() {
        let rows: [[TableBlockBuilder.CellContent]] = [
            [cell("a"), cell("b"), cell("c"), cell("d")],
            [cell("wide", span: 3), cell("e")],
        ]
        let table = TableBlockBuilder.build(rows: rows, headerRows: 0, theme: RenderTheme.current(size: 16),
                                            columnWidths: [1, 1, 1, 1])
        let (storage, layout, _) = makeStack(columnWidth: 800)
        storage.setAttributedString(table)
        let r = cellRects(storage, layout)
        XCTAssertEqual(r.count, 6, "reading order: r[0..3]=row0 cells, r[4]=span-3, r[5]=trailing single")
        let row0Seam = r[2].maxX          // col2|col3 boundary in the single-cell row
        let spanRightEdge = r[4].maxX      // same boundary, from the span-3 cell
        let trailingLeftEdge = r[5].minX    // same boundary, from the trailing single cell
        XCTAssertEqual(spanRightEdge, row0Seam, accuracy: 0.5,
                       "merged row's shared seam drifted off the single-cell row's (horizontal padding back?)")
        XCTAssertEqual(trailingLeftEdge, row0Seam, accuracy: 0.5,
                       "the seam is drawn at two x's WITHIN the merged row")
    }
}

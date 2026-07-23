import XCTest
import AppKit
@testable import FastDocReader

/// The custom table engine's geometry — the whole reason it exists is that a merged row's column
/// seam lands at the EXACT same x as a single-cell row's, because both read one shared cumulative
/// x-edge array. These tests pin that (and row-height measurement + the shared border edge grid)
/// without a view, using a stub content measurer.
final class TableGeometryTests: XCTestCase {
    private func cell(_ text: String, row: Int, col: Int, rowSpan: Int = 1, colSpan: Int = 1,
                      border: CGFloat = 1, pad: CGFloat = 0, bw: CGFloat = 1) -> TableGridCell {
        TableGridCell(content: NSAttributedString(string: text), row: row, col: col,
                      rowSpan: rowSpan, colSpan: colSpan, background: nil,
                      border: TableBorder(color: .black, width: bw), verticalAlignment: .top, padding: pad)
    }

    /// Column x-edges are one shared cumulative array: 4 equal columns at width 800 → 0,200,400,600,800,
    /// and the last edge is forced to exactly the table width.
    func testColumnEdgesAreOneSharedCumulativeArray() {
        let cells = [cell("a", row: 0, col: 0), cell("b", row: 0, col: 1),
                     cell("c", row: 0, col: 2), cell("d", row: 0, col: 3)]
        let g = TableGeometry.solve(cells: cells, ncol: 4, nrow: 1, columnRatios: [0.25, 0.25, 0.25, 0.25],
                                    width: 800, minRowHeight: 20, measure: { _, _ in 10 })
        XCTAssertEqual(g.columnEdges, [0, 200, 400, 600, 800])
    }

    /// The alignment guarantee: a `gridSpan=3` row's shared boundary (its right edge, and the trailing
    /// single cell's left edge) is the SAME x as the col2|col3 seam in a row of four single cells —
    /// because both come from `columnEdges[3]`, not per-row cell packing.
    func testMergedRowSeamAlignsWithSingleCellRow() {
        let cells = [
            cell("a", row: 0, col: 0), cell("b", row: 0, col: 1), cell("c", row: 0, col: 2), cell("d", row: 0, col: 3),
            cell("wide", row: 1, col: 0, colSpan: 3), cell("e", row: 1, col: 3),
        ]
        let g = TableGeometry.solve(cells: cells, ncol: 4, nrow: 2, columnRatios: [0.25, 0.25, 0.25, 0.25],
                                    width: 800, minRowHeight: 20, measure: { _, _ in 10 })
        // col2|col3 seam is columnEdges[3] == 600, shared by BOTH rows.
        XCTAssertEqual(g.columnEdges[3], 600)
        // row0 cell2 right edge, row1 span-3 right edge, row1 single left edge all == 600.
        XCTAssertEqual(g.columnEdges[2] + (g.columnEdges[3] - g.columnEdges[2]), 600)  // cell2 right
        XCTAssertEqual(g.columnEdges[0] + (g.columnEdges[3] - g.columnEdges[0]), 600)  // span-3 right
        XCTAssertEqual(g.columnEdges[3], 600)                                          // single left
    }

    /// Row height = max content height of its cells + padding; a taller cell sets its whole row.
    func testRowHeightIsMaxContentPlusPadding() {
        let cells = [cell("short", row: 0, col: 0, pad: 5), cell("tall", row: 0, col: 1, pad: 5)]
        let g = TableGeometry.solve(cells: cells, ncol: 2, nrow: 1, columnRatios: [0.5, 0.5],
                                    width: 400, minRowHeight: 10,
                                    measure: { c, _ in c.content.string == "tall" ? 40 : 12 })
        // taller cell: 40 + 2*5 padding = 50
        XCTAssertEqual(g.rowEdges, [0, 50])
    }

    /// A row-spanned cell whose content is taller than the rows it covers pushes the deficit onto the
    /// LAST covered row, so its content always fits (rhwp stage 2c).
    func testRowSpanDeficitGoesToLastCoveredRow() {
        let cells = [
            cell("tall", row: 0, col: 0, rowSpan: 2), cell("r0", row: 0, col: 1),
            cell("r1", row: 1, col: 1),
        ]
        let g = TableGeometry.solve(cells: cells, ncol: 2, nrow: 2, columnRatios: [0.5, 0.5],
                                    width: 400, minRowHeight: 10,
                                    measure: { c, _ in c.content.string == "tall" ? 50 : 10 })
        // rows start at 10 each (=20 covered); tall needs 50 → deficit 30 added to last covered row (row1).
        XCTAssertEqual(g.rowEdges, [0, 10, 50])
    }

    /// A vertical seam shared by two adjacent cells is ONE slot (drawn once), and the wider border
    /// wins the merge.
    func testSharedVerticalSeamStoredOnceWiderWins() {
        let cells = [cell("a", row: 0, col: 0, bw: 1), cell("b", row: 0, col: 1, bw: 3)]
        let g = TableGeometry.solve(cells: cells, ncol: 2, nrow: 1, columnRatios: [0.5, 0.5],
                                    width: 400, minRowHeight: 10, measure: { _, _ in 10 })
        // The middle seam vEdges[1][0] is written by cell a's RIGHT and cell b's LEFT — one slot,
        // wider (3) wins.
        XCTAssertEqual(g.vEdges[1][0]?.width, 3)
        // Outer edges present, single width.
        XCTAssertEqual(g.vEdges[0][0]?.width, 1)
        XCTAssertEqual(g.vEdges[2][0]?.width, 3)
    }
}

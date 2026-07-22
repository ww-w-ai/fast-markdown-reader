import XCTest
import AppKit
@testable import FastDocReader

/// A table's cells are drawn from separate `NSAttributedString`s the document's top-level media
/// passes never see, so an image or diagram INSIDE a cell would render blank (its pixels never
/// filled) and, worse, its row would be the wrong height. The fix reserves each cell medium's area
/// up front and re-solves the table's geometry. These pin the property everything else rests on:
/// the table's REAL height measurement (boundingRect over each cell's own string) sees a cell
/// attachment's reserved size, so a cell image sizes its row before a single pixel loads — and the
/// small accessors the document's cell-descent passes call are correct.
final class TableCellMediaTests: XCTestCase {
    private func imageCell(reserved: NSSize, row: Int = 0, col: Int = 0, padding: CGFloat = 7)
        -> (TableGridCell, SizedAttachmentCell) {
        let cell = SizedAttachmentCell(reservedSize: reserved)
        let att = NSTextAttachment()
        att.bounds = NSRect(origin: .zero, size: reserved)
        att.attachmentCell = cell
        let grid = TableGridCell(content: NSAttributedString(attachment: att), row: row, col: col,
                                 rowSpan: 1, colSpan: 1, background: nil,
                                 border: TableBorder(color: .black, width: 1),
                                 verticalAlignment: .top, padding: padding)
        return (grid, cell)
    }

    /// A cell holding an image that reserves 200×120 must make a table at least 120 + 2*padding tall.
    /// This is the whole point: the reserved size (owned by `SizedAttachmentCell`, present even when
    /// `image == nil`) flows through the table's own `measuredHeight` into the row height, so the
    /// table is the right size before its cell pixels ever load.
    func testCellImageReservedSizeDrivesRowHeight() {
        let (grid, _) = imageCell(reserved: NSSize(width: 200, height: 120), padding: 7)
        let table = TableAttachmentCell(cells: [grid], ncol: 1, nrow: 1, columnRatios: [1],
                                        minRowHeight: 20, initialWidth: 400)
        XCTAssertGreaterThanOrEqual(table.cellSize().height, 120 + 2 * 7)
    }

    /// The sizing pass sets a cell image's reserved size then calls `relayout` — the table height
    /// has to grow to follow, or a taller image would be clipped.
    func testRelayoutPicksUpNewCellReservedSize() {
        let (grid, cell) = imageCell(reserved: NSSize(width: 100, height: 40), padding: 5)
        let table = TableAttachmentCell(cells: [grid], ncol: 1, nrow: 1, columnRatios: [1],
                                        minRowHeight: 10, initialWidth: 300)
        let before = table.cellSize().height
        cell.reservedSize = NSSize(width: 100, height: 220)   // the pass reserves a bigger area
        table.relayout(width: 300)
        XCTAssertGreaterThan(table.cellSize().height, before)
        XCTAssertGreaterThanOrEqual(table.cellSize().height, 220)
    }

    /// A formula (an office equation lands as an `MDAttr.math` web block, `appendFormula`) sitting
    /// inside a table cell must be reachable through `cellContents` + `enumerateWebBlocks` — that is
    /// exactly how `prerenderAllDiagrams`/`sizeTableCellMedia`/`reconcileMedia` descend into cells to
    /// cache, size and paint it. If this can't find it, an in-cell equation renders blank.
    func testCellWebBlockIsReachableForTheMediaPasses() {
        let att = NSTextAttachment()
        att.attachmentCell = SizedAttachmentCell(reservedSize: NSSize(width: 260, height: 60))
        let content = NSMutableAttributedString(attachment: att)
        content.addAttribute(MDAttr.math, value: "E = mc^2", range: NSRange(location: 0, length: content.length))
        let grid = TableGridCell(content: content, row: 0, col: 0, rowSpan: 1, colSpan: 1, background: nil,
                                 border: TableBorder(color: .black, width: 1), verticalAlignment: .top, padding: 7)
        let table = TableAttachmentCell(cells: [grid], ncol: 1, nrow: 1, columnRatios: [1],
                                        minRowHeight: 20, initialWidth: 400)
        var found: [WebBlock] = []
        for c in table.cellContents { c.enumerateWebBlocks { block, _ in found.append(block) } }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.engine, .math)
        XCTAssertEqual(found.first?.code, "E = mc^2")
    }

    /// The accessors the document's cell-descent passes rely on: cell count, each cell's content
    /// string (so a pass can enumerate its media), and a positive inner width to fit that media to.
    func testCellAccessorsExposeContentAndInnerWidth() {
        let (a, _) = imageCell(reserved: NSSize(width: 50, height: 50), row: 0, col: 0)
        let (b, _) = imageCell(reserved: NSSize(width: 50, height: 50), row: 0, col: 1)
        let table = TableAttachmentCell(cells: [a, b], ncol: 2, nrow: 1, columnRatios: [0.5, 0.5],
                                        minRowHeight: 20, initialWidth: 400)
        XCTAssertEqual(table.cellCount, 2)
        XCTAssertEqual(table.cellContent(0).length, 1)
        XCTAssertEqual(table.cellContents.count, 2)
        // Two equal columns of a 400-usable table, minus 2*7 padding, is well above zero.
        XCTAssertGreaterThan(table.innerWidth(ofCell: 0), 0)
        XCTAssertLessThan(table.innerWidth(ofCell: 0), 200)   // one cell, not the whole table
    }
}

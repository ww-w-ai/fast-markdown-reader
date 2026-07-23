import XCTest
import AppKit
@testable import FastDocReader

/// The table draw path caches the grid as an image (rendered once, blitted per frame) instead of
/// re-laying-out every cell's content on each redraw — the fix for big-table documents crawling. The
/// cache is produced by a flipped offscreen render, so the one thing that could go wrong is
/// ORIENTATION: the stored image must be UPRIGHT (row 0 at the top), because `draw(withFrame:)` blits
/// it with `respectFlipped: true` into the flipped `ReaderTextView`, where an upright image lands
/// upright. This builds a table whose top row is red and bottom row is blue and asserts the cached
/// image really is red-on-top — a vertical-flip bug (the easy mistake with the double coordinate
/// system) would put blue on top and fail here instead of on screen.
final class TableRenderCacheTests: XCTestCase {
    private func redTopBlueBottomTable() -> TableAttachmentCell {
        func cell(_ s: String, row: Int, bg: NSColor) -> TableGridCell {
            TableGridCell(content: NSAttributedString(string: s, attributes: [.foregroundColor: NSColor.black]),
                          row: row, col: 0, rowSpan: 1, colSpan: 1, background: bg,
                          border: TableBorder(color: .black, width: 1), verticalAlignment: .top, padding: 4)
        }
        let t = TableAttachmentCell(cells: [cell("TOP", row: 0, bg: .red), cell("BOTTOM", row: 1, bg: .blue)],
                                    ncol: 1, nrow: 2, columnRatios: [1], minRowHeight: 30, initialWidth: 120)
        t.relayout(width: 120)
        return t
    }

    func testCachedImageIsUpright_redRowOnTop() throws {
        let table = redTopBlueBottomTable()
        guard let img = table.renderGridImage(scale: 2),
              let rep = img.representations.first as? NSBitmapImageRep
        else { throw XCTSkip("offscreen bitmap unavailable in this environment") }

        // Sample the vertical centre column, near the top eighth and the bottom eighth.
        let cx = rep.pixelsWide / 2
        func colorish(_ y: Int) -> (r: Int, g: Int, b: Int) {
            let c = rep.colorAt(x: cx, y: y) ?? .black
            return (Int(c.redComponent * 255), Int(c.greenComponent * 255), Int(c.blueComponent * 255))
        }
        let top = colorish(rep.pixelsHigh / 8)
        let bottom = colorish(rep.pixelsHigh * 7 / 8)

        // Top must read red (r dominant), bottom must read blue (b dominant). A vertical flip swaps them.
        XCTAssertTrue(top.r > top.b + 40, "top of the cached table should be RED, got \(top) — vertical flip?")
        XCTAssertTrue(bottom.b > bottom.r + 40, "bottom of the cached table should be BLUE, got \(bottom) — vertical flip?")
    }
}

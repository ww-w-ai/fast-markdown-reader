import XCTest
@testable import FastMDReader

/// BlockEdit is pure source arithmetic, so it can be tested without a window: build the spans by
/// hand, apply the returned (range, replacement), and assert on the resulting FILE text — which is
/// exactly what `applySourceEdit` writes to disk.
final class BlockEditTests: XCTestCase {
    /// "# A\n\nB\n\nC" — three markdown blocks separated by blank lines.
    private let md = "# A\n\nB\n\nC"
    private var mdSpans: [NSRange] {
        [NSRange(location: 0, length: 3), NSRange(location: 5, length: 1), NSRange(location: 8, length: 1)]
    }

    private func apply(_ text: String, _ edit: (NSRange, String)?) -> String? {
        guard let edit else { return nil }
        return (text as NSString).replacingCharacters(in: edit.0, with: edit.1)
    }

    // MARK: Move

    func testSwapMovesBlockDownAndKeepsSeparators() {
        let out = apply(md, BlockEdit.swapWithNext(0, spans: mdSpans, text: md as NSString))
        XCTAssertEqual(out, "B\n\n# A\n\nC")
    }

    func testSwapIsLengthPreserving() {
        let out = apply(md, BlockEdit.swapWithNext(1, spans: mdSpans, text: md as NSString))
        XCTAssertEqual(out, "# A\n\nC\n\nB")
        XCTAssertEqual(out?.count, md.count, "a swap must not change the file's length")
    }

    func testSwapPastTheEndIsRefused() {
        XCTAssertNil(BlockEdit.swapWithNext(2, spans: mdSpans, text: md as NSString))
        XCTAssertNil(BlockEdit.swapWithNext(-1, spans: mdSpans, text: md as NSString))
    }

    // MARK: Delete

    func testDeleteTakesTheFollowingSeparator() {
        let r = BlockEdit.deletion(of: 0, spans: mdSpans)
        XCTAssertEqual(apply(md, r.map { ($0, "") }), "B\n\nC")
    }

    func testDeleteLastBlockTakesThePrecedingSeparator() {
        let r = BlockEdit.deletion(of: 2, spans: mdSpans)
        XCTAssertEqual(apply(md, r.map { ($0, "") }), "# A\n\nB", "must not leave a trailing blank line")
    }

    func testDeleteOnlyBlockEmptiesTheFile() {
        let one = "solo"
        let spans = [NSRange(location: 0, length: 4)]
        XCTAssertEqual(apply(one, BlockEdit.deletion(of: 0, spans: spans).map { ($0, "") }), "")
    }

    // MARK: Insert

    func testInsertReusesTheDocumentsOwnSeparator() {
        let out = apply(md, BlockEdit.insertion(after: 0, spans: mdSpans, text: md as NSString,
                                                newSource: "NEW", fallbackSeparator: "\n\n"))
        XCTAssertEqual(out, "# A\n\nNEW\n\nB\n\nC")
    }

    /// A plain text file separates lines with ONE newline; inserting must not invent a blank line.
    func testInsertIntoSingleNewlineTextKeepsSingleNewline() {
        let csv = "a,1\nb,2\nc,3"
        let spans = [NSRange(location: 0, length: 3), NSRange(location: 4, length: 3),
                     NSRange(location: 8, length: 3)]
        let out = apply(csv, BlockEdit.insertion(after: 1, spans: spans, text: csv as NSString,
                                                 newSource: "x,9", fallbackSeparator: "\n"))
        XCTAssertEqual(out, "a,1\nb,2\nx,9\nc,3")
    }

    func testInsertAfterLastBlockUsesThePrecedingSeparator() {
        let out = apply(md, BlockEdit.insertion(after: 2, spans: mdSpans, text: md as NSString,
                                                newSource: "D", fallbackSeparator: "\n\n"))
        XCTAssertEqual(out, "# A\n\nB\n\nC\n\nD")
    }

    /// A single-block file has no gap to copy, so the caller's fallback decides.
    func testSeparatorFallsBackWhenThereIsNoGapToCopy() {
        let one = "solo"
        let spans = [NSRange(location: 0, length: 4)]
        XCTAssertEqual(BlockEdit.separator(around: 0, spans: spans, text: one as NSString, fallback: "\n"), "\n")
    }

    // MARK: Lookup

    func testIndexOfBlockFindsTheContainingBlock() {
        XCTAssertEqual(BlockEdit.indexOfBlock(containing: 5, in: mdSpans), 1)
        XCTAssertEqual(BlockEdit.indexOfBlock(containing: 8, in: mdSpans), 2)
    }

    /// An offset in the gap between blocks belongs to the block above it, not to nothing.
    func testIndexOfBlockInAGapPicksTheBlockAbove() {
        XCTAssertEqual(BlockEdit.indexOfBlock(containing: 4, in: mdSpans), 0)
    }

    // MARK: Spans from rendered text

    func testSpansCollapseRunsAndComeOutInSourceOrder() {
        let s = NSMutableAttributedString(string: "AAABB")
        s.addAttribute(MDAttr.srcRange, value: NSValue(range: NSRange(location: 10, length: 2)),
                       range: NSRange(location: 0, length: 3))
        s.addAttribute(MDAttr.srcRange, value: NSValue(range: NSRange(location: 0, length: 4)),
                       range: NSRange(location: 3, length: 2))
        let spans = BlockEdit.spans(in: s)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[0].location, 0)
        XCTAssertEqual(spans[1].location, 10)
    }
}

final class PlainTextRendererTests: XCTestCase {
    func testRendersVerbatimWithoutParsingMarkdown() {
        let src = "# not a heading\n*not italic*"
        let out = PlainTextRenderer.render(src, theme: .current(size: 16))
        XCTAssertEqual(out.string, src, "a text file must reach the screen character for character")
    }

    func testEachNonBlankLineIsOneBlock() {
        let src = "a,1\n\nb,2"
        let out = PlainTextRenderer.render(src, theme: .current(size: 16))
        let spans = BlockEdit.spans(in: out)
        XCTAssertEqual(spans.count, 2, "the blank line is a separator, not a block")
        XCTAssertEqual((src as NSString).substring(with: spans[0]), "a,1")
        XCTAssertEqual((src as NSString).substring(with: spans[1]), "b,2")
    }

    func testTrailingNewlineDoesNotAddAnEmptyBlock() {
        let out = PlainTextRenderer.render("only\n", theme: .current(size: 16))
        XCTAssertEqual(BlockEdit.spans(in: out).count, 1)
        XCTAssertEqual(out.string, "only\n")
    }
}

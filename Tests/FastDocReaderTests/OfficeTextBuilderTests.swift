import XCTest
import AppKit
@testable import FastDocReader

final class OfficeTextBuilderTests: XCTestCase {
    private let theme = RenderTheme.current(size: 16)

    private func span(_ text: String, bold: Bool = false, italic: Bool = false,
                       underline: Bool = false, code: Bool = false) -> Span {
        Span(text: text, bold: bold, italic: italic, underline: underline, code: code)
    }

    private func build(_ blocks: [OfficeBlock]) -> NSAttributedString {
        OfficeTextBuilder.build(blocks, theme: theme)
    }

    /// One marker string ("1.", "2.", "•", …) per list-item block, read up to its first tab, in
    /// document order — enumerated the same way the reading cursor / gutter click would.
    private func listMarkers(in out: NSAttributedString) -> [String] {
        var markers: [String] = []
        out.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard value is Int else { return }
            let line = out.attributedSubstring(from: range).string
            guard let tab = line.firstIndex(of: "\t") else { return }
            markers.append(String(line[line.startIndex..<tab]))
        }
        return markers
    }

    // MARK: Empty input

    func testEmptyBlockArrayReturnsEmptyAttributedStringWithoutCrashing() {
        let out = build([])
        XCTAssertEqual(out.length, 0)
        XCTAssertEqual(out.string, "")
    }

    // MARK: Block ids

    /// Every top-level block — regardless of kind — is exactly one navigation stop with a
    /// distinct, 0-based, monotonically increasing id over a non-empty range. A zero-length tag
    /// would be invisible to the reading cursor and gutter click (invariant carried over from
    /// `MarkdownRenderer`/`PlainTextRenderer`).
    func testEachBlockGetsADistinctMonotonicBlockIdOverANonEmptyRange() {
        let blocks: [OfficeBlock] = [
            .heading(level: 1, spans: [span("Title")]),
            .paragraph(spans: [span("Body")]),
            .listItem(level: 0, ordered: false, spans: [span("Item")]),
            .table(rows: [[Cell(spans: [span("A")]), Cell(spans: [span("B")])]], headerRows: 0),
            .image(id: "img1", size: CGSize(width: 100, height: 80)),
        ]
        let out = build(blocks)
        var ids: [Int] = []
        out.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let id = value as? Int else { return }
            XCTAssertGreaterThan(range.length, 0, "block \(id) has a zero-length tag")
            ids.append(id)
        }
        XCTAssertEqual(ids, Array(0..<blocks.count), "ids must be 0-based, distinct and in document order")
    }

    /// A block with no spans at all (an empty paragraph) still renders SOMETHING (its separator),
    /// so it still gets a non-empty, distinct id — it must not be silently dropped from navigation.
    func testABlockWithNoSpansStillGetsItsOwnNonEmptyBlockId() {
        let out = build([.paragraph(spans: []), .paragraph(spans: [span("next")])])
        var ids: [Int] = []
        out.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard let id = value as? Int else { return }
            XCTAssertGreaterThan(range.length, 0)
            ids.append(id)
        }
        XCTAssertEqual(ids, [0, 1])
    }

    // MARK: Heading outline (what OutlinePanel.reload does)

    func testHeadingAttributeEnumeratesLevelsInDocumentOrder() {
        let blocks: [OfficeBlock] = [
            .heading(level: 1, spans: [span("One")]),
            .paragraph(spans: [span("body text")]),
            .heading(level: 3, spans: [span("Three")]),
            .heading(level: 2, spans: [span("Two")]),
        ]
        let out = build(blocks)
        var levels: [Int] = []
        out.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            guard let level = value as? Int else { return }
            levels.append(level)
        }
        XCTAssertEqual(levels, [1, 3, 2])
    }

    /// `OutlinePanel.reload` trims the tagged range and shows it as the entry title — the heading
    /// range must be exactly the heading's own text, not swallow the paragraph after it.
    func testHeadingRangeCoversOnlyItsOwnText() {
        let out = build([.heading(level: 2, spans: [span("Section")]), .paragraph(spans: [span("prose")])])
        var title: String?
        out.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard value != nil else { return }
            title = out.attributedSubstring(from: range).string.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        XCTAssertEqual(title, "Section")
    }

    // MARK: Fonts

    func testHeadingLevel1UsesThemeHeadingFont() {
        let out = build([.heading(level: 1, spans: [span("Title")])])
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, theme.headingFont(level: 1).pointSize)
    }

    func testParagraphUsesThemeBodyFont() {
        let out = build([.paragraph(spans: [span("hello")])])
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, theme.bodyFont.pointSize)
        XCTAssertFalse(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    // MARK: Spans

    /// Bold must land on exactly the bold span's characters — not bleed into its neighbours.
    func testBoldAppliesOnlyToTheBoldSpansRange() {
        let out = build([.paragraph(spans: [span("plain "), span("bold", bold: true), span(" tail")])])
        let text = out.string as NSString
        let boldRange = text.range(of: "bold")
        let plainFont = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let boldFont = out.attribute(.font, at: boldRange.location, effectiveRange: nil) as? NSFont
        let tailFont = out.attribute(.font, at: boldRange.location + boldRange.length, effectiveRange: nil) as? NSFont
        XCTAssertFalse(plainFont!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertTrue(boldFont!.fontDescriptor.symbolicTraits.contains(.bold))
        XCTAssertFalse(tailFont!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testItalicAndUnderlineAreIndependentOfBold() {
        let out = build([.paragraph(spans: [span("slanted", italic: true), span("lined", underline: true)])])
        let text = out.string as NSString
        let italicRange = text.range(of: "slanted")
        let underlineRange = text.range(of: "lined")
        let italicFont = out.attribute(.font, at: italicRange.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(italicFont!.fontDescriptor.symbolicTraits.contains(.italic))
        XCTAssertFalse(italicFont!.fontDescriptor.symbolicTraits.contains(.bold))
        let underlineValue = out.attribute(.underlineStyle, at: underlineRange.location, effectiveRange: nil) as? Int
        XCTAssertEqual(underlineValue, NSUnderlineStyle.single.rawValue)
    }

    /// `code` overrides font/color to the theme's inline-code styling and tags `MDAttr.inlineCode`
    /// — same contract `MarkdownRenderer` uses for the layout manager's chip background.
    func testCodeSpanUsesInlineCodeStylingAndIsTagged() {
        let out = build([.paragraph(spans: [span("snippet", code: true)])])
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let color = out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(font?.pointSize, theme.codeFont.pointSize)
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.monoSpace))
        XCTAssertEqual(color, theme.inlineCodeColor)
        XCTAssertNotNil(out.attribute(MDAttr.inlineCode, at: 0, effectiveRange: nil))
    }

    /// `spansAttributedString` must stay reachable from other files in this module — a later
    /// sprint's RTF reader re-themes spans it parsed itself, not `OfficeBlock`s. This call is the
    /// regression guard: it fails to COMPILE if the method goes back to `private`.
    func testSpansAttributedStringIsCallableFromOutsideThisType() {
        let out = OfficeTextBuilder.spansAttributedString([span("hi", bold: true)], baseFont: theme.bodyFont,
                                                           baseColor: theme.textColor, theme: theme)
        XCTAssertEqual(out.string, "hi")
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font!.fontDescriptor.symbolicTraits.contains(.bold))
    }

    // MARK: Lists — indent

    func testNestedListIndentIncreasesStrictlyWithLevel() {
        let blocks: [OfficeBlock] = [
            .listItem(level: 0, ordered: true, spans: [span("top")]),
            .listItem(level: 1, ordered: true, spans: [span("nested")]),
            .listItem(level: 2, ordered: true, spans: [span("deeper")]),
        ]
        let out = build(blocks)
        var indents: [CGFloat] = []
        out.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: out.length)) { value, range, _ in
            guard value is Int else { return }
            let ps = out.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            indents.append(ps!.headIndent)
        }
        XCTAssertEqual(indents.count, 3)
        XCTAssertLessThan(indents[0], indents[1])
        XCTAssertLessThan(indents[1], indents[2])
    }

    // MARK: Lists — ordered numbering restart

    /// The brief's required case: after a deeper nested run, the OUTER level's numbering must
    /// still come out correct — i.e. it keeps counting (1, 2), not reset by the nested items.
    func testOrderedNumberingAfterADeeperLevelContinuesTheOuterCount() {
        let blocks: [OfficeBlock] = [
            .listItem(level: 0, ordered: true, spans: [span("a")]),
            .listItem(level: 1, ordered: true, spans: [span("a-1")]),
            .listItem(level: 1, ordered: true, spans: [span("a-2")]),
            .listItem(level: 0, ordered: true, spans: [span("b")]),
        ]
        XCTAssertEqual(listMarkers(in: build(blocks)), ["1.", "1.", "2.", "2."])
    }

    /// A SHALLOWER level intervening breaks the deeper level's run: level 1 must restart at "1."
    /// once a level-0 item has appeared in between.
    func testOrderedNumberingRestartsAfterAShallowerLevelIntervenes() {
        let blocks: [OfficeBlock] = [
            .listItem(level: 1, ordered: true, spans: [span("x-1")]),
            .listItem(level: 1, ordered: true, spans: [span("x-2")]),
            .listItem(level: 0, ordered: true, spans: [span("shallow")]),
            .listItem(level: 1, ordered: true, spans: [span("y-1")]),
        ]
        XCTAssertEqual(listMarkers(in: build(blocks)), ["1.", "2.", "1.", "1."])
    }

    /// An unordered item breaks an ordered run at the SAME level too.
    func testOrderedNumberingRestartsAfterABulletAtTheSameLevel() {
        let blocks: [OfficeBlock] = [
            .listItem(level: 0, ordered: true, spans: [span("one")]),
            .listItem(level: 0, ordered: false, spans: [span("bullet")]),
            .listItem(level: 0, ordered: true, spans: [span("restarted")]),
        ]
        XCTAssertEqual(listMarkers(in: build(blocks)), ["1.", "•", "1."])
    }

    func testUnorderedListUsesABulletNotANumber() {
        let out = build([.listItem(level: 0, ordered: false, spans: [span("item")])])
        XCTAssertEqual(listMarkers(in: out), ["•"])
    }

    // MARK: Tables

    /// Every `NSTextTableBlock` in `out`, in the order TextKit reports them, via the same
    /// paragraph-style enumeration `MarkdownRendererTests` uses to characterize markdown tables —
    /// office tables now go through the identical `TableBlockBuilder`, so they're inspected the
    /// same way.
    private func tableBlocks(in out: NSAttributedString) -> [NSTextTableBlock] {
        var blocks: [NSTextTableBlock] = []
        out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            guard let ps = value as? NSParagraphStyle else { return }
            for tb in ps.textBlocks {
                if let block = tb as? NSTextTableBlock { blocks.append(block) }
            }
        }
        return blocks
    }

    /// A 2x2 table where one cell is empty must keep both rows at the same column count — the
    /// empty cell still occupies its `NSTextTableBlock`, it doesn't collapse the row or shift the
    /// remaining column. `headerRows: 1` is today's asserted shape behaviour, kept as-is.
    func testTableWithHeaderRowAndAnEmptyCellKeepsItsRowAndColumnShape() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("Name")]), Cell(spans: [span("Score")])],
            [Cell(spans: []), Cell(spans: [span("42")])],
        ]
        let out = build([.table(rows: rows, headerRows: 1)])
        let blocks = tableBlocks(in: out)
        XCTAssertEqual(blocks.count, 4, "2 header cells + 2 body cells, empty cell included")
        let bodyRowCols = Set(blocks.filter { $0.startingRow == 1 }.map(\.startingColumn))
        XCTAssertEqual(bodyRowCols, [0, 1], "the empty first cell must still keep its column in place")
    }

    /// Same shape guarantee with NO header row at all — a headerless table (the common case in the
    /// real contract test set) must not collapse a column just because row 0 isn't styled.
    func testTableWithNoHeaderAndAnEmptyCellKeepsItsRowAndColumnShape() {
        let rows: [[Cell]] = [
            [Cell(spans: []), Cell(spans: [span("42")])],
            [Cell(spans: [span("Name")]), Cell(spans: [span("Score")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let blocks = tableBlocks(in: out)
        XCTAssertEqual(blocks.count, 4)
        let firstRowCols = Set(blocks.filter { $0.startingRow == 0 }.map(\.startingColumn))
        XCTAssertEqual(firstRowCols, [0, 1], "the empty first cell must still keep its column in place")
    }

    func testTableHeaderRowIsShadedWithThemeHeaderBackground() {
        let out = build([.table(rows: [
            [Cell(spans: [span("H1")]), Cell(spans: [span("H2")])],
            [Cell(spans: [span("v1")]), Cell(spans: [span("v2")])],
        ], headerRows: 1)])
        let blocks = tableBlocks(in: out)
        let headerBgs = blocks.filter { $0.startingRow == 0 }.compactMap(\.backgroundColor)
        XCTAssertEqual(headerBgs.count, 2)
        XCTAssertTrue(headerBgs.allSatisfy { $0 == Palette.tableHeaderBg })
        let bodyBgs = blocks.filter { $0.startingRow == 1 }.compactMap(\.backgroundColor)
        XCTAssertTrue(bodyBgs.isEmpty, "only the header row is shaded")
    }

    /// `headerRows: 0` — the "source can't tell us" case — must render row 0 as ordinary content:
    /// no bold, no header shading. Defaulting this to look like a header would misrepresent a
    /// document that never had one (see `OfficeBlock.table`).
    func testHeaderRowsZeroRendersFirstRowWithPlainBodyAttributes() {
        let out = build([.table(rows: [
            [Cell(spans: [span("H1")]), Cell(spans: [span("H2")])],
            [Cell(spans: [span("v1")]), Cell(spans: [span("v2")])],
        ], headerRows: 0)])
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertFalse(font!.fontDescriptor.symbolicTraits.contains(.bold), "headerRows: 0 must not bold row 0")
        let blocks = tableBlocks(in: out)
        XCTAssertTrue(blocks.allSatisfy { $0.backgroundColor == nil }, "headerRows: 0 must not shade any row")
    }

    /// The point of this whole sprint: a Word table and a markdown table with the same logical
    /// content (2 columns, 1 header row, 2 body rows) must produce structurally EQUIVALENT table
    /// blocks — same cell count, same row/column placement, same border colour, same header
    /// shading — because both now go through `TableBlockBuilder`. Font/text differ (different
    /// source pipelines feed the cell content), so this compares block STRUCTURE, not the string.
    func testOfficeAndMarkdownTablesWithSameContentProduceStructurallyEquivalentBlocks() {
        let officeOut = build([.table(rows: [
            [Cell(spans: [span("A")]), Cell(spans: [span("B")])],
            [Cell(spans: [span("1")]), Cell(spans: [span("2")])],
        ], headerRows: 1)])
        let markdownOut = MarkdownRenderer.render("| A | B |\n|---|---|\n| 1 | 2 |", theme: theme)

        let officeBlocks = tableBlocks(in: officeOut)
        var markdownBlocks: [NSTextTableBlock] = []
        markdownOut.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: markdownOut.length)) { value, _, _ in
            guard let ps = value as? NSParagraphStyle else { return }
            for tb in ps.textBlocks { if let block = tb as? NSTextTableBlock { markdownBlocks.append(block) } }
        }

        XCTAssertEqual(officeBlocks.count, 4)
        XCTAssertEqual(officeBlocks.count, markdownBlocks.count)
        func shape(_ blocks: [NSTextTableBlock]) -> [[Int]] {
            blocks.map { [$0.startingRow, $0.startingColumn] }
        }
        XCTAssertEqual(shape(officeBlocks), shape(markdownBlocks))
        XCTAssertEqual(officeBlocks.filter { $0.backgroundColor != nil }.count, 2)
        XCTAssertEqual(officeBlocks.filter { $0.backgroundColor != nil }.count,
                       markdownBlocks.filter { $0.backgroundColor != nil }.count)
        let officeBorders = Set(officeBlocks.compactMap { $0.borderColor(for: .minX) })
        let markdownBorders = Set(markdownBlocks.compactMap { $0.borderColor(for: .minX) })
        XCTAssertEqual(officeBorders, markdownBorders)
        XCTAssertEqual(officeBorders, [Palette.tableBorder])
    }

    // MARK: Tables — spans (R1-3)

    /// The safety net for the whole R1 change: a table where every `Cell` is left at its default
    /// `rowSpan`/`colSpan` of 1 must produce the exact block count and shape the pre-R1 rectangular
    /// grid did — nothing about ordinary tables may change just because spans exist as a concept.
    func testTableWithAllSpansOneRendersIdenticallyToAPlainGrid() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("A")]), Cell(spans: [span("B")]), Cell(spans: [span("C")])],
            [Cell(spans: [span("1")]), Cell(spans: [span("2")]), Cell(spans: [span("3")])],
        ]
        let out = build([.table(rows: rows, headerRows: 1)])
        let blocks = tableBlocks(in: out)
        XCTAssertEqual(blocks.count, 6)
        XCTAssertTrue(blocks.allSatisfy { $0.rowSpan == 1 && $0.columnSpan == 1 })
        XCTAssertEqual(Set(blocks.filter { $0.startingRow == 0 }.map(\.startingColumn)), [0, 1, 2])
        XCTAssertEqual(Set(blocks.filter { $0.startingRow == 1 }.map(\.startingColumn)), [0, 1, 2])
    }

    /// A `colSpan: 2` anchor in a 3-column table must occupy columns 0–1, and the row's next cell
    /// must land in column 2 — not column 1, which the anchor already covers.
    func testColSpanTwoOccupiesTwoColumnsAndTheNextCellStartsAfterIt() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("wide")], colSpan: 2), Cell(spans: [span("narrow")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let blocks = tableBlocks(in: out)
        XCTAssertEqual(blocks.count, 2)
        let wide = blocks.first { $0.startingColumn == 0 }
        let narrow = blocks.first { $0.startingColumn == 2 }
        XCTAssertEqual(wide?.columnSpan, 2)
        XCTAssertNotNil(narrow, "the second cell must start at column 2, past the merged span")
        XCTAssertEqual(narrow?.columnSpan, 1)
    }

    /// A `rowSpan: 2` anchor must occupy its own row and the one below it; the row below must
    /// place its OTHER cells in the columns the span doesn't cover, not shifted or dropped.
    func testRowSpanTwoOccupiesTwoRowsAndTheRowBelowFillsRemainingColumns() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("tall")], rowSpan: 2), Cell(spans: [span("top-right")])],
            [Cell(spans: [span("bottom-right")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let blocks = tableBlocks(in: out)
        XCTAssertEqual(blocks.count, 3)
        let tall = blocks.first { $0.startingRow == 0 && $0.startingColumn == 0 }
        XCTAssertEqual(tall?.rowSpan, 2)
        let bottomRight = blocks.first { $0.startingRow == 1 }
        XCTAssertEqual(bottomRight?.startingColumn, 1, "row 1's own cell must land in the column the span doesn't cover")
    }

    /// A row can carry FEWER anchors than the grid is wide — exactly what a Word row looks like once
    /// its other cells are absorbed by a merge. Every column must still get a block, or the border
    /// has a hole in it: an unoccupied position with no `NSTextTableBlock` draws nothing at all,
    /// which reads as a broken table rather than an empty cell. Note this is a SHORT ARRAY, not an
    /// empty `Cell` — the distinction the padding pass exists for.
    func testRowWithFewerAnchorsThanTheGridStillDrawsEveryColumn() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("A")]), Cell(spans: [span("B")]), Cell(spans: [span("C")])],
            [Cell(spans: [span("1")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let blocks = tableBlocks(in: out)
        XCTAssertEqual(Set(blocks.filter { $0.startingRow == 1 }.map(\.startingColumn)), [0, 1, 2],
                       "the short row must still cover all three columns")
        XCTAssertEqual(blocks.count, 6)
    }

    /// The other half of that rule: a position covered by another cell's span is OCCUPIED, not empty,
    /// and must NOT be padded. Padding it would put a second block in one grid position.
    func testColumnsCoveredByAnEarlierRowsSpanAreNotPadded() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("tall")], rowSpan: 2), Cell(spans: [span("top")])],
            [Cell(spans: [span("bottom")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let blocks = tableBlocks(in: out)
        XCTAssertEqual(blocks.count, 3, "no padding block may be added under the vertical span")
        let row1 = blocks.filter { $0.startingRow == 1 }
        XCTAssertEqual(row1.count, 1)
        XCTAssertEqual(row1.first?.startingColumn, 1)
    }

    /// A span that reaches the last column leaves nothing to pad.
    func testColSpanReachingTheLastColumnAddsNoTrailingPadding() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("A")]), Cell(spans: [span("B")])],
            [Cell(spans: [span("wide")], colSpan: 2)],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let blocks = tableBlocks(in: out)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks.filter { $0.startingRow == 1 }.count, 1)
    }

    /// Spans arrive from a parsed file, so they are untrusted input. A document claiming a cell spans
    /// a huge number of rows must not turn into that many loop iterations and set insertions — the
    /// same posture `ZipArchive` takes toward a declared size. The table still renders.
    func testAbsurdSpanIsClampedRatherThanLoopedOver() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("hostile")], rowSpan: 100_000, colSpan: 100_000)],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let blocks = tableBlocks(in: out)
        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.rowSpan, TableBlockBuilder.maxSpan)
        XCTAssertEqual(blocks.first?.columnSpan, TableBlockBuilder.maxSpan)
    }

    /// A zero or negative span is nonsense but must not vanish the cell or stall the column cursor.
    func testZeroSpanIsTreatedAsOne() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("A")], rowSpan: 0, colSpan: 0), Cell(spans: [span("B")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let blocks = tableBlocks(in: out)
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(Set(blocks.map(\.startingColumn)), [0, 1], "a zero span must still advance the cursor")
    }

    /// A merged cell must not disturb header shading: only row 0 is shaded, regardless of a span
    /// reaching into row 1.
    func testMergedCellCombinedWithOneHeaderRowStillShadesOnlyTheHeaderRow() {
        let rows: [[Cell]] = [
            [Cell(spans: [span("H1")], colSpan: 2)],
            [Cell(spans: [span("v1")]), Cell(spans: [span("v2")])],
        ]
        let out = build([.table(rows: rows, headerRows: 1)])
        let blocks = tableBlocks(in: out)
        let headerBgs = blocks.filter { $0.startingRow == 0 }.compactMap(\.backgroundColor)
        XCTAssertEqual(headerBgs.count, 1)
        let bodyBgs = blocks.filter { $0.startingRow == 1 }.compactMap(\.backgroundColor)
        XCTAssertTrue(bodyBgs.isEmpty)
    }

    // MARK: Span marks (R1-2 / R1-4)

    /// Each new mark must land on exactly its own span's range — the same "no bleed into
    /// neighbours" contract `testBoldAppliesOnlyToTheBoldSpansRange` already holds bold to.
    func testStrikethroughSuperscriptAndSubscriptEachRenderOnlyOnTheirOwnRange() {
        var strike = span("gone"); strike.strikethrough = true
        var sup = span("note"); sup.superscript = true
        var sub = span("index"); sub.subscripted = true
        let out = build([.paragraph(spans: [span("plain "), strike, span(" "), sup, span(" "), sub])])
        let text = out.string as NSString

        let strikeRange = text.range(of: "gone")
        XCTAssertEqual(out.attribute(.strikethroughStyle, at: strikeRange.location, effectiveRange: nil) as? Int,
                       NSUnderlineStyle.single.rawValue)
        XCTAssertNil(out.attribute(.strikethroughStyle, at: 0, effectiveRange: nil), "plain text must not be struck through")

        let supRange = text.range(of: "note")
        let plainFont = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let supFont = out.attribute(.font, at: supRange.location, effectiveRange: nil) as? NSFont
        let supOffset = out.attribute(.baselineOffset, at: supRange.location, effectiveRange: nil) as? CGFloat
        XCTAssertLessThan(supFont!.pointSize, plainFont!.pointSize, "superscript must shrink the glyph")
        XCTAssertGreaterThan(supOffset ?? 0, 0, "superscript must raise the baseline")

        let subRange = text.range(of: "index")
        let subFont = out.attribute(.font, at: subRange.location, effectiveRange: nil) as? NSFont
        let subOffset = out.attribute(.baselineOffset, at: subRange.location, effectiveRange: nil) as? CGFloat
        XCTAssertLessThan(subFont!.pointSize, plainFont!.pointSize, "subscript must shrink the glyph")
        XCTAssertLessThan(subOffset ?? 0, 0, "subscript must lower the baseline")
    }

    /// A linked office span must carry the identical `.foregroundColor`/`.underlineStyle`/`.link`
    /// treatment a markdown link gets — a reader shouldn't be able to tell which format a link
    /// came from just by looking at it.
    func testLinkSpanCarriesTheSameAttributesAMarkdownLinkDoes() {
        var linked = span("click here"); linked.link = "https://example.com/doc"
        let officeOut = build([.paragraph(spans: [linked])])
        let markdownOut = MarkdownRenderer.render("[click here](https://example.com/doc)", theme: theme)

        let officeColor = officeOut.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        let officeUnderline = officeOut.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        let officeURL = officeOut.attribute(.link, at: 0, effectiveRange: nil) as? URL

        let mdLoc = (markdownOut.string as NSString).range(of: "click here").location
        let mdColor = markdownOut.attribute(.foregroundColor, at: mdLoc, effectiveRange: nil) as? NSColor
        let mdUnderline = markdownOut.attribute(.underlineStyle, at: mdLoc, effectiveRange: nil) as? Int
        let mdURL = markdownOut.attribute(.link, at: mdLoc, effectiveRange: nil) as? URL

        XCTAssertEqual(officeColor, mdColor)
        XCTAssertEqual(officeUnderline, mdUnderline)
        XCTAssertEqual(officeURL, mdURL)
        XCTAssertEqual(officeURL, URL(string: "https://example.com/doc"))
    }

    // MARK: Images

    /// Requirement 7 / invariant 1: the reserved size must be exactly the declared size, and the
    /// image itself must be nil — pixels arrive in a later sprint, and loading them must never
    /// change layout (only redraw).
    func testImageBlockReservesExactSizeWithNoPixelsYet() throws {
        let size = CGSize(width: 240, height: 135)
        let out = build([.image(id: "rel42", size: size)])
        var found: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let att = value as? NSTextAttachment { found = att }
        }
        let attachment = try XCTUnwrap(found)
        XCTAssertNil(attachment.image)
        XCTAssertEqual(attachment.attachmentCell?.cellSize(), size)
        let sizedCell = attachment.attachmentCell as? SizedAttachmentCell
        XCTAssertEqual(sizedCell?.reservedSize, size)
        let idValue = out.attribute(MDAttr.image, at: 0, effectiveRange: nil) as? String
        XCTAssertEqual(idValue, "rel42")
    }

    /// A declared size WIDER than the column must scale down proportionally (aspect ratio
    /// preserved) — and the decision must be made HERE, at build time, from the declared size
    /// alone, not deferred to load time (see `MarkdownDocument.reconcileMedia`'s office branch,
    /// which only ever paints — never resizes — an office image).
    func testImageWiderThanColumnScalesDownProportionallyAtBuildTime() throws {
        let declared = CGSize(width: 2000, height: 1000)   // 2:1 aspect
        let out = OfficeTextBuilder.build([.image(id: "wide", size: declared)], theme: theme, columnWidth: 700)
        var found: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let att = value as? NSTextAttachment { found = att }
        }
        let attachment = try XCTUnwrap(found)
        let cell = try XCTUnwrap(attachment.attachmentCell as? SizedAttachmentCell)
        XCTAssertEqual(cell.reservedSize.width, 700, accuracy: 0.5)
        XCTAssertEqual(cell.reservedSize.height, 350, accuracy: 0.5, "aspect ratio (2:1) must be preserved")
        XCTAssertEqual(attachment.bounds.size, cell.reservedSize)
    }

    /// A declared size that already fits the column must pass through unchanged — scaling must
    /// never enlarge an image past its authored size.
    func testImageNarrowerThanColumnIsReservedAtItsDeclaredSize() {
        let declared = CGSize(width: 240, height: 135)
        let out = OfficeTextBuilder.build([.image(id: "small", size: declared)], theme: theme, columnWidth: 700)
        let cell = out.attribute(.attachment, at: 0, effectiveRange: nil)
            .flatMap { ($0 as? NSTextAttachment)?.attachmentCell as? SizedAttachmentCell }
        XCTAssertEqual(cell?.reservedSize, declared)
    }
}

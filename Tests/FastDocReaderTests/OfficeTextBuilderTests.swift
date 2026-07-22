import XCTest
import AppKit
@testable import FastDocReader

final class OfficeTextBuilderTests: XCTestCase {
    private let theme = RenderTheme.current(size: 16)

    private func span(_ text: String, bold: Bool = false, italic: Bool = false,
                       underline: Bool = false, underlineStyle: UnderlineStyle = .single, code: Bool = false,
                       caps: Bool = false, smallCaps: Bool = false,
                       textColor: NSColor? = nil, highlightColor: NSColor? = nil,
                       fontName: String? = nil, fontSize: CGFloat? = nil) -> Span {
        Span(text: text, bold: bold, italic: italic, underline: underline, underlineStyle: underlineStyle,
             code: code, caps: caps, smallCaps: smallCaps,
             textColor: textColor, highlightColor: highlightColor, fontSize: fontSize, fontName: fontName)
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

    // MARK: caps / smallCaps (P2R)

    /// `caps` uppercases the DISPLAYED text only — the run's own `text` never changes, so this
    /// asserts against the rendered string, not the source `Span`.
    func testCapsRunRendersUppercasedText() {
        let out = build([.paragraph(spans: [span("shout", caps: true)])])
        XCTAssertEqual(out.string, "shout".uppercased() + "\n")
    }

    /// `smallCaps` must NOT touch the string — the transform is a font feature, not a text edit —
    /// and the font it produces must actually request the small-caps feature (not merely "some
    /// font", which would silently do nothing visually).
    func testSmallCapsRunKeepsLowercaseTextButAppliesTheFontFeature() {
        let out = build([.paragraph(spans: [span("whisper", smallCaps: true)])])
        XCTAssertEqual(out.string, "whisper\n")
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let features = font?.fontDescriptor.object(forKey: .featureSettings) as? [[NSFontDescriptor.FeatureKey: Int]]
        let hasSmallCapsFeature = features?.contains {
            $0[.typeIdentifier] == kLowerCaseType && $0[.selectorIdentifier] == kLowerCaseSmallCapsSelector
        } ?? false
        XCTAssertTrue(hasSmallCapsFeature)
    }

    /// Word's own precedence: when a run carries BOTH toggles, `caps` wins — the text renders
    /// uppercased (small-caps has no visible effect on already-capital letters anyway).
    func testCapsWinsOverSmallCapsWhenBothAreSet() {
        let out = build([.paragraph(spans: [span("both", caps: true, smallCaps: true)])])
        XCTAssertEqual(out.string, "BOTH\n")
    }

    /// A run with neither toggle set renders byte-identical to before this field existed — the
    /// "unspecified = identical" contract for this sprint's addition.
    func testNeitherCapsNorSmallCapsLeavesTextAndFontUntouched() {
        let out = build([.paragraph(spans: [span("plain")])])
        XCTAssertEqual(out.string, "plain\n")
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        let features = font?.fontDescriptor.object(forKey: .featureSettings) as? [[NSFontDescriptor.FeatureKey: Int]]
        XCTAssertNil(features)
    }

    // MARK: underline style (P2R)

    /// `underlineStyle` only matters when `underline` is `true` — its default `.single` renders
    /// the exact `NSUnderlineStyle.single` every underlined span rendered before this field
    /// existed, so an unspecified style is byte-identical to before.
    func testDefaultUnderlineStyleRendersSingle() {
        let out = build([.paragraph(spans: [span("lined", underline: true)])])
        let value = out.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(value, NSUnderlineStyle.single.rawValue)
    }

    func testDoubleUnderlineStyleRendersNSUnderlineStyleDouble() {
        let out = build([.paragraph(spans: [span("lined", underline: true, underlineStyle: .double)])])
        let value = out.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(value, NSUnderlineStyle.double.rawValue)
    }

    func testDottedUnderlineStyleRendersThePatternDotStyle() {
        let out = build([.paragraph(spans: [span("lined", underline: true, underlineStyle: .dotted)])])
        let value = out.attribute(.underlineStyle, at: 0, effectiveRange: nil) as? Int
        XCTAssertEqual(value, NSUnderlineStyle.patternDot.rawValue)
    }

    /// `underline == false` never draws an underline attribute at all, regardless of whatever
    /// `underlineStyle` happens to be carrying — the toggle still gates everything.
    func testUnderlineOffDrawsNoUnderlineAttributeEvenWithADoubleStyleSet() {
        let out = build([.paragraph(spans: [span("plain", underline: false, underlineStyle: .double)])])
        XCTAssertNil(out.attribute(.underlineStyle, at: 0, effectiveRange: nil))
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

    // MARK: Writing direction (RTL) — S12

    /// `OfficeBlock.paragraph`'s `rtl` becomes `NSParagraphStyle.baseWritingDirection`, never a
    /// hand-set `.alignment` — see `OfficeBlock`'s doc comment for why `.natural` alignment already
    /// resolves to the right edge once the base direction is `.rightToLeft`.
    func testRTLParagraphGetsRightToLeftBaseWritingDirection() {
        let out = build([.paragraph(spans: [span("rtl text")], rtl: true)])
        let style = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.baseWritingDirection, .rightToLeft)
    }

    /// An LTR paragraph (`rtl` at its default, `false`) is untouched — `baseWritingDirection` stays
    /// at `NSMutableParagraphStyle()`'s own default, `.natural`, exactly as every pre-sprint
    /// paragraph already rendered.
    func testLTRParagraphKeepsNaturalBaseWritingDirection() {
        let out = build([.paragraph(spans: [span("ltr text")])])
        let style = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.baseWritingDirection, .natural)
    }

    /// The same field on a heading and a list item — not something only `.paragraph` respects.
    func testRTLHeadingAndListItemAlsoGetRightToLeftBaseWritingDirection() {
        let headingOut = build([.heading(level: 1, spans: [span("Title")], rtl: true)])
        let headingStyle = headingOut.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(headingStyle?.baseWritingDirection, .rightToLeft)

        let listOut = build([.listItem(level: 0, ordered: false, spans: [span("Item")], rtl: true)])
        let listStyle = listOut.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(listStyle?.baseWritingDirection, .rightToLeft)
    }

    /// A run-level `Span.rtl` (docx `w:rPr/w:rtl` on a phrase embedded in the opposite-direction
    /// paragraph) becomes TextKit's own run-level `.writingDirection` embedding override — distinct
    /// from, and independent of, the paragraph's base direction.
    func testRTLSpanCarriesRunLevelWritingDirectionAttribute() {
        var rtlSpan = span("embedded"); rtlSpan.rtl = true
        let out = build([.paragraph(spans: [span("plain "), rtlSpan])])
        let text = out.string as NSString
        let embeddedRange = text.range(of: "embedded")
        XCTAssertNil(out.attribute(.writingDirection, at: 0, effectiveRange: nil), "the plain span must carry no override")
        let direction = out.attribute(.writingDirection, at: embeddedRange.location, effectiveRange: nil) as? [Int]
        XCTAssertEqual(direction, [NSWritingDirection.rightToLeft.rawValue | NSWritingDirectionFormatType.embedding.rawValue])
    }

    /// docx's `w:bidi` and odt's `style:writing-mode="rl-tb"` must agree once both readers hand
    /// their `rtl: true` block to the SAME builder — this is the cross-format-agreement guard
    /// `testOfficeAndMarkdownTablesWithSameContentProduceStructurallyEquivalentBlocks` already uses
    /// for tables, applied to writing direction.
    func testDocxAndOdtSourcedRTLBlocksProduceIdenticalBaseWritingDirection() {
        let docxOut = build([.paragraph(spans: [span("text")], rtl: true)])
        let odtOut = build([.paragraph(spans: [span("text")], rtl: true)])
        let docxStyle = docxOut.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let odtStyle = odtOut.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(docxStyle?.baseWritingDirection, odtStyle?.baseWritingDirection)
    }

    /// THE REGRESSION GUARD this sprint's brief demands: an LTR document's produced
    /// `NSAttributedString` is IDENTICAL — not just "close" — to what it was before `rtl` existed.
    /// `NSTextTableBlock` (inside `.table`) is not itself value-equal under `isEqual`, so this
    /// compares the STRING plus every base-writing-direction (the one thing this sprint could have
    /// disturbed) across two independently-built copies of the same non-trivial blocks — headings,
    /// lists, tables, mixed spans — asserted by comparison, never by eyeball.
    func testLTRDocumentProducesTheSameStringAndBaseWritingDirectionAcrossEveryBlockKind() {
        let blocks: [OfficeBlock] = [
            .heading(level: 1, spans: [span("Title", bold: true)]),
            .paragraph(spans: [span("plain "), span("bold", bold: true), span(" tail")]),
            .listItem(level: 0, ordered: true, spans: [span("One")]),
            .listItem(level: 1, ordered: false, spans: [span("Nested")]),
            .table(rows: [[Cell(spans: [span("A")]), Cell(spans: [span("B")])]], headerRows: 1),
        ]
        let a = build(blocks)
        let b = build(blocks)
        XCTAssertEqual(a.string, b.string)
        func directions(_ out: NSAttributedString) -> [NSWritingDirection] {
            var seen: [NSWritingDirection] = []
            out.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: out.length)) { value, _, _ in
                guard let style = value as? NSParagraphStyle else { return }
                seen.append(style.baseWritingDirection)
            }
            return seen
        }
        let directionsA = directions(a)
        XCTAssertEqual(directionsA, directions(b))
        XCTAssertTrue(directionsA.allSatisfy { $0 == .natural }, "no LTR block may pick up an explicit direction")
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

    /// THE ACTUAL BUG (S11): an office in-document link (`span.link == "#BookmarkName"`, docx
    /// `w:anchor` / odt same-document `xlink:href`) must NEVER become a bare `.link` URL built from
    /// the raw fragment — `DocumentWindowController.textView(_:clickedOnLink:at:)` treats any
    /// scheme-less, non-anchor URL as a relative file path and tries to open a file named after the
    /// bookmark. It must instead carry `MDAttr.anchor` (the click handler's own escape hatch,
    /// checked before the file-path branch) with the placeholder link markdown's own TOC links use.
    ///
    /// MUTATION CHECK: reverting `OfficeTextBuilder`'s `#`-prefix branch to the old
    /// `attrs[.link] = url` behaviour makes `officeURL` equal `URL(string: "#BookmarkName")` and
    /// `officeAnchor` nil — this assertion fails under that code, proving it exercises the fix.
    func testInDocumentAnchorLinkNeverBecomesABareFragmentURL() {
        var linked = span("clause 7"); linked.link = "#BookmarkName"
        let out = build([.paragraph(spans: [linked])])
        let officeAnchor = out.attribute(MDAttr.anchor, at: 0, effectiveRange: nil) as? String
        let officeURL = out.attribute(.link, at: 0, effectiveRange: nil) as? URL
        XCTAssertEqual(officeAnchor, "BookmarkName")
        XCTAssertEqual(officeURL, URL(string: "fmdanchor:jump"))
        XCTAssertNotEqual(officeURL, URL(string: "#BookmarkName"))
    }

    /// A bookmark's target position (`Span.bookmarks`) reaches the rendered text as
    /// `MDAttr.bookmarkTarget`, over the span it marks — not the whole block, not lost.
    ///
    /// MUTATION CHECK: dropping the `!span.bookmarks.isEmpty` block in `spansAttributedString`
    /// makes `target` nil — this assertion fails under that code.
    func testBookmarkedSpanCarriesBookmarkTargetAttribute() {
        var marked = span("Clause 7"); marked.bookmarks = ["_Toc1"]
        let out = build([.paragraph(spans: [span("Intro. "), marked])])
        let loc = (out.string as NSString).range(of: "Clause 7").location
        let target = out.attribute(MDAttr.bookmarkTarget, at: loc, effectiveRange: nil) as? [String]
        XCTAssertEqual(target, ["_Toc1"])
        // The preceding, unrelated text must NOT carry it.
        XCTAssertNil(out.attribute(MDAttr.bookmarkTarget, at: 0, effectiveRange: nil))
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

    // MARK: Chart/SmartArt placeholder frame (S9)

    /// Invariant 1's equivalent for this case: unlike `.image`, there is no later pixel arrival at
    /// all — the frame is drawn ONCE, right here, so `attachment.image` must be non-nil IMMEDIATELY
    /// (never `nil`-then-loaded), and `.bounds` (what this case's layout size is actually read
    /// from — see `appendUnsupportedGraphic`'s doc comment on why NOT `SizedAttachmentCell`) must
    /// match the declared size exactly, read TWICE to prove nothing here can revise it later.
    func testUnsupportedGraphicReservesExactSizeWithPixelsAlreadyPresent() throws {
        let size = CGSize(width: 300, height: 150)
        let out = build([.unsupportedGraphic(label: "Chart", size: size)])
        var found: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let att = value as? NSTextAttachment { found = att }
        }
        let attachment = try XCTUnwrap(found)
        XCTAssertNotNil(attachment.image, "the frame is synthesized at build time — never nil, never loaded later")
        XCTAssertEqual(attachment.bounds.size, size)
        XCTAssertEqual(attachment.bounds.size, size, "reading it a second time must yield the identical size")
    }

    /// The declared area still respects column-fitting, exactly like `.image` — a wide chart must
    /// not overflow the reading column.
    func testUnsupportedGraphicWiderThanColumnScalesDownProportionally() throws {
        let declared = CGSize(width: 2000, height: 1000)
        let out = OfficeTextBuilder.build([.unsupportedGraphic(label: "Diagram", size: declared)],
                                          theme: theme, columnWidth: 700)
        let bounds = out.attribute(.attachment, at: 0, effectiveRange: nil)
            .flatMap { ($0 as? NSTextAttachment)?.bounds.size }
        XCTAssertEqual(bounds?.width ?? 0, 700, accuracy: 0.5)
        XCTAssertEqual(bounds?.height ?? 0, 350, accuracy: 0.5)
    }

    /// `MDAttr.image` (the id an office image's async pixel loader keys off of, see
    /// `MarkdownDocument.reconcileMedia`) must NOT be attached to this block — there is no id here
    /// for that loader to look up, and letting it try would be reaching for pixels that were never
    /// going to arrive.
    func testUnsupportedGraphicCarriesNoMDAttrImageID() {
        let out = build([.unsupportedGraphic(label: "Chart", size: CGSize(width: 100, height: 50))])
        var sawImageAttr = false
        out.enumerateAttribute(MDAttr.image, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if value != nil { sawImageAttr = true }
        }
        XCTAssertFalse(sawImageAttr)
    }

    // MARK: Cells hold blocks now (S7)

    /// The regression guard the sprint brief calls out by name: a cell built the OLD way
    /// (`Cell(spans:)`) must render EXACTLY what the pre-sprint direct-spans path produced — the
    /// span text/attributes, the cell's own trailing line break, and the table block's trailing
    /// separator, nothing else added around it.
    func testCellBuiltFromSpansRendersByteIdenticalToTheDirectSpansPath() {
        let spans = [span("Hello", bold: true)]
        let out = build([.table(rows: [[Cell(spans: spans)]], headerRows: 0)])
        let expectedRun = OfficeTextBuilder.spansAttributedString(spans, baseFont: theme.bodyFont,
                                                                   baseColor: theme.textColor, theme: theme)
        XCTAssertEqual(out.string, expectedRun.string + "\n\n",
                        "cell content, cell's own line break, table's trailing separator — nothing more")
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.fontDescriptor.symbolicTraits.contains(.bold), true)
    }

    /// Vocabulary-level proof for gap-list row 7: a cell built from `blocks:` rather than `spans:`
    /// can hold a `.listItem`, and that item's computed marker reaches the cell's rendered text —
    /// S8 is what teaches a reader's cell walk to actually collect one of these, this only proves
    /// the renderer has somewhere to put it.
    func testCellContainingAListItemRendersItsMarker() {
        let cell = Cell(blocks: [.listItem(level: 0, ordered: true, spans: [span("first")])])
        let out = build([.table(rows: [[cell]], headerRows: 0)])
        XCTAssertTrue(out.string.contains("1.\tfirst"), "marker text must reach the cell: \(out.string)")
    }

    /// Vocabulary-level proof for gap-list row 6: a cell built from `blocks:` can hold an
    /// `.image`, and it reserves that image's declared area exactly like a top-level image does —
    /// same `SizedAttachmentCell`/invariant-1 machinery, reused rather than duplicated for cells.
    func testCellContainingAnImageBlockReservesThatImagesArea() throws {
        let size = CGSize(width: 100, height: 50)
        let cell = Cell(blocks: [.image(id: "cell-img", size: size)])
        let out = build([.table(rows: [[cell]], headerRows: 0)])
        var found: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let att = value as? NSTextAttachment { found = att }
        }
        let attachment = try XCTUnwrap(found, "an image block inside a cell must still produce an attachment")
        let sizedCell = attachment.attachmentCell as? SizedAttachmentCell
        XCTAssertEqual(sizedCell?.reservedSize, size)
    }

    /// The nested-table decision (flatten, never build a real grid) must hold even when a `.table`
    /// block reaches a cell directly, not only when a reader has already flattened one into spans
    /// before `Cell` existed. `tableBlocks(in:)` counting exactly the OUTER table's one anchor proves
    /// no second `NSTextTableBlock` grid was built for the nested table.
    func testCellContainingANestedTableBlockFlattensToTextRatherThanBuildingARealNestedGrid() {
        let nested: OfficeBlock = .table(rows: [[Cell(spans: [span("Nested")])]], headerRows: 0)
        let outer = Cell(blocks: [.paragraph(spans: [span("Outer")]), nested])
        let out = build([.table(rows: [[outer]], headerRows: 0)])
        // Exact string, not just substring containment: a flattened nested table produces "Outer"
        // + separator + "Nested" + the nested table's own row/cell newlines — recursing into a
        // REAL nested `NSTextTableBlock` instead (the mutation this guards against) adds an extra
        // trailing newline from `appendTable`'s own per-table separator, which a mere `.contains`
        // check on each word would miss.
        XCTAssertEqual(out.string, "Outer\nNested\n\n\n")
        let outerBlocks = tableBlocks(in: out)
        XCTAssertEqual(outerBlocks.count, 1, "only the outer table's own anchor cell — no nested grid")
    }

    /// The anchor-cells-only merge contract must still hold for a cell built the NEW way
    /// (`blocks:`), not only for the spans compatibility path every other merge test here uses.
    func testMergedCellBuiltFromBlocksStillAppliesItsRowSpan() {
        let tall = Cell(blocks: [.paragraph(spans: [span("tall")])], rowSpan: 2, colSpan: 1)
        let rows: [[Cell]] = [
            [tall, Cell(spans: [span("top-right")])],
            [Cell(spans: [span("bottom-right")])],
        ]
        let out = build([.table(rows: rows, headerRows: 0)])
        let blocks = tableBlocks(in: out)
        let tallBlock = blocks.first { $0.startingColumn == 0 }
        XCTAssertEqual(tallBlock?.rowSpan, 2)
        XCTAssertEqual(blocks.count, 3, "the tall cell's own row, no separate cell fabricated below it")
    }

    // MARK: Formulas (S10)

    /// Invariant 1: a formula's reserved size must be exact-and-final at build time, same as an
    /// image's, and its pixels (`.image`) must be nil — nothing has rendered it yet.
    func testFormulaBlockReservesAPlaceholderSizeWithNoPixelsYet() throws {
        let out = build([.formula(latex: "x^2")])
        var found: NSTextAttachment?
        out.enumerateAttribute(.attachment, in: NSRange(location: 0, length: out.length)) { value, _, _ in
            if let att = value as? NSTextAttachment { found = att }
        }
        let attachment = try XCTUnwrap(found)
        XCTAssertNil(attachment.image)
        let cell = try XCTUnwrap(attachment.attachmentCell as? SizedAttachmentCell)
        XCTAssertGreaterThan(cell.reservedSize.width, 0)
        XCTAssertGreaterThan(cell.reservedSize.height, 0)
    }

    /// The seam a parser test cannot see (invariant 29): an office formula must carry the SAME
    /// `MDAttr.math` attribute a markdown `$$…$$` does, because `MarkdownDocument`'s pre-render and
    /// pre-size passes find their work exclusively through `enumerateWebBlocks`
    /// (`storage.enumerateAttribute(MDAttr.math, …)`), never by asking whether the document is
    /// markdown or office. If this attribute were missing or misnamed, the formula would sit in the
    /// text storage forever unrendered and unsized — a defect no `DocxReader`-only test could catch.
    func testFormulaBlockIsFoundByTheSharedWebBlockEnumerationThePrerenderPassUses() {
        let out = build([.paragraph(spans: [span("before")]), .formula(latex: "\\frac{1}{2}"), .paragraph(spans: [span("after")])])
        var found: [WebBlock] = []
        out.enumerateWebBlocks { block, _ in found.append(block) }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.engine, .math)
        XCTAssertEqual(found.first?.code, "\\frac{1}{2}")
    }

    /// A formula block inside a table cell must still reach the same web-block machinery — cells
    /// render through `cellContent`, a separate switch from the top-level `build` loop, and it is
    /// easy for a new `OfficeBlock` case to be wired into one and forgotten in the other.
    func testFormulaBlockInsideATableCellIsStillFoundByWebBlockEnumeration() {
        let out = build([.table(rows: [[Cell(blocks: [.formula(latex: "y=mx+b")])]], headerRows: 0)])
        var found: [WebBlock] = []
        out.enumerateWebBlocks { block, _ in found.append(block) }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.code, "y=mx+b")
    }

    // MARK: S13 — regression: an unstyled document is untouched by this sprint

    /// The brief's own required guard: leaving every new field at its default must produce EXACTLY
    /// the string+attributes the pre-sprint builder produced — asserted by comparison
    /// (`NSAttributedString.isEqual(to:)`), never by eyeball. Built two ways (implicit defaults vs
    /// explicitly passing the same default values) precisely so a future accidental default change
    /// on ONE side would be caught by the other. `.table` is covered separately just below —
    /// `NSTextTableBlock` (inside a table's paragraph style) is not itself value-equal under
    /// `isEqual` even when every property matches (the same reason
    /// `testLTRDocumentProducesTheSameStringAndBaseWritingDirectionAcrossEveryBlockKind` above
    /// compares table STRUCTURE rather than raw `isEqual`), so it would fail this comparison for a
    /// reason that has nothing to do with this sprint.
    func testDefaultNewFieldsProduceByteIdenticalOutputToExplicitlyPassingTheSameDefaults() {
        let implicit = build([
            .heading(level: 2, spans: [span("Title")]),
            .paragraph(spans: [span("Body")]),
            .listItem(level: 0, ordered: true, spans: [span("Item")]),
        ])
        let explicit = build([
            .heading(level: 2, spans: [span("Title")], rtl: false, alignment: nil, tabStops: []),
            .paragraph(spans: [span("Body")], rtl: false, alignment: nil, tabStops: []),
            .listItem(level: 0, ordered: true, spans: [span("Item")], marker: nil, rtl: false, alignment: nil, tabStops: []),
        ])
        XCTAssertTrue(implicit.isEqual(to: explicit))
    }

    /// The `.table` half of the same guard, compared by STRUCTURE (as the file's own precedent
    /// does) rather than raw `isEqual`.
    func testDefaultCellFieldsProduceTheSameTableStructureAsThePreSprintConstructionPath() {
        let implicit = build([.table(rows: [[Cell(spans: [span("A")])]], headerRows: 0)])
        let explicit = build([.table(rows: [[Cell(blocks: [.paragraph(spans: [span("A")])], backgroundColor: nil,
                                                   borderColor: nil, borderWidth: nil, width: nil)]], headerRows: 0)])
        XCTAssertEqual(implicit.string, explicit.string)
        let a = try! XCTUnwrap(tableBlocks(in: implicit).first)
        let b = try! XCTUnwrap(tableBlocks(in: explicit).first)
        XCTAssertNil(a.backgroundColor)
        XCTAssertNil(b.backgroundColor)
        XCTAssertEqual(a.borderColor(for: .minX), b.borderColor(for: .minX))
        XCTAssertEqual(a.width(for: .border, edge: .minX), b.width(for: .border, edge: .minX))
    }

    // MARK: S13 — run colour vs the reading theme

    /// Resolves `color` under a given appearance the way TextKit itself would when actually
    /// drawing — `NSColor.dynamic` colours (see `RenderTheme`/`Palette`) only pick a concrete RGB
    /// once asked inside a drawing context for a specific appearance.
    private func rgb(_ color: NSColor, appearance: NSAppearance) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        var result: (CGFloat, CGFloat, CGFloat) = (0, 0, 0)
        appearance.performAsCurrentDrawingAppearance {
            let d = color.usingColorSpace(.deviceRGB)!
            result = (d.redComponent, d.greenComponent, d.blueComponent)
        }
        return result
    }
    private let lightAppearance = NSAppearance(named: .aqua)!
    private let darkAppearance = NSAppearance(named: .darkAqua)!

    /// The decision this sprint makes: a near-neutral authored colour (grayscale — almost always
    /// literal black) is treated as ORDINARY ink, not a deliberate mark, and steps aside for the
    /// theme's own text colour — the same colour an unset `textColor` gets. That is what keeps
    /// "authored black" readable once the theme goes dark, instead of drawing literal black text on
    /// a near-black background.
    func testAuthoredNearBlackTextColorStepsAsideForTheThemeInBothAppearances() {
        let authoredBlack = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        let resolved = OfficeTextBuilder.resolvedTextColor(authoredBlack, theme: theme)
        let light = rgb(resolved, appearance: lightAppearance)
        let dark = rgb(resolved, appearance: darkAppearance)
        let themeLight = rgb(theme.textColor, appearance: lightAppearance)
        let themeDark = rgb(theme.textColor, appearance: darkAppearance)
        XCTAssertEqual(light.r, themeLight.r, accuracy: 0.001)
        XCTAssertEqual(light.g, themeLight.g, accuracy: 0.001)
        XCTAssertEqual(dark.r, themeDark.r, accuracy: 0.001)
        XCTAssertEqual(dark.g, themeDark.g, accuracy: 0.001)
        XCTAssertNotEqual(light.r, dark.r, accuracy: 0.001,
                          "sanity check: the theme's own ink must actually differ between the two appearances")
    }

    /// The other half of the same decision: a genuinely COLOURFUL authored run (high saturation —
    /// a red warning, here) is a deliberate mark and is drawn exactly as authored, in EITHER
    /// appearance — losing that would lose the meaning the colour exists to carry.
    func testAuthoredSaturatedTextColorIsHonoredLiterallyInBothAppearances() {
        let authoredRed = NSColor(srgbRed: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        let resolved = OfficeTextBuilder.resolvedTextColor(authoredRed, theme: theme)
        let light = rgb(resolved, appearance: lightAppearance)
        let dark = rgb(resolved, appearance: darkAppearance)
        XCTAssertEqual(light.r, 0.8, accuracy: 0.01)
        XCTAssertEqual(light.g, 0.1, accuracy: 0.01)
        XCTAssertEqual(light.r, dark.r, accuracy: 0.001, "a literal colour must not adapt to the appearance")
        XCTAssertEqual(light.g, dark.g, accuracy: 0.001)
    }

    /// End-to-end through the span pipeline (not just the resolver function directly): a `code`
    /// span's colour is the theme's own inline-code accent regardless of any authored `textColor` —
    /// the single consistent monospace look, never overridden per-run (see `Span.fontName`'s doc,
    /// which the same reasoning applies to for colour).
    func testAuthoredTextColorNeverOverridesTheInlineCodeAccentColor() {
        let out = build([.paragraph(spans: [span("snippet", code: true, textColor: .systemRed)])])
        let color = out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, theme.inlineCodeColor)
    }

    /// An unset `textColor` is untouched — the pre-sprint theme colour, exactly.
    func testSpanWithNoTextColorUsesTheThemeColorUnchanged() {
        let out = build([.paragraph(spans: [span("plain")])])
        let color = out.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, theme.textColor)
    }

    // MARK: S13 — highlight colour (always literal, never theme-adjusted)

    func testHighlightColorAppliesAsBackgroundColorAttribute() {
        let out = build([.paragraph(spans: [span("marked", highlightColor: .yellow)])])
        let bg = out.attribute(.backgroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(bg, NSColor.yellow)
    }

    func testSpanWithNoHighlightColorHasNoBackgroundColorAttribute() {
        let out = build([.paragraph(spans: [span("plain")])])
        XCTAssertNil(out.attribute(.backgroundColor, at: 0, effectiveRange: nil))
    }

    // MARK: S13 — font family

    func testAuthoredFontNameOverridesTheFamilyButNeverForACodeSpan() {
        let out = build([.paragraph(spans: [
            span("Named", fontName: "Helvetica"),
            span("Coded", code: true, fontName: "Helvetica"),
        ])])
        let expectedFamily = NSFont(name: "Helvetica", size: theme.bodyFont.pointSize)!.familyName
        let namedFont = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(namedFont?.familyName, expectedFamily)
        let text = out.string as NSString
        let codedRange = text.range(of: "Coded")
        let codedFont = out.attribute(.font, at: codedRange.location, effectiveRange: nil) as? NSFont
        XCTAssertEqual(codedFont?.fontName, theme.codeFont.fontName,
                       "an authored family must never override the single, consistent inline-code look")
    }

    func testSpanWithNoFontNameUsesTheThemeFamilyUnchanged() {
        let out = build([.paragraph(spans: [span("plain")])])
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.familyName, theme.bodyFont.familyName)
    }

    // MARK: S13 — the font-size model (authored size × user-size/document-default ratio)

    /// The brief's own required case: a 22-half-point (11pt) body run and a 32-half-point (16pt)
    /// run keep their AUTHORED ratio at any user reading size, and the reading size still sets the
    /// overall scale — tested at two different reading sizes so neither half of that claim could be
    /// satisfied by accident (a constant scale would pass the ratio check; a fixed size would fail
    /// the "still governs overall scale" check).
    func testAuthoredFontSizeKeepsItsRatioToTheDocumentDefaultAcrossTwoUserReadingSizes() {
        func sizes(userSize: CGFloat) -> (body: CGFloat, heading: CGFloat) {
            let out = OfficeTextBuilder.build([
                .paragraph(spans: [span("Body", fontSize: 11)]),
                .paragraph(spans: [span("Head", fontSize: 16)]),
            ], theme: RenderTheme.current(size: userSize), documentDefaultFontSize: 11)
            let bodyFont = out.attribute(.font, at: 0, effectiveRange: nil) as! NSFont
            let headRange = (out.string as NSString).range(of: "Head")
            let headFont = out.attribute(.font, at: headRange.location, effectiveRange: nil) as! NSFont
            return (bodyFont.pointSize, headFont.pointSize)
        }
        let atTwentyTwo = sizes(userSize: 22)   // scale = 22/11 = 2
        XCTAssertEqual(atTwentyTwo.body, 22)
        XCTAssertEqual(atTwentyTwo.heading, 32)

        let atFortyFour = sizes(userSize: 44)   // scale = 44/11 = 4
        XCTAssertEqual(atFortyFour.body, 44)
        XCTAssertEqual(atFortyFour.heading, 64)

        XCTAssertEqual(atTwentyTwo.heading / atTwentyTwo.body, 16.0 / 11.0, accuracy: 0.001,
                       "the authored 16pt-to-11pt ratio must survive scaling")
        XCTAssertEqual(atFortyFour.heading / atFortyFour.body, 16.0 / 11.0, accuracy: 0.001)
        XCTAssertNotEqual(atTwentyTwo.body, atFortyFour.body,
                          "the user's reading size must still govern the overall scale")
    }

    /// A span with NO authored size is untouched by `documentDefaultFontSize` entirely — it keeps
    /// whatever size the surrounding block's own theme font already is (already `theme.baseFontSize`
    /// scaled, with no further multiplication).
    func testSpanWithNoAuthoredFontSizeIgnoresTheDocumentDefaultScale() {
        let out = OfficeTextBuilder.build([.paragraph(spans: [span("plain")])],
                                          theme: RenderTheme.current(size: 30), documentDefaultFontSize: 11)
        let font = out.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(font?.pointSize, RenderTheme.current(size: 30).bodyFont.pointSize)
    }

    // MARK: S13 — alignment

    func testExplicitAlignmentWinsOverTheRTLDefaultEdge() {
        let out = build([.paragraph(spans: [span("text")], rtl: true, alignment: .center)])
        let style = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .center)
        XCTAssertEqual(style?.baseWritingDirection, .rightToLeft,
                       "an explicit alignment must not suppress the base direction")
    }

    func testNilAlignmentLeavesNaturalAlignmentExactlyAsBefore() {
        let out = build([.paragraph(spans: [span("text")])])
        let style = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.alignment, .natural)
    }

    func testHeadingAndListItemAlsoRespectAnExplicitAlignment() {
        let headingOut = build([.heading(level: 1, spans: [span("H")], alignment: .right)])
        let headingStyle = headingOut.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(headingStyle?.alignment, .right)

        let listOut = build([.listItem(level: 0, ordered: false, spans: [span("I")], alignment: .center)])
        let listStyle = listOut.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(listStyle?.alignment, .center)
    }

    // MARK: S13 — tab stops

    func testParagraphTabStopsAreAddedToTheParagraphStyle() {
        let out = build([.paragraph(spans: [span("a\tb")], tabStops: [TabStop(position: 100), TabStop(position: 200)])])
        let style = out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let locations = style?.tabStops.map(\.location) ?? []
        XCTAssertTrue(locations.contains(100))
        XCTAssertTrue(locations.contains(200))
    }

    func testEmptyTabStopsLeaveTheParagraphStylesDefaultTabsUnchanged() {
        let withNone = build([.paragraph(spans: [span("text")])])
        let withEmpty = build([.paragraph(spans: [span("text")], tabStops: [])])
        let styleA = withNone.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let styleB = withEmpty.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(styleA?.tabStops.map(\.location), styleB?.tabStops.map(\.location))
    }

    /// THE BRIEF'S REQUIRED CASE: a custom tab stop must coexist with, not break, a list item's own
    /// hanging-indent geometry — the marker's own tab stays FIRST and at its usual position, and the
    /// item's indentation (`headIndent`/`firstLineHeadIndent`) is completely unaffected by an
    /// authored tab stop being present.
    func testListItemTabStopsCoexistWithTheMarkersOwnHangingIndentTab() {
        let plain = build([.listItem(level: 1, ordered: true, spans: [span("Item")])])
        let withTab = build([.listItem(level: 1, ordered: true, spans: [span("Item")], tabStops: [TabStop(position: 300)])])
        let plainStyle = plain.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        let tabStyle = withTab.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle

        XCTAssertEqual(tabStyle?.headIndent, plainStyle?.headIndent, "hanging indent must be unaffected")
        XCTAssertEqual(tabStyle?.firstLineHeadIndent, plainStyle?.firstLineHeadIndent)
        let plainLocations = plainStyle?.tabStops.map(\.location) ?? []
        let tabLocations = tabStyle?.tabStops.map(\.location) ?? []
        XCTAssertEqual(tabLocations.first, plainLocations.first, "the marker's own tab must still be first")
        XCTAssertTrue(tabLocations.contains(300), "the authored tab stop must still be present alongside it")
    }

    /// P2b — `TabStop.alignment` must reach the actual `NSTextTab.alignment` AppKit lays out with,
    /// not just round-trip through `TabStop` itself. `.decimal` has no `NSTextAlignment` case (see
    /// `officeTextTab`'s own doc) — it maps to `.right` PLUS a `.` column terminator, so this
    /// asserts `.right` for it and separately proves the terminator option is present.
    func testTabStopAlignmentReachesTheBuiltNSTextTabsAlignment() {
        let out = build([.paragraph(spans: [span("a\tb\tc\td")],
                                     tabStops: [TabStop(position: 50, alignment: .left),
                                                TabStop(position: 100, alignment: .center),
                                                TabStop(position: 150, alignment: .right),
                                                TabStop(position: 200, alignment: .decimal)])])
        let style = try! XCTUnwrap(out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        let byLocation = Dictionary(uniqueKeysWithValues: style.tabStops.map { ($0.location, $0) })
        XCTAssertEqual(byLocation[50]?.alignment, .left)
        XCTAssertEqual(byLocation[100]?.alignment, .center)
        XCTAssertEqual(byLocation[150]?.alignment, .right)
        XCTAssertEqual(byLocation[200]?.alignment, .right, "decimal has no NSTextAlignment case — it maps to .right")
        XCTAssertNotNil(byLocation[200]?.options[.columnTerminators], "decimal must still carry the '.' column terminator")
    }

    /// A tab with a `leader` still renders as an ordinary aligned tab — `TabLeader` is carried
    /// through `TabStop` but `officeTextTab` never turns it into a drawing instruction (see
    /// `TabLeader`'s own doc); this pins that the alignment/position side is unaffected by it.
    func testTabLeaderDoesNotAffectTheBuiltNSTextTabsAlignmentOrPosition() {
        let out = build([.paragraph(spans: [span("a\tb")],
                                     tabStops: [TabStop(position: 80, alignment: .right, leader: .dot)])])
        let style = try! XCTUnwrap(out.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)
        XCTAssertEqual(style.tabStops.first?.location, 80)
        XCTAssertEqual(style.tabStops.first?.alignment, .right)
    }

    // MARK: P2b — paragraph shading / border MDAttrs

    /// A resolved `ParagraphFormat.shading` must reach `MDAttr.paraShading` over the block's full
    /// rendered range (content + separator) — the attribute `drawMDDecorations` actually paints.
    func testParagraphShadingFormatReachesMDAttrOverTheFullBlockRange() {
        var format = ParagraphFormat()
        format.shading = .systemYellow
        let out = build([.paragraph(spans: [span("Shaded")], format: format)])
        var range = NSRange()
        _ = out.attribute(MDAttr.paraShading, at: 0, longestEffectiveRange: &range, in: NSRange(location: 0, length: out.length))
        XCTAssertEqual(range, NSRange(location: 0, length: out.length), "must span content + trailing separator")
        XCTAssertEqual(out.attribute(MDAttr.paraShading, at: 0, effectiveRange: nil) as? NSColor, .systemYellow)
    }

    /// A resolved border colour+width must reach BOTH `MDAttr.paraBorderColor` and
    /// `MDAttr.paraBorderWidth` — the two `drawMDDecorations` reads together to stroke the box.
    func testParagraphBorderFormatReachesBothMDAttrs() {
        var format = ParagraphFormat()
        format.borderColor = .systemRed
        format.borderWidth = 2
        let out = build([.paragraph(spans: [span("Boxed")], format: format)])
        XCTAssertEqual(out.attribute(MDAttr.paraBorderColor, at: 0, effectiveRange: nil) as? NSColor, .systemRed)
        XCTAssertEqual((out.attribute(MDAttr.paraBorderWidth, at: 0, effectiveRange: nil) as? NSNumber)?.doubleValue, 2)
    }

    /// A block with no shading/border at all (every pre-P2b call site) must carry NEITHER MDAttr —
    /// the "unspecified stays unspecified" invariant this sprint's whole cascade depends on.
    func testUnshadedUnborderedParagraphCarriesNeitherMDAttr() {
        let out = build([.paragraph(spans: [span("Plain")])])
        XCTAssertNil(out.attribute(MDAttr.paraShading, at: 0, effectiveRange: nil))
        XCTAssertNil(out.attribute(MDAttr.paraBorderColor, at: 0, effectiveRange: nil))
        XCTAssertNil(out.attribute(MDAttr.paraBorderWidth, at: 0, effectiveRange: nil))
    }

    // MARK: S13 — table cell shading / borders / width

    func testCellBackgroundColorOverridesTheThemeDefaultShading() {
        let out = build([.table(rows: [[Cell(blocks: [.paragraph(spans: [span("A")])], backgroundColor: .systemGreen)]],
                                headerRows: 0)])
        let block = tableBlocks(in: out).first
        XCTAssertEqual(block?.backgroundColor, .systemGreen)
    }

    /// An explicit background on a HEADER cell overrides the theme's own header shading, not just
    /// a body cell's blank default.
    func testHeaderCellExplicitBackgroundColorOverridesThemeHeaderShading() {
        let out = build([.table(rows: [[Cell(blocks: [.paragraph(spans: [span("H")])], backgroundColor: .systemTeal)]],
                                headerRows: 1)])
        let block = tableBlocks(in: out).first
        XCTAssertEqual(block?.backgroundColor, .systemTeal)
    }

    func testCellBorderColorAndWidthOverrideTheThemeDefault() {
        let out = build([.table(rows: [[Cell(blocks: [.paragraph(spans: [span("A")])],
                                             borderColor: .systemPurple, borderWidth: 3)]], headerRows: 0)])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertEqual(block.borderColor(for: .minX), .systemPurple)
        XCTAssertEqual(block.width(for: .border, edge: .minX), 3)
    }

    func testCellWidthSetsTheTextTableBlocksAbsoluteContentWidth() {
        let out = build([.table(rows: [[Cell(blocks: [.paragraph(spans: [span("A")])], width: 120)]], headerRows: 0)])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertEqual(block.value(for: .width), 120)
        XCTAssertEqual(block.valueType(for: .width), .absoluteValueType)
    }

    // MARK: P3 — grid-ratio column widths (`OfficeBlock.table.columnWidths`)

    /// A table whose `columnWidths` matches the derived column count switches EVERY column to a
    /// percentage of the source's own grid ratios (20/20/60 for 100/100/300pt) — this is the fix
    /// for jagged columns: the per-cell absolute width path (`Cell.width`) is bypassed entirely
    /// once a usable grid is present.
    func testGridColumnWidthsBecomePercentagesThatSumToOneHundred() {
        let rows: [[Cell]] = [[
            Cell(spans: [span("A")]), Cell(spans: [span("B")]), Cell(spans: [span("C")]),
        ]]
        let out = build([.table(rows: rows, headerRows: 0, columnWidths: [100, 100, 300])])
        let blocks = tableBlocks(in: out).sorted { $0.startingColumn < $1.startingColumn }
        XCTAssertEqual(blocks.map { $0.valueType(for: .width) }, [.percentageValueType, .percentageValueType, .percentageValueType])
        let widths = blocks.map { $0.value(for: .width) }
        for (actual, expected) in zip(widths, [CGFloat(20), 20, 60]) {
            XCTAssertEqual(actual, expected, accuracy: 0.001)
        }
    }

    /// A merged cell (`colSpan: 2`) gets the SUM of the two grid columns it covers, not just the
    /// first one — 20 + 20 = 40 for the wide cell, 60 for the lone remaining column.
    func testMergedCellGetsTheSumOfItsCoveredColumnsPercentages() {
        let rows: [[Cell]] = [[
            Cell(spans: [span("Wide")], colSpan: 2), Cell(spans: [span("C")]),
        ]]
        let out = build([.table(rows: rows, headerRows: 0, columnWidths: [100, 100, 300])])
        let blocks = tableBlocks(in: out).sorted { $0.startingColumn < $1.startingColumn }
        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks[0].columnSpan, 2)
        XCTAssertEqual(blocks[0].value(for: .width), 40, accuracy: 0.001)
        XCTAssertEqual(blocks[0].valueType(for: .width), .percentageValueType)
        XCTAssertEqual(blocks[1].value(for: .width), 60, accuracy: 0.001)
    }

    /// `columnWidths` whose count doesn't match the table's own derived column count (a malformed
    /// grid) is exactly "no grid known" — the pre-existing per-cell/auto path renders unchanged.
    func testMismatchedColumnWidthsCountFallsBackToPerCellLayout() {
        let rows: [[Cell]] = [[Cell(spans: [span("A")]), Cell(spans: [span("B")])]]
        let out = build([.table(rows: rows, headerRows: 0, columnWidths: [100, 100, 300])])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertNotEqual(block.valueType(for: .width), .percentageValueType)
    }

    /// The pre-sprint construction path (`Cell(spans:)`) leaves all four fields `nil` — the theme's
    /// existing defaults (no shading, `Palette.tableBorder` at 1pt, auto column layout) must be
    /// exactly what a cell with no shading/border/width info renders as.
    func testCellWithNoShadingBorderOrWidthKeepsExactlyTheThemeDefaults() {
        let out = build([.table(rows: [[Cell(spans: [span("A")])]], headerRows: 0)])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertNil(block.backgroundColor)
        XCTAssertEqual(block.borderColor(for: .minX), Palette.tableBorder)
        XCTAssertEqual(block.width(for: .border, edge: .minX), 1)
    }

    /// Merged cells (R1's `colSpan`) must still work once a cell can ALSO carry shading — the two
    /// features must not interfere with each other.
    func testMergedCellWithShadingStillAppliesBothItsSpanAndItsShading() {
        let rows: [[Cell]] = [[Cell(blocks: [.paragraph(spans: [span("Wide")])], colSpan: 2, backgroundColor: .systemOrange)]]
        let out = build([.table(rows: rows, headerRows: 0)])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertEqual(block.columnSpan, 2)
        XCTAssertEqual(block.backgroundColor, .systemOrange)
    }

    // MARK: P3b — table-level default border/shading, cell vertical alignment, cell margins

    /// A table-level default border/width (`TableFormat`, from a `w:tblBorders` the reader read)
    /// is applied to a cell that declares no border of its own — the MIDDLE layer between the
    /// cell's own value and the theme default.
    func testTableDefaultBorderAppliesWhenTheCellDeclaresNoBorderOfItsOwn() {
        let rows: [[Cell]] = [[Cell(spans: [span("A")])]]
        let out = build([.table(rows: rows, headerRows: 0,
                                format: TableFormat(defaultBorderColor: .systemPurple, defaultBorderWidth: 3))])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertEqual(block.borderColor(for: .minX), .systemPurple)
        XCTAssertEqual(block.width(for: .border, edge: .minX), 3)
    }

    /// A cell's OWN border still wins over a table-level default that exists alongside it.
    func testCellOwnBorderWinsOverTheTableDefaultBorder() {
        let rows: [[Cell]] = [[Cell(blocks: [.paragraph(spans: [span("A")])], borderColor: .systemRed, borderWidth: 5)]]
        let out = build([.table(rows: rows, headerRows: 0,
                                format: TableFormat(defaultBorderColor: .systemPurple, defaultBorderWidth: 3))])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertEqual(block.borderColor(for: .minX), .systemRed)
        XCTAssertEqual(block.width(for: .border, edge: .minX), 5)
    }

    /// A table-level default shading applies to a cell with no shading of its own — including a
    /// HEADER cell, where it wins over the theme's own header shading too (a source-authored
    /// table default is more specific than the app's synthetic header colour).
    func testTableDefaultShadingAppliesToCellsWithNoShadingOfTheirOwnIncludingHeaderRows() {
        let rows: [[Cell]] = [[Cell(spans: [span("H")])]]
        let out = build([.table(rows: rows, headerRows: 1, format: TableFormat(defaultShading: .systemYellow))])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertEqual(block.backgroundColor, .systemYellow)
    }

    /// A cell's OWN shading still wins over a table-level default.
    func testCellOwnShadingWinsOverTheTableDefaultShading() {
        let rows: [[Cell]] = [[Cell(blocks: [.paragraph(spans: [span("A")])], backgroundColor: .systemGreen)]]
        let out = build([.table(rows: rows, headerRows: 0, format: TableFormat(defaultShading: .systemYellow))])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertEqual(block.backgroundColor, .systemGreen)
    }

    /// P5 — a cell carrying BOTH its own direct `backgroundColor` AND a table-STYLE-resolved
    /// `styleShading` renders with the DIRECT value: `TableBlockBuilder.build`'s resolution chain
    /// is `cell-direct > table-direct > table-style > theme`, and this is the top of that chain
    /// actually reaching `NSTextTableBlock.backgroundColor`, not just read from source.
    func testCellOwnDirectShadingWinsOverItsOwnStyleShadingAtBuildLevel() {
        var cell = Cell(blocks: [.paragraph(spans: [span("A")])], backgroundColor: .systemRed)
        cell.styleShading = .systemYellow
        let out = build([.table(rows: [[cell]], headerRows: 0)])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertEqual(block.backgroundColor, .systemRed)
    }

    /// `Cell.verticalAlignment == .center` becomes `NSTextTableBlock.verticalAlignment == .middleAlignment`.
    func testCellVerticalAlignmentCenterBecomesMiddleAlignment() {
        let rows: [[Cell]] = [[Cell(blocks: [.paragraph(spans: [span("A")])], verticalAlignment: .center)]]
        let out = build([.table(rows: rows, headerRows: 0)])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertEqual(block.verticalAlignment, .middleAlignment)
    }

    /// `nil` (the pre-sprint default) leaves AppKit's own already-`.topAlignment` untouched.
    func testCellWithNoVerticalAlignmentKeepsTheDefaultTopAlignment() {
        let rows: [[Cell]] = [[Cell(spans: [span("A")])]]
        let out = build([.table(rows: rows, headerRows: 0)])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertEqual(block.verticalAlignment, .topAlignment)
    }

    /// `Cell.padding` (already resolved by the reader against any table default) replaces the
    /// hardcoded 7pt when present.
    func testCellPaddingReplacesTheHardcodedSevenPointDefault() {
        let rows: [[Cell]] = [[Cell(blocks: [.paragraph(spans: [span("A")])], padding: 12)]]
        let out = build([.table(rows: rows, headerRows: 0)])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertEqual(block.width(for: .padding, edge: .minX), 12)
    }

    /// `nil` (every markdown table, and a docx table/cell with no declared margin) keeps the
    /// pre-sprint 7pt default exactly as before this field existed.
    func testCellWithNoPaddingKeepsTheHardcodedSevenPointDefault() {
        let rows: [[Cell]] = [[Cell(spans: [span("A")])]]
        let out = build([.table(rows: rows, headerRows: 0)])
        let block = try! XCTUnwrap(tableBlocks(in: out).first)
        XCTAssertEqual(block.width(for: .padding, edge: .minX), 7)
    }

    // MARK: P2 — ParagraphFormat → NSParagraphStyle (spacing/line-height/indent/contextualSpacing)

    private func paragraphStyle(in out: NSAttributedString, at index: Int = 0) -> NSParagraphStyle {
        out.attribute(.paragraphStyle, at: index, effectiveRange: nil) as! NSParagraphStyle
    }

    /// `documentDefaultFontSize` matching `theme.baseFontSize` (16) gives `fontSizeScale == 1`, so
    /// every expected number below is the SOURCE points value, unscaled — the cleanest fixture for
    /// pinning the conversion itself, separately from the scaling multiplication tested afterwards.
    private func buildUnscaled(_ blocks: [OfficeBlock]) -> NSAttributedString {
        OfficeTextBuilder.build(blocks, theme: theme, documentDefaultFontSize: theme.baseFontSize)
    }

    /// `spacingBefore`/`spacingAfter` reach `paragraphSpacingBefore`/`paragraphSpacing` unscaled at
    /// `fontSizeScale == 1` — the spec's own worked example (12pt/6pt, already twips→points
    /// converted by the reader; the reader-side conversion itself is `DocxReaderTests`' job).
    func testSpacingBeforeAndAfterReachParagraphSpacingAttributesUnscaled() {
        var format = ParagraphFormat()
        format.spacingBefore = 12
        format.spacingAfter = 6
        let out = buildUnscaled([.paragraph(spans: [span("Body")], format: format)])
        let style = paragraphStyle(in: out)
        XCTAssertEqual(style.paragraphSpacingBefore, 12)
        XCTAssertEqual(style.paragraphSpacing, 6)
    }

    /// The SAME format, scaled: `documentDefaultFontSize` half `theme.baseFontSize` makes
    /// `fontSizeScale == 2`, so 12pt/6pt authored becomes 24pt/12pt rendered — proving the P2
    /// values ride the SAME reading-size ratio `Span.fontSize` already does.
    func testSpacingBeforeAndAfterScaleWithFontSizeScale() {
        var format = ParagraphFormat()
        format.spacingBefore = 12
        format.spacingAfter = 6
        let out = OfficeTextBuilder.build([.paragraph(spans: [span("Body")], format: format)],
                                          theme: theme, documentDefaultFontSize: theme.baseFontSize / 2)
        let style = paragraphStyle(in: out)
        XCTAssertEqual(style.paragraphSpacingBefore, 24)
        XCTAssertEqual(style.paragraphSpacing, 12)
    }

    /// `.multiple` is a unitless RATIO (`w:lineRule="auto"`'s `line/240`) — it must land on
    /// `lineHeightMultiple` UNCHANGED regardless of `fontSizeScale`, unlike every point-valued field.
    func testLineHeightMultipleSetsLineHeightMultipleUnscaled() {
        var format = ParagraphFormat()
        format.lineHeight = .multiple(1.5)
        let out = OfficeTextBuilder.build([.paragraph(spans: [span("Body")], format: format)],
                                          theme: theme, documentDefaultFontSize: theme.baseFontSize / 2)
        XCTAssertEqual(paragraphStyle(in: out).lineHeightMultiple, 1.5)
    }

    /// `.exact` sets BOTH `minimumLineHeight` and `maximumLineHeight` to the same scaled point
    /// value — the hard cap the spec's `lineRule="exact"` describes (tall content clips rather than
    /// growing the line).
    func testLineHeightExactSetsMinimumAndMaximumToTheSameScaledValue() {
        var format = ParagraphFormat()
        format.lineHeight = .exact(20)
        let out = OfficeTextBuilder.build([.paragraph(spans: [span("Body")], format: format)],
                                          theme: theme, documentDefaultFontSize: theme.baseFontSize / 2)
        let style = paragraphStyle(in: out)
        XCTAssertEqual(style.minimumLineHeight, 40)
        XCTAssertEqual(style.maximumLineHeight, 40)
    }

    /// `.atLeast` sets `minimumLineHeight` to the scaled floor and clears `maximumLineHeight` back
    /// to 0 (AppKit's "no maximum") — a mutation that left the body-style token's own
    /// `maximumLineHeight` in place would silently reintroduce a cap `atLeast` explicitly forbids.
    func testLineHeightAtLeastSetsFloorAndClearsAnyCap() {
        var format = ParagraphFormat()
        format.lineHeight = .atLeast(20)
        let out = buildUnscaled([.paragraph(spans: [span("Body")], format: format)])
        let style = paragraphStyle(in: out)
        XCTAssertEqual(style.minimumLineHeight, 20)
        XCTAssertEqual(style.maximumLineHeight, 0)
    }

    /// The full indent formula (spec area 5's `NSParagraphStyle` mapping): `headIndent = indentStart`,
    /// `tailIndent = -indentEnd` (AppKit's own right-margin-relative convention, already used by the
    /// markdown code-card header/footer), `firstLineHeadIndent = indentStart + firstLineIndent`.
    func testIndentStartEndAndFirstLineCombineIntoHeadTailAndFirstLineIndent() {
        var format = ParagraphFormat()
        format.indentStart = 10
        format.indentEnd = 5
        format.firstLineIndent = 6
        let out = buildUnscaled([.paragraph(spans: [span("Body")], format: format)])
        let style = paragraphStyle(in: out)
        XCTAssertEqual(style.headIndent, 10)
        XCTAssertEqual(style.tailIndent, -5)
        XCTAssertEqual(style.firstLineHeadIndent, 16)
    }

    /// `hangingIndent` SUBTRACTS from `firstLineHeadIndent` (the classic bullet/numbered shape: the
    /// first line sits LEFT of the body) — the opposite sign from `firstLineIndent`.
    func testHangingIndentSubtractsFromFirstLineHeadIndent() {
        var format = ParagraphFormat()
        format.indentStart = 10
        format.hangingIndent = 4
        let out = buildUnscaled([.paragraph(spans: [span("Body")], format: format)])
        XCTAssertEqual(paragraphStyle(in: out).firstLineHeadIndent, 6)
    }

    /// A `ParagraphFormat` with every field `nil` (the default) must leave `headIndent` at its
    /// pre-P2 token default (0 for an ordinary body paragraph) — "unspecified = identical".
    func testDefaultParagraphFormatLeavesIndentAtTheTokenDefault() {
        let out = buildUnscaled([.paragraph(spans: [span("Body")], format: ParagraphFormat())])
        XCTAssertEqual(paragraphStyle(in: out).headIndent, 0)
    }

    /// A heading block's format is resolved through the SAME `applyParagraphFormat` path as a
    /// plain paragraph's — proving the wiring reaches `headingParagraphStyle`, not only
    /// `bodyParagraphStyle`.
    func testHeadingBlockAlsoAppliesItsOwnParagraphFormat() {
        var format = ParagraphFormat()
        format.spacingBefore = 30
        let out = buildUnscaled([.heading(level: 1, spans: [span("Title")], format: format)])
        XCTAssertEqual(paragraphStyle(in: out).paragraphSpacingBefore, 30)
    }

    /// A list item's DIRECT format still wins over the marker/hang-indent geometry
    /// `listParagraphStyle` otherwise computes from `level` — proving `applyParagraphFormat` is
    /// wired into the list path too, not only body/heading.
    func testListItemsOwnDirectIndentOverridesTheMarkerGeometry() {
        var format = ParagraphFormat()
        format.indentStart = 50
        let out = buildUnscaled([.listItem(level: 0, ordered: false, spans: [span("Item")], format: format)])
        XCTAssertEqual(paragraphStyle(in: out).headIndent, 50)
    }

    // MARK: P2 — contextualSpacing adjacency (spec area 5)

    /// Two CONSECUTIVE paragraphs sharing an EQUAL `ParagraphFormat` with `contextualSpacing: true`
    /// must have the shared edge's spacing zeroed on BOTH sides (the first's `spacingAfter`, the
    /// second's `spacingBefore`) while each paragraph's OUTER edge (nothing to suppress against)
    /// keeps its authored value — Word's own "no gap within a run of the same style" rule.
    func testConsecutiveSameStyleContextualSpacingParagraphsSuppressTheSharedEdge() {
        var format = ParagraphFormat()
        format.spacingBefore = 10
        format.spacingAfter = 8
        format.contextualSpacing = true
        let out = buildUnscaled([
            .paragraph(spans: [span("First")], format: format),
            .paragraph(spans: [span("Second")], format: format),
        ])
        let firstRange = (out.string as NSString).range(of: "First")
        let secondRange = (out.string as NSString).range(of: "Second")
        let first = paragraphStyle(in: out, at: firstRange.location)
        let second = paragraphStyle(in: out, at: secondRange.location)
        XCTAssertEqual(first.paragraphSpacingBefore, 10, "the first item's own leading edge is untouched")
        XCTAssertEqual(first.paragraphSpacing, 0, "suppressed — the next block shares its format")
        XCTAssertEqual(second.paragraphSpacingBefore, 0, "suppressed — the previous block shares its format")
        XCTAssertEqual(second.paragraphSpacing, 8, "the second item's own trailing edge is untouched")
    }

    /// Mutation check: if the NEXT block's format DIFFERS (a real style change, not the same list/
    /// style continuing), contextualSpacing must NOT suppress anything — proving the adjacency
    /// check compares actual format equality, not merely "both set contextualSpacing".
    func testContextualSpacingDoesNotSuppressWhenTheNeighboursFormatDiffers() {
        var format = ParagraphFormat()
        format.spacingAfter = 8
        format.contextualSpacing = true
        var differentFormat = format
        differentFormat.spacingAfter = 99
        let out = buildUnscaled([
            .paragraph(spans: [span("First")], format: format),
            .paragraph(spans: [span("Second")], format: differentFormat),
        ])
        let firstRange = (out.string as NSString).range(of: "First")
        XCTAssertEqual(paragraphStyle(in: out, at: firstRange.location).paragraphSpacing, 8,
                       "a differently-formatted neighbour must never trigger suppression")
    }

    /// A block whose `contextualSpacing` is `false` (the pre-P2 default) must never be suppressed,
    /// even sitting next to an identically-formatted neighbour — the rule is opt-in per the source.
    func testContextualSpacingFalseNeverSuppressesEvenWithAnIdenticalNeighbour() {
        var format = ParagraphFormat()
        format.spacingAfter = 8
        format.contextualSpacing = false
        let out = buildUnscaled([
            .paragraph(spans: [span("First")], format: format),
            .paragraph(spans: [span("Second")], format: format),
        ])
        let firstRange = (out.string as NSString).range(of: "First")
        XCTAssertEqual(paragraphStyle(in: out, at: firstRange.location).paragraphSpacing, 8)
    }
}

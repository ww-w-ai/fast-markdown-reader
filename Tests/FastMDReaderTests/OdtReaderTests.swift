import XCTest
@testable import FastMDReader

/// `OdtReader` is pure: build an `.odt`-shaped ZIP by hand (stored entries only), hand it to
/// `ZipArchive`, then `OdtReader.read`, and assert on the `[OfficeBlock]` that comes back. Same
/// shape as `DocxReaderTests` — no fixture files on disk, no view, no document.
final class OdtReaderTests: XCTestCase {
    // MARK: Fixture construction — a real (stored-only) ZIP, built in memory

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    private func buildOdt(content: String, styles: String? = nil) -> Data {
        var entries: [(String, Data)] = [("content.xml", Data(content.utf8))]
        if let styles { entries.append(("styles.xml", Data(styles.utf8))) }
        return buildZip(entries)
    }

    private func buildZip(_ entries: [(name: String, content: Data)]) -> Data {
        struct Prepared { let nameBytes: [UInt8]; let content: Data; let localOffset: Int }
        var body = [UInt8]()
        var prepared: [Prepared] = []
        for (name, content) in entries {
            let nameBytes = Array(name.utf8)
            let localOffset = body.count
            body += le32(0x0403_4b50)
            body += le16(20)
            body += le16(0)
            body += le16(0)
            body += le16(0) + le16(0)
            body += le32(0)
            body += le32(UInt32(content.count))
            body += le32(UInt32(content.count))
            body += le16(UInt16(nameBytes.count))
            body += le16(0)
            body += nameBytes
            body += Array(content)
            prepared.append(Prepared(nameBytes: nameBytes, content: content, localOffset: localOffset))
        }
        var centralDirectory = [UInt8]()
        for p in prepared {
            centralDirectory += le32(0x0201_4b50)
            centralDirectory += le16(20) + le16(20)
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le16(0) + le16(0)
            centralDirectory += le32(0)
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le16(UInt16(p.nameBytes.count))
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le16(0)
            centralDirectory += le32(0)
            centralDirectory += le32(UInt32(p.localOffset))
            centralDirectory += p.nameBytes
        }
        let centralDirectoryOffset = body.count
        var archive = body + centralDirectory
        archive += le32(0x0605_4b50)
        archive += le16(0) + le16(0)
        archive += le16(UInt16(entries.count))
        archive += le16(UInt16(entries.count))
        archive += le32(UInt32(centralDirectory.count))
        archive += le32(UInt32(centralDirectoryOffset))
        archive += le16(0)
        return Data(archive)
    }

    /// Wraps a body fragment in the minimal `office:document-content` shell every real ODT carries,
    /// with automatic-styles injected so tests can declare list/text styles inline.
    private func doc(body: String, automaticStyles: String = "") -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content>
          <office:automatic-styles>\(automaticStyles)</office:automatic-styles>
          <office:body><office:text>\(body)</office:text></office:body>
        </office:document-content>
        """
    }

    private func read(body: String, automaticStyles: String = "", styles: String? = nil) throws -> [OfficeBlock] {
        let zip = buildOdt(content: doc(body: body, automaticStyles: automaticStyles), styles: styles)
        let archive = try ZipArchive(data: zip)
        return try OdtReader.read(archive)
    }

    private func readWithMedia(body: String, media: [(name: String, bytes: [UInt8])]) throws -> [OfficeBlock] {
        var entries: [(String, Data)] = [("content.xml", Data(doc(body: body).utf8))]
        for (name, bytes) in media { entries.append((name, Data(bytes))) }
        let archive = try ZipArchive(data: buildZip(entries))
        return try OdtReader.read(archive)
    }

    // MARK: Headings

    func testOutlineLevelsOneThroughSixMapDirectlyToHeadingLevels() throws {
        let paragraphs = (1...6).map { "<text:h text:outline-level=\"\($0)\">H\($0)</text:h>" }
        let blocks = try read(body: paragraphs.joined())
        XCTAssertEqual(blocks, (1...6).map { .heading(level: $0, spans: [Span(text: "H\($0)")]) })
    }

    func testOutlineLevelSevenAndAboveClampsToHeadingLevelSix() throws {
        let blocks = try read(body: "<text:h text:outline-level=\"9\">Deep</text:h>")
        XCTAssertEqual(blocks, [.heading(level: 6, spans: [Span(text: "Deep")])])
    }

    // MARK: Paragraphs + span reassembly with mixed content ordering

    func testPlainParagraphIsText() throws {
        let blocks = try read(body: "<text:p>Hello, world.</text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Hello, world.")])])
    }

    func testConsecutiveSpansWithIdenticalStylingReassembleAcrossBareTextInterleaving() throws {
        let blocks = try read(
            body: """
            <text:p>before <text:span text:style-name="B">bold </text:span><text:span text:style-name="B">still bold</text:span> after</text:p>
            """,
            automaticStyles: """
            <style:style style:name="B" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "before "),
            Span(text: "bold still bold", bold: true),
            Span(text: " after"),
        ])])
    }

    // MARK: Unit conversion

    func testUnitConversionsMatchMeasuredRealFileValues() throws {
        let cases: [(width: String, expectedPt: CGFloat)] = [
            ("7.938cm", 225.0), ("5.292cm", 150.0), ("1in", 72), ("72pt", 72), ("100", 100),
        ]
        for (index, testCase) in cases.enumerated() {
            let blocks = try readWithMedia(
                body: """
                <text:p><draw:frame svg:width="\(testCase.width)" svg:height="\(testCase.width)">
                <draw:image xlink:href="Pictures/img\(index).png"/></draw:frame></text:p>
                """,
                media: [(name: "Pictures/img\(index).png", bytes: [0x01])])
            guard case .image(_, let size) = blocks.first else { return XCTFail("expected an image block") }
            XCTAssertEqual(size.width, testCase.expectedPt, accuracy: 0.02, "width '\(testCase.width)'")
        }
    }

    // MARK: Images

    func testEmbeddedImageResolvesToArchiveEntryNameAndDeclaredSize() throws {
        let blocks = try readWithMedia(
            body: """
            <text:p><draw:frame svg:width="225pt" svg:height="168.75pt">
            <draw:image xlink:href="Pictures/photo.png"/></draw:frame></text:p>
            """,
            media: [(name: "Pictures/photo.png", bytes: [0x01, 0x02])])
        XCTAssertEqual(blocks, [.image(id: "Pictures/photo.png", size: CGSize(width: 225, height: 168.75))])
    }

    func testHrefNotPresentInArchiveEmitsUnresolvableSizedImageNeverZeroOrDropped() throws {
        let blocks = try read(body: """
        <text:p><draw:frame svg:width="100pt" svg:height="50pt">
        <draw:image xlink:href="Pictures/missing.png"/></draw:frame></text:p>
        """)
        XCTAssertEqual(blocks, [.image(id: "odt-unresolvable:Pictures/missing.png", size: CGSize(width: 100, height: 50))])
    }

    func testFrameWithNoDeclaredSizeFallsBackToNonZeroPlaceholder() throws {
        let blocks = try read(body: """
        <text:p><draw:frame><draw:image xlink:href="Pictures/missing.png"/></draw:frame></text:p>
        """)
        guard case .image(_, let size) = blocks.first else { return XCTFail("expected an image block") }
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testImageOnlyParagraphEmitsNoPhantomEmptyTextBlock() throws {
        let blocks = try readWithMedia(
            body: """
            <text:p><draw:frame svg:width="72pt" svg:height="72pt">
            <draw:image xlink:href="Pictures/photo.png"/></draw:frame></text:p>
            """,
            media: [(name: "Pictures/photo.png", bytes: [0x01])])
        XCTAssertEqual(blocks, [.image(id: "Pictures/photo.png", size: CGSize(width: 72, height: 72))])
    }

    // MARK: Tables

    func testTwoByTwoTableWithAnEmptyCellKeepsShape() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row>
            <table:table-cell><text:p>H1</text:p></table:table-cell>
            <table:table-cell><text:p>H2</text:p></table:table-cell>
          </table:table-row>
          <table:table-row>
            <table:table-cell><text:p>A1</text:p></table:table-cell>
            <table:table-cell><text:p/></table:table-cell>
          </table:table-row>
        </table:table>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "H1")]), Cell(spans: [Span(text: "H2")])],
            [Cell(spans: [Span(text: "A1")]), Cell(spans: [])],
        ], headerRows: 0)])
    }

    func testNoTableHeaderRowsWrapperReportsZeroHeaderRows() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row><table:table-cell><text:p>A</text:p></table:table-cell></table:table-row>
        </table:table>
        """)
        guard case .table(_, let headerRows) = blocks.first else { return XCTFail("expected a table block") }
        XCTAssertEqual(headerRows, 0)
    }

    func testTableHeaderRowsWrapperReportsItsRowCount() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-header-rows>
            <table:table-row><table:table-cell><text:p>H1</text:p></table:table-cell></table:table-row>
          </table:table-header-rows>
          <table:table-row><table:table-cell><text:p>A1</text:p></table:table-cell></table:table-row>
        </table:table>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "H1")])],
            [Cell(spans: [Span(text: "A1")])],
        ], headerRows: 1)])
    }

    func testNumberColumnsRepeatedExpandsToThatManyColumns() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row>
            <table:table-cell table:number-columns-repeated="3"><text:p>X</text:p></table:table-cell>
          </table:table-row>
        </table:table>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "X")]), Cell(spans: [Span(text: "X")]), Cell(spans: [Span(text: "X")])],
        ], headerRows: 0)])
    }

    // MARK: Merged cells — ODF's covered-table-cell convention (the opposite of docx's vMerge)

    func testHorizontalMergeCollapsesCoveredCellAndCarriesColSpan() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row>
            <table:table-cell table:number-columns-spanned="2"><text:p>Wide</text:p></table:table-cell>
            <table:covered-table-cell/>
            <table:table-cell><text:p>C3</text:p></table:table-cell>
          </table:table-row>
        </table:table>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Wide")], rowSpan: 1, colSpan: 2), Cell(spans: [Span(text: "C3")])],
        ], headerRows: 0)])
    }

    func testVerticalMergeCollapsesCoveredCellInSubsequentRowAndCarriesRowSpan() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row>
            <table:table-cell table:number-rows-spanned="2"><text:p>Tall</text:p></table:table-cell>
            <table:table-cell><text:p>B1</text:p></table:table-cell>
          </table:table-row>
          <table:table-row>
            <table:covered-table-cell/>
            <table:table-cell><text:p>B2</text:p></table:table-cell>
          </table:table-row>
        </table:table>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Tall")], rowSpan: 2, colSpan: 1), Cell(spans: [Span(text: "B1")])],
            [Cell(spans: [Span(text: "B2")])],
        ], headerRows: 0)])
    }

    /// `table:number-columns-repeated` can appear on `table:covered-table-cell` too (a wide merge's
    /// covered run compressed the same way an empty run would be) — it must not throw off the anchor
    /// that follows it, regardless of the repeat count.
    func testRepeatedCoveredCellsDoNotShiftTheAnchorThatFollows() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row>
            <table:table-cell table:number-columns-spanned="3"><text:p>Wide</text:p></table:table-cell>
            <table:covered-table-cell table:number-columns-repeated="2"/>
            <table:table-cell><text:p>Next</text:p></table:table-cell>
          </table:table-row>
        </table:table>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Wide")], rowSpan: 1, colSpan: 3), Cell(spans: [Span(text: "Next")])],
        ], headerRows: 0)])
    }

    // MARK: Nested tables — flattened to text (Cell has no room for a nested block)

    func testNestedTableInsideACellFlattensToTextRatherThanDisappearing() throws {
        let blocks = try read(body: """
        <table:table>
          <table:table-row>
            <table:table-cell>
              <text:p>Outer</text:p>
              <table:table>
                <table:table-row>
                  <table:table-cell><text:p>Nested</text:p></table:table-cell>
                </table:table-row>
              </table:table>
            </table:table-cell>
          </table:table-row>
        </table:table>
        """)
        guard case .table(let rows, _) = blocks.first else { return XCTFail("expected a table block") }
        let allText = rows.flatMap { $0 }.flatMap { $0.spans }.map(\.text).joined()
        XCTAssertTrue(allText.contains("Outer"), "outer paragraph text must survive")
        XCTAssertTrue(allText.contains("Nested"), "nested table's text must survive, not disappear")
    }

    // MARK: Lists

    private let numberThenBulletListStyle = """
    <text:list-style style:name="L1">
      <text:list-level-style-number text:level="1"/>
      <text:list-level-style-bullet text:level="2"/>
    </text:list-style>
    """

    func testNestedListLevelsAndOrderedVsBulletResolveViaListStyle() throws {
        let blocks = try read(
            body: """
            <text:list text:style-name="L1">
              <text:list-item><text:p>One</text:p>
                <text:list><text:list-item><text:p>Nested</text:p></text:list-item></text:list>
              </text:list-item>
            </text:list>
            """,
            automaticStyles: numberThenBulletListStyle)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: true, spans: [Span(text: "One")]),
            .listItem(level: 1, ordered: false, spans: [Span(text: "Nested")]),
        ])
    }

    func testUnresolvableListStyleDefaultsToUnordered() throws {
        let blocks = try read(body: """
        <text:list text:style-name="Missing"><text:list-item><text:p>Item</text:p></text:list-item></text:list>
        """)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")])])
    }

    func testListWithNoStyleNameAtAllDefaultsToUnordered() throws {
        let blocks = try read(body: """
        <text:list><text:list-item><text:p>Item</text:p></text:list-item></text:list>
        """)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")])])
    }

    // MARK: Whitespace elements

    func testTextSWithCountProducesThatManySpaces() throws {
        let blocks = try read(body: "<text:p>a<text:s text:c=\"3\"/>b</text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "a   b")])])
    }

    func testBareTextSDefaultsToOneSpace() throws {
        let blocks = try read(body: "<text:p>a<text:s/>b</text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "a b")])])
    }

    func testTabAndLineBreakSurviveIntoText() throws {
        let blocks = try read(body: "<text:p>Col1<text:tab/>Col2<text:line-break/>Line2</text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Col1\tCol2\nLine2")])])
    }

    // MARK: Emphasis

    func testBoldItalicUnderlineLandOnTheRightRanges() throws {
        let blocks = try read(
            body: """
            <text:p><text:span text:style-name="Bold">B</text:span><text:span text:style-name="Italic">I</text:span><text:span text:style-name="Under">U</text:span></text:p>
            """,
            automaticStyles: """
            <style:style style:name="Bold" style:family="text"><style:text-properties fo:font-weight="bold"/></style:style>
            <style:style style:name="Italic" style:family="text"><style:text-properties fo:font-style="italic"/></style:style>
            <style:style style:name="Under" style:family="text"><style:text-properties style:text-underline-style="solid"/></style:style>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "B", bold: true),
            Span(text: "I", italic: true),
            Span(text: "U", underline: true),
        ])])
    }

    func testUnresolvableSpanStyleEmitsTextUnstyledRatherThanDropped() throws {
        let blocks = try read(body: "<text:p><text:span text:style-name=\"Missing\">Text</text:span></text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Text")])])
    }

    func testStrikethroughSuperscriptAndSubscriptStylesMapToSpanFlags() throws {
        let blocks = try read(
            body: """
            <text:p><text:span text:style-name="Strike">S</text:span><text:span text:style-name="Sup">P</text:span><text:span text:style-name="Sub">B</text:span></text:p>
            """,
            automaticStyles: """
            <style:style style:name="Strike" style:family="text"><style:text-properties style:text-line-through-style="solid"/></style:style>
            <style:style style:name="Sup" style:family="text"><style:text-properties style:text-position="super 58%"/></style:style>
            <style:style style:name="Sub" style:family="text"><style:text-properties style:text-position="sub 58%"/></style:style>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "S", strikethrough: true),
            Span(text: "P", superscript: true),
            Span(text: "B", subscripted: true),
        ])])
    }

    // MARK: Hyperlinks

    func testHyperlinkTextAProducesLinkSpan() throws {
        let blocks = try read(body: """
        <text:p>before <text:a xlink:href="https://example.com">link text</text:a> after</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "before "),
            Span(text: "link text", link: "https://example.com"),
            Span(text: " after"),
        ])])
    }

    func testHyperlinkWithNoHrefIsPlainTextNotACrash() throws {
        let blocks = try read(body: "<text:p><text:a>no href</text:a></text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "no href")])])
    }

    // MARK: Archive-level failure and absent optional parts

    func testArchiveWithNoContentXMLThrows() throws {
        let archive = try ZipArchive(data: buildZip([("styles.xml", Data("<x/>".utf8))]))
        XCTAssertThrowsError(try OdtReader.read(archive)) { error in
            XCTAssertEqual(error as? OdtReader.ReadError, .missingContentXML)
        }
    }

    func testMissingStylesXMLStillParsesWithNoCrash() throws {
        let blocks = try read(body: "<text:p>Plain</text:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain")])])
    }
}

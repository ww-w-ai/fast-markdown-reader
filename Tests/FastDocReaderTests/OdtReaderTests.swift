import XCTest
@testable import FastDocReader

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

    /// S3: a `text:p` whose OWN paragraph style declares `style:default-outline-level` is a heading
    /// too, even though it's a plain `text:p` element (Writer produces this shape). This is the ODT
    /// counterpart of docx's style-based mechanisms — needed so both formats agree on the same
    /// document (the sprint's cross-format-equality guard).
    func testParagraphStyleWithDefaultOutlineLevelIsAHeadingEvenThoughItsElementIsTextP() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"H2Style\">Styled Heading</text:p>",
            automaticStyles: """
            <style:style style:name="H2Style" style:family="paragraph" style:default-outline-level="2"/>
            """)
        XCTAssertEqual(blocks, [.heading(level: 2, spans: [Span(text: "Styled Heading")])])
    }

    func testParagraphStyleWithNoDefaultOutlineLevelIsAnOrdinaryParagraph() throws {
        let blocks = try read(
            body: "<text:p text:style-name=\"Body\">Plain</text:p>",
            automaticStyles: """
            <style:style style:name="Body" style:family="paragraph"/>
            """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain")])])
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

    // MARK: Footnotes / endnotes
    //
    // NOTE ON EVIDENCE: like `DocxReaderTests`' footnote section, this is entirely synthetic — no
    // fixture `.odt` in this project's corpus carries a real `text:note`. Built from the ODF spec
    // shape (`text:note` containing `text:note-citation` + `text:note-body`), not measured.

    func testFootnoteProducesSuperscriptMarkerAtCitationAndAppendsBodyAtDocumentEnd() throws {
        let blocks = try read(body: """
        <text:p>See <text:note text:id="ftn1" text:note-class="footnote">
          <text:note-citation>1</text:note-citation>
          <text:note-body><text:p>Note body text.</text:p></text:note-body>
        </text:note> note.</text:p>
        """)
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "See "), Span(text: "1", superscript: true), Span(text: " note.")]),
            // The tab between marker and text is SYNTHETIC (`OdtReader.noteMarkerSeparator`) — ODF
            // has nothing corresponding to docx's literal `w:tab` inside the note body, but the
            // marker here is our own construct, so we own the separator and match what docx already
            // shows for the same document (see the sprint's cross-format-divergence fix).
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: "\t"), Span(text: "Note body text.")]),
        ])
    }

    /// ODF tells footnotes and endnotes apart only by `text:note-class` — both are the SAME element
    /// otherwise, and this reader renders them identically (the marker is the file's own
    /// `text:note-citation` text either way, never recomputed), so an endnote needs no separate case.
    func testEndnoteIsRenderedTheSameWayAsAFootnote() throws {
        let blocks = try read(body: """
        <text:p>See <text:note text:id="edn1" text:note-class="endnote">
          <text:note-citation>i</text:note-citation>
          <text:note-body><text:p>Endnote body.</text:p></text:note-body>
        </text:note> note.</text:p>
        """)
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "See "), Span(text: "i", superscript: true), Span(text: " note.")]),
            .paragraph(spans: [Span(text: "i", superscript: true), Span(text: "\t"), Span(text: "Endnote body.")]),
        ])
    }

    /// The corruption this sprint exists to avoid: a naive reader that walks `text:note` like any
    /// other wrapper would splice "Note body text." into the middle of "See  note.", reading as one
    /// garbled sentence. The citation and the body must stay visually separated.
    func testFootnoteBodyIsNeverSplicedIntoTheCitingParagraphsOwnSpans() throws {
        let blocks = try read(body: """
        <text:p>See <text:note text:id="ftn1" text:note-class="footnote">
          <text:note-citation>1</text:note-citation>
          <text:note-body><text:p>Note body text.</text:p></text:note-body>
        </text:note> note.</text:p>
        """)
        guard case .paragraph(let citingSpans) = blocks[0] else { return XCTFail("expected a paragraph") }
        XCTAssertFalse(citingSpans.contains { $0.text.contains("Note body text.") })
    }

    /// Pins the exact separator between marker and body text against DRIFT: docx's note body reads
    /// as `"1\tThe first note body text."` (a real `w:tab` FROM THE FILE, in Word's own footnote
    /// template — see `DocxReaderTests`), and this reader must match that shape even though ODF has
    /// no equivalent element to read it from. Reading `docs/fixtures/office/notes.docx` and
    /// `docs/fixtures/office/notes.odt` (the real, LibreOffice-produced pair) must therefore produce
    /// identical block text end to end — this test pins the mechanism that makes that hold, in a
    /// fixture nobody has to keep around on disk to prove it.
    func testMarkerAndBodyAreSeparatedByATabMatchingDocxsOwnFootnoteConvention() throws {
        let blocks = try read(body: """
        <text:p>See <text:note text:id="ftn1" text:note-class="footnote">
          <text:note-citation>1</text:note-citation>
          <text:note-body><text:p>The first note body text.</text:p></text:note-body>
        </text:note> note.</text:p>
        """)
        guard case .paragraph(let noteSpans) = blocks[1] else { return XCTFail("expected the appended note paragraph") }
        XCTAssertEqual(noteSpans.map(\.text).joined(), "1\tThe first note body text.")
    }

    /// A note missing `text:note-citation` entirely (malformed — ODF requires one) falls back to a
    /// plain sequential counter in citation order, rather than a blank marker — mirroring what
    /// `DocxReader` does for EVERY docx note (which never carries a citation number of its own at
    /// all, see the correction in the sprint brief).
    func testNoteWithNoCitationElementFallsBackToASequentialCounter() throws {
        let blocks = try read(body: """
        <text:p>See <text:note text:id="ftn1" text:note-class="footnote">
          <text:note-body><text:p>Note body text.</text:p></text:note-body>
        </text:note> note.</text:p>
        """)
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "See "), Span(text: "1", superscript: true), Span(text: " note.")]),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: "\t"), Span(text: "Note body text.")]),
        ])
    }

    /// A note missing `text:note-body` entirely (malformed) still shows its citation marker inline —
    /// honest, since something WAS cited — but fabricates no body text, since there is none.
    func testNoteWithNoBodyElementStillShowsMarkerButAppendsNothing() throws {
        let blocks = try read(body: """
        <text:p>See <text:note text:id="ftn1" text:note-class="footnote">
          <text:note-citation>1</text:note-citation>
        </text:note> note.</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "See "), Span(text: "1", superscript: true), Span(text: " note.")])])
    }

    /// Two footnotes cited in the same paragraph both get their own marker AND their own appended
    /// body, in citation order — `text:note-citation`'s own text is trusted directly (never
    /// recomputed), so this is really just proving two notes don't collide or reorder.
    func testTwoFootnotesInOneParagraphEachGetTheirOwnMarkerAndBody() throws {
        let blocks = try read(body: """
        <text:p>One<text:note text:id="ftn1" text:note-class="footnote">
          <text:note-citation>1</text:note-citation>
          <text:note-body><text:p>First note.</text:p></text:note-body>
        </text:note> two<text:note text:id="ftn2" text:note-class="footnote">
          <text:note-citation>2</text:note-citation>
          <text:note-body><text:p>Second note.</text:p></text:note-body>
        </text:note></text:p>
        """)
        XCTAssertEqual(blocks, [
            .paragraph(spans: [
                Span(text: "One"), Span(text: "1", superscript: true), Span(text: " two"), Span(text: "2", superscript: true),
            ]),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: "\t"), Span(text: "First note.")]),
            .paragraph(spans: [Span(text: "2", superscript: true), Span(text: "\t"), Span(text: "Second note.")]),
        ])
    }

    /// An image inside a footnote's body belongs to the FOOTNOTE, not to the paragraph that cites
    /// it — `collectImages`' blind `allDescendants` walk over the citing paragraph would otherwise
    /// find it too and duplicate it at the wrong place (see `OdtReader.collectImages`).
    func testImageInsideAFootnoteBodyDoesNotLeakIntoTheCitingParagraphsOwnImages() throws {
        let blocks = try readWithMedia(
            body: """
            <text:p>See <text:note text:id="ftn1" text:note-class="footnote">
              <text:note-citation>1</text:note-citation>
              <text:note-body>
                <text:p><draw:frame svg:width="1in" svg:height="1in"><draw:image xlink:href="Pictures/note.png"/></draw:frame></text:p>
              </text:note-body>
            </text:note> note.</text:p>
            """,
            media: [("Pictures/note.png", [0x00])])
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "See "), Span(text: "1", superscript: true), Span(text: " note.")]),
            // The note body opens with an image, not text — nowhere to splice the marker span into
            // (`OdtReader.prependingMarker` returns `nil` for `.image`), so it becomes its own small
            // leading paragraph rather than being silently dropped.
            .paragraph(spans: [Span(text: "1", superscript: true)]),
            .image(id: "Pictures/note.png", size: CGSize(width: 72, height: 72)),
        ])
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

    // MARK: S4 item 1 — unknown body wrappers RECURSE instead of dropping their contents whole

    func testTextSectionContentSurvivesViaRecursionNotJustCoincidentalReachability() throws {
        let blocks = try read(body: """
        <text:section text:name="Sec1"><text:p>Inside a section.</text:p></text:section>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Inside a section.")])])
    }

    func testTableOfContentIndexBodyParagraphsSurvive() throws {
        let blocks = try read(body: """
        <text:table-of-content text:name="TOC">
          <text:table-of-content-source/>
          <text:index-body>
            <text:index-title><text:p>Table of Contents</text:p></text:index-title>
            <text:p>Chapter 1 ... 1</text:p>
          </text:index-body>
        </text:table-of-content>
        """)
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "Table of Contents")]),
            .paragraph(spans: [Span(text: "Chapter 1 ... 1")]),
        ])
    }

    /// Two of the other six index-family wrappers, confirming the fix is generic rather than
    /// scoped to the two names gap-list.md happened to mention by example.
    func testIllustrationAndBibliographyIndexBodiesSurvive() throws {
        let illustrations = try read(body: """
        <text:illustration-index text:name="LOI">
          <text:index-body><text:p>Figure 1: A diagram</text:p></text:index-body>
        </text:illustration-index>
        """)
        XCTAssertEqual(illustrations, [.paragraph(spans: [Span(text: "Figure 1: A diagram")])])

        let bibliography = try read(body: """
        <text:bibliography text:name="Bib">
          <text:index-body><text:p>Smith, J. (2020). A Book.</text:p></text:index-body>
        </text:bibliography>
        """)
        XCTAssertEqual(bibliography, [.paragraph(spans: [Span(text: "Smith, J. (2020). A Book.")])])
    }

    func testPageSequenceContentSurvives() throws {
        let blocks = try read(body: """
        <text:page-sequence><text:page><text:p>Page content.</text:p></text:page></text:page-sequence>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Page content.")])])
    }

    func testAnnotationTrackedChangesAndDeclarationBlocksStayExcludedEvenThoughRecursionIsNowPermissive() throws {
        let blocks = try read(body: """
        <office:annotation><text:p>A reviewer comment.</text:p></office:annotation>
        <text:tracked-changes>
          <text:changed-region text:id="ct1"><text:deletion><text:p>Deleted text.</text:p></text:deletion></text:changed-region>
        </text:tracked-changes>
        <text:sequence-decls><text:sequence-decl text:display-outline-level="0" text:name="Figure"/></text:sequence-decls>
        <office:forms><form:form><text:p>Not document prose.</text:p></form:form></office:forms>
        <text:p>Real content.</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Real content.")])])
    }

    /// Mutation check (invariant 30): confirm the recursion is what's carrying the content, not
    /// some OTHER reachable path — remove the recursion (simulate by asserting the wrapper name
    /// itself never reaches a matched case) by checking a NESTED wrapper (section inside a TOC
    /// index-body) still survives, which only recursion-at-every-level, not a single special case,
    /// can produce.
    func testNestedUnknownWrappersRecurseAtEveryLevelNotJustOnce() throws {
        let blocks = try read(body: """
        <text:table-of-content text:name="TOC">
          <text:index-body><text:section text:name="Inner"><text:p>Deeply nested.</text:p></text:section></text:index-body>
        </text:table-of-content>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Deeply nested.")])])
    }

    // MARK: S4 item 2 — text:numbered-paragraph (a list item with no enclosing text:list)

    func testNumberedParagraphAtLevelOneProducesAnOrderedListItem() throws {
        let blocks = try read(
            body: """
            <text:numbered-paragraph text:style-name="L1" text:list-level="1">
              <text:p>Clause one.</text:p>
            </text:numbered-paragraph>
            """,
            automaticStyles: numberThenBulletListStyle)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: true, spans: [Span(text: "Clause one.")])])
    }

    func testNumberedParagraphAtDeeperLevelConvertsOneBasedToZeroBasedLevel() throws {
        let blocks = try read(
            body: """
            <text:numbered-paragraph text:style-name="L1" text:list-level="3">
              <text:p>Sub-clause.</text:p>
            </text:numbered-paragraph>
            """,
            automaticStyles: numberThenBulletListStyle)
        // Level 3 (1-based) → 2 (0-based); the fixture's list style only declares levels 0/1, so an
        // undeclared level 2 correctly resolves to unordered (`isOrdered`'s own unresolvable-input
        // contract), proving the level really did convert rather than clamp to a declared one.
        XCTAssertEqual(blocks, [.listItem(level: 2, ordered: false, spans: [Span(text: "Sub-clause.")])])
    }

    func testNumberedParagraphWithNoListLevelAttributeDefaultsToLevelZero() throws {
        let blocks = try read(
            body: """
            <text:numbered-paragraph text:style-name="L1">
              <text:p>Default level.</text:p>
            </text:numbered-paragraph>
            """,
            automaticStyles: numberThenBulletListStyle)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: true, spans: [Span(text: "Default level.")])])
    }

    // MARK: S4 item 3 — hidden/conditional content shows unless the file explicitly says hidden

    /// `text:hidden-paragraph`'s content model is the SAME as `text:p`'s (spans directly, per ODF
    /// 1.3) — not a wrapper holding a nested `text:p`.
    func testHiddenParagraphMarkedHiddenIsSuppressed() throws {
        let blocks = try read(body: """
        <text:hidden-paragraph text:condition="false" text:is-hidden="true">Should not appear.</text:hidden-paragraph><text:p>Visible.</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Visible.")])])
    }

    func testHiddenParagraphMarkedVisibleShows() throws {
        let blocks = try read(body: """
        <text:hidden-paragraph text:condition="true" text:is-hidden="false">Shown text.</text:hidden-paragraph>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Shown text.")])])
    }

    /// The project's governing rule: an unknown/absent display state must fall to SHOWING.
    func testHiddenParagraphWithNoIsHiddenAttributeShowsByDefault() throws {
        let blocks = try read(body: """
        <text:hidden-paragraph text:condition="SomeVar==1">No recorded state.</text:hidden-paragraph>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "No recorded state.")])])
    }

    func testHiddenTextRunHiddenIsSuppressed() throws {
        let blocks = try read(body: """
        <text:p>Before <text:hidden-text text:condition="false" text:is-hidden="true" text:string-value="secret"/> after.</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Before  after.")])])
    }

    func testHiddenTextRunVisibleShowsCachedStringValue() throws {
        let blocks = try read(body: """
        <text:p>Before <text:hidden-text text:condition="true" text:is-hidden="false" text:string-value="shown"/> after.</text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Before shown after.")])])
    }

    func testConditionalTextShowsTrueBranchWhenCurrentValueIsTrue() throws {
        let blocks = try read(body: """
        <text:p><text:conditional-text text:condition="X" text:string-value-if-true="YES" text:string-value-if-false="NO" text:current-value="true"/></text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "YES")])])
    }

    func testConditionalTextShowsFalseBranchWhenCurrentValueIsFalseOrAbsent() throws {
        let blocksFalse = try read(body: """
        <text:p><text:conditional-text text:condition="X" text:string-value-if-true="YES" text:string-value-if-false="NO" text:current-value="false"/></text:p>
        """)
        XCTAssertEqual(blocksFalse, [.paragraph(spans: [Span(text: "NO")])])

        let blocksAbsent = try read(body: """
        <text:p><text:conditional-text text:condition="X" text:string-value-if-true="YES" text:string-value-if-false="NO"/></text:p>
        """)
        XCTAssertEqual(blocksAbsent, [.paragraph(spans: [Span(text: "NO")])])
    }

    // MARK: S4 item 4 — draw:frame > draw:text-box contributes its text content

    func testTextBoxContentsSurviveInsteadOfDisappearing() throws {
        let blocks = try read(body: """
        <text:p><draw:frame svg:width="72pt" svg:height="72pt">
          <draw:text-box><text:p>Callout text.</text:p></draw:text-box>
        </draw:frame></text:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Callout text.")])])
    }

    func testTextBoxWithHeadingAndEmptyPlaceholderParagraphFiltersTheEmptyOne() throws {
        let blocks = try read(body: """
        <text:p><draw:frame svg:width="72pt" svg:height="72pt">
          <draw:text-box>
            <text:h text:outline-level="2">Box Title</text:h>
            <text:p/>
          </draw:text-box>
        </draw:frame></text:p>
        """)
        XCTAssertEqual(blocks, [.heading(level: 2, spans: [Span(text: "Box Title")])])
    }

    func testFrameWithBothImageAndTextBoxIsTreatedAsAnImageNotDoubleCounted() throws {
        let blocks = try readWithMedia(
            body: """
            <text:p><draw:frame svg:width="72pt" svg:height="72pt">
              <draw:image xlink:href="Pictures/photo.png"/>
            </draw:frame></text:p>
            """,
            media: [("Pictures/photo.png", [0x01])])
        XCTAssertEqual(blocks, [.image(id: "Pictures/photo.png", size: CGSize(width: 72, height: 72))])
    }

    // MARK: S4 — a real read path, not just the parser (invariant 29)

    func testAllFourItemsSurviveThroughDocumentTypesReadOfficeNotJustOdtReaderDirectly() throws {
        let zip = buildOdt(content: doc(
            body: """
            <text:section text:name="Sec1"><text:p>Section text.</text:p></text:section>
            <text:numbered-paragraph text:style-name="L1" text:list-level="1"><text:p>Clause.</text:p></text:numbered-paragraph>
            <text:hidden-paragraph text:is-hidden="true">Hidden.</text:hidden-paragraph>
            <text:p><draw:frame svg:width="72pt" svg:height="72pt"><draw:text-box><text:p>Box text.</text:p></draw:text-box></draw:frame></text:p>
            """,
            automaticStyles: numberThenBulletListStyle))
        let archive = try ZipArchive(data: zip)
        let blocks = try DocumentTypes.readOffice(archive, extension: "odt")
        let allText = blocks.flatMap { block -> [String] in
            switch block {
            case .paragraph(let spans), .heading(_, let spans), .listItem(_, _, let spans, _): return spans.map(\.text)
            case .table, .image: return []
            }
        }.joined()
        XCTAssertTrue(allText.contains("Section text."))
        XCTAssertTrue(allText.contains("Clause."))
        XCTAssertFalse(allText.contains("Hidden."))
        XCTAssertTrue(allText.contains("Box text."))
    }
}

import XCTest
@testable import FastDocReader

/// `DocxReader` is pure: build a `.docx`-shaped ZIP by hand (stored entries only — no need to
/// deflate to exercise the reader), hand it to `ZipArchive`, then `DocxReader.read`, and assert
/// on the `[OfficeBlock]` that comes back. Same shape as `ZipArchiveTests` — no fixture files on
/// disk, no view, no document.
final class DocxReaderTests: XCTestCase {
    // MARK: Fixture construction — a real (stored-only) ZIP, built in memory

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// Builds a minimal `.docx`-shaped archive: `word/document.xml` always, `word/styles.xml`,
    /// `word/numbering.xml` and `word/_rels/document.xml.rels` only when provided (Word itself
    /// omits `numbering.xml` from documents with no lists, and a document with no relationships
    /// at all omits the `.rels` part too — several tests below exercise both).
    private func buildDocx(
        document: String, styles: String? = nil, numbering: String? = nil, rels: String? = nil,
        footnotes: String? = nil, endnotes: String? = nil, media: [(name: String, bytes: [UInt8])] = []
    ) -> Data {
        var entries: [(String, Data)] = [("word/document.xml", Data(document.utf8))]
        if let styles { entries.append(("word/styles.xml", Data(styles.utf8))) }
        if let numbering { entries.append(("word/numbering.xml", Data(numbering.utf8))) }
        if let rels { entries.append(("word/_rels/document.xml.rels", Data(rels.utf8))) }
        if let footnotes { entries.append(("word/footnotes.xml", Data(footnotes.utf8))) }
        if let endnotes { entries.append(("word/endnotes.xml", Data(endnotes.utf8))) }
        for (name, bytes) in media { entries.append(("word/media/" + name, Data(bytes))) }
        return buildZip(entries)
    }

    private func buildZip(_ entries: [(name: String, content: Data)]) -> Data {
        struct Prepared { let nameBytes: [UInt8]; let content: Data; let localOffset: Int }
        var body = [UInt8]()
        var prepared: [Prepared] = []
        for (name, content) in entries {
            let nameBytes = Array(name.utf8)
            let localOffset = body.count
            body += le32(0x0403_4b50)                  // local file header signature
            body += le16(20)                            // version needed to extract
            body += le16(0)                              // general purpose bit flag
            body += le16(0)                              // compression method: stored
            body += le16(0) + le16(0)                    // mod time, mod date
            body += le32(0)                               // crc-32 (unused by ZipArchive)
            body += le32(UInt32(content.count))           // compressed size == uncompressed for stored
            body += le32(UInt32(content.count))           // uncompressed size
            body += le16(UInt16(nameBytes.count))
            body += le16(0)                                // extra field length
            body += nameBytes
            body += Array(content)
            prepared.append(Prepared(nameBytes: nameBytes, content: content, localOffset: localOffset))
        }
        var centralDirectory = [UInt8]()
        for p in prepared {
            centralDirectory += le32(0x0201_4b50)          // central directory signature
            centralDirectory += le16(20) + le16(20)         // version made by, version needed
            centralDirectory += le16(0)                       // general purpose bit flag
            centralDirectory += le16(0)                       // compression method: stored
            centralDirectory += le16(0) + le16(0)              // mod time, mod date
            centralDirectory += le32(0)                        // crc-32
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le32(UInt32(p.content.count))
            centralDirectory += le16(UInt16(p.nameBytes.count))
            centralDirectory += le16(0)                        // extra field length
            centralDirectory += le16(0)                        // file comment length
            centralDirectory += le16(0)                        // disk number start
            centralDirectory += le16(0)                        // internal attributes
            centralDirectory += le32(0)                        // external attributes
            centralDirectory += le32(UInt32(p.localOffset))
            centralDirectory += p.nameBytes
        }
        let centralDirectoryOffset = body.count
        var archive = body + centralDirectory
        archive += le32(0x0605_4b50)                       // end of central directory signature
        archive += le16(0) + le16(0)                         // disk number, disk with CD start
        archive += le16(UInt16(entries.count))                // records on this disk
        archive += le16(UInt16(entries.count))                // total records
        archive += le32(UInt32(centralDirectory.count))
        archive += le32(UInt32(centralDirectoryOffset))
        archive += le16(0)                                     // comment length
        return Data(archive)
    }

    private func doc(_ body: String) -> String {
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?><w:document><w:body>\(body)</w:body></w:document>"
    }

    private func read(
        document: String, styles: String? = nil, numbering: String? = nil, footnotes: String? = nil,
        endnotes: String? = nil
    ) throws -> [OfficeBlock] {
        let zip = buildDocx(document: doc(document), styles: styles, numbering: numbering, footnotes: footnotes, endnotes: endnotes)
        let archive = try ZipArchive(data: zip)
        return try DocxReader.read(archive)
    }

    private func read(document: String, rels: String?, media: [(name: String, bytes: [UInt8])] = []) throws -> [OfficeBlock] {
        let zip = buildDocx(document: doc(document), rels: rels, media: media)
        let archive = try ZipArchive(data: zip)
        return try DocxReader.read(archive)
    }

    // MARK: Run reassembly

    func testFiveRunsWithIdenticalFormattingReassembleIntoOneSpan() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:b/></w:rPr><w:t>Hello</w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>, </w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>world</w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>! </w:t></w:r>
          <w:r><w:rPr><w:b/></w:rPr><w:t>Bye</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Hello, world! Bye", bold: true)])])
    }

    func testRunsWithDifferentFormattingStaySeparateInOrder() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:b/></w:rPr><w:t>Bold</w:t></w:r>
          <w:r><w:t>Plain</w:t></w:r>
          <w:r><w:rPr><w:i/></w:rPr><w:t>Italic</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "Bold", bold: true),
            Span(text: "Plain"),
            Span(text: "Italic", italic: true),
        ])])
    }

    func testExplicitlyDisabledBoldIsNotBold() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:rPr><w:b w:val="0"/></w:rPr><w:t>NotBold</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "NotBold", bold: false)])])
    }

    // MARK: Headings via outlineLvl

    private let headingStyles = """
    <w:styles>
      <w:style w:type="paragraph" w:styleId="Heading1"><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading2"><w:pPr><w:outlineLvl w:val="1"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading3"><w:pPr><w:outlineLvl w:val="2"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading4"><w:pPr><w:outlineLvl w:val="3"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading5"><w:pPr><w:outlineLvl w:val="4"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading6"><w:pPr><w:outlineLvl w:val="5"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading7"><w:pPr><w:outlineLvl w:val="6"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading8"><w:pPr><w:outlineLvl w:val="7"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="Heading9"><w:pPr><w:outlineLvl w:val="8"/></w:pPr></w:style>
      <w:style w:type="paragraph" w:styleId="TOCHeading"><w:pPr><w:outlineLvl w:val="9"/></w:pPr></w:style>
    </w:styles>
    """

    func testOutlineLevelsZeroThroughFiveMapToHeadingLevelsOneThroughSix() throws {
        let paragraphs = (1...6).map { "<w:p><w:pPr><w:pStyle w:val=\"Heading\($0)\"/></w:pPr><w:r><w:t>H\($0)</w:t></w:r></w:p>" }
        let blocks = try read(document: paragraphs.joined(), styles: headingStyles)
        XCTAssertEqual(blocks, (1...6).map { .heading(level: $0, spans: [Span(text: "H\($0)")]) })
    }

    func testOutlineLevelsSixSevenEightClampToHeadingLevelSix() throws {
        let paragraphs = (7...9).map { "<w:p><w:pPr><w:pStyle w:val=\"Heading\($0)\"/></w:pPr><w:r><w:t>H\($0)</w:t></w:r></w:p>" }
        let blocks = try read(document: paragraphs.joined(), styles: headingStyles)
        XCTAssertEqual(blocks, (7...9).map { .heading(level: 6, spans: [Span(text: "H\($0)")]) })
    }

    func testOutlineLevelNineIsNotAHeading() throws {
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"TOCHeading\"/></w:pPr><w:r><w:t>Contents</w:t></w:r></w:p>",
            styles: headingStyles)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Contents")])])
    }

    func testUnknownParagraphStyleIsAnOrdinaryParagraph() throws {
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Compact\"/></w:pPr><w:r><w:t>Text</w:t></w:r></w:p>",
            styles: headingStyles)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Text")])])
    }

    // MARK: S3 — the three ways Word marks a heading (mechanisms a/b/c of the sprint brief)

    /// Mechanism (a): a paragraph can be marked a heading directly, via its OWN `w:pPr/w:outlineLvl`,
    /// with no style involved at all.
    func testParagraphOwnOutlineLvlIsAHeadingWithNoStyleAtAll() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:outlineLvl w:val="1"/></w:pPr><w:r><w:t>Direct</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.heading(level: 2, spans: [Span(text: "Direct")])])
    }

    /// Mechanism (a)'s own TOCHeading guard: a paragraph's own `outlineLvl` of 9 is not a heading
    /// either — the same rule as a style-level 9, now checked at the paragraph level.
    func testParagraphOwnOutlineLvlNineIsNotAHeading() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:outlineLvl w:val="9"/></w:pPr><w:r><w:t>Contents</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Contents")])])
    }

    /// Mechanism (b): `Heading3`'s style DEFINITION carries no `w:outlineLvl` at all — Word very
    /// often omits it because the built-in id already says what it is — and it must still be read
    /// as a level-3 heading, purely from the id.
    func testBuiltInHeadingStyleIdWithNoOutlineLvlInItsOwnDefinitionIsStillAHeading() throws {
        let styles = "<w:styles><w:style w:type=\"paragraph\" w:styleId=\"Heading3\"/></w:styles>"
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"Heading3\"/></w:pPr><w:r><w:t>No outlineLvl</w:t></w:r></w:p>",
            styles: styles)
        XCTAssertEqual(blocks, [.heading(level: 3, spans: [Span(text: "No outlineLvl")])])
    }

    /// Mechanism (c): a CUSTOM style based on `Heading2` — carrying no `w:outlineLvl` of its own,
    /// and `Heading2`'s own definition also carrying none (mechanism (b)'s whole premise) — must
    /// resolve to level 2 by walking the `w:basedOn` chain up to the built-in id.
    func testCustomStyleBasedOnHeading2WithNoOutlineLvlAnywhereInTheChainIsStillAHeading() throws {
        let styles = """
        <w:styles>
          <w:style w:type="paragraph" w:styleId="Heading2"/>
          <w:style w:type="paragraph" w:styleId="ClauseHeading"><w:basedOn w:val="Heading2"/></w:style>
        </w:styles>
        """
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"ClauseHeading\"/></w:pPr><w:r><w:t>Inherited</w:t></w:r></w:p>",
            styles: styles)
        XCTAssertEqual(blocks, [.heading(level: 2, spans: [Span(text: "Inherited")])])
    }

    /// A `w:basedOn` CYCLE (malformed document) must not hang the reader — the walk detects the
    /// revisit and reports "not a heading" instead of looping forever.
    func testBasedOnCycleDoesNotHangAndIsNotTreatedAsAHeading() throws {
        let styles = """
        <w:styles>
          <w:style w:type="paragraph" w:styleId="A"><w:basedOn w:val="B"/></w:style>
          <w:style w:type="paragraph" w:styleId="B"><w:basedOn w:val="A"/></w:style>
        </w:styles>
        """
        let blocks = try read(
            document: "<w:p><w:pPr><w:pStyle w:val=\"A\"/></w:pPr><w:r><w:t>Cycle</w:t></w:r></w:p>",
            styles: styles)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Cycle")])])
    }

    // MARK: Empty markers and revision wrappers

    func testBookmarksAndProofErrProduceNoPhantomSpansAndDoNotSplitARunPair() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:b/></w:rPr><w:t>A</w:t></w:r>
          <w:bookmarkStart w:id="0" w:name="_GoBack"/>
          <w:bookmarkEnd w:id="0"/>
          <w:proofErr w:type="spellStart"/>
          <w:r><w:rPr><w:b/></w:rPr><w:t>B</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "AB", bold: true)])])
    }

    func testDeletedContentIsSkippedAndInsertedContentIsKept() throws {
        let blocks = try read(document: """
        <w:p>
          <w:del w:id="1" w:author="x"><w:r><w:delText>Deleted</w:delText></w:r></w:del>
          <w:ins w:id="2" w:author="x"><w:r><w:t>Inserted</w:t></w:r></w:ins>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Inserted")])])
    }

    // MARK: Tracked moves — S6 item 1: a guaranteed duplication bug before this fix
    //
    // `w:moveFrom` wraps the moved text at its ORIGINAL location, `w:moveTo` wraps the SAME text
    // at its NEW one. Before this fix neither name was excluded from `collectSpans`'s permissive
    // walk, so both rendered — every tracked move duplicated its own text, 100% reproducibly.

    /// The core acceptance case from the sprint brief: the moved text appears EXACTLY ONCE, at the
    /// new location — never at the old one, and never twice.
    func testTrackedMoveRendersItsTextExactlyOnceFromTheNewLocation() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:t>Before </w:t></w:r>
          <w:moveFrom w:id="1" w:author="x"><w:r><w:t>Moved</w:t></w:r></w:moveFrom>
          <w:r><w:t>after</w:t></w:r>
        </w:p>
        <w:p>
          <w:moveTo w:id="2" w:author="x"><w:r><w:t>Moved</w:t></w:r></w:moveTo>
        </w:p>
        """)
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "Before after")]),
            .paragraph(spans: [Span(text: "Moved")]),
        ])
        // Belt-and-braces on the acceptance criterion itself, not just structural equality above:
        // the word "Moved" must occur exactly once across the whole document.
        let fullText = blocks.compactMap { block -> String? in
            if case .paragraph(let spans) = block { return spans.map(\.text).joined() }
            return nil
        }.joined()
        XCTAssertEqual(fullText.components(separatedBy: "Moved").count - 1, 1,
                       "a tracked move must render its text exactly once, not once per location")
    }

    /// `w:moveFromRangeStart`/`w:moveFromRangeEnd` are empty boundary markers (no `w:t` of their
    /// own) — must not contribute any text even though they sit right next to real content.
    func testMoveFromRangeMarkersContributeNoText() throws {
        let blocks = try read(document: """
        <w:p>
          <w:moveFromRangeStart w:id="1" w:author="x" w:name="move1"/>
          <w:r><w:t>Kept</w:t></w:r>
          <w:moveFromRangeEnd w:id="1"/>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Kept")])])
    }

    // MARK: Breaks, tabs, whitespace

    func testLineBreakAndTabSurviveIntoText() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t>Line1</w:t><w:br/><w:t>Line2</w:t><w:tab/><w:t>Col2</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Line1\nLine2\tCol2")])])
    }

    func testPreserveSpaceKeepsLeadingAndTrailingSpaces() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t xml:space="preserve">  spaced  </w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "  spaced  ")])])
    }

    /// CLAUDE.md S2 item 2: `w:noBreakHyphen`, `w:softHyphen` and `w:ptab` are text, and used to be
    /// silently dropped by `buildSpan`'s `default: continue` — the author's character just vanished.
    func testNoBreakHyphenSurvivesAsNonBreakingHyphen() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t>well</w:t><w:noBreakHyphen/><w:t>known</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "well\u{2011}known")])])
    }

    func testSoftHyphenSurvivesAsSoftHyphen() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t>super</w:t><w:softHyphen/><w:t>cali</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "super\u{00AD}cali")])])
    }

    func testPtabSurvivesAsTab() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t>Col1</w:t><w:ptab w:relativeTo="margin" w:alignment="left" w:leader="none"/><w:t>Col2</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Col1\tCol2")])])
    }

    // MARK: Lists

    private let bulletThenDecimalNumbering = """
    <w:numbering>
      <w:abstractNum w:abstractNumId="1">
        <w:lvl w:ilvl="0"><w:numFmt w:val="bullet"/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="decimal"/></w:lvl>
      </w:abstractNum>
      <w:num w:numId="5"><w:abstractNumId w:val="1"/></w:num>
    </w:numbering>
    """

    func testNestedListLevelsAndFormatsResolveViaNumbering() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="5"/></w:numPr></w:pPr><w:r><w:t>Bullet</w:t></w:r></w:p>
        <w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="5"/></w:numPr></w:pPr><w:r><w:t>Decimal</w:t></w:r></w:p>
        """, numbering: bulletThenDecimalNumbering)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: false, spans: [Span(text: "Bullet")]),
            .listItem(level: 1, ordered: true, spans: [Span(text: "Decimal")]),
        ])
    }

    func testHeadingStyleWithNumPrStillEmitsHeadingNotListItem() throws {
        let blocks = try read(
            document: """
            <w:p>
              <w:pPr>
                <w:pStyle w:val="Heading2"/>
                <w:numPr><w:ilvl w:val="0"/><w:numId w:val="5"/></w:numPr>
              </w:pPr>
              <w:r><w:t>Interpretation</w:t></w:r>
            </w:p>
            """,
            styles: headingStyles, numbering: bulletThenDecimalNumbering)
        XCTAssertEqual(blocks, [.heading(level: 2, spans: [Span(text: "Interpretation")])])
    }

    func testNumPrWithoutHeadingStyleStillEmitsListItem() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="5"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p>
        """, numbering: bulletThenDecimalNumbering)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")])])
    }

    func testOutlineLevelNineWithNumPrStillEmitsListItem() throws {
        let blocks = try read(
            document: """
            <w:p>
              <w:pPr>
                <w:pStyle w:val="TOCHeading"/>
                <w:numPr><w:ilvl w:val="1"/><w:numId w:val="5"/></w:numPr>
              </w:pPr>
              <w:r><w:t>Contents</w:t></w:r>
            </w:p>
            """,
            styles: headingStyles, numbering: bulletThenDecimalNumbering)
        XCTAssertEqual(blocks, [.listItem(level: 1, ordered: true, spans: [Span(text: "Contents")])])
    }

    func testMissingNumberingXMLDefaultsListsToUnordered() throws {
        let blocks = try read(document: """
        <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:t>Item</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")])])
    }

    // MARK: S5 — clause and list numbering (the reader computes marker text)

    /// `%1.` decimal at level 0, `%1.%2` decimal.lowerLetter at level 1 — the shape a real
    /// multi-level clause numbering uses.
    private let clauseNumbering = """
    <w:numbering>
      <w:abstractNum w:abstractNumId="1">
        <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%1.%2"/></w:lvl>
      </w:abstractNum>
      <w:num w:numId="7"><w:abstractNumId w:val="1"/></w:num>
    </w:numbering>
    """

    private func numberedItem(_ numId: String, _ ilvl: Int, _ text: String) -> String {
        "<w:p><w:pPr><w:numPr><w:ilvl w:val=\"\(ilvl)\"/><w:numId w:val=\"\(numId)\"/></w:numPr></w:pPr><w:r><w:t>\(text)</w:t></w:r></w:p>"
    }

    /// Mechanism: counters continue across an intervening PLAIN paragraph. A document with no
    /// interruption at all would pass this same assertion for the wrong reason (nothing to reset
    /// in the first place), so this specifically inserts a non-list paragraph between two level-0
    /// items and asserts the second is still "2.", not "1." again.
    func testCounterContinuesAcrossAnInterveningPlainParagraph() throws {
        let blocks = try read(document: """
        \(numberedItem("7", 0, "First"))
        <w:p><w:r><w:t>Ordinary paragraph in between.</w:t></w:r></w:p>
        \(numberedItem("7", 0, "Second"))
        """, numbering: clauseNumbering)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: true, spans: [Span(text: "First")], marker: "1."),
            .paragraph(spans: [Span(text: "Ordinary paragraph in between.")]),
            .listItem(level: 0, ordered: true, spans: [Span(text: "Second")], marker: "2."),
        ])
    }

    /// Mechanism: a shallower item resets deeper levels; a deeper run does not disturb the
    /// shallower counter (`1. / a. / b. / 2.`, mirroring the old builder-side rule now proven at
    /// the numId granularity the reader itself uses).
    func testShallowerItemResetsDeeperLevelsButDeeperRunDoesNotDisturbShallower() throws {
        let blocks = try read(document: """
        \(numberedItem("7", 0, "One"))
        \(numberedItem("7", 1, "a"))
        \(numberedItem("7", 1, "b"))
        \(numberedItem("7", 0, "Two"))
        \(numberedItem("7", 1, "restart"))
        """, numbering: clauseNumbering)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: true, spans: [Span(text: "One")], marker: "1."),
            .listItem(level: 1, ordered: true, spans: [Span(text: "a")], marker: "1.a"),
            .listItem(level: 1, ordered: true, spans: [Span(text: "b")], marker: "1.b"),
            .listItem(level: 0, ordered: true, spans: [Span(text: "Two")], marker: "2."),
            .listItem(level: 1, ordered: true, spans: [Span(text: "restart")], marker: "2.a"),
        ])
    }

    /// Mechanism: `%1.%2.%3` with level 2 in letters (per its own `w:numFmt`), levels 1/3 decimal.
    func testThreeLevelLvlTextSubstitutesEachLevelsOwnFormat() throws {
        let numbering = """
        <w:numbering>
          <w:abstractNum w:abstractNumId="2">
            <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1"/></w:lvl>
            <w:lvl w:ilvl="1"><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%1.%2"/></w:lvl>
            <w:lvl w:ilvl="2"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1.%2.%3"/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="3"><w:abstractNumId w:val="2"/></w:num>
        </w:numbering>
        """
        let blocks = try read(document: """
        \(numberedItem("3", 0, "One"))
        \(numberedItem("3", 1, "a"))
        \(numberedItem("3", 2, "deep"))
        """, numbering: numbering)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: true, spans: [Span(text: "One")], marker: "1"),
            .listItem(level: 1, ordered: true, spans: [Span(text: "a")], marker: "1.a"),
            .listItem(level: 2, ordered: true, spans: [Span(text: "deep")], marker: "1.a.1"),
        ])
    }

    /// Mechanism: `w:startOverride` of 5 produces 5.
    func testStartOverrideChangesTheFirstValueEmitted() throws {
        let numbering = """
        <w:numbering>
          <w:abstractNum w:abstractNumId="1">
            <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="8">
            <w:abstractNumId w:val="1"/>
            <w:lvlOverride w:ilvl="0"><w:startOverride w:val="5"/></w:lvlOverride>
          </w:num>
        </w:numbering>
        """
        let blocks = try read(document: numberedItem("8", 0, "Fifth"), numbering: numbering)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: true, spans: [Span(text: "Fifth")], marker: "5.")])
    }

    /// Mechanism: `w:lvlOverride/w:lvl` replaces the WHOLE level definition for this numId only —
    /// here swapping decimal for upperRoman, which a shared-abstract-num lookup alone could never
    /// produce.
    func testLvlOverrideReplacingALevelDefinitionTakesEffect() throws {
        let numbering = """
        <w:numbering>
          <w:abstractNum w:abstractNumId="1">
            <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="8">
            <w:abstractNumId w:val="1"/>
            <w:lvlOverride w:ilvl="0">
              <w:lvl w:ilvl="0"><w:numFmt w:val="upperRoman"/><w:lvlText w:val="%1."/></w:lvl>
            </w:lvlOverride>
          </w:num>
        </w:numbering>
        """
        let blocks = try read(document: """
        \(numberedItem("8", 0, "One"))
        \(numberedItem("8", 0, "Two"))
        """, numbering: numbering)
        XCTAssertEqual(blocks, [
            .listItem(level: 0, ordered: true, spans: [Span(text: "One")], marker: "I."),
            .listItem(level: 0, ordered: true, spans: [Span(text: "Two")], marker: "II."),
        ])
    }

    /// Mechanism: `numId="0"` is Word's sentinel for "not numbered at all" — a plain paragraph,
    /// never a `.listItem`, regardless of whatever `word/numbering.xml` otherwise contains.
    func testNumIdZeroProducesAPlainParagraphNotAListItem() throws {
        let blocks = try read(document: numberedItem("0", 0, "Not a list"), numbering: clauseNumbering)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Not a list")])])
    }

    /// Mechanism: upper/lower Roman and upper/lower letter formats.
    func testRomanAndLetterFormatsUpperAndLower() throws {
        let numbering = """
        <w:numbering>
          <w:abstractNum w:abstractNumId="4">
            <w:lvl w:ilvl="0"><w:numFmt w:val="upperRoman"/><w:lvlText w:val="%1."/></w:lvl>
          </w:abstractNum>
          <w:abstractNum w:abstractNumId="5">
            <w:lvl w:ilvl="0"><w:numFmt w:val="lowerRoman"/><w:lvlText w:val="%1."/></w:lvl>
          </w:abstractNum>
          <w:abstractNum w:abstractNumId="6">
            <w:lvl w:ilvl="0"><w:numFmt w:val="upperLetter"/><w:lvlText w:val="%1)"/></w:lvl>
          </w:abstractNum>
          <w:abstractNum w:abstractNumId="7">
            <w:lvl w:ilvl="0"><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%1)"/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="40"><w:abstractNumId w:val="4"/></w:num>
          <w:num w:numId="50"><w:abstractNumId w:val="5"/></w:num>
          <w:num w:numId="60"><w:abstractNumId w:val="6"/></w:num>
          <w:num w:numId="70"><w:abstractNumId w:val="7"/></w:num>
        </w:numbering>
        """
        // Four INDEPENDENT numIds, each incremented three times, so a run of 1/2/3 in each format
        // is checked rather than just its first value.
        let body = (1...3).map { numberedItem("40", 0, "R\($0)") }.joined()
            + (1...3).map { numberedItem("50", 0, "r\($0)") }.joined()
            + (1...3).map { numberedItem("60", 0, "L\($0)") }.joined()
            + (1...3).map { numberedItem("70", 0, "l\($0)") }.joined()
        let blocks = try read(document: body, numbering: numbering)
        let markers = blocks.compactMap { block -> String? in
            if case .listItem(_, _, _, let marker) = block { return marker }
            return nil
        }
        XCTAssertEqual(markers, [
            "I.", "II.", "III.",
            "i.", "ii.", "iii.",
            "A)", "B)", "C)",
            "a)", "b)", "c)",
        ])
    }

    /// Mechanism: an unknown `w:numFmt` falls back to decimal and still produces a number, rather
    /// than throwing or leaving the marker blank.
    func testUnknownNumFmtFallsBackToDecimal() throws {
        let numbering = """
        <w:numbering>
          <w:abstractNum w:abstractNumId="1">
            <w:lvl w:ilvl="0"><w:numFmt w:val="chineseCounting"/><w:lvlText w:val="%1."/></w:lvl>
          </w:abstractNum>
          <w:num w:numId="9"><w:abstractNumId w:val="1"/></w:num>
        </w:numbering>
        """
        let blocks = try read(document: numberedItem("9", 0, "Item"), numbering: numbering)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: true, spans: [Span(text: "Item")], marker: "1.")])
    }

    /// Mechanism: an unresolvable numId (absent from `word/numbering.xml` entirely) still produces
    /// today's pre-sprint fallback — unordered, no fabricated marker — never a made-up number.
    func testUnresolvableNumIdStillFallsBackRatherThanFabricatingANumber() throws {
        let blocks = try read(document: numberedItem("999", 0, "Item"), numbering: clauseNumbering)
        XCTAssertEqual(blocks, [.listItem(level: 0, ordered: false, spans: [Span(text: "Item")])])
    }

    // MARK: Tables

    func testTwoByTwoTableWithAnEmptyCellKeepsShapeAndReportsHeaderRow() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr><w:trPr><w:tblHeader/></w:trPr>
            <w:tc><w:p><w:r><w:t>H1</w:t></w:r></w:p></w:tc>
            <w:tc><w:p><w:r><w:t>H2</w:t></w:r></w:p></w:tc>
          </w:tr>
          <w:tr>
            <w:tc><w:p><w:r><w:t>A1</w:t></w:r></w:p></w:tc>
            <w:tc><w:p></w:p></w:tc>
          </w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "H1")]), Cell(spans: [Span(text: "H2")])],
            [Cell(spans: [Span(text: "A1")]), Cell(spans: [])],
        ], headerRows: 1)])
    }

    func testTableWithNoTblHeaderMarkerReportsZeroHeaderRows() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr><w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr>
          <w:tr><w:tc><w:p><w:r><w:t>C</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>D</w:t></w:r></w:p></w:tc></w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "A")]), Cell(spans: [Span(text: "B")])],
            [Cell(spans: [Span(text: "C")]), Cell(spans: [Span(text: "D")])],
        ], headerRows: 0)])
    }

    // MARK: Tables — merged cells (corpus-measured: 31 gridSpan / 16 vMerge in the TAGO guide,
    // 13 of those 16 with no `w:val` at all)

    private func tc(_ cellXML: String) -> String { "<w:tc>\(cellXML)</w:tc>" }
    private func para(_ text: String) -> String { "<w:p><w:r><w:t>\(text)</w:t></w:r></w:p>" }

    /// The #1 footgun, and the majority case in the real corpus: a bare `<w:vMerge/>` with no
    /// `w:val` means CONTINUE, not restart. A reader that gets this backwards turns a real vertical
    /// merge into two separate one-row cells and silently loses the span.
    func testBareVMergeWithNoValContinuesTheMergeAbove() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>
            \(tc("<w:tcPr><w:vMerge w:val=\"restart\"/></w:tcPr>\(para("Top"))"))
            \(tc(para("B0")))
          </w:tr>
          <w:tr>
            \(tc("<w:tcPr><w:vMerge/></w:tcPr>\(para(""))"))
            \(tc(para("B1")))
          </w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Top")], rowSpan: 2), Cell(spans: [Span(text: "B0")])],
            [Cell(spans: [Span(text: "B1")])],
        ], headerRows: 0)])
    }

    /// Same as above but with an EXPLICIT `val="continue"` — the non-default spelling of the same
    /// footgun, kept as its own test since a reader could special-case the missing-attribute form
    /// and still mishandle this one.
    func testExplicitValContinueAlsoContinuesTheMerge() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>\(tc("<w:tcPr><w:vMerge w:val=\"restart\"/></w:tcPr>\(para("Top"))"))</w:tr>
          <w:tr>\(tc("<w:tcPr><w:vMerge w:val=\"continue\"/></w:tcPr>\(para(""))"))</w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Top")], rowSpan: 2)],
            [],
        ], headerRows: 0)])
    }

    /// Word routinely leaves stale leftover paragraph text inside a `continue` cell from before the
    /// merge existed — that text is dead and must never surface as a phantom extra line.
    func testStaleContentInAContinueCellIsDiscardedNotRendered() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>\(tc("<w:tcPr><w:vMerge w:val=\"restart\"/></w:tcPr>\(para("Top"))"))</w:tr>
          <w:tr>\(tc("<w:tcPr><w:vMerge/></w:tcPr>\(para("Leftover stale text"))"))</w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Top")], rowSpan: 2)],
            [],
        ], headerRows: 0)])
    }

    /// A three-row chain: `restart` then two bare `continue`s must accumulate `rowSpan` to 3, not
    /// reset or double-count partway through.
    func testThreeRowVerticalMergeAccumulatesRowSpanAcrossTwoContinuations() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>\(tc("<w:tcPr><w:vMerge w:val=\"restart\"/></w:tcPr>\(para("Top"))"))</w:tr>
          <w:tr>\(tc("<w:tcPr><w:vMerge/></w:tcPr>\(para(""))"))</w:tr>
          <w:tr>\(tc("<w:tcPr><w:vMerge/></w:tcPr>\(para(""))"))</w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Top")], rowSpan: 3)],
            [],
            [],
        ], headerRows: 0)])
    }

    func testGridSpanSetsColSpanOnTheAnchorCell() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>\(tc("<w:tcPr><w:gridSpan w:val=\"3\"/></w:tcPr>\(para("Title band"))"))</w:tr>
          <w:tr>\(tc(para("A")))\(tc(para("B")))\(tc(para("C")))</w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Title band")], colSpan: 3)],
            [Cell(spans: [Span(text: "A")]), Cell(spans: [Span(text: "B")]), Cell(spans: [Span(text: "C")])],
        ], headerRows: 0)])
    }

    /// A merged 2×2 region: row N's anchor is BOTH `gridSpan`'d and `vMerge`'d, row N+1's matching
    /// cell is a `gridSpan`'d `continue` — both the column-span and the row-span must land on the
    /// SAME logical cell, and the covered 2-column-wide footprint in row N+1 must vanish entirely
    /// (not leave one of its two columns behind as a phantom cell).
    func testCombinedGridSpanAndVMergeAppliesBothSpansToTheSameCell() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>
            \(tc("<w:tcPr><w:gridSpan w:val=\"2\"/><w:vMerge w:val=\"restart\"/></w:tcPr>\(para("Merged"))"))
            \(tc(para("Side0")))
          </w:tr>
          <w:tr>
            \(tc("<w:tcPr><w:gridSpan w:val=\"2\"/><w:vMerge/></w:tcPr>\(para(""))"))
            \(tc(para("Side1")))
          </w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "Merged")], rowSpan: 2, colSpan: 2), Cell(spans: [Span(text: "Side0")])],
            [Cell(spans: [Span(text: "Side1")])],
        ], headerRows: 0)])
    }

    /// A `continue` cell whose grid column has NO open merge above it (a malformed/hand-edited
    /// document — there is no `restart` anywhere earlier at that column) must not be fabricated
    /// into a normal cell of its own; it is simply dropped, same as a genuinely covered position.
    func testContinueWithNoOpenMergeAboveIsDroppedNotFabricatedIntoANewCell() throws {
        let blocks = try read(document: """
        <w:tbl>
          <w:tr>\(tc(para("A0")))</w:tr>
          <w:tr>\(tc("<w:tcPr><w:vMerge/></w:tcPr>\(para("Orphaned"))"))</w:tr>
        </w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [
            [Cell(spans: [Span(text: "A0")])],
            [],
        ], headerRows: 0)])
    }

    /// A content control inside a table cell — a very common Word form/template shape ("click
    /// here to enter a value" inside a template row) — must not make that cell's text disappear.
    /// This is the THIRD place `w:sdt` can wrap real content (body-level and inline-in-a-paragraph
    /// are covered above); a table cell is a distinct code path and was the one this fix closes.
    func testContentControlInsideATableCellIsUnwrappedNotDropped() throws {
        let blocks = try read(document: """
        <w:tbl><w:tr>\(tc("<w:sdt><w:sdtPr/><w:sdtContent>\(para("Filled in"))</w:sdtContent></w:sdt>"))</w:tr></w:tbl>
        """)
        XCTAssertEqual(blocks, [.table(rows: [[Cell(spans: [Span(text: "Filled in")])]], headerRows: 0)])
    }

    /// A `<w:tbl>` nested directly inside a `<w:tc>` — `Cell` has no case for a nested `.table`
    /// block, so its text is FLATTENED into the containing cell's spans (a tab between the nested
    /// table's cells, a newline after each of its non-empty rows) rather than silently dropped —
    /// mirrors `OdtReader`'s identical handling of ODF's equivalent construct, and the same loose
    /// "the words all survive somewhere" assertion style its test uses, since flattening does not
    /// merge every span into one and pinning exact span boundaries would over-specify the point.
    func testNestedTableInsideACellFlattensToTextRatherThanDisappearing() throws {
        // Same shape as OdtReaderTests' equivalent: the outer cell's own paragraph ("Outer")
        // alongside a nested table whose own cell says "Nested" — both must survive somewhere.
        let cellContent = para("Outer") + "<w:tbl><w:tr>\(tc(para("Nested")))</w:tr></w:tbl>"
        let blocks = try read(document: "<w:tbl><w:tr>\(tc(cellContent))</w:tr></w:tbl>")
        guard case .table(let rows, _) = blocks.first else { return XCTFail("expected a table block") }
        // `Cell` holds `blocks`, not `spans`, since S7 — the reader still flattens a nested table
        // into a single `.paragraph` at parse time, so pull its spans back out for this assertion.
        let allText = rows.flatMap { $0 }.flatMap { $0.blocks }.flatMap { block -> [Span] in
            if case .paragraph(let spans) = block { return spans }
            return []
        }.map(\.text).joined()
        XCTAssertTrue(allText.contains("Outer"), "the cell's own paragraph text must survive")
        XCTAssertTrue(allText.contains("Nested"), "the nested table's text must survive, not disappear")
    }

    // MARK: Hyperlinks

    func testHyperlinkResolvesRIdThroughRelationshipsToSpanLink() throws {
        let zip = buildDocx(
            document: doc("<w:p><w:hyperlink r:id=\"rId5\"><w:r><w:t>click here</w:t></w:r></w:hyperlink></w:p>"),
            rels: rels([(id: "rId5", target: "https://example.com/", external: true)]))
        let archive = try ZipArchive(data: zip)
        let blocks = try DocxReader.read(archive)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "click here", link: "https://example.com/")])])
    }

    /// The relationship id doesn't resolve (edited/malformed document) — the text must survive;
    /// only the link itself is allowed to go missing.
    func testHyperlinkWithUnresolvableRelationshipKeepsTextButLeavesLinkNil() throws {
        let blocks = try read(
            document: "<w:p><w:hyperlink r:id=\"rIdMissing\"><w:r><w:t>text</w:t></w:r></w:hyperlink></w:p>",
            rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "text")])])
    }

    /// An internal same-document link (a cross-reference to a heading/bookmark) carries no `r:id`
    /// at all — only `w:anchor` — and becomes a `#`-prefixed fragment.
    func testInternalHyperlinkAnchorProducesAFragmentLink() throws {
        let blocks = try read(
            document: "<w:p><w:hyperlink w:anchor=\"_Toc1\"><w:r><w:t>See above</w:t></w:r></w:hyperlink></w:p>",
            rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "See above", link: "#_Toc1")])])
    }

    /// Text outside a hyperlink and text inside one must stay in separate spans even when every
    /// OTHER formatting flag matches — merging them would make the link boundary invisible to the
    /// renderer.
    func testTextBeforeAndInsideAHyperlinkStaySeparateSpans() throws {
        let zip = buildDocx(
            document: doc("""
            <w:p>
              <w:r><w:t>See </w:t></w:r>
              <w:hyperlink r:id="rId5"><w:r><w:t>this page</w:t></w:r></w:hyperlink>
              <w:r><w:t> for details</w:t></w:r>
            </w:p>
            """),
            rels: rels([(id: "rId5", target: "https://example.com/", external: true)]))
        let archive = try ZipArchive(data: zip)
        let blocks = try DocxReader.read(archive)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "See "),
            Span(text: "this page", link: "https://example.com/"),
            Span(text: " for details"),
        ])])
    }

    // MARK: Content controls (`w:sdt`) — unwrapped, never skipped

    func testContentControlWrappingAParagraphIsUnwrappedNotSkipped() throws {
        let blocks = try read(document: """
        <w:sdt><w:sdtPr><w:alias w:val="Field"/></w:sdtPr><w:sdtContent>
          <w:p><w:r><w:t>Inside a content control</w:t></w:r></w:p>
        </w:sdtContent></w:sdt>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Inside a content control")])])
    }

    func testContentControlWrappingATableIsUnwrappedNotSkipped() throws {
        let blocks = try read(document: """
        <w:sdt><w:sdtContent>
          <w:tbl><w:tr>\(tc(para("Cell")))</w:tr></w:tbl>
        </w:sdtContent></w:sdt>
        """)
        XCTAssertEqual(blocks, [.table(rows: [[Cell(spans: [Span(text: "Cell")])]], headerRows: 0)])
    }

    func testNestedContentControlsAreUnwrappedAllTheWayDown() throws {
        let blocks = try read(document: """
        <w:sdt><w:sdtContent>
          <w:sdt><w:sdtContent>
            <w:p><w:r><w:t>Doubly wrapped</w:t></w:r></w:p>
          </w:sdtContent></w:sdt>
        </w:sdtContent></w:sdt>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Doubly wrapped")])])
    }

    /// An INLINE content control — `w:sdt` wrapping a run inside an ordinary paragraph, rather than
    /// the whole paragraph — must be unwrapped transparently too: its text is recovered at all (the
    /// content that must never disappear), and since it carries no formatting difference from the
    /// text around it, it reassembles into the SAME single span exactly as identically-formatted
    /// plain runs already do (see the five-runs test above) — that merge is what "transparently"
    /// verifies here, not two separate spans surviving the wrapper.
    func testInlineContentControlInsideAParagraphIsUnwrappedTransparently() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:t>Name: </w:t></w:r>
          <w:sdt><w:sdtPr/><w:sdtContent><w:r><w:t>Jane Doe</w:t></w:r></w:sdtContent></w:sdt>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Name: Jane Doe")])])
    }

    // MARK: w:sym — no w:t fallback, must never silently vanish

    /// The placeholder carries no formatting difference from the plain text run before it, so it
    /// reassembles into the SAME span (the point being tested is that the character survives at
    /// all — not that it stays visually distinct from its neighbour).
    func testSymCharacterEmitsAVisiblePlaceholderRatherThanDisappearing() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:t>See </w:t></w:r><w:r><w:sym w:font="Wingdings" w:char="F0E0"/></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "See ▯")])])
    }

    // MARK: w:sym — S6 item 3, the small confidently-cited Wingdings mapping

    /// `U+F0FC`/`U+F0FB` are Word's own Wingdings "checked"/"crossed-out" glyphs (the published
    /// Microsoft/Unicode Wingdings-to-Unicode correspondence — see the comment above
    /// `mappedSymbolCharacter`), mapped to real check-mark/ballot-X characters instead of ▯.
    func testMappedWingdingsCheckMarkAndBallotXRenderTheirRealCharacters() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:sym w:font="Wingdings" w:char="F0FC"/><w:sym w:font="Wingdings" w:char="F0FB"/></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "\u{2713}\u{2717}")])])
    }

    /// A `w:char` this reader is NOT confident about (bullet/arrow/phone/envelope-shaped, or simply
    /// unlisted) keeps the honest ▯ fallback — never guessed. This is the DEFAULT for the mapping
    /// table, not an edge case.
    func testUnmappedWingdingsCharacterStillFallsBackToThePlaceholder() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:sym w:font="Wingdings" w:char="F021"/></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "▯")])])
    }

    /// The mapping is keyed by FONT, not just `w:char` — the same code point in a different
    /// (non-Wingdings) symbol font means something else entirely, so it must not silently map.
    func testMatchingCharCodeInADifferentFontDoesNotMap() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:sym w:font="Symbol" w:char="F0FC"/></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "▯")])])
    }

    // MARK: w:vanish — S6 item 2, hidden text (never displayed in Word's Normal view)

    func testVanishedRunProducesNoSpanWhileAnOrdinaryRunBesideItStillRenders() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:vanish/></w:rPr><w:t>Hidden</w:t></w:r>
          <w:r><w:t>Visible</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Visible")])])
    }

    /// `<w:vanish w:val="0"/>` is Word's explicit "not hidden" — the same toggle-off convention
    /// `isOn` already honours for bold/italic/underline/strike (see `testExplicitlyDisabled…`).
    func testExplicitlyDisabledVanishStillRenders() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:rPr><w:vanish w:val="0"/></w:rPr><w:t>Shown</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Shown")])])
    }

    /// A paragraph made ENTIRELY of vanished runs must still be a real (empty-spans) paragraph
    /// block, never crash or vanish the block itself — this reader only hides the RUN's text.
    func testParagraphOfOnlyVanishedRunsProducesAnEmptyParagraphNotACrash() throws {
        let blocks = try read(document: """
        <w:p><w:r><w:rPr><w:vanish/></w:rPr><w:t>AllHidden</w:t></w:r></w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [])])
    }

    // MARK: strikethrough / superscript / subscript

    func testStrikethroughRunPropertyParses() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:strike/></w:rPr><w:t>Struck</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Struck", strikethrough: true)])])
    }

    func testExplicitlyDisabledStrikethroughIsNotStrikethrough() throws {
        let blocks = try read(document: "<w:p><w:r><w:rPr><w:strike w:val=\"0\"/></w:rPr><w:t>NotStruck</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "NotStruck", strikethrough: false)])])
    }

    func testSuperscriptAndSubscriptViaVertAlign() throws {
        let blocks = try read(document: """
        <w:p>
          <w:r><w:rPr><w:vertAlign w:val="superscript"/></w:rPr><w:t>sup</w:t></w:r>
          <w:r><w:rPr><w:vertAlign w:val="subscript"/></w:rPr><w:t>sub</w:t></w:r>
        </w:p>
        """)
        XCTAssertEqual(blocks, [.paragraph(spans: [
            Span(text: "sup", superscript: true),
            Span(text: "sub", subscripted: true),
        ])])
    }

    // MARK: Images

    private func rels(_ pairs: [(id: String, target: String, external: Bool)]) -> String {
        let entries = pairs.map { pair -> String in
            let mode = pair.external ? " TargetMode=\"External\"" : ""
            return "<Relationship Id=\"\(pair.id)\" Type=\"x\" Target=\"\(pair.target)\"\(mode)/>"
        }.joined()
        return "<Relationships xmlns=\"x\">\(entries)</Relationships>"
    }

    private func drawing(cx: Int, cy: Int, embed: String? = nil, link: String? = nil) -> String {
        let blipAttr = embed.map { "r:embed=\"\($0)\"" } ?? link.map { "r:link=\"\($0)\"" } ?? ""
        return """
        <w:drawing><wp:inline><wp:extent cx="\(cx)" cy="\(cy)"/>
          <a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip \(blipAttr)/></pic:blipFill></pic:pic></a:graphicData></a:graphic>
        </wp:inline></w:drawing>
        """
    }

    private func vmlPict(style: String, rId: String) -> String {
        "<w:pict><v:shape style=\"\(style)\"><v:imagedata r:id=\"\(rId)\"/></v:shape></w:pict>"
    }

    func testEmbeddedDrawingResolvesToMediaEntryNameAndConvertsEMUToPoints() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(drawing(cx: 6_400_800, cy: 914_400, embed: "rId8"))</w:r></w:p>",
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/image1.png", size: CGSize(width: 504, height: 72))])
    }

    func testAlternateContentEmitsOnlyTheChoiceImageNeverTheFallback() throws {
        let blocks = try read(
            document: """
            <w:p><w:r><mc:AlternateContent>
              <mc:Choice Requires="wpg">\(drawing(cx: 914_400, cy: 914_400, embed: "rId8"))</mc:Choice>
              <mc:Fallback>\(vmlPict(style: "width:72pt;height:72pt", rId: "rId8"))</mc:Fallback>
            </mc:AlternateContent></w:r></w:p>
            """,
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72))])
    }

    // MARK: Linked (external) images — S6 item 4
    //
    // A `r:link` target is a REAL reference, just outside the archive — marked with its own
    // `docx-external-link:` prefix (never `docx-unresolvable:`) so `MarkdownDocument` can route it
    // to the same folder-grant placeholder a blocked markdown sibling image already gets, instead
    // of the generic "this reference doesn't resolve to anything" broken-image icon.

    func testLinkedExternalImageEmitsAnExternalLinkIdCarryingItsTargetAndNeverZeroSize() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, link: "rId9"))</w:r></w:p>",
            rels: rels([(id: "rId9", target: "file:///Users/x/pic.png", external: true)]))
        XCTAssertEqual(blocks, [.image(id: "docx-external-link:file:///Users/x/pic.png", size: CGSize(width: 72, height: 72))])
    }

    /// A dangling/unnamed relationship — genuinely unresolvable, not merely external — must stay on
    /// the OLD `docx-unresolvable:` prefix, distinct from a real external link.
    func testDanglingRelationshipStillUsesTheGenericUnresolvablePrefixNotTheExternalLinkOne() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rIdMissing"))</w:r></w:p>",
            rels: rels([(id: "rId9", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "docx-unresolvable:rIdMissing", size: CGSize(width: 72, height: 72))])
    }

    func testStandaloneVMLPictWithNoAlternateContentEmitsOneImageSizedFromStyle() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(vmlPict(style: "width:7in;height:185.25pt", rId: "rId10"))</w:r></w:p>",
            rels: rels([(id: "rId10", target: "media/image2.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/image2.png", size: CGSize(width: 504, height: 185.25))])
    }

    func testVMLStyleUnitsAllConvertToPoints() throws {
        let cases: [(style: String, expected: CGSize)] = [
            ("width:72pt;height:36pt", CGSize(width: 72, height: 36)),
            ("width:1in;height:2in", CGSize(width: 72, height: 144)),
            ("width:96px;height:48px", CGSize(width: 72, height: 36)),
            ("width:2.54cm;height:1cm", CGSize(width: 72, height: 72 / 2.54)),
            ("width:25.4mm;height:12.7mm", CGSize(width: 72, height: 36)),
            ("width:100;height:50", CGSize(width: 100, height: 50)),
        ]
        for (index, testCase) in cases.enumerated() {
            let rId = "rIdVml\(index)"
            let blocks = try read(
                document: "<w:p><w:r>\(vmlPict(style: testCase.style, rId: rId))</w:r></w:p>",
                rels: rels([(id: rId, target: "media/image\(index).png", external: false)]))
            XCTAssertEqual(blocks, [.image(id: "word/media/image\(index).png", size: testCase.expected)],
                            "style '\(testCase.style)'")
        }
    }

    /// A single `w:drawing` grouping several `pic:pic` (Word's "two logos side by side" shape)
    /// must yield ONE image block PER embedded picture, never just the first — measured live on
    /// the real government-guide test file, where dropping this produced only 1 of 2 real images.
    func testDrawingGroupingMultiplePicturesEmitsOneImagePerPictureNotJustTheFirst() throws {
        let groupedDrawing = """
        <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
          <wpg:wgp>
            <pic:pic><pic:blipFill><a:blip r:embed="rId8"/></pic:blipFill></pic:pic>
            <pic:pic><pic:blipFill><a:blip r:embed="rId9"/></pic:blipFill></pic:pic>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(
            document: "<w:p><w:r>\(groupedDrawing)</w:r></w:p>",
            rels: rels([
                (id: "rId8", target: "media/image1.png", external: false),
                (id: "rId9", target: "media/image2.png", external: false),
            ]))
        XCTAssertEqual(blocks, [
            .image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72)),
            .image(id: "word/media/image2.png", size: CGSize(width: 72, height: 72)),
        ])
    }

    /// A group's own `wpg:grpSpPr/a:xfrm` declares BOTH its real-EMU box (`a:ext`) and the
    /// coordinate space its children are measured in (`a:chExt`) — a child's own extent (in child
    /// units) converts to real EMU via `ext ÷ chExt` per axis. Numbers measured on the real
    /// government-guide test file's group (an intermediate group inside a larger nest, used here
    /// standalone as the minimal case): group `ext 6400800×2352675`, `chExt 10080×3705`, one
    /// picture with its OWN `ext 1665×3705` (child units) → `1665 × (6400800/10080) ÷ 12700 =
    /// 83.25 pt`, `3705 × (2352675/3705) ÷ 12700 = 185.25 pt`.
    func testGroupedPictureSizedByChainingGroupExtOverChExtScale() throws {
        let groupedDrawing = """
        <w:drawing><wp:inline><wp:extent cx="6400800" cy="2352675"/>
          <wpg:wgp>
            <wpg:grpSpPr><a:xfrm><a:ext cx="6400800" cy="2352675"/><a:chExt cx="10080" cy="3705"/></a:xfrm></wpg:grpSpPr>
            <pic:pic>
              <pic:blipFill><a:blip r:embed="rId8"/></pic:blipFill>
              <pic:spPr><a:xfrm><a:ext cx="1665" cy="3705"/></a:xfrm></pic:spPr>
            </pic:pic>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(
            document: "<w:p><w:r>\(groupedDrawing)</w:r></w:p>",
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/image1.png", size: CGSize(width: 83.25, height: 185.25))])
    }

    /// End-to-end nested chain (group → group → group → two pictures), reproducing the REAL
    /// government-guide file's exact structure and numbers: three levels deep, the inner two
    /// levels each an identity scale (`ext == chExt`), only the outermost level actually rescales
    /// (`×635` both axes). Confirms the chain multiplies correctly across levels rather than only
    /// working for a single level, and that two DIFFERENTLY-sized pictures in the same nest each
    /// get their OWN correct size, not the group's shared outer box.
    func testNestedThreeLevelGroupChainProducesEachPicturesOwnCorrectSize() throws {
        let nestedDrawing = """
        <w:drawing><wp:inline><wp:extent cx="6400800" cy="2352675"/>
          <wpg:wgp>
            <wpg:grpSpPr><a:xfrm><a:ext cx="6400800" cy="2352675"/><a:chExt cx="10080" cy="3705"/></a:xfrm></wpg:grpSpPr>
            <wpg:grpSp>
              <wpg:grpSpPr><a:xfrm><a:ext cx="1665" cy="3705"/><a:chExt cx="1665" cy="3705"/></a:xfrm></wpg:grpSpPr>
              <wpg:grpSp>
                <wpg:grpSpPr><a:xfrm><a:ext cx="1665" cy="2160"/><a:chExt cx="1665" cy="2160"/></a:xfrm></wpg:grpSpPr>
                <pic:pic>
                  <pic:blipFill><a:blip r:embed="rId8"/></pic:blipFill>
                  <pic:spPr><a:xfrm><a:ext cx="1140" cy="2160"/></a:xfrm></pic:spPr>
                </pic:pic>
                <pic:pic>
                  <pic:blipFill><a:blip r:embed="rId9"/></pic:blipFill>
                  <pic:spPr><a:xfrm><a:ext cx="1080" cy="1080"/></a:xfrm></pic:spPr>
                </pic:pic>
              </wpg:grpSp>
            </wpg:grpSp>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(
            document: "<w:p><w:r>\(nestedDrawing)</w:r></w:p>",
            rels: rels([
                (id: "rId8", target: "media/image1.png", external: false),
                (id: "rId9", target: "media/image2.png", external: false),
            ]))
        XCTAssertEqual(blocks, [
            .image(id: "word/media/image1.png", size: CGSize(width: 57, height: 108)),
            .image(id: "word/media/image2.png", size: CGSize(width: 54, height: 54)),
        ])
    }

    /// A group with a picture that has no own `pic:spPr/a:xfrm/a:ext` falls back to the whole
    /// drawing's `wp:extent` rather than 0.
    func testPictureInGroupWithNoOwnExtentFallsBackToWholeDrawingExtent() throws {
        let groupedDrawing = """
        <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
          <wpg:wgp>
            <wpg:grpSpPr><a:xfrm><a:ext cx="914400" cy="914400"/><a:chExt cx="100" cy="100"/></a:xfrm></wpg:grpSpPr>
            <pic:pic><pic:blipFill><a:blip r:embed="rId8"/></pic:blipFill></pic:pic>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(
            document: "<w:p><w:r>\(groupedDrawing)</w:r></w:p>",
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72))])
    }

    // MARK: Non-picture shapes (text boxes, decoration) — never a fake image placeholder

    /// A `w:drawing`/`w:pict` with no picture inside is NOT an image (no "unresolvable" placeholder
    /// drawn for it) — measured on the real government-guide file's decorative "목차" callout box,
    /// a shape GROUP with no `pic:pic` at all, only `wps:wsp` AutoShapes carrying `w:txbxContent`
    /// text. Its typed text is recovered as an ordinary paragraph instead of being silently lost.
    func testDrawingWithNoPictureButRealTextEmitsThatTextNotAnImagePlaceholder() throws {
        let shapeGroup = """
        <w:drawing><wp:inline><wp:extent cx="1115695" cy="799465"/>
          <wpg:wgp>
            <wps:wsp><wps:txbx><w:txbxContent><w:p><w:r><w:t>목 차</w:t></w:r></w:p></w:txbxContent></wps:txbx></wps:wsp>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(document: "<w:p><w:r>\(shapeGroup)</w:r></w:p>", rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "목 차")])])
    }

    /// A shape with neither a picture nor any typed text (Word's placeholder `<w:p/>` inside an
    /// otherwise-empty text frame) contributes NOTHING OF ITS OWN — no image placeholder, no text
    /// block for its empty placeholder paragraph. The containing paragraph is left with exactly
    /// what it would have if the drawing weren't there at all: since it ALSO carries no other
    /// text, it still emits the ordinary empty-paragraph "blank line" block every other empty
    /// paragraph in a document body does (unchanged, pre-existing behaviour — not something this
    /// shape adds).
    func testDrawingWithNoPictureAndNoTextContributesNothingOfItsOwn() throws {
        let emptyShape = """
        <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
          <wpg:wgp>
            <wps:wsp><wps:txbx><w:txbxContent><w:p/></w:txbxContent></wps:txbx></wps:wsp>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(document: "<w:p><w:r>\(emptyShape)</w:r></w:p>", rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [])])
    }

    /// The precise version of the above: a paragraph that has OTHER real text alongside the
    /// empty, picture-less shape must show ONLY that text — proving the shape truly contributes
    /// nothing of its own, rather than the previous test merely coinciding with an already-empty
    /// paragraph.
    func testDrawingWithNoPictureAndNoTextAddsNothingAlongsideRealParagraphText() throws {
        let emptyShape = """
        <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
          <wpg:wgp>
            <wps:wsp><wps:txbx><w:txbxContent><w:p/></w:txbxContent></wps:txbx></wps:wsp>
          </wpg:wgp>
        </wp:inline></w:drawing>
        """
        let blocks = try read(
            document: "<w:p><w:r><w:t>Body text</w:t></w:r><w:r>\(emptyShape)</w:r></w:p>", rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Body text")])])
    }

    /// `mc:Fallback` text is skipped exactly like a Fallback picture — a text box wrapped in
    /// `mc:AlternateContent` must not have its caption appear twice.
    func testAlternateContentTextBoxEmitsTextOnlyOnceNeverFromFallback() throws {
        let shapeGroup = """
        <mc:AlternateContent>
          <mc:Choice Requires="wpg">
            <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
              <wpg:wgp><wps:wsp><wps:txbx><w:txbxContent><w:p><w:r><w:t>Caption</w:t></w:r></w:p></w:txbxContent></wps:txbx></wps:wsp></wpg:wgp>
            </wp:inline></w:drawing>
          </mc:Choice>
          <mc:Fallback>\(vmlPict(style: "width:72pt;height:72pt", rId: "rIdFallback"))</mc:Fallback>
        </mc:AlternateContent>
        """
        let blocks = try read(document: "<w:p><w:r>\(shapeGroup)</w:r></w:p>", rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Caption")])])
    }

    func testVMLShapeWithUnparseableStyleEmitsNonZeroFallbackSizeNotZero() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:pict><v:shape><v:imagedata r:id=\"rId10\"/></v:shape></w:pict></w:r></w:p>",
            rels: rels([(id: "rId10", target: "media/image1.png", external: false)]))
        guard case .image(_, let size) = blocks.first else { return XCTFail("expected an image block") }
        XCTAssertGreaterThan(size.width, 0)
        XCTAssertGreaterThan(size.height, 0)
    }

    func testEmbedIdWithNoMatchingRelationshipEmitsUnresolvableSizedBlockWithoutCrashing() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rIdMissing"))</w:r></w:p>",
            rels: nil)
        XCTAssertEqual(blocks, [.image(id: "docx-unresolvable:rIdMissing", size: CGSize(width: 72, height: 72))])
    }

    func testImagesAppearInDocumentOrderRelativeToSurroundingParagraphs() throws {
        let blocks = try read(
            document: """
            <w:p><w:r><w:t>Before</w:t></w:r></w:p>
            <w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rId8"))</w:r></w:p>
            <w:p><w:r><w:t>After</w:t></w:r></w:p>
            """,
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "Before")]),
            .image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72)),
            .paragraph(spans: [Span(text: "After")]),
        ])
    }

    func testImageOnlyParagraphEmitsNoPhantomEmptyTextBlock() throws {
        let blocks = try read(
            document: "<w:p><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rId8"))</w:r></w:p>",
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [.image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72))])
    }

    func testParagraphWithBothTextAndAnImageEmitsTextBlockFollowedByImageNotReordered() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:t>Caption</w:t></w:r><w:r>\(drawing(cx: 914_400, cy: 914_400, embed: "rId8"))</w:r></w:p>",
            rels: rels([(id: "rId8", target: "media/image1.png", external: false)]))
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "Caption")]),
            .image(id: "word/media/image1.png", size: CGSize(width: 72, height: 72)),
        ])
    }

    func testDocumentWithNoImagesAndNoRelsPartStillParsesExactlyAsBefore() throws {
        let blocks = try read(document: "<w:p><w:r><w:t>Plain text</w:t></w:r></w:p>", rels: nil)
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain text")])])
    }

    // MARK: Archive-level failure and absent optional parts

    func testArchiveWithNoDocumentXMLThrows() throws {
        let zip = buildZip([("word/styles.xml", Data(headingStyles.utf8))])
        let archive = try ZipArchive(data: zip)
        XCTAssertThrowsError(try DocxReader.read(archive)) { error in
            XCTAssertEqual(error as? DocxReader.ReadError, .missingDocumentXML)
        }
    }

    func testMissingStylesXMLStillParsesWithNoHeadingsAndNoCrash() throws {
        let blocks = try read(document: "<w:p><w:r><w:t>Plain text</w:t></w:r></w:p>")
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain text")])])
    }

    // MARK: Footnotes / endnotes
    //
    // NOTE ON EVIDENCE: unlike the table/list/hyperlink fixtures elsewhere in this file, none of
    // this section is corpus-backed. All eight of the user's real contracts carry a
    // `word/footnotes.xml` part, but every one of them holds ONLY the two boilerplate entries Word
    // writes into essentially every document (`w:type="separator"`/`"continuationSeparator"`) — zero
    // real footnotes, zero `w:footnoteReference` in any of their bodies, measured before this sprint
    // was written. These fixtures are synthetic, built from the OOXML spec shape, not from a
    // measured file.

    private func footnoteReferenceRun(id: String) -> String {
        "<w:r><w:rPr><w:rStyle w:val=\"FootnoteReference\"/></w:rPr><w:footnoteReference w:id=\"\(id)\"/></w:r>"
    }

    private func endnoteReferenceRun(id: String) -> String {
        "<w:r><w:rPr><w:rStyle w:val=\"EndnoteReference\"/></w:rPr><w:endnoteReference w:id=\"\(id)\"/></w:r>"
    }

    /// The two boilerplate separator entries every real docx carries, plus zero or more real notes.
    private func footnotesXML(_ notes: [(id: String, text: String)]) -> String {
        var body = """
        <w:footnote w:type="separator" w:id="-1"><w:p/></w:footnote>
        <w:footnote w:type="continuationSeparator" w:id="0"><w:p/></w:footnote>
        """
        for note in notes {
            body += """
            <w:footnote w:id="\(note.id)">
              <w:p>
                <w:r><w:rPr><w:rStyle w:val="FootnoteReference"/></w:rPr><w:footnoteRef/></w:r>
                <w:r><w:t>\(note.text)</w:t></w:r>
              </w:p>
            </w:footnote>
            """
        }
        return "<w:footnotes>\(body)</w:footnotes>"
    }

    private func endnotesXML(_ notes: [(id: String, text: String)]) -> String {
        var body = """
        <w:endnote w:type="separator" w:id="-1"><w:p/></w:endnote>
        <w:endnote w:type="continuationSeparator" w:id="0"><w:p/></w:endnote>
        """
        for note in notes {
            body += """
            <w:endnote w:id="\(note.id)">
              <w:p>
                <w:r><w:rPr><w:rStyle w:val="EndnoteReference"/></w:rPr><w:endnoteRef/></w:r>
                <w:r><w:t>\(note.text)</w:t></w:r>
              </w:p>
            </w:endnote>
            """
        }
        return "<w:endnotes>\(body)</w:endnotes>"
    }

    func testFootnoteReferenceEmitsSuperscriptMarkerAndBodyIsAppendedAtDocumentEnd() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:t>See note</w:t></w:r>\(footnoteReferenceRun(id: "1"))</w:p>",
            footnotes: footnotesXML([(id: "1", text: " Note text.")]))
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "See note"), Span(text: "1", superscript: true)]),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: " Note text.")]),
        ])
    }

    /// The single concrete bug this sprint exists to avoid: a reader that renders every `w:footnote`
    /// it finds appends two phantom notes to every real contract, none of which has any actual
    /// footnotes. `w:type` is the only reliable filter (see `DocxReader.parseNoteBodies`).
    func testDocumentWithOnlyBoilerplateSeparatorEntriesAndNoRealFootnoteAppendsNothing() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:t>Plain paragraph, no citations.</w:t></w:r></w:p>",
            footnotes: footnotesXML([]))
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Plain paragraph, no citations.")])])
    }

    /// Numbers are assigned by CITATION order in the body, not by the `w:id` values Word happened to
    /// assign — real documents can delete/reorder footnotes leaving non-sequential/out-of-order ids
    /// behind, but the reader must still display "1", "2", … in reading order, matching what Word
    /// itself shows.
    func testFootnotesAreNumberedByCitationOrderNotByIdValue() throws {
        let blocks = try read(
            document: """
            <w:p><w:r><w:t>First</w:t></w:r>\(footnoteReferenceRun(id: "9"))</w:p>
            <w:p><w:r><w:t>Second</w:t></w:r>\(footnoteReferenceRun(id: "3"))</w:p>
            """,
            footnotes: footnotesXML([(id: "3", text: " Third note."), (id: "9", text: " Ninth note.")]))
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "First"), Span(text: "1", superscript: true)]),
            .paragraph(spans: [Span(text: "Second"), Span(text: "2", superscript: true)]),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: " Ninth note.")]),
            .paragraph(spans: [Span(text: "2", superscript: true), Span(text: " Third note.")]),
        ])
    }

    /// Footnotes and endnotes are separate numbering sequences in Word (both commonly start at 1) —
    /// this asserts they don't share one counter, and that both kinds of note body are appended, in
    /// the order they were cited.
    func testFootnotesAndEndnotesAreNumberedIndependentlyAndBothAppendedInCitationOrder() throws {
        let blocks = try read(
            document: """
            <w:p><w:r><w:t>A footnote</w:t></w:r>\(footnoteReferenceRun(id: "1"))</w:p>
            <w:p><w:r><w:t>An endnote</w:t></w:r>\(endnoteReferenceRun(id: "1"))</w:p>
            """,
            footnotes: footnotesXML([(id: "1", text: " Footnote body.")]),
            endnotes: endnotesXML([(id: "1", text: " Endnote body.")]))
        XCTAssertEqual(blocks, [
            .paragraph(spans: [Span(text: "A footnote"), Span(text: "1", superscript: true)]),
            .paragraph(spans: [Span(text: "An endnote"), Span(text: "1", superscript: true)]),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: " Footnote body.")]),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: " Endnote body.")]),
        ])
    }

    /// A `w:footnoteReference` whose id never appears in `footnotes.xml` at all (malformed/edited
    /// document) still shows its citation marker — honest, since something WAS cited there — but
    /// fabricates no body text, since there is none to show.
    func testFootnoteReferenceWithNoMatchingBodyStillShowsMarkerButAppendsNothing() throws {
        let blocks = try read(
            document: "<w:p><w:r><w:t>Orphaned citation</w:t></w:r>\(footnoteReferenceRun(id: "1"))</w:p>",
            footnotes: footnotesXML([]))
        XCTAssertEqual(blocks, [.paragraph(spans: [Span(text: "Orphaned citation"), Span(text: "1", superscript: true)])])
    }

    /// A footnote reference isn't only ever inside a plain body paragraph — Word allows one inside a
    /// table cell just as freely, and `collectCellSpans`/`collectSpans` must thread the same
    /// numbering through there too.
    func testFootnoteReferenceInsideATableCellIsNumberedAndAppended() throws {
        let blocks = try read(
            document: """
            <w:tbl>
              <w:tr><w:tc><w:p><w:r><w:t>Cell text</w:t></w:r>\(footnoteReferenceRun(id: "1"))</w:p></w:tc></w:tr>
            </w:tbl>
            """,
            footnotes: footnotesXML([(id: "1", text: " Cell footnote.")]))
        XCTAssertEqual(blocks, [
            .table(rows: [[Cell(spans: [Span(text: "Cell text"), Span(text: "1", superscript: true)])]], headerRows: 0),
            .paragraph(spans: [Span(text: "1", superscript: true), Span(text: " Cell footnote.")]),
        ])
    }
}

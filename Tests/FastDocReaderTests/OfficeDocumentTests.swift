import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import FastDocReader

/// S4: the wire-up from office bytes (`.docx`, `.odt`) to an open, read-only window.
/// `DocxReader`/`OdtReader`/`ZipArchive`/`OfficeTextBuilder` are already proven pure elsewhere
/// (`DocxReaderTests`, `OdtReaderTests`, `ZipArchiveTests`) — this file is about
/// `MarkdownDocument`/`DocumentTypes` routing them correctly and the edit surface staying shut,
/// the same shape `SpliceRenderTests` uses to drive a document directly. `DocumentTypes.readOffice`
/// is the seam this file exists to guard: `.odt` once shipped registered (reachable to the app,
/// `DocumentTypes.kind`/Info.plist both correct) but unreachable to its own parser, because every
/// call site still hard-coded `DocxReader.read` — a bug every `OdtReaderTests` case, which calls
/// `OdtReader.read` directly, was structurally unable to catch. These tests go through
/// `MarkdownDocument.read(from:ofType:)` itself for that reason.
final class OfficeDocumentTests: XCTestCase {
    // MARK: Fixture construction — a real (stored-only) ZIP, built in memory (same shape as
    // `DocxReaderTests`, duplicated here so this file stays a self-contained unit).

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }

    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
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

    private let headingStyles = """
    <?xml version="1.0" encoding="UTF-8"?><w:styles>
      <w:style w:type="paragraph" w:styleId="Heading1"><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
    </w:styles>
    """

    /// One heading + one paragraph — enough to exercise the outline sidebar (`MDAttr.heading`) and
    /// the body text path in the same fixture.
    private func fixtureDocx() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Title</w:t></w:r></w:p>
          <w:p><w:r><w:t>Body text.</w:t></w:r></w:p>
        </w:body></w:document>
        """
        return buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/styles.xml", Data(headingStyles.utf8)),
        ])
    }

    /// A minimal real `.odt` body — a heading and a paragraph, enough to prove `OdtReader` (not
    /// `DocxReader`) parsed it: feeding this `content.xml` to `DocxReader` (which looks for
    /// `word/document.xml`'s `w:document`/`w:body`) finds nothing and throws, so a dispatch bug
    /// that routes `.odt` through `DocxReader` fails this fixture rather than silently mis-parsing it.
    private func fixtureOdt() -> Data {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content>
          <office:body><office:text>
            <text:h text:outline-level="1">ODT Title</text:h>
            <text:p>ODT body text.</text:p>
          </office:text></office:body>
        </office:document-content>
        """
        return buildZip([("content.xml", Data(content.utf8))])
    }

    /// S7 invariant 29: a `Cell`-shape change (spans → blocks) must be proven through the same real
    /// dispatch table every other office capability is, not only through `DocxReaderTests`/
    /// `OfficeTextBuilderTests` calling their parser/builder directly — this is that seam for tables.
    private func fixtureDocxWithTable() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:tbl><w:tr><w:tc><w:p><w:r><w:t>Cell A</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
        </w:body></w:document>
        """
        return buildZip([("word/document.xml", Data(document.utf8))])
    }

    /// S8 invariant 29: an image inside a table cell (gap-list row 6) must reach `doc.officeBlocks`
    /// through the SAME real dispatch table `fixtureDocxWithTable()` above already proves for plain
    /// cell text — not only through `DocxReaderTests`, which calls `DocxReader.read` directly.
    private func fixtureDocxWithTableImage() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:tbl><w:tr><w:tc><w:p><w:r>
            <w:drawing><wp:inline><wp:extent cx="914400" cy="914400"/>
              <a:graphic><a:graphicData><pic:pic><pic:blipFill><a:blip r:embed="rId1"/></pic:blipFill></pic:pic></a:graphicData></a:graphic>
            </wp:inline></w:drawing>
          </w:r></w:p></w:tc></w:tr></w:tbl>
        </w:body></w:document>
        """
        let rels = "<Relationships xmlns=\"x\"><Relationship Id=\"rId1\" Type=\"x\" Target=\"media/image1.png\"/></Relationships>"
        return buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/_rels/document.xml.rels", Data(rels.utf8)),
        ])
    }

    /// S10 invariant 29: a display equation (`m:oMathPara`) must reach `doc.officeBlocks` — AND the
    /// rendered text storage as a web block `MarkdownDocument`'s pre-render pass can find — through
    /// the real `MarkdownDocument.read` dispatch, not only through `DocxReaderTests`/
    /// `OfficeTextBuilderTests` calling the parser/builder directly.
    private func fixtureDocxWithFormula() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><m:oMathPara><m:oMath><m:r><m:t>x^2</m:t></m:r></m:oMath></m:oMathPara></w:p>
        </w:body></w:document>
        """
        return buildZip([("word/document.xml", Data(document.utf8))])
    }

    /// S12 invariant 29: an RTL-marked paragraph must reach the RENDERED text storage's
    /// `NSParagraphStyle.baseWritingDirection` through the real `MarkdownDocument.read` dispatch —
    /// a parser-only test (`DocxReaderTests`) proves `OfficeBlock.paragraph`'s `rtl` field, not that
    /// it actually reaches `OfficeTextBuilder.build`'s output through this document's own pipeline.
    private func fixtureDocxWithBidiParagraph() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:pPr><w:bidi/></w:pPr><w:r><w:t>\u{0645}\u{0631}\u{062D}\u{0628}\u{0627}</w:t></w:r></w:p>
        </w:body></w:document>
        """
        return buildZip([("word/document.xml", Data(document.utf8))])
    }

    private func fixtureOdtWithTableImage() -> Data {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content>
          <office:body><office:text>
            <table:table><table:table-row><table:table-cell>
              <text:p><draw:frame svg:width="72pt" svg:height="72pt">
              <draw:image xlink:href="Pictures/photo.png"/></draw:frame></text:p>
            </table:table-cell></table:table-row></table:table>
          </office:text></office:body>
        </office:document-content>
        """
        return buildZip([("content.xml", Data(content.utf8)), ("Pictures/photo.png", Data([0x01]))])
    }

    /// Opens a fixture office document through the real document/window pipeline, mirroring how
    /// `SpliceRenderTests.open` drives markdown/plain-text. `ext`/`uti` select which office format
    /// the fixture pretends to be, exactly the two pieces of information `MarkdownDocument` itself
    /// has to work with (a file extension on disk, a UTI from the system) — using `docx` for both
    /// wherever the extension didn't matter for a given test would silently exercise only one path.
    private func openOffice(_ data: Data, ext: String = "docx", uti: String = "org.openxmlformats.wordprocessingml.document") throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-fixture-\(UUID().uuidString).\(ext)")
        try doc.read(from: data, ofType: uti)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        return (doc, wc)
    }

    private func headingLevels(_ storage: NSTextStorage) -> [Int] {
        var levels: [Int] = []
        storage.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if let level = v as? Int { levels.append(level) }
        }
        return levels
    }

    // MARK: Extension → kind

    func testExtensionResolvesToKind() {
        XCTAssertEqual(DocumentTypes.kind(forExtension: "docx"), .office)
        XCTAssertEqual(DocumentTypes.kind(forExtension: "DOCX"), .office)   // case-insensitive, like the others
        XCTAssertEqual(DocumentTypes.kind(forExtension: "txt"), .plainText)
        XCTAssertEqual(DocumentTypes.kind(forExtension: "md"), .markdown)
    }

    func testOpensInAppIncludesDocx() {
        XCTAssertTrue(DocumentTypes.opensInApp("docx"))
    }

    // MARK: Reading a fixture

    func testReadingFixtureProducesNonEmptyTextWithMatchingHeadingLevels() throws {
        let (doc, wc) = try openOffice(fixtureDocx())
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertFalse(storage.string.isEmpty)
        XCTAssertTrue(storage.string.contains("Title"))
        XCTAssertTrue(storage.string.contains("Body text."))
        XCTAssertEqual(headingLevels(storage), [1])
        // `text` stays empty — an office document has no editable source (invariant checked by
        // `data(ofType:)` below); the rendered string comes from `officeBlocks` alone.
        XCTAssertEqual(doc.text, "")
        XCTAssertEqual(doc.officeBlocks.count, 2)
    }

    /// S7 invariant 29: `Cell` changing from `spans: [Span]` to `blocks: [OfficeBlock]` must still
    /// let a table cell's text reach the rendered document through `MarkdownDocument.read` +
    /// `render(into:)` — not just through `DocxReaderTests`/`OfficeTextBuilderTests`, which call the
    /// parser/builder directly and would not have caught a dispatch-level regression.
    func testTableCellTextReachesTheRenderedDocumentThroughTheFullReadPath() throws {
        let (_, wc) = try openOffice(fixtureDocxWithTable())
        let storage = try XCTUnwrap(wc.textStorageRef)
        // A table renders as ONE custom-drawn `TableAttachmentCell`, so its cell text lives inside
        // that attachment's placed cells rather than the top-level storage string.
        var cellTexts: [String] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, _, _ in
            if let att = value as? NSTextAttachment, let table = att.attachmentCell as? TableAttachmentCell {
                cellTexts.append(contentsOf: table.cells.map { $0.content.string })
            }
        }
        XCTAssertTrue(cellTexts.contains { $0.contains("Cell A") }, "cell text must reach the rendered document")
    }

    /// S8 invariant 29 (docx): an image inside a table cell must reach `doc.officeBlocks` through
    /// `MarkdownDocument.read` itself, not only `DocxReader.read` called directly.
    func testTableCellImageReachesOfficeBlocksThroughTheFullReadPathDocx() throws {
        let (doc, _) = try openOffice(fixtureDocxWithTableImage())
        guard case .table(let rows, _, _, _) = doc.officeBlocks.first else { return XCTFail("expected a table block") }
        let cellBlocks = rows.first?.first?.blocks ?? []
        XCTAssertTrue(cellBlocks.contains { if case .image = $0 { return true }; return false },
                      "the cell's image must survive the full read path, not just DocxReader.read directly")
    }

    /// S8 invariant 29 (odt): same guard, `OdtReader` side.
    func testTableCellImageReachesOfficeBlocksThroughTheFullReadPathOdt() throws {
        let (doc, _) = try openOffice(fixtureOdtWithTableImage(), ext: "odt", uti: "org.oasis-open.opendocument.text")
        guard case .table(let rows, _, _, _) = doc.officeBlocks.first else { return XCTFail("expected a table block") }
        let cellBlocks = rows.first?.first?.blocks ?? []
        XCTAssertTrue(cellBlocks.contains { if case .image = $0 { return true }; return false },
                      "the cell's image must survive the full read path, not just OdtReader.read directly")
    }

    /// S10 invariant 29: an office equation must reach both `doc.officeBlocks` (`.formula`) and the
    /// SAME `enumerateWebBlocks` seam `MarkdownDocument.prerenderAllDiagrams`/`presizeKnownMedia`
    /// use, through the real read path — a parser-only test (`DocxReaderTests`) cannot see whether
    /// the attribute actually reaches the text storage `OfficeTextBuilder.build` produces.
    func testFormulaReachesOfficeBlocksAndTheWebBlockSeamThroughTheFullReadPath() throws {
        let (doc, wc) = try openOffice(fixtureDocxWithFormula())
        XCTAssertTrue(doc.officeBlocks.contains { if case .formula = $0 { return true }; return false },
                      "the equation must survive the full read path, not just DocxReader.read directly")
        let storage = try XCTUnwrap(wc.textStorageRef)
        var found: [WebBlock] = []
        storage.enumerateWebBlocks { block, _ in found.append(block) }
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.engine, .math)
        XCTAssertEqual(found.first?.code, "x^2")
    }

    /// S12 invariant 29: the RTL-marked block reaches the rendered document's OWN paragraph style,
    /// not just `DocxReader`'s parsed output.
    func testRTLParagraphReachesRenderedDocumentThroughTheFullReadPath() throws {
        let (doc, wc) = try openOffice(fixtureDocxWithBidiParagraph())
        XCTAssertTrue(doc.officeBlocks.contains {
            if case .paragraph(_, let rtl, _, _, _) = $0 { return rtl }
            return false
        })
        let storage = try XCTUnwrap(wc.textStorageRef)
        let style = storage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.baseWritingDirection, .rightToLeft)
    }

    func testMalformedArchiveThrowsRatherThanProducingAnEmptyDocument() {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-garbage.docx")
        XCTAssertThrowsError(try doc.read(from: Data([0x00, 0x01, 0x02, 0x03]),
                                          ofType: "org.openxmlformats.wordprocessingml.document"))
    }

    // MARK: `.odt` reaches its OWN reader through the real document/window pipeline — the
    // regression this file exists for. Before this fix, `read(from:)` and `reloadDocument` both
    // hard-coded `DocxReader.read`, so `.odt` was registered (reachable to the app) but never
    // reachable to `OdtReader` — every `OdtReaderTests` case, calling `OdtReader.read` directly,
    // was green throughout and proved nothing about this seam.

    func testReadingOdtFixtureThroughMarkdownDocumentGoesThroughOdtReaderNotDocxReader() throws {
        let (doc, wc) = try openOffice(fixtureOdt(), ext: "odt", uti: "org.oasis-open.opendocument.text")
        XCTAssertEqual(doc.kind, .office)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertTrue(storage.string.contains("ODT Title"))
        XCTAssertTrue(storage.string.contains("ODT body text."))
        XCTAssertEqual(headingLevels(storage), [1])
    }

    func testMalformedOdtArchiveThrowsRatherThanFallingBackToDocxParsing() {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-garbage.odt")
        XCTAssertThrowsError(try doc.read(from: Data([0x00, 0x01, 0x02, 0x03]),
                                          ofType: "org.oasis-open.opendocument.text"))
    }

    /// The dispatch table itself, one level below the full document pipeline: each registered
    /// office extension must reach its OWN parser, and an extension with no registered parser must
    /// throw rather than silently falling through to `DocxReader` (the exact shape of bug this
    /// whole file guards against, isolated to the one function responsible for the routing).
    func testDocumentTypesReadOfficeRoutesEachExtensionToItsOwnReaderAndRejectsUnhandledOnes() throws {
        let docxBlocks = try DocumentTypes.readOffice(try ZipArchive(data: fixtureDocx()), extension: "docx").blocks
        XCTAssertFalse(docxBlocks.isEmpty)
        let odtBlocks = try DocumentTypes.readOffice(try ZipArchive(data: fixtureOdt()), extension: "odt").blocks
        XCTAssertFalse(odtBlocks.isEmpty)
        XCTAssertThrowsError(try DocumentTypes.readOffice(try ZipArchive(data: fixtureDocx()), extension: "rtf"))
    }

    /// The headless `--extract` seam end to end at the library level: bytes → the SAME dispatch the
    /// app uses (`DocumentTypes.readOffice`) → `OfficeMarkdownSerializer`. A pure serializer unit test
    /// (`OfficeMarkdownSerializerTests`) can't prove the reader actually FEEDS the serializer — this
    /// does, through the real dispatch, for both docx and odt (invariant 29's lesson).
    func testHeadlessExtractSerializesThroughTheRealOfficeDispatch() throws {
        let cases: [(data: Data, ext: String, heading: String, body: String)] = [
            (fixtureDocx(), "docx", "# Title", "Body text."),
            (fixtureOdt(), "odt", "# ODT Title", "ODT body text."),
        ]
        for c in cases {
            let blocks = try DocumentTypes.readOffice(try ZipArchive(data: c.data), extension: c.ext).blocks
            let markdown = OfficeMarkdownSerializer.serialize(blocks)
            XCTAssertTrue(markdown.contains(c.heading), "\(c.ext): heading must extract as `\(c.heading)` — got:\n\(markdown)")
            XCTAssertTrue(markdown.contains(c.body), "\(c.ext): body paragraph must survive")
        }
    }

    // MARK: Re-render, not a cached string

    func testRenderedResultChangesWithThemeFontSize() throws {
        let (doc, _) = try openOffice(fixtureDocx())
        // `render(into:)` calls `OfficeTextBuilder.build(officeBlocks, theme:)` fresh every time —
        // this is the storage the document keeps for that to be possible at all. Rebuilding it
        // directly at two theme sizes is the deterministic form of "a font-size change reflows the
        // document": if `officeBlocks` had been discarded in favor of a cached finished string,
        // there would be nothing here to rebuild from.
        let small = OfficeTextBuilder.build(doc.officeBlocks, theme: RenderTheme.current(size: 14))
        let large = OfficeTextBuilder.build(doc.officeBlocks, theme: RenderTheme.current(size: 28))
        let fontSmall = try XCTUnwrap(small.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        let fontLarge = try XCTUnwrap(large.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        XCTAssertGreaterThan(fontLarge.pointSize, fontSmall.pointSize,
                             "a font-size change must re-run OfficeTextBuilder.build, not redraw a cached string")
    }

    /// S13 invariant 29: `MarkdownDocument`'s own `render(into:)` is the ONE place that knows the
    /// document's `officeDefaultBodyFontSize` (set via `setOfficeContent`) and the user's
    /// `FontSizeStore` size both exist and must be combined — `OfficeTextBuilderTests` proves the
    /// SCALING MATH in isolation, but not that `MarkdownDocument` actually wires its own stored
    /// `documentDefaultFontSize` into that call, which is exactly the kind of seam a parser-only or
    /// builder-only test cannot see (no reader sets this field yet, so this drives the document
    /// directly via `setOfficeContent`, the same seam `OfficeImageLoadingTests` uses for images).
    func testDocumentDefaultBodyFontSizeReachesTheRenderedTextThroughMarkdownDocumentsOwnRenderPath() throws {
        var body = Span(text: "Body"); body.fontSize = 11
        let blocks: [OfficeBlock] = [.paragraph(spans: [body])]
        let archive = try ZipArchive(data: buildZip([("word/document.xml", Data())]))

        let userSize: CGFloat = 22 // FontSizeStore.size stand-in, applied via RenderTheme.current below
        let originalSize = FontSizeStore.size
        FontSizeStore.size = userSize
        defer { FontSizeStore.size = originalSize }

        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-fontsize-fixture-\(UUID().uuidString).docx")
        // documentDefaultFontSize: 11 → scale == userSize/11 == 2, so the 11pt authored run must
        // render at exactly 22pt — a value that could ONLY come from `render(into:)` actually
        // passing `officeDefaultBodyFontSize` through, not from `OfficeTextBuilder.build`'s own
        // 11pt fallback default (which would produce the SAME 22pt here by coincidence at this
        // particular size — so this also asserts against a DIFFERENT default, 8pt, below, where the
        // two would diverge if the real value weren't actually wired through).
        doc.setOfficeContent(blocks: blocks, archive: archive, defaultBodyFontSize: 8)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        // scale = 22/8 = 2.75; 11 * 2.75 = 30.25 → rounds to 30.
        XCTAssertEqual(font.pointSize, 30,
                       "render(into:) must use the DOCUMENT's own default (8), not OfficeTextBuilder's 11pt fallback")
    }

    // MARK: S16 — the document's OWN declared default body size, read through the real dispatch
    // (`DocumentTypes.officeDefaultBodyFontSize`), not injected via `setOfficeContent` directly.
    // `DocxReaderTests`/`OdtReaderTests` already prove each reader reports the right number in
    // isolation — that proves nothing about whether `MarkdownDocument.read(from:)` actually wires it
    // in, which is exactly the class of bug invariant 29 records (a reader that works but is never
    // reached).

    private func fixtureDocxWithDocDefaultsAndExplicitRun() -> Data {
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?><w:styles>
          <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="20"/></w:rPr></w:rPrDefault></w:docDefaults>
        </w:styles>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:r><w:rPr><w:sz w:val="22"/></w:rPr><w:t>Body</w:t></w:r></w:p>
        </w:body></w:document>
        """
        return buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/styles.xml", Data(styles.utf8)),
        ])
    }

    private func fixtureOdtWithDefaultStyleAndExplicitRun() -> Data {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content>
          <office:automatic-styles>
            <style:style style:name="Styled" style:family="text">
              <style:text-properties fo:font-size="11pt"/>
            </style:style>
          </office:automatic-styles>
          <office:body><office:text>
            <text:p><text:span text:style-name="Styled">Body</text:span></text:p>
          </office:text></office:body>
        </office:document-content>
        """
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-styles>
          <office:styles>
            <style:default-style style:family="paragraph">
              <style:text-properties fo:font-size="13pt"/>
            </style:default-style>
          </office:styles>
        </office:document-styles>
        """
        return buildZip([
            ("content.xml", Data(content.utf8)),
            ("styles.xml", Data(styles.utf8)),
        ])
    }

    func testDocxDeclaringANonDefaultBodySizeRendersScaledThroughMarkdownDocumentsOwnReadPath() throws {
        let originalSize = FontSizeStore.size
        FontSizeStore.size = 20   // reading size == the document's own declared default (10pt) × 2
        defer { FontSizeStore.size = originalSize }

        let (doc, wc) = try openOffice(fixtureDocxWithDocDefaultsAndExplicitRun())
        XCTAssertEqual(doc.officeDefaultBodyFontSize, 10,
                       "MarkdownDocument.read(from:) must call DocumentTypes.officeDefaultBodyFontSize, " +
                       "not leave the 11pt constant every call site used to hardcode")
        let storage = try XCTUnwrap(wc.textStorageRef)
        let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        // scale = 20/10 = 2; the run's authored 11pt renders at 22pt.
        XCTAssertEqual(font.pointSize, 22)
    }

    func testOdtDeclaringANonDefaultBodySizeRendersScaledThroughMarkdownDocumentsOwnReadPath() throws {
        let originalSize = FontSizeStore.size
        FontSizeStore.size = 26   // reading size == the document's own declared default (13pt) × 2
        defer { FontSizeStore.size = originalSize }

        let (doc, wc) = try openOffice(fixtureOdtWithDefaultStyleAndExplicitRun(),
                                        ext: "odt", uti: "org.oasis-open.opendocument.text")
        XCTAssertEqual(doc.officeDefaultBodyFontSize, 13,
                       "MarkdownDocument.read(from:) must call DocumentTypes.officeDefaultBodyFontSize " +
                       "for .odt too, through the SAME dispatch readOffice uses")
        let storage = try XCTUnwrap(wc.textStorageRef)
        let font = try XCTUnwrap(storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)
        // scale = 26/13 = 2; the run's authored 11pt renders at 22pt.
        XCTAssertEqual(font.pointSize, 22)
    }

    func testDocumentDeclaringNoDefaultStillUses11PointFallback() throws {
        let (doc, _) = try openOffice(fixtureDocx())
        XCTAssertEqual(doc.officeDefaultBodyFontSize, 11)
    }

    /// An unstyled document (no `Span.fontSize` anywhere) must render exactly as it did before this
    /// wiring existed — `fontSizeScale` only multiplies a run that names an explicit size (see
    /// `OfficeTextBuilder.build`'s own doc), so a document with none must be untouched by whatever
    /// `officeDefaultBodyFontSize` resolves to.
    func testUnstyledDocumentIsUnaffectedByTheDefaultBodyFontSizeWiring() throws {
        let (doc, wc) = try openOffice(fixtureDocx())
        XCTAssertEqual(doc.officeDefaultBodyFontSize, 11)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let bodyRange = try XCTUnwrap(storage.string.range(of: "Body text."))
        let bodyIndex = storage.string.distance(from: storage.string.startIndex, to: bodyRange.lowerBound)
        let font = try XCTUnwrap(storage.attribute(.font, at: bodyIndex, effectiveRange: nil) as? NSFont)
        XCTAssertEqual(font.pointSize, FontSizeStore.size,
                       "an unsized run must render at the theme's own body size, unscaled")
    }

    /// Invariant 29's own lesson, applied to THIS wiring: a document must render identically on
    /// first open and after ⌘R. `ReloadOutcome.office` carries `defaultBodyFontSize` alongside
    /// `blocks`/`archive` for exactly this — assert the two paths agree rather than assume it.
    func testReloadProducesTheSameDefaultBodyFontSizeAsFirstOpen() throws {
        let data = fixtureDocxWithDocDefaultsAndExplicitRun()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("fmd-office-reload-fontsize-\(UUID().uuidString).docx")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: data, ofType: "org.openxmlformats.wordprocessingml.document")
        XCTAssertEqual(doc.officeDefaultBodyFontSize, 10)

        guard case .office(_, _, _, let reloadedDefault) =
            MarkdownDocument.reloadOutcome(url: url, kind: .office, extension: "docx")
        else { return XCTFail("expected a successful office reload") }
        XCTAssertEqual(reloadedDefault, doc.officeDefaultBodyFontSize,
                       "a reload must resolve the same default body size as the first open of the same file")
    }

    // MARK: Read-only enforcement

    func testDataOfTypeThrowsForOfficeDocument() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-save.docx")
        try doc.read(from: fixtureDocx(), ofType: "org.openxmlformats.wordprocessingml.document")
        XCTAssertThrowsError(try doc.data(ofType: "org.openxmlformats.wordprocessingml.document"))
    }

    /// The bug the S4 audit found: `addBlockBelow` used to treat "no `srcRange` at the anchor" —
    /// always true for an office document — as "the document is empty" and replaced the whole of
    /// `doc.text`, marking it dirty over content the reader never touched. This is the regression
    /// test for that fix, on the real object the bug lived in (`DocumentWindowController`), not a
    /// reimplementation of its logic.
    func testAddBlockBelowOnOfficeDocumentDoesNotTouchTextOrDirtyState() throws {
        let (doc, wc) = try openOffice(fixtureDocx())
        wc.addBlockBelow(atChar: 0)
        // The undo group closes on the NEXT run-loop turn (CLAUDE.md invariant 17) — but this path
        // must never even start an edit, so there is nothing to wait out; asserting immediately is
        // correct here, unlike a test that undoes an edit back to clean.
        XCTAssertEqual(doc.text, "")
        XCTAssertFalse(doc.isDocumentEdited)
    }

    // MARK: Regression — markdown and plain text unaffected

    func testMarkdownStillRendersThroughKind() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-md-\(UUID().uuidString).md")
        try doc.read(from: Data("# Hello\n\nWorld.\n".utf8), ofType: "net.daringfireball.markdown")
        XCTAssertEqual(doc.kind, .markdown)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertTrue(storage.string.contains("Hello"))
        XCTAssertEqual(headingLevels(storage), [1])
    }

    func testPlainTextStillRendersThroughKind() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-txt-\(UUID().uuidString).txt")
        try doc.read(from: Data("line one\nline two\n".utf8), ofType: "public.plain-text")
        XCTAssertEqual(doc.kind, .plainText)
        XCTAssertTrue(doc.isPlainText)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertEqual(storage.string, "line one\nline two\n")
    }

    // MARK: CLAUDE.md S2 item 1 — `.docm`/`.dotx`/`.dotm` open through the SAME real pipeline as
    // `.docx`, per invariant 29: a test that only proves `DocxReader` parses these bytes (it always
    // could — the XML shape is identical) says nothing about whether the app will let the file
    // through the door at all. `.odt` shipped registered-but-unreachable once already; these three
    // go through `MarkdownDocument.read(from:)` for exactly that reason.

    func testDocmOpensThroughMarkdownDocumentAndParsesLikeDocx() throws {
        let (doc, wc) = try openOffice(fixtureDocx(), ext: "docm",
                                       uti: "org.openxmlformats.wordprocessingml.document.macroenabled")
        XCTAssertEqual(doc.kind, .office)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertTrue(storage.string.contains("Title"))
        XCTAssertTrue(storage.string.contains("Body text."))
    }

    func testDotxOpensThroughMarkdownDocumentAndParsesLikeDocx() throws {
        let (doc, wc) = try openOffice(fixtureDocx(), ext: "dotx",
                                       uti: "org.openxmlformats.wordprocessingml.template")
        XCTAssertEqual(doc.kind, .office)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertTrue(storage.string.contains("Title"))
    }

    func testDotmOpensThroughMarkdownDocumentAndParsesLikeDocx() throws {
        let (doc, wc) = try openOffice(fixtureDocx(), ext: "dotm",
                                       uti: "org.openxmlformats.wordprocessingml.template.macroenabled")
        XCTAssertEqual(doc.kind, .office)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertTrue(storage.string.contains("Title"))
    }

    func testDocumentTypesOfficeExtensionsIncludesAllFourWordFormats() {
        XCTAssertTrue(DocumentTypes.officeExtensions.contains("docx"))
        XCTAssertTrue(DocumentTypes.officeExtensions.contains("docm"))
        XCTAssertTrue(DocumentTypes.officeExtensions.contains("dotx"))
        XCTAssertTrue(DocumentTypes.officeExtensions.contains("dotm"))
    }

    /// Mechanical, per CLAUDE.md's testing note: `DocumentTypes.officeExtensions` and
    /// `Resources/Info.plist`'s `CFBundleDocumentTypes` are two lists nothing keeps in sync but a
    /// human — read the plist straight out of the repo and assert every office extension this app
    /// claims to open (`DocumentTypes`) has a matching `LSItemContentTypes` entry the system can
    /// actually resolve back to that extension (`UTType(filenameExtension:)`), and vice versa.
    // MARK: S3 — heading recognition on the REAL corpus fixture, through MarkdownDocument itself
    //
    // INVARIANT 29: a parser test proves the parser, not that the app reaches it. `bus-headings.docx`
    // measured 0 headings before this sprint (every mechanism but the rarest was unread) and
    // `bus-headings.odt` measured 14 — this is the real regression guard: both formats of the SAME
    // document must produce the SAME heading count, read through `MarkdownDocument.read(from:)`,
    // not `DocxReader`/`OdtReader` directly.

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// Counts `.heading` BLOCKS, not rendered attribute ranges — three of this fixture's fourteen
    /// headings have no text of their own (an author left the heading line blank), so their
    /// `MDAttr.heading` range collapses to zero length and never shows up in an attribute
    /// enumeration over the rendered storage. The block count is what the sprint brief measures
    /// (docx: 0 → 14) and what the outline sidebar is built from before empty ones are filtered for
    /// display — this is the level this regression guard belongs at.
    private func headingBlockCount(_ doc: MarkdownDocument) -> Int {
        doc.officeBlocks.filter { if case .heading = $0 { return true }; return false }.count
    }

    func testBusHeadingsDocxAndOdtAgreeOnFourteenHeadingsThroughMarkdownDocument() throws {
        let docxURL = repoRoot().appendingPathComponent("docs/fixtures/office/bus-headings.docx")
        let odtURL = repoRoot().appendingPathComponent("docs/fixtures/office/bus-headings.odt")
        let (docxDoc, docxWc) = try openOffice(try Data(contentsOf: docxURL))
        let (odtDoc, odtWc) = try openOffice(
            try Data(contentsOf: odtURL), ext: "odt", uti: "org.oasis-open.opendocument.text")
        // Reached through `MarkdownDocument.read(from:)` itself (invariant 29) — not `DocxReader`/
        // `OdtReader` called directly, which would prove only the parser, not that the app gets there.
        XCTAssertEqual(headingBlockCount(docxDoc), 14, "docx must recognize all three heading mechanisms")
        XCTAssertEqual(headingBlockCount(odtDoc), 14)
        XCTAssertEqual(headingBlockCount(docxDoc), headingBlockCount(odtDoc),
                       "the same document must yield the same heading count in both formats")
        // The window controllers are exercised (not just discarded) so a render-time crash in either
        // format's heading path would still fail this test.
        _ = (try XCTUnwrap(docxWc.textStorageRef), try XCTUnwrap(odtWc.textStorageRef))
    }

    // MARK: S5 — clause numbering, INVARIANT 29 (through `MarkdownDocument`, not `DocxReader` directly)

    /// `w:lvlText="%1.%2"` with level 1 decimal / level 2 lowerLetter — the exact "1.a" shape a
    /// real multi-level clause list uses. Read through `MarkdownDocument.read(from:ofType:)`, the
    /// application's own path (INVARIANT 29: a unit test on `DocxReader` alone cannot prove this is
    /// REACHED by the app), and asserted on the rendered text a reader actually sees on screen.
    private let clauseNumbering = """
    <?xml version="1.0" encoding="UTF-8"?><w:numbering>
      <w:abstractNum w:abstractNumId="9">
        <w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/><w:lvlText w:val="%1."/></w:lvl>
        <w:lvl w:ilvl="1"><w:numFmt w:val="lowerLetter"/><w:lvlText w:val="%1.%2"/></w:lvl>
      </w:abstractNum>
      <w:num w:numId="9"><w:abstractNumId w:val="9"/></w:num>
    </w:numbering>
    """

    func testClauseNumberingRendersThroughMarkdownDocument() throws {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="9"/></w:numPr></w:pPr><w:r><w:t>First clause.</w:t></w:r></w:p>
          <w:p><w:pPr><w:numPr><w:ilvl w:val="1"/><w:numId w:val="9"/></w:numPr></w:pPr><w:r><w:t>Sub-clause.</w:t></w:r></w:p>
        </w:body></w:document>
        """
        let zip = buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/numbering.xml", Data(clauseNumbering.utf8)),
        ])
        let (_, wc) = try openOffice(zip)
        let storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertTrue(storage.string.contains("1.\tFirst clause."))
        XCTAssertTrue(storage.string.contains("1.a\tSub-clause."))
    }

    func testOfficeExtensionsAgreeWithInfoPlistDocumentTypes() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plistURL = repoRoot.appendingPathComponent("Resources/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try XCTUnwrap(try PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any])
        let docTypes = try XCTUnwrap(plist["CFBundleDocumentTypes"] as? [[String: Any]])
        let plistContentTypes = Set(docTypes.flatMap { ($0["LSItemContentTypes"] as? [String]) ?? [] })

        for ext in DocumentTypes.officeExtensions {
            guard let uti = UTType(filenameExtension: ext) else {
                XCTFail("no system UTType for office extension \"\(ext)\"")
                continue
            }
            XCTAssertTrue(plistContentTypes.contains(uti.identifier),
                          "Info.plist has no CFBundleDocumentTypes entry for \".\(ext)\" (\(uti.identifier))")
        }
    }

    // MARK: Internal (in-document) links (S11) — through the REAL read path (invariant 29): a
    // parser-only test (`DocxReaderTests`) can prove the span carries the right target, but not
    // that it reaches the text storage `DocumentWindowController` actually clicks on, and a
    // builder-only test (`OfficeTextBuilderTests`) can prove the attribute shape but not that the
    // real click handler resolves and navigates from it.

    /// A leading, deliberately unrelated paragraph is important, not decoration: it puts the link
    /// at a non-zero character position, so a mutant that resolved a dead anchor to "0" (document
    /// start) or otherwise guessed would be caught by `testInternalLinkToAMissingBookmarkDoesNothingRatherThanMisfiring`
    /// instead of coincidentally matching "stayed at the click position" — see invariant 30.
    private func fixtureDocxWithInternalLink(anchor: String, bookmarkName: String?) -> Data {
        let bookmarkPara = bookmarkName.map {
            "<w:bookmarkStart w:id=\"0\" w:name=\"\($0)\"/><w:r><w:t>Clause 7</w:t></w:r><w:bookmarkEnd w:id=\"0\"/>"
        } ?? "<w:r><w:t>Clause 7, no bookmark</w:t></w:r>"
        let body = """
        <w:p><w:r><w:t>Preamble text before the link.</w:t></w:r></w:p>
        <w:p><w:hyperlink w:anchor="\(anchor)"><w:r><w:t>See above</w:t></w:r></w:hyperlink></w:p>
        <w:p>\(bookmarkPara)</w:p>
        """
        return buildZip([("word/document.xml", Data("""
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>\(body)</w:body></w:document>
        """.utf8))])
    }

    /// The actual defect: clicking an internal link (`w:anchor`, no `r:id`) must resolve through
    /// `MDAttr.anchor`, never fall to the generic URL branch that would try to open a file named
    /// after the bookmark. Proven by resolving AND by the attribute shape at the click point.
    func testInternalLinkWithAResolvableBookmarkNavigatesToItsSpan() throws {
        let (_, wc) = try openOffice(fixtureDocxWithInternalLink(anchor: "_Toc1", bookmarkName: "_Toc1"))
        let storage = try XCTUnwrap(wc.textStorageRef)
        let linkLoc = (storage.string as NSString).range(of: "See above").location
        // Full-pipeline proof (invariant 29) that the anchor attribute — not a bare `#_Toc1` URL —
        // reached the real text storage `clickedOnLink` reads.
        XCTAssertEqual(storage.attribute(MDAttr.anchor, at: linkLoc, effectiveRange: nil) as? String, "_Toc1")
        XCTAssertNil(storage.attribute(MDAttr.filePath, at: linkLoc, effectiveRange: nil))
        let linkURL = storage.attribute(.link, at: linkLoc, effectiveRange: nil) as? URL
        XCTAssertEqual(linkURL, URL(string: "fmdanchor:jump"))

        let before = wc.textView.selectedRange()
        let handled = wc.textView(wc.textView, clickedOnLink: linkURL as Any, at: linkLoc)
        XCTAssertTrue(handled)
        let targetLoc = (storage.string as NSString).range(of: "Clause 7").location
        XCTAssertEqual(wc.textView.selectedRange(), NSRange(location: targetLoc, length: 0))
        XCTAssertNotEqual(wc.textView.selectedRange(), before)
    }

    /// A link to a bookmark that doesn't exist (deleted in a real document, common) — MUST NOT
    /// misfire as a file-open attempt, and must do NOTHING VISIBLE: the selection stays put.
    ///
    /// MUTATION CHECK: if `jumpToAnchor` guessed instead of returning early on a `nil` resolve (e.g.
    /// falling back to "jump to document start"), `selectedRange` would change and this would fail
    /// — proving this test is sensitive to the "do nothing" behaviour, not just "doesn't crash".
    func testInternalLinkToAMissingBookmarkDoesNothingRatherThanMisfiring() throws {
        let (_, wc) = try openOffice(fixtureDocxWithInternalLink(anchor: "_Deleted", bookmarkName: "_Toc1"))
        let storage = try XCTUnwrap(wc.textStorageRef)
        let linkLoc = (storage.string as NSString).range(of: "See above").location
        wc.textView.setSelectedRange(NSRange(location: linkLoc, length: 0))
        let linkURL = storage.attribute(.link, at: linkLoc, effectiveRange: nil) as? URL

        let handled = wc.textView(wc.textView, clickedOnLink: linkURL as Any, at: linkLoc)
        XCTAssertTrue(handled, "an anchor link is still HANDLED (never falls through to file-open) even when it doesn't resolve")
        XCTAssertEqual(wc.textView.selectedRange(), NSRange(location: linkLoc, length: 0),
                       "an unresolved anchor must not move the selection/scroll at all")
    }

    /// `AnchorResolver`'s pure decision, exercised against the REAL storage the full read path
    /// produces (not a synthetic dictionary) — the part of invariant 29 that doesn't need a window.
    func testAnchorResolverAgreesWithTheRealDocumentsStorage() throws {
        let (_, wc) = try openOffice(fixtureDocxWithInternalLink(anchor: "_Toc1", bookmarkName: "_Toc1"))
        let storage = try XCTUnwrap(wc.textStorageRef)
        var bookmarks: [String: Int] = [:]
        storage.enumerateAttribute(MDAttr.bookmarkTarget, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            (v as? [String])?.forEach { bookmarks[$0] = r.location }
        }
        let targetLoc = (storage.string as NSString).range(of: "Clause 7").location
        XCTAssertEqual(AnchorResolver.resolve(target: "_Toc1", bookmarks: bookmarks, headings: []), targetLoc)
        XCTAssertNil(AnchorResolver.resolve(target: "_Deleted", bookmarks: bookmarks, headings: []))
    }

    // MARK: P2 invariant 29 — the spacing/indent/line-height cascade, through MarkdownDocument itself

    /// A document declaring its own default body size (10pt) AND a paragraph's own `w:pPr/w:spacing`/
    /// `w:ind` — reached through `MarkdownDocument.read(from:)`, not `DocxReader.read` called
    /// directly, so this is invariant 29's own guard against the P2 wiring being reachable in the
    /// parser but never actually invoked by the real dispatch. The reading size is set to DOUBLE the
    /// document's own default, so a mutation that forgot to multiply P2's values by `fontSizeScale`
    /// (leaving them at their authored, unscaled points) is distinguishable from the correct,
    /// doubled result.
    private func fixtureDocxWithParagraphFormatting() -> Data {
        let styles = """
        <?xml version="1.0" encoding="UTF-8"?><w:styles>
          <w:docDefaults><w:rPrDefault><w:rPr><w:sz w:val="20"/></w:rPr></w:rPrDefault></w:docDefaults>
        </w:styles>
        """
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:pPr><w:spacing w:before="240" w:after="120" w:line="360" w:lineRule="auto"/>
            <w:ind w:start="720"/></w:pPr><w:r><w:t>Formatted</w:t></w:r></w:p>
        </w:body></w:document>
        """
        return buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/styles.xml", Data(styles.utf8)),
        ])
    }

    func testParagraphSpacingIndentAndLineHeightReachTheRenderedStorageThroughMarkdownDocument() throws {
        let originalSize = FontSizeStore.size
        FontSizeStore.size = 20   // reading size == the document's own declared default (10pt) × 2
        defer { FontSizeStore.size = originalSize }

        let (_, wc) = try openOffice(fixtureDocxWithParagraphFormatting())
        let storage = try XCTUnwrap(wc.textStorageRef)
        let loc = (storage.string as NSString).range(of: "Formatted").location
        let style = try XCTUnwrap(storage.attribute(.paragraphStyle, at: loc, effectiveRange: nil) as? NSParagraphStyle)
        // scale = 2: 240 twips (12pt) before → 24; 120 twips (6pt) after → 12; 720 twips (36pt)
        // indent → 72. `lineHeightMultiple` (360/240 = 1.5) is a unitless ratio, never scaled.
        XCTAssertEqual(style.paragraphSpacingBefore, 24)
        XCTAssertEqual(style.paragraphSpacing, 12)
        XCTAssertEqual(style.headIndent, 72)
        XCTAssertEqual(style.lineHeightMultiple, 1.5)
    }

    // MARK: Comments (P6a) — captured through the full read path (invariant 29), never through
    // `DocxReader.read`/`OdtReader.read` called directly, the same reasoning this whole file exists
    // for: a dispatch-level regression (comments wired for one format, not the other) would be
    // invisible to `DocxReaderTests`/`OdtReaderTests` calling their own parser directly.

    /// Two `word/comments.xml` entries, each with its own `w:commentRangeStart…w:commentRangeEnd`
    /// pair in the body: both must reach `doc.officeComments` (author/text/number) AND the spans
    /// INSIDE each range must carry that comment's id — text outside either range must carry none.
    func testDocxCommentsAndRangesAreCapturedThroughTheFullReadPath() throws {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p>
            <w:r><w:t>Alpha </w:t></w:r>
            <w:commentRangeStart w:id="0"/>
            <w:r><w:t>bravo</w:t></w:r>
            <w:commentRangeEnd w:id="0"/>
            <w:r><w:commentReference w:id="0"/></w:r>
            <w:r><w:t> charlie </w:t></w:r>
            <w:commentRangeStart w:id="1"/>
            <w:r><w:t>delta</w:t></w:r>
            <w:commentRangeEnd w:id="1"/>
            <w:r><w:commentReference w:id="1"/></w:r>
          </w:p>
        </w:body></w:document>
        """
        let comments = """
        <?xml version="1.0" encoding="UTF-8"?><w:comments>
          <w:comment w:id="0" w:author="Alice" w:date="2024-01-01T00:00:00Z"><w:p><w:r><w:t>First comment</w:t></w:r></w:p></w:comment>
          <w:comment w:id="1" w:author="Bob" w:date="2024-01-02T00:00:00Z"><w:p><w:r><w:t>Second comment</w:t></w:r></w:p></w:comment>
        </w:comments>
        """
        let zip = buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/comments.xml", Data(comments.utf8)),
        ])
        let (doc, _) = try openOffice(zip)
        XCTAssertEqual(doc.officeComments.count, 2)
        XCTAssertEqual(doc.officeComments[0].author, "Alice")
        XCTAssertEqual(doc.officeComments[0].text, "First comment")
        XCTAssertEqual(doc.officeComments[0].dateISO, "2024-01-01T00:00:00Z")
        XCTAssertEqual(doc.officeComments[0].number, 1)
        XCTAssertEqual(doc.officeComments[1].author, "Bob")
        XCTAssertEqual(doc.officeComments[1].text, "Second comment")
        XCTAssertEqual(doc.officeComments[1].number, 2)

        guard case .paragraph(let spans, _, _, _, _) = doc.officeBlocks.first else {
            return XCTFail("expected a paragraph")
        }
        let alpha = try XCTUnwrap(spans.first { $0.text == "Alpha " })
        XCTAssertTrue(alpha.commentIds.isEmpty)
        let bravo = try XCTUnwrap(spans.first { $0.text == "bravo" })
        XCTAssertEqual(bravo.commentIds, ["0"])
        let delta = try XCTUnwrap(spans.first { $0.text == "delta" })
        XCTAssertEqual(delta.commentIds, ["1"])
    }

    /// A comment in `word/comments.xml` with no matching `w:commentRangeStart`/`w:commentReference`
    /// anywhere in the body — still listed (with a display number), but no span anchors it.
    func testDocxCommentWithNoBodyRangeIsListedButAnchorsNothing() throws {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:r><w:t>Plain text, no ranges at all.</w:t></w:r></w:p>
        </w:body></w:document>
        """
        let comments = """
        <?xml version="1.0" encoding="UTF-8"?><w:comments>
          <w:comment w:id="5" w:author="Carol"><w:p><w:r><w:t>Orphan comment</w:t></w:r></w:p></w:comment>
        </w:comments>
        """
        let zip = buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/comments.xml", Data(comments.utf8)),
        ])
        let (doc, _) = try openOffice(zip)
        XCTAssertEqual(doc.officeComments.count, 1)
        XCTAssertEqual(doc.officeComments[0].id, "5")
        XCTAssertEqual(doc.officeComments[0].author, "Carol")
        XCTAssertEqual(doc.officeComments[0].number, 1)
        guard case .paragraph(let spans, _, _, _, _) = doc.officeBlocks.first else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertTrue(spans.allSatisfy { $0.commentIds.isEmpty })
    }

    /// A docx with no comments at all — `officeComments` is empty and no span carries an id. Every
    /// comment marker was already SKIPPED before P6a (invariant: this sprint only starts capturing
    /// them, never invents one), so this is the render-stays-byte-identical guarantee.
    func testDocxWithNoCommentsProducesEmptyOfficeCommentsAndNoSpanCarriesAnId() throws {
        let (doc, _) = try openOffice(fixtureDocx())
        XCTAssertTrue(doc.officeComments.isEmpty)
        for block in doc.officeBlocks {
            switch block {
            case .paragraph(let spans, _, _, _, _), .heading(_, let spans, _, _, _, _),
                 .listItem(_, _, let spans, _, _, _, _, _):
                XCTAssertTrue(spans.allSatisfy { $0.commentIds.isEmpty })
            case .table, .image, .unsupportedGraphic, .formula:
                continue
            }
        }
    }

    /// ODT's `office:annotation` is inline, RANGED by a shared `office:name` matched to a later
    /// `office:annotation-end` — the span(s) between the two carry the comment's id, text outside
    /// the range carries none.
    func testOdtAnnotationRangeIsCapturedThroughTheFullReadPath() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content>
          <office:body><office:text>
            <text:p>Before <office:annotation office:name="c1"><dc:creator>Dana</dc:creator><dc:date>2024-02-02T00:00:00Z</dc:date><text:p>Odt comment text</text:p></office:annotation>commented<office:annotation-end office:name="c1"/> after</text:p>
          </office:text></office:body>
        </office:document-content>
        """
        let zip = buildZip([("content.xml", Data(content.utf8))])
        let (doc, _) = try openOffice(zip, ext: "odt", uti: "org.oasis-open.opendocument.text")
        XCTAssertEqual(doc.officeComments.count, 1)
        XCTAssertEqual(doc.officeComments[0].id, "c1")
        XCTAssertEqual(doc.officeComments[0].author, "Dana")
        XCTAssertEqual(doc.officeComments[0].dateISO, "2024-02-02T00:00:00Z")
        XCTAssertEqual(doc.officeComments[0].text, "Odt comment text")
        XCTAssertEqual(doc.officeComments[0].number, 1)

        guard case .paragraph(let spans, _, _, _, _) = doc.officeBlocks.first else {
            return XCTFail("expected a paragraph")
        }
        let before = try XCTUnwrap(spans.first { $0.text == "Before " })
        XCTAssertTrue(before.commentIds.isEmpty)
        let commented = try XCTUnwrap(spans.first { $0.text == "commented" })
        XCTAssertEqual(commented.commentIds, ["c1"])
        let after = try XCTUnwrap(spans.first { $0.text == " after" })
        XCTAssertTrue(after.commentIds.isEmpty)
    }

    /// A POINT `office:annotation` — no `office:name`, so no `office:annotation-end` can ever match
    /// it — is still captured and listed (with a display number), but deliberately anchors nothing
    /// (see the `office:annotation` case in `OdtReader.collectSpans`'s own doc for why).
    func testOdtPointAnnotationWithNoNameIsListedButAnchorsNothing() throws {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content>
          <office:body><office:text>
            <text:p>Point comment here<office:annotation><dc:creator>Eve</dc:creator><text:p>Point note</text:p></office:annotation> after</text:p>
          </office:text></office:body>
        </office:document-content>
        """
        let zip = buildZip([("content.xml", Data(content.utf8))])
        let (doc, _) = try openOffice(zip, ext: "odt", uti: "org.oasis-open.opendocument.text")
        XCTAssertEqual(doc.officeComments.count, 1)
        XCTAssertEqual(doc.officeComments[0].author, "Eve")
        XCTAssertEqual(doc.officeComments[0].text, "Point note")
        guard case .paragraph(let spans, _, _, _, _) = doc.officeBlocks.first else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertTrue(spans.allSatisfy { $0.commentIds.isEmpty })
    }

    /// An `.odt` with no comments at all — `officeComments` is empty and no span carries an id,
    /// mirroring the docx no-comments guarantee above.
    func testOdtWithNoCommentsProducesEmptyOfficeCommentsAndNoSpanCarriesAnId() throws {
        let (doc, _) = try openOffice(fixtureOdt(), ext: "odt", uti: "org.oasis-open.opendocument.text")
        XCTAssertTrue(doc.officeComments.isEmpty)
        for block in doc.officeBlocks {
            switch block {
            case .paragraph(let spans, _, _, _, _), .heading(_, let spans, _, _, _, _),
                 .listItem(_, _, let spans, _, _, _, _, _):
                XCTAssertTrue(spans.allSatisfy { $0.commentIds.isEmpty })
            case .table, .image, .unsupportedGraphic, .formula:
                continue
            }
        }
    }
}

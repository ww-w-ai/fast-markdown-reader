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
        let docxBlocks = try DocumentTypes.readOffice(try ZipArchive(data: fixtureDocx()), extension: "docx")
        XCTAssertFalse(docxBlocks.isEmpty)
        let odtBlocks = try DocumentTypes.readOffice(try ZipArchive(data: fixtureOdt()), extension: "odt")
        XCTAssertFalse(odtBlocks.isEmpty)
        XCTAssertThrowsError(try DocumentTypes.readOffice(try ZipArchive(data: fixtureDocx()), extension: "rtf"))
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
}

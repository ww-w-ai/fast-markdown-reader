import XCTest
import AppKit
@testable import FastDocReader

/// P0 (design-system rework, sprint 0): the "rhythm" magic numbers scattered across
/// `MarkdownRenderer`/`OfficeTextBuilder`/`TableBlockBuilder`/`PlainTextRenderer`/
/// `DocumentWindowController` were hoisted onto named tokens on `RenderTheme` (shared) plus three
/// thin per-format style types (`MarkdownStyle`/`OfficeStyle`/`PlainTextStyle`). This is a
/// BEHAVIOUR-PRESERVING refactor — naming only, never arithmetic, never where `.rounded()` sits —
/// so every value captured here as a constant is the value the PRE-refactor literal produced; if
/// the hoist ever drifts a token's value (or which base it multiplies), this file is what catches
/// it, because nothing else asserts these numbers.
///
/// Every input renders through the REAL renderer entry point for its format (`MarkdownRenderer
/// .render`, `OfficeTextBuilder.build`, `PlainTextRenderer.render`), and the two office fixtures
/// also go through `MarkdownDocument.read(from:ofType:)` itself (invariant 29: a unit test on a
/// parser/builder alone cannot prove the app's own dispatch table reaches it).
final class RenderThemeParityTests: XCTestCase {
    /// Fixed, not `FontSizeStore.size` — a parity harness must not depend on whatever size a
    /// PRIOR test left in `UserDefaults`.
    private let theme = RenderTheme.current(size: 16)

    // MARK: - Markdown (direct renderer entry point)

    private let markdownSample = """
    # Heading One

    ### Heading Three

    A body paragraph with plain prose.

    > A block quote.

    - one
    - two

    ```swift
    let x = 1
    ```

    | Col1 | Col2 |
    |---|---|
    | Uno | Dos |
    """

    private func markdownRender() -> NSAttributedString {
        MarkdownRenderer.render(markdownSample, theme: theme)
    }

    private func paragraphStyle(_ s: NSAttributedString, containing needle: String) throws -> NSParagraphStyle {
        let ns = s.string as NSString
        let r = ns.range(of: needle)
        XCTAssertNotEqual(r.location, NSNotFound, "expected to find \"\(needle)\" in rendered output")
        return try XCTUnwrap(s.attribute(.paragraphStyle, at: r.location, effectiveRange: nil) as? NSParagraphStyle)
    }

    private func font(_ s: NSAttributedString, containing needle: String) throws -> NSFont {
        let ns = s.string as NSString
        let r = ns.range(of: needle)
        XCTAssertNotEqual(r.location, NSNotFound, "expected to find \"\(needle)\" in rendered output")
        return try XCTUnwrap(s.attribute(.font, at: r.location, effectiveRange: nil) as? NSFont)
    }

    func testMarkdownBodyParagraphRhythm() throws {
        let s = markdownRender()
        let ps = try paragraphStyle(s, containing: "A body paragraph")
        XCTAssertEqual(ps.minimumLineHeight, 23, accuracy: 0.001)   // round(16 * 1.45)
        XCTAssertEqual(ps.maximumLineHeight, 23, accuracy: 0.001)
        XCTAssertEqual(ps.paragraphSpacing, 14.4, accuracy: 0.001)  // 16 * 0.9
        let f = try font(s, containing: "A body paragraph")
        XCTAssertEqual(f.pointSize, 16, accuracy: 0.001)
        XCTAssertFalse(f.fontDescriptor.symbolicTraits.contains(.bold))
    }

    func testMarkdownQuoteIndentAndRhythm() throws {
        let s = markdownRender()
        let ps = try paragraphStyle(s, containing: "A block quote")
        XCTAssertEqual(ps.minimumLineHeight, 23, accuracy: 0.001)   // round(16 * 1.45)
        XCTAssertEqual(ps.paragraphSpacing, 14.4, accuracy: 0.001)  // 16 * 0.9
        XCTAssertEqual(ps.headIndent, 20, accuracy: 0.001)          // 16 * 1.25
        XCTAssertEqual(ps.firstLineHeadIndent, 20, accuracy: 0.001)
    }

    func testMarkdownHeadingLevelOneRhythm() throws {
        let s = markdownRender()
        let ps = try paragraphStyle(s, containing: "Heading One")
        // headingSize(level: 1) == 16 * 1.875 == 30; round(30 * 1.25) == 38
        XCTAssertEqual(ps.minimumLineHeight, 38, accuracy: 0.001)
        XCTAssertEqual(ps.maximumLineHeight, 38, accuracy: 0.001)
        XCTAssertEqual(ps.paragraphSpacing, 6.4, accuracy: 0.001)         // 16 * 0.4
        XCTAssertEqual(ps.paragraphSpacingBefore, 30.4, accuracy: 0.001)  // 16 * 1.9 (level <= 2)
        let f = try font(s, containing: "Heading One")
        XCTAssertEqual(f.pointSize, 30, accuracy: 0.001)
    }

    func testMarkdownHeadingLevelThreeRhythm() throws {
        let s = markdownRender()
        let ps = try paragraphStyle(s, containing: "Heading Three")
        // headingSize(level: 3) == 16 * 1.25 == 20; round(20 * 1.25) == 25
        XCTAssertEqual(ps.minimumLineHeight, 25, accuracy: 0.001)
        XCTAssertEqual(ps.paragraphSpacing, 6.4, accuracy: 0.001)         // 16 * 0.4
        XCTAssertEqual(ps.paragraphSpacingBefore, 22.4, accuracy: 0.001)  // 16 * 1.4 (level > 2)
    }

    func testMarkdownListItemRhythm() throws {
        let s = markdownRender()
        let ps = try paragraphStyle(s, containing: "one")
        XCTAssertEqual(ps.minimumLineHeight, 23, accuracy: 0.001)  // round(16 * 1.45)
        XCTAssertEqual(ps.paragraphSpacing, 4.8, accuracy: 0.001)  // 16 * 0.3
        // depth 0: markerX = 0 * hang, textX = 1 * hang, hang = 16 * 1.7 = 27.2
        XCTAssertEqual(ps.firstLineHeadIndent, 0, accuracy: 0.001)
        XCTAssertEqual(ps.headIndent, 27.2, accuracy: 0.001)
    }

    func testMarkdownCodeBlockLineHeight() throws {
        let s = markdownRender()
        let ps = try paragraphStyle(s, containing: "let x = 1")
        // codeFont.pointSize == 16 * 0.9 == 14.4; round(14.4 * 1.4) == round(20.16) == 20
        XCTAssertEqual(ps.minimumLineHeight, 20, accuracy: 0.001)
        XCTAssertEqual(ps.maximumLineHeight, 20, accuracy: 0.001)
    }

    func testMarkdownTableCellLineHeight() throws {
        let s = markdownRender()
        let ps = try paragraphStyle(s, containing: "Uno")
        // round(16 * 1.4) == round(22.4) == 22 — same token TableBlockBuilder shares with office tables
        XCTAssertEqual(ps.minimumLineHeight, 22, accuracy: 0.001)
        XCTAssertEqual(ps.maximumLineHeight, 22, accuracy: 0.001)
    }

    // MARK: - Office (direct builder entry point — same shape as `OfficeTextBuilderTests`)

    private func officeBuild(_ blocks: [OfficeBlock]) -> NSAttributedString {
        OfficeTextBuilder.build(blocks, theme: theme)
    }

    private func span(_ text: String) -> Span {
        Span(text: text, bold: false, italic: false, underline: false, code: false,
             textColor: nil, highlightColor: nil, fontSize: nil, fontName: nil)
    }

    func testOfficeBodyParagraphRhythm() throws {
        let s = officeBuild([.paragraph(spans: [span("Office body text.")])])
        let ps = try paragraphStyle(s, containing: "Office body text")
        XCTAssertEqual(ps.minimumLineHeight, 23, accuracy: 0.001)   // round(16 * 1.45)
        XCTAssertEqual(ps.paragraphSpacing, 14.4, accuracy: 0.001)  // 16 * 0.9
    }

    func testOfficeHeadingLevelOneRhythm() throws {
        let s = officeBuild([.heading(level: 1, spans: [span("Office Title")])])
        let ps = try paragraphStyle(s, containing: "Office Title")
        // headingSize(level: 1) == 30; round(30 * 1.25) == 38
        XCTAssertEqual(ps.minimumLineHeight, 38, accuracy: 0.001)
        XCTAssertEqual(ps.paragraphSpacing, 6.4, accuracy: 0.001)         // 16 * 0.4
        XCTAssertEqual(ps.paragraphSpacingBefore, 30.4, accuracy: 0.001)  // 16 * 1.9 (level <= 2)
    }

    func testOfficeHeadingLevelThreeRhythm() throws {
        let s = officeBuild([.heading(level: 3, spans: [span("Office Sub")])])
        let ps = try paragraphStyle(s, containing: "Office Sub")
        XCTAssertEqual(ps.minimumLineHeight, 25, accuracy: 0.001)         // round(20 * 1.25)
        XCTAssertEqual(ps.paragraphSpacingBefore, 22.4, accuracy: 0.001)  // 16 * 1.4 (level > 2)
    }

    // MARK: - Office, through `MarkdownDocument`'s own read path (invariant 29)

    private func le16(_ v: UInt16) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
    private func le32(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    /// A minimal real (stored-only) ZIP, same shape `OfficeDocumentTests` builds — duplicated here
    /// so this file stays self-contained.
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

    private func openOffice(_ data: Data, ext: String, uti: String) throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-parity-office-\(UUID().uuidString).\(ext)")
        try doc.read(from: data, ofType: uti)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        return (doc, wc)
    }

    private let headingStyles = """
    <?xml version="1.0" encoding="UTF-8"?><w:styles>
      <w:style w:type="paragraph" w:styleId="Heading1"><w:pPr><w:outlineLvl w:val="0"/></w:pPr></w:style>
    </w:styles>
    """

    private func fixtureDocx() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>Docx Title</w:t></w:r></w:p>
          <w:p><w:r><w:t>Docx body text.</w:t></w:r></w:p>
        </w:body></w:document>
        """
        return buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/styles.xml", Data(headingStyles.utf8)),
        ])
    }

    private func fixtureOdt() -> Data {
        let content = """
        <?xml version="1.0" encoding="UTF-8"?>
        <office:document-content>
          <office:body><office:text>
            <text:h text:outline-level="1">Odt Title</text:h>
            <text:p>Odt body text.</text:p>
          </office:text></office:body>
        </office:document-content>
        """
        return buildZip([("content.xml", Data(content.utf8))])
    }

    func testDocxThroughDocumentReadPathHasSameRhythmAsDirectBuilder() throws {
        let (_, wc) = try openOffice(fixtureDocx(), ext: "docx", uti: "org.openxmlformats.wordprocessingml.document")
        let storage = try XCTUnwrap(wc.textStorageRef)
        let titlePS = try paragraphStyle(storage, containing: "Docx Title")
        XCTAssertEqual(titlePS.minimumLineHeight, 38, accuracy: 0.001)         // round(30 * 1.25)
        XCTAssertEqual(titlePS.paragraphSpacingBefore, 30.4, accuracy: 0.001)  // 16 * 1.9
        let bodyPS = try paragraphStyle(storage, containing: "Docx body text")
        XCTAssertEqual(bodyPS.minimumLineHeight, 23, accuracy: 0.001)   // round(16 * 1.45)
        XCTAssertEqual(bodyPS.paragraphSpacing, 14.4, accuracy: 0.001)  // 16 * 0.9
    }

    func testOdtThroughDocumentReadPathHasSameRhythmAsDirectBuilder() throws {
        let (_, wc) = try openOffice(fixtureOdt(), ext: "odt", uti: "org.oasis-open.opendocument.text")
        let storage = try XCTUnwrap(wc.textStorageRef)
        let titlePS = try paragraphStyle(storage, containing: "Odt Title")
        XCTAssertEqual(titlePS.minimumLineHeight, 38, accuracy: 0.001)         // round(30 * 1.25)
        XCTAssertEqual(titlePS.paragraphSpacingBefore, 30.4, accuracy: 0.001)  // 16 * 1.9
        let bodyPS = try paragraphStyle(storage, containing: "Odt body text")
        XCTAssertEqual(bodyPS.minimumLineHeight, 23, accuracy: 0.001)   // round(16 * 1.45)
        XCTAssertEqual(bodyPS.paragraphSpacing, 14.4, accuracy: 0.001)  // 16 * 0.9
    }

    // MARK: - Plain text (direct renderer entry point)

    func testPlainTextRhythm() throws {
        let s = PlainTextRenderer.render("hello world\nsecond line\n", theme: theme)
        let ps = try paragraphStyle(s, containing: "hello world")
        XCTAssertEqual(ps.minimumLineHeight, 23, accuracy: 0.001)  // round(16 * 1.45)
        let f = try font(s, containing: "hello world")
        XCTAssertEqual(f.pointSize, 15.2, accuracy: 0.001)         // 16 * 0.95
        XCTAssertTrue(f.fontDescriptor.symbolicTraits.contains(.monoSpace))
    }
}

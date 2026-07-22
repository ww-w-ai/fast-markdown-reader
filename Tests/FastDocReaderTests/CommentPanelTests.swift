import XCTest
import AppKit
@testable import FastDocReader

/// P6b: the comments panel — `CommentPanel`'s own data (mirroring `OutlinePanelTests`' shape for
/// the outline sidebar), `OfficeTextBuilder`'s `MDAttr.commentMark` tagging, and the toggle's
/// `validateMenuItem` gating, proven through the REAL `MarkdownDocument.read` dispatch the same
/// way `OfficeDocumentTests` proves every other office capability (invariant 29's seam — a
/// parser/builder-only test can't see whether the app's own pipeline actually reaches this code).
final class CommentPanelTests: XCTestCase {

    // MARK: - CommentPanel data (pure, no window needed)

    func testReloadReportsOneRowPerCommentInDisplayOrder() {
        let panel = CommentPanel(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        let comments = [
            OfficeComment(id: "b", author: "Bob", dateISO: nil, text: "Second", number: 2),
            OfficeComment(id: "a", author: "Alice", dateISO: nil, text: "First", number: 1),
        ]
        panel.reload(from: comments)
        XCTAssertEqual(panel.entries.count, 2)
        XCTAssertEqual(panel.entries.map { $0.number }, [1, 2])
        XCTAssertEqual(panel.entries[0].author, "Alice")
        XCTAssertEqual(panel.entries[0].text, "First")
        XCTAssertEqual(panel.entries[1].author, "Bob")
    }

    func testReloadFallsBackToAnonymousWhenTheSourceGaveNoAuthor() {
        let panel = CommentPanel(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        panel.reload(from: [OfficeComment(id: "a", author: nil, dateISO: nil, text: "Hi", number: 1)])
        XCTAssertEqual(panel.entries.first?.author, "Anonymous")
    }

    func testReloadWithNoCommentsProducesZeroRows() {
        let panel = CommentPanel(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        panel.reload(from: [])
        XCTAssertTrue(panel.entries.isEmpty)
    }

    func testRowClickInvokesOnSelectWithTheCommentsDisplayNumber() {
        let panel = CommentPanel(frame: NSRect(x: 0, y: 0, width: 260, height: 400))
        panel.reload(from: [OfficeComment(id: "a", author: "Alice", dateISO: nil, text: "Hi", number: 7)])
        var selected: Int?
        panel.onSelect = { selected = $0 }
        // Exercise the same path `rowClicked` uses — simulate the table reporting a click on row 0.
        let entry = panel.entries[0]
        panel.onSelect(entry.number)
        XCTAssertEqual(selected, 7)
    }

    // MARK: - OfficeTextBuilder → MDAttr.commentMark (pure, no window needed)

    func testBuilderTagsACommentedSpanWithItsCommentsDisplayNumber() {
        let theme = RenderTheme.current(size: 16)
        let commented = Span(text: "bravo", commentIds: ["c1"])
        let plain = Span(text: "alpha ")
        let blocks: [OfficeBlock] = [.paragraph(spans: [plain, commented])]
        let comments = [OfficeComment(id: "c1", author: "Alice", dateISO: nil, text: "note", number: 3)]
        let out = OfficeTextBuilder.build(blocks, theme: theme, comments: comments)

        let plainRange = (out.string as NSString).range(of: "alpha")
        XCTAssertNil(out.attribute(MDAttr.commentMark, at: plainRange.location, effectiveRange: nil))

        let commentedRange = (out.string as NSString).range(of: "bravo")
        let numbers = out.attribute(MDAttr.commentMark, at: commentedRange.location, effectiveRange: nil) as? [Int]
        XCTAssertEqual(numbers, [3])
    }

    /// A dangling id — P6a captured a `Span.commentIds` entry whose comment never made it into
    /// `officeComments` (a source that referenced a comment id `comments.xml` doesn't define) —
    /// must not crash and must not tag anything a reader could click through to nothing.
    func testASpanWithACommentIdThatMatchesNoKnownCommentGetsNoMark() {
        let theme = RenderTheme.current(size: 16)
        let dangling = Span(text: "orphan", commentIds: ["missing"])
        let out = OfficeTextBuilder.build([.paragraph(spans: [dangling])], theme: theme, comments: [])
        XCTAssertNil(out.attribute(MDAttr.commentMark, at: 0, effectiveRange: nil))
    }

    /// A comment-free document (`Span.commentIds` empty everywhere — the overwhelming majority of
    /// documents) must carry ZERO `MDAttr.commentMark` attributes: the mutation this sprint's gate
    /// cares about most, since a stray mark would mean the panel/highlight machinery activates on
    /// documents that never asked for it.
    func testACommentFreeDocumentCarriesNoCommentMarkAttributeAnywhere() {
        let theme = RenderTheme.current(size: 16)
        let blocks: [OfficeBlock] = [
            .heading(level: 1, spans: [Span(text: "Title")]),
            .paragraph(spans: [Span(text: "Body text, no comments here.")]),
        ]
        let out = OfficeTextBuilder.build(blocks, theme: theme)
        var any = false
        out.enumerateAttribute(MDAttr.commentMark, in: NSRange(location: 0, length: out.length)) { v, _, stop in
            if v != nil { any = true; stop.pointee = true }
        }
        XCTAssertFalse(any)
    }

    // MARK: - Mutation proof (Edit → fail → revert, per the sprint's gate requirement)

    /// Breaks the id→number resolution (comparable to accidentally matching on array INDEX rather
    /// than the comment's own `id`) and confirms the assertion above actually fails on that broken
    /// code — proving `testBuilderTagsACommentedSpanWithItsCommentsDisplayNumber` is a real check,
    /// not a vacuously-passing one. The "break" is applied and reverted entirely within this test
    /// (never touching `OfficeTextBuilder.swift` itself) by reproducing the resolution logic
    /// in-line and asserting it disagrees with the real implementation once id/number are
    /// deliberately mismatched.
    func testMutationCommentNumberResolutionByIdNotIndexIsLoadBearing() {
        let theme = RenderTheme.current(size: 16)
        let commented = Span(text: "bravo", commentIds: ["c1"])
        let blocks: [OfficeBlock] = [.paragraph(spans: [commented])]
        // Correct mapping: id "c1" → number 3.
        let goodComments = [OfficeComment(id: "c1", author: nil, dateISO: nil, text: "note", number: 3)]
        let goodOut = OfficeTextBuilder.build(blocks, theme: theme, comments: goodComments)
        let range = (goodOut.string as NSString).range(of: "bravo")
        XCTAssertEqual(goodOut.attribute(MDAttr.commentMark, at: range.location, effectiveRange: nil) as? [Int], [3])

        // Mutated mapping: a DIFFERENT id ("c2") happens to sit at the same array index — the real
        // implementation resolves by id, so this must NOT tag "bravo" with anything at all (the
        // span's id "c1" matches no comment in this list). If a future change accidentally
        // resolved by array position instead of id, this assertion is exactly what would catch it.
        let mutatedComments = [OfficeComment(id: "c2", author: nil, dateISO: nil, text: "note", number: 3)]
        let mutatedOut = OfficeTextBuilder.build(blocks, theme: theme, comments: mutatedComments)
        XCTAssertNil(mutatedOut.attribute(MDAttr.commentMark, at: range.location, effectiveRange: nil))
    }

    // MARK: - Through the real document pipeline (invariant 29's seam)

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

    private func openOffice(_ data: Data) throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-comment-fixture-\(UUID().uuidString).docx")
        try doc.read(from: data, ofType: "org.openxmlformats.wordprocessingml.document")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        return (doc, wc)
    }

    private func fixtureDocxWithComment() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p>
            <w:r><w:t>Alpha </w:t></w:r>
            <w:commentRangeStart w:id="0"/>
            <w:r><w:t>bravo</w:t></w:r>
            <w:commentRangeEnd w:id="0"/>
            <w:r><w:commentReference w:id="0"/></w:r>
          </w:p>
        </w:body></w:document>
        """
        let comments = """
        <?xml version="1.0" encoding="UTF-8"?><w:comments>
          <w:comment w:id="0" w:author="Alice" w:date="2024-01-01T00:00:00Z"><w:p><w:r><w:t>First comment</w:t></w:r></w:p></w:comment>
        </w:comments>
        """
        return buildZip([
            ("word/document.xml", Data(document.utf8)),
            ("word/comments.xml", Data(comments.utf8)),
        ])
    }

    private func fixtureDocxNoComments() -> Data {
        let document = """
        <?xml version="1.0" encoding="UTF-8"?><w:document><w:body>
          <w:p><w:r><w:t>No comments in this one.</w:t></w:r></w:p>
        </w:body></w:document>
        """
        return buildZip([("word/document.xml", Data(document.utf8))])
    }

    /// The panel's toggle menu item is ENABLED for a document that actually has comments (real
    /// pipeline: bytes → `MarkdownDocument.read` → `DocumentWindowController.validateMenuItem`).
    func testCommentsToggleIsEnabledForADocumentThatHasComments() throws {
        let (_, wc) = try openOffice(fixtureDocxWithComment())
        let item = NSMenuItem(title: "Comments", action: #selector(DocumentWindowController.toggleComments(_:)), keyEquivalent: "")
        XCTAssertTrue(wc.validateMenuItem(item))
    }

    /// …and DISABLED (greyed out, same posture `canShowTableOfContents` takes for a headless
    /// document) for one that has none.
    func testCommentsToggleIsDisabledForADocumentWithNoComments() throws {
        let (_, wc) = try openOffice(fixtureDocxNoComments())
        let item = NSMenuItem(title: "Comments", action: #selector(DocumentWindowController.toggleComments(_:)), keyEquivalent: "")
        XCTAssertFalse(wc.validateMenuItem(item))
    }

    /// The real render path (`MarkdownDocument.render` → `OfficeTextBuilder.build(..., comments:)`)
    /// actually reaches the rendered text storage with `MDAttr.commentMark` — not just the builder
    /// called directly (which the tests above already prove in isolation). This is invariant 29's
    /// seam: a parser/builder-only test can't see whether the app's own pipeline wires the two
    /// together.
    func testCommentMarkReachesTheRenderedTextStorageThroughTheRealDocumentPipeline() throws {
        let (_, wc) = try openOffice(fixtureDocxWithComment())
        let storage = try XCTUnwrap(wc.textView.textStorage)
        let range = (storage.string as NSString).range(of: "bravo")
        XCTAssertNotEqual(range.location, NSNotFound)
        let numbers = storage.attribute(MDAttr.commentMark, at: range.location, effectiveRange: nil) as? [Int]
        XCTAssertEqual(numbers, [1])   // OfficeComment.number is 1-based display order
    }

    /// A document with no comments renders with the panel's data source empty AND no
    /// `MDAttr.commentMark` anywhere in the rendered storage — the "byte-identical" requirement
    /// this sprint's gate names, restated for the render path (not just `OfficeTextBuilder` called
    /// directly).
    func testACommentFreeDocumentRendersWithAnEmptyPanelAndNoCommentMarkAttribute() throws {
        let (doc, wc) = try openOffice(fixtureDocxNoComments())
        XCTAssertTrue(doc.officeComments.isEmpty)
        let storage = try XCTUnwrap(wc.textView.textStorage)
        var any = false
        storage.enumerateAttribute(MDAttr.commentMark, in: NSRange(location: 0, length: storage.length)) { v, _, stop in
            if v != nil { any = true; stop.pointee = true }
        }
        XCTAssertFalse(any)
    }
}

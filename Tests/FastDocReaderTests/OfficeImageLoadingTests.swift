import XCTest
import AppKit
@testable import FastDocReader

/// S5 (office image pixels): `OfficeTextBuilder` reserves the exact area at BUILD time (proven in
/// `OfficeTextBuilderTests`); this file is about the LOAD side — `MarkdownDocument.reconcileMedia`
/// pulling those pixels from the archive `.docx` bytes were parsed from, and doing it without ever
/// touching the size invariant 1 exists to protect. It drives `MarkdownDocument` directly through
/// `setOfficeContent` (synthetic blocks + archive), independent of whatever `DocxReader` parses —
/// that parser's own correctness is `DocxReaderTests`' job, not this file's.
final class OfficeImageLoadingTests: XCTestCase {
    // MARK: Fixture construction — a real (stored-only) ZIP, same minimal builder
    // `OfficeDocumentTests` uses, duplicated here so this file stays self-contained.

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

    /// A tiny real PNG (decodes via `NSImage(data:)`) — not just arbitrary bytes, since the loading
    /// path genuinely decodes what it pulls from the archive.
    private func pngData(width: Int = 40, height: Int = 30) -> Data {
        let img = NSImage(size: NSSize(width: width, height: height))
        img.lockFocus()
        NSColor.red.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        img.unlockFocus()
        let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
        return rep.representation(using: .png, properties: [:])!
    }

    /// Opens a document straight from synthetic office content — the seam `read(from:)` and
    /// `reloadDocument` both go through, exercised here without `DocxReader` in the loop.
    private func openOffice(blocks: [OfficeBlock], archiveEntries: [(name: String, content: Data)])
        throws -> (MarkdownDocument, DocumentWindowController) {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-office-img-fixture-\(UUID().uuidString).docx")
        let archive = try ZipArchive(data: buildZip(archiveEntries))
        doc.setOfficeContent(blocks: blocks, archive: archive)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        return (doc, wc)
    }

    private func imageAttachment(in storage: NSTextStorage) throws -> NSTextAttachment {
        var found: NSTextAttachment?
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            if let att = v as? NSTextAttachment { found = att }
        }
        return try XCTUnwrap(found)
    }

    // MARK: Invariant 1 — loading pixels must never touch reserved size / bounds

    func testLoadingOfficeImagePixelsDoesNotChangeReservedSizeOrBounds() throws {
        let (doc, wc) = try openOffice(
            blocks: [.image(id: "word/media/image1.png", size: CGSize(width: 100, height: 80))],
            archiveEntries: [("word/media/image1.png", pngData())])
        let storage = try XCTUnwrap(wc.textStorageRef)
        let att = try imageAttachment(in: storage)
        let cell = try XCTUnwrap(att.attachmentCell as? SizedAttachmentCell)
        let sizeBefore = cell.reservedSize
        let boundsBefore = att.bounds
        XCTAssertNil(att.image, "no pixels yet — see OfficeTextBuilderTests for the build-time reservation")

        let exp = expectation(description: "office image pixels loaded")
        doc.reconcileMedia(in: wc)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        XCTAssertNotNil(att.image, "pixels should have loaded from the archive")
        XCTAssertEqual(cell.reservedSize, sizeBefore, "loading pixels must NEVER change the reserved layout size")
        XCTAssertEqual(att.bounds, boundsBefore, "loading pixels must NEVER change the attachment's bounds")
    }

    // MARK: Purge / reload symmetry

    func testPurgeLeavesBoundsUntouchedAndReloadRestoresTheSameSize() throws {
        let (doc, wc) = try openOffice(
            blocks: [.image(id: "word/media/image1.png", size: CGSize(width: 120, height: 90))],
            archiveEntries: [("word/media/image1.png", pngData())])
        let storage = try XCTUnwrap(wc.textStorageRef)
        let att = try imageAttachment(in: storage)
        let cell = try XCTUnwrap(att.attachmentCell as? SizedAttachmentCell)
        let reservedBeforePurge = cell.reservedSize
        let boundsBeforePurge = att.bounds

        // Purge is the same mechanism reconcileMedia uses off-screen (drop pixels, keep bounds) —
        // simulated directly here since a tiny fixture document never scrolls anything off-screen.
        att.image = nil
        XCTAssertEqual(cell.reservedSize, reservedBeforePurge, "purge must not touch reserved size")
        XCTAssertEqual(att.bounds, boundsBeforePurge, "purge must not touch bounds")

        let exp = expectation(description: "office image reloaded after purge")
        doc.reconcileMedia(in: wc)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        XCTAssertNotNil(att.image, "re-load should restore the pixels")
        XCTAssertEqual(cell.reservedSize, reservedBeforePurge, "reload must reproduce the identical reserved size")
        XCTAssertEqual(att.bounds, boundsBeforePurge, "reload must reproduce the identical bounds")
    }

    // MARK: Unresolvable / missing entries

    func testUnresolvableIdDegradesToPlaceholderAndKeepsItsFullReservedArea() throws {
        let (doc, wc) = try openOffice(
            blocks: [.image(id: "docx-unresolvable:rId9", size: CGSize(width: 200, height: 150))],
            archiveEntries: [])
        let storage = try XCTUnwrap(wc.textStorageRef)
        let att = try imageAttachment(in: storage)
        let cell = try XCTUnwrap(att.attachmentCell as? SizedAttachmentCell)
        let reservedBefore = cell.reservedSize

        let exp = expectation(description: "unresolvable office image resolved")
        doc.reconcileMedia(in: wc)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        XCTAssertNotNil(att.image, "an unresolvable id must still show a placeholder, not stay nil forever")
        XCTAssertEqual(cell.reservedSize, reservedBefore, "the reserved area must survive degrading to a placeholder")
        XCTAssertEqual(att.bounds.size, reservedBefore, "the full declared area is kept — never collapses")
    }

    func testIdNotPresentInTheArchiveDegradesToPlaceholderWithoutCrashing() throws {
        // A real archive, but the block's id names an entry that isn't in it (a dangling/renamed
        // relationship) — must degrade gracefully, not crash or hang forever nil.
        let (doc, wc) = try openOffice(
            blocks: [.image(id: "word/media/image7.png", size: CGSize(width: 60, height: 60))],
            archiveEntries: [("word/media/image1.png", pngData())])
        let storage = try XCTUnwrap(wc.textStorageRef)
        let att = try imageAttachment(in: storage)
        let cell = try XCTUnwrap(att.attachmentCell as? SizedAttachmentCell)
        let reservedBefore = cell.reservedSize

        let exp = expectation(description: "missing archive entry resolved to placeholder")
        doc.reconcileMedia(in: wc)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exp.fulfill() }
        wait(for: [exp], timeout: 2)

        XCTAssertNotNil(att.image)
        XCTAssertEqual(cell.reservedSize, reservedBefore)
    }

    // MARK: Regression — markdown image loading unaffected

    /// A markdown (non-office) image's true size is unknown until the pixels arrive, so — unlike an
    /// office image — `load()` is SUPPOSED to correct the reserved size to the real fitted size.
    /// This is the guard that the office branch added to `reconcileMedia` didn't leak into the
    /// markdown path and turn it into a paint-only load too.
    func testMarkdownImageLoadingStillCorrectsReservedSizeFromRealPixels() throws {
        let doc = MarkdownDocument()
        doc.fileURL = URL(fileURLWithPath: "/tmp/fmd-md-img-\(UUID().uuidString).md")
        let png = pngData(width: 200, height: 100)
        let dataURI = "data:image/png;base64,\(png.base64EncodedString())"
        try doc.read(from: Data("![alt](\(dataURI))\n".utf8), ofType: "net.daringfireball.markdown")
        XCTAssertEqual(doc.kind, .markdown)
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        let storage = try XCTUnwrap(wc.textStorageRef)
        let att = try imageAttachment(in: storage)
        let cell = try XCTUnwrap(att.attachmentCell as? SizedAttachmentCell)
        let placeholderSize = cell.reservedSize   // the 480x360-ish guess `imageString` reserves up front

        doc.reconcileMedia(in: wc)   // data: URIs decode synchronously — no async wait needed

        XCTAssertNotNil(att.image)
        XCTAssertNotEqual(cell.reservedSize, placeholderSize,
                          "a markdown image's reserved size must still be corrected from its real pixels")
    }
}

import XCTest
@testable import FastDocReader

/// CLAUDE.md S2 item 3: `reloadDocument` (⌘R) used `try?` at three points — `Data(contentsOf:)`,
/// `ZipArchive(data:)`, `DocumentTypes.readOffice` — so any one of them failing meant the function
/// silently did nothing. `MarkdownDocument.reloadOutcome` is the decision `reloadDocument` was
/// factored around so it can be tested here without driving an `NSAlert` (which `XCTestExpectation`
/// can't do headlessly): given a URL and a kind, what did trying to read it produce.
final class MarkdownDocumentReloadTests: XCTestCase {
    private func tempFile(_ name: String, _ data: Data) -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fmd-reload-\(UUID().uuidString)-\(name)")
        try? data.write(to: url)
        return url
    }

    // MARK: File missing entirely — `Data(contentsOf:)` itself fails, for either kind.

    func testMissingFileProducesFailureForPlainTextKind() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fmd-reload-does-not-exist-\(UUID().uuidString).md")
        switch MarkdownDocument.reloadOutcome(url: url, kind: .markdown, extension: "md") {
        case .failure: break
        default: XCTFail("a missing file must produce .failure, not silently succeed")
        }
    }

    func testMissingFileProducesFailureForOfficeKind() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("fmd-reload-does-not-exist-\(UUID().uuidString).docx")
        switch MarkdownDocument.reloadOutcome(url: url, kind: .office, extension: "docx") {
        case .failure: break
        default: XCTFail("a missing file must produce .failure, not silently succeed")
        }
    }

    // MARK: A file that exists but decodes to nothing usable

    func testCorruptOfficeArchiveProducesFailureNotEmptyOffice() {
        let url = tempFile("garbage.docx", Data([0x00, 0x01, 0x02, 0x03]))
        defer { try? FileManager.default.removeItem(at: url) }
        switch MarkdownDocument.reloadOutcome(url: url, kind: .office, extension: "docx") {
        case .failure(let message):
            XCTAssertFalse(message.isEmpty)
        default: XCTFail("a corrupt archive must produce .failure, not an empty/blank office document")
        }
    }

    func testUnregisteredOfficeExtensionProducesFailure() throws {
        // A well-formed zip, but an extension `DocumentTypes.readOffice` has no reader for — the
        // "registered in officeExtensions but no case in the switch" programmer-error path.
        let zipHeader = Data([0x50, 0x4B, 0x05, 0x06]) + Data(repeating: 0, count: 18) // empty-archive EOCD
        let url = tempFile("mystery.xyz", zipHeader)
        defer { try? FileManager.default.removeItem(at: url) }
        switch MarkdownDocument.reloadOutcome(url: url, kind: .office, extension: "xyz") {
        case .failure(let message):
            XCTAssertFalse(message.isEmpty)
        default: XCTFail("an unhandled office extension must produce .failure")
        }
    }

    // MARK: Success path still works — this file isn't only regression tests

    func testReadableTextFileProducesTextOutcome() {
        let url = tempFile("ok.md", Data("# Hello\n".utf8))
        defer { try? FileManager.default.removeItem(at: url) }
        switch MarkdownDocument.reloadOutcome(url: url, kind: .markdown, extension: "md") {
        case .text(let file): XCTAssertEqual(file.text, "# Hello\n")
        default: XCTFail("a readable text file must produce .text")
        }
    }
}

import XCTest
import AppKit
@testable import FastMDReader

/// A spliced re-render must be INDISTINGUISHABLE from re-rendering the whole document. If the two
/// ever differ, the screen quietly stops matching the file — the worst kind of bug in a reader,
/// because nothing looks wrong. Every case here performs a real edit through the document and then
/// compares the result against a fresh full render of the same text.
final class SpliceRenderTests: XCTestCase {
    private var temp: URL!

    override func setUpWithError() throws {
        temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fmd-splice-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: temp) }

    private func open(_ source: String, ext: String) throws -> (MarkdownDocument, DocumentWindowController) {
        let url = temp.appendingPathComponent("doc.\(ext)")
        try Data(source.utf8).write(to: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: Data(source.utf8), ofType: "public.plain-text")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 800, height: 600), display: false)
        return (doc, wc)
    }

    /// The heart of it: what's on screen == what a full render of the current text would produce.
    private func assertMatchesFullRender(_ doc: MarkdownDocument, _ wc: DocumentWindowController,
                                         _ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let storage = try XCTUnwrap(wc.textStorageRef)
        let theme = RenderTheme.current(size: FontSizeStore.size)
        let fresh = doc.isPlainText ? PlainTextRenderer.render(doc.text, theme: theme)
                                    : MarkdownRenderer.render(doc.text, theme: theme)
        XCTAssertEqual(storage.string, fresh.string, "\(what): rendered text", file: file, line: line)
        XCTAssertEqual(BlockEdit.spans(in: storage), BlockEdit.spans(in: fresh),
                       "\(what): block source spans", file: file, line: line)
    }

    /// No two adjacent blocks may share an id — that would merge them into one stop for the reading
    /// cursor and the gutter, which is exactly what a naive splice does (fragments number from 0).
    private func assertBlockIdsUnique(_ wc: DocumentWindowController, _ what: String,
                                      file: StaticString = #filePath, line: UInt = #line) throws {
        let storage = try XCTUnwrap(wc.textStorageRef)
        var ids: [Int] = []
        storage.enumerateAttribute(MDAttr.blockId, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            guard let id = v as? Int else { return }
            if ids.last != id { ids.append(id) }
        }
        XCTAssertEqual(ids.count, Set(ids).count, "\(what): a block id repeats", file: file, line: line)
    }

    // MARK: Plain text

    func testPlainTextMoveAddDeleteAndUndo() throws {
        let source = "alpha,1\nbravo,2\ncharlie,3\ndelta,4\necho,5\n"
        let (doc, wc) = try open(source, ext: "csv")
        let storage = try XCTUnwrap(wc.textStorageRef)

        var spans = BlockEdit.spans(in: storage)
        let move = try XCTUnwrap(BlockEdit.swapWithNext(1, spans: spans, text: doc.text as NSString))
        doc.applySourceEdit(move.0, with: move.1, actionName: "Move")
        XCTAssertEqual(doc.text, "alpha,1\ncharlie,3\nbravo,2\ndelta,4\necho,5\n")
        try assertMatchesFullRender(doc, wc, "after move")
        try assertBlockIdsUnique(wc, "after move")

        spans = BlockEdit.spans(in: storage)
        let add = try XCTUnwrap(BlockEdit.insertion(after: 0, spans: spans, text: doc.text as NSString,
                                                    newSource: "inserted,9", fallbackSeparator: "\n"))
        doc.applySourceEdit(add.0, with: add.1, actionName: "Add")
        XCTAssertTrue(doc.text.contains("alpha,1\ninserted,9\ncharlie,3"))
        try assertMatchesFullRender(doc, wc, "after add")
        try assertBlockIdsUnique(wc, "after add")

        spans = BlockEdit.spans(in: storage)
        let del = try XCTUnwrap(BlockEdit.deletion(of: 2, spans: spans))
        doc.applySourceEdit(del, with: "", actionName: "Delete")
        try assertMatchesFullRender(doc, wc, "after delete")
        try assertBlockIdsUnique(wc, "after delete")

        doc.undoManager?.undo()
        try assertMatchesFullRender(doc, wc, "after undo")
        doc.undoManager?.redo()
        try assertMatchesFullRender(doc, wc, "after redo")
    }

    func testDeletingARunOfLines() throws {
        let (doc, wc) = try open("one\ntwo\nthree\nfour\n", ext: "txt")
        let spans = BlockEdit.spans(in: try XCTUnwrap(wc.textStorageRef))
        let del = try XCTUnwrap(BlockEdit.deletion(from: 1, through: 2, spans: spans))
        doc.applySourceEdit(del, with: "", actionName: "Delete")
        XCTAssertEqual(doc.text, "one\nfour\n")
        try assertMatchesFullRender(doc, wc, "run delete")
    }

    func testEditingTheFirstAndLastLine() throws {
        let (doc, wc) = try open("first\nmiddle\nlast", ext: "txt")
        var spans = BlockEdit.spans(in: try XCTUnwrap(wc.textStorageRef))
        doc.applySourceEdit(spans[0], with: "FIRST EDITED", actionName: "Edit")
        try assertMatchesFullRender(doc, wc, "first line")

        spans = BlockEdit.spans(in: try XCTUnwrap(wc.textStorageRef))
        doc.applySourceEdit(spans[spans.count - 1], with: "LAST EDITED", actionName: "Edit")
        try assertMatchesFullRender(doc, wc, "last line")
        XCTAssertEqual(doc.text, "FIRST EDITED\nmiddle\nLAST EDITED")
    }

    // MARK: Markdown

    func testMarkdownMoveAcrossBlockKinds() throws {
        let source = """
        # Title

        A paragraph here.

        - item one
        - item two

        ```swift
        let x = 1
        ```

        Final paragraph.
        """
        let (doc, wc) = try open(source, ext: "md")
        let storage = try XCTUnwrap(wc.textStorageRef)
        for i in 0..<3 {
            let spans = BlockEdit.spans(in: storage)
            guard let e = BlockEdit.swapWithNext(i, spans: spans, text: doc.text as NSString) else { continue }
            doc.applySourceEdit(e.0, with: e.1, actionName: "Move")
            try assertMatchesFullRender(doc, wc, "markdown move \(i)")
            try assertBlockIdsUnique(wc, "markdown move \(i)")
        }
    }

    func testMarkdownEditThatChangesBlockKind() throws {
        let (doc, wc) = try open("# Heading\n\nA paragraph.\n", ext: "md")
        let spans = BlockEdit.spans(in: try XCTUnwrap(wc.textStorageRef))
        // A heading becomes a table — the fragment renders to something structurally different.
        doc.applySourceEdit(spans[0], with: "| a | b |\n|---|---|\n| 1 | 2 |", actionName: "Edit")
        try assertMatchesFullRender(doc, wc, "heading → table")
    }

    /// Reference-style links resolve across blocks, so this document must take the FULL path — and
    /// the point of the fallback is that the result is still correct.
    func testReferenceStyleDocumentStillRendersCorrectly() throws {
        let source = "See [the docs][ref].\n\nAnother paragraph.\n\n[ref]: https://example.com\n"
        let (doc, wc) = try open(source, ext: "md")
        let spans = BlockEdit.spans(in: try XCTUnwrap(wc.textStorageRef))
        let e = try XCTUnwrap(BlockEdit.swapWithNext(0, spans: spans, text: doc.text as NSString))
        doc.applySourceEdit(e.0, with: e.1, actionName: "Move")
        try assertMatchesFullRender(doc, wc, "reference-style document")
    }

    // MARK: Showing the reader what changed

    /// Undo/redo must land the cursor on the block that actually changed — pressing ⌘Z and seeing
    /// nothing move gives no evidence it did anything.
    func testUndoAndRedoPutTheCursorOnTheChangedBlock() throws {
        let (doc, wc) = try open("one\ntwo\nthree\nfour\nfive\n", ext: "txt")
        let spans = BlockEdit.spans(in: try XCTUnwrap(wc.textStorageRef))
        doc.applySourceEdit(spans[3], with: "FOUR EDITED", actionName: "Edit")

        // Move the cursor far away, as a reader scrolling elsewhere would.
        wc.textView.setSelectedRange(NSRange(location: 0, length: 0))
        doc.undoManager?.undo()
        var selected = wc.textView.selectedRange()
        var storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertEqual(storage.attributedSubstring(from: selected).string, "four\n",
                       "undo should select the restored line")

        wc.textView.setSelectedRange(NSRange(location: 0, length: 0))
        doc.undoManager?.redo()
        selected = wc.textView.selectedRange()
        storage = try XCTUnwrap(wc.textStorageRef)
        XCTAssertEqual(storage.attributedSubstring(from: selected).string, "FOUR EDITED\n",
                       "redo should select the re-applied line")
    }

    /// After a delete there is no block to select, so the cursor goes to whatever took its place.
    func testUndoOfADeleteSelectsTheRestoredBlock() throws {
        let (doc, wc) = try open("one\ntwo\nthree\n", ext: "txt")
        let spans = BlockEdit.spans(in: try XCTUnwrap(wc.textStorageRef))
        doc.applySourceEdit(try XCTUnwrap(BlockEdit.deletion(of: 1, spans: spans)), with: "", actionName: "Delete")
        XCTAssertEqual(doc.text, "one\nthree\n")

        doc.undoManager?.undo()
        let storage = try XCTUnwrap(wc.textStorageRef)
        // A line's block covers its terminator, so the selection shows the whole restored line.
        XCTAssertEqual(storage.attributedSubstring(from: wc.textView.selectedRange()).string, "two\n",
                       "the restored line should be selected")
    }

    // MARK: The reason the splice exists

    /// A guard against silently falling back to re-rendering everything. On this 1.2MB document a
    /// full re-render measured well over a second, while a splice is a few milliseconds — so the
    /// bound below is loose enough never to fail on a busy machine, yet a regression to the old
    /// path can't sneak past it.
    func testLongDocumentEditStaysFast() throws {
        let line = "widget,3,a fairly typical row of text from a log or a spreadsheet export\n"
        let (doc, wc) = try open(String(repeating: line, count: 16_000), ext: "csv")
        let spans = BlockEdit.spans(in: try XCTUnwrap(wc.textStorageRef))
        XCTAssertGreaterThan(spans.count, 15_000)
        let edit = try XCTUnwrap(BlockEdit.swapWithNext(200, spans: spans, text: doc.text as NSString))

        let start = Date()
        doc.applySourceEdit(edit.0, with: edit.1, actionName: "Move")
        let ms = Date().timeIntervalSince(start) * 1000
        print(String(format: "  one edit on a 1.2MB document: %.0f ms", ms))
        XCTAssertLessThan(ms, 250, "an edit re-rendered the whole document again")
    }

    // MARK: Saving

    /// An undo group closes on the next run-loop turn, and NSDocument's dirty flag follows THAT —
    /// so a test that asks immediately after an edit is asking too early. Measured, not assumed:
    /// groupingLevel goes 1 → 0 across one turn.
    private func settle() {
        RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.1))
    }

    func testEditsAreNotWrittenUntilSave() throws {
        let source = "one\ntwo\n"
        let (doc, wc) = try open(source, ext: "txt")
        let spans = BlockEdit.spans(in: try XCTUnwrap(wc.textStorageRef))
        doc.applySourceEdit(spans[0], with: "EDITED", actionName: "Edit")
        settle()

        let onDisk = try String(contentsOf: doc.fileURL!, encoding: .utf8)
        XCTAssertEqual(onDisk, source, "the file must be untouched before ⌘S")
        XCTAssertTrue(doc.isDocumentEdited, "the document must report itself dirty")

        let saved = try doc.data(ofType: "public.plain-text")
        XCTAssertEqual(String(decoding: saved, as: UTF8.self), "EDITED\ntwo\n")
    }

    /// Undo back to the original must leave the document CLEAN — otherwise closing it asks to save
    /// changes that no longer exist.
    func testUndoingEverythingLeavesTheDocumentClean() throws {
        let (doc, wc) = try open("one\ntwo\n", ext: "txt")
        let spans = BlockEdit.spans(in: try XCTUnwrap(wc.textStorageRef))
        doc.applySourceEdit(spans[0], with: "EDITED", actionName: "Edit")
        settle()
        XCTAssertTrue(doc.isDocumentEdited)
        doc.undoManager?.undo()
        settle()
        XCTAssertEqual(doc.text, "one\ntwo\n")
        XCTAssertFalse(doc.isDocumentEdited, "undone back to the original — nothing to save")
    }

    /// A file that arrived as UTF-16 must be SAVED as UTF-16, not converted because it was edited.
    func testSavePreservesTheOriginalEncoding() throws {
        let url = temp.appendingPathComponent("korean.txt")
        let original = "한글 첫 줄\n둘째 줄\n"
        let bytes = Data([0xFF, 0xFE]) + original.data(using: .utf16LittleEndian)!
        try bytes.write(to: url)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: bytes, ofType: "public.plain-text")
        XCTAssertEqual(doc.text, original, "decoded correctly")

        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        let spans = BlockEdit.spans(in: try XCTUnwrap(wc.textStorageRef))
        doc.applySourceEdit(spans[0], with: "바뀐 첫 줄", actionName: "Edit")

        let saved = try doc.data(ofType: "public.plain-text")
        XCTAssertEqual(Array(saved.prefix(2)), [0xFF, 0xFE], "BOM kept")
        XCTAssertEqual(String(data: saved.dropFirst(2), encoding: .utf16LittleEndian), "바뀐 첫 줄\n둘째 줄\n")
    }
}

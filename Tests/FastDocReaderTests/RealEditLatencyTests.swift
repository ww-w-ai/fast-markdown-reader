import XCTest
import AppKit
@testable import FastDocReader

/// End-to-end latency of ONE block edit, driven through the real document + window controller
/// rather than the pure-Swift pieces — the earlier breakdown measured render and layout in
/// isolation and came out far too fast to explain what the app actually feels like, which means
/// the cost is somewhere in between them.
///
/// Reads a file only if FMD_LATENCY_FILE points at one; nothing is printed from its contents.
final class RealEditLatencyTests: XCTestCase {
    private func stamp(_ label: String, _ start: Date) {
        print(String(format: "  %-34@ %6.0f ms", label as NSString, Date().timeIntervalSince(start) * 1000))
    }

    func testOneEditEndToEnd() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_LATENCY_FILE"] else {
            throw XCTSkip("set FMD_LATENCY_FILE to measure a real document")
        }
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)

        let doc = MarkdownDocument()
        doc.fileURL = url
        var t = Date()
        try doc.read(from: data, ofType: "public.plain-text")
        stamp("read + decode", t)
        print("  characters: \((doc.text as NSString).length), plain text: \(doc.isPlainText)")

        t = Date()
        doc.makeWindowControllers()
        stamp("first render (makeWindowControllers)", t)
        guard let wc = doc.windowControllers.first as? DocumentWindowController else {
            return XCTFail("no window controller")
        }
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        spinRunLoop(seconds: 2)

        // The measured operation: swap two blocks, exactly what pressing ▲ does.
        let storage = try XCTUnwrap(wc.textView.textStorage)
        t = Date()
        let spans = BlockEdit.spans(in: storage)
        stamp("BlockEdit.spans", t)
        print("  blocks: \(spans.count)")
        let target = min(40, max(0, spans.count - 2))
        let edit = try XCTUnwrap(BlockEdit.swapWithNext(target, spans: spans, text: doc.text as NSString))

        t = Date()
        doc.applySourceEdit(edit.0, with: edit.1, actionName: "Move")
        stamp("applySourceEdit (SYNCHRONOUS)", t)
        t = Date()
        spinRunLoop(seconds: 3)          // the async tail: precomputeLayout, media passes, overlays
        stamp("async tail settles within", t)

        // A second edit, now that everything is warm — this is what repeated ▲ presses cost.
        let spans2 = BlockEdit.spans(in: storage)
        if let e2 = BlockEdit.swapWithNext(target, spans: spans2, text: doc.text as NSString) {
            t = Date()
            doc.applySourceEdit(e2.0, with: e2.1, actionName: "Move")
            stamp("second edit (SYNCHRONOUS)", t)
        }
    }

    /// Which STAGE of a re-render costs the 130ms — the parts of `render(into:)`, timed separately.
    func testRenderStageBreakdown() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_LATENCY_FILE"] else {
            throw XCTSkip("set FMD_LATENCY_FILE to measure a real document")
        }
        let url = URL(fileURLWithPath: path)
        let doc = MarkdownDocument()
        doc.fileURL = url
        try doc.read(from: try Data(contentsOf: url), ofType: "public.plain-text")
        doc.makeWindowControllers()
        let wc = try XCTUnwrap(doc.windowControllers.first as? DocumentWindowController)
        wc.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        spinRunLoop(seconds: 2)

        var t = Date()
        let attr = PlainTextRenderer.render(doc.text, theme: .current(size: FontSizeStore.size))
        stamp("PlainTextRenderer.render", t)

        t = Date(); let anchor = wc.topVisibleCharIndex(); stamp("topVisibleCharIndex", t)
        t = Date(); wc.display(attr); stamp("display(attr)", t)
        t = Date(); wc.textView.recomputeHeadingOffsets(); stamp("recomputeHeadingOffsets", t)
        t = Date(); wc.scrollCharToTop(anchor); stamp("scrollCharToTop", t)
        t = Date(); wc.placeCopyButtons(); stamp("placeCopyButtons", t)
        t = Date()
        try? Data(doc.text.utf8).write(to: URL(fileURLWithPath: NSTemporaryDirectory() + "/fmd-write-test"))
        stamp("file write", t)
    }

    private func spinRunLoop(seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
    }
}

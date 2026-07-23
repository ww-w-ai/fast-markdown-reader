import XCTest
import AppKit
@testable import FastDocReader

/// TEMPORARY perf probe — set FMD_PERF_DOCX=<path to a slow .docx> to time each stage of the office
/// render pipeline and localize where a big-table document spends its open time. Not a shipped test.
///
/// This is the probe that found table-cell measurement was accidentally O(n²): `NSAttributedString`
/// `.boundingRect`/`.draw` re-lay-out per call and blow up on rich CJK cells (a 1000-char legal cell
/// measured 53ms, vs 0.8ms for its first 100 chars). The fix routes measure+draw through the reused
/// `CellText` TextKit stack (O(n)); `relayout ALL` should now read tens of ms, not hundreds. Keep the
/// probe so that finding can be re-derived on any document rather than re-discovered from scratch.
final class TablePerfProbeTests: XCTestCase {
    func testTimeStagesOnRealDocx() throws {
        guard let path = ProcessInfo.processInfo.environment["FMD_PERF_DOCX"] else {
            throw XCTSkip("set FMD_PERF_DOCX=<path>")
        }
        _ = NSApplication.shared   // graphics context for AppKit text measurement in a headless test
        func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }
        func ms(_ label: String, _ body: () -> Void) {
            let t = Date()
            body()
            log(String(format: "PERF %-40@ %7.1f ms", label as NSString, Date().timeIntervalSince(t) * 1000))
        }

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var blocks: [OfficeBlock] = []
        var archive: ZipArchive!
        ms("ZipArchive") { archive = try? ZipArchive(data: data) }
        ms("DocxReader.read") { blocks = (try? DocxReader.read(archive))?.blocks ?? [] }
        print("PERF blocks=\(blocks.count)  tables=\(blocks.filter { if case .table = $0 { return true } else { return false } }.count)")

        let theme = RenderTheme.current(size: 16)
        var attr = NSAttributedString()
        ms("OfficeTextBuilder.build") {
            attr = OfficeTextBuilder.build(blocks, theme: theme, columnWidth: 660, documentDefaultFontSize: 11)
        }

        // collect the table attachment cells
        var tables: [TableAttachmentCell] = []
        attr.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attr.length)) { v, _, _ in
            if let att = v as? NSTextAttachment, let t = att.attachmentCell as? TableAttachmentCell { tables.append(t) }
        }
        print("PERF tableAttachmentCells=\(tables.count)")

        // The real cost: solving every table's geometry (measures each cell) at the reading width. The
        // O(n²)→O(n) fix lives here — x1 is the first solve, x2/x3 are the width-cache no-ops.
        ms("relayout ALL @660 (x1)") { for t in tables { t.relayout(width: 660) } }
        ms("relayout ALL @660 (x2 same width)") { for t in tables { t.relayout(width: 660) } }

        var totalLen = 0
        for t in tables { for i in 0..<t.cellCount { totalLen += t.cellContent(i).length } }
        print("PERF total cell content length=\(totalLen)")

        // Contrast the two measurement APIs on the real cells: the reused CellText stack (what the app
        // now uses) vs the old per-call boundingRect that measured O(n²) on big CJK cells.
        ms("CellText.height ALL cells (O(n))") {
            for t in tables { for i in 0..<t.cellCount { _ = CellText.height(t.cellContent(i), width: 620) } }
        }
        ms("boundingRect ALL cells (old O(n²))") {
            for t in tables {
                for i in 0..<t.cellCount {
                    _ = t.cellContent(i).boundingRect(
                        with: NSSize(width: 620, height: CGFloat.greatestFiniteMagnitude),
                        options: [.usesLineFragmentOrigin, .usesFontLeading])
                }
            }
        }
    }
}

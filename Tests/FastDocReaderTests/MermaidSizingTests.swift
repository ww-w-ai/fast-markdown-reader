import XCTest
@testable import FastDocReader

/// Covers the fix in `docs/06-research/mermaid-sizing.md`: mermaid's `useMaxWidth:true` only ever
/// shrinks a diagram, never grows one, so `fittedSize`'s mermaid branch is the only place a diagram
/// grows toward the column at all.
final class MermaidSizingTests: XCTestCase {

    private let colW: CGFloat = 600

    // MARK: - Pure grow function

    func testTinyDiagramGrowsButStaysUnderFactorCap() {
        let natural: CGFloat = 0.3 * colW // 180
        let target = MarkdownDocument.mermaidTargetWidth(naturalWidth: natural, colW: colW)
        XCTAssertGreaterThan(target, natural, "must grow")
        XCTAssertLessThanOrEqual(target, natural * MarkdownDocument.mermaidEnlargeFactorCap)
        XCTAssertEqual(target, natural * MarkdownDocument.mermaidEnlargeFactorCap, accuracy: 0.001)
    }

    func testMidBandDiagramReachesColumnWidth() {
        // This is the case the old "floor at 50%" rule left completely untouched.
        let natural: CGFloat = 0.7 * colW // 420
        let target = MarkdownDocument.mermaidTargetWidth(naturalWidth: natural, colW: colW)
        XCTAssertEqual(target, colW, "70% of column should now reach full column width")
    }

    func testGrowNeverExceedsColumnWidth() {
        let natural: CGFloat = 0.05 * colW
        let target = MarkdownDocument.mermaidTargetWidth(naturalWidth: natural, colW: colW)
        XCTAssertLessThanOrEqual(target, colW)
    }

    // MARK: - fittedSize integration (through the real mermaid attribute + column-fit pipeline)

    private func mermaidStorage(diagramWidth: CGFloat, diagramHeight: CGFloat) -> (NSTextStorage, NSRange) {
        let storage = NSTextStorage(string: "x")
        let range = NSRange(location: 0, length: 1)
        storage.addAttribute(MDAttr.mermaid, value: "graph TD; A-->B", range: range)
        return (storage, range)
    }

    func testFittedSizeGrowsMidBandMermaidDiagram() {
        let doc = MarkdownDocument()
        let (storage, range) = mermaidStorage(diagramWidth: 0.7 * colW, diagramHeight: 0.7 * 200)
        let natural = NSSize(width: 0.7 * colW, height: 0.7 * 200)
        let fitted = doc.fittedSize(natural, storage, range, maxWidth: colW + 8) // fittedSize subtracts 8
        XCTAssertEqual(fitted.width, colW, accuracy: 1)
    }

    func testFittedSizePreservesAspectRatioWhenGrowing() {
        let doc = MarkdownDocument()
        let natural = NSSize(width: 0.3 * colW, height: 100)
        let (storage, range) = mermaidStorage(diagramWidth: natural.width, diagramHeight: natural.height)
        let fitted = doc.fittedSize(natural, storage, range, maxWidth: colW + 8)
        let naturalRatio = natural.height / natural.width
        let fittedRatio = fitted.height / fitted.width
        XCTAssertEqual(naturalRatio, fittedRatio, accuracy: 0.01)
    }

    func testFittedSizeStillShrinksOversizedMermaidDiagram() {
        // Unchanged path: a diagram wider than the column keeps shrinking to fit, same as before.
        let doc = MarkdownDocument()
        let natural = NSSize(width: 1.5 * colW, height: 300)
        let (storage, range) = mermaidStorage(diagramWidth: natural.width, diagramHeight: natural.height)
        let fitted = doc.fittedSize(natural, storage, range, maxWidth: colW + 8)
        XCTAssertEqual(fitted.width, colW, accuracy: 1)
        let naturalRatio = natural.height / natural.width
        let fittedRatio = fitted.height / fitted.width
        XCTAssertEqual(naturalRatio, fittedRatio, accuracy: 0.01)
    }

    /// Invariant 1: the reserved size must be knowable BEFORE layout and must not depend on whether
    /// the attachment's pixels are currently loaded — `fittedSize` takes only the natural size (read
    /// from the cached PDF, loaded or not) plus column width, never the attachment's image itself, so
    /// calling it twice with the same inputs (as would happen for a loaded vs. a purged attachment)
    /// must produce byte-identical results.
    func testFittedSizeIdenticalRegardlessOfAttachmentLoadState() {
        let doc = MarkdownDocument()
        let natural = NSSize(width: 0.65 * colW, height: 150)
        let (storageA, rangeA) = mermaidStorage(diagramWidth: natural.width, diagramHeight: natural.height)
        let (storageB, rangeB) = mermaidStorage(diagramWidth: natural.width, diagramHeight: natural.height)
        // storageA/storageB stand in for "pixels loaded" vs "purged" — fittedSize never reads the
        // attachment's image, only the natural size and the mermaid attribute, so both must match.
        let fittedLoaded = doc.fittedSize(natural, storageA, rangeA, maxWidth: colW + 8)
        let fittedPurged = doc.fittedSize(natural, storageB, rangeB, maxWidth: colW + 8)
        XCTAssertEqual(fittedLoaded, fittedPurged)
    }

    /// Resize/reflow (invariant 24): recomputing at a different live column width must stay internally
    /// consistent with the new rule — never past the column, never past the factor cap.
    func testFittedSizeRecomputesConsistentlyAcrossColumnWidths() {
        let doc = MarkdownDocument()
        let natural = NSSize(width: 300, height: 150)
        for testColW: CGFloat in [320, 600, 900, 1400] {
            let (storage, range) = mermaidStorage(diagramWidth: natural.width, diagramHeight: natural.height)
            let fitted = doc.fittedSize(natural, storage, range, maxWidth: testColW + 8)
            XCTAssertLessThanOrEqual(fitted.width, testColW, "never exceeds the live column")
            XCTAssertLessThanOrEqual(
                fitted.width, natural.width * MarkdownDocument.mermaidEnlargeFactorCap + 1,
                "never exceeds the factor cap"
            )
        }
    }
}

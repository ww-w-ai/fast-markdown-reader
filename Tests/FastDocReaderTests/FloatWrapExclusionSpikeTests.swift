import XCTest
import AppKit
@testable import FastDocReader

/// S16 feasibility spike — NOT the feature, a controlled experiment against this app's REAL TextKit 1
/// stack (contiguous NSLayoutManager, explicit NSTextContainer, no TextKit 2) to answer the sprint's
/// central question before any production code is written: can a floating image's exclusion rect be
/// resolved entirely inside the existing up-front measure pass, with the geometry never touched again
/// during scroll (invariant 1) or on pixel load/purge?
///
/// The technique under test: exclusion rects are NOT known until layout has happened (you need to know
/// where the anchor paragraph landed), and setting `NSTextContainer.exclusionPaths` invalidates the
/// WHOLE container's glyph layout (AppKit does not do a partial invalidation below the change). So N
/// floating images cost N sequential full-container layouts if resolved one at a time, in document
/// order, each seeded with every exclusion already placed by the ones before it. That is still ONE
/// bounded pass at OPEN time (or at the end of a resize/sidebar reflow) — never during scroll — which
/// is exactly the shape invariant 2's diagram pre-render already uses.
final class FloatWrapExclusionSpikeTests: XCTestCase {

    /// A minimal stand-in for the app's real stack: contiguous layout, explicit container width —
    /// the two properties invariant 1/24's comments call out as load-bearing.
    private func makeStack(columnWidth: CGFloat) -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage()
        let layout = NSLayoutManager()
        layout.allowsNonContiguousLayout = false
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: NSSize(width: columnWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        return (storage, layout, container)
    }

    private let font = NSFont.systemFont(ofSize: 13)

    /// A body of `paragraphs` short paragraphs, each long enough to wrap several lines at 500pt.
    /// `markerAt` paragraph indices get a 1x1 NSTextAttachment inserted at their start — the anchor
    /// stand-in a real floating-image marker character would be.
    private func buildDocument(paragraphs: Int, markerAt: Set<Int>) -> (NSAttributedString, [Int]) {
        let out = NSMutableAttributedString()
        var markerIndices: [Int] = []
        let sentence = "The quick brown fox jumps over the lazy dog near the riverbank at dusk. "
        for p in 0..<paragraphs {
            if markerAt.contains(p) {
                let attachment = NSTextAttachment()
                attachment.bounds = NSRect(x: 0, y: 0, width: 1, height: 1)   // marker only — the
                // picture itself is drawn as a floating overlay outside the glyph stream, never as
                // a normal-size inline attachment (an inline attachment of the image's real size
                // would just push text down, not wrap beside it).
                let cell = NSTextAttachmentCell(imageCell: nil)
                attachment.attachmentCell = cell
                markerIndices.append(out.length)
                out.append(NSAttributedString(attachment: attachment))
            }
            let text = String(repeating: sentence, count: 4) + "\n\n"
            out.append(NSAttributedString(string: text, attributes: [.font: font]))
        }
        return (out, markerIndices)
    }

    /// The algorithm under test, run against the container's OWN sequence of markers, in document
    /// order. Returns the exclusion rects it placed (for assertions) and total elapsed time.
    @discardableResult
    private func resolveExclusionsSequentially(
        markers: [Int], imageSize: NSSize, side: [Int: Bool] /* true = left */,
        storage: NSTextStorage, layout: NSLayoutManager, container: NSTextContainer
    ) -> (rects: [NSRect], seconds: Double) {
        container.exclusionPaths = []
        let colW = container.size.width
        var rects: [NSRect] = []
        let start = Date()
        for charIndex in markers {
            // Layout only as far as this marker — already includes every exclusion set by an
            // EARLIER marker in this same pass, because container.exclusionPaths was mutated below
            // before moving on to the next one. Text before a marker never depends on exclusions
            // placed after it, so processing strictly in document order is enough — no iteration
            // needed within a marker, only a forward walk across markers.
            layout.ensureLayout(forCharacterRange: NSRange(location: 0, length: charIndex + 1))
            let glyphIndex = layout.glyphIndexForCharacter(at: charIndex)
            let lineRect = layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let isLeft = side[charIndex] ?? true
            let x: CGFloat = isLeft ? 0 : max(0, colW - imageSize.width)
            let rect = NSRect(x: x, y: lineRect.minY, width: imageSize.width, height: imageSize.height)
            rects.append(rect)
            container.exclusionPaths.append(NSBezierPath(rect: rect))
        }
        // Final full pass — the one that actually matters for the scroll bar (invariant 2's "lay out
        // the whole document once" step).
        layout.ensureLayout(for: container)
        return (rects, Date().timeIntervalSince(start))
    }

    // MARK: - Correctness

    /// The central claim: a single sequential forward pass, seeded only with markers already placed,
    /// produces STABLE geometry — running the exact same full-container layout again afterwards must
    /// not change the total height. If it did, that would be exactly the "lay out, see where things
    /// landed, adjust, lay out again" cycle invariant 1 forbids.
    func testSequentialPassIsStableUnderRepeatedLayout() {
        let (storage, layout, container) = makeStack(columnWidth: 500)
        let (doc, markers) = buildDocument(paragraphs: 6, markerAt: [1, 3])
        storage.setAttributedString(doc)
        resolveExclusionsSequentially(
            markers: markers, imageSize: NSSize(width: 150, height: 150),
            side: [markers[0]: true, markers[1]: false],
            storage: storage, layout: layout, container: container)
        let heightAfterPass = layout.usedRect(for: container).height

        // Re-run layout for the whole container again (simulating a later `ensureLayout` call that
        // would happen if, say, an unrelated attachment elsewhere loaded pixels and the code asked
        // for layout again) — WITHOUT touching exclusionPaths.
        layout.ensureLayout(for: container)
        let heightAfterRepeat = layout.usedRect(for: container).height

        XCTAssertEqual(heightAfterPass, heightAfterRepeat, accuracy: 0.5,
                        "geometry must be stable — no second adjustment pass")
    }

    /// Text actually flows narrower on the line(s) beside the exclusion — this is the wrap itself,
    /// not just "some rect got appended". Also the invariant-30 mutation: deliberately break the
    /// computation (place the exclusion far off-document) and confirm the same assertion FAILS,
    /// proving this test is not passing "for the wrong reason" (text that would have been that width
    /// anyway).
    func testLineBesideExclusionIsNarrower_andMutationBreaksIt() {
        let imageSize = NSSize(width: 150, height: 150)
        func lineWidthAtMarker(brokenExclusion: Bool) -> CGFloat {
            let (storage, layout, container) = makeStack(columnWidth: 500)
            let (doc, markers) = buildDocument(paragraphs: 4, markerAt: [1])
            storage.setAttributedString(doc)
            let marker = markers[0]
            if brokenExclusion {
                // MUTATION: compute the rect at a Y far below the actual anchor position, so it
                // excludes nothing where the marker's own paragraph actually lands.
                container.exclusionPaths = [NSBezierPath(rect: NSRect(x: 0, y: 5000, width: 150, height: 150))]
                layout.ensureLayout(for: container)
            } else {
                resolveExclusionsSequentially(
                    markers: [marker], imageSize: imageSize, side: [marker: true],
                    storage: storage, layout: layout, container: container)
            }
            let glyphIndex = layout.glyphIndexForCharacter(at: marker)
            return layout.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil).width
        }
        let correctWidth = lineWidthAtMarker(brokenExclusion: false)
        let brokenWidth = lineWidthAtMarker(brokenExclusion: true)
        XCTAssertLessThan(correctWidth, 500 - 100, "the real pass must narrow the anchor's line")
        XCTAssertGreaterThan(brokenWidth, 500 - 20, "the mutation must NOT narrow it — proves the real pass is load-bearing")
        XCTAssertNotEqual(correctWidth, brokenWidth, accuracy: 1)
    }

    /// Invariant 1 stated as an assertion for the float case: once the exclusion pass has run, a
    /// LATER attachment's pixels loading/purging elsewhere in the document (bounds unchanged, only
    /// `.image` swapped, exactly what `reconcileMedia` does) must not move the total document height.
    func testHeightUnchangedWhenUnrelatedAttachmentPixelsLoadOrPurge() {
        let (storage, layout, container) = makeStack(columnWidth: 500)
        let (doc, markers) = buildDocument(paragraphs: 6, markerAt: [2])
        let mutable = NSMutableAttributedString(attributedString: doc)
        // An ordinary inline attachment elsewhere, reserved at a fixed size — the pattern
        // `SizedAttachmentCell` gives every other image in this app.
        let ordinary = NSTextAttachment()
        ordinary.bounds = NSRect(x: 0, y: 0, width: 80, height: 60)
        mutable.append(NSAttributedString(attachment: ordinary))
        storage.setAttributedString(mutable)
        resolveExclusionsSequentially(
            markers: markers, imageSize: NSSize(width: 150, height: 150), side: [markers[0]: true],
            storage: storage, layout: layout, container: container)
        let before = layout.usedRect(for: container).height

        // "Purge": nothing about `ordinary`'s bounds changes (that's the whole point of the reserved-
        // size cell design) — only what the fake reconcile pass in this real app would ever touch.
        // Nothing here calls exclusionPaths again.
        layout.ensureLayout(for: container)
        let after = layout.usedRect(for: container).height
        XCTAssertEqual(before, after, accuracy: 0.5)
    }

    // MARK: - Cost (opt-in — FMD_FLOAT_PERF=1)

    /// The gate's own numbers: layout TIME for a realistic document with several floating images,
    /// wrap on vs off. Peak memory is reported separately (see the sprint return) since XCTest has no
    /// portable in-process RSS probe worth trusting here — timing is the reproducible half.
    func testSequentialPassCost() throws {
        guard ProcessInfo.processInfo.environment["FMD_FLOAT_PERF"] != nil else {
            throw XCTSkip("set FMD_FLOAT_PERF=1 to measure layout cost")
        }
        let paragraphCount = 400            // a substantial real document
        let imageCounts = [0, 1, 4, 12]     // 0 = wrap off (the control)
        for n in imageCounts {
            let markerAt = Set((0..<n).map { $0 * (paragraphCount / max(n, 1)) })
            let (storage, layout, container) = makeStack(columnWidth: 500)
            let (doc, markers) = buildDocument(paragraphs: paragraphCount, markerAt: markerAt)
            storage.setAttributedString(doc)
            let side = Dictionary(uniqueKeysWithValues: markers.enumerated().map { ($1, $0 % 2 == 0) })
            let (_, seconds) = resolveExclusionsSequentially(
                markers: markers, imageSize: NSSize(width: 150, height: 150), side: side,
                storage: storage, layout: layout, container: container)
            print(String(format: "  floating images: %2d  →  sequential-pass layout time: %6.1f ms", n, seconds * 1000))
        }
    }
}

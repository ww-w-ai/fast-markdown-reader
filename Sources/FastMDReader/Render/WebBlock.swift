import AppKit

/// A block only WebKit can draw, cached on disk as a vector PDF: a mermaid diagram or a TeX formula.
///
/// Both ride ONE pipeline — measure every uncached block up front, lay the document out once, then
/// fill pixels lazily — which is what keeps the scroll bar stable (see the invariants in CLAUDE.md).
/// Giving maths its own parallel pipeline would mean re-earning that property, and getting it wrong
/// once means formulas resize under the reader mid-scroll.
struct WebBlock: Hashable {
    enum Engine: String, CaseIterable {
        case mermaid, math

        /// The attribute the renderer leaves on the placeholder for this engine.
        var attribute: NSAttributedString.Key { self == .mermaid ? MDAttr.mermaid : MDAttr.math }

        /// Part of the cache key, so the two engines can never collide and a bump invalidates only
        /// its own PDFs. Bump when the engine version OR the way we capture it changes — a cached
        /// PDF outlives the bug that produced it. Mermaid's stays "10": nothing about its capture has
        /// changed, and bumping would throw away every cached diagram for no reason.
        var cacheVersion: String { self == .mermaid ? "10" : "katex-0.17.0-2" }
    }

    let engine: Engine
    let code: String
}

extension NSAttributedString {
    /// Every WebKit-drawn block in the document, whichever engine draws it. The ONE place that knows
    /// there is more than one engine — every pass (measure, presize, reconcile) goes through here, so
    /// adding an engine can't silently skip a pass.
    func enumerateWebBlocks(in range: NSRange? = nil, _ body: (WebBlock, NSRange) -> Void) {
        let whole = range ?? NSRange(location: 0, length: length)
        for engine in WebBlock.Engine.allCases {
            enumerateAttribute(engine.attribute, in: whole) { value, r, _ in
                guard let code = value as? String else { return }
                body(WebBlock(engine: engine, code: code), r)
            }
        }
    }
}

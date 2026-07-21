import AppKit

/// A text-attachment cell that OWNS its layout size (`reservedSize`) independently of whether an
/// image is currently loaded. The default NSTextAttachmentCell derives its size from the image, so
/// an image==nil attachment collapses to ~zero height — which made the reserved placeholder space
/// vanish and the document's total height (and scroll bar) swing as diagrams lazily loaded/unloaded.
///
/// Here the size is fixed at pre-measure time and never changes when the image toggles, so lazy
/// loading/purging pixels does NOT touch layout: the frame height (and scroll bar) stay rock stable.
/// The cell just draws the attachment's image when one is present, nothing when it isn't.
final class SizedAttachmentCell: NSTextAttachmentCell {
    var reservedSize: NSSize

    init(reservedSize: NSSize) {
        self.reservedSize = reservedSize
        super.init()
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func cellSize() -> NSSize { reservedSize }
    override func cellBaselineOffset() -> NSPoint { .zero }

    override func cellFrame(for textContainer: NSTextContainer, proposedLineFragment lineFrag: NSRect,
                            glyphPosition position: NSPoint, characterIndex charIndex: Int) -> NSRect {
        NSRect(origin: .zero, size: reservedSize)
    }

    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?) {
        attachment?.image?.draw(in: cellFrame, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
    override func draw(withFrame cellFrame: NSRect, in controlView: NSView?,
                       characterIndex charIndex: Int, layoutManager: NSLayoutManager) {
        draw(withFrame: cellFrame, in: controlView)
    }
}

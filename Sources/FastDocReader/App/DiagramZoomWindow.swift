import AppKit

/// A scroll view that zooms with ⌘+ / ⌘− / ⌘0 (0 = fit) — and the same keys bare — on top of the
/// native trackpad pinch, and pans by click-drag (grab-hand) so you can move around a zoomed-in
/// diagram.
final class ZoomScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }

    /// `keyDown` only runs when this view is the first responder, which it is not reliably: the
    /// image view or the window can hold it, and then the bare keys silently do nothing (they did).
    /// A key equivalent is offered to the whole view tree regardless of who is first responder, so
    /// the ⌘ forms always land — and they take precedence over the menu bar's ⌘+/⌘−/⌘0, which
    /// resize the READER's text and mean nothing in front of a diagram.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .option, .control]) == [.command],
              let key = event.charactersIgnoringModifiers else {
            return super.performKeyEquivalent(with: event)
        }
        switch key {
        case "+", "=": zoom(by: 1.25); return true
        case "-", "_": zoom(by: 1 / 1.25); return true
        case "0":      fit(); return true
        default:       return super.performKeyEquivalent(with: event)
        }
    }

    override func keyDown(with event: NSEvent) {
        // Esc by KEY CODE, closed here rather than left to `cancelOperation`. That callback only
        // arrives via `interpretKeyEvents`, which a plain NSView never calls (it is NSTextView and
        // NSControl behaviour) — so the tidy-looking route silently never fired.
        if event.keyCode == 53 { window?.performClose(nil); return }
        switch event.charactersIgnoringModifiers {
        case "+", "=": zoom(by: 1.25)
        case "-", "_": zoom(by: 1 / 1.25)
        case "0":      fit()
        default:       super.keyDown(with: event)
        }
    }

    func fit() { if let dv = documentView { magnify(toFit: dv.frame) } }

    private func zoom(by factor: CGFloat) {
        let r = contentView.documentVisibleRect
        let target = max(minMagnification, min(maxMagnification, magnification * factor))
        setMagnification(target, centeredAt: NSPoint(x: r.midX, y: r.midY))
    }

    // MARK: - Grab-hand panning
    private var panStart: NSPoint = .zero
    private var panOrigin: NSPoint = .zero

    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        panStart = event.locationInWindow
        panOrigin = contentView.bounds.origin
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        let now = event.locationInWindow
        let dx = now.x - panStart.x
        let dy = now.y - panStart.y
        // Content follows the cursor (hand grab). Sign of dy depends on the clip view's flippedness.
        let flip: CGFloat = contentView.isFlipped ? 1 : -1
        contentView.scroll(to: NSPoint(x: panOrigin.x - dx, y: panOrigin.y + flip * dy))
        reflectScrolledClipView(contentView)
    }

    override func mouseUp(with event: NSEvent) { NSCursor.openHand.set() }
}

/// The zoom window itself closes on Esc. A window receives `keyDown` only for keys nothing in its
/// responder chain took, which makes it the one place the key can't be missed — the scroll view's
/// own handler works only while it happens to be first responder, and that is not guaranteed (it is
/// why the zoom keys appeared dead before they were moved to a key equivalent).
final class ZoomWindow: NSWindow {
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { performClose(nil); return }   // esc
        super.keyDown(with: event)
    }
}

/// Centers the document view when it is smaller than the viewport (a wide/short diagram would
/// otherwise sit in the bottom-left corner instead of the middle).
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let doc = documentView else { return rect }
        if doc.frame.width < rect.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
        if doc.frame.height < rect.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        return rect
    }
}

/// A standalone, zoomable window for viewing a rendered diagram (mermaid) enlarged. The image is
/// PDF-backed (vector), so NSScrollView magnification stays crisp at any zoom level.
final class DiagramZoomWindowController: NSWindowController, NSWindowDelegate {
    // At most ONE zoom window: clicking a second diagram swaps this one's content instead of piling
    // up windows. Also retains the controller, which nothing else holds.
    private static var current: DiagramZoomWindowController?
    private let scroll = ZoomScrollView()

    static func show(_ image: NSImage) {
        if let c = current {
            c.replace(with: image)
            c.window?.makeKeyAndOrderFront(nil)
            return
        }
        let c = DiagramZoomWindowController(image: image)
        current = c
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    /// Swap the displayed image, resetting zoom to fit — the previous diagram's magnification and
    /// scroll offset mean nothing for a different image.
    private func replace(with image: NSImage) {
        let iv = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown
        scroll.documentView = iv
        DispatchQueue.main.async { [weak self] in
            self?.scroll.fit()
            self?.window?.makeFirstResponder(self?.scroll)
        }
    }

    private convenience init(image: NSImage) {
        let win = ZoomWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                             styleMask: [.titled, .closable, .resizable, .miniaturizable],
                             backing: .buffered, defer: false)
        win.title = "Zoom — ⌘+ / ⌘− or pinch · ⌘0 to fit · drag to move · esc to close"
        win.isReleasedWhenClosed = false
        self.init(window: win)
        win.delegate = self
        win.center()

        scroll.frame = win.contentLayoutRect
        scroll.autoresizingMask = [.width, .height]
        scroll.contentView = CenteringClipView()    // center small diagrams instead of bottom-left
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.2
        scroll.maxMagnification = 12
        scroll.backgroundColor = .white

        let iv = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        iv.image = image
        iv.imageScaling = .scaleProportionallyUpOrDown   // preserve aspect; magnification does the zoom
        scroll.documentView = iv
        win.contentView = scroll

        // Fit the whole diagram on open; the user zooms in from there.
        DispatchQueue.main.async { [weak self] in
            self?.scroll.fit()
            self?.window?.makeFirstResponder(self?.scroll)
        }
    }

    func windowWillClose(_ notification: Notification) {
        if Self.current === self { Self.current = nil }
    }
}

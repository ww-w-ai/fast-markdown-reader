import AppKit

/// A scroll view that zooms with + / − / 0 (0 = fit) on top of the native trackpad pinch, and
/// pans by click-drag (grab-hand) so you can move around a zoomed-in diagram.
final class ZoomScrollView: NSScrollView {
    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
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

/// A standalone, zoomable window for viewing a rendered diagram (mermaid) enlarged. The image is
/// PDF-backed (vector), so NSScrollView magnification stays crisp at any zoom level.
final class DiagramZoomWindowController: NSWindowController, NSWindowDelegate {
    // Retain open zoom windows until they close (a window controller isn't held by anything else).
    private static var open: [DiagramZoomWindowController] = []
    private let scroll = ZoomScrollView()

    static func show(_ image: NSImage) {
        let c = DiagramZoomWindowController(image: image)
        open.append(c)
        c.showWindow(nil)
        c.window?.makeKeyAndOrderFront(nil)
    }

    private convenience init(image: NSImage) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 760),
                           styleMask: [.titled, .closable, .resizable, .miniaturizable],
                           backing: .buffered, defer: false)
        win.title = "Zoom — pinch/+/− · drag to move · 0 to fit"
        win.isReleasedWhenClosed = false
        self.init(window: win)
        win.delegate = self
        win.center()

        scroll.frame = win.contentLayoutRect
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.allowsMagnification = true
        scroll.minMagnification = 0.2
        scroll.maxMagnification = 12
        scroll.backgroundColor = .white

        let iv = NSImageView(frame: NSRect(origin: .zero, size: image.size))
        iv.image = image
        iv.imageScaling = .scaleAxesIndependently   // fills its frame; magnification does the zoom
        scroll.documentView = iv
        win.contentView = scroll

        // Fit the whole diagram on open; the user zooms in from there.
        DispatchQueue.main.async { [weak self] in
            self?.scroll.fit()
            self?.window?.makeFirstResponder(self?.scroll)
        }
    }

    func windowWillClose(_ notification: Notification) {
        Self.open.removeAll { $0 === self }
    }
}

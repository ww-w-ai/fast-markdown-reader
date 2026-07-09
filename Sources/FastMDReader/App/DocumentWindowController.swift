import AppKit

final class DocumentWindowController: NSWindowController {
    // Explicit TextKit 1 stack (C2): building the view with init(frame:textContainer:)
    // guarantees the classic NSLayoutManager path instead of silently falling back
    // to TextKit 2 compatibility mode when layoutManager is later accessed.
    let textView: ReaderTextView
    private let scrollView = NSScrollView()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.tabbingMode = .preferred   // native tabs
        self.init(window: window)
        window.center()

        textView.isEditable = false
        textView.isSelectable = true          // mouse selection allowed
        textView.isRichText = true
        textView.textContainerInset = NSSize(width: 24, height: 20)
        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = true
        window.contentView = scrollView

        // C6: text reflow on window resize restrands copy buttons at stale positions.
        // Observe frame changes and re-place them (debounced).
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged),
            name: NSView.frameDidChangeNotification, object: textView)
        // Re-place buttons on scroll so only visible code blocks carry one (perf: we never
        // force layout of off-screen blocks just to position an overlay).
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(viewportChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override init(window: NSWindow?) {
        let storage = NSTextStorage()
        let layout = CodeCardLayoutManager()   // draws code blocks as rounded cards
        storage.addLayoutManager(layout)
        // Non-contiguous layout: TextKit 1 lays out only what's needed (≈ the viewport)
        // instead of the whole document up front — the key lever for opening and scrolling
        // long documents fast with low memory.
        layout.allowsNonContiguousLayout = true
        let container = NSTextContainer(size: NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = true
        layout.addTextContainer(container)
        textView = ReaderTextView(frame: .zero, textContainer: container)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func display(_ attributed: NSAttributedString) {
        textView.textStorage?.setAttributedString(attributed)
        textView.recomputeHeadingOffsets()
        textView.resetCaret()
        window?.makeFirstResponder(textView)
        // Place buttons after layout has a chance to run.
        DispatchQueue.main.async { [weak self] in self?.placeCopyButtons() }
    }

    /// The live text storage, so the document layer can swap mermaid placeholders in place.
    var textStorageRef: NSTextStorage? { textView.textStorage }

    /// Called after the document layer mutates the text (e.g. the mermaid swap), which
    /// shifts character offsets. Recompute heading offsets from the live text, clamp the
    /// caret to the new length, and re-place copy buttons.
    func refreshAfterMutation() {
        textView.recomputeHeadingOffsets()
        textView.clampCaretToText()
        placeCopyButtons()
    }

    // MARK: - Copy-button overlay

    private var copyButtons: [NSButton] = []
    private var pendingPlace: DispatchWorkItem?

    @objc private func viewportChanged() {
        pendingPlace?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.placeCopyButtons() }
        pendingPlace = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    func placeCopyButtons() {
        copyButtons.forEach { $0.removeFromSuperview() }
        copyButtons.removeAll()
        guard let storage = textView.textStorage,
              let lm = textView.layoutManager,
              let container = textView.textContainer, storage.length > 0 else { return }
        // Visible character range only — enumerating attributes is cheap (no layout), but
        // boundingRect forces glyph layout, so we compute it solely for on-screen blocks.
        let visibleRect = textView.visibleRect
        let visibleGlyphs = lm.glyphRange(forBoundingRect: visibleRect, in: container)
        let visibleChars = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        guard visibleChars.length > 0 else { return }
        storage.enumerateAttribute(MDAttr.codeBlock, in: visibleChars) { value, range, _ in
            guard let code = value as? String else { return }
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.x += textView.textContainerInset.width
            rect.origin.y += textView.textContainerInset.height
            let btn = NSButton(title: "Copy", target: self, action: #selector(copyCode(_:)))
            btn.bezelStyle = .inline
            btn.font = .systemFont(ofSize: 10)
            btn.sizeToFit()
            // Top-right of the card (card right edge = inset + container width - margin),
            // independent of the code line length.
            let cardRight = textView.textContainerInset.width + container.size.width - CodeCardMetrics.horizontalMargin
            btn.setFrameOrigin(NSPoint(x: cardRight - btn.frame.width - 6,
                                       y: rect.minY - CodeCardMetrics.verticalPadding + 3))
            btn.identifier = NSUserInterfaceItemIdentifier(code)
            textView.addSubview(btn)
            copyButtons.append(btn)
        }
    }

    @objc private func copyCode(_ sender: NSButton) {
        guard let code = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        sender.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sender.title = "Copy" }
    }
}

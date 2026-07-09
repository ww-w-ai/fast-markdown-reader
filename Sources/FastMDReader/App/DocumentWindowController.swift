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
        textView.usesFindBar = true           // ⌘F find bar (free for NSTextView)
        textView.isIncrementalSearchingEnabled = true
        // Standard NSScrollView + NSTextView sizing: without a non-zero frame and a huge
        // maxSize, a manually-created text view can't grow past its initial frame, so the
        // document is clipped to the visible area and won't scroll.
        let content = window.contentLayoutRect.size
        textView.frame = NSRect(origin: .zero, size: content)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false   // viewer never scrolls sideways; text wraps
        scrollView.drawsBackground = true
        window.contentView = scrollView
        updateTextInset()

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
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        // Wrap at an EXPLICIT container width (set in updateTextInset) rather than tracking
        // the text view — tracking left the view too wide, so text overflowed the window.
        container.widthTracksTextView = false
        layout.addTextContainer(container)
        textView = ReaderTextView(frame: .zero, textContainer: container)
        super.init(window: window)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // Readability: cap the text column to a ~660pt measure (~66 chars at 15pt) and center
    // it, growing the side gutters on wide windows instead of the line length (Butterick /
    // Baymard / WCAG 1.4.12). Centering via textContainerInset also guarantees text wraps to
    // the column, so the viewer never scrolls sideways.
    private let maxColumnWidth: CGFloat = 660
    private let minSideInset: CGFloat = 28
    private let verticalInset: CGFloat = 28

    private func updateTextInset() {
        let clipWidth = scrollView.contentSize.width
        guard clipWidth > 1 else { return }
        // Column = the readable measure, capped at 660 and never wider than the window minus
        // margins; centered by the side inset. Text view fills the clip; the container wraps
        // at `column`, so nothing overflows sideways.
        let column = min(maxColumnWidth, max(200, clipWidth - 2 * minSideInset))
        let side = (clipWidth - column) / 2
        textView.textContainerInset = NSSize(width: side, height: verticalInset)
        textView.textContainer?.containerSize = NSSize(width: column, height: CGFloat.greatestFiniteMagnitude)
        var f = textView.frame; f.size.width = clipWidth; textView.frame = f
    }

    func display(_ attributed: NSAttributedString) {
        updateTextInset()
        textView.textStorage?.setAttributedString(attributed)
        textView.recomputeHeadingOffsets()
        textView.resetCaret()
        window?.makeFirstResponder(textView)
        // Re-apply the column and place buttons after layout has established real sizes.
        DispatchQueue.main.async { [weak self] in
            self?.updateTextInset()
            self?.placeCopyButtons()
        }
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

    private var lastClipWidth: CGFloat = 0

    @objc private func viewportChanged() {
        // Recompute the centered column only when the width actually changed (a window
        // resize), not on every scroll — avoids reflow churn while scrolling.
        let w = scrollView.contentSize.width
        if abs(w - lastClipWidth) > 0.5 { lastClipWidth = w; updateTextInset() }
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

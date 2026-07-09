import AppKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate {
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
        window.delegate = self                     // windowDidResize → recompute the column
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

    // Re-render the centered column and re-place code overlays whenever the window resizes.
    func windowDidResize(_ notification: Notification) {
        lastClipWidth = scrollView.contentSize.width
        updateTextInset()
        placeCopyButtons()
    }

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

    // Text fills the window width, with comfortable side margins (per user preference — the
    // readable ~660pt cap felt too narrow). Wrapping at an explicit container width still
    // guarantees the viewer never scrolls sideways.
    private let minSideInset: CGFloat = 32
    private let verticalInset: CGFloat = 28

    private func updateTextInset() {
        let clipWidth = scrollView.contentSize.width
        guard clipWidth > 1 else { return }
        let column = max(200, clipWidth - 2 * minSideInset)   // fill the window minus margins
        textView.textContainerInset = NSSize(width: minSideInset, height: verticalInset)
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

    // MARK: - Zoom anchor (keep the top visible line stable across a font-size change)

    /// The character index currently at the top of the visible area.
    func topVisibleCharIndex() -> Int {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              lm.numberOfGlyphs > 0 else { return 0 }
        let visible = textView.visibleRect
        let pt = NSPoint(x: 4, y: visible.minY - textView.textContainerInset.height + 1)
        let glyph = lm.glyphIndex(for: pt, in: tc)
        return lm.characterIndexForGlyph(at: min(glyph, lm.numberOfGlyphs - 1))
    }

    /// Scroll so the given character sits at the top of the viewport (top anchor).
    func scrollCharToTop(_ charIndex: Int) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              let storage = textView.textStorage, lm.numberOfGlyphs > 0 else { return }
        let idx = min(max(0, charIndex), storage.length)
        let glyph = lm.glyphIndexForCharacter(at: idx)
        var rect = lm.lineFragmentRect(forGlyphAt: min(glyph, lm.numberOfGlyphs - 1), effectiveRange: nil)
        rect.origin.y += textView.textContainerInset.height
        let clip = scrollView.contentView
        let maxY = max(0, textView.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, rect.origin.y), maxY)))
        scrollView.reflectScrolledClipView(clip)
        placeCopyButtons()
    }

    /// Called after the document layer mutates the text (e.g. the mermaid swap), which
    /// shifts character offsets. Recompute heading offsets from the live text, clamp the
    /// caret to the new length, and re-place copy buttons.
    func refreshAfterMutation() {
        textView.recomputeHeadingOffsets()
        textView.clampCaretToText()
        placeCopyButtons()
    }

    // MARK: - Code-block overlays (Copy + Wrap toggle + optional no-wrap scroll view)

    private var codeOverlays: [NSView] = []
    private var noWrapCodes: Set<String> = []   // code blocks toggled to no-wrap (per session)
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

    /// Place the Copy + Wrap buttons (and, for no-wrap blocks, a horizontally-scrollable code
    /// overlay) for every code block currently on screen. Rebuilt on scroll/resize so only
    /// visible blocks cost anything; the no-wrap overlay exists only for toggled blocks, so a
    /// normal document loads with zero extra views.
    func placeCopyButtons() {
        codeOverlays.forEach { $0.removeFromSuperview() }
        codeOverlays.removeAll()
        guard let storage = textView.textStorage,
              let lm = textView.layoutManager,
              let container = textView.textContainer, storage.length > 0 else { return }
        let visibleRect = textView.visibleRect
        let visibleGlyphs = lm.glyphRange(forBoundingRect: visibleRect, in: container)
        let visibleChars = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        guard visibleChars.length > 0 else { return }
        let inset = textView.textContainerInset
        let cardRight = inset.width + container.size.width - CodeCardMetrics.horizontalMargin
        let cardLeft = inset.width + CodeCardMetrics.horizontalMargin

        storage.enumerateAttribute(MDAttr.codeBlock, in: visibleChars) { value, range, _ in
            guard let code = value as? String else { return }
            let lang = (storage.attribute(MDAttr.codeLang, at: range.location, effectiveRange: nil) as? String) ?? ""
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.x += inset.width; rect.origin.y += inset.height
            let headerY = rect.minY + 2   // the blank header line reserved by the renderer

            // No-wrap overlay covers the code area (below the header line) with its own scroller.
            if self.noWrapCodes.contains(code), range.length > 2 {
                let codeChars = NSRange(location: range.location + 2, length: range.length - 2)
                let codeGlyphs = lm.glyphRange(forCharacterRange: codeChars, actualCharacterRange: nil)
                var codeRect = lm.boundingRect(forGlyphRange: codeGlyphs, in: container)
                codeRect.origin.x += inset.width; codeRect.origin.y += inset.height
                let frame = NSRect(x: cardLeft, y: codeRect.minY,
                                   width: cardRight - cardLeft, height: codeRect.height)
                let sv = self.makeNoWrapCodeView(code: code, lang: lang, frame: frame)
                self.textView.addSubview(sv)
                self.codeOverlays.append(sv)
            }

            let copy = self.makeButton("Copy", action: #selector(self.copyCode(_:)), code: code)
            let wrapTitle = self.noWrapCodes.contains(code) ? "Wrap" : "No-wrap"
            let wrap = self.makeButton(wrapTitle, action: #selector(self.toggleWrap(_:)), code: code)
            copy.setFrameOrigin(NSPoint(x: cardRight - copy.frame.width - 6, y: headerY))
            wrap.setFrameOrigin(NSPoint(x: copy.frame.minX - wrap.frame.width - 6, y: headerY))
            self.textView.addSubview(copy)   // buttons on top of any overlay
            self.textView.addSubview(wrap)
            self.codeOverlays.append(copy); self.codeOverlays.append(wrap)
        }
    }

    private func makeButton(_ title: String, action: Selector, code: String) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.bezelStyle = .inline
        b.font = .systemFont(ofSize: 10)
        b.sizeToFit()
        b.identifier = NSUserInterfaceItemIdentifier(code)
        return b
    }

    private func makeNoWrapCodeView(code: String, lang: String, frame: NSRect) -> NSScrollView {
        let sv = NSScrollView(frame: frame)
        sv.hasHorizontalScroller = true
        sv.hasVerticalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = true
        sv.backgroundColor = .textBackgroundColor   // opaque, hides the folded code underneath
        sv.wantsLayer = true
        sv.layer?.cornerRadius = CodeCardMetrics.cornerRadius
        sv.layer?.borderWidth = 1
        sv.layer?.borderColor = NSColor.textColor.withAlphaComponent(0.11).cgColor
        let tv = NSTextView(frame: NSRect(origin: .zero, size: frame.size))
        tv.isEditable = false; tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: CodeCardMetrics.textInset, height: 4)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let hl = CodeHighlighter.highlight(code, language: lang.isEmpty ? nil : lang,
                                           theme: .current(size: FontSizeStore.size))
        tv.textStorage?.setAttributedString(hl)
        sv.documentView = tv
        return sv
    }

    @objc private func copyCode(_ sender: NSButton) {
        guard let code = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        sender.title = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { sender.title = "Copy" }
    }

    @objc private func toggleWrap(_ sender: NSButton) {
        guard let code = sender.identifier?.rawValue else { return }
        if noWrapCodes.contains(code) { noWrapCodes.remove(code) } else { noWrapCodes.insert(code) }
        placeCopyButtons()
    }
}

import AppKit

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate {
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
        // Don't let macOS restore previously-open documents on relaunch — every launch starts
        // clean, so closing the window / quitting doesn't leave old docs (tabs) behind next time.
        window.isRestorable = false
        self.init(window: window)
        window.center()

        // Editable so a real blinking insertion point (caret) is shown and arrow-key caret
        // navigation works — you can see where a selection will start, and future editing is a
        // one-line change. Actual mutations are rejected in shouldChangeTextIn (read-only by
        // policy). Substitutions/spell-check are off so nothing tries to change the text.
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true           // ⌘F find bar (free for NSTextView)
        textView.isIncrementalSearchingEnabled = true
        textView.delegate = self              // intercept link/path clicks
        textView.displaysLinkToolTips = true
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
        // NSClipView repaints only the newly-exposed strip while scrolling, so custom card/quote
        // backgrounds can tear briefly mid-scroll. That's fine: viewportChanged repaints the whole
        // visible area ONCE when scrolling settles.
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
        // Reflow immediately for a responsive resize; the overlay re-placement rides the debounced
        // viewportChanged (frame/bounds change) — no need to also rebuild overlays on every step.
        lastClipWidth = scrollView.contentSize.width
        updateTextInset()
    }

    override init(window: NSWindow?) {
        let storage = NSTextStorage()
        let layout = CodeCardLayoutManager()   // draws code blocks as rounded cards
        storage.addLayoutManager(layout)
        // CONTIGUOUS layout. We deliberately precompute the whole document's layout anyway (for a
        // complete scroll bar from the start), so non-contiguous layout's "lay out only the
        // viewport" benefit is already given up. Worse, with non-contiguous layout every attachment
        // edit (a diagram/image loading) drops the layout below it and reverts the total height to
        // an ESTIMATE for a frame — which is exactly the scroll-bar jitter. Contiguous layout keeps
        // the full layout, so an unchanged-size edit re-renders just that glyph and the height (and
        // scroll bar) never move.
        layout.allowsNonContiguousLayout = false
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

    /// Redraw just the glyphs for a character range WITHOUT invalidating layout — used when a media
    /// attachment's IMAGE toggles (load/purge) but its reserved size (owned by SizedAttachmentCell)
    /// is unchanged. Touching layout here would resize the frame from a partial usedRect mid-scroll
    /// (the scroll-bar jitter); this only repaints, so the frame/scroll bar never move.
    func redrawGlyphs(_ r: NSRange) {
        guard let lm = textView.layoutManager, let tc = textView.textContainer else { return }
        let gr = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: gr, in: tc)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        textView.setNeedsDisplay(rect)
    }

    // MARK: - Zoom anchor (keep the top visible line stable across a font-size change)

    private var layoutToken = 0

    /// Lay out the ENTIRE document up front (media are placeholders, so this is cheap — no images
    /// are rasterized) so the scroll bar reflects the full length immediately: the reader sees how
    /// much content there is without scrolling. Done in small chunks across run-loop turns to keep
    /// the UI responsive; aborts if the document changes.
    func precomputeLayout() {
        layoutToken += 1
        let token = layoutToken
        guard let lm = textView.layoutManager, let storage = textView.textStorage else { return }
        let total = storage.length
        let chunk = 20_000
        func step(_ loc: Int) {
            guard token == self.layoutToken, loc < total, self.textView.textStorage?.length == total else { return }
            let end = min(loc + chunk, total)
            lm.ensureLayout(forCharacterRange: NSRange(location: loc, length: end - loc))
            if end < total { DispatchQueue.main.async { step(end) } }
        }
        DispatchQueue.main.async { step(0) }
    }

    /// Visible character range grown by `margin` screenfuls above and below — the region whose
    /// images/diagrams should stay loaded. (Also lays that region out, which smooths scrolling.)
    func visibleCharRange(margin: CGFloat) -> NSRange {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0 else { return NSRange(location: 0, length: 0) }
        let rect = textView.visibleRect.insetBy(dx: 0, dy: -textView.visibleRect.height * margin)
        let gr = lm.glyphRange(forBoundingRect: rect, in: tc)
        return lm.characterRange(forGlyphRange: gr, actualGlyphRange: nil)
    }

    /// The character index currently at the top of the visible area.
    func topVisibleCharIndex() -> Int {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              lm.numberOfGlyphs > 0 else { return 0 }
        let visible = textView.visibleRect
        let pt = NSPoint(x: 4, y: visible.minY - textView.textContainerInset.height + 1)
        let glyph = lm.glyphIndex(for: pt, in: tc)
        return lm.characterIndexForGlyph(at: min(glyph, lm.numberOfGlyphs - 1))
    }

    /// Scroll so the given character sits at the top of the viewport. `lineOffset` pushes it down
    /// by N lines (used when selecting downward so the already-selected line above stays visible).
    func scrollCharToTop(_ charIndex: Int, lineOffset: Int = 0) {
        guard let lm = textView.layoutManager,
              let storage = textView.textStorage, lm.numberOfGlyphs > 0 else { return }
        let idx = min(max(0, charIndex), storage.length)
        let glyph = lm.glyphIndexForCharacter(at: idx)
        var rect = lm.lineFragmentRect(forGlyphAt: min(glyph, lm.numberOfGlyphs - 1), effectiveRange: nil)
        rect.origin.y += textView.textContainerInset.height
        let targetY = rect.origin.y - CGFloat(lineOffset) * rect.height
        let clip = scrollView.contentView
        let maxY = max(0, textView.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, targetY), maxY)))
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

    /// Lightweight refresh for image fills: an attachment's size changed (editedAttributes,
    /// changeInLength 0) so CHARACTER OFFSETS are unchanged — heading offsets don't need
    /// recomputing. Coalesce the button re-placement so N images cost ONE placement, not N
    /// full-document passes (was O(N²) via refreshAfterMutation per image).
    func refreshAfterImageFill() {
        pendingPlace?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.placeCopyButtons() }
        pendingPlace = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    // MARK: - Code-block overlays (Copy + Wrap toggle + optional no-wrap scroll view)

    private var codeOverlays: [NSView] = []
    private var lastPlacementSig = ""            // skip overlay rebuild when nothing relevant changed
    private var noWrapCodes: Set<String> = []   // code blocks toggled to no-wrap (per session)
    private var pendingPlace: DispatchWorkItem?
    private var lastClipWidth: CGFloat = 0

    @objc private func viewportChanged() {
        // Recompute the centered column only when the width actually changed (a window
        // resize), not on every scroll — avoids reflow churn while scrolling.
        let w = scrollView.contentSize.width
        if abs(w - lastClipWidth) > 0.5 { lastClipWidth = w; updateTextInset() }
        pendingPlace?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.placeCopyButtons()
            // Free off-screen images/diagrams and reload near-screen ones (memory bounded to the
            // viewport on long docs).
            (self.document as? MarkdownDocument)?.reconcileMedia(in: self)
            // Scroll has settled: repaint the whole visible area once so any card/quote background
            // torn by copy-on-scroll blitting is drawn clean (mid-scroll tearing is acceptable).
            self.textView.setNeedsDisplay(self.textView.visibleRect)
        }
        pendingPlace = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    /// Place the Copy + Wrap buttons (and, for no-wrap blocks, a horizontally-scrollable code
    /// overlay) for every code block currently on screen. Rebuilt on scroll/resize so only
    /// visible blocks cost anything; the no-wrap overlay exists only for toggled blocks, so a
    /// normal document loads with zero extra views.
    private func teardownOverlays() {
        codeOverlays.forEach { $0.removeFromSuperview() }
        codeOverlays.removeAll()
    }

    func placeCopyButtons() {
        guard let storage = textView.textStorage,
              let lm = textView.layoutManager,
              let container = textView.textContainer, storage.length > 0 else {
            teardownOverlays(); lastPlacementSig = ""; return
        }
        let visibleRect = textView.visibleRect
        let visibleGlyphs = lm.glyphRange(forBoundingRect: visibleRect, in: container)
        let visibleChars = lm.characterRange(forGlyphRange: visibleGlyphs, actualGlyphRange: nil)
        guard visibleChars.length > 0 else { teardownOverlays(); lastPlacementSig = ""; return }
        let whole = NSRange(location: 0, length: storage.length)
        // Signature of everything that determines overlay layout: visible code blocks (full range
        // + wrap state + vertical position) plus column width and font size. If unchanged since the
        // last placement, existing overlays are still correct — skip the teardown + rebuild.
        var sig = "\(Int(container.size.width))|\(FontSizeStore.size)"
        storage.enumerateAttribute(MDAttr.codeBlock, in: visibleChars) { value, visRange, _ in
            guard let code = value as? String else { return }
            var range = visRange
            _ = storage.attribute(MDAttr.codeBlock, at: visRange.location, longestEffectiveRange: &range, in: whole)
            let g = lm.glyphRange(forCharacterRange: NSRange(location: range.location, length: 1), actualCharacterRange: nil).location
            let y = Int(lm.lineFragmentRect(forGlyphAt: g, effectiveRange: nil).minY)
            sig += "#\(range.location):\(range.length):\(self.noWrapCodes.contains(code) ? 1 : 0):\(y)"
        }
        if sig == lastPlacementSig { return }
        lastPlacementSig = sig
        teardownOverlays()
        let inset = textView.textContainerInset
        let cardRight = inset.width + container.size.width - CodeCardMetrics.horizontalMargin
        let cardLeft = inset.width + CodeCardMetrics.horizontalMargin

        storage.enumerateAttribute(MDAttr.codeBlock, in: visibleChars) { value, visRange, _ in
            guard let code = value as? String else { return }
            // The enumeration range is CLIPPED to the visible portion; anchoring to it pins the
            // header to the viewport top as you scroll. Recover the block's FULL range so the
            // header sits at the block's real top and scrolls away with it.
            var range = visRange
            _ = storage.attribute(MDAttr.codeBlock, at: visRange.location, longestEffectiveRange: &range, in: whole)
            let lang = (storage.attribute(MDAttr.codeLang, at: range.location, effectiveRange: nil) as? String) ?? ""
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rect = lm.boundingRect(forGlyphRange: glyphRange, in: container)
            rect.origin.x += inset.width; rect.origin.y += inset.height
            let headerY = rect.minY + 2   // the blank header line reserved by the renderer
            // Nested-in-quote code shifts its card (and chrome) right to align with the quote.
            let qInset = CGFloat((storage.attribute(MDAttr.codeInset, at: range.location, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0)
            let blockLeft = cardLeft + qInset

            // The code text starts after the 2-char blank header line.
            if range.length > 2 {
                let codeChars = NSRange(location: range.location + 2, length: range.length - 2)
                let codeGlyphs = lm.glyphRange(forCharacterRange: codeChars, actualCharacterRange: nil)
                var codeRect = lm.boundingRect(forGlyphRange: codeGlyphs, in: container)
                codeRect.origin.x += inset.width; codeRect.origin.y += inset.height

                // No-wrap overlay covers the code area (below the header) with its own scroller.
                if self.noWrapCodes.contains(code) {
                    let frame = NSRect(x: blockLeft, y: codeRect.minY,
                                       width: cardRight - blockLeft, height: codeRect.height)
                    let sv = self.makeNoWrapCodeView(code: code, lang: lang, frame: frame)
                    self.textView.addSubview(sv)
                    self.codeOverlays.append(sv)
                }
            }

            // Header divider — separates the header row (lang label + buttons) from the code,
            // making each block read as a real code card.
            let divider = NSView(frame: NSRect(x: blockLeft, y: headerY + 18,
                                               width: cardRight - blockLeft, height: 1))
            divider.wantsLayer = true
            divider.layer?.backgroundColor = Palette.hairline.cgColor
            self.textView.addSubview(divider)
            self.codeOverlays.append(divider)

            // Header strip runs from the card's top edge to the divider; center its chrome in it.
            let cardTopY = headerY - 2 - CodeCardMetrics.verticalPadding
            let bandCenterY = (cardTopY + (headerY + 18)) / 2

            // Language label on the left of the header (e.g. "SWIFT", "PYTHON").
            if !lang.isEmpty {
                let label = self.makeLangLabel(lang)
                label.setFrameOrigin(NSPoint(x: blockLeft + CodeCardMetrics.textInset, y: bandCenterY - label.frame.height / 2))
                self.textView.addSubview(label)
                self.codeOverlays.append(label)
            }

            let copy = self.makeChipButton("Copy", textColor: .secondaryLabelColor,
                bg: NSColor.textColor.withAlphaComponent(0.06), weight: .medium,
                action: #selector(self.copyCode(_:)), code: code, widest: "Copied")
            // Wrap toggle: accent fill + accent text when wrapping is ON; grey text, no fill when OFF.
            let wrapping = !self.noWrapCodes.contains(code)
            let wrap = self.makeChipButton("Wrap",
                textColor: wrapping ? Palette.link : .tertiaryLabelColor,
                bg: wrapping ? Palette.link.withAlphaComponent(0.16) : .clear,
                weight: wrapping ? .semibold : .regular,
                action: #selector(self.toggleWrap(_:)), code: code)
            let btnY = bandCenterY - copy.frame.height / 2
            copy.setFrameOrigin(NSPoint(x: cardRight - copy.frame.width - 6, y: btnY))
            wrap.setFrameOrigin(NSPoint(x: copy.frame.minX - wrap.frame.width - 4, y: btnY))
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

    /// A uniform header chip (Copy / Wrap) — same size and shape so they line up; only the
    /// colors differ (Wrap uses an accent fill when wrapping is on, grey when off).
    /// `widest` is the longest label this chip will ever show. The chip is sized for THAT, so
    /// switching label (Copy → Copied) can't clip the text or shove its neighbour sideways — the
    /// frame is set once here and never touched again.
    private func makeChipButton(_ title: String, textColor: NSColor, bg: NSColor,
                                weight: NSFont.Weight, action: Selector, code: String,
                                widest: String? = nil) -> NSButton {
        let b = NSButton(title: title, target: self, action: action)
        b.isBordered = false
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: weight), .foregroundColor: textColor]
        b.attributedTitle = NSAttributedString(string: widest ?? title, attributes: attrs)
        b.sizeToFit()
        var f = b.frame; f.size.width += 14; f.size.height = 17; b.frame = f
        b.attributedTitle = NSAttributedString(string: title, attributes: attrs)   // frame stays
        b.wantsLayer = true
        b.layer?.cornerRadius = 4
        b.layer?.backgroundColor = bg.cgColor
        b.identifier = NSUserInterfaceItemIdentifier(code)
        return b
    }

    /// A small uppercase language tag ("SWIFT", "PYTHON") for the code-card header.
    private func makeLangLabel(_ lang: String) -> NSTextField {
        let f = NSTextField(labelWithString: lang.uppercased())
        f.font = .monospacedSystemFont(ofSize: 9, weight: .semibold)
        f.textColor = .tertiaryLabelColor
        f.sizeToFit()
        return f
    }

    private func makeNoWrapCodeView(code: String, lang: String, frame: NSRect) -> NSScrollView {
        let sv = NSScrollView(frame: frame)
        sv.hasHorizontalScroller = true
        sv.hasVerticalScroller = false
        sv.autohidesScrollers = true
        sv.drawsBackground = true
        sv.backgroundColor = Palette.codeCardBg      // opaque, matches the card, hides folded code
        sv.wantsLayer = true
        sv.layer?.cornerRadius = CodeCardMetrics.cornerRadius
        sv.layer?.borderWidth = 1
        sv.layer?.borderColor = Palette.codeCardBorder.cgColor
        let tv = NSTextView(frame: NSRect(origin: .zero, size: frame.size))
        tv.isEditable = false; tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: CodeCardMetrics.textInset, height: 4)
        tv.isHorizontallyResizable = true
        tv.isVerticallyResizable = true
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let overlayTheme = RenderTheme.current(size: FontSizeStore.size)
        let hl = NSMutableAttributedString(attributedString:
            CodeHighlighter.highlight(code, language: lang.isEmpty ? nil : lang, theme: overlayTheme))
        // Match the wrapped card's line leading so no-wrap lines aren't tighter than wrap mode.
        let codeLH = (overlayTheme.codeFont.pointSize * 1.4).rounded()
        let ps = NSMutableParagraphStyle()
        ps.minimumLineHeight = codeLH; ps.maximumLineHeight = codeLH
        hl.addAttribute(.paragraphStyle, value: ps, range: NSRange(location: 0, length: hl.length))
        tv.textStorage?.setAttributedString(hl)
        sv.documentView = tv

        // Force layout of this (visible, user-toggled) block to measure its real extent —
        // deterministic, and only paid for a block on screen.
        if let tc = tv.textContainer, let tlm = tv.layoutManager {
            tlm.ensureLayout(for: tc)
            let usedRect = tlm.usedRect(for: tc)
            // Does the code overflow horizontally? If so a scroller appears along the bottom and
            // would sit ON TOP of the last code line — reserve extra height for it.
            let used = usedRect.width + 2 * CodeCardMetrics.textInset
            let hasHScroll = used > frame.width + 1
            let scrollerPad: CGFloat = hasHScroll ? 16 : 0
            // Fit the overlay to its ACTUAL content (+ top/bottom inset + scroller room) so the
            // last code line is never clipped.
            let contentH = ceil(usedRect.height + 2 * 4 + scrollerPad)
            if contentH > sv.frame.height {
                sv.setFrameSize(NSSize(width: sv.frame.width, height: contentH))
                tv.setFrameSize(NSSize(width: sv.frame.width, height: contentH))
            }
            // Resizing the document view can leave the clip view scrolled off the top line;
            // pin it back to the origin so the first code line is never clipped.
            sv.contentView.scroll(to: .zero)
            sv.reflectScrolledClipView(sv.contentView)
            // Scroll affordance: fade the right edge so it reads as "there's more →".
            if hasHScroll {
                let fade = EdgeFadeView(frame: NSRect(x: sv.frame.width - 26, y: 0, width: 26, height: sv.frame.height))
                fade.autoresizingMask = [.minXMargin, .height]
                sv.addSubview(fade)
            }
        }
        return sv
    }

    @objc private func copyCode(_ sender: NSButton) {
        guard let code = sender.identifier?.rawValue else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        setChipTitle(sender, "Copied")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.setChipTitle(sender, "Copy") }
    }

    /// A chip's whole look (10pt, its colour) lives in its attributedTitle. Assigning `.title`
    /// silently throws all of that away and the label snaps to the default 13pt system font —
    /// which is why "Copied" appeared twice the size of "Copy". Re-use the existing attributes.
    private func setChipTitle(_ b: NSButton, _ title: String) {
        let attrs = b.attributedTitle.length > 0
            ? b.attributedTitle.attributes(at: 0, effectiveRange: nil) : [:]
        b.attributedTitle = NSAttributedString(string: title, attributes: attrs)
    }

    @objc private func toggleWrap(_ sender: NSButton) {
        guard let code = sender.identifier?.rawValue, let storage = textView.textStorage else { return }
        let noWrap = !noWrapCodes.contains(code)
        if noWrap { noWrapCodes.insert(code) } else { noWrapCodes.remove(code) }
        // Change the underlying code paragraphs' wrapping so the BLOCK HEIGHT actually reflows:
        // wrap = fold long lines (tall); no-wrap = one clipped line per source line (short), with
        // the scroll overlay providing horizontal scrolling on top.
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.enumerateAttribute(MDAttr.codeBlock, in: whole) { v, r, _ in
            guard (v as? String) == code else { return }
            storage.enumerateAttribute(.paragraphStyle, in: r, options: []) { ps, sub, _ in
                guard let ps = ps as? NSParagraphStyle, let mps = ps.mutableCopy() as? NSMutableParagraphStyle else { return }
                // no-wrap: the OVERLAY shows the scrollable code; the underlying copy just needs to
                // keep the block's height. Use truncatingTail (not clipping) so a long line stops at
                // the card's right edge instead of overflowing past the overlay and peeking out.
                mps.lineBreakMode = noWrap ? .byTruncatingTail : .byCharWrapping
                storage.addAttribute(.paragraphStyle, value: mps, range: sub)
            }
        }
        storage.endEditing()
        placeCopyButtons()
    }

    /// Read-only by policy: the view is editable (for a visible caret + future editing) but we
    /// reject every mutation. Flip this to allow editing later.
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange,
                  replacementString: String?) -> Bool { false }

    // MARK: - Link / file-path clicks

    /// Open clicked links: web URLs in the browser, `.md` files as a tab (focusing an already-
    /// open one), other files in their associated app, and folders in Finder.
    func textView(_ tv: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        // In-document anchor (a TOC entry) → scroll to the matching heading.
        if let slug = tv.textStorage?.attribute(MDAttr.anchor, at: charIndex, effectiveRange: nil) as? String {
            jumpToHeading(slug: slug); return true
        }
        // A detected file path (stored raw so it can be resolved against the document's folder).
        if let raw = tv.textStorage?.attribute(MDAttr.filePath, at: charIndex, effectiveRange: nil) as? String {
            openFile(resolvePath(raw)); return true
        }
        let url: URL? = (link as? URL) ?? (link as? String).flatMap { URL(string: $0) }
        guard let url else { return false }
        if url.isFileURL {
            openFile(url)
        } else if url.scheme == nil {
            // `[docs](demo/code-blocks.md)` — a relative link, which is how every README on earth
            // points at its neighbours. It is neither a file: URL nor a web one, so handing it to
            // NSWorkspace asks macOS to open "demo/code-blocks.md" as a web address and it fails.
            // Resolve it against the document's own folder, exactly like a bare path in the prose.
            openFile(resolvePath(url.relativePath.removingPercentEncoding ?? url.relativePath))
        } else {
            NSWorkspace.shared.open(url)   // http(s), mailto → the system handler
        }
        return true
    }

    /// Menu counterpart of clicking a blocked image — the same grant, reachable when a document's
    /// images are blocked but none is on screen.
    @objc func grantFolderAccess(_ sender: Any?) {
        grantFolder()
    }

    /// Ask for the folder, then re-read the document: placeholders were sized as placeholders, and
    /// every image can now be measured for real, so a full re-render is both simplest and correct.
    private func grantFolder() {
        guard let doc = (document as? NSDocument)?.fileURL else { return }
        FolderAccess.requestAccess(to: FolderAccess.suggestedFolder(for: doc), in: window) { [weak self] granted in
            guard granted else { return }
            (self?.document as? MarkdownDocument)?.reloadDocument(nil)
        }
    }

    /// Resolve a GFM anchor slug to its heading and scroll there (top-anchored). Slugs are matched
    /// by the GitHub rule: lowercase, drop punctuation, spaces→hyphens (Hangul/CJK preserved).
    private func jumpToHeading(slug: String) {
        guard let storage = textView.textStorage else { return }
        let target = Self.slugify(slug)
        var found: Int?
        storage.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: storage.length)) { v, r, stop in
            guard v != nil else { return }
            if Self.slugify((storage.string as NSString).substring(with: r)) == target {
                found = r.location; stop.pointee = true
            }
        }
        if let f = found {
            textView.setSelectedRange(NSRange(location: f, length: 0))
            scrollCharToTop(f)
        } else {
            NSSound.beep()
        }
    }

    private static func slugify(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch == " " || ch == "\t" { out.append("-") }
            else if ch == "-" || ch == "_" || ch.isLetter || ch.isNumber { out.append(ch) }
        }
        return out
    }

    /// ⌘-click on a selection: open whatever was highlighted, even without an http prefix.
    /// Tries, in order: an explicit URL scheme → a resolvable file path → a bare web domain.
    /// Right-click → Edit: open the markdown SOURCE of the block(s) the selection touches in a
    /// popup; on save, replace just that source span and re-render (Notion-style block editing).
    func editSelectedSource(atChar: Int? = nil) {
        guard let storage = textView.textStorage, let doc = document as? MarkdownDocument, storage.length > 0 else { return }
        let sel = textView.selectedRange()
        // Use the selection if there is one; otherwise the block under the right-click (or caret).
        let anchor = (atChar ?? sel.location)
        let scan = sel.length > 0 ? sel
                                  : NSRange(location: min(max(0, anchor), storage.length - 1), length: 1)
        var lo = Int.max, hi = Int.min
        storage.enumerateAttribute(MDAttr.srcRange, in: scan) { v, _, _ in
            guard let r = (v as? NSValue)?.rangeValue else { return }
            lo = min(lo, r.location); hi = max(hi, r.location + r.length)
        }
        guard lo != Int.max, hi > lo else { NSSound.beep(); return }
        let srcRange = NSRange(location: lo, length: hi - lo)
        SourceEditPanel.show(markdown: doc.sourceSubstring(srcRange)) { [weak doc] edited in
            doc?.applySourceEdit(srcRange, with: edited)
        }
    }

    func openSelectionText(_ raw: String) {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { NSSound.beep(); return }
        if s.contains("://"), let url = URL(string: s) { NSWorkspace.shared.open(url); return }
        let fileURL = resolvePath(s)
        // An explicit path is a path even when it can't be stat'd (sandbox, or simply gone): let
        // openFile ask for the folder or beep, rather than falling through to a bogus https guess.
        if s.hasPrefix("/") || s.hasPrefix("~") || FileManager.default.fileExists(atPath: fileURL.path) {
            openFile(fileURL); return
        }
        // Schemeless web address ("ww-w.ai", "example.com/x") → assume https.
        if s.contains("."), !s.contains(" "), let url = URL(string: "https://\(s)") {
            NSWorkspace.shared.open(url); return
        }
        NSSound.beep()
    }

    /// Resolve a raw path: expand `~`, take absolute paths as-is, resolve relatives against
    /// the current document's directory.
    private func resolvePath(_ raw: String) -> URL {
        if raw.hasPrefix("~") { return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath) }
        if raw.hasPrefix("/") { return URL(fileURLWithPath: raw) }
        if let dir = (document as? NSDocument)?.fileURL?.deletingLastPathComponent() {
            return dir.appendingPathComponent(raw).standardizedFileURL
        }
        return URL(fileURLWithPath: raw)
    }

    /// Open a local target (folder, `.md` tab, or associated app).
    ///
    /// Sandboxed, a linked path outside the granted folders is refused by the system, not by us —
    /// macOS puts up its own "doesn't have permission to open X" alert and the click dead-ends. So a
    /// blocked link takes the same route as a blocked image: ask for the folder, then open. Retry
    /// once only (`afterGrant`), since a grant that doesn't cover the target would otherwise loop.
    private func openFile(_ url: URL, afterGrant: Bool = false) {
        if !afterGrant, FolderAccess.needsGrant(for: url) {
            FolderAccess.requestAccess(to: FolderAccess.suggestedFolder(for: url), in: window,
                                       what: "linked files") { [weak self] granted in
                guard granted else { return }               // cancelled: the user already said no
                self?.openFile(url, afterGrant: true)
            }
            return
        }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        let ext = url.pathExtension.lowercased()
        if exists, isDir.boolValue {
            NSWorkspace.shared.open(url)                    // folder → Finder
        } else if ext == "md" || ext == "markdown" {
            // Open (or focus) as a tab. NSDocumentController returns the already-open document
            // and fronts its window; tabbingMode = .preferred makes new windows join as tabs.
            NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, _ in }
        } else if exists {
            NSWorkspace.shared.open(url)                    // other file → associated app
        } else {
            NSSound.beep()                                  // dangling path
        }
    }

    // MARK: - Print (⌘P)

    private var printRestore: [(NSView, Bool)] = []

    @objc func printDocument(_ sender: Any?) {
        guard let window = window else { return }
        // Code-block overlays (Copy/Wrap buttons, no-wrap scrollers, dividers) are live subviews;
        // hide them so the printout shows clean code cards, then restore after the panel closes.
        printRestore = codeOverlays.map { ($0, $0.isHidden) }
        codeOverlays.forEach { $0.isHidden = true }
        let info = NSPrintInfo.shared
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        let op = NSPrintOperation(view: textView, printInfo: info)
        op.jobTitle = (document as? NSDocument)?.fileURL?.lastPathComponent ?? "Document"
        op.runModal(for: window, delegate: self,
                    didRun: #selector(printDidRun(_:success:contextInfo:)), contextInfo: nil)
    }

    @objc private func printDidRun(_ op: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
        printRestore.forEach { $0.0.isHidden = $0.1 }
        printRestore = []
    }

    // MARK: - Shortcut guide (?, Help menu)

    private static var guidePanel: NSPanel?

    @objc func showShortcutGuide(_ sender: Any?) {
        if let p = Self.guidePanel { p.makeKeyAndOrderFront(nil); return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 640),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Keyboard Shortcuts"
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 640))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        let tv = NSTextView(frame: scroll.bounds)
        tv.isEditable = false; tv.isSelectable = true
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 24, height: 22)
        tv.textStorage?.setAttributedString(Self.guideText())
        tv.isVerticallyResizable = true
        tv.autoresizingMask = [.width]
        scroll.documentView = tv
        panel.contentView = scroll
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        Self.guidePanel = panel
    }

    private static func guideText() -> NSAttributedString {
        let out = NSMutableAttributedString()
        let head = NSFont.boldSystemFont(ofSize: 12)
        let body = NSFont.systemFont(ofSize: 13)
        let key  = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let para = NSMutableParagraphStyle()
        para.tabStops = [NSTextTab(textAlignment: .left, location: 160)]
        para.defaultTabInterval = 160
        para.lineSpacing = 4
        para.paragraphSpacing = 2
        func section(_ title: String) {
            out.append(NSAttributedString(string: "\n\(title)\n",
                attributes: [.font: head, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
        }
        func row(_ k: String, _ desc: String) {
            out.append(NSAttributedString(string: k + "\t",
                attributes: [.font: key, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
            out.append(NSAttributedString(string: desc + "\n",
                attributes: [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: para]))
        }
        func note(_ text: String) {
            out.append(NSAttributedString(string: text + "\n",
                attributes: [.font: NSFont.systemFont(ofSize: 11),
                             .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: para]))
        }
        section("Navigation")
        note("Modifier position = jump size — farther left jumps bigger  (fn › ⌥ › ⌘)")
        row("⌘↑ / ⌘↓", "Previous / next heading")
        row("⌥↑ / ⌥↓", "Page up / down  (a few lines overlap, so you can find your place)")
        row("fn↑ / fn↓", "Document start / end")
        row("⌘← / ⌘→", "Start / end of the line")
        row("⌥← / ⌥→", "Previous / next sentence")
        row("fn← / fn→", "Previous / next paragraph")
        row("⇧ + any of these", "Same move, selecting what it crosses")
        row("Space / ⇧Space", "Page down / up")
        row("↑ ↓ ← →", "Move the reading cursor one line/char")
        section("File")
        row("⌘O", "Open");  row("⌘W", "Close tab");  row("⌘R", "Reload from disk");  row("⌘P", "Print")
        section("Find & copy")
        row("⌘F", "Find in document");  row("⌘C", "Copy selection");  row("⌘A", "Select all")
        section("Zoom (text)")
        row("⌘+ / ⌘−", "Increase / decrease font size");  row("⌘0", "Actual size")
        section("Window")
        row("⌘M", "Minimize");  row("⌃⇥ / ⌃⇧⇥", "Next / previous tab")
        section("Mouse")
        row("Click link / path", "Open a URL, file, or folder")
        row("⌘-Click selection", "Open the selected text as a link / path / file")
        row("Click left margin", "Copy that whole block (or section, beside a heading)")
        row("Right-click selection", "Copy · Open · Edit… (edit that block's markdown source)")
        row("Click a diagram / formula / image", "Open it enlarged in a zoomable window")
        row("Wrap / Copy button", "Toggle a code block's wrapping / copy its code")
        section("Diagram window")
        row("Pinch  or  + / −", "Zoom in / out");  row("0", "Fit to window");  row("Drag", "Move around (pan)")
        section("Help")
        row("?", "Show this guide")
        return out
    }
}

/// A non-interactive right-edge fade (clear → card background) that signals horizontal
/// overflow in a no-wrap code block. Overrides hitTest so it never intercepts scrolling.
final class EdgeFadeView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) {
        let bg = Palette.codeCardBg
        let gradient = NSGradient(colors: [bg.withAlphaComponent(0), bg])!
        gradient.draw(in: bounds, angle: 0)   // 0° = clear on the left, solid at the right edge
    }
}

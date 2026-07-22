import AppKit
import UniformTypeIdentifiers

final class DocumentWindowController: NSWindowController, NSWindowDelegate, NSTextViewDelegate,
                                     NSMenuItemValidation {
    // Explicit TextKit 1 stack (C2): building the view with init(frame:textContainer:)
    // guarantees the classic NSLayoutManager path instead of silently falling back
    // to TextKit 2 compatibility mode when layoutManager is later accessed.
    let textView: ReaderTextView
    private let scrollView = NSScrollView()
    private let outline = OutlinePanel(frame: NSRect(x: 0, y: 0, width: OutlinePanel.defaultWidth, height: 400))
    // P6b: the right-side comments panel — an INSPECTOR split item (trailing), distinct from the
    // outline's SIDEBAR item (leading). Both live on the same `splitVC`; `NSSplitViewController`
    // treats "sidebar" and "inspector" as independent kinds; see invariant 26/27's reasoning for
    // why this must be a real split item rather than a hand-built overlay.
    private let commentPanel = CommentPanel(frame: NSRect(x: 0, y: 0, width: CommentPanel.defaultWidth, height: 400))
    // A real NSSplitViewController with a `sidebar` item, not a hand-built NSSplitView. That is
    // what makes the panel LOOK like a Mac sidebar — the inset rounded panel, the system material,
    // the toolbar's ⌥⌘S toggle sitting beside the traffic lights, the divider that tracks it. Every
    // one of those was a thing to imitate by hand and get subtly wrong.
    private let splitVC = NSSplitViewController()
    /// The standard indeterminate spinner, shown over the text while a relayout runs.
    private let spinner: NSProgressIndicator = {
        let p = NSProgressIndicator()
        p.style = .spinning
        p.isIndeterminate = true
        p.controlSize = .regular
        p.isDisplayedWhenStopped = false
        p.isHidden = true
        return p
    }()
    private var sidebarItem: NSSplitViewItem!
    private var commentsItem: NSSplitViewItem!

    // MARK: R5 — read-only badge + "Edit in <App>" (office documents only)
    private let officeBadge = NSTextField(labelWithString: "Read-only")
    private let editButton = NSButton(title: "", target: nil, action: nil)
    private let editMenuButton = NSButton(title: "▾", target: nil, action: nil)
    private var officeAccessoryHost: NSView!
    private let externalEditorService = ExternalEditorService()

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
        // The table of contents sits beside the text as a system sidebar. Collapsed until asked
        // for: a reader opens a document to read it, not to look at a list of its headings.
        let sidebarVC = NSViewController()
        sidebarVC.view = outline
        sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 420
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = true
        let contentVC = NSViewController()
        contentVC.view = scrollView
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(NSSplitViewItem(viewController: contentVC))
        // P6b: the comments panel as a trailing INSPECTOR item, added AFTER content so it sits on
        // the right. Hidden by default (owner's decision, verbatim) — a document with no comments
        // (or one whose panel hasn't been asked for) shows nothing extra.
        let commentsVC = NSViewController()
        commentsVC.view = commentPanel
        commentsItem = NSSplitViewItem(inspectorWithViewController: commentsVC)
        commentsItem.minimumThickness = 220
        commentsItem.maximumThickness = 420
        commentsItem.canCollapse = true
        commentsItem.isCollapsed = true
        splitVC.addSplitViewItem(commentsItem)
        // Old name kept on purpose after the rename — a defaults key for the remembered sidebar
        // width, not a visible identifier. See the matching note on the window frame autosave.
        splitVC.splitView.autosaveName = "FastMDReaderSidebar"
        outline.onSelect = { [weak self] charIndex in self?.goToOutlineEntry(charIndex) }
        commentPanel.onSelect = { [weak self] number in self?.goToComment(number: number) }
        window.contentViewController = splitVC
        // The sidebar button goes in a TITLEBAR ACCESSORY, not a toolbar. Measured, twice: this
        // macOS lays toolbar items out trailing — with the title leading — so a toolbar button ends
        // up on the far right however the identifiers are ordered, and `.flexibleSpace` doesn't
        // move it. A `.leading` accessory is the documented way to put a control immediately right
        // of the traffic lights, which is where every Mac app keeps this one.
        let accessory = NSTitlebarAccessoryViewController()
        accessory.layoutAttribute = .leading
        accessory.view = sidebarButtonView()
        window.addTitlebarAccessoryViewController(accessory)
        // R5: the read-only badge + edit-in-app button mirror invariant 26's leading accessory,
        // just on the other side — `.trailing` puts it right of the title, not far-right (a
        // toolbar item would land there regardless of identifier order; see invariant 26).
        let officeAcc = NSTitlebarAccessoryViewController()
        officeAcc.layoutAttribute = .trailing
        officeAcc.view = officeAccessoryView()
        window.addTitlebarAccessoryViewController(officeAcc)
        // NOT fullSizeContentView / titlebarAppearsTransparent. Tried, and wrong: it runs the
        // document up under the title bar so text scrolls through it. The title bar stays solid and
        // opaque, which is what Preview does too — the sidebar is a panel below it, not behind it.
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

    // The text column is recomputed when a resize ENDS, not on every frame of one. Re-wrapping a
    // long document is a full relayout; doing it per frame is what makes a drag feel like it is
    // fighting you. During the drag the column simply keeps its old width and the window moves
    // around it — the same treatment the sidebar animation gets, and for the same reason.
    /// The line at the top of the viewport when a resize began — restored after the reflow.
    private var resizeAnchor = ReadingAnchor(char: 0, offsetFromTop: 0)

    func windowWillStartLiveResize(_ notification: Notification) {
        resizeAnchor = readingAnchor()
        suspendReflow = true
    }

    func windowDidEndLiveResize(_ notification: Notification) {
        lastClipWidth = scrollView.contentSize.width
        // Restore the reading position by CHARACTER, not by scroll offset. A narrower column wraps
        // the same text into more lines, so the document grows taller and the old offset lands
        // somewhere else entirely — further from where you were the longer the document is.
        reflow(keeping: resizeAnchor)
    }

    /// Re-wrap the document and put `anchor` back at the top, with the system spinner over it while
    /// that happens. On a 1MB file the relayout takes long enough to look like the app has stopped
    /// responding, and a spinner is the difference between "working" and "broken".
    ///
    /// The work runs on the NEXT run-loop turn: it blocks the main thread, so a spinner started and
    /// stopped around it in one turn would never paint. And the spinner only appears if the work
    /// outlasts a short delay — on a small document it finishes first and nothing flashes.
    private func reflow(keeping anchor: ReadingAnchor) {
        runBusy { [weak self] in
            guard let self else { return }
            self.suspendReflow = false
            self.updateTextInset()
            // Lay the WHOLE document out before scrolling. Narrowing the column wraps the text into
            // more lines, so the document gets taller — but until that layout exists the text view's
            // height is still the old, shorter one, and scrolling to the anchor gets clamped short
            // of it. That is why the position held when widening and drifted when narrowing, and
            // why opening the sidebar (narrower) drifted while closing it (wider) did not.
            if let lm = self.textView.layoutManager, let tc = self.textView.textContainer {
                lm.ensureLayout(for: tc)
                self.textView.sizeToFit()
            }
            self.restore(anchor)
            self.placeCopyButtons()
        }
    }

    /// Run work that blocks the main thread, with the spinner over it if it takes long enough to
    /// notice. Every path that re-lays out the whole document goes through here — resize, sidebar,
    /// font size — so none of them can look like a freeze.
    func runBusy(_ work: @escaping () -> Void) {
        // Show it FIRST and force it to draw. A delayed show can never fire: the work blocks the
        // main thread, so the timer only gets its turn after the work is already done and the
        // spinner has been cancelled — which is exactly why no spinner ever appeared.
        //
        // Only for documents big enough for the relayout to be visible; below that the work is a
        // few milliseconds and a spinner would be a flash of noise.
        let heavy = (textView.textStorage?.length ?? 0) > 120_000
        if heavy {
            setBusy(true)
            spinner.display()                     // paint it now, before the main thread is busy
        }
        DispatchQueue.main.async {
            work()
            if heavy { self.setBusy(false) }
        }
    }

    func setBusy(_ busy: Bool) {
        if busy {
            spinner.frame = NSRect(x: (scrollView.bounds.width - 32) / 2,
                                   y: (scrollView.bounds.height - 32) / 2, width: 32, height: 32)
            if spinner.superview == nil { scrollView.addFloatingSubview(spinner, for: .vertical) }
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
        }
    }

    func windowDidResize(_ notification: Notification) {
        // Still runs for programmatic resizes (zoom, tiling, entering full screen), which arrive in
        // one step and have no drag to be jerky — but reflow moves the text under the reader there
        // too, so the same anchor applies.
        guard !suspendReflow else { return }
        let anchor = readingAnchor()
        lastClipWidth = scrollView.contentSize.width
        updateTextInset()
        restore(anchor)
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

    /// Set while the sidebar animates: width changes are ignored until it settles (see the toggle).
    private var suspendReflow = false

    private func updateTextInset() {
        let clipWidth = scrollView.contentSize.width
        guard clipWidth > 1, !suspendReflow else { return }
        let column = max(200, clipWidth - 2 * minSideInset)   // fill the window minus margins
        textView.textContainerInset = NSSize(width: minSideInset, height: verticalInset)
        textView.textContainer?.containerSize = NSSize(width: column, height: CGFloat.greatestFiniteMagnitude)
        var f = textView.frame; f.size.width = clipWidth; textView.frame = f
        reanchorFillMarginTabs(toColumn: column)
        resizeTableColumns(toColumn: column)
    }

    /// Office-only (markdown/plain never carry `MDAttr.fillMarginTab`): re-anchors a paragraph's
    /// "fill to margin" tab — a Word Table of Contents entry's page number, most commonly — to
    /// THIS reading column's right edge. The source authored that tab against its own page's
    /// margin, which is unrelated to this reader's window-width column; office TABLES already
    /// track the window this way (`OfficeTextBuilder.appendTable`'s column widths are resolved
    /// against the same column), and this extends the same "fill the window" behaviour to a plain
    /// right-aligned tab stop, which has no size of its own to track anything with. Runs every
    /// time `updateTextInset` does — display, resize, sidebar toggle — so the anchor never lags
    /// the column it targets.
    ///
    /// This mutates ONLY `.paragraphStyle` on already-rendered storage — a display attribute, not
    /// a document edit — so it must never mark the document dirty. It doesn't: dirty tracking here
    /// goes through `MarkdownDocument.applySourceEdit` registering undo actions (see invariant 17
    /// in CLAUDE.md), and this path never touches the undo manager or `applySourceEdit` at all.
    ///
    /// Two passes, not one: collecting `(range, info)` first and applying after avoids mutating
    /// `.paragraphStyle` attributes while `enumerateAttribute` is still walking `.fillMarginTab`
    /// ranges over the same storage.
    private func reanchorFillMarginTabs(toColumn column: CGFloat) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        let width = max(0, column - OfficeTextBuilder.fillMarginTrailingInset)
        var targets: [(NSRange, FillMarginTabInfo)] = []
        storage.enumerateAttribute(MDAttr.fillMarginTab, in: full, options: []) { value, range, _ in
            guard let info = value as? FillMarginTabInfo else { return }
            targets.append((range, info))
        }
        guard !targets.isEmpty else { return }
        for (range, info) in targets {
            guard let base = storage.attribute(.paragraphStyle, at: range.location,
                                                effectiveRange: nil) as? NSParagraphStyle else { continue }
            let p = (base.mutableCopy() as! NSMutableParagraphStyle)
            p.tabStops = OfficeTextBuilder.fillMarginTabStops(info, width: width)
            storage.addAttribute(.paragraphStyle, value: p.copy() as! NSParagraphStyle, range: range)
        }
    }

    /// P11: re-sets every `FixedWidthTableBlock`'s RIGID, ABSOLUTE column width to
    /// `columnFraction * column` — same reasoning, same two-pass shape, same run cadence as
    /// `reanchorFillMarginTabs` immediately above (display, resize, sidebar toggle, always from
    /// `updateTextInset`). A table's columns are fixed fractions of its own width, set once at
    /// build time (`TableBlockBuilder.build`); this is what keeps that width tracking the
    /// window's, exactly the way `reanchorFillMarginTabs`'s tab stop tracks it for a right-aligned
    /// TOC entry — the table just has more than one number to re-anchor per row.
    ///
    /// Display-state only, like `reanchorFillMarginTabs`: mutates an already-rendered
    /// `FixedWidthTableBlock`'s width and reassigns `.paragraphStyle` to force the redraw, never
    /// touching the undo manager or `applySourceEdit`, so a read-only office document never goes
    /// dirty because its window was resized (invariant: office Viewers stay clean).
    ///
    /// Two passes for the same reason `reanchorFillMarginTabs` is two passes: collecting
    /// `(range, block)` first and mutating/reassigning after avoids touching `.paragraphStyle`
    /// while `enumerateAttribute` is still walking that very attribute over the same storage.
    private func resizeTableColumns(toColumn column: CGFloat) {
        guard let storage = textView.textStorage, storage.length > 0 else { return }
        let full = NSRange(location: 0, length: storage.length)
        var targets: [(NSRange, FixedWidthTableBlock)] = []
        storage.enumerateAttribute(.paragraphStyle, in: full, options: []) { value, range, _ in
            guard let ps = value as? NSParagraphStyle,
                  let block = ps.textBlocks.first as? FixedWidthTableBlock else { return }
            targets.append((range, block))
        }
        guard !targets.isEmpty else { return }
        for (range, block) in targets {
            block.setContentWidth(block.columnFraction * column, type: .absoluteValueType)
            guard let base = storage.attribute(.paragraphStyle, at: range.location,
                                                effectiveRange: nil) as? NSParagraphStyle,
                  let mutable = base.mutableCopy() as? NSMutableParagraphStyle else { continue }
            storage.addAttribute(.paragraphStyle, value: mutable.copy() as! NSParagraphStyle, range: range)
        }
    }

    // MARK: - Table of contents (⌥⌘T)

    private var isOutlineVisible = false

    /// Toggle the sidebar. Off for a document with no headings — an empty panel taking a third of
    /// the window teaches the reader that the feature is broken.
    @objc func toggleTableOfContents(_ sender: Any?) {
        guard let storage = textView.textStorage else { return }
        outline.reload(from: storage)
        guard !outline.entries.isEmpty || isOutlineVisible else { NSSound.beep(); return }
        // Freeze the text column while the sidebar slides. Every animation frame changes the split
        // view's width, and reflowing a long document at 60fps is what made the open/close feel
        // heavy — the text is simply pushed across, then laid out ONCE when the animation lands.
        let anchor = readingAnchor()
        suspendReflow = true
        splitVC.toggleSidebar(sender)
        isOutlineVisible = !sidebarItem.isCollapsed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.reflow(keeping: anchor)          // the line you were reading stays put
            self.reloadOutline()
        }
    }

    /// Rebuild the sidebar's list from the current text. Called from BOTH render paths — a spliced
    /// edit changes headings just as a full re-render does, and only the full one used to say so,
    /// which is why adding a `##` or moving a section left the list stale.
    func reloadOutline() {
        guard let storage = textView.textStorage else { return }
        outline.reload(from: storage)
        if isOutlineVisible { outline.markCurrent(charIndex: textView.selectedRange().location) }
    }

    /// Clicking a heading in the sidebar moves the READING CURSOR there, not just the scroll
    /// position. The cursor is where every block action starts from, so leaving it behind would
    /// mean the sidebar takes you to a section that `E` or `J` then doesn't act on.
    private func goToOutlineEntry(_ charIndex: Int) {
        textView.setSelectedRange(NSRange(location: charIndex, length: 0))
        scrollCharToTop(charIndex)
        window?.makeFirstResponder(textView)
    }

    // MARK: - Comments panel (P6b, ⌥⌘C)

    private var isCommentsVisible = false

    /// Toggle the right-side comments panel. Off for a document with no comments — same reasoning
    /// `toggleTableOfContents` gives for an empty outline (a panel taking a fifth of the window that
    /// teaches the reader the feature is broken).
    @objc func toggleComments(_ sender: Any?) {
        guard let doc = document as? MarkdownDocument else { return }
        reloadCommentPanel()
        guard !doc.officeComments.isEmpty || isCommentsVisible else { NSSound.beep(); return }
        // Same freeze-during-slide treatment the outline toggle uses (see its own comment): the
        // text column doesn't change width here — only the trailing inspector does — but reflow is
        // still suspended so a resize-triggered relayout can't race the split animation.
        let anchor = readingAnchor()
        suspendReflow = true
        commentsItem.animator().isCollapsed.toggle()
        isCommentsVisible = !commentsItem.isCollapsed
        textView.commentsVisible = isCommentsVisible
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.reflow(keeping: anchor)
            self.reloadCommentPanel()
        }
    }

    /// Rebuild the panel's list from the current document — called from every place that renders
    /// (both `display(_:)` and the splice-edit path), the same "both render paths" discipline
    /// `reloadOutline()` follows (invariant 23), so the panel never shows a stale list.
    func reloadCommentPanel() {
        guard let doc = document as? MarkdownDocument else { commentPanel.reload(from: []); return }
        commentPanel.reload(from: doc.officeComments)
    }

    /// Clicking a comment row scrolls the body to that comment's first anchored span — found by
    /// scanning `MDAttr.commentMark` for the matching NUMBER, the same attribute the draw pass
    /// reads. A comment the body never anchors (see `OfficeComment.number`'s doc) has no range to
    /// find; nothing happens, same as a dead cross-reference (`AnchorResolver`'s own posture).
    private func goToComment(number: Int) {
        guard let storage = textView.textStorage else { return }
        var found: Int?
        storage.enumerateAttribute(MDAttr.commentMark, in: NSRange(location: 0, length: storage.length)) { value, range, stop in
            guard let numbers = value as? [Int], numbers.contains(number) else { return }
            found = range.location
            stop.pointee = true
        }
        guard let charIndex = found else { return }
        textView.setSelectedRange(NSRange(location: charIndex, length: 0))
        scrollCharToTop(charIndex)
    }

    // MARK: Toolbar (the sidebar button)

    private func sidebarButtonView() -> NSView {
        let button = NSButton(image: NSImage(systemSymbolName: "sidebar.left",
                                             accessibilityDescription: "Table of contents")!,
                              target: self, action: #selector(toggleTableOfContents(_:)))
        button.bezelStyle = .texturedRounded
        button.isBordered = false
        button.toolTip = "Show or hide the table of contents (T)"
        button.translatesAutoresizingMaskIntoConstraints = false
        // Centred by CONSTRAINT, not by a hand-picked frame: the title bar's height isn't ours to
        // predict (it changes with the system and with tabs), and a guessed y sits a pixel or two
        // off — which is precisely what it looked like.
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 44, height: 28))
        host.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 6),
            button.widthAnchor.constraint(equalToConstant: 32),
            button.heightAnchor.constraint(equalToConstant: 22),
        ])
        return host
    }

    // MARK: R5 — read-only badge + edit-in-app button

    private func officeAccessoryView() -> NSView {
        officeBadge.font = .systemFont(ofSize: 11, weight: .semibold)
        officeBadge.textColor = .white
        officeBadge.alignment = .center
        officeBadge.wantsLayer = true
        officeBadge.layer?.backgroundColor = NSColor.systemRed.cgColor
        officeBadge.layer?.cornerRadius = 6
        officeBadge.translatesAutoresizingMaskIntoConstraints = false

        editButton.bezelStyle = .texturedRounded
        editButton.target = self
        editButton.action = #selector(editButtonClicked(_:))
        editButton.translatesAutoresizingMaskIntoConstraints = false

        editMenuButton.bezelStyle = .texturedRounded
        editMenuButton.target = self
        editMenuButton.action = #selector(showEditMenu(_:))
        editMenuButton.translatesAutoresizingMaskIntoConstraints = false

        let host = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 28))
        host.isHidden = true   // shown only once `updateOfficeAccessory` sees an office document
        host.addSubview(officeBadge)
        host.addSubview(editButton)
        host.addSubview(editMenuButton)
        NSLayoutConstraint.activate([
            officeBadge.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 6),
            officeBadge.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            officeBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 62),
            officeBadge.heightAnchor.constraint(equalToConstant: 18),

            editButton.leadingAnchor.constraint(equalTo: officeBadge.trailingAnchor, constant: 8),
            editButton.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            editButton.heightAnchor.constraint(equalToConstant: 22),

            editMenuButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 2),
            editMenuButton.centerYAnchor.constraint(equalTo: host.centerYAnchor),
            editMenuButton.widthAnchor.constraint(equalToConstant: 20),
            editMenuButton.heightAnchor.constraint(equalToConstant: 22),
            editMenuButton.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -6),
        ])
        officeAccessoryHost = host
        return host
    }

    /// Called from every render pass (`display(_:)`), same as `reloadOutline()` — the badge/button
    /// must reflect the CURRENT document, not whatever was open when the window was built.
    private func updateOfficeAccessory() {
        guard let doc = document as? MarkdownDocument, doc.kind == .office else {
            officeAccessoryHost.isHidden = true
            return
        }
        officeAccessoryHost.isHidden = false
        let ext = doc.fileURL?.pathExtension.lowercased() ?? ""
        editButton.title = ExternalEditor.editLabel(for: externalEditorService.rememberedCandidate(forExtension: ext))
    }

    /// Body click (S7-6/S7-7): open directly if an app is remembered; otherwise there is nothing to
    /// launch yet, so fall through to the same picker the arrow shows.
    @objc private func editButtonClicked(_ sender: Any?) {
        guard let (doc, ext) = officeDocumentContext() else { return }
        if let app = externalEditorService.rememberedCandidate(forExtension: ext) {
            openExternally(doc, with: app)
        } else {
            presentEditMenu(forExtension: ext, anchor: editButton)
        }
    }

    @objc private func showEditMenu(_ sender: Any?) {
        guard let (_, ext) = officeDocumentContext() else { return }
        presentEditMenu(forExtension: ext, anchor: editMenuButton)
    }

    private func officeDocumentContext() -> (MarkdownDocument, String)? {
        guard let doc = document as? MarkdownDocument, doc.kind == .office,
              let url = doc.fileURL else { return nil }
        return (doc, url.pathExtension.lowercased())
    }

    /// The arrow's menu: every candidate app (S7-3 already excludes us), a checkmark on whichever
    /// one is currently remembered, then `Choose other app…`.
    private func presentEditMenu(forExtension ext: String, anchor: NSView) {
        let remembered = externalEditorService.rememberedCandidate(forExtension: ext)
        let menu = NSMenu()
        for app in externalEditorService.candidates(forExtension: ext) {
            let item = NSMenuItem(title: app.displayName,
                                  action: #selector(chooseCandidateFromMenu(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = app
            item.state = (app.bundleIdentifier == remembered?.bundleIdentifier) ? .on : .off
            menu.addItem(item)
        }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        let other = NSMenuItem(title: "Choose Other App…",
                               action: #selector(chooseOtherApp(_:)), keyEquivalent: "")
        other.target = self
        menu.addItem(other)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: anchor.bounds.height + 4), in: anchor)
    }

    @objc private func chooseCandidateFromMenu(_ sender: NSMenuItem) {
        guard let app = sender.representedObject as? ExternalEditor.AppCandidate,
              let (doc, ext) = officeDocumentContext() else { return }
        externalEditorService.remember(app, forExtension: ext)
        editButton.title = ExternalEditor.editLabel(for: app)
        openExternally(doc, with: app)
    }

    /// S7-6: `Choose other app…` — an `NSOpenPanel` restricted to `/Applications`. The user's own
    /// selection grants access to that app regardless of what the sandbox otherwise allows.
    @objc private func chooseOtherApp(_ sender: Any?) {
        guard let (doc, ext) = officeDocumentContext() else { return }
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        guard panel.runModal() == .OK, let appURL = panel.url,
              let app = externalEditorService.appCandidate(from: appURL) else { return }
        externalEditorService.remember(app, forExtension: ext)
        editButton.title = ExternalEditor.editLabel(for: app)
        openExternally(doc, with: app)
    }

    /// S7-8/S7-9: hand the document to the chosen app. The sandbox hand-off itself was NOT
    /// verified here — see the sprint report — so a failure surfaces as an alert rather than
    /// being swallowed.
    private func openExternally(_ doc: MarkdownDocument, with app: ExternalEditor.AppCandidate) {
        guard let url = doc.fileURL else { return }
        externalEditorService.open(url, with: app) { [weak self] error in
            guard let error, let window = self?.window else { return }
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Couldn't open \(app.displayName)"
            a.informativeText = error.localizedDescription
            a.beginSheetModal(for: window)
        }
    }

    /// Grey the menu item out where a table of contents would be empty, rather than opening an empty
    /// panel and leaving the reader to work out why.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(toggleTableOfContents(_:)) {
            item.title = isOutlineVisible ? "Hide Table of Contents" : "Table of Contents"
            return canShowTableOfContents
        }
        if item.action == #selector(toggleComments(_:)) {
            item.title = isCommentsVisible ? "Hide Comments" : "Comments"
            return canShowComments
        }
        return true
    }

    /// Enabled only where the panel means something: an office document that actually has
    /// comments. (Once open it stays enabled/toggle-able even if a later reload finds zero — same
    /// posture `guard !doc.officeComments.isEmpty || isCommentsVisible` already takes in the toggle
    /// itself, so the menu and the action never disagree about whether closing is allowed.)
    var canShowComments: Bool {
        guard let doc = document as? MarkdownDocument else { return false }
        return !doc.officeComments.isEmpty || isCommentsVisible
    }

    /// Enabled only where a table of contents means something: markdown, with headings in it.
    var canShowTableOfContents: Bool {
        guard let doc = document as? MarkdownDocument, !doc.isPlainText,
              let storage = textView.textStorage else { return false }
        var any = false
        storage.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: storage.length)) { v, _, stop in
            if v != nil { any = true; stop.pointee = true }
        }
        return any
    }

    /// Keep the sidebar's highlight on the section the CURSOR is in — not the one that happens to
    /// be scrolled into view. The cursor is what the reader placed deliberately and what every
    /// block action works from, so the two halves of the window agree about where "here" is.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard isOutlineVisible else { return }
        outline.markCurrent(charIndex: textView.selectedRange().location)
    }

    func display(_ attributed: NSAttributedString) {
        updateTextInset()
        textView.textStorage?.setAttributedString(attributed)
        textView.recomputeHeadingOffsets()
        reloadOutline()
        reloadCommentPanel()
        updateOfficeAccessory()
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

    /// What the reader is looking at, as a character plus where on screen it sat. Restoring BOTH is
    /// what makes a reflow invisible: keeping only the character would jump that line to the top of
    /// the window, and keeping only the offset would land on different text once the wrapping
    /// changed.
    struct ReadingAnchor {
        let char: Int
        /// Distance from the top of the viewport to that line, in points.
        let offsetFromTop: CGFloat
    }

    /// The cursor if it is on screen, otherwise whatever sits at the middle of the viewport.
    ///
    /// The cursor wins because it is the one place the reader put deliberately — it is where every
    /// block action happens, and watching it slide away while the window resizes is the thing that
    /// feels wrong. With no cursor in sight the centre of the page is the honest stand-in: anchoring
    /// on the top line lets everything below it drift, which is most of what you are reading.
    func readingAnchor() -> ReadingAnchor {
        guard let lm = textView.layoutManager, let tc = textView.textContainer,
              let storage = textView.textStorage, storage.length > 0, lm.numberOfGlyphs > 0 else {
            return ReadingAnchor(char: 0, offsetFromTop: 0)
        }
        let visible = textView.visibleRect
        let inset = textView.textContainerInset
        func lineTop(_ char: Int) -> CGFloat {
            let glyph = min(lm.glyphIndexForCharacter(at: char), lm.numberOfGlyphs - 1)
            return lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY + inset.height
        }
        // Two cases, two meanings. The CURSOR is an exact spot the reader put there, so it anchors
        // on its own line and comes back to the same height. With no cursor in view there is no such
        // spot: take whatever character sits dead centre of the page and put it back dead centre.
        // Centre is the right target because a reflow changes how much fits above and below — hold
        // the middle and the drift is split evenly instead of piling up on one side.
        let caret = min(textView.selectedRange().location, storage.length - 1)
        let caretTop = lineTop(caret)
        if caretTop >= visible.minY, caretTop <= visible.maxY {
            return ReadingAnchor(char: caret, offsetFromTop: caretTop - visible.minY)
        }
        let centrePoint = NSPoint(x: tc.size.width / 2, y: visible.midY - inset.height)
        let centre = min(lm.characterIndexForGlyph(at: lm.glyphIndex(for: centrePoint, in: tc)),
                         storage.length - 1)
        return ReadingAnchor(char: centre, offsetFromTop: visible.height / 2)
    }

    /// Put an anchor back where it was on screen.
    func restore(_ anchor: ReadingAnchor) {
        guard let lm = textView.layoutManager, let storage = textView.textStorage,
              lm.numberOfGlyphs > 0 else { return }
        let char = min(max(0, anchor.char), max(0, storage.length - 1))
        let glyph = min(lm.glyphIndexForCharacter(at: char), lm.numberOfGlyphs - 1)
        let lineTop = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            + textView.textContainerInset.height
        var y = lineTop - anchor.offsetFromTop
        if y <= textView.textContainerInset.height { y = 0 }   // keep the page's top margin
        let clip = scrollView.contentView
        let maxY = max(0, textView.bounds.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
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
        var targetY = rect.origin.y - CGFloat(lineOffset) * rect.height
        // The first line is a special case: putting it flush with the top edge scrolls the page's
        // top margin out of sight, so the document looks like it lost its padding. Nothing above it
        // needs the room, so go to the very top instead.
        if targetY <= textView.textContainerInset.height { targetY = 0 }
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
        let codeLH = (overlayTheme.codeFont.pointSize * overlayTheme.codeLineHeightRatio).rounded()
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
        // In-document anchor (a markdown TOC entry, or an office cross-reference/bookmark link) —
        // resolved against bookmark markers first, then heading slugs (`AnchorResolver`). This MUST
        // be checked, and must return, before the raw-URL/file-path branches below: an office
        // bookmark link carries no `.link` scheme AppKit can route on its own (see
        // `OfficeTextBuilder`'s `#`-prefixed-link handling), so falling through here is exactly the
        // defect this branch exists to prevent — a bare `#BookmarkName` misread as a relative file
        // path and handed to `openFile`.
        if let target = tv.textStorage?.attribute(MDAttr.anchor, at: charIndex, effectiveRange: nil) as? String {
            jumpToAnchor(target: target); return true
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

    /// Resolve an in-document anchor's raw target and scroll there (top-anchored) — same reveal
    /// path `goToOutlineEntry` uses, so a bookmark/cross-reference jump feels identical to clicking
    /// the sidebar. The matching itself is `AnchorResolver`'s pure decision (bookmark exact match,
    /// then GFM heading-slug match); this function's only job is gathering the two candidate sets
    /// from the live text storage and acting on the result. A target that resolves to nothing does
    /// NOTHING VISIBLE — a link to a deleted bookmark/heading is common in real documents and is
    /// not an error a reader should announce (no beep, no guess).
    private func jumpToAnchor(target: String) {
        guard let storage = textView.textStorage else { return }
        var bookmarks: [String: Int] = [:]
        storage.enumerateAttribute(MDAttr.bookmarkTarget, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let names = v as? [String] else { return }
            for name in names { bookmarks[name] = r.location }
        }
        var headings: [(text: String, position: Int)] = []
        storage.enumerateAttribute(MDAttr.heading, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard v != nil else { return }
            headings.append((text: (storage.string as NSString).substring(with: r), position: r.location))
        }
        guard let found = AnchorResolver.resolve(target: target, bookmarks: bookmarks, headings: headings) else { return }
        textView.setSelectedRange(NSRange(location: found, length: 0))
        scrollCharToTop(found)
    }

    /// ⌘-click on a selection: open whatever was highlighted, even without an http prefix.
    /// Tries, in order: an explicit URL scheme → a resolvable file path → a bare web domain.
    /// Right-click → Edit: open the markdown SOURCE of the block(s) the selection touches in a
    /// popup; on save, replace just that source span and re-render (Notion-style block editing).
    func editSelectedSource(atChar: Int? = nil) {
        guard let storage = textView.textStorage, let doc = document as? MarkdownDocument else { return }
        // An office document has no editable source (see `isOfficeDocument`/CLAUDE.md invariant
        // 22) — refuse explicitly rather than rely on the srcRange scan below coming up empty.
        guard doc.kind != .office else { NSSound.beep(); return }
        // Nothing to edit yet — treat Edit on an empty document as writing its first block, rather
        // than beeping at someone who is trying to start.
        guard storage.length > 0 else { addBlockBelow(atChar: nil); return }
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
        SourceEditPanel.show(title: "Edit block source", markdown: doc.sourceSubstring(srcRange)) { [weak doc] edited in
            doc?.applySourceEdit(srcRange, with: edited)
        }
    }

    // MARK: - Block operations (add / delete / move)
    //
    // All three resolve the block under the pointer to ONE source span pair and hand it to
    // `applySourceEdit` — the single write path — so each is persisted, re-rendered and undoable
    // exactly like a hand edit, and none of them can half-apply.

    /// The block spans of the current document plus the index of the one at `char`.
    private func blockContext(atChar char: Int?) -> (doc: MarkdownDocument, spans: [NSRange], index: Int)? {
        guard let storage = textView.textStorage, let doc = document as? MarkdownDocument,
              storage.length > 0 else { return nil }
        let anchor = min(max(0, char ?? textView.selectedRange().location), storage.length - 1)
        guard let value = storage.attribute(MDAttr.srcRange, at: anchor, effectiveRange: nil) as? NSValue
        else { return nil }
        let spans = BlockEdit.spans(in: storage)
        guard let i = BlockEdit.indexOfBlock(containing: value.rangeValue.location, in: spans) else { return nil }
        return (doc, spans, i)
    }

    /// Right-click → Add Block Below: an empty edit popup; on save the text is inserted after the
    /// clicked block, reusing that document's own separator (blank line in markdown, single
    /// newline in a plain text file).
    func addBlockBelow(atChar char: Int?) {
        guard let doc = document as? MarkdownDocument else { NSSound.beep(); return }
        // An office document has no editable source (see `isOfficeDocument`/CLAUDE.md invariant
        // 22). This guard must come BEFORE the "empty document" branch below: an office document's
        // `text` is always "" and carries no `srcRange`, so `blockContext` is always nil for it —
        // which the branch below would otherwise read as "empty document, start typing" and
        // overwrite `doc.text` (harmlessly empty here, but dirtying the document over content the
        // reader never touched — the real bug this sprint's audit found).
        guard doc.kind != .office else { NSSound.beep(); return }
        // An EMPTY document has no blocks to add below, and without this it had no way in at all:
        // every editing route resolves a block first, so a new tab was a document you could never
        // put anything into. Here the first block simply becomes the document. Tested directly on
        // `doc.text`, NOT on `blockContext == nil` — a nil block context means "no srcRange at this
        // anchor", which is not the same claim as "the document is empty" (see the guard above).
        if doc.text.isEmpty {
            SourceEditPanel.show(title: doc.isPlainText ? "New line" : "New block", markdown: "") { added in
                guard !added.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                let whole = NSRange(location: 0, length: (doc.text as NSString).length)
                doc.applySourceEdit(whole, with: added, actionName: "Add")
            }
            return
        }
        guard let ctx = blockContext(atChar: char) else { NSSound.beep(); return }
        // A text file gets exactly one new line; a markdown file keeps its own paragraph spacing.
        let fixed = ctx.doc.isPlainText ? ctx.doc.lineEnding : nil
        let title = ctx.doc.isPlainText ? "New line" : "New block"
        SourceEditPanel.show(title: title, markdown: "") { [weak self] added in
            guard let self, !added.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            // Spans are recomputed at save time: the popup is modeless, so the document may have
            // changed (another edit, a reload) while it was open.
            guard let ctx = self.blockContext(atChar: char),
                  let (r, replacement) = BlockEdit.insertion(after: ctx.index, spans: ctx.spans,
                                                             text: ctx.doc.text as NSString,
                                                             newSource: added,
                                                             fallbackSeparator: fixed ?? "\n\n",
                                                             fixedSeparator: fixed)
            else { NSSound.beep(); return }
            ctx.doc.applySourceEdit(r, with: replacement, actionName: "Add Block")
        }
    }

    /// The run of blocks a delete should take: everything the SELECTION touches, or — with no
    /// selection — just the block under the pointer. Deleting one block at a time when several are
    /// highlighted would ignore what the user plainly indicated.
    private func blockRunToDelete(atChar char: Int?) -> (doc: MarkdownDocument, spans: [NSRange],
                                                         first: Int, last: Int)? {
        guard let ctx = blockContext(atChar: char), let storage = textView.textStorage else { return nil }
        let sel = textView.selectedRange()
        guard sel.length > 0 else { return (ctx.doc, ctx.spans, ctx.index, ctx.index) }
        var lo = Int.max, hi = Int.min
        storage.enumerateAttribute(MDAttr.srcRange, in: sel) { v, _, _ in
            guard let s = (v as? NSValue)?.rangeValue,
                  let i = BlockEdit.indexOfBlock(containing: s.location, in: ctx.spans) else { return }
            lo = min(lo, i); hi = max(hi, i)
        }
        guard lo != Int.max else { return (ctx.doc, ctx.spans, ctx.index, ctx.index) }
        return (ctx.doc, ctx.spans, lo, hi)
    }

    /// Right-click → Delete: confirm first (this rewrites the file on disk), showing what is about
    /// to go so the user can tell they picked the right thing.
    func deleteBlock(atChar char: Int?) {
        guard let run = blockRunToDelete(atChar: char),
              BlockEdit.deletion(from: run.first, through: run.last, spans: run.spans) != nil
        else { NSSound.beep(); return }
        let count = run.last - run.first + 1
        let noun = (run.doc.isPlainText ? "line" : "block") + (count == 1 ? "" : "s")
        let source = run.doc.sourceSubstring(run.spans[run.first])
        let firstLine = source.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? source
        var preview = firstLine.count > 80 ? String(firstLine.prefix(80)) + "…" : firstLine
        if count > 1 { preview += "\n… through …\n" + run.doc.sourceSubstring(run.spans[run.last]).prefix(80) }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = count == 1 ? "Delete this \(noun)?" : "Delete these \(count) \(noun)?"
        alert.informativeText = "\(preview)\n\nThis rewrites \(run.doc.fileURL?.lastPathComponent ?? "the file") on disk. You can undo it with ⌘Z."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        // The sheet is asynchronous, so re-resolve when the user actually confirms — an undo or a
        // ⌘R reload while it was up would have moved every offset under it.
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .alertFirstButtonReturn, let self,
                  let run = self.blockRunToDelete(atChar: char),
                  let r = BlockEdit.deletion(from: run.first, through: run.last, spans: run.spans)
            else { return }
            run.doc.applySourceEdit(r, with: "", actionName: "Delete")
        }
        if let w = window { alert.beginSheetModal(for: w, completionHandler: apply) }
        else { apply(alert.runModal()) }
    }

    /// Put the reading cursor on the block an edit touched, and bring it on screen if it isn't
    /// already. This matters most for undo/redo: the change can be anywhere in the document, and a
    /// reader who presses ⌘Z and sees nothing move can't tell whether it did anything.
    ///
    /// Only scrolls when the block is NOT fully visible — undoing an edit you're looking at should
    /// leave the page exactly where it is.
    func revealEditedSource(_ span: NSRange, highlight: Bool) {
        guard let storage = textView.textStorage, storage.length > 0,
              let lm = textView.layoutManager, let container = textView.textContainer else { return }
        let probe = NSRange(location: span.location, length: max(span.length, 1))
        var lo = Int.max, hi = Int.min
        var fallback: Int?
        storage.enumerateAttribute(MDAttr.srcRange, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let s = (v as? NSValue)?.rangeValue else { return }
            if s.location < probe.location + probe.length, s.location + s.length > probe.location {
                lo = min(lo, r.location); hi = max(hi, r.location + r.length)
            } else if fallback == nil, s.location >= probe.location + probe.length {
                fallback = r.location          // the block that moved up into a deleted one's place
            }
        }
        let target: NSRange
        if lo != Int.max, hi > lo { target = NSRange(location: lo, length: hi - lo) }
        else if let f = fallback { target = NSRange(location: f, length: 0) }
        else { target = NSRange(location: min(span.location, storage.length), length: 0) }

        textView.setSelectedRange(highlight ? target : NSRange(location: target.location, length: 0))
        let glyphs = lm.glyphRange(forCharacterRange: target, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        if !textView.visibleRect.contains(rect) {
            // Leave a little air above it rather than pinning it to the very top edge.
            textView.scrollRangeToVisible(target)
            let clip = scrollView.contentView
            let y = max(0, rect.minY - clip.bounds.height / 4)
            if rect.height < clip.bounds.height {
                clip.scroll(to: NSPoint(x: 0, y: min(y, max(0, textView.bounds.height - clip.bounds.height))))
                scrollView.reflectScrolledClipView(clip)
            }
        }
        placeCopyButtons()
    }

    /// Move the block under the reading cursor one step, without entering move mode — the `u`/`j`
    /// keys.
    ///
    /// Selecting ONLY the block that moved is what makes repeated presses work, not just tidier
    /// highlighting. A swap edits two blocks, so the generic post-edit reveal selects both and
    /// leaves the cursor at the start — which for a downward move is the OTHER block, so the next
    /// press picks that one up and swaps the pair straight back. (`u` appeared fine only because
    /// there the moved block happens to end up first.) Landing the cursor on the moved block walks
    /// it as far as you keep pressing.
    func moveBlockUnderCaret(by delta: Int) {
        guard let storage = textView.textStorage, let doc = document as? MarkdownDocument,
              let ctx = blockContext(atChar: textView.selectedRange().location) else { NSSound.beep(); return }
        let spans = BlockEdit.spans(in: storage)
        let first = delta < 0 ? ctx.index - 1 : ctx.index
        guard let (r, replacement) = BlockEdit.swapWithNext(first, spans: spans, text: doc.text as NSString)
        else { NSSound.beep(); return }              // already at the end it's moving toward
        doc.applySourceEdit(r, with: replacement, actionName: "Move")
        selectBlock(at: ctx.index + delta)
    }

    /// Select one block by index and bring it on screen if it isn't already.
    @discardableResult
    func selectBlock(at index: Int) -> Bool {
        guard let storage = textView.textStorage,
              let r = renderedRange(ofBlockAt: index, in: storage) else { return false }
        textView.setSelectedRange(r)
        revealIfOffscreen(r)
        placeCopyButtons()
        return true
    }

    /// The rendered range of the block at `index` — the one place that answers "where on screen is
    /// this block?", so the post-edit reveal and the key moves can't drift apart.
    private func renderedRange(ofBlockAt index: Int, in storage: NSTextStorage,
                               spans precomputed: [NSRange]? = nil) -> NSRange? {
        let spans = precomputed ?? BlockEdit.spans(in: storage)
        guard spans.indices.contains(index) else { return nil }
        let target = spans[index]
        var lo = Int.max, hi = Int.min
        storage.enumerateAttribute(MDAttr.srcRange, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let s = (v as? NSValue)?.rangeValue, s.location == target.location, s.length == target.length
            else { return }
            lo = min(lo, r.location); hi = max(hi, r.location + r.length)
        }
        guard lo != Int.max, hi > lo else { return nil }
        return NSRange(location: lo, length: hi - lo)
    }

    /// Scroll a range into view ONLY if it isn't fully visible — moving a block you're looking at
    /// shouldn't shift the page under you.
    private func revealIfOffscreen(_ r: NSRange) {
        guard let lm = textView.layoutManager, let container = textView.textContainer else { return }
        let glyphs = lm.glyphRange(forCharacterRange: r, actualCharacterRange: nil)
        var rect = lm.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerInset.width
        rect.origin.y += textView.textContainerInset.height
        guard !textView.visibleRect.contains(rect) else { return }
        textView.scrollRangeToVisible(r)
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
        } else if DocumentTypes.opensInApp(ext) {
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
        row("E · I · D", "Edit · Insert below · Delete — the block at the reading cursor")
        row("U · J", "Move that block up · down (⌘Z undoes each step)")
        row("Right-click a block", "The same four, on the block under the pointer")
        row("⌘S", "Save — edits stay in memory until you do")
        row("T", "Table of contents (Markdown with headings) — click a heading to jump")
        row("⌘N", "New file — asks for Markdown or plain text")
        row("Click a diagram / formula / image", "Open it enlarged in a zoomable window")
        row("Wrap / Copy button", "Toggle a code block's wrapping / copy its code")
        section("Diagram window")
        row("Pinch  or  ⌘+ / ⌘−", "Zoom in / out");  row("⌘0", "Fit to window")
        row("Drag", "Move around (pan)");  row("esc", "Close the zoom window")
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

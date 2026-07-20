import AppKit
import ImageIO

final class MarkdownDocument: NSDocument {
    private(set) var text: String = ""

    // C3: bumped on every full render; async mermaid swaps from a previous render carry
    // a stale generation and abort before mutating, so only the latest render wins.
    private var renderGeneration = 0

    // While the up-front measure pass is rendering uncached diagrams, their exact size isn't known
    // yet — reconcileMedia must NOT load them (that would resize under the reader). Cleared once the
    // pass finishes and every diagram has been sized. `prerenderToken` cancels a stale pass when a
    // new render starts.
    private var isPrerendering = false
    private var prerenderToken = 0

    // Same idea for remote images: until their header has been fetched their size is a guess, so
    // reconcileMedia must not fill them mid-pass (the pixels would arrive and resize the layout).
    private var isMeasuringRemote = false
    private var measureToken = 0

    override class var autosavesInPlace: Bool { false }
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { false }

    /// Saving is ⌘S, not every edit. Writing on each keystroke-sized change meant rewriting the
    /// whole file for one moved line — and, worse, it left no way back: the file on disk had
    /// already changed before the reader decided they liked it. Edits now live in memory, the
    /// document goes dirty, and AppKit's own "Save / Don't Save / Cancel" sheet handles closing.
    /// Change tracking is left to NSDocument, which watches the undo manager — undo back to the
    /// original state correctly reports the document as clean again.
    override func data(ofType typeName: String) throws -> Data {
        guard let bytes = TextEncodingDetector.encode(text, like: file) else {
            throw NSError(domain: "ai.ww-w.fast-md-reader", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "This file's text encoding can't represent some of the characters in your edits.",
                NSLocalizedRecoverySuggestionErrorKey:
                    "\(fileURL?.lastPathComponent ?? "The file") is stored in an older encoding. Remove those characters, or convert the file to UTF-8 in another editor, and save again.",
            ])
        }
        return bytes
    }

    /// How this file was stored, kept so a save writes it back the same way (see TextFile). Set on
    /// every read; the default only matters for a document that was never read from disk.
    private(set) var file = TextFile(text: "", encoding: .utf8, hasBOM: false)

    override func read(from data: Data, ofType typeName: String) throws {
        // NOT `String(decoding:as: UTF8.self)`: that never fails, it just substitutes replacement
        // characters, so a Windows-made CP949 or UTF-16 file arrives as a wall of "?" and looks
        // corrupted. The detector reads the bytes for what they are.
        self.file = TextEncodingDetector.decode(data)
        self.text = file.text
    }

    override func makeWindowControllers() {
        let wc = DocumentWindowController()
        addWindowController(wc)
        wc.window?.setFrameAutosaveName("FastMDReaderDoc")
        // Record the file in Open Recent. Auto-recording wasn't firing for our open paths, so note
        // it explicitly (idempotent — the controller de-dupes).
        if let url = fileURL { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
        render(into: wc)
    }

    // MARK: - Font size (menu actions routed through the responder chain)

    /// ⌘R: re-read the file from disk and re-render, keeping the scroll position. Note this
    /// reloads the DOCUMENT's content — it runs the currently-launched app binary, so it does
    /// not pick up a new app build (that still needs a relaunch).
    @objc func reloadDocument(_ sender: Any?) {
        // Re-reading throws away whatever hasn't been saved, so say so first. Silently discarding
        // edits because someone reached for Reload would be the worst kind of data loss: invisible.
        if isDocumentEdited {
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = "Reload and lose your unsaved changes?"
            a.informativeText = "\(fileURL?.lastPathComponent ?? "This document") has edits that haven't been saved. Reloading reads the file from disk again and discards them."
            a.addButton(withTitle: "Reload")
            a.addButton(withTitle: "Cancel")
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        if let url = fileURL, let data = try? Data(contentsOf: url) {
            let reread = TextEncodingDetector.decode(data)
            // The undo stack holds source OFFSETS into the text we're replacing. Re-reading the file
            // can move every one of them (the file may have changed behind us), so an undo applied
            // afterwards would overwrite the wrong span. Drop the history rather than corrupt the file.
            // Compared as TEXT, not bytes: re-encoding is not a change the user made.
            if reread.text != self.text { undoManager?.removeAllActions() }
            self.file = reread
            self.text = reread.text
            updateChangeCount(.changeCleared)     // the document now matches the file again
        }
        guard let wc = windowControllers.first as? DocumentWindowController else { return }
        let anchor = wc.topVisibleCharIndex()
        render(into: wc)
        wc.scrollCharToTop(anchor)
    }

    // MARK: - Block-level source editing (right-click a selection → Edit)

    /// The markdown source substring for a block's source range (UTF-16).
    func sourceSubstring(_ r: NSRange) -> String {
        let ns = text as NSString
        guard r.location >= 0, r.location + r.length <= ns.length else { return "" }
        return ns.substring(with: r)
    }

    /// Replace a source range with edited markdown and update the screen. Nothing is written to
    /// disk — that is ⌘S (see `data(ofType:)`); this marks the document dirty instead.
    ///
    /// Undo runs back through here with the inverse edit, so it re-renders exactly like a typed one,
    /// and redo falls out for free: the undo manager records the inverse this call registers while
    /// it is undoing.
    func applySourceEdit(_ r: NSRange, with replacement: String, actionName: String = "Edit") {
        let ns = text as NSString
        guard r.location >= 0, r.location + r.length <= ns.length else { NSSound.beep(); return }
        let updated = ns.replacingCharacters(in: r, with: replacement)
        let previous = ns.substring(with: r)
        self.text = updated
        self.file.text = updated          // keep the two in step; `file` also carries the encoding
        let undoRange = NSRange(location: r.location, length: (replacement as NSString).length)
        undoManager?.registerUndo(withTarget: self) {
            $0.applySourceEdit(undoRange, with: previous, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
        guard let wc = windowControllers.first as? DocumentWindowController else { return }
        // Re-rendering the WHOLE document for one changed block is what made long files crawl:
        // measured at 92ms in `display` alone for a 64k-character file, and it grows with the file,
        // so undo/redo of a small edit paid the price of the entire document. Splice the changed
        // blocks in instead, and fall back to the full path only when that can't be trusted.
        let newSpan = NSRange(location: r.location, length: (replacement as NSString).length)
        if spliceRender(into: wc, editedSource: r, replacementLength: newSpan.length) {
            wc.revealEditedSource(newSpan, highlight: newSpan.length > 0)
            return
        }
        let anchor = wc.topVisibleCharIndex()
        render(into: wc)
        wc.scrollCharToTop(anchor)
        wc.revealEditedSource(newSpan, highlight: newSpan.length > 0)
    }

    // MARK: - Incremental (spliced) re-render

    /// Block ids must stay unique across a splice: two neighbouring blocks that share an id read as
    /// ONE block to the reading cursor and the gutter. A fresh fragment numbers its blocks from
    /// zero, so each splice lifts them clear of every id already on screen.
    private var blockIdBase = 1_000_000

    /// Redraw ONLY the blocks an edit touched.
    ///
    /// Safe because a block renders the same alone as it does in context — verified per block kind
    /// in FragmentRenderTests — with one documented exception: a reference-style link resolves
    /// against a definition elsewhere in the file, so such documents take the full path.
    ///
    /// Returns false when it cannot do the job, and the caller re-renders everything. Refusing is
    /// always correct here; guessing is not.
    private func spliceRender(into wc: DocumentWindowController, editedSource r: NSRange,
                              replacementLength: Int) -> Bool {
        guard let storage = wc.textStorageRef, storage.length > 0 else { return false }
        if !isPlainText && hasCrossBlockReferences { return false }

        let spans = BlockEdit.spans(in: storage)          // spans of the text BEFORE this edit
        guard let first = BlockEdit.indexOfBlock(containing: r.location, in: spans) else { return false }
        // Grow the run until it covers the whole edited range: a delete reaches past its block into
        // the separator and on into the next one, and the fragment must span all of it.
        var last = first
        let editEnd = r.location + r.length
        while last + 1 < spans.count, spans[last].location + spans[last].length < editEnd { last += 1 }
        let oldStart = spans[first].location
        let oldEnd = spans[last].location + spans[last].length
        guard oldStart <= r.location, oldEnd >= editEnd else { return false }   // edit spills outside the blocks

        let delta = replacementLength - r.length
        let ns = text as NSString
        // Run the fragment up to where the NEXT block starts, not just to the last block's text.
        // A block's rendered range includes the separator that follows it (in a text file that is
        // the newline the blank line itself is made of), so a fragment that stopped at the text
        // would splice that separator away.
        // (`spans` are offsets into the text BEFORE the edit; `ns` is the text after, so the old
        // length is recovered from the delta rather than kept around.)
        let oldTextLength = ns.length - delta
        let oldFragmentEnd = last + 1 < spans.count ? spans[last + 1].location : oldTextLength
        let newLength = (oldFragmentEnd - oldStart) + delta
        guard newLength >= 0, oldStart + newLength <= ns.length else { return false }

        // The rendered range these blocks occupy must be one contiguous run to be replaceable.
        guard let rendered = renderedRange(ofSourceSpans: spans[first...last], in: storage) else { return false }

        let theme = RenderTheme.current(size: FontSizeStore.size)
        let fragmentSource = ns.substring(with: NSRange(location: oldStart, length: newLength))
        let fragment = NSMutableAttributedString(attributedString:
            isPlainText ? PlainTextRenderer.render(fragmentSource, theme: theme)
                        : MarkdownRenderer.render(fragmentSource, theme: theme))
        // A fragment is rendered from position zero, so its source offsets and block ids are local.
        // Lift both into the document's coordinates before it goes in.
        rebase(fragment, sourceOffset: oldStart, idBase: blockIdBase)
        blockIdBase += 100_000

        let tail = NSRange(location: rendered.location + rendered.length,
                           length: storage.length - (rendered.location + rendered.length))
        storage.beginEditing()
        storage.replaceCharacters(in: rendered, with: fragment)
        // Everything after the splice keeps its rendered text but now sits at a different place in
        // the FILE, so its recorded source offsets move by the same delta the edit made.
        if delta != 0, tail.length > 0 {
            let shifted = NSRange(location: rendered.location + fragment.length,
                                  length: storage.length - (rendered.location + fragment.length))
            storage.enumerateAttribute(MDAttr.srcRange, in: shifted) { value, range, _ in
                guard let s = (value as? NSValue)?.rangeValue else { return }
                storage.addAttribute(MDAttr.srcRange,
                                     value: NSValue(range: NSRange(location: s.location + delta, length: s.length)),
                                     range: range)
            }
        }
        storage.endEditing()

        renderGeneration += 1
        wc.refreshAfterMutation()
        // Media inside the new fragment still needs its exact area reserved before it can draw —
        // same rule as a full render (invariant: size first, pixels later).
        DispatchQueue.main.async { [weak self, weak wc] in
            guard let self, let wc else { return }
            self.presizeKnownMedia(in: wc)
            self.reconcileMedia(in: wc)
            self.prerenderAllDiagrams(in: wc)
            self.measureRemoteImages(in: wc)
        }
        return true
    }

    /// The single contiguous rendered range covering a run of source spans, or nil if the run isn't
    /// contiguous on screen (which would make a splice cut into something it shouldn't).
    private func renderedRange(ofSourceSpans wanted: ArraySlice<NSRange>,
                               in storage: NSTextStorage) -> NSRange? {
        let targets = Set(wanted.map { NSRange(location: $0.location, length: $0.length) }.map(NSStringFromRange))
        var lo = Int.max, hi = Int.min
        storage.enumerateAttribute(MDAttr.srcRange, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            guard let s = (v as? NSValue)?.rangeValue, targets.contains(NSStringFromRange(s)) else { return }
            lo = min(lo, r.location); hi = max(hi, r.location + r.length)
        }
        guard lo != Int.max, hi > lo else { return nil }
        return NSRange(location: lo, length: hi - lo)
    }

    private func rebase(_ fragment: NSMutableAttributedString, sourceOffset: Int, idBase: Int) {
        let whole = NSRange(location: 0, length: fragment.length)
        fragment.enumerateAttribute(MDAttr.srcRange, in: whole) { value, range, _ in
            guard let s = (value as? NSValue)?.rangeValue else { return }
            fragment.addAttribute(MDAttr.srcRange,
                                  value: NSValue(range: NSRange(location: s.location + sourceOffset, length: s.length)),
                                  range: range)
        }
        fragment.enumerateAttribute(MDAttr.blockId, in: whole) { value, range, _ in
            guard let id = value as? Int else { return }
            fragment.addAttribute(MDAttr.blockId, value: idBase + id, range: range)
        }
    }

    /// True when the document has link/footnote definitions, which a single block can refer to from
    /// anywhere — the one case where a block does NOT render the same on its own.
    private var hasCrossBlockReferences: Bool {
        text.split(separator: "\n", omittingEmptySubsequences: true).contains { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("[") && t.contains("]:")
        }
    }

    // MARK: - Undo / Redo (⌘Z, ⇧⌘Z)

    /// Own selectors rather than the standard `undo:`/`redo:`: the menu bar is built in code, so
    /// nothing wires those up for us, and this app's responder chain already reaches the document
    /// this way (see `reloadDocument:`). SourceEditPanel answers the same two selectors for its own
    /// typing, so one pair of menu items serves both windows.
    @objc func undoSourceEdit(_ sender: Any?) { undoManager?.undo() }
    @objc func redoSourceEdit(_ sender: Any?) { undoManager?.redo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        switch item.action {
        case #selector(undoSourceEdit(_:)): return undoManager?.canUndo ?? false
        case #selector(redoSourceEdit(_:)): return undoManager?.canRedo ?? false
        default: return super.validateUserInterfaceItem(item)
        }
    }

    @objc func increaseReaderFontSize(_ sender: Any?) { FontSizeStore.increase(); reRenderPreservingCaret() }
    @objc func decreaseReaderFontSize(_ sender: Any?) { FontSizeStore.decrease(); reRenderPreservingCaret() }
    @objc func resetReaderFontSize(_ sender: Any?) { FontSizeStore.reset(); reRenderPreservingCaret() }

    private func reRenderPreservingCaret() {
        guard let wc = windowControllers.first as? DocumentWindowController else { return }
        let anchor = wc.topVisibleCharIndex()      // keep the top visible line stable across zoom
        let savedCaret = wc.textView.readingCaret
        render(into: wc)                            // resets caret to 0 and re-lays out at the new size
        wc.textView.readingCaret = savedCaret       // restore reading position (clamped internally)
        wc.scrollCharToTop(anchor)                  // top anchor wins over the caret scroll
    }

    /// True for a file this app opens as TEXT rather than markdown (.txt, .csv, .log, …). Decided
    /// by extension, not content: a `.txt` full of `#` and `*` is a text file whose author wanted
    /// those characters on the page, and guessing otherwise would rewrite what they see.
    /// Markdown extensions are the allowlist; everything else that reaches us is plain.
    var isPlainText: Bool {
        let ext = (fileURL?.pathExtension ?? "md").lowercased()
        return !["md", "markdown", "mdown", "mkd", "mdtext"].contains(ext) && !ext.isEmpty
    }

    /// The line ending this file uses, so an inserted line matches the ones around it. A file made
    /// on Windows stays CRLF — mixing the two inside one file is the kind of thing that shows up
    /// later as a stray character in someone else's tool.
    var lineEnding: String { text.contains("\r\n") ? "\r\n" : "\n" }

    private func render(into wc: DocumentWindowController) {
        // FontSizeStore is the SINGLE owner of font size — never read UserDefaults directly.
        let theme = RenderTheme.current(size: FontSizeStore.size)
        let attr = isPlainText ? PlainTextRenderer.render(text, theme: theme)
                               : MarkdownRenderer.render(text, theme: theme)
        wc.display(attr)
        wc.window?.title = displayName ?? "fast-md-reader"
        renderGeneration += 1
        DispatchQueue.main.async { [weak self, weak wc] in
            guard let self, let wc else { return }
            // Reserve EXACT area up front wherever the size is known cheaply — local images
            // (ImageIO header) and already-cached diagrams (cached PDF size). Then loading only
            // toggles the drawing (pixels), never the geometry, so the scroll bar stays stable.
            self.presizeKnownMedia(in: wc)
            // Lay out the WHOLE document up front (media are just placeholders, so it's cheap): the
            // scrollbar then reflects the full length immediately — the user sees how much content
            // there is without scrolling. Content itself streams in lazily via reconcileMedia.
            wc.precomputeLayout()
            self.reconcileMedia(in: wc)   // load only what's on screen now
            // Then, in the background, render EVERY uncached diagram to the disk cache so its exact
            // size is known — the scrollbar becomes correct and never resizes again as you scroll
            // (the whole point: uncached docs behave like cached ones). Cached docs skip this.
            self.prerenderAllDiagrams(in: wc)
            // Same for remote images: fetch each header (a few KB, not the image) so its exact size
            // is known before it lands. Docs with no remote images skip this.
            self.measureRemoteImages(in: wc)
        }
    }

    /// The up-front measure pass. On the FIRST open of a diagram-heavy document nothing is cached,
    /// so each diagram's real height is unknown and loading it on scroll would resize the layout
    /// under the reader (the scroll-bar jitter). Here we render every uncached diagram to the disk
    /// cache in the background (bounded concurrency for memory), and once they're ALL sized we
    /// reserve each exact area and lay the document out ONCE. After this, sizes never change, so
    /// scrolling only ever draws pixels — no reflow, no jitter. Second open onward: all cached, so
    /// there's nothing to render and presizeKnownMedia already reserved exact areas.
    func prerenderAllDiagrams(in wc: DocumentWindowController) {
        guard let storage = wc.textStorageRef else { return }
        var codes: [WebBlock] = []
        var seen = Set<WebBlock>()
        storage.enumerateWebBlocks { block, _ in
            guard seen.insert(block).inserted else { return }
            if WebBlockRenderer.cachedSize(block) == nil { codes.append(block) }
        }
        guard !codes.isEmpty else { return }   // all cached → already presized to exact areas
        isPrerendering = true
        prerenderToken += 1
        let token = prerenderToken
        let gen = renderGeneration
        Task { @MainActor in
            // A few blocks render at once (each on its OWN WebBlockRenderer so their web views
            // don't collide); a small cap keeps the transient WebKit memory modest.
            let cap = min(3, codes.count)
            var next = 0
            await withTaskGroup(of: Void.self) { group in
                func pump() {
                    guard next < codes.count else { return }
                    let block = codes[next]; next += 1
                    group.addTask { @MainActor in _ = await WebBlockRenderer().prerenderToCache(block) }
                }
                for _ in 0..<cap { pump() }
                while await group.next() != nil {
                    guard token == self.prerenderToken, gen == self.renderGeneration else { break }
                    pump()
                }
            }
            guard token == self.prerenderToken, gen == self.renderGeneration else { return }
            self.isPrerendering = false
            // Every diagram is cached now → reserve each EXACT area, lay the whole doc out once
            // (scroll bar becomes correct), keep the reader's position, then fill visible pixels.
            let anchor = wc.topVisibleCharIndex()
            self.presizeKnownMedia(in: wc)
            wc.precomputeLayout()
            wc.scrollCharToTop(anchor)
            self.reconcileMedia(in: wc)
        }
    }

    // MARK: - Images / diagrams (lazy: only on-screen media hold pixels)

    /// Decoded-image cache keyed by resolved absolute URL string (muya's loadImageMap).
    private static let imageCache = NSCache<NSString, NSImage>()

    /// Column-fit a raw pixel size, honoring an explicit width (HTML/Pandoc/Obsidian) or shrinking
    /// oversized images to the column width.
    private func fittedSize(_ pixelSize: NSSize, _ storage: NSTextStorage, _ range: NSRange, maxWidth: CGFloat) -> NSSize {
        let colW = maxWidth - 8
        var size = pixelSize
        guard size.width > 0 else { return size }
        var targetW: CGFloat?
        if let pct = (storage.attribute(MDAttr.imageWidthPct, at: range.location, effectiveRange: nil) as? NSNumber)?.doubleValue {
            targetW = colW * CGFloat(pct)
        } else if let pts = (storage.attribute(MDAttr.imageWidth, at: range.location, effectiveRange: nil) as? NSNumber)?.doubleValue {
            targetW = min(CGFloat(pts), colW)
        } else if size.width > colW {
            targetW = colW
        } else if storage.attribute(MDAttr.mermaid, at: range.location, effectiveRange: nil) != nil,
                  size.width < colW * 0.5 {
            // A diagram's natural width is a mermaid layout artefact, not a size anyone chose: a
            // three-box graph comes out tiny and unreadable beside full-width text. Floor it at half
            // the column. It's vector art, so enlarging costs no sharpness.
            //
            // Diagrams ONLY. An image's size IS authored (a 16px icon must stay a 16px icon), and a
            // short formula stretched to half the page would look absurd.
            targetW = colW * 0.5
        }
        if let targetW {
            let s = targetW / size.width
            size = NSSize(width: targetW.rounded(), height: (size.height * s).rounded())
        }
        return size
    }

    /// Reserve the exact column-fitted area for media whose size is known WITHOUT rendering: local
    /// images (ImageIO header), already-cached diagrams (cached PDF size), and remote images whose
    /// header has already been fetched. Runs once after render, before the full layout, so those
    /// never resize on load. Uncached diagrams / unmeasured remote images keep their placeholder.
    private func presizeKnownMedia(in wc: DocumentWindowController) {
        guard let storage = wc.textStorageRef else { return }
        let maxWidth = wc.textView.textContainer?.size.width ?? 800
        let baseDir = fileURL?.deletingLastPathComponent()
        let whole = NSRange(location: 0, length: storage.length)
        var sets: [(NSSize, NSRange)] = []
        storage.enumerateAttribute(MDAttr.image, in: whole) { v, r, _ in
            guard let src = v as? String, !src.hasPrefix("data:"),
                  let url = self.resolveImageURL(src, baseDir: baseDir) else { return }
            if url.isFileURL {
                guard let px = MarkdownDocument.imagePixelSize(url) else { return }
                sets.append((px, r))
            } else if let px = MarkdownDocument.remoteSizes[url.absoluteString] {
                sets.append((px, r))
            }
        }
        storage.enumerateWebBlocks(in: whole) { block, r in
            guard let sz = WebBlockRenderer.cachedSize(block) else { return }
            sets.append((sz, r))
        }
        for (px, r) in sets {
            guard r.location < storage.length,
                  let att = storage.attribute(.attachment, at: r.location, effectiveRange: nil) as? NSTextAttachment,
                  let cell = att.attachmentCell as? SizedAttachmentCell else { continue }
            let fitted = fittedSize(px, storage, r, maxWidth: maxWidth)
            cell.reservedSize = fitted           // the cell owns layout size (survives image==nil)
            att.bounds = NSRect(origin: .zero, size: fitted)
            storage.edited(.editedAttributes, range: r, changeInLength: 0)
        }
    }

    /// The core of the lazy scheme: on-screen images/diagrams hold their pixels; those far from the
    /// viewport drop them (bounds stay, so no reflow); reload from cache when they come back near.
    /// Text is left alone — it's tiny and non-contiguous layout already purges its off-screen glyphs.
    /// Called after render and on every scroll-settle. All work here is main-thread.
    func reconcileMedia(in wc: DocumentWindowController) {
        guard let storage = wc.textStorageRef else { return }
        let keep = wc.visibleCharRange(margin: 1.5)   // ±1.5 screens stay loaded
        guard keep.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let baseDir = fileURL?.deletingLastPathComponent()
        let maxWidth = wc.textView.textContainer?.size.width ?? 800
        let gen = renderGeneration
        func onScreen(_ r: NSRange) -> Bool { NSIntersectionRange(r, keep).length > 0 }
        func attach(_ r: NSRange) -> NSTextAttachment? {
            storage.attribute(.attachment, at: r.location, effectiveRange: nil) as? NSTextAttachment
        }
        // Load: set the image AND its real fitted bounds (placeholder → actual). Reload gives the
        // same size, so it's stable. Purge: drop the image, keep bounds (no reflow).
        func load(_ image: NSImage?, _ r: NSRange) {
            guard gen == self.renderGeneration, r.location < storage.length,
                  let att = attach(r), let cell = att.attachmentCell as? SizedAttachmentCell else { return }
            let img = image ?? MarkdownDocument.brokenImage()
            let newSize = self.fittedSize(img.size, storage, r, maxWidth: maxWidth)
            let sizeChanged = abs(cell.reservedSize.height - newSize.height) > 0.5 || abs(cell.reservedSize.width - newSize.width) > 0.5
            att.image = img
            if sizeChanged {
                // Reserved size was only a guess (uncached diagram / remote image) — correct it, which
                // DOES reflow. Rare after the up-front measure pass (which pre-sizes every diagram).
                cell.reservedSize = newSize
                att.bounds = NSRect(origin: .zero, size: newSize)
                storage.edited(.editedAttributes, range: r, changeInLength: 0)
                wc.textView.layoutManager?.ensureLayout(forCharacterRange:
                    NSRange(location: r.location, length: storage.length - r.location))
            } else {
                // Reserved size already exact → just paint the pixels. No layout touch → the frame
                // height and scroll bar do not move at all.
                wc.redrawGlyphs(r)
            }
            wc.refreshAfterImageFill()
        }
        func purgeAt(_ r: NSRange) {
            guard r.location < storage.length, let att = attach(r) else { return }
            att.image = nil                 // reserved size (cell) unchanged → space kept, no reflow
            wc.redrawGlyphs(r)              // repaint the now-empty reserved area
        }

        // Collect first (don't mutate storage while enumerating its attributes).
        var purge: [NSRange] = [], imgLoad: [(String, NSRange)] = [], mmLoad: [(WebBlock, NSRange)] = []
        storage.enumerateAttribute(MDAttr.image, in: whole) { v, r, _ in
            guard let src = v as? String, !src.isEmpty, let att = attach(r) else { return }
            if onScreen(r) {
                guard att.image == nil else { return }
                // Mid-measure, an unmeasured remote image has no exact size yet — filling it now
                // would resize under the reader. The measure pass fills it once it's sized.
                if self.isMeasuringRemote, !src.hasPrefix("data:"),
                   let u = self.resolveImageURL(src, baseDir: baseDir), !u.isFileURL,
                   MarkdownDocument.remoteSizes[u.absoluteString] == nil { return }
                imgLoad.append((src, r))
            }
            else if att.image != nil { purge.append(r) }
        }
        storage.enumerateWebBlocks(in: whole) { block, r in
            guard let att = attach(r) else { return }
            if onScreen(r) {
                guard att.image == nil else { return }
                // During the up-front pass an uncached block has no exact size yet — loading it
                // now would resize the layout under the reader. Wait for the pass to size it; a
                // cached one is already exact, so it's safe to fill.
                if self.isPrerendering && WebBlockRenderer.cachedSize(block) == nil { return }
                mmLoad.append((block, r))
            }
            else if att.image != nil { purge.append(r) }
        }

        for r in purge { purgeAt(r) }
        for (src, r) in imgLoad {
            if src.hasPrefix("data:") {
                load(MarkdownDocument.decodeDataURI(src), r)
            } else if let url = resolveImageURL(src, baseDir: baseDir) {
                if let c = MarkdownDocument.imageCache.object(forKey: url.absoluteString as NSString) {
                    load(c, r)
                } else if FolderAccess.needsGrant(for: url) {
                    // Sandboxed and unreadable: don't attempt the read (it just fails silently, and
                    // macOS won't prompt). Offer the grant instead — clicking the range runs it.
                    storage.addAttribute(MDAttr.needsFolderGrant, value: url.deletingLastPathComponent(), range: r)
                    load(MarkdownDocument.needsAccessImage(), r)
                } else {
                    MarkdownDocument.loadImage(url) { [weak wc] img in
                        if let img { MarkdownDocument.imageCache.setObject(img, forKey: url.absoluteString as NSString) }
                        if wc != nil { load(img, r) }
                    }
                }
            } else { load(nil, r) }
        }
        if !mmLoad.isEmpty {
            let renderer = WebBlockRenderer()   // cache-first: reloads hit the disk cache, no WebKit
            Task { @MainActor in
                for (block, r) in mmLoad {
                    guard let img = await renderer.renderImage(block) else { continue }
                    load(img, r)
                }
            }
        }
    }

    private func resolveImageURL(_ src: String, baseDir: URL?) -> URL? {
        if let u = URL(string: src), let scheme = u.scheme, !scheme.isEmpty { return u }   // http(s)/file
        if src.hasPrefix("~") { return URL(fileURLWithPath: (src as NSString).expandingTildeInPath) }
        if src.hasPrefix("/") { return URL(fileURLWithPath: src) }
        if let baseDir { return baseDir.appendingPathComponent(src).standardizedFileURL }   // relative to the doc
        return nil
    }

    /// Measured sizes of remote images, keyed by absolute URL. Process-wide: the same URL keeps its
    /// size across reloads and documents, so it's measured once.
    static var remoteSizes: [String: NSSize] = [:]

    /// Pixel dimensions of a REMOTE image without downloading it: ask for the first 64 KB only, which
    /// carries the header of every format we care about, and let ImageIO read the dimensions out of
    /// that. Falls back to a full GET if the server ignores Range (some CDNs do).
    private static func remoteImageSize(_ url: URL) async -> NSSize? {
        func size(of data: Data) -> NSSize? {
            let src = CGImageSourceCreateIncremental(nil)
            CGImageSourceUpdateData(src, data as CFData, false)   // false: more bytes may follow
            guard let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                  let w = p[kCGImagePropertyPixelWidth] as? Double,
                  let h = p[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else { return nil }
            return NSSize(width: w, height: h)
        }
        var head = URLRequest(url: url)
        head.setValue("bytes=0-65535", forHTTPHeaderField: "Range")
        if let (data, _) = try? await URLSession.shared.data(for: head), let s = size(of: data) { return s }
        if let (data, _) = try? await URLSession.shared.data(from: url) { return size(of: data) }
        return nil
    }

    /// The remote counterpart of prerenderAllDiagrams: measure every not-yet-known remote image, then
    /// reserve exact areas and lay out ONCE. Without this each image would resize the document as it
    /// arrived — the reflow this whole design exists to avoid. Only headers are fetched, so it costs
    /// a few KB per image, not the image.
    func measureRemoteImages(in wc: DocumentWindowController) {
        guard let storage = wc.textStorageRef else { return }
        let baseDir = fileURL?.deletingLastPathComponent()
        var urls: [URL] = []
        var seen = Set<String>()
        storage.enumerateAttribute(MDAttr.image, in: NSRange(location: 0, length: storage.length)) { v, _, _ in
            guard let src = v as? String, !src.hasPrefix("data:"),
                  let url = self.resolveImageURL(src, baseDir: baseDir), !url.isFileURL,
                  MarkdownDocument.remoteSizes[url.absoluteString] == nil,
                  seen.insert(url.absoluteString).inserted else { return }
            urls.append(url)
        }
        guard !urls.isEmpty else { return }   // all measured (or none) → presize already exact
        isMeasuringRemote = true
        measureToken += 1
        let token = measureToken
        let gen = renderGeneration
        Task { @MainActor in
            await withTaskGroup(of: (String, NSSize?).self) { group in
                for url in urls {
                    group.addTask { (url.absoluteString, await MarkdownDocument.remoteImageSize(url)) }
                }
                for await (key, size) in group {
                    if let size { MarkdownDocument.remoteSizes[key] = size }
                }
            }
            guard token == self.measureToken, gen == self.renderGeneration else { return }
            self.isMeasuringRemote = false
            let anchor = wc.topVisibleCharIndex()
            self.presizeKnownMedia(in: wc)
            wc.precomputeLayout()
            wc.scrollCharToTop(anchor)
            self.reconcileMedia(in: wc)
        }
    }

    /// Pixel dimensions of an image WITHOUT decoding it (ImageIO reads only the header) — fast and
    /// cheap, so a local image's exact height can be reserved before its pixels load.
    private static func imagePixelSize(_ url: URL) -> NSSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double, w > 0, h > 0 else { return nil }
        return NSSize(width: w, height: h)
    }

    private static func loadImage(_ url: URL, completion: @escaping (NSImage?) -> Void) {
        if url.isFileURL {
            DispatchQueue.global(qos: .userInitiated).async {
                let img = NSImage(contentsOf: url)
                DispatchQueue.main.async { completion(img) }
            }
        } else {
            URLSession.shared.dataTask(with: url) { data, _, _ in
                let img = data.flatMap { NSImage(data: $0) }
                DispatchQueue.main.async { completion(img) }
            }.resume()
        }
    }

    private static func decodeDataURI(_ src: String) -> NSImage? {
        guard let comma = src.firstIndex(of: ","),
              let data = Data(base64Encoded: String(src[src.index(after: comma)...])) else { return nil }
        return NSImage(data: data)
    }

    /// Placeholder for an image the sandbox blocks: it says what to do, because a plain broken icon
    /// would read as "this app can't show images" when one click fixes it. Click → folder grant.
    static func needsAccessImage() -> NSImage {
        let text = "Click to allow images in this folder" as NSString
        let font = NSFont.systemFont(ofSize: 12)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.secondaryLabelColor]
        let pad: CGFloat = 10, iconW: CGFloat = 18
        let textSize = text.size(withAttributes: attrs)
        let size = NSSize(width: (textSize.width + iconW + pad * 3).rounded(), height: 34)
        let img = NSImage(size: size)
        img.lockFocus()
        let bg = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5),
                              xRadius: 6, yRadius: 6)
        NSColor.quaternaryLabelColor.setFill(); bg.fill()
        NSColor.tertiaryLabelColor.setStroke(); bg.stroke()
        if let icon = NSImage(systemSymbolName: "lock", accessibilityDescription: nil) {
            icon.draw(in: NSRect(x: pad, y: (size.height - 14) / 2, width: 12, height: 14))
        }
        text.draw(at: NSPoint(x: pad + iconW, y: (size.height - textSize.height) / 2), withAttributes: attrs)
        img.unlockFocus()
        return img
    }

    /// A broken/missing-image placeholder so a failed load isn't just blank space.
    private static func brokenImage() -> NSImage {
        let img = NSImage(systemSymbolName: "photo", accessibilityDescription: "missing image")
            ?? NSImage(size: NSSize(width: 22, height: 22))
        img.size = NSSize(width: 22, height: 22)
        return img
    }

    /// Swap each mermaid placeholder for a rendered PDF image. Runs async so text opens
    /// instantly with placeholders and diagrams stream in. A no-mermaid document does no
    /// work here and never touches WebKit.
}

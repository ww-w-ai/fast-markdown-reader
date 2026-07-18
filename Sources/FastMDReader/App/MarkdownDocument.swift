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
    // The text view is editable only to show a caret; edits are rejected, so the document is
    // never dirty and closing a tab must never prompt to save.
    override var isDocumentEdited: Bool { false }
    override func canAsynchronouslyWrite(to url: URL, ofType typeName: String, for saveOperation: NSDocument.SaveOperationType) -> Bool { false }

    override func read(from data: Data, ofType typeName: String) throws {
        self.text = String(decoding: data, as: UTF8.self)
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
        if let url = fileURL, let data = try? Data(contentsOf: url) {
            // The undo stack holds source OFFSETS into the text we're replacing. Re-reading the file
            // can move every one of them (the file may have changed behind us), so an undo applied
            // afterwards would overwrite the wrong span. Drop the history rather than corrupt the file.
            if data != Data(self.text.utf8) { undoManager?.removeAllActions() }
            self.text = String(decoding: data, as: UTF8.self)
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

    /// Replace a source range with edited markdown, persist to the .md file, and re-render
    /// (keeping scroll position). This is the ONLY path that writes the file — an explicit edit.
    ///
    /// Undo runs back through here with the inverse edit, so it persists and re-renders exactly like
    /// a typed one, and redo falls out for free: the undo manager records the inverse this call
    /// registers while it is undoing. Registration happens only AFTER the write succeeds — offering
    /// to undo an edit that never reached the file would be a lie.
    func applySourceEdit(_ r: NSRange, with replacement: String) {
        let ns = text as NSString
        guard r.location >= 0, r.location + r.length <= ns.length else { NSSound.beep(); return }
        let updated = ns.replacingCharacters(in: r, with: replacement)
        let previous = ns.substring(with: r)
        if let url = fileURL {
            do {
                try Data(updated.utf8).write(to: url)
            } catch {
                // NEVER swallow this: the edit only exists on screen until it reaches the file, so a
                // silent failure looks exactly like a save and the user closes the window trusting it.
                // (The sandbox denying the write is one way here — hence user-selected.read-WRITE.)
                let a = NSAlert()
                a.alertStyle = .warning
                a.messageText = "Couldn't save the edit"
                a.informativeText = "\(url.lastPathComponent) was not changed on disk.\n\n\(error.localizedDescription)"
                a.addButton(withTitle: "OK")
                if let w = windowControllers.first?.window { a.beginSheetModal(for: w) } else { a.runModal() }
                return   // keep the document as it is on disk — don't show an edit that didn't persist
            }
        }
        self.text = updated
        let undoRange = NSRange(location: r.location, length: (replacement as NSString).length)
        undoManager?.registerUndo(withTarget: self) { $0.applySourceEdit(undoRange, with: previous) }
        undoManager?.setActionName("Edit")
        guard let wc = windowControllers.first as? DocumentWindowController else { return }
        let anchor = wc.topVisibleCharIndex()
        render(into: wc)
        wc.scrollCharToTop(anchor)
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

    private func render(into wc: DocumentWindowController) {
        // FontSizeStore is the SINGLE owner of font size — never read UserDefaults directly.
        let attr = MarkdownRenderer.render(text, theme: .current(size: FontSizeStore.size))
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

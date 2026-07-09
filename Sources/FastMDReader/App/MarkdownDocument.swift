import AppKit

final class MarkdownDocument: NSDocument {
    private(set) var text: String = ""

    // C3: bumped on every full render; async mermaid swaps from a previous render carry
    // a stale generation and abort before mutating, so only the latest render wins.
    private var renderGeneration = 0

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
        render(into: wc)
    }

    // MARK: - Font size (menu actions routed through the responder chain)

    /// ⌘R: re-read the file from disk and re-render, keeping the scroll position. Note this
    /// reloads the DOCUMENT's content — it runs the currently-launched app binary, so it does
    /// not pick up a new app build (that still needs a relaunch).
    @objc func reloadDocument(_ sender: Any?) {
        if let url = fileURL, let data = try? Data(contentsOf: url) {
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
    func applySourceEdit(_ r: NSRange, with replacement: String) {
        let ns = text as NSString
        guard r.location >= 0, r.location + r.length <= ns.length else { NSSound.beep(); return }
        self.text = ns.replacingCharacters(in: r, with: replacement)
        if let url = fileURL { try? Data(text.utf8).write(to: url) }
        guard let wc = windowControllers.first as? DocumentWindowController else { return }
        let anchor = wc.topVisibleCharIndex()
        render(into: wc)
        wc.scrollCharToTop(anchor)
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
        renderMermaid(in: wc, generation: renderGeneration)
        renderImages(in: wc, generation: renderGeneration)
    }

    // MARK: - Images (async attachment fill, mirrors the mermaid pattern)

    /// Decoded-image cache keyed by resolved absolute URL string (muya's loadImageMap).
    private static let imageCache = NSCache<NSString, NSImage>()

    private func renderImages(in wc: DocumentWindowController, generation: Int) {
        guard let storage = wc.textStorageRef else { return }
        var jobs: [(NSRange, String)] = []
        storage.enumerateAttribute(MDAttr.image, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            if let src = v as? String, !src.isEmpty { jobs.append((r, src)) }
        }
        guard !jobs.isEmpty else { return }
        let maxWidth = wc.textView.textContainer?.size.width ?? 800
        let baseDir = fileURL?.deletingLastPathComponent()

        for (range, src) in jobs {
            let apply: (NSImage?) -> Void = { [weak self, weak wc] image in
                guard let self, let wc, generation == self.renderGeneration else { return }
                guard let storage = wc.textStorageRef, range.location < storage.length,
                      let att = storage.attribute(.attachment, at: range.location, effectiveRange: nil) as? NSTextAttachment
                else { return }
                let img = image ?? MarkdownDocument.brokenImage()
                let colW = maxWidth - 8
                var size = img.size
                if size.width > 0 {
                    // Explicit width (HTML/Pandoc/Obsidian) wins, capped to the column; otherwise
                    // only shrink oversized images to fit. No height cap (tall webtoons stay tall).
                    var targetW: CGFloat?
                    if let pct = (storage.attribute(MDAttr.imageWidthPct, at: range.location, effectiveRange: nil) as? NSNumber)?.doubleValue {
                        targetW = colW * CGFloat(pct)
                    } else if let pts = (storage.attribute(MDAttr.imageWidth, at: range.location, effectiveRange: nil) as? NSNumber)?.doubleValue {
                        targetW = min(CGFloat(pts), colW)
                    } else if size.width > colW {
                        targetW = colW
                    }
                    if let targetW {
                        let s = targetW / size.width
                        size = NSSize(width: targetW.rounded(), height: (size.height * s).rounded())
                    }
                }
                att.image = img
                att.bounds = NSRect(origin: .zero, size: size)
                // Force the attachment glyph to be re-measured + redrawn at its new size.
                storage.beginEditing()
                storage.edited(.editedAttributes, range: range, changeInLength: 0)
                storage.endEditing()
                wc.refreshAfterImageFill()
            }
            // data: URI decodes inline; everything else resolves to a URL and loads off-thread.
            if src.hasPrefix("data:") {
                apply(MarkdownDocument.decodeDataURI(src))
            } else if let url = resolveImageURL(src, baseDir: baseDir) {
                if let cached = MarkdownDocument.imageCache.object(forKey: url.absoluteString as NSString) {
                    apply(cached)
                } else {
                    MarkdownDocument.loadImage(url) { image in
                        if let image { MarkdownDocument.imageCache.setObject(image, forKey: url.absoluteString as NSString) }
                        apply(image)
                    }
                }
            } else {
                apply(nil)
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
    private func renderMermaid(in wc: DocumentWindowController, generation: Int) {
        guard let storage = wc.textStorageRef else { return }
        var jobs: [(NSRange, String)] = []
        storage.enumerateAttribute(MDAttr.mermaid, in: NSRange(location: 0, length: storage.length)) { v, r, _ in
            if let src = v as? String { jobs.append((r, src)) }
        }
        guard !jobs.isEmpty else { return }
        let maxWidth = wc.textView.textContainer?.size.width ?? 800
        let renderer = MermaidRenderer()
        // Weak captures so closing a document mid-render never keeps the document, its
        // window controller, or its text storage alive until the render finishes.
        Task { @MainActor [weak self, weak wc] in
            for (range, src) in jobs.reversed() { // reversed so earlier ranges stay valid
                guard let self, generation == self.renderGeneration else { return }  // C3: stale/closed aborts
                guard let storage = wc?.textStorageRef else { return }
                guard let image = await renderer.renderImage(source: src) else { continue }
                guard generation == self.renderGeneration else { return }            // re-check after await
                // Scale to fit the text width, preserving aspect (avoids horizontal scroll).
                var size = image.size
                if size.width > maxWidth, size.width > 0 {
                    let s = (maxWidth - 8) / size.width
                    size = NSSize(width: maxWidth - 8, height: size.height * s)
                }
                let att = NSTextAttachment()
                att.image = image
                att.bounds = NSRect(origin: .zero, size: size)
                // Guard the range against text that shifted underneath us.
                guard range.location + range.length <= storage.length else { continue }
                // Keep MDAttr.mermaid on the swapped-in image so a click can reopen it enlarged.
                let attStr = NSMutableAttributedString(attachment: att)
                attStr.addAttribute(MDAttr.mermaid, value: src, range: NSRange(location: 0, length: attStr.length))
                storage.replaceCharacters(in: range, with: attStr)
            }
            guard let self, generation == self.renderGeneration else { return }
            wc?.refreshAfterMutation()
        }
    }
}

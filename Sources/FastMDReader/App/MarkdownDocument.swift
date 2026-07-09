import AppKit

final class MarkdownDocument: NSDocument {
    private(set) var text: String = ""

    // C3: bumped on every full render; async mermaid swaps from a previous render carry
    // a stale generation and abort before mutating, so only the latest render wins.
    private var renderGeneration = 0

    override class var autosavesInPlace: Bool { false }
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

    @objc func increaseReaderFontSize(_ sender: Any?) { FontSizeStore.increase(); reRenderPreservingCaret() }
    @objc func decreaseReaderFontSize(_ sender: Any?) { FontSizeStore.decrease(); reRenderPreservingCaret() }

    private func reRenderPreservingCaret() {
        guard let wc = windowControllers.first as? DocumentWindowController else { return }
        let saved = wc.textView.readingCaret
        render(into: wc)                    // resets caret to 0 and re-lays out at the new size
        wc.textView.readingCaret = saved    // restore reading position (clamped internally)
    }

    private func render(into wc: DocumentWindowController) {
        // FontSizeStore is the SINGLE owner of font size — never read UserDefaults directly.
        let attr = MarkdownRenderer.render(text, theme: .current(size: FontSizeStore.size))
        wc.display(attr)
        wc.window?.title = displayName ?? "fast-md-reader"
        renderGeneration += 1
        renderMermaid(in: wc, generation: renderGeneration)
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
                storage.replaceCharacters(in: range, with: NSAttributedString(attachment: att))
            }
            guard let self, generation == self.renderGeneration else { return }
            wc?.refreshAfterMutation()
        }
    }
}

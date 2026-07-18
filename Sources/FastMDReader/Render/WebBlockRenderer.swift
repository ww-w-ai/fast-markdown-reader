import AppKit
import WebKit
import os.log

/// Renders the blocks WebKit has to draw — mermaid diagrams and TeX formulas — to PDF. Lookup order
/// (C4): in-RAM memo → disk PDF cache → transient offscreen WKWebView. A document with neither, or a
/// fully-cached one, never constructs a WKWebView, so there is no persistent web/JS cost. The web
/// view is created only on a cache miss and released the instant the snapshot completes.
///
/// The engines differ ONLY in the HTML they get and the element to wait for; everything that makes
/// the reader stable — measure to the cache first, size from the cached PDF, snapshot only once the
/// content really has a size — is shared, so neither engine can drift away from it.
final class WebBlockRenderer {
    private static let log = Logger(subsystem: "ai.ww-w.fast-md-reader", category: "webblock")

    // C4: images are font-independent, so cache the decoded NSImage in RAM for the session.
    // Prevents placeholder flicker and PDF re-decode on every font change.
    private var memo: [String: NSImage] = [:]
    private var webView: WKWebView?

    private static func key(_ block: WebBlock) -> String {
        MermaidCache.key(source: block.code, version: block.engine.cacheVersion)
    }

    /// The natural size of a block if it is ALREADY cached on disk (reads the PDF header, no render)
    /// — so its exact area can be reserved up front. nil if not cached yet.
    static func cachedSize(_ block: WebBlock) -> NSSize? {
        guard let pdf = MermaidCache.pdf(forKey: key(block)), let rep = NSPDFImageRep(data: pdf) else { return nil }
        let s = rep.size
        return (s.width > 0 && s.height > 0) ? s : nil
    }

    /// Render to the DISK cache only and return the block's size — WITHOUT retaining the NSImage in
    /// `memo`. Used by the up-front measure pass so every block is cached (and thus exactly sizeable)
    /// before layout, without holding all images in RAM (pixels load lazily per viewport).
    func prerenderToCache(_ block: WebBlock) async -> NSSize? {
        if let sz = Self.cachedSize(block) { return sz }
        guard let data = await renderViaWebView(block), data.count > 512,
              let rep = NSPDFImageRep(data: data) else { return nil }
        MermaidCache.store(data, forKey: Self.key(block))   // never cache empty/failed renders
        let s = rep.size
        return (s.width > 0 && s.height > 0) ? s : nil
    }

    /// Returns a rendered block image, or nil on failure. Uses caches first.
    func renderImage(_ block: WebBlock) async -> NSImage? {
        let k = Self.key(block)
        if let img = memo[k] { return img }
        if let pdf = MermaidCache.pdf(forKey: k), let img = NSImage(data: pdf) {
            memo[k] = img
            return img
        }
        guard let data = await renderViaWebView(block), data.count > 512,
              let img = NSImage(data: data) else {
            Self.log.error("\(block.engine.rawValue, privacy: .public) render failed (cache miss, empty/invalid output)")
            return nil
        }
        MermaidCache.store(data, forKey: k)   // never cache empty/failed renders
        memo[k] = img
        return img
    }

    // MARK: - Page

    private static func bundledText(_ resource: String, _ ext: String) -> String? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: ext),
              let s = try? String(contentsOf: url, encoding: .utf8) else {
            log.error("\(resource, privacy: .public).\(ext, privacy: .public) not found in bundle")
            return nil
        }
        return s
    }

    /// The page for one block. The source is handed over as JSON data and assigned from script —
    /// NEVER interpolated into markup — so a `</script>` or `</div>` inside a .md can't break out of
    /// the render (injection safety).
    private static func html(for block: WebBlock) -> String? {
        let json = String(decoding: (try? JSONSerialization.data(withJSONObject: [block.code])) ?? Data("[\"\"]".utf8),
                          as: UTF8.self)
        let frame = """
        <!doctype html><html><head><meta charset="utf-8">%@
        <style>body{margin:0;padding:8px;background:transparent}#host{display:inline-block}</style>
        </head><body><div id="host"></div><script>%@</script></body></html>
        """
        switch block.engine {
        case .mermaid:
            guard let js = bundledText("mermaid.min", "js") else { return nil }
            let head = "<script>\(js)</script>"
            let body = """
              var el = document.getElementById('host');
              el.className = 'mermaid';
              el.textContent = \(json)[0];
              mermaid.initialize({startOnLoad:true});
            """
            return String(format: frame, head, body)
        case .math:
            // The CSS carries its fonts inlined as data: URIs — this page is loaded with baseURL nil,
            // so a relative font url() would resolve to nothing and every glyph would quietly fall
            // back to a system font at the wrong metrics. See Scripts/build-katex-css.sh.
            guard let js = bundledText("katex.min", "js"), let css = bundledText("katex-inlined.min", "css") else { return nil }
            // displayMode wraps the formula in .katex-display, whose 1em margins would be baked into
            // the captured PDF as dead space (and pushed the formula past the page). The reader lays
            // the block out with its own spacing, so zero them here.
            let head = "<style>\(css)</style><style>.katex-display{margin:0}</style><script>\(js)</script>"
            let body = """
              window.__ready = false;
              katex.render(\(json)[0], document.getElementById('host'),
                           {displayMode:true, throwOnError:false, output:'html'});
              // Only report ready once the inlined fonts are live: KaTeX lays out synchronously, so
              // snapshotting before then bakes fallback-font metrics into the cached PDF forever.
              document.fonts.ready.then(function(){ window.__ready = true; });
            """
            return String(format: frame, head, body)
        }
    }

    /// What to measure, per engine. Returning a real size is also the readiness signal — we never
    /// snapshot on a timer, which would cache a blank or half-drawn block permanently.
    ///
    /// Reports the content's RIGHT/BOTTOM edge, not its width/height: an engine is free to offset its
    /// own content (KaTeX's display wrapper does), and sizing the page by height alone then clips
    /// exactly that offset off the bottom. Since the element sits at the 8px body padding, right/
    /// bottom + 8 is identical to width/height + 16 whenever there is no offset — mermaid is
    /// unaffected.
    private static func probe(for engine: WebBlock.Engine) -> String {
        let selector = engine == .mermaid ? "#host svg" : "#host .katex"
        let gate = engine == .mermaid ? "" : "if(!window.__ready)return[0,0];"
        return "(function(){\(gate)var s=document.querySelector('\(selector)');" +
               "if(!s)return[0,0];var r=s.getBoundingClientRect();return[r.right,r.bottom];})()"
    }

    @MainActor
    private func renderViaWebView(_ block: WebBlock) async -> Data? {
        guard let html = Self.html(for: block) else { return nil }
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000), configuration: WKWebViewConfiguration())
        webView = wv
        let probe = Self.probe(for: block.engine)
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            // The continuation closure is nonisolated, but this whole method is @MainActor and every
            // hop below re-enters on the main queue — so state it explicitly instead of hopping.
            MainActor.assumeIsolated {
                wv.loadHTMLString(html, baseURL: nil)
                let start = Date()
                var finished = false
                @MainActor func poll() {
                    if finished { return }
                    wv.evaluateJavaScript(probe) { result, _ in
                        let size = (result as? [CGFloat]) ?? [0, 0]
                        if size.count == 2, size[0] > 1, size[1] > 1 {
                            finished = true
                            let w = size[0] + 8, h = size[1] + 8   // content's far edge + the padding

                            wv.frame = NSRect(x: 0, y: 0, width: w, height: h)
                            let cfg = WKPDFConfiguration()
                            cfg.rect = CGRect(x: 0, y: 0, width: w, height: h)
                            wv.createPDF(configuration: cfg) { r in
                                self.webView = nil   // release the web view immediately
                                if case .success(let data) = r { cont.resume(returning: data) }
                                else { cont.resume(returning: nil) }
                            }
                        } else if Date().timeIntervalSince(start) > 5.0 {
                            finished = true; self.webView = nil
                            cont.resume(returning: nil) // timeout → return nil so we do NOT cache it
                        } else {
                            schedulePoll()
                        }
                    }
                }
                @MainActor func schedulePoll() {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        MainActor.assumeIsolated { poll() }
                    }
                }
                schedulePoll()
            }
        }
    }
}

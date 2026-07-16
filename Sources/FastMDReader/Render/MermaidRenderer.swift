import AppKit
import WebKit
import os.log

/// Renders mermaid diagrams to PDF. Lookup order (C4): in-RAM memo → disk PDF cache →
/// transient offscreen WKWebView. A no-mermaid document and a fully-cached document
/// never construct a WKWebView, so there is no persistent web/JS cost. The web view is
/// created only on a cache miss and released the instant the snapshot completes.
final class MermaidRenderer {
    static let version = "10"
    private static let log = Logger(subsystem: "ai.ww-w.fast-md-reader", category: "mermaid")

    // C4: images are font-independent, so cache the decoded NSImage in RAM for the
    // session. Prevents placeholder flicker and PDF re-decode on every font change.
    private var memo: [String: NSImage] = [:]
    private var webView: WKWebView?

    /// The natural size of a diagram if it is ALREADY cached on disk (reads the PDF header, no
    /// render) — so its exact area can be reserved up front. nil if not cached yet.
    static func cachedSize(source: String) -> NSSize? {
        let key = MermaidCache.key(source: source, version: version)
        guard let pdf = MermaidCache.pdf(forKey: key), let rep = NSPDFImageRep(data: pdf) else { return nil }
        let s = rep.size
        return (s.width > 0 && s.height > 0) ? s : nil
    }

    /// Render to the DISK cache only and return the diagram's size — WITHOUT retaining the NSImage
    /// in `memo`. Used by the up-front measure pass so every diagram is cached (and thus exactly
    /// sizeable) before layout, without holding all images in RAM (pixels load lazily per viewport).
    func prerenderToCache(source: String) async -> NSSize? {
        let key = MermaidCache.key(source: source, version: Self.version)
        if let sz = Self.cachedSize(source: source) { return sz }
        guard let data = await renderViaWebView(source: source), data.count > 512,
              let rep = NSPDFImageRep(data: data) else { return nil }
        MermaidCache.store(data, forKey: key)   // never cache empty/failed renders
        let s = rep.size
        return (s.width > 0 && s.height > 0) ? s : nil
    }

    /// Returns a rendered diagram image, or nil on failure. Uses caches first.
    func renderImage(source: String) async -> NSImage? {
        let key = MermaidCache.key(source: source, version: Self.version)
        if let img = memo[key] { return img }
        if let pdf = MermaidCache.pdf(forKey: key), let img = NSImage(data: pdf) {
            memo[key] = img
            return img
        }
        guard let data = await renderViaWebView(source: source), data.count > 512,
              let img = NSImage(data: data) else {
            Self.log.error("mermaid render failed (cache miss, empty/invalid output)")
            return nil
        }
        MermaidCache.store(data, forKey: key)   // never cache empty/failed renders
        memo[key] = img
        return img
    }

    @MainActor
    private func renderViaWebView(source: String) async -> Data? {
        guard let jsURL = Bundle.main.url(forResource: "mermaid.min", withExtension: "js"),
              let js = try? String(contentsOf: jsURL, encoding: .utf8) else {
            Self.log.error("mermaid.min.js not found in bundle")
            return nil
        }
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1000, height: 1000), configuration: config)
        webView = wv
        // Inject the diagram source as JS data (textContent), never interpolated into markup —
        // avoids </div>/<script> in the .md breaking the render (injection safety).
        let jsonSource = String(decoding: (try? JSONSerialization.data(withJSONObject: [source])) ?? Data("[\"\"]".utf8), as: UTF8.self)
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <style>body{margin:0;padding:8px;background:transparent}</style>
        <script>\(js)</script></head>
        <body><div id="host"></div>
        <script>
          var el = document.getElementById('host');
          el.className = 'mermaid';
          el.textContent = \(jsonSource)[0];
          mermaid.initialize({startOnLoad:true});
        </script></body></html>
        """
        return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            // The continuation closure is nonisolated, but this whole method is @MainActor and every
            // hop below re-enters on the main queue — so state it explicitly instead of hopping.
            MainActor.assumeIsolated {
                wv.loadHTMLString(html, baseURL: nil)
                let start = Date()
                var finished = false
                // Poll until mermaid has produced an <svg> with non-zero size, THEN snapshot.
                // Never snapshot on a fixed timer (would cache a blank/partial diagram forever).
                @MainActor func poll() {
                    if finished { return }
                    let probe = "(function(){var s=document.querySelector('#host svg');" +
                                "if(!s)return[0,0];var r=s.getBoundingClientRect();return[r.width,r.height];})()"
                    wv.evaluateJavaScript(probe) { result, _ in
                        let size = (result as? [CGFloat]) ?? [0, 0]
                        if size.count == 2, size[0] > 1, size[1] > 1 {
                            finished = true
                            let w = size[0] + 16, h = size[1] + 16
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

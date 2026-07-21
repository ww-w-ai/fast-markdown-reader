import Foundation

/// Resolves an in-document anchor link's raw target (`MDAttr.anchor`'s value — the fragment after
/// `#`, e.g. `"_Toc123"` or `"Getting-Started"`) to the character position it should scroll to.
/// Pure decision logic, no `NSTextView`/window — the same split `TextNavigator` makes from
/// `ReaderTextView`, kept testable headless (CLAUDE.md invariant 30/29: the resolution decision is
/// what a test can prove; the scroll/reveal itself needs a real window).
///
/// Two, independently sourced candidate sets, tried in order:
/// 1. **Exact bookmark match** (`MDAttr.bookmarkTarget` — office documents). Bookmark names are
///    opaque ids (`_Toc123`, `_Ref456`), never slugified, so this is a plain `==`.
/// 2. **GFM heading-slug match** (`MDAttr.heading` — markdown TOC links, and, incidentally, an
///    office link whose target happens to equal a heading's own slugified text). Markdown's
///    existing convention, unchanged.
///
/// A target present in NEITHER set returns `nil` — the caller does nothing (no beep, no guess): a
/// dead cross-reference to a deleted bookmark is common in real documents and is not an error.
enum AnchorResolver {
    /// - Parameters:
    ///   - target: the raw fragment, exactly as stored in `MDAttr.anchor` (no leading `#`).
    ///   - bookmarks: exact bookmark name → character position, gathered from every
    ///     `MDAttr.bookmarkTarget` range in the document (first character of the range).
    ///   - headings: every heading's (raw, un-slugified) text and its character position, in
    ///     document order.
    /// - Returns: the character position to jump to, or `nil` if nothing matches.
    static func resolve(target: String, bookmarks: [String: Int], headings: [(text: String, position: Int)]) -> Int? {
        if let exact = bookmarks[target] { return exact }
        let want = slugify(target)
        return headings.first { slugify($0.text) == want }?.position
    }

    /// GitHub's own slug rule: lowercase, drop punctuation, spaces/tabs → hyphens. Hangul/CJK and
    /// other letters/digits pass through untouched — this must stay byte-for-byte identical to
    /// `DocumentWindowController`'s (now-removed) private copy, since both markdown TOC links and
    /// office links that happen to target a heading rely on the exact same rule.
    static func slugify(_ s: String) -> String {
        var out = ""
        for ch in s.lowercased() {
            if ch == " " || ch == "\t" { out.append("-") }
            else if ch == "-" || ch == "_" || ch.isLetter || ch.isNumber { out.append(ch) }
        }
        return out
    }
}

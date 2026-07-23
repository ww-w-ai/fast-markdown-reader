import Foundation

/// Boundary-finding for the reading cursor. All offsets are UTF-16 units (NSString), to
/// match NSTextView/NSRange/scrollRangeToVisible (C1). Character/grapheme indices are
/// deliberately NOT used — they diverge from UTF-16 for emoji/CJK and would produce
/// out-of-range NSRanges. Every method clamps `from` into [0, length].
struct TextNavigator {
    private let newline: unichar = 10
    private let space: unichar = 32
    private let period: unichar = 46

    private func clamp(_ v: Int, _ len: Int) -> Int { max(0, min(v, len)) }

    func lineStart(_ s: String, from: Int) -> Int {
        let ns = s as NSString
        var i = clamp(from, ns.length) - 1
        while i >= 0 && ns.character(at: i) != newline { i -= 1 }
        return i + 1
    }

    func lineEnd(_ s: String, from: Int) -> Int {
        let ns = s as NSString
        var i = clamp(from, ns.length)
        while i < ns.length && ns.character(at: i) != newline { i += 1 }
        return i
    }

    func previousLineBoundary(_ s: String, from: Int) -> Int {
        let ls = lineStart(s, from: from)
        if from == ls { // already at line start → previous line's start
            return from == 0 ? 0 : lineStart(s, from: from - 1)
        }
        return ls
    }

    func nextLineBoundary(_ s: String, from: Int) -> Int {
        let ns = s as NSString
        let le = lineEnd(s, from: from)
        if from == le { // already at line end → next line's end
            return le >= ns.length ? le : lineEnd(s, from: le + 1)
        }
        return le
    }

    // Sentence = ends at ". "/".\n"/"." EOF. Start = first non-space after a terminator.
    private func sentenceStarts(_ s: String) -> [Int] {
        let ns = s as NSString
        var starts = [0]; var i = 0
        while i < ns.length {
            if ns.character(at: i) == period {
                var j = i + 1
                while j < ns.length, ns.character(at: j) == space || ns.character(at: j) == newline { j += 1 }
                if j < ns.length { starts.append(j) }
                i = j
            } else { i += 1 }
        }
        return starts   // built left-to-right, already strictly ascending — no sort needed
    }

    func sentenceStart(_ s: String, from: Int) -> Int {
        let f = clamp(from, (s as NSString).length)
        let starts = sentenceStarts(s)
        if starts.contains(f) { return starts.last(where: { $0 < f }) ?? starts.first ?? 0 }
        return starts.last(where: { $0 <= f }) ?? 0
    }

    func nextSentenceStart(_ s: String, from: Int) -> Int {
        let f = clamp(from, (s as NSString).length)
        return sentenceStarts(s).first(where: { $0 > f }) ?? (s as NSString).length
    }

    // Paragraph = separated by a blank line. Start = first char after "\n\n".
    private func paragraphStarts(_ s: String) -> [Int] {
        let ns = s as NSString
        var starts = [0]; var i = 0
        while i < ns.length - 1 {
            if ns.character(at: i) == newline && ns.character(at: i + 1) == newline {
                var j = i + 2
                while j < ns.length && ns.character(at: j) == newline { j += 1 }
                if j < ns.length { starts.append(j) }
                i = j
            } else { i += 1 }
        }
        return starts   // built left-to-right, already strictly ascending — no sort needed
    }

    func paragraphStart(_ s: String, from: Int) -> Int {
        let f = clamp(from, (s as NSString).length)
        let starts = paragraphStarts(s)
        if starts.contains(f) { return starts.last(where: { $0 < f }) ?? starts.first ?? 0 }
        return starts.last(where: { $0 <= f }) ?? 0
    }

    func nextParagraphStart(_ s: String, from: Int) -> Int {
        let f = clamp(from, (s as NSString).length)
        return paragraphStarts(s).first(where: { $0 > f }) ?? (s as NSString).length
    }

    // MARK: - Unit ranges (for select-on-navigate)

    /// The line containing `from` (excludes the trailing newline), as a UTF-16 NSRange.
    func lineRange(_ s: String, from: Int) -> NSRange {
        let a = lineStart(s, from: from), b = lineEnd(s, from: from)
        return NSRange(location: a, length: max(0, b - a))
    }

    /// The sentence containing `from`, trailing whitespace trimmed.
    func sentenceRange(_ s: String, from: Int) -> NSRange {
        let ns = s as NSString
        return trimTrailing(ns, bracket(sentenceStarts(s), clamp(from, ns.length), ns.length))
    }

    /// The paragraph containing `from`, trailing blank lines trimmed.
    func paragraphRange(_ s: String, from: Int) -> NSRange {
        let ns = s as NSString
        return trimTrailing(ns, bracket(paragraphStarts(s), clamp(from, ns.length), ns.length))
    }

    private func bracket(_ starts: [Int], _ from: Int, _ len: Int) -> NSRange {
        let a = starts.last(where: { $0 <= from }) ?? 0
        let b = starts.first(where: { $0 > a }) ?? len
        return NSRange(location: a, length: max(0, b - a))
    }

    private func trimTrailing(_ ns: NSString, _ r: NSRange) -> NSRange {
        var b = r.location + r.length
        while b > r.location {
            let c = ns.character(at: b - 1)
            if c == newline || c == space { b -= 1 } else { break }
        }
        return NSRange(location: r.location, length: b - r.location)
    }
}

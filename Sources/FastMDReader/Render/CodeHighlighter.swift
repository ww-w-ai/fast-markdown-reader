import AppKit

/// Native, dependency-free regex tokenizer for a curated language set. This keeps the
/// "no JavaScriptCore for code-only documents" guarantee (spec §2, §10.1). Unknown /
/// unsupported languages fall back to plain monospace. tree-sitter is a v2 upgrade.
enum CodeHighlighter {
    private struct Palette {
        let keyword = NSColor.systemPink
        let type = NSColor.systemTeal
        let string = NSColor.systemRed
        let number = NSColor.systemOrange
        let comment = NSColor.secondaryLabelColor
    }

    private static let keywords: [String: Set<String>] = [
        "swift": ["let","var","func","if","else","for","while","return","struct","class","enum","import","guard","in","self","true","false","nil"],
        "js": ["const","let","var","function","if","else","for","while","return","class","import","export","await","async","true","false","null","undefined"],
        "ts": ["const","let","var","function","if","else","for","while","return","class","import","export","await","async","interface","type","true","false","null"],
        "python": ["def","class","if","elif","else","for","while","return","import","from","as","with","in","not","and","or","True","False","None"],
        "bash": ["if","then","else","fi","for","in","do","done","case","esac","function","return","echo","export"],
        "json": [],
    ]

    private static func canonical(_ lang: String?) -> String? {
        guard let l = lang?.lowercased() else { return nil }
        switch l {
        case "javascript": return "js"
        case "typescript": return "ts"
        case "py": return "python"
        case "sh", "shell", "zsh": return "bash"
        default: return keywords[l] != nil ? l : nil
        }
    }

    // Regexes are compiled ONCE (not per code block per render). Per-language keywords collapse
    // into a single `\b(a|b|c)\b` alternation instead of one regex per keyword.
    private static let numberRE = try! NSRegularExpression(pattern: "\\b[0-9]+(?:\\.[0-9]+)?\\b")
    private static let dqStringRE = try! NSRegularExpression(pattern: "\"(?:[^\"\\\\]|\\\\.)*\"")
    private static let sqStringRE = try! NSRegularExpression(pattern: "'(?:[^'\\\\]|\\\\.)*'")
    private static let slashCommentRE = try! NSRegularExpression(pattern: "//[^\\n]*")
    private static let hashCommentRE = try! NSRegularExpression(pattern: "#[^\\n]*")
    private static let keywordRE: [String: NSRegularExpression] = {
        var d: [String: NSRegularExpression] = [:]
        for (lang, kws) in keywords where !kws.isEmpty {
            let alt = kws.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|")
            if let re = try? NSRegularExpression(pattern: "\\b(?:\(alt))\\b") { d[lang] = re }
        }
        return d
    }()

    static func highlight(_ code: String, language: String?, theme: RenderTheme) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: theme.codeFont, .foregroundColor: theme.textColor]
        let result = NSMutableAttributedString(string: code, attributes: base)
        guard let lang = canonical(language) else { return result } // plain fallback
        let p = Palette()
        let full = NSRange(location: 0, length: (code as NSString).length)

        func apply(_ re: NSRegularExpression, _ c: NSColor) {
            for m in re.matches(in: code, range: full) {
                result.addAttribute(.foregroundColor, value: c, range: m.range)
            }
        }

        // keywords first, then literals/comments override where they overlap
        if let kwRE = keywordRE[lang] { apply(kwRE, p.keyword) }
        apply(numberRE, p.number)
        apply(dqStringRE, p.string)
        apply(sqStringRE, p.string)
        apply((lang == "python" || lang == "bash") ? hashCommentRE : slashCommentRE, p.comment)
        return result
    }
}

import AppKit

/// Native, dependency-free tokenizer for a curated language set. This keeps the "no JavaScriptCore
/// for code-only documents" guarantee (spec §2, §10.1). Unknown languages fall back to plain
/// monospace. tree-sitter is a v2 upgrade.
///
/// ONE left-to-right pass, not a stack of regex passes painting over each other. That ordering is
/// what decides correctness: a scanner that has already consumed `"http://a.com"` as a string can't
/// then mistake its `//` for a comment, and a `#` inside a shell string stays a string. Overlapping
/// regex passes get both of those wrong, and every language added multiplies the collisions.
enum CodeHighlighter {
    private struct Palette {
        let keyword = NSColor.systemPink
        let type = NSColor.systemTeal
        let string = NSColor.systemRed
        let number = NSColor.systemOrange
        let comment = NSColor.secondaryLabelColor
        let added = NSColor.systemGreen
        let removed = NSColor.systemRed
    }

    /// A language is just its comment markers, its string delimiters and its keywords — enough for
    /// reading, which is all this app does.
    private struct Lang {
        var kw: Set<String> = []
        var line: [String] = ["//"]                     // line-comment starters
        var block: [(String, String)] = [("/*", "*/")]  // block-comment delimiters
        var quotes: String = "\"'"                      // string delimiters (single char each)
        var raw: [(String, String)] = []                // multi-char string fences ("""…""")
        /// Colour Capitalised words as types. True only where that convention actually holds, so
        /// Python's `None` or a shell's `PATH` don't get painted as types.
        var caps: Bool = false
        /// Diffs are coloured by line, not by token — see `diffHighlight`.
        var lineShaped: Bool = false
    }

    // MARK: - Languages

    private static func cLike(_ kw: Set<String>, caps: Bool = true, line: [String] = ["//"]) -> Lang {
        Lang(kw: kw, line: line, block: [("/*", "*/")], quotes: "\"'`", caps: caps)
    }
    private static func hashLike(_ kw: Set<String>, quotes: String = "\"'", raw: [(String, String)] = []) -> Lang {
        Lang(kw: kw, line: ["#"], block: [], quotes: quotes, raw: raw)
    }

    private static let langs: [String: Lang] = [
        "swift": cLike(["let","var","func","if","else","for","while","return","struct","class","enum","protocol","extension","import","guard","in","self","init","case","switch","defer","throws","try","await","async","some","any","true","false","nil"]),
        "js": cLike(["const","let","var","function","if","else","for","while","return","class","new","import","export","from","default","await","async","try","catch","throw","typeof","switch","case","break","continue","true","false","null","undefined","this"], caps: false),
        "ts": cLike(["const","let","var","function","if","else","for","while","return","class","new","import","export","from","default","await","async","try","catch","throw","interface","type","enum","implements","extends","public","private","readonly","switch","case","true","false","null","undefined","this"]),
        "go": cLike(["func","package","import","var","const","type","struct","interface","if","else","for","range","return","go","defer","chan","select","switch","case","map","make","new","nil","true","false"]),
        "rust": cLike(["fn","let","mut","const","struct","enum","impl","trait","pub","use","mod","if","else","for","while","loop","match","return","self","Self","async","await","move","ref","where","true","false"]),
        "java": cLike(["class","interface","enum","public","private","protected","static","final","void","new","if","else","for","while","return","import","package","extends","implements","try","catch","throw","throws","switch","case","this","true","false","null"]),
        "kotlin": cLike(["fun","val","var","class","object","interface","if","else","for","while","return","when","import","package","data","sealed","suspend","override","private","public","true","false","null","this"]),
        "c": cLike(["int","char","float","double","void","long","short","unsigned","signed","struct","union","enum","typedef","static","const","if","else","for","while","return","switch","case","break","continue","sizeof","include","define","NULL"], caps: false),
        "cpp": cLike(["int","char","float","double","void","bool","auto","class","struct","enum","namespace","template","typename","public","private","protected","virtual","const","static","if","else","for","while","return","switch","case","new","delete","try","catch","throw","nullptr","true","false"]),
        "csharp": cLike(["using","namespace","class","struct","interface","enum","public","private","protected","internal","static","readonly","var","void","if","else","for","foreach","in","while","return","switch","case","new","try","catch","throw","async","await","true","false","null","this"]),
        "scala": cLike(["def","val","var","class","object","trait","case","match","if","else","for","while","return","import","package","extends","with","implicit","lazy","new","true","false","null","this"]),
        "dart": cLike(["class","void","var","final","const","if","else","for","while","return","import","export","new","async","await","try","catch","throw","extends","implements","true","false","null","this"]),
        "php": cLike(["function","class","interface","trait","public","private","protected","static","if","else","elseif","foreach","for","while","return","echo","require","include","namespace","use","new","try","catch","throw","true","false","null","this"], caps: false, line: ["//", "#"]),
        "objc": cLike(["interface","implementation","property","import","include","if","else","for","while","return","void","id","self","nil","YES","NO","nonatomic","strong","weak"]),
        "json": Lang(kw: ["true","false","null"], line: [], block: [], quotes: "\""),

        "python": hashLike(["def","class","if","elif","else","for","while","return","import","from","as","with","in","not","and","or","try","except","finally","raise","lambda","yield","async","await","pass","break","continue","global","True","False","None","self"],
                           quotes: "\"'", raw: [("\"\"\"", "\"\"\""), ("'''", "'''")]),
        "bash": hashLike(["if","then","else","elif","fi","for","in","do","done","while","case","esac","function","return","echo","export","local","source","exit","cd","set"], quotes: "\"'`"),
        "ruby": hashLike(["def","class","module","if","elsif","else","end","for","while","do","return","require","include","attr_accessor","yield","begin","rescue","ensure","raise","true","false","nil","self","puts"]),
        "perl": hashLike(["sub","my","our","local","if","elsif","else","unless","for","foreach","while","return","use","package","require","last","next","undef"]),
        "r": hashLike(["function","if","else","for","while","repeat","return","library","require","TRUE","FALSE","NULL","NA","Inf","in","next","break"], quotes: "\"'`"),
        "elixir": hashLike(["def","defmodule","defp","do","end","if","else","cond","case","fn","when","import","alias","require","use","true","false","nil"]),
        "yaml": hashLike([ "true","false","null","yes","no","on","off"]),
        "toml": hashLike(["true","false"]),
        "dockerfile": hashLike(["FROM","RUN","CMD","LABEL","EXPOSE","ENV","ADD","COPY","ENTRYPOINT","VOLUME","USER","WORKDIR","ARG","HEALTHCHECK","SHELL","AS"]),
        "makefile": hashLike(["include","ifeq","ifneq","ifdef","ifndef","else","endif","define","endef","export",".PHONY"]),
        "powershell": Lang(kw: ["function","param","if","else","elseif","foreach","for","while","return","try","catch","finally","throw","switch","begin","process","end","true","false","null"],
                           line: ["#"], block: [("<#", "#>")], quotes: "\"'"),
        "ini": Lang(kw: ["true","false"], line: [";", "#"], block: [], quotes: "\"'"),

        "sql": Lang(kw: ["select","from","where","insert","into","values","update","set","delete","create","table","alter","drop","index","join","left","right","inner","outer","on","group","order","by","having","limit","offset","as","and","or","not","null","distinct","union","primary","key","foreign","references","default","case","when","then","end"],
                    line: ["--"], block: [("/*", "*/")], quotes: "\"'`"),
        "lua": Lang(kw: ["function","local","if","then","else","elseif","end","for","while","do","repeat","until","return","break","nil","true","false","and","or","not","in"],
                    line: ["--"], block: [("--[[", "]]")], quotes: "\"'"),
        "haskell": Lang(kw: ["module","import","where","let","in","if","then","else","case","of","data","type","newtype","class","instance","deriving","do","True","False"],
                        line: ["--"], block: [("{-", "-}")], quotes: "\"'", caps: true),

        "html": Lang(kw: [], line: [], block: [("<!--", "-->")], quotes: "\"'"),
        "xml": Lang(kw: [], line: [], block: [("<!--", "-->")], quotes: "\"'"),
        "css": Lang(kw: ["important","media","import","keyframes","supports","from","to"], line: [], block: [("/*", "*/")], quotes: "\"'"),
        "diff": Lang(kw: [], line: [], block: [], quotes: "", lineShaped: true),
    ]

    /// Aliases as people actually write them in a fence, mapped onto the table above.
    private static let aliases: [String: String] = [
        "javascript": "js", "jsx": "js", "mjs": "js", "cjs": "js", "node": "js",
        "typescript": "ts", "tsx": "ts",
        "py": "python", "python3": "python",
        "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash", "terminal": "bash",
        "golang": "go", "rs": "rust", "kt": "kotlin", "rb": "ruby",
        "c++": "cpp", "cc": "cpp", "hpp": "cpp", "cxx": "cpp",
        "c#": "csharp", "cs": "csharp",
        "objective-c": "objc", "objectivec": "objc",
        "yml": "yaml", "docker": "dockerfile", "make": "makefile",
        "ps1": "powershell", "pwsh": "powershell",
        "postgres": "sql", "postgresql": "sql", "mysql": "sql", "sqlite": "sql", "psql": "sql",
        "cfg": "ini", "conf": "ini", "editorconfig": "ini",
        "htm": "html", "svg": "xml", "plist": "xml",
        "scss": "css", "less": "css",
        "patch": "diff", "hs": "haskell", "ex": "elixir", "exs": "elixir", "pl": "perl",
        "json5": "json", "jsonc": "json",
    ]

    private static func lang(for raw: String?) -> Lang? {
        guard let l = raw?.lowercased() else { return nil }
        return langs[aliases[l] ?? l]
    }

    // MARK: - Tokenizer

    private static let identifierExtras: Set<unichar> = [95, 36]   // _ $

    static func highlight(_ code: String, language: String?, theme: RenderTheme) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [.font: theme.codeFont, .foregroundColor: theme.textColor]
        let result = NSMutableAttributedString(string: code, attributes: base)
        guard let lang = lang(for: language) else { return result }   // plain fallback
        let p = Palette()
        let ns = code as NSString
        let n = ns.length

        func paint(_ from: Int, _ to: Int, _ c: NSColor) {
            guard to > from else { return }
            result.addAttribute(.foregroundColor, value: c, range: NSRange(location: from, length: to - from))
        }
        func matches(_ token: String, at k: Int) -> Bool {
            let t = token as NSString
            guard t.length > 0, k + t.length <= n else { return false }
            for j in 0..<t.length where ns.character(at: k + j) != t.character(at: j) { return false }
            return true
        }
        func isDigit(_ c: unichar) -> Bool { c >= 48 && c <= 57 }
        func isWordStart(_ c: unichar) -> Bool {
            (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || identifierExtras.contains(c) || c > 127
        }
        func isWord(_ c: unichar) -> Bool { isWordStart(c) || isDigit(c) }

        if lang.lineShaped { return diffHighlight(result, ns, p) }

        var i = 0
        while i < n {
            let c = ns.character(at: i)

            if lang.line.contains(where: { matches($0, at: i) }) {
                var j = i
                while j < n && ns.character(at: j) != 10 { j += 1 }
                paint(i, j, p.comment); i = j; continue
            }
            if let b = lang.block.first(where: { matches($0.0, at: i) }) {
                var j = i + (b.0 as NSString).length
                while j < n && !matches(b.1, at: j) { j += 1 }
                j = min(n, j + (b.1 as NSString).length)
                paint(i, j, p.comment); i = j; continue
            }
            if let r = lang.raw.first(where: { matches($0.0, at: i) }) {
                var j = i + (r.0 as NSString).length
                while j < n && !matches(r.1, at: j) { j += 1 }
                j = min(n, j + (r.1 as NSString).length)
                paint(i, j, p.string); i = j; continue
            }
            if lang.quotes.utf16.contains(c) {
                // Stop a runaway at the line end (except for backticks, which legitimately span
                // lines) so one stray quote can't paint the rest of the block red.
                let multiline = (c == 96)
                var j = i + 1
                while j < n {
                    let d = ns.character(at: j)
                    if d == 92 { j += 2; continue }                  // escape
                    if d == c { j += 1; break }
                    if d == 10 && !multiline { break }
                    j += 1
                }
                paint(i, min(j, n), p.string); i = min(j, n); continue
            }
            if isDigit(c) {
                var j = i
                while j < n, isWord(ns.character(at: j)) || ns.character(at: j) == 46 { j += 1 }
                paint(i, j, p.number); i = j; continue
            }
            if isWordStart(c) {
                var j = i
                while j < n, isWord(ns.character(at: j)) { j += 1 }
                let word = ns.substring(with: NSRange(location: i, length: j - i))
                if lang.kw.contains(word) {
                    paint(i, j, p.keyword)
                } else if lang.caps, let f = word.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(f) {
                    paint(i, j, p.type)
                }
                i = j; continue
            }
            i += 1
        }
        return result
    }

    /// Diffs are line-shaped, not token-shaped: what matters is which side a line is on.
    private static func diffHighlight(_ result: NSMutableAttributedString, _ ns: NSString,
                                      _ p: Palette) -> NSMutableAttributedString {
        ns.enumerateSubstrings(in: NSRange(location: 0, length: ns.length),
                               options: [.byLines, .substringNotRequired]) { _, range, _, _ in
            guard range.length > 0 else { return }
            let head = ns.character(at: range.location)
            let color: NSColor?
            switch head {
            case 43: color = ns.substring(with: range).hasPrefix("+++") ? p.comment : p.added      // +
            case 45: color = ns.substring(with: range).hasPrefix("---") ? p.comment : p.removed    // -
            case 64: color = p.keyword                                                             // @@ hunk
            default: color = nil
            }
            if let color { result.addAttribute(.foregroundColor, value: color, range: range) }
        }
        return result
    }
}

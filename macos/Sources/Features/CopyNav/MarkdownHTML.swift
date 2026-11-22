import Foundation

/// Safe Markdown (CommonMark core + GFM tables, strikethrough, autolinks) to theme-neutral
/// semantic HTML for the pasteboard.
///
/// Safety is by construction: every text run is HTML-escaped, raw HTML is never passed
/// through, and hrefs are emitted only for http, https and mailto. `file:` links become
/// `<code>basename</code>`; `ghostty-phil:` and other schemes keep only their text.
///
/// Not a full CommonMark implementation (no reference links, setext headings or
/// indented code blocks); it targets the Markdown `ag` renders. Kept in-tree rather
/// than adding a cmark-gfm package to the Xcode project.
enum MarkdownHTML {
    static func render(_ markdown: String) -> String {
        let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        return renderBlocks(lines[...])
    }

    // MARK: Blocks

    private static func renderBlocks(_ lines: ArraySlice<String>) -> String {
        var out = ""
        var i = lines.startIndex
        while i < lines.endIndex {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }

            if let fence = Fence(line) {
                var j = i + 1
                var body: [String] = []
                while j < lines.endIndex, !fence.closes(lines[j]) {
                    body.append(stripIndent(lines[j], upTo: fence.indent))
                    j += 1
                }
                let cls = fence.lang.isEmpty ? "" : " class=\"language-\(escape(fence.lang))\""
                out += "<pre><code\(cls)>\(escape(body.joined(separator: "\n")))\(body.isEmpty ? "" : "\n")</code></pre>\n"
                i = min(j + 1, lines.endIndex)
                continue
            }

            if let (level, text) = heading(line) {
                out += "<h\(level)>\(inline(text))</h\(level)>\n"
                i += 1
                continue
            }

            if isRule(line) {
                out += "<hr>\n"
                i += 1
                continue
            }

            if quoteContent(line) != nil {
                var inner: [String] = []
                while i < lines.endIndex, let q = quoteContent(lines[i]) ?? lazyLine(lines[i], inner) {
                    inner.append(q)
                    i += 1
                }
                out += "<blockquote>\n\(renderBlocks(inner[...]))</blockquote>\n"
                continue
            }

            if i + 1 < lines.endIndex, line.contains("|"), let aligns = delimiterRow(lines[i + 1]) {
                let header = cells(line)
                if header.count == aligns.count {
                    var rows: [[String]] = []
                    var j = i + 2
                    while j < lines.endIndex, !isBlank(lines[j]), lines[j].contains("|") {
                        rows.append(cells(lines[j]))
                        j += 1
                    }
                    out += table(header, aligns, rows)
                    i = j
                    continue
                }
            }

            if let marker = ListMarker(line) {
                let (html, next) = list(lines, from: i, marker)
                out += html
                i = next
                continue
            }

            var para: [String] = [line]
            i += 1
            while i < lines.endIndex, !isBlank(lines[i]), !startsBlock(lines[i]) {
                para.append(lines[i])
                i += 1
            }
            out += "<p>\(paragraph(para))</p>\n"
        }
        return out
    }

    /// Joins paragraph lines; two trailing spaces or a trailing backslash is a hard break.
    private static func paragraph(_ lines: [String]) -> String {
        var parts: [String] = []
        for (n, raw) in lines.enumerated() {
            var line = raw.drop(while: { $0 == " " || $0 == "\t" })
            var hard = false
            if n < lines.count - 1 {
                if line.hasSuffix("  ") { hard = true } else if line.hasSuffix("\\") { hard = true; line = line.dropLast() }
            }
            while line.last == " " || line.last == "\t" { line = line.dropLast() }
            parts.append(String(line) + (hard ? "\u{0}" : ""))
        }
        return inline(parts.joined(separator: "\n")).replacingOccurrences(of: "\u{0}\n", with: "<br>\n")
    }

    private static func startsBlock(_ line: String) -> Bool {
        Fence(line) != nil || heading(line) != nil || isRule(line) || quoteContent(line) != nil
            || ListMarker(line) != nil
    }

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " || $0 == "\t" } }

    private static func leadingSpaces(_ line: String) -> Int {
        var n = 0
        for c in line { if c == " " { n += 1 } else if c == "\t" { n += 4 - n % 4 } else { break } }
        return n
    }

    private static func stripIndent(_ line: String, upTo n: Int) -> String {
        var dropped = 0
        var idx = line.startIndex
        while idx < line.endIndex, dropped < n, line[idx] == " " { dropped += 1; idx = line.index(after: idx) }
        return String(line[idx...])
    }

    private struct Fence {
        let char: Character
        let count: Int
        let indent: Int
        let lang: String

        init?(_ line: String) {
            indent = MarkdownHTML.leadingSpaces(line)
            guard indent < 4 else { return nil }
            let rest = line.drop(while: { $0 == " " })
            guard let c = rest.first, c == "`" || c == "~" else { return nil }
            let run = rest.prefix(while: { $0 == c }).count
            guard run >= 3 else { return nil }
            let info = rest.dropFirst(run).trimmingCharacters(in: .whitespaces)
            if c == "`", info.contains("`") { return nil }
            char = c
            count = run
            let word = info.prefix(while: { !$0.isWhitespace })
            lang = String(word.filter { $0.isLetter || $0.isNumber || "+-_.#".contains($0) })
        }

        func closes(_ line: String) -> Bool {
            guard MarkdownHTML.leadingSpaces(line) < 4 else { return false }
            let rest = line.trimmingCharacters(in: .whitespaces)
            return rest.count >= count && rest.allSatisfy { $0 == char }
        }
    }

    private static func heading(_ line: String) -> (Int, String)? {
        guard leadingSpaces(line) < 4 else { return nil }
        let rest = line.drop(while: { $0 == " " })
        let level = rest.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " || after.first == "\t" else { return nil }
        var text = after.trimmingCharacters(in: .whitespaces)
        // Optional closing sequence.
        if let r = text.range(of: #"(^|\s)#+$"#, options: .regularExpression) {
            text = String(text[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return (level, text)
    }

    private static func isRule(_ line: String) -> Bool {
        guard leadingSpaces(line) < 4 else { return false }
        let chars = line.filter { $0 != " " && $0 != "\t" }
        guard chars.count >= 3, let c = chars.first, "-*_".contains(c) else { return false }
        return chars.allSatisfy { $0 == c }
    }

    private static func quoteContent(_ line: String) -> String? {
        guard leadingSpaces(line) < 4 else { return nil }
        let rest = line.drop(while: { $0 == " " })
        guard rest.first == ">" else { return nil }
        var body = rest.dropFirst()
        if body.first == " " { body = body.dropFirst() }
        return String(body)
    }

    /// Lazy continuation of a quoted paragraph.
    private static func lazyLine(_ line: String, _ inner: [String]) -> String? {
        guard let last = inner.last, !isBlank(last), !isBlank(line), !startsBlock(line) else { return nil }
        return line
    }

    // MARK: Lists

    private struct ListMarker {
        let indent: Int
        let ordered: Bool
        let bullet: Character
        let start: Int
        /// Column where item content starts.
        let contentIndent: Int
        let content: String

        init?(_ line: String) {
            indent = MarkdownHTML.leadingSpaces(line)
            guard indent < 16 else { return nil }
            let rest = line.drop(while: { $0 == " " || $0 == "\t" })
            var markerLen: Int
            if let c = rest.first, "-*+".contains(c) {
                ordered = false
                bullet = c
                start = 1
                markerLen = 1
            } else {
                let digits = rest.prefix(while: \.isNumber)
                guard (1...9).contains(digits.count), let d = rest.dropFirst(digits.count).first,
                      d == "." || d == ")" else { return nil }
                ordered = true
                bullet = d
                start = Int(digits) ?? 1
                markerLen = digits.count + 1
            }
            let after = rest.dropFirst(markerLen)
            if after.isEmpty {
                content = ""
                contentIndent = indent + markerLen + 1
                return
            }
            guard after.first == " " || after.first == "\t" else { return nil }
            let spaces = min(after.prefix(while: { $0 == " " }).count, 4)
            content = String(after.dropFirst(max(spaces, 1)))
            contentIndent = indent + markerLen + max(spaces, 1)
            // A rule like "- - -" is not a list.
            if !ordered, MarkdownHTML.isRule(line) { return nil }
        }

        func sameList(_ other: ListMarker) -> Bool { ordered == other.ordered && bullet == other.bullet }
    }

    private static func list(_ lines: ArraySlice<String>, from start: Int, _ first: ListMarker) -> (String, Int) {
        var items: [[String]] = []
        var i = start
        var loose = false
        var sawBlank = false
        var contentIndent = first.contentIndent
        while i < lines.endIndex {
            let line = lines[i]
            if let m = ListMarker(line), m.indent < contentIndent, m.indent <= first.indent + 3 {
                guard m.sameList(first) else { break }
                if sawBlank, !items.isEmpty { loose = true }
                items.append([m.content])
                contentIndent = m.contentIndent
                sawBlank = false
                i += 1
                continue
            }
            if isBlank(line) {
                sawBlank = true
                items[items.count - 1].append("")
                i += 1
                continue
            }
            if leadingSpaces(line) >= contentIndent {
                items[items.count - 1].append(stripIndent(line, upTo: contentIndent))
                sawBlank = false
                i += 1
                continue
            }
            // Lazy paragraph continuation.
            if !sawBlank, !startsBlock(line) {
                items[items.count - 1].append(line.trimmingCharacters(in: .whitespaces))
                i += 1
                continue
            }
            break
        }
        // Trailing blanks don't belong to the list.
        while let last = items.last?.last, isBlank(last) { items[items.count - 1].removeLast() }
        if !loose {
            loose = items.contains { item in
                item.indices.dropLast().contains { isBlank(item[$0]) && !isBlank(item[$0 + 1]) && ListMarker(item[$0 + 1]) == nil }
            }
        }

        let tag = first.ordered ? "ol" : "ul"
        var out = first.ordered && first.start != 1 ? "<ol start=\"\(first.start)\">\n" : "<\(tag)>\n"
        for item in items {
            var body = renderBlocks(item[...])
            if !loose { body = tighten(body) }
            out += "<li>\(body)</li>\n"
        }
        out += "</\(tag)>\n"
        return (out, i)
    }

    /// Tight list items show paragraphs without `<p>`.
    private static func tighten(_ html: String) -> String {
        var s = html
        s = s.replacingOccurrences(of: #"<p>([\s\S]*?)</p>\n"#, with: "$1\n", options: .regularExpression)
        while s.hasSuffix("\n") { s.removeLast() }
        return s
    }

    // MARK: Tables

    private enum Align { case none, left, center, right }

    private static func delimiterRow(_ line: String) -> [Align]? {
        let parts = cells(line)
        guard !parts.isEmpty else { return nil }
        var aligns: [Align] = []
        for p in parts {
            let t = p.trimmingCharacters(in: .whitespaces)
            guard t.range(of: #"^:?-+:?$"#, options: .regularExpression) != nil else { return nil }
            switch (t.hasPrefix(":"), t.hasSuffix(":")) {
            case (true, true): aligns.append(.center)
            case (true, false): aligns.append(.left)
            case (false, true): aligns.append(.right)
            default: aligns.append(.none)
            }
        }
        return aligns
    }

    /// Splits a table row on unescaped pipes outside code spans.
    private static func cells(_ line: String) -> [String] {
        var t = line.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|"), !t.hasSuffix("\\|") { t.removeLast() }
        var out: [String] = []
        var cur = ""
        var inCode = false
        var prev: Character = " "
        for c in t {
            if c == "`" { inCode.toggle() }
            if c == "|", !inCode, prev != "\\" {
                out.append(cur.trimmingCharacters(in: .whitespaces))
                cur = ""
            } else if c == "|", prev == "\\" {
                cur.removeLast()
                cur.append(c)
            } else {
                cur.append(c)
            }
            prev = c
        }
        out.append(cur.trimmingCharacters(in: .whitespaces))
        return out
    }

    private static func table(_ header: [String], _ aligns: [Align], _ rows: [[String]]) -> String {
        func attr(_ a: Align) -> String {
            switch a {
            case .none: return ""
            case .left: return " align=\"left\""
            case .center: return " align=\"center\""
            case .right: return " align=\"right\""
            }
        }
        var out = "<table>\n<thead>\n<tr>"
        for (n, h) in header.enumerated() { out += "<th\(attr(aligns[n]))>\(inline(h))</th>" }
        out += "</tr>\n</thead>\n"
        if !rows.isEmpty {
            out += "<tbody>\n"
            for row in rows {
                out += "<tr>"
                for n in 0..<aligns.count { out += "<td\(attr(aligns[n]))>\(n < row.count ? inline(row[n]) : "")</td>" }
                out += "</tr>\n"
            }
            out += "</tbody>\n"
        }
        return out + "</table>\n"
    }

    // MARK: Inline

    static func inline(_ text: String) -> String {
        var p = InlineParser(Array(text))
        return p.parse(until: nil)
    }

    private struct InlineParser {
        let c: [Character]
        var i = 0

        init(_ c: [Character]) { self.c = c }

        mutating func parse(until close: [Character]?) -> String {
            var out = ""
            while i < c.count {
                if let close, matches(close, at: i) { return out }
                let ch = c[i]
                switch ch {
                case "\\":
                    if i + 1 < c.count, c[i + 1].isASCII, c[i + 1].isPunctuation || c[i + 1].isSymbol {
                        out += MarkdownHTML.escape(String(c[i + 1]))
                        i += 2
                    } else {
                        out += "\\"
                        i += 1
                    }
                case "`":
                    if let code = codeSpan() { out += code } else { out += "`"; i += 1 }
                case "!" where i + 1 < c.count && c[i + 1] == "[":
                    if let (text, url) = linkAt(i + 1) {
                        out += MarkdownHTML.link(text: text, url: url)
                    } else {
                        out += "!"
                        i += 1
                    }
                case "[":
                    if let (text, url) = linkAt(i) { out += MarkdownHTML.link(text: text, url: url) } else { out += "["; i += 1 }
                case "<":
                    if let auto = autolink() { out += auto } else { out += "&lt;"; i += 1 }
                case "*", "_", "~":
                    if let em = emphasis() { out += em } else { out += MarkdownHTML.escape(String(ch)); i += 1 }
                case "h", "w":
                    if let bare = bareURL() { out += bare } else { out += String(ch); i += 1 }
                default:
                    out += MarkdownHTML.escape(String(ch))
                    i += 1
                }
            }
            return out
        }

        func matches(_ s: [Character], at k: Int) -> Bool {
            k + s.count <= c.count && Array(c[k..<k + s.count]) == s
        }

        mutating func codeSpan() -> String? {
            let run = c[i...].prefix(while: { $0 == "`" }).count
            var k = i + run
            while k < c.count {
                if c[k] == "`" {
                    let r = c[k...].prefix(while: { $0 == "`" }).count
                    if r == run {
                        var body = String(c[(i + run)..<k]).replacingOccurrences(of: "\n", with: " ")
                        if body.count >= 2, body.first == " ", body.last == " ", body.contains(where: { $0 != " " }) {
                            body = String(body.dropFirst().dropLast())
                        }
                        i = k + r
                        return "\(MarkdownHTML.codeOpen)\(MarkdownHTML.escape(body))</code>"
                    }
                    k += r
                } else {
                    k += 1
                }
            }
            return nil
        }

        /// `[text](url "title")` starting at the `[`; advances past it.
        mutating func linkAt(_ open: Int) -> (String, String)? {
            var depth = 0
            var k = open
            var close = -1
            while k < c.count {
                if c[k] == "\\" { k += 2; continue }
                if c[k] == "`", let end = c[(k + 1)...].firstIndex(of: "`") { k = end + 1; continue }
                if c[k] == "[" { depth += 1 }
                if c[k] == "]" { depth -= 1; if depth == 0 { close = k; break } }
                k += 1
            }
            guard close > 0, close + 1 < c.count, c[close + 1] == "(" else { return nil }
            var j = close + 2
            var parens = 0
            var dest = ""
            while j < c.count, c[j] == " " { j += 1 }
            if j < c.count, c[j] == "<" {
                guard let end = c[j...].firstIndex(of: ">") else { return nil }
                dest = String(c[(j + 1)..<end])
                j = end + 1
            } else {
                while j < c.count, !c[j].isWhitespace {
                    if c[j] == "(" { parens += 1 }
                    if c[j] == ")" { if parens == 0 { break }; parens -= 1 }
                    dest.append(c[j])
                    j += 1
                }
            }
            while j < c.count, c[j] == " " { j += 1 }
            if j < c.count, c[j] == "\"" || c[j] == "'" {
                let q = c[j]
                guard let end = c[(j + 1)...].firstIndex(of: q) else { return nil }
                j = end + 1
                while j < c.count, c[j] == " " { j += 1 }
            }
            guard j < c.count, c[j] == ")" else { return nil }
            var sub = InlineParser(Array(c[(open + 1)..<close]))
            let text = sub.parse(until: nil)
            i = j + 1
            return (text, dest)
        }

        mutating func autolink() -> String? {
            guard let end = c[(i + 1)...].firstIndex(of: ">") else { return nil }
            let body = String(c[(i + 1)..<end])
            guard !body.contains(where: { $0.isWhitespace || $0 == "<" }) else { return nil }
            if body.range(of: #"^[A-Za-z][A-Za-z0-9+.-]{1,31}:"#, options: .regularExpression) != nil {
                i = end + 1
                return MarkdownHTML.link(text: MarkdownHTML.escape(body), url: body)
            }
            if body.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil {
                i = end + 1
                return MarkdownHTML.link(text: MarkdownHTML.escape(body), url: "mailto:" + body)
            }
            return nil
        }

        /// GFM extended autolinks: `https://…`, `http://…`, `www.…` at a word start.
        mutating func bareURL() -> String? {
            if i > 0, c[i - 1].isLetter || c[i - 1].isNumber { return nil }
            let rest = String(c[i..<min(c.count, i + 8)]).lowercased()
            guard rest.hasPrefix("https://") || rest.hasPrefix("http://") || rest.hasPrefix("www.") else { return nil }
            var k = i
            while k < c.count, !c[k].isWhitespace, c[k] != "<" { k += 1 }
            // Trailing punctuation and unbalanced closing parens are not part of the link.
            while k > i, ".,:;!?\"'*_~".contains(c[k - 1]) { k -= 1 }
            if k > i, c[k - 1] == ")" {
                let s = c[i..<k]
                if s.filter({ $0 == ")" }).count > s.filter({ $0 == "(" }).count { k -= 1 }
            }
            let url = String(c[i..<k])
            guard url.count > (url.lowercased().hasPrefix("www.") ? 4 : 8) else { return nil }
            i = k
            let href = url.lowercased().hasPrefix("www.") ? "http://" + url : url
            return MarkdownHTML.link(text: MarkdownHTML.escape(url), url: href)
        }

        mutating func emphasis() -> String? {
            let ch = c[i]
            let run = c[i...].prefix(while: { $0 == ch }).count
            let n: Int
            let tag: String
            if ch == "~" {
                guard run == 2 || run == 1 else { return nil }
                n = run
                tag = "del"
            } else if run >= 2 {
                n = 2
                tag = "strong"
            } else {
                n = 1
                tag = "em"
            }
            let open = i + n
            guard open < c.count, !c[open].isWhitespace else { return nil }
            // Intraword underscores are literal.
            if ch == "_", i > 0, c[i - 1].isLetter || c[i - 1].isNumber { return nil }
            let delim = Array(repeating: ch, count: n)
            // Find a closing run not preceded by whitespace.
            var k = open
            while k < c.count {
                if c[k] == "\\" { k += 2; continue }
                if c[k] == "`", let end = c[(k + 1)...].firstIndex(of: "`") { k = end + 1; continue }
                if matches(delim, at: k), !c[k - 1].isWhitespace, k > open {
                    let after = k + n
                    let nextSame = after < c.count && c[after] == ch
                    let closesWord = ch != "_" || after >= c.count || !(c[after].isLetter || c[after].isNumber)
                    if !(n == 1 && nextSame) || ch == "~", closesWord {
                        var sub = InlineParser(Array(c[open..<k]))
                        let inner = sub.parse(until: nil)
                        i = after
                        return "<\(tag)>\(inner)</\(tag)>"
                    }
                    k += nextSame ? 2 : 1
                    continue
                }
                k += 1
            }
            return nil
        }
    }

    // MARK: Links

    enum Href: Equatable {
        case link(String)
        case file(basename: String)
        case none
    }

    static func classify(_ url: String) -> Href {
        // Browsers ignore embedded whitespace and controls when reading a scheme.
        let squeezed = String(url.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }.map(Character.init))
        guard let colon = squeezed.firstIndex(of: ":") else { return .none }
        let scheme = squeezed[..<colon].lowercased()
        guard scheme.range(of: #"^[a-z][a-z0-9+.-]*$"#, options: .regularExpression) != nil else { return .none }
        switch scheme {
        case "http", "https", "mailto":
            return .link(url.trimmingCharacters(in: .whitespaces))
        case "file":
            let path = URL(string: squeezed)?.path ?? String(squeezed.dropFirst(5))
            let base = (path as NSString).lastPathComponent
            return base.isEmpty ? .none : .file(basename: base)
        default:
            return .none
        }
    }

    /// `text` is already HTML.
    static func link(text: String, url: String) -> String {
        switch classify(url) {
        case .link(let href):
            return "<a href=\"\(escape(href))\">\(text)</a>"
        case .file(let base):
            // Notes drops file: hrefs; show the name. Keep distinct link text too.
            let plainText = text.replacingOccurrences(of: #"<[^>]*>"#, with: "", options: .regularExpression)
            if plainText.isEmpty || plainText == escape(url) || plainText.hasSuffix(escape(base)) {
                return "\(codeOpen)\(escape(base))</code>"
            }
            return "\(text) (\(codeOpen)\(escape(base))</code>)"
        case .none:
            return text
        }
    }

    /// Escapes per Unicode scalar: a `<` followed by a combining mark is one Character
    /// that compares unequal to "<", so Character-wise escaping would let it through.
    /// Inline code. Apple Notes drops bare `<code>` to the body font, so it carries an
    /// explicit monospace family (the only inline style emitted; no colors).
    static let codeOpen = "<code style=\"font-family:Menlo,monospace\">"

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.utf8.count)
        for scalar in s.unicodeScalars {
            switch scalar {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

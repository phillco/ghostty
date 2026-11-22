import AppKit
import Darwin
import Foundation
import Testing
@testable import Ghostty

private let schemes: Set<String> = ["ghostty-phil"]

struct PhilLinkTests {
    @Test func copyLinksAreByReferenceOnly() {
        #expect(PhilLink.parse("ghostty-phil://copy?pid=42&gen=ab12&seg=3&block=1", schemes: schemes)
            == .copy(CopyRef(pid: 42, gen: "ab12", seg: 3, block: 1)))
        #expect(PhilLink.parse("Ghostty-Phil://copy?pid=42&gen=ab12&turn=2", schemes: schemes)
            == .copy(CopyRef(pid: 42, gen: "ab12", turn: 2)))
        // Unverifiable inline payloads, missing or malformed ids, ambiguous targets.
        #expect(PhilLink.parse("ghostty-phil://copy?text=hello&fmt=plain", schemes: schemes) == nil)
        #expect(PhilLink.parse("ghostty-phil://copy?pid=42&seg=3", schemes: schemes) == nil)
        #expect(PhilLink.parse("ghostty-phil://copy?pid=42&gen=zz&seg=3", schemes: schemes) == nil)
        #expect(PhilLink.parse("ghostty-phil://copy?pid=-1&gen=ab&seg=3", schemes: schemes) == nil)
        #expect(PhilLink.parse("ghostty-phil://copy?pid=42&gen=ab&seg=3&turn=1", schemes: schemes) == nil)
        #expect(PhilLink.parse("ghostty-phil://copy?pid=42&gen=ab&turn=1&block=2", schemes: schemes) == nil)
        #expect(PhilLink.parse("other://copy?pid=42&gen=ab&seg=3", schemes: schemes) == nil)
    }

    @Test func msgLinks() throws {
        let raw = "ghostty-phil://msg?pid=7&gen=ff&seg=4&sid=S&rec=R&scroll=1"
        guard case .msg(let m)? = PhilLink.parse(raw, schemes: schemes) else {
            Issue.record("not a msg link")
            return
        }
        #expect(m.scroll && m.sid == "S" && m.rec == "R" && m.raw == raw)
        #expect(m.copyRef == CopyRef(pid: 7, gen: "ff", seg: 4))
        guard case .msg(let plain)? = PhilLink.parse("ghostty-phil://msg?sid=S&rec=R", schemes: schemes) else {
            Issue.record("not a msg link")
            return
        }
        #expect(!plain.scroll && plain.copyRef == nil)
    }

    @Test func externalOpensCannotCopy() throws {
        let copy = try #require(PhilLink.parse("ghostty-phil://copy?pid=1&gen=ab&seg=1", schemes: schemes))
        let msg = try #require(PhilLink.parse("ghostty-phil://msg?pid=1&gen=ab&seg=1", schemes: schemes))
        #expect(!copy.allowed(from: .externalOpen))
        #expect(copy.allowed(from: .surfaceClick))
        #expect(msg.allowed(from: .externalOpen))
        // Malformed copy links are still ours to refuse, not passed to other openers.
        #expect(PhilLink.isOurs("ghostty-phil://copy?text=hi", schemes: schemes))
        #expect(!PhilLink.isOurs("ghostty-phil://focus?tty=x", schemes: schemes))
        #expect(!PhilLink.isOurs("https://copy?x", schemes: schemes))
    }
}

struct ResolveRequestTests {
    @Test func selectionRequestMatchesWireContract() throws {
        let json = """
        {"flavor":"rich","anchor":"ghostty-phil://msg?pid=9&gen=ab&seg=3","cols":80,"startRow":2,"startCol":4,
         "endRow":5,"endCol":18,"rowWraps":[false,false,false,true,false,false],
         "spanned":[{"uri":"ghostty-phil://msg?pid=9&gen=ab&seg=4","relRow":4},
                    {"uri":"ghostty-phil://msg?pid=10&gen=ab&seg=5","relRow":5}],
         "selectedPlain":"hi"}
        """
        let snap = try JSONDecoder().decode(SelectionSnapshot.self, from: Data(json.utf8))
        let (pid, line) = try #require(ResolveRequest.selection(id: "r1", snap, schemes: schemes))
        #expect(pid == 9)
        #expect(line.last == 0x0A)
        let obj = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        #expect(obj["op"] as? String == "resolveCopy" && obj["mode"] as? String == "selection")
        #expect(obj["gen"] as? String == "ab" && obj["id"] as? String == "r1")
        #expect((obj["startAnchor"] as? [String: Any])?["seg"] as? Int == 3)
        // The other process's anchor is dropped.
        let spanned = try #require(obj["spannedAnchors"] as? [[String: Any]])
        #expect(spanned.count == 1 && spanned[0]["seg"] as? Int == 4 && spanned[0]["relRow"] as? Int == 4)
        #expect(obj["rowWraps"] as? [Bool] == [false, false, false, true, false, false])
        #expect(obj["endCol"] as? Int == 18 && obj["cols"] as? Int == 80 && obj["selectedPlain"] as? String == "hi")
    }

    @Test func refRequest() throws {
        let line = ResolveRequest.ref(id: "x", CopyRef(pid: 1, gen: "ab", seg: 3, block: 1))
        let obj = try #require(try JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        #expect(obj["mode"] as? String == "ref" && obj["seg"] as? Int == 3 && obj["block"] as? Int == 1)
        #expect(obj["turn"] == nil)
    }
}

struct ClarcReadyTests {
    private func ready(pid: Int32 = 42, tty: String? = "/dev/ttys012") -> Data {
        var obj: [String: Any] = ["v": 1, "pid": pid, "agent": "agy", "sessionId": "S1"]
        if let tty { obj["tty"] = tty }
        return (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
    }

    @Test func acceptsOwnMatchingEndpoint() throws {
        let e = try ClarcReady.check(data: ready(), ownerUID: 501, myUID: 501, pid: 42, tty: "/dev/ttys012")
        #expect(e.pid == 42 && e.sid == "S1" && e.tty == "ttys012")
        #expect(e.socketPath.hasSuffix("/claude-clarc-42.sock"))
        // Surface tty names may come with or without /dev/.
        #expect(throws: Never.self) {
            try ClarcReady.check(data: ready(), ownerUID: 501, myUID: 501, pid: 42, tty: "ttys012")
        }
    }

    @Test func rejectsForeignOwnerPidOrTty() {
        #expect(throws: CopyNavError.untrusted("ready owner 0")) {
            try ClarcReady.check(data: ready(), ownerUID: 0, myUID: 501, pid: 42, tty: "/dev/ttys012")
        }
        #expect(throws: CopyNavError.untrusted("pid mismatch")) {
            try ClarcReady.check(data: ready(pid: 43), ownerUID: 501, myUID: 501, pid: 42, tty: "/dev/ttys012")
        }
        #expect(throws: CopyNavError.untrusted("tty mismatch")) {
            try ClarcReady.check(data: ready(), ownerUID: 501, myUID: 501, pid: 42, tty: "/dev/ttys013")
        }
        #expect(throws: CopyNavError.untrusted("tty mismatch")) {
            try ClarcReady.check(data: ready(tty: nil), ownerUID: 501, myUID: 501, pid: 42, tty: "/dev/ttys012")
        }
        #expect(throws: CopyNavError.untrusted("tty mismatch")) {
            try ClarcReady.check(data: ready(), ownerUID: 501, myUID: 501, pid: 42, tty: nil)
        }
    }
}

/// A fake `ag` on a real Unix socket in a private directory.
private final class FakeAg {
    let dir: String
    let pid: Int32 = 4242
    private var listener: Int32 = -1

    init(tty: String, replies: @escaping (String) -> [String]) throws {
        dir = "/tmp/cnt-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let ready: [String: Any] = ["pid": pid, "tty": tty, "agent": "agy", "sid": "S1"]
        try JSONSerialization.data(withJSONObject: ready).write(to: URL(fileURLWithPath: "\(dir)/claude-clarc-\(pid).ready"))

        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = Array("\(dir)/claude-clarc-\(pid).sock".utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: path); $0[path.count] = 0 }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        listen(listener, 4)
        let fd = listener
        Thread.detachNewThread {
            let conn = accept(fd, nil, nil)
            guard conn >= 0 else { return }
            defer { close(conn) }
            var on: Int32 = 1
            setsockopt(conn, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var buf = [UInt8](repeating: 0, count: 65536)
            var got = Data()
            while !got.contains(0x0A) {
                let n = read(conn, &buf, buf.count)
                guard n > 0 else { return }
                got.append(contentsOf: buf[0..<n])
            }
            let request = String(bytes: got.prefix(while: { $0 != 0x0A }), encoding: .utf8) ?? ""
            for line in replies(request) {
                if line == "SLEEP" { usleep(200_000); continue }
                _ = (line + "\n").withCString { write(conn, $0, strlen($0)) }
            }
            usleep(300_000)
        }
    }

    deinit {
        close(listener)
        try? FileManager.default.removeItem(atPath: dir)
    }
}

@Suite(.serialized)
struct ClarcSocketTests {
    @Test func skipsStatePushesAndOtherIds() throws {
        let ag = try FakeAg(tty: "/dev/ttys099") { request in
            let id = (try? JSONSerialization.jsonObject(with: Data(request.utf8)) as? [String: Any])?["id"] as? String ?? ""
            return [
                #"{"event":"state","state":{"busy":false}}"#,
                #"{"id":"someone-else","ok":true,"markdown":"wrong"}"#,
                ##"{"id":"\##(id)","ok":true,"markdown":"# Hi","plain":"Hi","kind":"prose"}"##,
            ]
        }
        ClarcReady.directory = ag.dir
        defer { ClarcReady.directory = "/tmp" }
        let r = try CopyResolver.resolve(pid: ag.pid, tty: "ttys099",
                                         line: ResolveRequest.ref(id: "abc", CopyRef(pid: ag.pid, gen: "ab", seg: 1)),
                                         id: "abc", deadline: Date(timeIntervalSinceNow: 1))
        #expect(r.markdown == "# Hi" && r.plain == "Hi")
    }

    @Test func rejectsWrongTtyBeforeConnecting() throws {
        let ag = try FakeAg(tty: "/dev/ttys099") { _ in [] }
        ClarcReady.directory = ag.dir
        defer { ClarcReady.directory = "/tmp" }
        #expect(throws: CopyNavError.untrusted("tty mismatch")) {
            try CopyResolver.resolve(pid: ag.pid, tty: "/dev/ttys098", line: Data("{}\n".utf8), id: "x")
        }
    }

    @Test func timesOutWithinBudget() throws {
        let ag = try FakeAg(tty: "/dev/ttys099") { _ in ["SLEEP", #"{"id":"x","ok":true,"markdown":"late"}"#] }
        ClarcReady.directory = ag.dir
        defer { ClarcReady.directory = "/tmp" }
        let start = Date()
        #expect(throws: CopyNavError.timeout) {
            try CopyResolver.resolve(pid: ag.pid, tty: "ttys099", line: Data("{\"id\":\"x\"}\n".utf8), id: "x")
        }
        #expect(Date().timeIntervalSince(start) < 0.15)
    }

    @Test func chattyPeerStillTimesOut() throws {
        let ag = try FakeAg(tty: "/dev/ttys099") { _ in
            Array(repeating: #"{"event":"state","state":{}}"#, count: 20000)
        }
        ClarcReady.directory = ag.dir
        defer { ClarcReady.directory = "/tmp" }
        let start = Date()
        #expect(throws: CopyNavError.timeout) {
            try CopyResolver.resolve(pid: ag.pid, tty: "ttys099", line: Data("{\"id\":\"x\"}\n".utf8), id: "x")
        }
        #expect(Date().timeIntervalSince(start) < 0.15)
    }

    @Test func reusedPidNeedsMatchingSession() throws {
        let ag = try FakeAg(tty: "/dev/ttys099") { _ in [] }
        ClarcReady.directory = ag.dir
        defer { ClarcReady.directory = "/tmp" }
        #expect(ClarcReady.endpoint(pid: ag.pid)?.tty == "ttys099")
        #expect(ClarcReady.endpoint(pid: ag.pid, sid: "S1")?.tty == "ttys099")
        #expect(ClarcReady.endpoint(pid: ag.pid, sid: "other") == nil)
    }

    @Test func rejectedResponsesThrow() throws {
        let ag = try FakeAg(tty: "/dev/ttys099") { _ in [#"{"id":"x","ok":false,"reason":"stale_gen"}"#] }
        ClarcReady.directory = ag.dir
        defer { ClarcReady.directory = "/tmp" }
        #expect(throws: CopyNavError.rejected("stale_gen")) {
            try CopyResolver.resolve(pid: ag.pid, tty: "ttys099", line: Data("{\"id\":\"x\"}\n".utf8), id: "x",
                                     deadline: Date(timeIntervalSinceNow: 1))
        }
    }
}

struct MarkdownHTMLTests {
    @Test func escapesRawHTML() {
        let html = MarkdownHTML.render("<script>alert(1)</script>\n\nhi <b>x</b> & `<i>`")
        #expect(!html.contains("<script>") && !html.contains("<b>") && !html.contains("<i>"))
        #expect(html.contains("&lt;script&gt;") && html.contains("&amp;") && html.contains("<code style=\"font-family:Menlo,monospace\">&lt;i&gt;</code>"))
    }

    @Test func escapesPerScalar() {
        // "<" + combining acute is one Character but must still be escaped.
        #expect(MarkdownHTML.escape("<\u{301}b>\"\u{301}'&") == "&lt;\u{301}b&gt;&quot;\u{301}&#39;&amp;")
        let html = MarkdownHTML.render("<\u{301}script>x</script> [l](https://a.test/\"\u{301}onmouseover=x)")
        let scalars = Array(html.unicodeScalars)
        #expect(!zip(scalars, scalars.dropFirst()).contains { $0 == "<" && $1 == "\u{301}" })
        #expect(html.contains("https://a.test/&quot;\u{301}onmouseover=x"))
    }

    @Test func allowlistsLinkSchemes() {
        let html = MarkdownHTML.render("""
        [a](https://x.test/?q=1&r=2) [m](mailto:a@b.test) [j](javascript:alert(1)) [j2](JaVa\tScRiPt:alert(1))
        [d](data:text/html,x) [g](ghostty-phil://copy?pid=1&gen=ab&seg=1) [rel](./x) <javascript:alert(1)>
        """)
        #expect(html.contains(#"<a href="https://x.test/?q=1&amp;r=2">a</a>"#))
        #expect(html.contains(#"<a href="mailto:a@b.test">m</a>"#))
        #expect(!html.lowercased().contains("javascript:alert(1)\""))
        #expect(!html.contains("href=\"javascript") && !html.contains("href=\"data") && !html.contains("ghostty-phil"))
        #expect(html.components(separatedBy: "<a ").count == 3)
    }

    @Test func fileLinksBecomeBasenames() {
        #expect(MarkdownHTML.render("[file:///Users/me/src/main.go](file:///Users/me/src/main.go)")
            == "<p><code style=\"font-family:Menlo,monospace\">main.go</code></p>\n")
        #expect(MarkdownHTML.render("see [the config](file:///etc/x.toml)")
            == "<p>see the config (<code style=\"font-family:Menlo,monospace\">x.toml</code>)</p>\n")
    }

    @Test func semanticBlocks() {
        let md = """
        # Title

        Some **bold**, *em*, ~~gone~~ and `code`
        continued line.

        - one
        - two
          - nested

        1. first
        2. second

        > quoted

        ```go
        func main() {}
        ```

        | A | B |
        |:--|--:|
        | 1 | `x\\|y` |

        ---
        """
        let html = MarkdownHTML.render(md)
        #expect(html.contains("<h1>Title</h1>"))
        #expect(html.contains("<p>Some <strong>bold</strong>, <em>em</em>, <del>gone</del> and <code style=\"font-family:Menlo,monospace\">code</code>\ncontinued line.</p>"))
        #expect(html.contains("<ul>\n<li>one</li>\n<li>two\n<ul>\n<li>nested</li>\n</ul></li>\n</ul>"))
        #expect(html.contains("<ol>\n<li>first</li>\n<li>second</li>\n</ol>"))
        #expect(html.contains("<blockquote>\n<p>quoted</p>\n</blockquote>"))
        #expect(html.contains("<pre><code class=\"language-go\">func main() {}\n</code></pre>"))
        #expect(html.contains("<th align=\"left\">A</th><th align=\"right\">B</th>"))
        #expect(html.contains("<td align=\"right\"><code style=\"font-family:Menlo,monospace\">x|y</code></td>"))
        #expect(html.contains("<hr>"))
        // Theme-neutral: no inline styles or colors.
        // Theme-neutral: the only inline style is inline code's font family.
        #expect(!html.contains("color") && !html.contains("white-space"))
        #expect(html.components(separatedBy: "style=").count - 1
            == html.components(separatedBy: MarkdownHTML.codeOpen).count - 1)
        // Fenced code stays a plain <pre><code>.
        #expect(html.contains("<pre><code class=\"language-go\">"))
    }

    @Test func intrawordUnderscoresAndBareURLs() {
        #expect(MarkdownHTML.render("snake_case_name") == "<p>snake_case_name</p>\n")
        #expect(MarkdownHTML.render("go to https://x.test/a_b.")
            == "<p>go to <a href=\"https://x.test/a_b\">https://x.test/a_b</a>.</p>\n")
    }

    @Test func codeLanguageIsSanitized() {
        let html = MarkdownHTML.render("```js\" onload=\"x\nhi\n```")
        #expect(html.hasPrefix("<pre><code class=\"language-js\">"))
    }
}

@MainActor
struct RichClipTests {
    private func response(kind: String, plain: String = "p", markdown: String = "**m**") -> ResolveResponse {
        ResolveResponse(id: "1", ok: true, markdown: markdown, plain: plain, kind: kind, codeLang: nil, reason: nil)
    }

    @Test func plainTextIsContentAware() {
        #expect(RichClip(response(kind: "code", plain: "let x = 1")).plain == "let x = 1")
        #expect(RichClip(response(kind: "code", plain: "let x = 1", markdown: "```swift\nlet x = 1\n```"),
                         markdownPlain: true).plain == "```swift\nlet x = 1\n```")
        #expect(RichClip(response(kind: "prose")).plain == "p")
        #expect(RichClip(response(kind: "prose"), markdownPlain: true).plain == "**m**")
        #expect(RichClip(response(kind: "mixed")).html.contains("<strong>m</strong>"))
    }

    @Test func rtfCarriesNoForcedColors() throws {
        let rtf = try #require(RichClip(response(kind: "prose", markdown: "# Head\n\n**bold** `c`")).rtf())
        let text = try #require(String(bytes: rtf, encoding: .ascii))
        #expect(text.hasPrefix("{\\rtf"))
        #expect(!text.contains("\\cf1") && !text.contains("\\cb1") && !text.contains("\\strokec"))
        #expect(text.contains("bold"))
    }

    private func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("io.phillip.ghostty-phil.test.\(UUID().uuidString)"))
    }

    @Test func fallbackThenRichWrite() throws {
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        let ticket = CopyPasteboard.writePlain("plain fallback", html: "<b>term</b>", to: pb)
        #expect(pb.string(forType: .html) == "<b>term</b>")
        #expect(CopyPasteboard.commit(RichClip(response(kind: "prose")), to: pb, ticket: ticket))
        #expect(pb.string(forType: .string) == "p")
        #expect(pb.string(forType: RichClip.markdownType) == "**m**")
        #expect(pb.string(forType: .html)?.contains("<strong>m</strong>") == true)
        #expect(pb.data(forType: .rtf) != nil)
        #expect(pb.pasteboardItems?.count == 1)
    }

    @Test func markdownCopyWritesOnlyMarkdown() {
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        let ticket = CopyPasteboard.writePlain("plain fallback", to: pb)
        let clip = RichClip(response(kind: "prose", markdown: "# H\n\n`c`"), markdownPlain: true)
        #expect(CopyPasteboard.commit(clip, to: pb, ticket: ticket))
        #expect(pb.string(forType: .string) == "# H\n\n`c`")
        #expect(pb.string(forType: RichClip.markdownType) == "# H\n\n`c`")
        #expect(pb.data(forType: .html) == nil && pb.data(forType: .rtf) == nil)
    }

    @Test func otherAppsWriteWins() {
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        let ticket = CopyPasteboard.writePlain("plain fallback", to: pb)
        pb.clearContents()
        pb.setString("newer copy", forType: .string)
        #expect(!CopyPasteboard.commit(RichClip(response(kind: "prose")), to: pb, ticket: ticket))
        #expect(pb.string(forType: .string) == "newer copy")
    }

    @Test func newestCopyIntentWins() {
        let pb = scratchPasteboard()
        defer { pb.releaseGlobally() }
        let a = RichClip(response(kind: "prose", plain: "A"))
        let b = RichClip(response(kind: "prose", plain: "B"))

        // A then B clicked; A answers first, then B: B still lands.
        let ta = CopyPasteboard.ticket(for: pb)
        let tb = CopyPasteboard.ticket(for: pb)
        #expect(CopyPasteboard.commit(a, to: pb, ticket: ta))
        #expect(CopyPasteboard.commit(b, to: pb, ticket: tb))
        #expect(pb.string(forType: .string) == "B")

        // C then D clicked; D answers first: the late C is dropped.
        let tc = CopyPasteboard.ticket(for: pb)
        let td = CopyPasteboard.ticket(for: pb)
        #expect(CopyPasteboard.commit(b, to: pb, ticket: td))
        #expect(!CopyPasteboard.commit(a, to: pb, ticket: tc))
        #expect(pb.string(forType: .string) == "B")

        // A newer selection copy's plain fallback beats an older pending chip.
        let te = CopyPasteboard.ticket(for: pb)
        _ = CopyPasteboard.writePlain("selection", to: pb)
        #expect(!CopyPasteboard.commit(a, to: pb, ticket: te))
        #expect(pb.string(forType: .string) == "selection")
    }
}

struct ForegroundJobTests {
    @Test func readsOwnProcessAndGroup() throws {
        let me = try #require(ForegroundJob.process(getpid()))
        #expect(me.uid == getuid() && me.pgid == getpgrp() && !me.comm.isEmpty)
        #expect(!me.isAg)
        #expect(ForegroundJob.group(getpgrp()).contains { $0.pid == getpid() })
        // Not an ag, so never eligible for composer keys.
        #expect(!ForegroundJob.isOnly(agPID: getpid(), foregroundPGID: getpgrp(), tty: "ttys000"))
    }
}

struct ComposerKeyPolicyTests {
    @Test func onlyUnboundOrLocalPerformableCopyYields() {
        let y = ComposerKeyPolicy.yields
        #expect(y("x", false, false, false, false))
        #expect(y("c", true, true, false, true))
        // Another action on the key, a non-performable copy, or a copy that reaches
        // other surfaces keeps the key.
        #expect(!y("c", true, true, false, false))
        #expect(!y("c", true, false, false, true))
        #expect(!y("c", true, true, true, true))
        #expect(!y("x", true, true, false, false))
    }
}

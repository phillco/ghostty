import AppKit

/// One resolved copy as every pasteboard flavor, written as a single item so each
/// destination picks what suits it: HTML for Notes/Mail/Slack/Docs, RTF for AppKit text
/// views, Markdown for Markdown apps, plain for terminals and editors.
struct RichClip: Equatable {
    static let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")

    var html: String
    var markdown: String
    var plain: String
    /// Explicit Markdown copy: only the Markdown and plain-text flavors are written, so
    /// rich-text apps paste the Markdown source rather than rendering it.
    var markdownOnly: Bool

    /// `markdownPlain` is the explicit `copy_to_clipboard:markdown` flavor: plain text
    /// carries the Markdown, fences included. Otherwise code selections (`kind == "code"`)
    /// copy the bare code, unfenced, and everything else the unwrapped plain text.
    init(_ r: ResolveResponse, markdownPlain: Bool = false) {
        let markdown = r.markdown ?? ""
        self.markdown = markdown
        self.markdownOnly = markdownPlain
        self.html = "<meta charset=\"utf-8\">" + MarkdownHTML.render(markdown)
        if markdownPlain {
            plain = markdown
        } else if r.kind == "code", let code = r.plain {
            plain = code
        } else {
            plain = r.plain ?? markdown
        }
    }

    /// RTF from the HTML with no forced colors, so it follows the destination's theme.
    /// Uses AppKit's HTML importer, which must run on the main thread.
    @MainActor
    func rtf() -> Data? {
        let styled = "<style>body{font-family:-apple-system,Helvetica,sans-serif;font-size:13px}"
            + "pre,code{font-family:Menlo,monospace}</style>" + html
        guard let data = styled.data(using: .utf8),
              let attr = try? NSMutableAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html,
                          .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil) else { return nil }
        let all = NSRange(location: 0, length: attr.length)
        attr.removeAttribute(.foregroundColor, range: all)
        attr.removeAttribute(.backgroundColor, range: all)
        attr.removeAttribute(.strokeColor, range: all)
        attr.removeAttribute(.strokeWidth, range: all)
        return try? attr.data(from: all, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    @MainActor
    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        if !markdownOnly {
            item.setString(html, forType: .html)
            if let rtf = rtf() { item.setData(rtf, forType: .rtf) }
        }
        item.setString(markdown, forType: Self.markdownType)
        item.setString(plain, forType: .string)
        return item
    }
}

/// Orders our pasteboard writes. Each copy takes a ticket when it starts; its rich
/// write lands only if no newer copy of ours has written since and nothing outside
/// Ghostty has written since its ticket (our own writes don't count against it).
@MainActor
enum CopyPasteboard {
    struct Ticket {
        let seq: Int
        let changeCount: Int
        let pasteboard: NSPasteboard.Name
    }

    private struct State {
        var issued = 0
        /// Sequence of the newest copy that has written.
        var written = 0
        /// Change count right after our latest write.
        var ourChangeCount: Int?
    }

    private static var states: [NSPasteboard.Name: State] = [:]

    static func ticket(for pasteboard: NSPasteboard) -> Ticket {
        var st = states[pasteboard.name] ?? State()
        st.issued += 1
        states[pasteboard.name] = st
        return Ticket(seq: st.issued, changeCount: pasteboard.changeCount, pasteboard: pasteboard.name)
    }

    /// Writes the fallback for a new copy (plain text, and HTML if given) and returns
    /// its ticket.
    static func writePlain(_ text: String, html: String? = nil, to pasteboard: NSPasteboard) -> Ticket {
        let t = ticket(for: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let html { pasteboard.setString(html, forType: .html) }
        record(t, pasteboard)
        return Ticket(seq: t.seq, changeCount: pasteboard.changeCount, pasteboard: t.pasteboard)
    }

    /// Writes `clip` for the copy holding `ticket`, unless a newer copy of ours already
    /// wrote or another app wrote the pasteboard since the ticket.
    @discardableResult
    static func commit(_ clip: RichClip, to pasteboard: NSPasteboard, ticket: Ticket) -> Bool {
        // Build first (RTF conversion takes a while), then check and write back to back.
        let item = clip.pasteboardItem()
        let st = states[pasteboard.name] ?? State()
        guard ticket.seq >= st.written else { return false }
        let now = pasteboard.changeCount
        guard now == ticket.changeCount || now == st.ourChangeCount else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([item]) else { return false }
        record(ticket, pasteboard)
        return true
    }

    private static func record(_ t: Ticket, _ pasteboard: NSPasteboard) {
        var st = states[pasteboard.name] ?? State()
        st.written = max(st.written, t.seq)
        st.ourChangeCount = pasteboard.changeCount
        states[pasteboard.name] = st
    }
}

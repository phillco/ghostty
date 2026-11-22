import AppKit

/// One resolved copy as every pasteboard flavor, written as a single item so each
/// destination picks what suits it: HTML for Notes/Mail/Slack/Docs, RTF for AppKit text
/// views, Markdown for Markdown apps, plain for terminals and editors.
struct RichClip: Equatable {
    static let markdownType = NSPasteboard.PasteboardType("net.daringfireball.markdown")

    var html: String
    var markdown: String
    var plain: String

    /// `markdownPlain` is the `copy_to_clipboard:markdown` flavor: plain text carries the
    /// Markdown. Code selections (`kind == "code"`) always copy the bare code, unfenced.
    init(_ r: ResolveResponse, markdownPlain: Bool = false) {
        let markdown = r.markdown ?? ""
        self.markdown = markdown
        self.html = "<meta charset=\"utf-8\">" + MarkdownHTML.render(markdown)
        if r.kind == "code", let code = r.plain {
            plain = code
        } else if markdownPlain {
            plain = markdown
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
        return try? attr.data(from: all, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    @MainActor
    func pasteboardItem() -> NSPasteboardItem {
        let item = NSPasteboardItem()
        item.setString(html, forType: .html)
        if let rtf = rtf() { item.setData(rtf, forType: .rtf) }
        item.setString(markdown, forType: Self.markdownType)
        item.setString(plain, forType: .string)
        return item
    }
}

@MainActor
enum CopyPasteboard {
    /// Writes the plain fallback and returns the change count a later rich write must match.
    @discardableResult
    static func writePlain(_ text: String, to pasteboard: NSPasteboard) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        return pasteboard.changeCount
    }

    /// Replaces our plain fallback with `clip`, unless anything wrote the pasteboard since
    /// `changeCount` (a newer copy wins). Pass nil to write unconditionally.
    @discardableResult
    static func commit(_ clip: RichClip, to pasteboard: NSPasteboard, ifUnchangedSince changeCount: Int?) -> Bool {
        if let changeCount, pasteboard.changeCount != changeCount { return false }
        pasteboard.clearContents()
        return pasteboard.writeObjects([clip.pasteboardItem()])
    }
}

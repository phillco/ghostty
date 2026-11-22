import AppKit
import GhosttyKit

/// `ghostty-phil://copy` and `ghostty-phil://msg` links from `ag`.
///
/// Authority split: copy links write the clipboard, so they're honored only for OSC 8
/// clicks inside a surface; external opens (other apps, browsers) can only navigate.
/// An in-surface `⏺` click copies its segment; `&scroll=1` or an external open scrolls
/// to the message instead.
@MainActor
enum MsgLink {
    /// An OSC 8 click in `view`. False when `url` isn't one of these links.
    static func handleClick(_ url: String, view: Ghostty.SurfaceView?) -> Bool {
        guard PhilLink.isOurs(url, schemes: FocusLink.schemes) else { return false }
        guard let link = PhilLink.parse(url, schemes: FocusLink.schemes) else {
            NSSound.beep()
            return true
        }
        guard let view else {
            CopyProvider.logger.info("ignored copy/msg link without an originating surface")
            return true
        }
        // The core opens links under the renderer lock; act once it's released.
        DispatchQueue.main.async {
            switch link {
            case .copy(let ref):
                CopyProvider.copyRef(ref, view: view)
            case .msg(let msg) where msg.scroll:
                navigate(msg, from: view)
            case .msg(let msg):
                if let ref = msg.copyRef {
                    CopyProvider.copyRef(ref, view: view)
                } else {
                    NSSound.beep()
                }
            }
        }
        return true
    }

    /// A Launch Services open. Copy links are dropped; msg links navigate.
    static func handleExternal(_ url: String) -> Bool {
        guard PhilLink.isOurs(url, schemes: FocusLink.schemes) else { return false }
        guard let link = PhilLink.parse(url, schemes: FocusLink.schemes) else { return true }
        guard link.allowed(from: .externalOpen) else {
            CopyProvider.logger.info("ignored external copy link")
            return true
        }
        if case .msg(let msg) = link { navigate(msg, from: nil) }
        return true
    }

    /// Scrolls the surface holding the anchor to it and focuses that surface. Candidates
    /// are the clicked surface, then terminals on the verified `ag` endpoint's tty.
    static func navigate(_ msg: MsgRef, from origin: Ghostty.SurfaceView?) {
        var candidates: [Ghostty.SurfaceView] = origin.map { [$0] } ?? []
        for tty in ttys(for: msg) {
            if let view = FocusLink.surface(tty: tty), !candidates.contains(where: { $0 === view }) {
                candidates.append(view)
            }
        }
        for view in candidates {
            guard let surface = view.surface else { continue }
            let found = msg.raw.withCString { ghostty_surface_scroll_to_anchor(surface, $0, UInt(strlen($0))) }
            guard found else { continue }
            if view !== origin, let controller = BaseTerminalController.controller(owning: view) {
                controller.focusSurface(view)
            }
            return
        }
        NSSound.beep()
        if let origin { CopyToast.show("Message not in scrollback", over: origin) }
    }

    private static func ttys(for msg: MsgRef) -> [String] {
        if let pid = msg.pid, let endpoint = ClarcReady.endpoint(pid: pid) { return [endpoint.tty] }
        if let sid = msg.sid { return ClarcReady.endpoints(sid: sid).map(\.tty) }
        return []
    }
}

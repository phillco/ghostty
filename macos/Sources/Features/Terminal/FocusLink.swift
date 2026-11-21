import AppKit

/// `<scheme>://focus?tty=/dev/ttysNNN[&pane=%N][&fallback=URL]` focuses the terminal whose pty
/// is `tty`, in-process, from an OSC 8 click or an external open. Agent peer badges link here;
/// agentlib/peers (Phil's ~/bin) builds the URLs. Under tmux, `tty` is the tmux client's
/// terminal and `pane` the pane to select in it. With no matching surface, `fallback` opens if
/// its scheme is allowed: any process that prints OSC 8 can produce these links.
@MainActor
enum FocusLink {
    /// Fallback schemes allowed without config; link-trusted-schemes adds more.
    static let fallbackSchemes: Set<String> = ["clarc-observer", "clarc", "hammerspoon", "https"]

    /// Schemes handled here: `ghostty-phil`, which links are printed with, and this build's own
    /// (`ghostty-phil-test` in test builds), so a click is handled by the app it happens in.
    static var schemes: Set<String> {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let own = (types?.first?["CFBundleURLSchemes"] as? [String])?.first
        return Set(["ghostty-phil", own].compactMap { $0?.lowercased() })
    }

    /// Handles a focus link; false when `string` isn't one, so callers fall through.
    static func handle(_ string: String) -> Bool {
        guard let c = URLComponents(string: string),
              let scheme = c.scheme?.lowercased(), schemes.contains(scheme), c.host == "focus" else { return false }
        let query = { (name: String) in c.queryItems?.first(where: { $0.name == name })?.value }
        if let tty = query("tty"), let view = surface(tty: tty),
           let controller = BaseTerminalController.controller(owning: view) {
            if let pane = query("pane"), pane.hasPrefix("%") {
                selectTmuxPane(pane)
            }
            controller.focusSurface(view)
            return true
        }
        if let raw = query("fallback"), let url = URL(string: raw),
           let s = url.scheme?.lowercased(), fallbackSchemes.contains(s)
            || (NSApp.delegate as? AppDelegate)?.ghostty.config.linkTrustedSchemes.contains(s) == true {
            NSWorkspace.shared.open(url)
        } else {
            NSSound.beep()
        }
        return true
    }

    private static func surface(tty: String) -> Ghostty.SurfaceView? {
        let want = bare(tty)
        return NSApp.windows
            .compactMap { $0.windowController as? BaseTerminalController }
            .flatMap { $0.surfaceTree.root?.leaves() ?? [] }
            .first { $0.surfaceModel?.ttyName.map(bare) == want }
    }

    private static func bare(_ tty: String) -> String {
        tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
    }

    /// Selects the pane's window and the pane itself; the attached client follows.
    private static func selectTmuxPane(_ pane: String) {
        let candidates = ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let tmux = candidates.first(where: FileManager.default.isExecutableFile) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tmux)
        p.arguments = ["select-window", "-t", pane, ";", "select-pane", "-t", pane]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
    }
}

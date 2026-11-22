import AppKit
import GhosttyKit
import os

/// Lazy semantic copy from `ag`: resolves selections and copy links to Markdown over
/// clarc-ipc off the main thread, then writes every pasteboard flavor at once.
@MainActor
enum CopyProvider {
    static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ghostty", category: "copy-nav")

    /// ⌘C on a selection below an `ag` anchor. The core already left the renderer lock.
    /// The regular copy lands immediately: plain text, plus terminal HTML when the
    /// selection has no copy chips (which it would render as links). The rich item
    /// replaces it only if `ag` answers within the budget and no newer copy or other app
    /// wrote the pasteboard meanwhile; otherwise the regular copy stays.
    static func copySelection(snapshot: Data, plain: String, html: String?, view: Ghostty.SurfaceView,
                              pasteboard: NSPasteboard) {
        let ticket = CopyPasteboard.writePlain(plain, html: html, to: pasteboard)
        guard let snap = try? JSONDecoder().decode(SelectionSnapshot.self, from: snapshot) else {
            logger.warning("undecodable copy snapshot")
            return
        }
        let id = UUID().uuidString
        guard let (pid, line) = ResolveRequest.selection(id: id, snap, schemes: FocusLink.schemes) else { return }
        resolve(pid: pid, view: view, line: line, id: id) { response in
            guard let response else { return }
            CopyPasteboard.commit(RichClip(response, markdownPlain: snap.wantsMarkdownPlain),
                                  to: pasteboard, ticket: ticket)
        }
    }

    /// A copy chip or ⏺ click: copy the referenced block, segment or turn and confirm with
    /// a toast. Beeps (clipboard untouched) when it can't be verified or resolved.
    static func copyRef(_ ref: CopyRef, view: Ghostty.SurfaceView) {
        let pasteboard = NSPasteboard.general
        let ticket = CopyPasteboard.ticket(for: pasteboard)
        let id = UUID().uuidString
        resolve(pid: ref.pid, view: view, line: ResolveRequest.ref(id: id, ref), id: id) { response in
            guard let response,
                  CopyPasteboard.commit(RichClip(response), to: pasteboard, ticket: ticket) else {
                NSSound.beep()
                return
            }
            CopyToast.show("Copied", over: view)
        }
    }

    private static func resolve(pid: Int32, view: Ghostty.SurfaceView, line: Data, id: String,
                                then: @escaping @MainActor (ResolveResponse?) -> Void) {
        let deadline = Date(timeIntervalSinceNow: CopyResolver.budget)
        let tty = view.surfaceModel?.ttyName
        Task.detached(priority: .userInitiated) {
            let response: ResolveResponse?
            do {
                response = try CopyResolver.resolve(pid: pid, tty: tty, line: line, id: id, deadline: deadline)
            } catch {
                await MainActor.run { logger.info("semantic copy fell back: \(String(describing: error), privacy: .public)") }
                response = nil
            }
            await then(response)
        }
    }
}

/// ⌘C with nothing selected and ⌘X act on `ag`'s composer draft. `ag` reads them as
/// CSI u `super+c` / `super+x`, which Ghostty otherwise drops on macOS. They're sent only
/// when the surface's foreground job is a verified live `ag` with the Kitty keyboard
/// protocol off, so other programs never see the sequences.
@MainActor
enum AgComposerKeys {
    static func handle(_ event: NSEvent, view: Ghostty.SurfaceView, bindingFlags: Ghostty.Input.BindingFlags?,
                       isCopyBinding: Bool) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]) == .command,
              let key = event.charactersIgnoringModifiers?.lowercased(), key == "c" || key == "x",
              yieldsToComposer(key: key, bindingFlags: bindingFlags, isCopyBinding: isCopyBinding),
              let surface = view.surface, let model = view.surfaceModel else { return false }
        // A terminal selection means the user is copying terminal text, not the draft.
        guard !ghostty_surface_has_selection(surface),
              ghostty_surface_kitty_keyboard_flags(surface) == 0,
              let tty = model.ttyName, let pid = ClarcReady.agPID(tty: tty),
              let fg = model.foregroundPID,
              ForegroundJob.isOnly(agPID: pid, foregroundPGID: Int32(fg), tty: tty) else { return false }
        let action = key == "c" ? "text:\\x1b[99;9u" : "text:\\x1b[120;9u"
        return ghostty_surface_binding_action(surface, action, UInt(action.utf8.count))
    }

    static func yieldsToComposer(key: String, bindingFlags: Ghostty.Input.BindingFlags?, isCopyBinding: Bool) -> Bool {
        ComposerKeyPolicy.yields(key: key, bound: bindingFlags != nil,
                                 performable: bindingFlags?.contains(.performable) == true,
                                 crossSurface: bindingFlags?.isDisjoint(with: [.all, .global]) == false,
                                 isCopyBinding: isCopyBinding)
    }
}

/// A brief "Copied" label over the surface. A borderless, click-through child panel that
/// never becomes key, so it can't take focus.
@MainActor
enum CopyToast {
    private static var panel: NSPanel?
    private static var generation = 0

    static func show(_ text: String, over view: NSView) {
        guard let window = view.window else { return }
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()
        let size = NSSize(width: label.frame.width + 28, height: label.frame.height + 14)

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        label.frame.origin = NSPoint(x: 14, y: 7)
        effect.addSubview(label)

        let rect = view.convert(view.bounds, to: nil)
        let screenRect = window.convertToScreen(rect)
        let origin = NSPoint(x: screenRect.midX - size.width / 2, y: screenRect.minY + 24)

        panel?.parent?.removeChildWindow(panel!)
        panel?.orderOut(nil)
        let p = NSPanel(contentRect: NSRect(origin: origin, size: size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.ignoresMouseEvents = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.contentView = effect
        window.addChildWindow(p, ordered: .above)
        p.orderFront(nil)
        panel = p

        generation += 1
        let mine = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            guard mine == generation, let p = panel else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                p.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated {
                    guard mine == generation else { return }
                    p.parent?.removeChildWindow(p)
                    p.orderOut(nil)
                    panel = nil
                }
            })
        }
    }
}

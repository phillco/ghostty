import AppKit
import Combine
import Foundation
import Testing
@testable import Ghostty

/// The sidebar's idle age (`WindowTracker.lastActive`) tracks terminal
/// activity only: a title change or a bell, never focusing the tab.
@MainActor
struct VerticalTabsActivityTests {
    @MainActor
    private final class Fixture {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
            styleMask: [.titled], backing: .buffered, defer: true)
        let bell = CurrentValueSubject<Bool, Never>(false)
        var changes = 0
        lazy var tracker = WindowTracker(window: window, bell: bell.eraseToAnyPublisher()) { [unowned self] in
            changes += 1
        }

        init(title: String = "zsh") {
            window.isReleasedWhenClosed = false
            window.title = title
            _ = tracker
        }
    }

    private let past = Date(timeIntervalSince1970: 1_000)

    @Test func reassigningTheSameTitleIsNotActivity() {
        let f = Fixture()
        f.tracker.lastActive = past
        var raw = 0
        let observation = f.window.observe(\.title) { _, _ in raw += 1 }
        // What Ghostty does on focus: reapply the unchanged title.
        f.window.title = "zsh"
        f.window.title = "zsh"
        observation.invalidate()
        #expect(raw == 2)  // KVO itself fires anyway; the tracker must filter
        #expect(f.tracker.lastActive == past)
        #expect(f.changes == 0)
    }

    @Test func aRealTitleChangeIsActivity() {
        let f = Fixture()
        f.tracker.lastActive = past
        f.window.title = "⠋ claude"
        #expect(f.tracker.lastActive! > past)
        #expect(f.changes == 1)
    }

    @Test func togglingTheBellPrefixIsNotActivity() {
        let f = Fixture()
        f.tracker.lastActive = past
        f.window.title = "🔔 zsh"
        f.window.title = "zsh"  // focusing the tab clears the bell
        #expect(f.tracker.lastActive == past)
    }

    @Test func aBellRingIsActivityButClearingItIsNot() {
        let f = Fixture()
        f.tracker.lastActive = past
        f.bell.send(true)
        let rang = f.tracker.lastActive
        #expect(rang! > past)
        #expect(f.changes == 1)

        f.tracker.lastActive = past
        f.bell.send(false)  // focusing the tab clears the bell
        #expect(f.tracker.lastActive == past)
        #expect(f.changes == 2)  // still refreshes so the bell badge goes away
    }

    @Test func idleAgeFallsBackToLastLeft() {
        let f = Fixture()
        #expect(f.tracker.shownActive == nil)
        f.tracker.lastLeft = past
        #expect(f.tracker.shownActive == past)
        let later = past.addingTimeInterval(60)
        f.tracker.lastActive = later
        #expect(f.tracker.shownActive == later)
    }

    @Test func titleChangeIsActivityRules() {
        #expect(!VerticalTabs.titleChangeIsActivity(from: "zsh", to: "zsh"))
        #expect(!VerticalTabs.titleChangeIsActivity(from: "zsh", to: "🔔 zsh"))
        #expect(!VerticalTabs.titleChangeIsActivity(from: "🔔 zsh", to: "zsh"))
        #expect(VerticalTabs.titleChangeIsActivity(from: "⠋ claude", to: "⠙ claude"))
        #expect(VerticalTabs.titleChangeIsActivity(from: "zsh", to: "vim"))
        #expect(VerticalTabs.titleChangeIsActivity(from: nil, to: "zsh"))
    }
}

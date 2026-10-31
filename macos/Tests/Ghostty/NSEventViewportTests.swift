import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

@Suite
struct NSEventViewportTests {
    @Test(arguments: [true, false])
    func markedKeyboardEventsPreserveViewport(keyDown: Bool) throws {
        let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: keyDown))
        cgEvent.setIntegerValueField(.eventSourceUserData, value: NSEvent.ghosttyPreserveViewportMarker)
        let event = try #require(NSEvent(cgEvent: cgEvent))

        #expect(event.preservesViewport)
        let action = keyDown ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
        #expect(event.ghosttyKeyEvent(action).preserve_viewport)
    }

    @Test(arguments: [Int64(0), NSEvent.ghosttyPreserveViewportMarker + 1])
    func ordinaryAndUnrelatedKeyboardEventsKeepNormalScrolling(marker: Int64) throws {
        let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: true))
        cgEvent.setIntegerValueField(.eventSourceUserData, value: marker)
        let event = try #require(NSEvent(cgEvent: cgEvent))

        #expect(!event.preservesViewport)
        #expect(!event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS).preserve_viewport)
    }

    @Test func markerOnModifierEventPropagates() throws {
        let cgEvent = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true))
        cgEvent.type = .flagsChanged
        cgEvent.flags = .maskShift
        cgEvent.setIntegerValueField(.eventSourceUserData, value: NSEvent.ghosttyPreserveViewportMarker)
        let event = try #require(NSEvent(cgEvent: cgEvent))

        #expect(event.preservesViewport)
        #expect(event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS).preserve_viewport)
    }

    @Test func markerOnMouseEventIsIgnored() throws {
        let cgEvent = try #require(CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: .zero,
            mouseButton: .left))
        cgEvent.setIntegerValueField(.eventSourceUserData, value: NSEvent.ghosttyPreserveViewportMarker)
        let event = try #require(NSEvent(cgEvent: cgEvent))

        #expect(!event.preservesViewport)
    }
}

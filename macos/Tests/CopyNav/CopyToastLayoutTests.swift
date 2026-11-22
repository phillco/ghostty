import AppKit
import Testing
@testable import Ghostty

struct CopyToastLayoutTests {
    private let size = NSSize(width: 100, height: 30)
    private let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
    private let view = NSRect(x: 100, y: 100, width: 600, height: 500)

    private func origin(_ cursor: NSPoint, view: NSRect? = nil, screen: NSRect? = nil) -> NSPoint {
        CopyToastLayout.origin(for: size, cursor: cursor, viewRect: view ?? self.view, screenFrame: screen ?? self.screen)
    }

    @Test func centersAboveTheCursor() {
        #expect(origin(NSPoint(x: 400, y: 300)) == NSPoint(x: 350, y: 318))
        // Slightly outside the surface still follows the mouse.
        #expect(origin(NSPoint(x: 730, y: 300)) == NSPoint(x: 680, y: 318))
    }

    @Test func flipsBelowAtTheTopEdge() {
        let view = NSRect(x: 100, y: 400, width: 600, height: 390)
        // 780 + 18 + 30 overflows 800 - 8, so the toast goes 24pt below the cursor.
        #expect(origin(NSPoint(x: 400, y: 780), view: view) == NSPoint(x: 350, y: 726))
    }

    @Test func clampsToTheScreen() {
        let wide = NSRect(x: -50, y: 100, width: 1100, height: 500)
        #expect(origin(NSPoint(x: 10, y: 300), view: wide).x == 8)
        #expect(origin(NSPoint(x: 995, y: 300), view: wide).x == 892)
        // A screen that isn't at the origin.
        let right = NSRect(x: 1000, y: 0, width: 800, height: 600)
        let onRight = NSRect(x: 1000, y: 0, width: 800, height: 600)
        #expect(origin(NSPoint(x: 1002, y: 5), view: onRight, screen: right) == NSPoint(x: 1008, y: 23))
    }

    @Test func fallsBackToTheSurfaceWhenTheMouseIsElsewhere() {
        // Keyboard-triggered toast with the mouse on another monitor.
        #expect(origin(NSPoint(x: 2500, y: 300)) == NSPoint(x: 350, y: 124))
        #expect(!CopyToastLayout.anchorsToCursor(NSPoint(x: 2500, y: 300), viewRect: view))
        #expect(CopyToastLayout.anchorsToCursor(NSPoint(x: 60, y: 60), viewRect: view))
        #expect(!CopyToastLayout.anchorsToCursor(NSPoint(x: 59, y: 300), viewRect: view))
        // The fallback is clamped too.
        let low = NSRect(x: -80, y: -10, width: 120, height: 20)
        #expect(origin(NSPoint(x: 2500, y: 300), view: low) == NSPoint(x: 8, y: 14))
    }
}

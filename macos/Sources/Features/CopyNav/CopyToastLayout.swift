import AppKit

/// Where `CopyToast` goes: just above the mouse when it's over (or near) the surface,
/// otherwise near the bottom of the surface, always fully on screen.
enum CopyToastLayout {
    /// How far outside the surface the mouse may be and still anchor the toast.
    static let cursorSlop: CGFloat = 40
    static let gapAbove: CGFloat = 18
    static let gapBelow: CGFloat = 24
    static let fallbackInset: CGFloat = 24
    static let screenMargin: CGFloat = 8

    /// Whether the toast follows the mouse rather than falling back to the surface.
    static func anchorsToCursor(_ cursor: NSPoint, viewRect: NSRect) -> Bool {
        viewRect.insetBy(dx: -cursorSlop, dy: -cursorSlop).contains(cursor)
    }

    /// The toast's bottom-left origin in screen coordinates. `viewRect` is the surface
    /// and `screenFrame` the screen the toast lands on, both in screen coordinates.
    static func origin(for size: NSSize, cursor: NSPoint, viewRect: NSRect, screenFrame: NSRect) -> NSPoint {
        var origin: NSPoint
        if anchorsToCursor(cursor, viewRect: viewRect) {
            origin = NSPoint(x: cursor.x - size.width / 2, y: cursor.y + gapAbove)
            if origin.y + size.height > screenFrame.maxY - screenMargin {
                origin.y = cursor.y - gapBelow - size.height
            }
        } else {
            origin = NSPoint(x: viewRect.midX - size.width / 2, y: viewRect.minY + fallbackInset)
        }
        let bounds = screenFrame.insetBy(dx: screenMargin, dy: screenMargin)
        origin.x = max(bounds.minX, min(origin.x, bounds.maxX - size.width))
        origin.y = max(bounds.minY, min(origin.y, bounds.maxY - size.height))
        return origin
    }
}

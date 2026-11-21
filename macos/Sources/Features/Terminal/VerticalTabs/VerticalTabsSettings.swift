import AppKit
import Combine

/// Persisted vertical tab preferences, shared by every sidebar.
final class VerticalTabsSettings: ObservableObject {
    static let shared = VerticalTabsSettings()

    enum Density: String, CaseIterable {
        case compact
        case tall
    }

    static let defaultWidth: CGFloat = 240
    static let widthRange: ClosedRange<CGFloat> = 160...420

    /// Pins not seen on any live tab for this long are dropped at launch.
    private static let pinExpiry: TimeInterval = 14 * 86_400

    private enum Key {
        static let enabled = "VerticalTabsEnabled"
        static let width = "VerticalTabsWidth"
        static let density = "VerticalTabsDensity"
        static let recentsCollapsed = "VerticalTabsRecentsCollapsed"
        static let pins = "VerticalTabsPins"
        static let pinsSeen = "VerticalTabsPinsSeen"
    }

    private let defaults: UserDefaults

    @Published var enabled: Bool {
        didSet { defaults.set(enabled, forKey: Key.enabled) }
    }

    @Published var width: CGFloat {
        didSet { defaults.set(Double(width), forKey: Key.width) }
    }

    @Published var density: Density {
        didSet { defaults.set(density.rawValue, forKey: Key.density) }
    }

    @Published var recentsCollapsed: Bool {
        didSet { defaults.set(recentsCollapsed, forKey: Key.recentsCollapsed) }
    }

    @Published var pins: VerticalTabs.Pins {
        didSet {
            guard pins != oldValue else { return }
            defaults.set(pins.keys, forKey: Key.pins)
            markSeen(pins.keys.filter { !oldValue.keys.contains($0) })
        }
    }

    /// Last time each pin key matched a live tab.
    private var pinsSeen: [String: Double]

    init(defaults: UserDefaults = .ghostty) {
        self.defaults = defaults
        enabled = defaults.bool(forKey: Key.enabled)
        let storedWidth = defaults.double(forKey: Key.width)
        width = storedWidth > 0 ? Self.clamp(CGFloat(storedWidth)) : Self.defaultWidth
        density = defaults.string(forKey: Key.density).flatMap(Density.init(rawValue:)) ?? .compact
        recentsCollapsed = defaults.bool(forKey: Key.recentsCollapsed)
        let seen = defaults.dictionary(forKey: Key.pinsSeen) as? [String: Double] ?? [:]

        // Drop pins whose tab has been gone for a long time (closed tabs never come back).
        let now = Date().timeIntervalSince1970
        let keys = defaults.stringArray(forKey: Key.pins) ?? []
        let live = keys.filter { now - (seen[$0] ?? now) < Self.pinExpiry }
        pins = .init(keys: live)
        pinsSeen = seen.filter { live.contains($0.key) }
        if live != keys { defaults.set(live, forKey: Key.pins) }
    }

    static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, widthRange.lowerBound), widthRange.upperBound)
    }

    /// Records that these pin keys matched live tabs. Writes at most once a day per key.
    func markSeen(_ keys: [String]) {
        let now = Date().timeIntervalSince1970
        var changed = false
        for key in keys where now - (pinsSeen[key] ?? 0) > 86_400 {
            pinsSeen[key] = now
            changed = true
        }
        if changed { defaults.set(pinsSeen, forKey: Key.pinsSeen) }
    }
}

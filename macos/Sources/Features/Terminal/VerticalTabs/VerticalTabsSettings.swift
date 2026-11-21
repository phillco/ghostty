import AppKit
import Combine

/// Persisted vertical tab preferences, shared by every sidebar.
final class VerticalTabsSettings: ObservableObject {
    static let shared = VerticalTabsSettings()

    enum Density: String, CaseIterable {
        case compact
        case tall
    }

    enum TextSize: String, CaseIterable {
        case small
        case medium
        case large

        /// Title point size; secondary text and icons scale from it.
        var pointSize: CGFloat {
            switch self {
            case .small: return 11
            case .medium: return 13
            case .large: return 15
            }
        }
    }

    /// The `vertical-tabs-*` keys from the Ghostty config, already validated.
    struct ConfigValues: Equatable {
        /// nil: use the View Options menu's `textSize`.
        var fontSize: CGFloat?
        /// nil: derived from the title size.
        var secondaryFontSize: CGFloat?
        var recentsLimit = VerticalTabs.recentsLimit
        var recentsDwell: TimeInterval = 1
        /// 0: folder pills never truncate.
        var pillMaxChars = 12
    }

    static let defaultWidth: CGFloat = 240
    static let widthRange: ClosedRange<CGFloat> = 160...420

    /// Pins not seen on any live tab for this long are dropped at launch.
    private static let pinExpiry: TimeInterval = 14 * 86_400

    private enum Key {
        static let enabled = "VerticalTabsEnabled"
        static let width = "VerticalTabsWidth"
        static let density = "VerticalTabsDensity"
        static let textSize = "VerticalTabsTextSize"
        /// The configured font size a menu preset overrides, so it survives restarts.
        static let textSizeOverrides = "VerticalTabsTextSizeOverridesConfig"
        static let showFolders = "VerticalTabsShowFolders"
        static let showIdleTime = "VerticalTabsShowIdleTime"
        static let showShortcuts = "VerticalTabsShowShortcuts"
        static let showIcons = "VerticalTabsShowIcons"
        static let showRecents = "VerticalTabsShowRecents"
        static let recentsCollapsed = "VerticalTabsRecentsCollapsed"
        static let pins = "VerticalTabsPins"
        static let pinsSeen = "VerticalTabsPinsSeen"
    }

    private let defaults: UserDefaults
    /// Set while values are read from defaults, so `didSet` doesn't write them back.
    private var isLoading = false

    private func save(_ value: Any, _ key: String) {
        if !isLoading { defaults.set(value, forKey: key) }
    }

    @Published var enabled: Bool {
        didSet { save(enabled, Key.enabled) }
    }

    @Published var width: CGFloat {
        didSet { save(Double(width), Key.width) }
    }

    @Published var density: Density {
        didSet { save(density.rawValue, Key.density) }
    }

    @Published var textSize: TextSize {
        didSet { save(textSize.rawValue, Key.textSize) }
    }

    /// Live `vertical-tabs-*` config values; see `applyConfig`.
    @Published private(set) var config = ConfigValues()

    /// Whether the title size comes from `config.fontSize` rather than `textSize`.
    /// Picking a menu size turns it off until the configured size changes.
    @Published private(set) var useConfigFontSize = false

    /// Takes new config values. A changed `vertical-tabs-font-size` takes over
    /// from the menu's size, unless a preset was picked over that same size;
    /// removing it falls back to the menu's size.
    func applyConfig(_ values: ConfigValues) {
        guard values != config else { return }
        let fontChanged = values.fontSize != config.fontSize
        config = values
        guard fontChanged else { return }
        let overridden = defaults.object(forKey: Key.textSizeOverrides) as? Double
        useConfigFontSize = values.fontSize.map { Double($0) != overridden } ?? false
        if useConfigFontSize || values.fontSize == nil { defaults.removeObject(forKey: Key.textSizeOverrides) }
    }

    /// The Text Size menu's choice: nil is the configured size.
    var textSizeChoice: TextSize? {
        get { useConfigFontSize ? nil : textSize }
        set {
            if let newValue { textSize = newValue }
            useConfigFontSize = newValue == nil && config.fontSize != nil
            if let size = config.fontSize, !useConfigFontSize {
                defaults.set(Double(size), forKey: Key.textSizeOverrides)
            } else {
                defaults.removeObject(forKey: Key.textSizeOverrides)
            }
        }
    }

    var fontSize: CGFloat {
        useConfigFontSize ? config.fontSize ?? textSize.pointSize : textSize.pointSize
    }

    var secondaryFontSize: CGFloat {
        config.secondaryFontSize ?? max(9, fontSize - 2)
    }

    /// `14pt`, `14.5pt`.
    static func pointLabel(_ size: CGFloat) -> String {
        String(format: "%gpt", Double(size))
    }

    /// Project (folder) labels on each row.
    @Published var showFolders: Bool {
        didSet { save(showFolders, Key.showFolders) }
    }

    @Published var showIdleTime: Bool {
        didSet { save(showIdleTime, Key.showIdleTime) }
    }

    @Published var showShortcuts: Bool {
        didSet { save(showShortcuts, Key.showShortcuts) }
    }

    /// Agent / terminal glyphs at the start of each row.
    @Published var showIcons: Bool {
        didSet { save(showIcons, Key.showIcons) }
    }

    /// The Recents section; when off its tabs stay in Open.
    @Published var showRecents: Bool {
        didSet { save(showRecents, Key.showRecents) }
    }

    @Published var recentsCollapsed: Bool {
        didSet { save(recentsCollapsed, Key.recentsCollapsed) }
    }

    @Published var pins: VerticalTabs.Pins {
        didSet {
            guard !isLoading, pins != oldValue else { return }
            defaults.set(pins.keys, forKey: Key.pins)
            markSeen(pins.keys.filter { !oldValue.keys.contains($0) })
        }
    }

    /// Last time each pin key matched a live tab.
    private var pinsSeen: [String: Double]

    init(defaults: UserDefaults = .ghostty) {
        self.defaults = defaults
        let stored = Stored(defaults: defaults)
        enabled = stored.enabled
        width = stored.width
        density = stored.density
        textSize = stored.textSize
        showFolders = stored.showFolders
        showIdleTime = stored.showIdleTime
        showShortcuts = stored.showShortcuts
        showIcons = stored.showIcons
        showRecents = stored.showRecents
        recentsCollapsed = stored.recentsCollapsed
        pins = stored.pins
        pinsSeen = stored.pinsSeen
        stored.pruneExpiredPins(in: defaults)
    }

    /// Re-reads every preference another process (`ghostty-test-mirror`) may
    /// have written while we run. Publishes only values that changed.
    func reloadFromDefaults() {
        let stored = Stored(defaults: defaults)
        isLoading = true
        defer { isLoading = false }
        if enabled != stored.enabled { enabled = stored.enabled }
        if width != stored.width { width = stored.width }
        if density != stored.density { density = stored.density }
        if textSize != stored.textSize { textSize = stored.textSize }
        if showFolders != stored.showFolders { showFolders = stored.showFolders }
        if showIdleTime != stored.showIdleTime { showIdleTime = stored.showIdleTime }
        if showShortcuts != stored.showShortcuts { showShortcuts = stored.showShortcuts }
        if showIcons != stored.showIcons { showIcons = stored.showIcons }
        if showRecents != stored.showRecents { showRecents = stored.showRecents }
        if recentsCollapsed != stored.recentsCollapsed { recentsCollapsed = stored.recentsCollapsed }
        if pins != stored.pins { pins = stored.pins }
        pinsSeen = stored.pinsSeen
        stored.pruneExpiredPins(in: defaults)
    }

    /// Every preference as stored, with defaults applied and expired pins dropped.
    private struct Stored {
        let enabled: Bool
        let width: CGFloat
        let density: Density
        let textSize: TextSize
        let showFolders: Bool
        let showIdleTime: Bool
        let showShortcuts: Bool
        let showIcons: Bool
        let showRecents: Bool
        let recentsCollapsed: Bool
        let pins: VerticalTabs.Pins
        let pinsSeen: [String: Double]
        /// Stored pin keys, before expiry.
        private let storedPins: [String]

        init(defaults: UserDefaults) {
            enabled = defaults.bool(forKey: Key.enabled)
            let storedWidth = defaults.double(forKey: Key.width)
            width = storedWidth > 0 ? VerticalTabsSettings.clamp(CGFloat(storedWidth)) : VerticalTabsSettings.defaultWidth
            density = defaults.string(forKey: Key.density).flatMap(Density.init(rawValue:)) ?? .compact
            textSize = defaults.string(forKey: Key.textSize).flatMap(TextSize.init(rawValue:)) ?? .medium
            showFolders = defaults.object(forKey: Key.showFolders) as? Bool ?? true
            showIdleTime = defaults.object(forKey: Key.showIdleTime) as? Bool ?? true
            showShortcuts = defaults.object(forKey: Key.showShortcuts) as? Bool ?? true
            showIcons = defaults.object(forKey: Key.showIcons) as? Bool ?? true
            showRecents = defaults.object(forKey: Key.showRecents) as? Bool ?? true
            recentsCollapsed = defaults.bool(forKey: Key.recentsCollapsed)
            let seen = defaults.dictionary(forKey: Key.pinsSeen) as? [String: Double] ?? [:]

            // Drop pins whose tab has been gone for a long time (closed tabs never come back).
            let now = Date().timeIntervalSince1970
            storedPins = defaults.stringArray(forKey: Key.pins) ?? []
            let live = storedPins.filter { now - (seen[$0] ?? now) < VerticalTabsSettings.pinExpiry }
            pins = .init(keys: live)
            pinsSeen = seen.filter { live.contains($0.key) }
        }

        func pruneExpiredPins(in defaults: UserDefaults) {
            if pins.keys != storedPins { defaults.set(pins.keys, forKey: Key.pins) }
        }
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

extension VerticalTabsSettings.ConfigValues {
    init(_ config: Ghostty.Config) {
        self.init(
            fontSize: config.verticalTabsFontSize,
            secondaryFontSize: config.verticalTabsSecondaryFontSize,
            recentsLimit: config.verticalTabsRecentsLimit,
            recentsDwell: config.verticalTabsRecentsDwell,
            pillMaxChars: config.verticalTabsPillMaxChars)
    }
}

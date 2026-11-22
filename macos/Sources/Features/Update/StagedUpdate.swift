import Foundation

/// Where `ghostty-rebuild` stages builds for the running app, and how to install them.
struct StagedUpdateLocation: Equatable {
    /// The `staged/` directory, which `ghostty-rebuild` replaces atomically with `rename()`.
    let stagedDirectory: URL
    /// App bundle names accepted inside `staged/`; the first one present counts.
    let appNames: [String]
    let installCommand: String
    /// The LaunchAgent that installs the staged build, if this flavor has one.
    let launchAgentLabel: String?

    // Split so `ghostty-rebuild -t`, which rewrites the main ID throughout the Swift
    // sources for the test app, leaves these intact.
    static let mainBundleID = "io.phillip." + "ghostty-phil"
    static let testBundleID = mainBundleID + ".link-test.debug"
    /// Points the watcher at another `staged/` directory, for GUI testing without real builds.
    static let overrideEnvironmentKey = "GHOSTTY_PHIL_STAGED_DIR"

    /// The location for a bundle ID, or nil for builds `ghostty-rebuild` doesn't stage.
    /// A non-empty override directory applies to any bundle, with the main app's
    /// command and updater so the whole popover can be exercised.
    static func forBundle(id: String?, home: URL, environment: [String: String]) -> StagedUpdateLocation? {
        let state = home.appendingPathComponent(".local/share/ghostty-rebuild", isDirectory: true)
        if let override = environment[overrideEnvironmentKey], !override.isEmpty {
            let main = main(state: state)
            return .init(
                stagedDirectory: URL(fileURLWithPath: (override as NSString).expandingTildeInPath, isDirectory: true),
                appNames: main.appNames,
                installCommand: main.installCommand,
                launchAgentLabel: main.launchAgentLabel)
        }
        switch id {
        case mainBundleID:
            return main(state: state)
        case testBundleID:
            return .init(
                stagedDirectory: state.appendingPathComponent("test/staged", isDirectory: true),
                // ghostty-rebuild stages the test app under the main app's bundle name.
                appNames: ["Ghostty Phil.app", "Ghostty Phil Test.app"],
                installCommand: "ghostty-rebuild -t install",
                launchAgentLabel: nil)
        default:
            return nil
        }
    }

    private static func main(state: URL) -> StagedUpdateLocation {
        .init(
            stagedDirectory: state.appendingPathComponent("staged", isDirectory: true),
            appNames: ["Ghostty Phil.app"],
            installCommand: "ghostty-rebuild install",
            launchAgentLabel: "com.phillco.ghostty-phil-updater")
    }
}

/// Build provenance `ghostty-rebuild` stamps into the running app's Info.plist.
struct RunningBuild: Equatable {
    var fingerprint: String?
    var revision: String?
    var dirty: Bool?
    var swift: String?
    /// `GhosttyPhilBuiltAt`, else the executable's modification time.
    var builtAt: Date?

    static func current(bundle: Bundle = .main) -> RunningBuild {
        let info = bundle.infoDictionary ?? [:]
        var builtAt: Date?
        switch info["GhosttyPhilBuiltAt"] {
        case let date as Date: builtAt = date
        case let string as String: builtAt = StagedUpdate.parseDate(string)
        default: break
        }
        if builtAt == nil, let executable = bundle.executableURL {
            builtAt = try? executable.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        }
        return .init(
            fingerprint: info["GhosttyPhilSourceFingerprint"] as? String,
            revision: info["GhosttyPhilSourceRevision"] as? String,
            dirty: info["GhosttyPhilSourceDirty"] as? Bool,
            swift: info["GhosttyPhilSwiftBuild"] as? String,
            builtAt: builtAt)
    }
}

/// A build `ghostty-rebuild` staged on disk: `staged/build.json` beside the app bundle.
struct StagedUpdate: Equatable {
    struct Metadata: Codable, Equatable {
        var revision: String
        var dirty: Bool
        var branch: String?
        var source: String?
        var builtAt: String
        var buildHost: String?
        var swift: String?
        var fingerprint: String?
        var subject: String?

        enum CodingKeys: String, CodingKey {
            case revision, dirty, branch, source, swift, fingerprint, subject
            case builtAt = "built_at"
            case buildHost = "build_host"
        }
    }

    let metadata: Metadata
    let location: StagedUpdateLocation

    var shortRevision: String { String(metadata.revision.prefix(12)) }
    var builtAt: Date? { Self.parseDate(metadata.builtAt) }
    var isFastSwift: Bool { metadata.swift == "fast" }

    /// The staged build in `location`, or nil when `build.json` or the app bundle is
    /// missing or `build.json` doesn't decode.
    static func load(from location: StagedUpdateLocation, fileManager: FileManager = .default) -> StagedUpdate? {
        let directory = location.stagedDirectory
        let hasApp = location.appNames.contains { name in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: directory.appendingPathComponent(name).path,
                                          isDirectory: &isDirectory) && isDirectory.boolValue
        }
        guard hasApp,
              let data = fileManager.contents(atPath: directory.appendingPathComponent("build.json").path),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: data) else { return nil }
        return .init(metadata: metadata, location: location)
    }

    /// Whether this staged build differs from (and, without fingerprints, is newer than)
    /// the running one. Fingerprints decide when both exist. Otherwise a differing
    /// revision or Swift flavor counts as an update, two clean builds of the same
    /// revision are the same build, and a dirty one is newer only if it was built more
    /// than `tolerance` after the running one. Unknown running provenance counts as
    /// different; unknown build times count as current.
    func isNewer(than running: RunningBuild, tolerance: TimeInterval = 5) -> Bool {
        if let staged = metadata.fingerprint, let current = running.fingerprint {
            return staged != current
        }
        guard running.revision == metadata.revision,
              (running.swift ?? "release") == (metadata.swift ?? "release") else { return true }
        if !metadata.dirty && running.dirty != true { return false }
        guard let staged = builtAt, let current = running.builtAt else { return false }
        return staged.timeIntervalSince(current) > tolerance
    }

    /// `built_at` is local time without an offset (Python `isoformat`); accept offsets too.
    static func parseDate(_ string: String) -> Date? {
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        local.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ssXXXXX",
                       "yyyy-MM-dd'T'HH:mm:ss.SSSSSSXXXXX"] {
            local.dateFormat = format
            if let date = local.date(from: string) { return date }
        }
        return nil
    }

    /// `9:16am`.
    static func clockTime(_ date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "h:mma"
        return formatter.string(from: date).lowercased()
    }

    /// `just now`, `5m ago`, `3h ago`, `2d ago`.
    static func relativeAge(of date: Date, now: Date) -> String {
        let minutes = Int(max(0, now.timeIntervalSince(date)) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 120 { return "\(minutes)m ago" }
        if minutes < 48 * 60 { return "\(minutes / 60)h ago" }
        return "\(minutes / (24 * 60))d ago"
    }
}

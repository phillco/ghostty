import Foundation
import Testing
@testable import Ghostty

struct StagedUpdateTests {
    private static let location = StagedUpdateLocation(
        stagedDirectory: URL(fileURLWithPath: "/nonexistent/staged"), appNames: ["Ghostty Phil.app"],
        installCommand: "ghostty-rebuild install", launchAgentLabel: "com.phillco.ghostty-phil-updater")

    private func staged(revision: String = "abc", dirty: Bool = false, swift: String? = "release",
                        builtAt: String = "2026-11-22T10:00:00", fingerprint: String? = nil) -> StagedUpdate {
        .init(metadata: .init(revision: revision, dirty: dirty, builtAt: builtAt, swift: swift,
                              fingerprint: fingerprint),
              location: Self.location)
    }

    private func date(_ string: String) throws -> Date {
        try #require(StagedUpdate.parseDate(string))
    }

    @Test func locationsByBundle() {
        let home = URL(fileURLWithPath: "/Users/me")
        let main = StagedUpdateLocation.forBundle(id: "io.phillip.ghostty-phil", home: home, environment: [:])
        #expect(main?.stagedDirectory.path == "/Users/me/.local/share/ghostty-rebuild/staged")
        #expect(main?.installCommand == "ghostty-rebuild install")
        #expect(main?.launchAgentLabel == "com.phillco.ghostty-phil-updater")

        let test = StagedUpdateLocation.forBundle(id: "io.phillip.ghostty-phil.link-test.debug", home: home,
                                                  environment: [:])
        #expect(test?.stagedDirectory.path == "/Users/me/.local/share/ghostty-rebuild/test/staged")
        #expect(test?.installCommand == "ghostty-rebuild -t install")
        #expect(test?.launchAgentLabel == nil)

        #expect(StagedUpdateLocation.forBundle(id: "com.mitchellh.ghostty", home: home, environment: [:]) == nil)
        let empty = ["GHOSTTY_PHIL_STAGED_DIR": ""]
        #expect(StagedUpdateLocation.forBundle(id: "com.mitchellh.ghostty", home: home, environment: empty) == nil)

        let override = ["GHOSTTY_PHIL_STAGED_DIR": "/tmp/fake/staged"]
        let overridden = StagedUpdateLocation.forBundle(id: "io.phillip.ghostty-phil.link-test.debug", home: home,
                                                        environment: override)
        #expect(overridden?.stagedDirectory.path == "/tmp/fake/staged")
        #expect(overridden?.installCommand == "ghostty-rebuild install")
        // A fixture never reaches the production updater unless one is named.
        #expect(overridden?.launchAgentLabel == nil)
        let named = StagedUpdateLocation.forBundle(
            id: "io.phillip.ghostty-phil", home: home,
            environment: override.merging(["GHOSTTY_PHIL_UPDATER_LABEL": "com.example.fixture"]) { $1 })
        #expect(named?.launchAgentLabel == "com.example.fixture")
        let unknown = StagedUpdateLocation.forBundle(id: nil, home: home, environment: override)
        #expect(unknown?.stagedDirectory.path == "/tmp/fake/staged")
        #expect(unknown?.installCommand == "ghostty-rebuild install")
    }

    @Test func loadsBuildJSONBesideTheApp() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("staged-update-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let location = StagedUpdateLocation(stagedDirectory: root, appNames: ["Ghostty Phil.app"],
                                            installCommand: "x", launchAgentLabel: nil)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let json = """
        {"revision": "190f830c2ecec8c0681375e5", "dirty": true, "branch": "main", "source": "/src",
         "built_at": "2026-11-22T10:11:32", "build_host": "phillco@m5-studio", "swift": "fast",
         "fingerprint": "f1", "subject": "macos: a thing", "future_key": 1}
        """
        try Data(json.utf8).write(to: root.appendingPathComponent("build.json"))
        // No app bundle yet.
        #expect(StagedUpdate.load(from: location) == nil)

        // A file with the app's name isn't a bundle.
        try Data().write(to: root.appendingPathComponent("Ghostty Phil.app"))
        #expect(StagedUpdate.load(from: location) == nil)
        try fm.removeItem(at: root.appendingPathComponent("Ghostty Phil.app"))

        try fm.createDirectory(at: root.appendingPathComponent("Ghostty Phil.app"), withIntermediateDirectories: true)
        let update = try #require(StagedUpdate.load(from: location))
        #expect(update.shortRevision == "190f830c2ece")
        #expect(update.metadata.dirty)
        #expect(update.metadata.branch == "main")
        #expect(update.metadata.buildHost == "phillco@m5-studio")
        #expect(update.metadata.fingerprint == "f1")
        #expect(update.metadata.subject == "macos: a thing")
        #expect(update.isFastSwift)
        #expect(update.builtAt == (try date("2026-11-22T10:11:32")))

        // Missing build.json, then undecodable build.json.
        try fm.removeItem(at: root.appendingPathComponent("build.json"))
        #expect(StagedUpdate.load(from: location) == nil)
        try Data(#"{"revision": "abc"}"#.utf8).write(to: root.appendingPathComponent("build.json"))
        #expect(StagedUpdate.load(from: location) == nil)
    }

    @Test func fingerprintsDecide() {
        let running = RunningBuild(fingerprint: "a", revision: "abc", dirty: false, swift: "release")
        #expect(!staged(fingerprint: "a").isNewer(than: running))
        #expect(staged(fingerprint: "b").isNewer(than: running))
        // Matching fingerprints win over differing revisions.
        #expect(!staged(revision: "def", fingerprint: "a").isNewer(than: running))
    }

    @Test func cleanBuildsCompareRevisionAndSwift() {
        let running = RunningBuild(revision: "abc", dirty: false, swift: "release")
        #expect(!staged().isNewer(than: running))
        #expect(!staged(fingerprint: "only-staged").isNewer(than: running))
        #expect(staged(revision: "def").isNewer(than: running))
        #expect(staged(swift: "fast").isNewer(than: running))
        // Builds from before the Swift flavor was stamped are release builds.
        #expect(!staged(swift: nil).isNewer(than: RunningBuild(revision: "abc", dirty: false)))
        // An app ghostty-rebuild never stamped.
        #expect(staged().isNewer(than: RunningBuild()))
    }

    @Test func dirtyBuildsCompareBuildTimes() throws {
        let built = try date("2026-11-22T10:00:00")
        let running = RunningBuild(revision: "abc", dirty: true, swift: "release", builtAt: built)
        // The running build itself: same time, or the executable written a moment earlier.
        #expect(!staged(dirty: true).isNewer(than: running))
        #expect(!staged(dirty: true, builtAt: "2026-11-22T10:00:04").isNewer(than: running))
        #expect(staged(dirty: true, builtAt: "2026-11-22T10:05:00").isNewer(than: running))
        #expect(!staged(dirty: true, builtAt: "2026-11-22T09:00:00").isNewer(than: running))
        // A clean rebuild of a dirty running build's revision, and vice versa.
        #expect(staged(dirty: false, builtAt: "2026-11-22T10:05:00").isNewer(than: running))
        let cleanRunning = RunningBuild(revision: "abc", dirty: false, swift: "release", builtAt: built)
        #expect(staged(dirty: true, builtAt: "2026-11-22T10:05:00").isNewer(than: cleanRunning))
        // Unknown build times count as current.
        #expect(!staged(dirty: true, builtAt: "garbage").isNewer(than: running))
        #expect(!staged(dirty: true).isNewer(than: RunningBuild(revision: "abc", dirty: true, swift: "release")))
    }

    @Test func parsesTimestamps() throws {
        let local = try date("2026-11-22T10:11:32")
        let utc = try date("2026-11-22T10:11:32+00:00")
        let offset = TimeInterval(TimeZone.current.secondsFromGMT(for: local))
        #expect(utc.timeIntervalSince(local) == offset)
        #expect(StagedUpdate.parseDate("2026-11-22T10:11:32.123456") != nil)
        #expect(StagedUpdate.parseDate("yesterday") == nil)
    }

    @Test func formatsTimes() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let morning = try date("2026-11-22T09:16:00+00:00")
        let evening = try date("2026-11-22T21:05:00+00:00")
        #expect(StagedUpdate.clockTime(morning, timeZone: utc) == "9:16am")
        #expect(StagedUpdate.clockTime(evening, timeZone: utc) == "9:05pm")

        #expect(StagedUpdate.relativeAge(of: morning, now: morning.addingTimeInterval(20)) == "just now")
        #expect(StagedUpdate.relativeAge(of: morning, now: morning.addingTimeInterval(5 * 60)) == "5m ago")
        #expect(StagedUpdate.relativeAge(of: morning, now: morning.addingTimeInterval(3 * 3600)) == "3h ago")
        #expect(StagedUpdate.relativeAge(of: morning, now: morning.addingTimeInterval(3 * 86400)) == "3d ago")
        #expect(StagedUpdate.relativeAge(of: morning, now: morning.addingTimeInterval(-60)) == "just now")
    }
}

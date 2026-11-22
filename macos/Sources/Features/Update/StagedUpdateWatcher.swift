import AppKit
import os

/// Drives `UpdateViewModel` into `.staged` while `ghostty-rebuild` has a newer build
/// staged, and back to `.idle` when it goes away or matches the running app. Sparkle
/// states are left alone.
///
/// `ghostty-rebuild` swaps `staged/` in with `rename()`, so this watches the parent
/// directory, `staged/` and `staged/build.json`, re-arming after every check because
/// the inodes change. Activation and a slow timer cover a parent that doesn't exist
/// yet and in-place edits the sources can't see.
final class StagedUpdateWatcher: @unchecked Sendable {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ghostty", category: "staged-update")

    let location: StagedUpdateLocation
    private let running: RunningBuild
    private weak var model: UpdateViewModel?

    /// Everything below is confined to `queue`.
    private let queue = DispatchQueue(label: "com.mitchellh.ghostty.staged-update", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var timer: DispatchSourceTimer?
    private var pending: DispatchWorkItem?
    private var activeObserver: NSObjectProtocol?

    init(location: StagedUpdateLocation, running: RunningBuild, model: UpdateViewModel) {
        self.location = location
        self.running = running
        self.model = model
    }

    /// A watcher for the running app, or nil for builds `ghostty-rebuild` doesn't stage.
    static func forCurrentApp(model: UpdateViewModel) -> StagedUpdateWatcher? {
        guard let location = StagedUpdateLocation.forBundle(
            id: Bundle.main.bundleIdentifier,
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment) else { return nil }
        return .init(location: location, running: .current(), model: model)
    }

    deinit {
        if let activeObserver { NotificationCenter.default.removeObserver(activeObserver) }
        timer?.cancel()
        sources.forEach { $0.cancel() }
    }

    func start() {
        Self.logger.info("watching \(self.location.stagedDirectory.path, privacy: .public)")
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: nil
        ) { [weak self] _ in self?.scheduleCheck() }
        queue.async { [self] in
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.check() }
            timer.resume()
            self.timer = timer
            check()
        }
    }

    /// Coalesces bursts of file-system events into one check.
    func scheduleCheck() {
        queue.async { [self] in
            pending?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.check() }
            pending = item
            queue.asyncAfter(deadline: .now() + .milliseconds(150), execute: item)
        }
    }

    private func check() {
        dispatchPrecondition(condition: .onQueue(queue))
        // Re-arm before reading so a change during the read triggers another check.
        rearm()
        let staged = StagedUpdate.load(from: location)
        let available = staged.flatMap { $0.isNewer(than: running) ? $0 : nil }
        DispatchQueue.main.async { [weak self] in
            guard let model = self?.model else { return }
            Self.apply(available, to: model)
        }
    }

    private func rearm() {
        sources.forEach { $0.cancel() }
        let staged = location.stagedDirectory
        sources = [staged.deletingLastPathComponent(), staged, staged.appendingPathComponent("build.json")]
            .compactMap { watch($0) }
    }

    private func watch(_ url: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: queue)
        source.setEventHandler { [weak self] in self?.scheduleCheck() }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    static func apply(_ staged: StagedUpdate?, to model: UpdateViewModel) {
        switch model.state {
        case .idle:
            if let staged { model.state = .staged(staged) }
        case .staged(let current):
            if let staged {
                if staged != current {
                    model.stagedInstallError = nil
                    model.state = .staged(staged)
                }
            } else {
                model.stagedInstallError = nil
                model.state = .idle
            }
        default:
            // Sparkle owns every other state.
            break
        }
    }
}

/// Installs a staged build by kicking its LaunchAgent, which quits and relaunches Ghostty.
enum StagedUpdateInstaller {
    /// Runs `launchctl kickstart` off the main thread; returns a one-line error, or nil.
    static func install(_ staged: StagedUpdate) async -> String? {
        guard let label = staged.location.launchAgentLabel else { return "No updater for this build" }
        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            process.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
            let stderr = Pipe()
            process.standardError = stderr
            process.standardOutput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return error.localizedDescription
            }
            let output = stderr.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let status = process.terminationStatus
            guard status != 0 else { return nil }
            // 113: no such service, i.e. the LaunchAgent isn't loaded.
            if status == 113 { return "Updater not loaded (\(label))" }
            let message = String(bytes: output, encoding: .utf8)?
                .split(whereSeparator: \.isNewline).first?
                .trimmingCharacters(in: .whitespaces)
            return message.flatMap { $0.isEmpty ? nil : $0 } ?? "launchctl exited \(status)"
        }.value
    }

    /// The command palette's install: failures beep and wait in the popover.
    static func confirm(_ staged: StagedUpdate) {
        Task { @MainActor in
            guard let error = await install(staged) else { return }
            NSSound.beep()
            (NSApp.delegate as? AppDelegate)?.updateViewModel.stagedInstallError = error
        }
    }

    static func copyCommand(_ staged: StagedUpdate) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(staged.location.installCommand, forType: .string)
    }
}

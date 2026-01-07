import AppKit
import Foundation

/// ScriptableTerminal wraps a Ghostty.SurfaceView for AppleScript access.
/// This class conforms to Cocoa Scripting requirements and provides object specifiers.
@objc(ScriptableTerminal)
class ScriptableTerminal: NSObject {

    /// The underlying surface view. May become nil if the terminal is closed.
    weak var surfaceView: Ghostty.SurfaceView?

    /// Cached UUID for the terminal (survives view deallocation for specifier resolution)
    let id: UUID

    init(_ view: Ghostty.SurfaceView) {
        self.surfaceView = view
        self.id = view.id
        super.init()
    }

    // MARK: - Scriptable Properties

    /// Unique identifier for the terminal (for AppleScript "id" property)
    @objc var uniqueID: String {
        id.uuidString
    }

    /// Terminal title (for AppleScript "title" property)
    @objc var title: String {
        guard let view = surfaceView else { return "" }
        return view.title
    }

    /// Current working directory (for AppleScript "working directory" property)
    @objc var workingDirectory: String {
        guard let view = surfaceView else { return "" }
        return view.pwd ?? ""
    }

    /// Terminal screen contents (for AppleScript "contents" property)
    @objc var contents: String {
        guard let view = surfaceView else { return "" }
        // Access cached screen contents if available
        return view.cachedScreenContents.get()
    }

    /// Terminal kind - normal or quick (for AppleScript "kind" property)
    @objc var kind: FourCharCode {
        guard let view = surfaceView,
              let window = view.window else {
            return FourCharCode(0x6E6F726D) // 'norm'
        }

        if window.windowController is QuickTerminalController {
            return FourCharCode(0x7174726D) // 'qtrm'
        }
        return FourCharCode(0x6E6F726D) // 'norm'
    }

    // MARK: - Object Specifier

    override var objectSpecifier: NSScriptObjectSpecifier? {
        // Get our index in the terminals array - must be on main thread
        let terminals: [ScriptableTerminal]
        if Thread.isMainThread {
            terminals = MainActor.assumeIsolated {
                TerminalRegistry.shared.allTerminals
            }
        } else {
            var result: [ScriptableTerminal] = []
            DispatchQueue.main.sync {
                result = MainActor.assumeIsolated {
                    TerminalRegistry.shared.allTerminals
                }
            }
            terminals = result
        }

        guard let index = terminals.firstIndex(where: { $0.id == self.id }) else {
            return nil
        }

        // Create container specifier for the application
        let containerSpecifier = NSApp.objectSpecifier

        // Create index specifier for this terminal
        guard let classDesc = NSApp.classDescription as? NSScriptClassDescription else {
            return nil
        }

        return NSIndexSpecifier(
            containerClassDescription: classDesc,
            containerSpecifier: containerSpecifier,
            key: "terminals",
            index: index
        )
    }
}

// MARK: - Terminal Registry

/// Singleton that manages scriptable terminal instances.
/// Provides the bridge between Cocoa Scripting and Ghostty's terminal infrastructure.
final class TerminalRegistry {
    static let shared = TerminalRegistry()

    private init() {}

    /// Returns all current terminals as ScriptableTerminal objects.
    /// This reuses the same enumeration logic as TerminalQuery in App Intents.
    @MainActor
    var allTerminals: [ScriptableTerminal] {
        // Find all terminal windows
        let controllers = NSApp.windows.compactMap {
            $0.windowController as? BaseTerminalController
        }

        // Get all surface views and wrap them
        let surfaces = controllers.flatMap {
            $0.surfaceTree.root?.leaves() ?? []
        }

        return surfaces.map { ScriptableTerminal($0) }
    }

    /// Find a terminal by its UUID
    @MainActor
    func terminal(withID id: UUID) -> ScriptableTerminal? {
        allTerminals.first { $0.id == id }
    }

    /// Find a terminal by its UUID string
    @MainActor
    func terminal(withIDString idString: String) -> ScriptableTerminal? {
        guard let uuid = UUID(uuidString: idString) else { return nil }
        return terminal(withID: uuid)
    }
}

// MARK: - NSApplication Extension for Scripting

extension NSApplication {
    /// Returns all terminals for AppleScript access.
    /// This is the "terminals" element defined in the SDEF.
    @objc var terminals: [ScriptableTerminal] {
        // AppleScript calls come on the main thread
        if Thread.isMainThread {
            return MainActor.assumeIsolated {
                TerminalRegistry.shared.allTerminals
            }
        } else {
            var result: [ScriptableTerminal] = []
            DispatchQueue.main.sync {
                result = MainActor.assumeIsolated {
                    TerminalRegistry.shared.allTerminals
                }
            }
            return result
        }
    }

    /// Returns the application version for AppleScript.
    @objc var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}

import AppKit
import UniformTypeIdentifiers

/// An existing local file or directory named by a clicked link, optionally
/// followed by `:LINE` or `:LINE:COLUMN` as compilers and grep print.
struct LocalFileLink: Equatable {
    /// The canonical target with symlinks resolved.
    let url: URL
    let line: Int?
    let column: Int?

    /// Resolves an absolute, `~` or relative path, or a `file:` URL, to an
    /// existing filesystem object. Returns nil for other URLs and for paths
    /// that do not exist, with or without a line suffix.
    init?(_ value: String, pwd: String?) {
        let path: String
        var fragmentLine: (line: Int, column: Int?)?
        // Values such as "notes.md:12" parse with a "notes.md" scheme, so only
        // file URLs are decoded; everything else is tried as a path and web
        // URLs fall out because no such path exists.
        if let url = URL(string: value), url.scheme?.lowercased() == "file" {
            guard url.query == nil else { return nil }
            if let fragment = url.fragment {
                guard let parsed = Self.lineFragment(fragment) else { return nil }
                fragmentLine = parsed
            }
            if let host = url.host, !host.isEmpty, host.caseInsensitiveCompare("localhost") != .orderedSame {
                return nil
            }
            path = url.path
        } else {
            path = value
        }
        guard !path.isEmpty, !UntrustedURL.containsUnsafeCharacters(path) else { return nil }

        if let url = Self.existing(path, pwd: pwd) {
            self.init(url: url, line: fragmentLine?.line, column: fragmentLine?.column)
            return
        }

        // Strip ":LINE" or ":LINE:COLUMN" only when the full path does not
        // exist, so file names that really contain colons still resolve.
        guard let match = path.wholeMatch(of: #/(.+?):(\d+)(?::(\d+))?:?/#),
              let url = Self.existing(String(match.1), pwd: pwd)
        else { return nil }
        self.init(url: url, line: Int(match.2), column: match.3.flatMap { Int($0) })
    }

    init(url: URL, line: Int?, column: Int?) {
        self.url = url
        self.line = line
        self.column = column
    }

    /// GitHub-style line anchors: `L20`, `L20C5`, `L20-L27` (opens at the start).
    private static func lineFragment(_ fragment: String) -> (line: Int, column: Int?)? {
        guard let m = fragment.wholeMatch(of: #/L(\d+)(?:C(\d+))?(?:-L\d+(?:C\d+)?)?/#),
              let line = Int(m.1)
        else { return nil }
        return (line, m.2.flatMap { Int($0) })
    }

    private static func existing(_ path: String, pwd: String?) -> URL? {
        var expanded = NSString(string: path).expandingTildeInPath
        if !expanded.hasPrefix("/") {
            guard let pwd, !pwd.isEmpty else { return nil }
            expanded = NSString(string: pwd).appendingPathComponent(expanded)
        }
        let url = URL(filePath: expanded).standardizedFileURL.resolvingSymlinksInPath()
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// The path with its line suffix, as editor command-line tools accept.
    var editorArgument: String {
        var result = url.path
        guard let line else { return result }
        result += ":\(line)"
        if let column { result += ":\(column)" }
        return result
    }

    enum Disposition: Equatable {
        /// Open in the configured or default text editor.
        case editor
        /// Open in the default application, such as Preview or Finder.
        case defaultApplication
        /// Reveal in Finder rather than run it.
        case reveal
    }

    /// What a plain click does with this target.
    var disposition: Disposition {
        let values = try? url.resourceValues(forKeys: [.contentTypeKey, .isDirectoryKey, .isExecutableKey])
        let type = values?.contentType
        let isDirectory = values?.isDirectory == true

        if isDirectory {
            // Bundles such as .app are directories that Launch Services runs.
            if let type, type.conforms(to: .bundle) || type.conforms(to: .package) { return .reveal }
            return .defaultApplication
        }
        if let type, type.conforms(to: .html) { return line != nil ? .editor : .defaultApplication }
        // Scripts conform to plain text, so check text before executables.
        if let type, type.conforms(to: .text) { return .editor }
        // Extensionless scripts are executable text; editing them is safe.
        if values?.isExecutable == true { return isShebangScript ? .editor : .reveal }
        if let type, type.conforms(to: .executable) || type.conforms(to: .application) { return .reveal }
        if line != nil { return .editor }
        // Unknown types (dynamic UTIs, bare data) have no useful viewer.
        guard let type, !type.isDynamic, type != .data,
              NSWorkspace.shared.urlForApplication(toOpen: url) != nil
        else { return .editor }
        return .defaultApplication
    }

    private var isShebangScript: Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data("#!".utf8)
    }
}

/// Opens local file links without prompting.
enum LocalFileLinkOpener {
    /// The `link-editor` setting.
    private static var editor: String? {
        (NSApp.delegate as? AppDelegate)?.ghostty.config.linkEditor
    }

    static func open(_ link: LocalFileLink) {
        switch link.disposition {
        case .editor: openInEditor(link)
        case .defaultApplication: NSWorkspace.shared.open(link.url)
        case .reveal: reveal(link)
        }
    }

    static func reveal(_ link: LocalFileLink) {
        NSWorkspace.shared.activateFileViewerSelecting([link.url])
    }

    static func openInEditor(_ link: LocalFileLink) {
        if let editor {
            let editorURL = URL(filePath: NSString(string: editor).expandingTildeInPath)
            if editorURL.pathExtension == "app" {
                open(link.url, with: editorURL)
                return
            }
            let process = Process()
            process.executableURL = editorURL
            process.arguments = [link.editorArgument]
            do {
                try process.run()
                return
            } catch {
                Ghostty.logger.warning("link-editor failed to launch: \(error.localizedDescription, privacy: .public)")
            }
        }
        if let app = NSWorkspace.shared.defaultTextEditor {
            open(link.url, with: app)
        } else {
            NSWorkspace.shared.open(link.url)
        }
    }

    static func open(_ url: URL, with app: URL) {
        NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}

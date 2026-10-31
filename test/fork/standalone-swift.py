#!/usr/bin/env python3
"""Run focused fork Swift tests without launching Ghostty or posting input.

This compiles real split-tree, tab-color, and NSEvent extension sources in a
temporary Swift package. It does not replace a full app compile or verify native
window, focus, AppleScript command routing, or rendering behavior. ghosttyMods is
extracted unchanged from production into a minimal Ghostty namespace; the other
production Swift sources and C header are used in full.

Example: python3 test/fork/standalone-swift.py -j 4 /path/to/ghostty
"""

import argparse
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
import xml.etree.ElementTree as ET


def extract_ghostty_mods(source: str) -> str:
    """Extract the complete production function by balancing its body braces."""
    signature = "    static func ghosttyMods("
    if source.count(signature) != 1:
        raise ValueError("expected exactly one production ghosttyMods function")
    start = source.index(signature)
    opening = source.index("{", start)
    depth = 0
    for index in range(opening, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                return source[start : index + 1]
    raise ValueError("unterminated production ghosttyMods function")


def scripting_dictionary_test(repo: Path) -> str:
    """Test the actual Swift color mapping against the actual scripting dictionary."""
    root = ET.parse(repo / "macos/Ghostty.sdef").getroot()
    enumerations = root.findall(".//enumeration[@name='tab color']")
    if len(enumerations) != 1:
        raise ValueError("expected exactly one tab color enumeration in Ghostty.sdef")
    codes = {}
    for entry in enumerations[0].findall("enumerator"):
        name = entry.attrib["name"]
        code = entry.attrib["code"].encode("ascii")
        if len(code) != 4 or name in codes:
            raise ValueError(f"invalid or duplicate tab color enumerator: {name}")
        codes[name] = int.from_bytes(code, "big")
    if len(codes) != 10 or len(set(codes.values())) != 10:
        raise ValueError("expected ten distinct AppleScript tab color codes")
    entries = ",\n".join(
        f"            {json.dumps(name)}: 0x{code:08X}" for name, code in codes.items()
    )
    return (
        """import AppKit
import Testing
@testable import ForkCore

struct ScriptingDictionaryTests {
    @Test func tabColorDictionaryMatchesProduction() throws {
        let dictionary: [String: FourCharCode] = [
"""
        + entries
        + "\n"
        + """
        ]
        #expect(Set(dictionary.keys) == Set(TerminalTabColor.allCases.map { String(describing: $0) }))
        for color in TerminalTabColor.allCases {
            let code = try #require(dictionary[String(describing: color)])
            #expect(color.appleScriptCode == code)
            #expect(TerminalTabColor(appleScriptCode: code) == color)
        }
    }
}
"""
    )


def prepare_package(repo: Path, package: Path) -> None:
    sources = (
        "macos/Sources/Features/Splits/SplitTree.swift",
        "macos/Sources/Helpers/Extensions/Array+Extension.swift",
        "macos/Sources/Features/Terminal/TerminalTabColor.swift",
        "macos/Sources/Ghostty/NSEvent+Extension.swift",
    )
    tests = (
        "macos/Tests/Splits/SplitTreeTests.swift",
        "macos/Tests/Terminal/TerminalTabColorTests.swift",
        "macos/Tests/Ghostty/NSEventViewportTests.swift",
    )
    for relative in (
        *sources,
        *tests,
        "include/ghostty.h",
        "macos/Sources/Ghostty/Ghostty.Input.swift",
    ):
        if not (repo / relative).is_file():
            raise ValueError(f"missing required source: {repo / relative}")

    core = package / "Sources/ForkCore"
    test_target = package / "Tests/ForkTests"
    c_module = package / "Sources/GhosttyKit"
    core.mkdir(parents=True)
    test_target.mkdir(parents=True)
    (c_module / "include").mkdir(parents=True)

    for relative in sources:
        source = repo / relative
        (core / source.name).symlink_to(source)
    for relative in tests:
        source = repo / relative
        contents = source.read_text()
        original_import = "@testable import Ghostty"
        if contents.count(original_import) != 1:
            raise ValueError(f"expected one Ghostty test import in {source}")
        (test_target / source.name).write_text(
            contents.replace(original_import, "@testable import ForkCore")
        )

    function = extract_ghostty_mods(
        (repo / "macos/Sources/Ghostty/Ghostty.Input.swift").read_text()
    )
    (core / "GhosttyMods.swift").write_text(
        "import Cocoa\nimport GhosttyKit\n\nenum Ghostty {\n" + function + "\n}\n"
    )
    (test_target / "ScriptingDictionaryTests.swift").write_text(
        scripting_dictionary_test(repo)
    )
    shutil.copyfile(repo / "include/ghostty.h", c_module / "include/ghostty.h")
    (c_module / "module.modulemap").write_text(
        'module GhosttyKit [system] {\n    header "include/ghostty.h"\n    export *\n}\n'
    )
    (package / "Package.swift").write_text("""// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GhosttyForkValidation",
    platforms: [.macOS(.v14)],
    targets: [
        .systemLibrary(name: "GhosttyKit"),
        .target(name: "ForkCore", dependencies: ["GhosttyKit"]),
        .testTarget(name: "ForkTests", dependencies: ["ForkCore", "GhosttyKit"]),
    ],
    swiftLanguageModes: [.v5]
)
""")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "repo",
        type=Path,
        nargs="?",
        default=Path(__file__).resolve().parents[2],
        help="repository root (default: this script's checkout)",
    )
    parser.add_argument(
        "-j", "--jobs", type=int, default=4, help="Swift build jobs (default: 4)"
    )
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be at least 1")

    with tempfile.TemporaryDirectory(prefix="ghostty-fork-swift-") as directory:
        package = Path(directory)
        try:
            prepare_package(args.repo.expanduser().resolve(), package)
        except (OSError, ValueError, ET.ParseError) as error:
            parser.error(str(error))
        print(
            "Running focused Swift source tests; full app compilation and UI behavior are not covered.",
            flush=True,
        )
        return subprocess.run(
            ["swift", "test", "--package-path", str(package), "-j", str(args.jobs)],
            check=False,
        ).returncode


if __name__ == "__main__":
    raise SystemExit(main())

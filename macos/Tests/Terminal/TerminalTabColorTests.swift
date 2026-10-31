import AppKit
import Testing
@testable import Ghostty

struct TerminalTabColorTests {
    @Test(arguments: [
        (TerminalTabColor.none, "none"),
        (.blue, "blue"),
        (.purple, "prpl"),
        (.pink, "pink"),
        (.red, "red "),
        (.orange, "orng"),
        (.yellow, "ylow"),
        (.green, "gren"),
        (.teal, "teal"),
        (.graphite, "grph"),
    ])
    func appleScriptCodeRoundTrips(color: TerminalTabColor, code: String) {
        let expected = code.utf8.reduce(FourCharCode(0)) { ($0 << 8) | FourCharCode($1) }
        #expect(color.appleScriptCode == expected)
        #expect(TerminalTabColor(appleScriptCode: expected) == color)
    }

    @Test(arguments: [FourCharCode(0), 0xFFFF_FFFF, 0x7265_6400, 0x7075_7270])
    func unknownAppleScriptCodesAreRejected(code: FourCharCode) {
        #expect(TerminalTabColor(appleScriptCode: code) == nil)
    }

    @Test func everyColorHasADistinctCode() {
        #expect(TerminalTabColor.allCases.count == 10)
        #expect(Set(TerminalTabColor.allCases.map(\.appleScriptCode)).count == 10)
    }
}

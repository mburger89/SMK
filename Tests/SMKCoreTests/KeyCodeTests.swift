import Testing
@testable import SMKCore

/// Deliberately a change-detector over the generated vocabulary. KeyCode is
/// generated into two repos from ~/esp/SMK/keycodes.json; a bad regeneration
/// silently changes what a keymap token means on a real keyboard, with no
/// error anywhere. Failing here is the cheapest place to notice.
@Suite("KeyCode matches the HID usage table")
struct KeyCodeTests {
    @Test("rawValue is the HID usage, not the enum ordinal")
    func rawValuesAreHIDUsages() {
        #expect(KeyCode.a.rawValue == 0x04)
        #expect(KeyCode.z.rawValue == 0x1D)
        #expect(KeyCode.k1.rawValue == 0x1E)
        #expect(KeyCode.k0.rawValue == 0x27)
        #expect(KeyCode.backslash.rawValue == 0x31)
        #expect(KeyCode.semicolon.rawValue == 0x33)
        #expect(KeyCode.application.rawValue == 0x65)
        #expect(KeyCode.noKey.rawValue == 0x00)
        #expect(KeyCode.transparent.rawValue == 0xFF)
    }

    @Test("fromCString resolves the tokens LayerEngine accepts")
    func fromCStringResolvesKnownTokens() {
        #expect(KeyCode.fromCString("a") == .a)
        #expect(KeyCode.fromCString("1") == .k1)
        #expect(KeyCode.fromCString("leftBracket") == .leftBracket)
        #expect(KeyCode.fromCString("left") == .leftArrow)
        #expect(KeyCode.fromCString("application") == .application)
    }

    @Test("fromCString falls through to noKey for unknown input")
    func fromCStringRejectsUnknown() {
        #expect(KeyCode.fromCString("") == .noKey)
        #expect(KeyCode.fromCString("nonsense") == .noKey)
        #expect(KeyCode.fromCString("A") == .noKey)   // case-sensitive by design
    }
}

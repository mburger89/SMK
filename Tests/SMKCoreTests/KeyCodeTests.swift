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

    @Test("the previously missing keyboard-page usages are present and correct")
    func newUsagesArePinned() {
        #expect(KeyCode.nonUSHash.rawValue == 0x32)
        #expect(KeyCode.insert.rawValue == 0x49)
        #expect(KeyCode.numLock.rawValue == 0x53)
        #expect(KeyCode.keypad1.rawValue == 0x59)
        #expect(KeyCode.keypad0.rawValue == 0x62)
        #expect(KeyCode.nonUSBackslash.rawValue == 0x64)
        #expect(KeyCode.keyboardPower.rawValue == 0x66)
        #expect(KeyCode.keypadEqual.rawValue == 0x67)
        #expect(KeyCode.f13.rawValue == 0x68)
        #expect(KeyCode.f24.rawValue == 0x73)
        #expect(KeyCode.paste.rawValue == 0x7D)
        #expect(KeyCode.lockingCapsLock.rawValue == 0x82)
        #expect(KeyCode.international1.rawValue == 0x87)
        #expect(KeyCode.language9.rawValue == 0x98)
        #expect(KeyCode.exsel.rawValue == 0xA4)
    }

    @Test("new tokens resolve through fromCString")
    func newTokensResolve() {
        #expect(KeyCode.fromCString("insert") == .insert)
        #expect(KeyCode.fromCString("keypadAsterisk") == .keypadAsterisk)
        #expect(KeyCode.fromCString("f24") == .f24)
        #expect(KeyCode.fromCString("international1") == .international1)
        #expect(KeyCode.fromCString("exsel") == .exsel)
    }
}

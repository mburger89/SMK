import Testing
@testable import SMKCore

@Test func modifierRawValuesAreDistinctBitFlags() {
    #expect(Modifier.leftCtrl.rawValue == 0b00000001)
    #expect(Modifier.leftShift.rawValue == 0b00000010)
    #expect(Modifier.leftAlt.rawValue == 0b00000100)
    #expect(Modifier.leftGUI.rawValue == 0b00001000)
    #expect(Modifier.rightCtrl.rawValue == 0b00010000)
    #expect(Modifier.rightShift.rawValue == 0b00100000)
    #expect(Modifier.rightAlt.rawValue == 0b01000000)
    #expect(Modifier.rightGUI.rawValue == 0b10000000)
}

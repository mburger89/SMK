import Testing
@testable import SMKCore

@Test func hidReportAddKeyFillsFirstEmptySlot() {
    var report = HIDReport()
    report.addKey(0x04)
    report.addKey(0x05)
    #expect(report.keys == [0x04, 0x05, 0, 0, 0, 0])
}

@Test func hidReportAddKeyIgnoresZeroKeycode() {
    var report = HIDReport()
    report.addKey(0x00)
    #expect(report.keys == [0, 0, 0, 0, 0, 0])
}

@Test func hidReportAddKeyDropsBeyondSixSimultaneousKeys() {
    var report = HIDReport()
    for code: UInt8 in [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A] {
        report.addKey(code)
    }
    #expect(report.keys == [0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
}

@Test func hidReportResetClearsModifierAndKeys() {
    var report = HIDReport()
    report.addKey(0x04)
    report.addModifier(.leftShift)
    report.reset()
    #expect(report.modifier == 0)
    #expect(report.keys == [0, 0, 0, 0, 0, 0])
}

@Test func hidReportAddModifierOrsBits() {
    var report = HIDReport()
    report.addModifier(.leftShift)
    report.addModifier(.leftCtrl)
    #expect(report.modifier == Modifier.leftShift.rawValue | Modifier.leftCtrl.rawValue)
}

import Testing
@testable import SMKCore

@Test func hidReportAddKeyFillsFirstEmptySlot() {
    var report = HIDReport()
    report.addKey(0x04)
    report.addKey(0x05)
    #expect(report.withKeyBytes { p in (0..<6).map { p[$0] } } == [0x04, 0x05, 0, 0, 0, 0])
}

@Test func hidReportAddKeyIgnoresZeroKeycode() {
    var report = HIDReport()
    report.addKey(0x00)
    #expect(report.withKeyBytes { p in (0..<6).map { p[$0] } } == [0, 0, 0, 0, 0, 0])
}

@Test func hidReportAddKeyDropsBeyondSixSimultaneousKeys() {
    var report = HIDReport()
    for code: UInt8 in [0x04, 0x05, 0x06, 0x07, 0x08, 0x09, 0x0A] {
        report.addKey(code)
    }
    #expect(report.withKeyBytes { p in (0..<6).map { p[$0] } } == [0x04, 0x05, 0x06, 0x07, 0x08, 0x09])
}

@Test func hidReportResetClearsModifierAndKeys() {
    var report = HIDReport()
    report.addKey(0x04)
    report.addModifier(.leftShift)
    report.reset()
    #expect(report.modifier == 0)
    #expect(report.withKeyBytes { p in (0..<6).map { p[$0] } } == [0, 0, 0, 0, 0, 0])
}

@Test func hidReportAddModifierOrsBits() {
    var report = HIDReport()
    report.addModifier(.leftShift)
    report.addModifier(.leftCtrl)
    #expect(report.modifier == Modifier.leftShift.rawValue | Modifier.leftCtrl.rawValue)
}

@Test func reportsDifferingOnlyInLastSlotAreUnequal() {
    var a = HIDReport(), b = HIDReport()
    for k: UInt8 in [4, 5, 6, 7, 8] { a.addKey(k); b.addKey(k) }
    a.addKey(9); b.addKey(10)
    #expect(a.keys[5] == 9 && b.keys[5] == 10)
    #expect(a != b)
}

@Test func withKeyBytesExposesAllSixSlotsInOrder() {
    var r = HIDReport()
    for k: UInt8 in [4, 5, 6] { r.addKey(k) }
    let bytes = r.withKeyBytes { p in (0..<6).map { p[$0] } }
    #expect(bytes == [4, 5, 6, 0, 0, 0])
}

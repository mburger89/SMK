import Testing
@testable import SMKCore

@Test func lowercaseNeedsNoShift() {
    let a = asciiKeystroke(UInt8(ascii: "a"))
    #expect(a?.usage == KeyCode.a.rawValue)
    #expect(a?.shift == false)
}

@Test func uppercaseIsShiftedLowercase() {
    #expect(asciiKeystroke(UInt8(ascii: "A"))?.usage == KeyCode.a.rawValue)
    #expect(asciiKeystroke(UInt8(ascii: "A"))?.shift == true)
}

@Test func shiftedSymbolsShareTheirDigitsUsage() {
    #expect(asciiKeystroke(UInt8(ascii: "!"))?.usage
            == asciiKeystroke(UInt8(ascii: "1"))?.usage)
    #expect(asciiKeystroke(UInt8(ascii: "!"))?.shift == true)
}

@Test func everyPrintableByteMaps() {
    for b in UInt8(0x20)...UInt8(0x7E) {
        #expect(asciiKeystroke(b) != nil, "no mapping for byte \(b)")
    }
}

@Test func nonPrintableBytesAreRejected() {
    #expect(asciiKeystroke(0x00) == nil)
    #expect(asciiKeystroke(0x1F) == nil)
    #expect(asciiKeystroke(0x7F) == nil)
    #expect(asciiKeystroke(0x80) == nil)
}

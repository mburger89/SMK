import Testing
@testable import SMKCore

@Test func clampCountRejectsNegative() {
    #expect(smkLedStripClampCount(-1, maxLeds: 60) == 0)
}

@Test func clampCountPassesThroughWithinRange() {
    #expect(smkLedStripClampCount(30, maxLeds: 60) == 30)
}

@Test func clampCountClampsAboveMax() {
    #expect(smkLedStripClampCount(999, maxLeds: 60) == 60)
}

@Test func clampCountAtMaxStaysAtMax() {
    #expect(smkLedStripClampCount(60, maxLeds: 60) == 60)
}

@Test func setPixelWritesGrbWireOrder() {
    var pixels = [UInt8](repeating: 0, count: 3 * 3)
    smkLedStripSetPixel(&pixels, index: 1, numLeds: 3, r: 0x11, g: 0x22, b: 0x33)
    // Wire order is G, R, B -- not R, G, B.
    #expect(pixels[3] == 0x22)
    #expect(pixels[4] == 0x11)
    #expect(pixels[5] == 0x33)
}

@Test func setPixelOutOfBoundsNegativeIndexIsNoOp() {
    var pixels = [UInt8](repeating: 0xAA, count: 3 * 3)
    smkLedStripSetPixel(&pixels, index: -1, numLeds: 3, r: 1, g: 2, b: 3)
    #expect(pixels == [UInt8](repeating: 0xAA, count: 9))
}

@Test func setPixelOutOfBoundsAtNumLedsIsNoOp() {
    var pixels = [UInt8](repeating: 0xAA, count: 3 * 3)
    smkLedStripSetPixel(&pixels, index: 3, numLeds: 3, r: 1, g: 2, b: 3)
    #expect(pixels == [UInt8](repeating: 0xAA, count: 9))
}

@Test func setPixelAtBoundaryIndexSucceeds() {
    var pixels = [UInt8](repeating: 0, count: 3 * 3)
    smkLedStripSetPixel(&pixels, index: 2, numLeds: 3, r: 0x44, g: 0x55, b: 0x66)
    #expect(pixels[6] == 0x55)
    #expect(pixels[7] == 0x44)
    #expect(pixels[8] == 0x66)
}

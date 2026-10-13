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

// The drivers keep their pixels in a fixed-size InlineArray and hand
// smkLedStripSetPixel a MutableSpan over it, so the tests do the same.
private func allBytes(_ pixels: InlineArray<9, UInt8>, equal value: UInt8) -> Bool {
    for i in 0..<9 where pixels[i] != value { return false }
    return true
}

@Test func setPixelWritesGrbWireOrder() {
    var pixels = InlineArray<9, UInt8>(repeating: 0)
    var span = pixels.mutableSpan
    smkLedStripSetPixel(&span, index: 1, numLeds: 3, r: 0x11, g: 0x22, b: 0x33)
    // Wire order is G, R, B -- not R, G, B.
    #expect(pixels[3] == 0x22)
    #expect(pixels[4] == 0x11)
    #expect(pixels[5] == 0x33)
}

@Test func setPixelOutOfBoundsNegativeIndexIsNoOp() {
    var pixels = InlineArray<9, UInt8>(repeating: 0xAA)
    var span = pixels.mutableSpan
    smkLedStripSetPixel(&span, index: -1, numLeds: 3, r: 1, g: 2, b: 3)
    #expect(allBytes(pixels, equal: 0xAA))
}

@Test func setPixelOutOfBoundsAtNumLedsIsNoOp() {
    var pixels = InlineArray<9, UInt8>(repeating: 0xAA)
    var span = pixels.mutableSpan
    smkLedStripSetPixel(&span, index: 3, numLeds: 3, r: 1, g: 2, b: 3)
    #expect(allBytes(pixels, equal: 0xAA))
}

@Test func setPixelAtBoundaryIndexSucceeds() {
    var pixels = InlineArray<9, UInt8>(repeating: 0)
    var span = pixels.mutableSpan
    smkLedStripSetPixel(&span, index: 2, numLeds: 3, r: 0x44, g: 0x55, b: 0x66)
    #expect(pixels[6] == 0x55)
    #expect(pixels[7] == 0x44)
    #expect(pixels[8] == 0x66)
}

// numLeds is the live chain length, which can exceed what a short span
// holds; the write must stay a no-op rather than trap on the span.
@Test func setPixelPastTheSpanIsNoOp() {
    var pixels = InlineArray<9, UInt8>(repeating: 0xAA)
    var span = pixels.mutableSpan
    smkLedStripSetPixel(&span, index: 3, numLeds: 60, r: 1, g: 2, b: 3)
    #expect(allBytes(pixels, equal: 0xAA))
}

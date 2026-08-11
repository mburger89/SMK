// Shared SK6812/WS2812 pixel-buffer logic: LED-count clamping and GRB
// wire-order packing. Extracted from what were two independent,
// byte-identical copies of this logic (Sources/smk/LedStripDriverRMT.swift
// [ESP32-C6, RMT-based] and ports/rp2040/LedStripDriverPIO.swift
// [smk_kbd_rp2040, PIO-based]). Pure logic, zero hardware calls —
// host-testable.

// Clamps a requested LED count to the driver's fixed-size pixel buffer.
// Negative counts (which a caller should never pass, but the C-facing
// entry point takes a signed Int32) clamp to 0 rather than underflowing;
// counts past `maxLeds` clamp down rather than overrunning the buffer.
public func smkLedStripClampCount(_ requestedNumLeds: Int32, maxLeds: Int) -> Int {
    var count = Int(requestedNumLeds)
    if count < 0 { count = 0 }
    if count > maxLeds { count = maxLeds }
    return count
}

// Writes one pixel's RGB triplet into `pixels` at `index`, reordered to
// the G, R, B wire order SK6812/WS2812 chains expect. Out-of-range
// indices (negative, or >= numLeds) are a silent no-op, matching the
// bounds guard both port drivers had inline before this was extracted —
// a caller mustn't be able to corrupt a neighboring pixel or crash by
// passing a bad index.
public func smkLedStripSetPixel(_ pixels: inout [UInt8], index: Int32, numLeds: Int, r: UInt8, g: UInt8, b: UInt8) {
    guard index >= 0, Int(index) < numLeds else { return }
    let i = Int(index)
    pixels[i * 3 + 0] = g
    pixels[i * 3 + 1] = r
    pixels[i * 3 + 2] = b
}

import Testing
@testable import SMKCore

@Test func crc32MatchesKnownVector() {
    let bytes: [UInt8] = Array("123456789".utf8)
    let crc = bytes.withUnsafeBufferPointer { smkCrc32($0.baseAddress!, $0.count) }
    #expect(crc == 0xCBF4_3926) // standard CRC-32 check value for "123456789"
}

@Test func frameValidateRejectsTruncatedFrame() {
    let short: [UInt8] = [0x53, 0x4D, 0x4B, 0x4D, 1, 0, 0]
    let result = short.withUnsafeBufferPointer { smkKeymapFrameValidate($0.baseAddress!, frameLen: $0.count) }
    #expect(result == nil)
}

@Test func frameValidateRejectsBadMagic() {
    var frame = [UInt8](repeating: 0, count: 11)
    frame[0] = 0x00 // wrong magic
    let result = frame.withUnsafeBufferPointer { smkKeymapFrameValidate($0.baseAddress!, frameLen: $0.count) }
    #expect(result == nil)
}

@Test func frameValidateRejectsWrongVersion() {
    var frame = [UInt8](repeating: 0, count: 11)
    frame[0] = 0x53; frame[1] = 0x4D; frame[2] = 0x4B; frame[3] = 0x4D
    frame[4] = 1 // wrong version -- version 1 was the retired JSON frame; frame format version is now 2
    let result = frame.withUnsafeBufferPointer { smkKeymapFrameValidate($0.baseAddress!, frameLen: $0.count) }
    #expect(result == nil)
}

@Test func frameValidateRejectsJsonLenOverMax() {
    var frame = [UInt8](repeating: 0, count: 11)
    frame[0] = 0x53; frame[1] = 0x4D; frame[2] = 0x4B; frame[3] = 0x4D; frame[4] = 2
    // jsonLen = smkKeymapMaxLen + 1, little-endian
    let overMax = smkKeymapMaxLen + 1
    frame[5] = UInt8(overMax & 0xFF)
    frame[6] = UInt8((overMax >> 8) & 0xFF)
    let result = frame.withUnsafeBufferPointer { smkKeymapFrameValidate($0.baseAddress!, frameLen: $0.count) }
    #expect(result == nil)
}

@Test func frameValidateRejectsCrcMismatch() {
    var frame = [UInt8](repeating: 0, count: 11 + 4)
    frame[0] = 0x53; frame[1] = 0x4D; frame[2] = 0x4B; frame[3] = 0x4D; frame[4] = 2
    frame[5] = 4; frame[6] = 0 // jsonLen = 4
    // bytes 7-10 (stored CRC) left at 0 — won't match the real CRC of frame[11..<15]
    frame[11] = 0x7B; frame[12] = 0x7D // arbitrary payload bytes
    let result = frame.withUnsafeBufferPointer { smkKeymapFrameValidate($0.baseAddress!, frameLen: $0.count) }
    #expect(result == nil)
}

@Test func crc32OfZeroLengthInputIsWellDefined() {
    // Loop body never executes for len == 0, so this reduces to the
    // initial 0xFFFFFFFF XORed with the final 0xFFFFFFFF -- i.e. 0. This
    // asserts that fixed value rather than merely "doesn't crash". Uses a
    // non-empty backing array (with a real baseAddress) but passes
    // len: 0, so the pointer is never dereferenced.
    let bytes: [UInt8] = [0xAB]
    let crc = bytes.withUnsafeBufferPointer { smkCrc32($0.baseAddress!, 0) }
    #expect(crc == 0)
}

@Test func writeHeaderThenValidateRoundTrips() {
    var frame = [UInt8](repeating: 0, count: 11 + 4)
    let payload: [UInt8] = [0x7B, 0x7D, 0x00, 0x00]
    for i in 0..<4 { frame[11 + i] = payload[i] }
    let crc = payload.withUnsafeBufferPointer { smkCrc32($0.baseAddress!, $0.count) }
    frame.withUnsafeMutableBufferPointer { smkKeymapFrameWriteHeader($0.baseAddress!, jsonLen: 4, crc32: crc) }
    let result = frame.withUnsafeBufferPointer { smkKeymapFrameValidate($0.baseAddress!, frameLen: $0.count) }
    #expect(result == 4)
}

// MARK: - Version 2 binary payload migration

// Duplicated from KeymapBinaryTests.swift's private `samplePayload` rather
// than shared: this task's brief scopes edits to KeymapFrame.swift,
// LayerEngine.swift and this file only (a sibling task is mid-flight on
// other files in this same tree), so widening that helper's access level in
// KeymapBinaryTests.swift is out of scope here. Keep the two copies in sync
// if the wire format's header/cell layout ever changes.
//
// Builds a minimal valid payload: 1x2 matrix, `layerCount` layers, no macros.
private func samplePayload(layerCount: Int) -> [UInt8] {
    var b: [UInt8] = [1, 2, 1, UInt8(layerCount), 0, 0]  // header
    b += [5]        // rows[]  GPIO 5
    b += [6, 7]     // cols[]  GPIO 6,7
    for _ in 0..<layerCount {
        b += [1, KeyCode.a.rawValue]   // key:a
        b += [5, 0]                    // trans
    }
    return b
}

/// Wraps a payload in a frame: "SMKM" + version + length(LE) + crc32(LE).
private func frame(payload: [UInt8], version: UInt8) -> [UInt8] {
    var f: [UInt8] = Array("SMKM".utf8)
    f.append(version)
    f.append(UInt8(payload.count & 0xFF))
    f.append(UInt8((payload.count >> 8) & 0xFF))
    let crc = payload.withUnsafeBufferPointer { smkCrc32($0.baseAddress!, $0.count) }
    f.append(UInt8(crc & 0xFF))
    f.append(UInt8((crc >> 8) & 0xFF))
    f.append(UInt8((crc >> 16) & 0xFF))
    f.append(UInt8((crc >> 24) & 0xFF))
    return f + payload
}

@Test func versionOneFrameIsRejected() {
    // The migration story: the frame never moves, so an old JSON frame
    // fails a clean version check rather than being read as garbage.
    let payload = samplePayload(layerCount: 1)
    let f = frame(payload: payload, version: 1)
    let ok = f.withUnsafeBufferPointer {
        smkKeymapFrameValidate($0.baseAddress!, frameLen: f.count)
    }
    #expect(ok == nil)
}

@Test func versionTwoFrameValidates() {
    let payload = samplePayload(layerCount: 1)
    let f = frame(payload: payload, version: 2)
    let len = f.withUnsafeBufferPointer {
        smkKeymapFrameValidate($0.baseAddress!, frameLen: f.count)
    }
    #expect(len == payload.count)
}

@Test func versionTwoFrameWithBadCrcIsRejected() {
    var f = frame(payload: samplePayload(layerCount: 1), version: 2)
    f[11] ^= 0xFF                        // corrupt the first payload byte
    let ok = f.withUnsafeBufferPointer {
        smkKeymapFrameValidate($0.baseAddress!, frameLen: f.count)
    }
    #expect(ok == nil)
}

@Test func engineLoadsActionsFromBinary() {
    var engine = LayerEngine()
    let payload = samplePayload(layerCount: 1)
    payload.withUnsafeBufferPointer {
        engine.loadKeymap(binary: $0.baseAddress!, count: payload.count)
    }
    #expect(engine.getAction(row: 0, col: 0) == .key(.a))
    // Not .transparent, as the brief's sketch guessed: getAction's existing,
    // already-tested contract (see layerEngineTransparentFallsThroughToLowerActiveLayer
    // in LayerEngineTests.swift) resolves .transparent by falling through to
    // a lower active layer. Layer 0 -- the only layer this payload decodes --
    // has nothing below it to fall through to, so the cell resolves to
    // .none, exactly as a JSON-loaded single-layer keymap with "trans" at
    // this cell already would. This is the decoder's cell decoding straight
    // through unchanged; getAction never returns .transparent for a caller
    // to observe, on either load path.
    #expect(engine.getAction(row: 0, col: 1) == .none)
}

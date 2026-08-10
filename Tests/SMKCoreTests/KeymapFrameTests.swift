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

@Test func frameValidateRejectsCrcMismatch() {
    var frame = [UInt8](repeating: 0, count: 11 + 4)
    frame[0] = 0x53; frame[1] = 0x4D; frame[2] = 0x4B; frame[3] = 0x4D; frame[4] = 1
    frame[5] = 4; frame[6] = 0 // jsonLen = 4
    // bytes 7-10 (stored CRC) left at 0 — won't match the real CRC of frame[11..<15]
    frame[11] = 0x7B; frame[12] = 0x7D // arbitrary payload bytes
    let result = frame.withUnsafeBufferPointer { smkKeymapFrameValidate($0.baseAddress!, frameLen: $0.count) }
    #expect(result == nil)
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

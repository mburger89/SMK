// Shared keymap-store frame format: CRC32 + 11-byte header pack/unpack.
// Extracted from what were three independent, byte-identical copies of
// this logic (Sources/components/smk_keymap_store.c [ESP32-C6],
// ports/rp2040/platform/smk_keymap_store.c, and the nRF52840 stub which
// never needed it). Pure logic, zero hardware calls — host-testable.
// See docs/superpowers/specs/2026-07-31-runtime-keymap-updates-design.md
// for the frame layout/protocol this implements.

public let smkKeymapMaxLen: Int = 4085
public let smkKeymapFrameLen: Int = 11 + smkKeymapMaxLen

private let magic0: UInt8 = 0x53 // 'S'
private let magic1: UInt8 = 0x4D // 'M'
private let magic2: UInt8 = 0x4B // 'K'
private let magic3: UInt8 = 0x4D // 'M'
private let frameVersion: UInt8 = 1

public func smkCrc32(_ data: UnsafePointer<UInt8>, _ len: Int) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for i in 0..<len {
        crc ^= UInt32(data[i])
        for _ in 0..<8 {
            let mask: UInt32 = (crc & 1) == 1 ? 0xFFFF_FFFF : 0
            crc = (crc >> 1) ^ (0xEDB8_8320 & mask)
        }
    }
    return crc ^ 0xFFFF_FFFF
}

// Validates magic/version/length/CRC and returns the JSON payload length,
// or nil if the frame is malformed/corrupt. `frame` must point to at
// least `frameLen` readable bytes.
public func smkKeymapFrameValidate(_ frame: UnsafePointer<UInt8>, frameLen: Int) -> Int? {
    guard frameLen >= 11 else { return nil }
    guard frame[0] == magic0, frame[1] == magic1, frame[2] == magic2, frame[3] == magic3, frame[4] == frameVersion else {
        return nil
    }
    let jsonLen = Int(frame[5]) | (Int(frame[6]) << 8)
    let storedCrc = UInt32(frame[7]) | (UInt32(frame[8]) << 8) | (UInt32(frame[9]) << 16) | (UInt32(frame[10]) << 24)
    guard jsonLen <= smkKeymapMaxLen, 11 + jsonLen <= frameLen else { return nil }
    guard smkCrc32(frame + 11, jsonLen) == storedCrc else { return nil }
    return jsonLen
}

// Writes the 11-byte header (magic/version/length/crc) into `frame[0..<11]`.
// Caller must have already placed the JSON payload at frame[11...] and
// computed crc32 over exactly those jsonLen bytes.
public func smkKeymapFrameWriteHeader(_ frame: UnsafeMutablePointer<UInt8>, jsonLen: Int, crc32: UInt32) {
    frame[0] = magic0
    frame[1] = magic1
    frame[2] = magic2
    frame[3] = magic3
    frame[4] = frameVersion
    frame[5] = UInt8(jsonLen & 0xFF)
    frame[6] = UInt8((jsonLen >> 8) & 0xFF)
    frame[7] = UInt8(crc32 & 0xFF)
    frame[8] = UInt8((crc32 >> 8) & 0xFF)
    frame[9] = UInt8((crc32 >> 16) & 0xFF)
    frame[10] = UInt8((crc32 >> 24) & 0xFF)
}

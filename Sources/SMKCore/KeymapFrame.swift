// Shared keymap-store frame format: CRC32 + 11-byte header pack/unpack.
// Extracted from what were three independent, byte-identical copies of
// this logic (Sources/components/smk_keymap_store.c [ESP32-C6],
// ports/rp2040/platform/smk_keymap_store.c, and the nRF52840 stub which
// never needed it). Pure logic, zero hardware calls — host-testable.
// See docs/superpowers/specs/2026-07-31-runtime-keymap-updates-design.md
// for the frame layout/protocol this implements, and
// docs/superpowers/specs/2026-08-21-binary-keymap-format-design.md for the
// version-2 payload format below.
//
// frameVersion 2 is the binary keymap payload (see KeymapBinary.swift);
// version 1 was the JSON payload it replaces. The frame's own layout --
// magic/version/length/CRC at the same 11-byte header, same offset -- is
// unchanged, which is the point: a version 1 frame written by old firmware
// fails this validator's plain version-byte check instead of being
// misread as a binary payload at a moved offset. That rejection is not
// incidental; it is the entire migration story (see the design doc's
// "Version handling" section). A rejected frame falls back to the
// compiled-in default the same way a corrupt frame already does.

public let smkKeymapMaxLen: Int = 4085
public let smkKeymapFrameLen: Int = 11 + smkKeymapMaxLen

private let magic0: UInt8 = 0x53 // 'S'
private let magic1: UInt8 = 0x4D // 'M'
private let magic2: UInt8 = 0x4B // 'K'
private let magic3: UInt8 = 0x4D // 'M'
private let frameVersion: UInt8 = 2

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

// Validates magic/version/length/CRC and returns the payload length, or nil
// if the frame is malformed/corrupt (including a stale version-1 JSON
// frame, which fails the version check on `frame[4]` and is deliberately
// indistinguishable here from any other corruption -- both fall back to
// the compiled default). `frame` must point to at least `frameLen`
// readable bytes.
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
// Caller must have already placed the payload (binary as of version 2) at
// frame[11...] and computed crc32 over exactly those jsonLen bytes. The
// parameter is still named `jsonLen` -- it is just a byte count, and
// renaming it is out of scope for this change.
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

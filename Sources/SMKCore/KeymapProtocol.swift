// Shared BEGIN/CHUNK/COMMIT/ERASE packet dispatch for the runtime keymap
// upload protocol — ported from the former Sources/components/
// smk_keymap_protocol.c. Transport-agnostic: each port's transport layer
// (ble_helper.c's BLE Report ID 2 path, usb_descriptors.c's raw-HID path)
// calls this with whatever bytes it received and sends back whatever
// bytes this writes into `response`.

let smkKeymapPacketLen = 32

let smkKeymapOpBegin: UInt8 = 0x01
let smkKeymapOpChunk: UInt8 = 0x02
let smkKeymapOpCommit: UInt8 = 0x03
let smkKeymapOpErase: UInt8 = 0x04

let smkKeymapStatusOk: UInt8 = 0x00
let smkKeymapStatusErr: UInt8 = 0x01

// Real storage backends are all same-module Swift now: ESP32-C6
// (Sources/smk/KeymapStoreNVS.swift, Task 5), RP2040
// (ports/rp2040/KeymapStoreFlash.swift, Task 6), and nRF52840
// (ports/nrf52840/KeymapStoreStub.swift, Task 7) each flat-compile their
// definitions of smk_keymap_begin_write/write_chunk/commit/erase/load
// alongside this file into one swiftc invocation per target, so no
// `@_extern(c, ...)` declaration is needed here for any of them — declaring
// one here as well as a real Swift definition in one of those files would
// be a same-module redeclaration conflict.
//
// smk_keymap_erase is declared/defined separately in each of those same
// per-target files (used there for the factory-reset-on-boot path in
// Sources/smk/Main.swift); this file just reuses that same-module
// definition.

// Testable core of the dispatch logic. The four storage operations are
// injected rather than called directly so host tests can substitute fakes
// instead of linking against the real (still-C-backed) NVS/flash storage
// functions declared above. This also makes the opcode/length-validation
// branching itself observable in isolation — e.g. a CHUNK packet with
// chunk_len > smkKeymapPacketLen - 4 short-circuits to result = -1
// without ever invoking `writeChunk`.
func smkKeymapDispatchPacket(
    _ packet: UnsafePointer<UInt8>,
    _ response: UnsafeMutablePointer<UInt8>,
    beginWrite: (UInt16) -> Int32,
    writeChunk: (UInt16, UnsafePointer<UInt8>, UInt16) -> Int32,
    commit: (UInt32) -> Int32,
    erase: () -> Void
) {
    for i in 0..<smkKeymapPacketLen { response[i] = 0 }
    let opcode = packet[0]
    var result: Int32 = -1

    switch opcode {
    case smkKeymapOpBegin:
        let totalLen = UInt16(packet[1]) | (UInt16(packet[2]) << 8)
        result = beginWrite(totalLen)
    case smkKeymapOpChunk:
        let offset = UInt16(packet[1]) | (UInt16(packet[2]) << 8)
        let chunkLen = packet[3]
        if Int(chunkLen) > smkKeymapPacketLen - 4 {
            result = -1
        } else {
            result = writeChunk(offset, packet + 4, UInt16(chunkLen))
        }
    case smkKeymapOpCommit:
        let crc32 = UInt32(packet[1]) | (UInt32(packet[2]) << 8) | (UInt32(packet[3]) << 16) | (UInt32(packet[4]) << 24)
        result = commit(crc32)
    case smkKeymapOpErase:
        erase()
        result = 0
    default:
        result = -1
    }

    response[0] = (result == 0) ? smkKeymapStatusOk : smkKeymapStatusErr
    response[1] = opcode
}

#if SMK_TARGET_ESP32C6 || SMK_TARGET_RP2040 || SMK_TARGET_NRF52840

// Real cross-language entry point. ports/rp2040/platform/usb_descriptors.c
// and ports/nrf52840/platform/usb_descriptors.c call this directly from C
// via smk_keymap_usb_service(); ble_helper.c's BLE Report ID 2 path calls
// it too. The `@_cdecl` boundary is real even though the dispatch logic
// above now lives in Swift.
@_cdecl("smk_keymap_dispatch_packet")
func smk_keymap_dispatch_packet(_ packet: UnsafePointer<UInt8>, _ response: UnsafeMutablePointer<UInt8>) {
    smkKeymapDispatchPacket(
        packet, response,
        beginWrite: smk_keymap_begin_write,
        writeChunk: smk_keymap_write_chunk,
        commit: smk_keymap_commit,
        erase: smk_keymap_erase
    )
}

#endif

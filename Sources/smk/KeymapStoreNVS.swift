// Runtime keymap store (ESP32-C6, NVS-backed) — Swift port of the former
// Sources/components/smk_keymap_store.c. Persists the framed
// {"layers":[...]} JSON blob uploaded over BLE so LayerEngine.loadKeymap
// has something to load besides the compiled default. CRC32/frame-format
// logic lives in Sources/SMKCore/KeymapFrame.swift, shared with RP2040's
// equivalent — only the NVS I/O itself is ESP32-C6-specific.
//
// NVS is already initialized by init_ble_hid() (Sources/components/
// ble_helper.c) before Main.swift reaches the keymap-load call site, so no
// separate init is needed here.
//
// These are plain module-internal Swift functions, not `@c` — nothing
// outside the Swift module calls smk_keymap_load/erase/begin_write/
// write_chunk/commit directly. Sources/smk/Main.swift and
// Sources/SMKCore/KeymapProtocol.swift (both flat-compiled into this same
// module) call them same-module. No C prototypes for these five in
// Sources/smk/Bridging.h either, for the same reason (see the comment
// there).

// nvs_open/nvs_get_blob/nvs_set_blob/nvs_erase_key/nvs_commit/nvs_close
// and the nvs_open_mode_t constants NVS_READONLY/NVS_READWRITE come straight
// from nvs.h, which Sources/smk/Bridging.h imports via nvs_flash.h — no
// hand-written @_extern(c, ...) declarations or mirrored enum values needed.
private let espOk: Int32 = 0 // ESP_OK

private var stage = [UInt8](repeating: 0, count: smkKeymapFrameLen)
private var stageTotalLen: UInt16 = 0

func smk_keymap_load(_ buf: UnsafeMutablePointer<UInt8>, _ bufSize: UInt32) -> Int32 {
    var handle: UInt32 = 0
    guard nvs_open("smk_kmap", NVS_READONLY, &handle) == espOk else { return -1 }
    defer { nvs_close(handle) }

    var frame = [UInt8](repeating: 0, count: smkKeymapFrameLen)
    var frameLen = smkKeymapFrameLen
    guard frame.withUnsafeMutableBufferPointer({ nvs_get_blob(handle, "frame", $0.baseAddress, &frameLen) }) == espOk else {
        return -1
    }

    guard let jsonLen = frame.withUnsafeBufferPointer({ smkKeymapFrameValidate($0.baseAddress!, frameLen: frameLen) }) else {
        return -1
    }
    guard jsonLen + 1 <= Int(bufSize) else { return -1 }

    for i in 0..<jsonLen { buf[i] = frame[11 + i] }
    return Int32(jsonLen)
}

func smk_keymap_erase() {
    var handle: UInt32 = 0
    guard nvs_open("smk_kmap", NVS_READWRITE, &handle) == espOk else { return }
    _ = nvs_erase_key(handle, "frame")
    _ = nvs_commit(handle)
    nvs_close(handle)
}

func smk_keymap_begin_write(_ totalLen: UInt16) -> Int32 {
    guard Int(totalLen) <= smkKeymapMaxLen else { return -1 }
    stageTotalLen = totalLen
    for i in 0..<stage.count { stage[i] = 0 }
    return 0
}

func smk_keymap_write_chunk(_ offset: UInt16, _ data: UnsafePointer<UInt8>, _ len: UInt16) -> Int32 {
    guard Int(offset) + Int(len) <= Int(stageTotalLen) else { return -1 }
    for i in 0..<Int(len) { stage[11 + Int(offset) + i] = data[i] }
    return 0
}

func smk_keymap_commit(_ crc32: UInt32) -> Int32 {
    let computed = stage.withUnsafeBufferPointer { smkCrc32($0.baseAddress! + 11, Int(stageTotalLen)) }
    guard computed == crc32 else { return -1 }

    stage.withUnsafeMutableBufferPointer { smkKeymapFrameWriteHeader($0.baseAddress!, jsonLen: Int(stageTotalLen), crc32: crc32) }

    var handle: UInt32 = 0
    guard nvs_open("smk_kmap", NVS_READWRITE, &handle) == espOk else { return -1 }
    defer { nvs_close(handle) }
    let writeLen = 11 + Int(stageTotalLen)
    guard stage.withUnsafeBufferPointer({ nvs_set_blob(handle, "frame", $0.baseAddress!, writeLen) }) == espOk else { return -1 }
    return (nvs_commit(handle) == espOk) ? 0 : -1
}

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
// These are plain module-internal Swift functions, not `@_cdecl` — nothing
// outside the Swift module calls smk_keymap_load/erase/begin_write/
// write_chunk/commit directly. Sources/smk/Main.swift and
// Sources/SMKCore/KeymapProtocol.swift (both flat-compiled into this same
// module) call them same-module. No C prototypes for these five in
// Sources/smk/Bridging.h either, for the same reason (see the comment
// there).

@_extern(c, "nvs_open")
func nvs_open(_ namespace: UnsafePointer<CChar>, _ openMode: Int32, _ outHandle: UnsafeMutablePointer<UInt32>) -> Int32

@_extern(c, "nvs_get_blob")
func nvs_get_blob(_ handle: UInt32, _ key: UnsafePointer<CChar>, _ outValue: UnsafeMutableRawPointer?, _ length: UnsafeMutablePointer<Int>) -> Int32

@_extern(c, "nvs_set_blob")
func nvs_set_blob(_ handle: UInt32, _ key: UnsafePointer<CChar>, _ value: UnsafeRawPointer, _ length: Int) -> Int32

@_extern(c, "nvs_erase_key")
func nvs_erase_key(_ handle: UInt32, _ key: UnsafePointer<CChar>) -> Int32

@_extern(c, "nvs_commit")
func nvs_commit(_ handle: UInt32) -> Int32

@_extern(c, "nvs_close")
func nvs_close(_ handle: UInt32)

// NVS_READONLY / NVS_READWRITE — verified against
// ~/.espressif/v6.0.1/esp-idf/components/nvs_flash/include/nvs.h's
// nvs_open_mode_t enum: { NVS_READONLY, NVS_READWRITE, NVS_READWRITE_PURGE },
// i.e. 0 / 1 / 2 — a plain C enum (int-sized), passed here as Int32.
private let nvsReadonly: Int32 = 0 // NVS_READONLY
private let nvsReadwrite: Int32 = 1 // NVS_READWRITE
private let espOk: Int32 = 0 // ESP_OK

private var stage = [UInt8](repeating: 0, count: smkKeymapFrameLen)
private var stageTotalLen: UInt16 = 0

func smk_keymap_load(_ buf: UnsafeMutablePointer<CChar>, _ bufSize: UInt32) -> Int32 {
    var handle: UInt32 = 0
    guard nvs_open("smk_kmap", nvsReadonly, &handle) == espOk else { return -1 }
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

    buf.withMemoryRebound(to: UInt8.self, capacity: jsonLen) { dst in
        for i in 0..<jsonLen { dst[i] = frame[11 + i] }
    }
    return Int32(jsonLen)
}

func smk_keymap_erase() {
    var handle: UInt32 = 0
    guard nvs_open("smk_kmap", nvsReadwrite, &handle) == espOk else { return }
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
    guard nvs_open("smk_kmap", nvsReadwrite, &handle) == espOk else { return -1 }
    defer { nvs_close(handle) }
    let writeLen = 11 + Int(stageTotalLen)
    guard stage.withUnsafeBufferPointer({ nvs_set_blob(handle, "frame", $0.baseAddress!, writeLen) }) == espOk else { return -1 }
    return (nvs_commit(handle) == espOk) ? 0 : -1
}

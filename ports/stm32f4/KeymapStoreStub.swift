// Runtime keymap store (STM32F4) — BUILD-ONLY STUB. No flash layout
// designed yet for this board (bring-up target only, not a real keyboard —
// see the design spec's Board section). Every operation is a no-op /
// "nothing stored" placeholder, NOT a real implementation. Mirrors
// ports/nrf52840/KeymapStoreStub.swift exactly.

func smk_keymap_load(_ buf: UnsafeMutablePointer<CChar>, _ bufSize: UInt32) -> Int32 {
    -1 // no stored keymap
}

func smk_keymap_erase() {
    // no-op: nothing is ever stored yet
}

func smk_keymap_begin_write(_ totalLen: UInt16) -> Int32 {
    -1
}

func smk_keymap_write_chunk(_ offset: UInt16, _ data: UnsafePointer<UInt8>, _ len: UInt16) -> Int32 {
    -1
}

func smk_keymap_commit(_ crc32: UInt32) -> Int32 {
    -1
}

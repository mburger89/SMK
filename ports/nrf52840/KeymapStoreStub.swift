// Runtime keymap store (nRF52840) — BUILD-ONLY STUB, ported to Swift.
// See the deleted ports/nrf52840/platform/smk_keymap_store.c's git history
// for the full reasoning this comment condenses: this board has no
// hardware yet, so there's no flash layout to target. Every operation is
// a no-op / "nothing stored" placeholder, NOT a real implementation.
// NVMC is off-limits once the SoftDevice Controller (Task 6/7 of
// docs/superpowers/plans/2026-08-09-nrf52840-support.md) is running —
// whoever implements a real store needs to check what flash-write
// mechanism the SDC version in use at that time exposes (this vendored
// nrfxlib snapshot's sdc_soc.h has none) rather than assuming raw NVMC
// access or a specific historical SDC function name still works.
//
// USB HID is wired up, so smk_keymap_begin_write/write_chunk/commit ARE
// reachable from a real host via Sources/SMKCore/KeymapProtocol.swift's
// dispatch — they're not dead code. They just unconditionally fail
// (return -1), same as smk_keymap_load: any keymap upload attempted
// against this board today will be accepted over USB but silently fail
// to persist.

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

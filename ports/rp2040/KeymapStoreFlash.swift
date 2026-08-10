// Runtime keymap store (RP2040, flash-backed) — Swift port of the former
// ports/rp2040/platform/smk_keymap_store.c. Reserves the last flash sector
// for the stored keymap. CRC32/frame-format logic lives in
// Sources/SMKCore/KeymapFrame.swift, shared with ESP32-C6's equivalent.
//
// flash_range_erase/flash_range_program are real extern (non-static)
// pico-sdk symbols — verified against
// ~/pico-sdk/src/rp2_common/hardware_flash/include/hardware/flash.h:
//   void flash_range_erase(uint32_t flash_offs, size_t count);
//   void flash_range_program(uint32_t flash_offs, const uint8_t *data, size_t count);
// (no `static`/`inline`), so they're callable directly via @_extern(c, ...).
// `size_t count` is declared here as Swift `Int`, matching this project's
// existing size_t-as-Int convention (see Sources/smk/KeymapStoreNVS.swift's
// nvs_set_blob `length: Int`).
//
// save_and_disable_interrupts()/restore_interrupts() (hardware/sync.h) are
// `__force_inline static` — no linkable symbol exists for those, so they're
// wrapped in platform/flash_irq_wrappers.c (smk_save_and_disable_interrupts/
// smk_restore_interrupts), matching the established pattern
// platform/gpio_init_wrappers.c already uses for hardware/gpio.h's static
// inline functions.
//
// PICO_FLASH_SIZE_BYTES is similarly a C-preprocessor macro Swift can't see
// at all, and is genuinely board-specific (verified against
// ~/pico-sdk/src/boards/include/boards/*.h: 2MB for pico.h/pico_w.h, 4MB
// for pico2.h/pico2_w.h; smk_kbd_rp2040 reuses PICO_BOARD=pico as its
// electrical descriptor per ports/rp2040/CMakeLists.txt, so it's 2MB too) —
// read at runtime via smk_pico_flash_size_bytes() (also in
// flash_irq_wrappers.c) rather than duplicating pico-sdk's per-board
// numbers here.

@_extern(c, "flash_range_erase")
func flash_range_erase(_ flashOffset: UInt32, _ count: Int)

@_extern(c, "flash_range_program")
func flash_range_program(_ flashOffset: UInt32, _ data: UnsafePointer<UInt8>, _ count: Int)

@_extern(c, "smk_save_and_disable_interrupts")
func smk_save_and_disable_interrupts() -> UInt32

@_extern(c, "smk_restore_interrupts")
func smk_restore_interrupts(_ savedIrq: UInt32)

@_extern(c, "smk_pico_flash_size_bytes")
func smk_pico_flash_size_bytes() -> UInt32

// XIP_BASE — verified against both
// ~/pico-sdk/src/rp2040/hardware_regs/include/hardware/regs/addressmap.h
// and .../rp2350/.../addressmap.h: both `#define XIP_BASE _u(0x10000000)`,
// identical on RP2040 and RP2350. Flash is memory-mapped for reads at
// XIP_BASE at all times, so the store can be read directly through a raw
// pointer — same as the deleted C file's `static const uint8_t *const`.
private let xipBase: UInt32 = 0x1000_0000

// FLASH_SECTOR_SIZE/FLASH_PAGE_SIZE — verified against
// ~/pico-sdk/src/rp2_common/hardware_flash/include/hardware/flash.h:
// `#define FLASH_PAGE_SIZE (1u << 8)` / `#define FLASH_SECTOR_SIZE (1u << 12)`
// (256/4096), same on both chips — unlike PICO_FLASH_SIZE_BYTES above,
// these don't vary per board.
private let flashSectorSize: Int = 4096
private let flashPageSize: Int = 256

// Computed per-call (not a stored global) since it depends on a runtime
// call into smk_pico_flash_size_bytes() — avoids relying on C-call-in-
// global-initializer ordering in Embedded Swift.
private func flashOffset() -> UInt32 {
    smk_pico_flash_size_bytes() - UInt32(flashSectorSize)
}

private var stage = [UInt8](repeating: 0, count: smkKeymapFrameLen)
private var stageTotalLen: UInt16 = 0

// UnsafePointer<UInt8>(bitPattern:) against a raw XIP address: this is the
// same pattern ports/rp2040/GPIORegisters.swift already uses (and has
// running on real hardware) for the SIO MMIO block at a hardcoded
// 0xD0000000 address — memory-mapped reads through a bitPattern-constructed
// pointer are already proven to work on this target, not something new
// introduced here.
private func flashFramePointer() -> UnsafePointer<UInt8> {
    UnsafePointer<UInt8>(bitPattern: UInt(xipBase) + UInt(flashOffset()))!
}

func smk_keymap_load(_ buf: UnsafeMutablePointer<CChar>, _ bufSize: UInt32) -> Int32 {
    let frame = flashFramePointer()
    guard let jsonLen = smkKeymapFrameValidate(frame, frameLen: smkKeymapFrameLen) else { return -1 }
    guard jsonLen + 1 <= Int(bufSize) else { return -1 }
    buf.withMemoryRebound(to: UInt8.self, capacity: jsonLen) { dst in
        for i in 0..<jsonLen { dst[i] = frame[11 + i] }
    }
    return Int32(jsonLen)
}

func smk_keymap_erase() {
    let offset = flashOffset()
    let ints = smk_save_and_disable_interrupts()
    flash_range_erase(offset, flashSectorSize)
    smk_restore_interrupts(ints)
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

    // flash_range_program requires a length that's a multiple of
    // FLASH_PAGE_SIZE; stage is already zero-padded past the real data.
    let programLen = ((11 + Int(stageTotalLen) + flashPageSize - 1) / flashPageSize) * flashPageSize

    let offset = flashOffset()
    let ints = smk_save_and_disable_interrupts()
    flash_range_erase(offset, flashSectorSize)
    stage.withUnsafeBufferPointer { flash_range_program(offset, $0.baseAddress!, programLen) }
    smk_restore_interrupts(ints)
    return 0
}

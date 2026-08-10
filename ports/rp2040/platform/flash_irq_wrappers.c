// Wrapper functions for pico-sdk hardware_sync static-inline functions,
// plus a runtime accessor for the board-specific PICO_FLASH_SIZE_BYTES
// macro — both needed by ports/rp2040/KeymapStoreFlash.swift via
// @_extern(c, ...).
//
// save_and_disable_interrupts()/restore_interrupts() (hardware/sync.h) are
// __force_inline static, meaning they're not exported symbols when the
// header is only #include'd from a non-inlining Swift translation unit —
// same situation gpio_init_wrappers.c documents for hardware/gpio.h. These
// wrappers provide real, non-inline entry points for the same
// functionality.
//
// PICO_FLASH_SIZE_BYTES is a compile-time macro, not a function, so Swift
// can't see it via @_extern at all. It's genuinely board-specific (verified
// against ~/pico-sdk/src/boards/include/boards/*.h: 2MB for pico/pico_w —
// and smk_kbd_rp2040, which reuses PICO_BOARD=pico as its electrical
// descriptor per ports/rp2040/CMakeLists.txt's own comment — vs. 4MB for
// pico2/pico2_w). Reading it here at compile time, from whichever real
// board header this translation unit is actually built against, means the
// Swift side never has to duplicate pico-sdk's per-board flash-size table.

#include "pico/stdlib.h"
#include "hardware/sync.h"
#include "hardware/flash.h"

uint32_t smk_save_and_disable_interrupts(void) {
    return save_and_disable_interrupts();
}

void smk_restore_interrupts(uint32_t status) {
    restore_interrupts(status);
}

uint32_t smk_pico_flash_size_bytes(void) {
    return PICO_FLASH_SIZE_BYTES;
}

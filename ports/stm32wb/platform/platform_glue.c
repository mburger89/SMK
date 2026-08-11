// Misc platform glue for the STM32WB build: logging, the cooperative delay
// shim, the C entry point, board/connection-mode config, BLE HID stubs
// (real implementation lands in Task 7), the newlib syscall stub bodies,
// and the Embedded-Swift linker stubs.
//
// This is a build-only pass — no hardware bring-up beyond Tasks 1-3 has
// happened yet. kb_log and vTaskDelay below are placeholders, same status
// as ports/stm32f4/platform/platform_glue.c's:
//   - kb_log: no-op. Real firmware should route this to a UART once one is
//     selected during hardware bring-up.
//   - vTaskDelay: busy-loop only (still pumps kb_usb_task() each tick, same
//     as F4). Real timing should come from a hardware timer once one is set
//     up — not done in this pass.
//
// posix_memalign/_init are needed even for the Task 1 smoke test, not just
// the full app — see this file's own Task 1 version for the full story
// (same real finding as STM32F4's Task 1). Carried forward unchanged here.

#include <errno.h>
#include <malloc.h>
#include <stddef.h>
#include <stdint.h>

extern void smk_clock_init(void); // RCC/HSE/HSI48/CRS bring-up (Task 2, ports/stm32wb/ClockInit.swift)
extern void app_main_swift(void); // shared entry point (Sources/smk/Main.swift)
extern void kb_usb_task(void);    // pumps TinyUSB (Task 5, ports/stm32wb/UsbHid.swift)

// --- Logging -----------------------------------------------------------
void kb_log(const char *msg) {
    (void)msg;
}

// --- Cooperative delay shim ----------------------------------------------
// The shared scan loop calls vTaskDelay(1) once per tick. Placeholder
// busy-loop only (no calibrated timer yet) — real timing should use a
// hardware timer once hardware bring-up starts.
void vTaskDelay(uint32_t ticks) {
    kb_usb_task();
    if (ticks == 0) ticks = 1;
    for (volatile uint32_t i = 0; i < ticks * 100000u; i++) {
        __asm__ volatile("nop");
    }
}

// --- Connection-mode config ------------------------------------------------
// This board has real native-USB wired HID (Task 5) and, until Task 7 lands
// real BLE HID, defaults to wired — same reasoning as
// ports/stm32f4/platform/platform_glue.c.
int smk_has_wired_bridge(void) { return 1; }
int smk_default_mode_is_wired(void) { return 1; }

// --- BLE HID stub (real implementation lands in Task 7, platform/ble_hid_wb.c) ---
// Sources/smk/Main.swift calls these unconditionally regardless of board.
// Guarded so Task 7 can supersede this pair by defining
// SMK_HAS_REAL_BLE_HID_WB, matching ports/nrf52840/platform/platform_glue.c's
// own SMK_HAS_REAL_BLE_HID_SDC pattern for the identical
// "task N stubs it, task N+1 provides the real definition" problem.
#ifndef SMK_HAS_REAL_BLE_HID_WB
void init_ble_hid(void) {
    // Stub — Task 7 (ble_hid_wb.c) provides the real implementation.
}

void send_keyboard_report(uint8_t modifier, uint8_t *keycodes) {
    (void)modifier;
    (void)keycodes;
}
#endif

// --- Entry point -----------------------------------------------------------
int main(void) {
    smk_clock_init(); // RCC/HSE/HSI48/CRS bring-up before anything else (Task 2)
    app_main_swift();  // never returns (infinite scan loop)
    return 0;
}

// --- posix_memalign (not in newlib; needed by Swift's swift_allocObject) ----
int posix_memalign(void **memptr, size_t alignment, size_t size) {
    if (alignment == 0 || (alignment & (alignment - 1)) != 0) return EINVAL;
    if (size == 0) { *memptr = NULL; return 0; }
    void *p = memalign(alignment, size);
    if (p == NULL) return ENOMEM;
    *memptr = p;
    return 0;
}

// --- _init (crti.o/crtn.o normally provide this; excluded by -nostartfiles) ---
void _init(void) {}

// --- Embedded-Swift linker stubs -------------------------------------------
// Swift's String / Unicode support references these symbols. The shared
// code only uses ASCII JSON, so stubs are sufficient (mirrors RP2040's,
// nRF52840's, and STM32F4's platform_glue.c).
void _swift_stdlib_getNormData(void) {}
void _swift_stdlib_getComposition(void) {}
void _swift_stdlib_getDecompositionEntry(void) {}
uint8_t *_swift_stdlib_nfd_decompositions = 0;
void _swift_stdlib_isExtendedPictographic(void) {}
void _swift_stdlib_isInCB_Consonant(void) {}
void _swift_stdlib_getGraphemeBreakProperty(void) {}

// Misc platform glue for the nRF52840 build: logging, the cooperative delay
// shim, the C entry point, board/connection-mode config, and the
// Embedded-Swift linker stubs.
//
// Counterpart to ports/rp2040/platform/platform_glue.c. Task 1's minimal
// smoke-test stub is replaced here with the real shape now that the full
// shared application layer (Sources/smk, Sources/SMKCore) is wired in.
//
// This is a build-only pass — no hardware exists for this board yet (see
// docs/superpowers/specs/2026-08-09-nrf52840-support-design.md). kb_log and
// vTaskDelay below are therefore placeholders, flagged for real
// implementations once Tasks 4-7 (USB/BLE) and hardware bring-up land:
//   - kb_log: no-op. Real firmware should route this to RTT (SEGGER
//     Real-Time Transfer, the usual no-UART-required logging channel for
//     nRF52 boards) or a UART, once one is selected.
//   - vTaskDelay: busy-loop only. Real timing should come from NRF_RTC (a
//     low-power hardware timer) once MPSL/SoftDevice Controller init
//     (Task 5) claims ownership of the relevant peripherals — this must be
//     coordinated with that init, not implemented independently here.

#include <errno.h>
#include <malloc.h>
#include <stddef.h>
#include <stdint.h>

extern void app_main_swift(void); // shared entry point (Sources/smk/Main.swift)

// --- Logging -----------------------------------------------------------
// Placeholder: no-op until a real logging channel (RTT or UART) is wired
// up during hardware bring-up. Not wired to anything yet since this is a
// build-only pass with no hardware to verify against.
void kb_log(const char *msg) {
    (void)msg;
}

// --- Cooperative delay shim ----------------------------------------------
// The shared scan loop calls vTaskDelay(1) once per tick. Placeholder
// busy-loop only (no RTOS, no calibrated timer yet) — real timing should
// use NRF_RTC once Task 5's MPSL init claims the relevant peripherals.
// Loop count is an uncalibrated guess, NOT a real millisecond delay.
void vTaskDelay(uint32_t ticks) {
    if (ticks == 0) ticks = 1;
    for (volatile uint32_t i = 0; i < ticks * 100000u; i++) {
        __asm__ volatile("nop");
    }
}

// --- Connection-mode config ------------------------------------------------
// This board always has real native-USB wired HID (Task 4, TinyUSB), so
// it's always available and stays the boot default, matching RP2040's
// pattern (see ports/rp2040/platform/platform_glue.c).
int smk_has_wired_bridge(void) { return 1; }
int smk_default_mode_is_wired(void) { return 1; }

// --- HID transport stubs ----------------------------------------------------
// Placeholders only: Sources/smk/Main.swift's scan loop calls these
// unconditionally (init_ble_hid()/init_wired_link() at startup,
// send_keyboard_report()/send_wired_report() per tick), so they must
// resolve at link time even though no real transport exists yet on this
// build-only pass. No dedicated usb_hid.c/ble_hid.c exists for this board
// yet (unlike RP2040's), so the no-op stubs live here temporarily.
// init_wired_link/send_wired_report: Task 4 (TinyUSB) implements these for
// real in Swift (ports/nrf52840/UsbHid.swift, no @_cdecl — reached via
// ordinary same-module Swift symbol resolution). These C stubs are NOT
// removed by Task 4; they become harmless dead code after it lands (Swift's
// version uses a different, mangled symbol name, so there's no link
// conflict) but could be deleted as cleanup.
//
// init_ble_hid/send_keyboard_report: Task 7 (SDC + BTstack GATT HID) adds
// ports/nrf52840/platform/ble_hid_sdc.c with real C-linkage definitions of
// the same names. Unlike the wired pair, THESE stubs must be disabled (see
// SMK_HAS_REAL_BLE_HID_SDC guard below) or the build will fail with a
// duplicate-symbol linker error once ble_hid_sdc.c is added.
void init_wired_link(void) {}
void send_wired_report(uint8_t modifier, uint8_t *keycodes) {
    (void)modifier;
    (void)keycodes;
}

#ifndef SMK_HAS_REAL_BLE_HID_SDC
void init_ble_hid(void) {
    // Stub — Task 7 (ble_hid_sdc.c) provides the real implementation.
    // Once ble_hid_sdc.c is added to the CMake source list, define
    // SMK_HAS_REAL_BLE_HID_SDC (e.g. via target_compile_definitions) to
    // disable this stub and avoid a duplicate-symbol link error.
}

void send_keyboard_report(uint8_t modifier, uint8_t *keycodes) {
    // Stub — see init_ble_hid above.
    (void)modifier;
    (void)keycodes;
}
#endif

// --- Entry point -----------------------------------------------------------
int main(void) {
    app_main_swift(); // never returns (infinite scan loop)
    return 0;
}

// --- posix_memalign (not in newlib; needed by Swift's swift_allocObject) ----
// Swift's Embedded runtime allocates heap objects with posix_memalign for
// alignment guarantees. Newlib doesn't provide it, so we bridge via memalign.
int posix_memalign(void **memptr, size_t alignment, size_t size) {
    if (alignment == 0 || (alignment & (alignment - 1)) != 0) return EINVAL;
    if (size == 0) { *memptr = NULL; return 0; }
    void *p = memalign(alignment, size);
    if (p == NULL) return ENOMEM;
    *memptr = p;
    return 0;
}

// --- Embedded-Swift linker stubs -------------------------------------------
// Swift's String / Unicode support references these symbols. The shared
// code only uses ASCII JSON, so stubs are sufficient (mirrors RP2040's
// platform_glue.c and ESP32's kb_main.c).
void _swift_stdlib_getNormData(void) {}
void _swift_stdlib_getComposition(void) {}
void _swift_stdlib_getDecompositionEntry(void) {}
uint8_t *_swift_stdlib_nfd_decompositions = 0;
void _swift_stdlib_isExtendedPictographic(void) {}
void _swift_stdlib_isInCB_Consonant(void) {}
void _swift_stdlib_getGraphemeBreakProperty(void) {}

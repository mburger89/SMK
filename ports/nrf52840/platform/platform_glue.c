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
// kb_usb_task (Task 4, ports/nrf52840/UsbHid.swift) pumps TinyUSB. Task 4's
// own UsbHid.swift header comment already claimed vTaskDelay calls this
// "via its own extern void kb_usb_task(void) declaration" — that turned out
// not to actually be true in this file (no declaration, no call site
// existed), so this pass adds both, fixing what would otherwise be a
// silent gap (USB HID reports never getting pumped) discovered while
// wiring in Task 5's mpsl_glue_poll() below it.
extern void kb_usb_task(void);
extern void mpsl_glue_init(void); // MPSL bring-up (Task 5, ports/nrf52840/MpslGlue.swift)
extern void mpsl_glue_poll(void); // pumps MPSL's low-priority work queue (Task 5)
extern void sdc_transport_poll(void); // drains SDC HCI events/data into BTstack (Task 7, platform/ble_hid_sdc.c)
extern void btstack_run_loop_embedded_execute_once(void); // pumps BTstack's timers/callbacks (Task 7 fix round, Critical #2)

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
//
// kb_usb_task() pumps TinyUSB (see extern declaration above for why it's
// added here, alongside mpsl_glue_poll()). mpsl_glue_poll() is called
// every tick (same cooperative-poll pattern) to pump MPSL's low-priority
// work queue promptly, per mpsl.rst's "call within a couple of ms of the
// low_prio_irq firing" contract — see MpslGlue.swift's SWI0_EGU0_IRQHandler
// comment for why this project polls unconditionally rather than gating on
// that ISR. sdc_transport_poll() (Task 7) drains SDC's HCI event/data queue
// into BTstack the same way — without this call, BTstack never sees
// incoming HCI events and init_ble_hid() hangs or silently does nothing
// past hci_power_control(). btstack_run_loop_embedded_execute_once() (Task
// 7 fix round, Critical #2) is BTstack's own run loop pump — separate from
// sdc_transport_poll() above, which only forwards raw HCI packets; this
// call is what actually processes those packets into state transitions,
// fires timers, and runs deferred callbacks (see ble_hid_sdc.c's
// init_ble_hid() for where this run loop gets installed via
// btstack_run_loop_init()).
void vTaskDelay(uint32_t ticks) {
    kb_usb_task();
    mpsl_glue_poll();
    sdc_transport_poll();
    btstack_run_loop_embedded_execute_once();
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

// --- BLE HID stub (disabled once the real implementation is linked in) -----
// init_ble_hid()/send_keyboard_report() are declared in
// ports/nrf52840/BridgingHeader.h and called unconditionally from
// Sources/smk/Main.swift's scan loop. The wired pair (init_wired_link/
// send_wired_report) is backed directly in Swift instead
// (ports/nrf52840/UsbHid.swift, same-module resolution — see
// BridgingHeader.h's comment for why no C declaration/stub exists for
// those here). ports/nrf52840/platform/ble_hid_sdc.c provides the real
// C-linkage definitions of init_ble_hid/send_keyboard_report (MPSL/SDC +
// BTstack GATT HID); these stubs must stay disabled (see
// SMK_HAS_REAL_BLE_HID_SDC guard below) whenever ble_hid_sdc.c is linked
// in, or the build fails with a duplicate-symbol linker error.
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
    mpsl_glue_init(); // bring up MPSL before the scan loop starts (Task 5)
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

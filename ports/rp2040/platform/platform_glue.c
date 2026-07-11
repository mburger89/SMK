// Misc platform glue for the RP2040 build: logging, the cooperative delay
// shim, the C entry point, and the Embedded-Swift linker stubs.
//
// Counterpart to the relevant bits of Sources/componets/kb_main.c (ESP32).

#include "pico/stdlib.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <malloc.h>
#include <errno.h>

extern void app_main_swift(void); // shared entry point (Sources/smk/Main.swift)
extern void kb_usb_task(void);     // usb_hid.c

// --- Logging ---------------------------------------------------------------
// Routed over the pico-sdk stdio (USB-CDC and/or UART, per CMake config).
void kb_log(const char *msg) {
    printf("[SMK] %s\n", msg);
}

// --- Cooperative delay shim ------------------------------------------------
// The shared scan loop calls vTaskDelay(1) once per tick. On RP2040 there is
// no RTOS by default, so we (a) keep USB serviced and (b) sleep ~ticks ms.
void vTaskDelay(uint32_t ticks) {
    kb_usb_task();
    if (ticks == 0) ticks = 1;
    sleep_ms(ticks);
}

// --- Connection-mode config --------------------------------------------------
// RP2040 always has real native-USB wired HID (usb_hid.c/TinyUSB), so it's
// always available and stays the boot default, unchanged from before this
// option existed. See ports/rp2040/BridgingHeader.h.
int smk_has_wired_bridge(void) { return 1; }
int smk_default_mode_is_wired(void) { return 1; }

// --- Entry point -----------------------------------------------------------
int main(void) {
    stdio_init_all();
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
// Swift's String / Unicode support references these symbols. The shared code
// only uses ASCII JSON, so stubs are sufficient (mirrors kb_main.c).
void _swift_stdlib_getNormData(void) {}
void _swift_stdlib_getComposition(void) {}
void _swift_stdlib_getDecompositionEntry(void) {}
uint8_t *_swift_stdlib_nfd_decompositions = 0;
void _swift_stdlib_isExtendedPictographic(void) {}
void _swift_stdlib_isInCB_Consonant(void) {}
void _swift_stdlib_getGraphemeBreakProperty(void) {}

// Misc platform glue for the RP2040 build: the C entry point and the
// Embedded-Swift linker stubs. Logging, the cooperative delay shim, and
// connection-mode config were ported to Swift — see
// ports/rp2040/PlatformConfig.swift.
//
// Counterpart to the relevant bits of Sources/components/kb_main.c (ESP32).

#include "pico/stdlib.h"
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <malloc.h>
#include <errno.h>

extern void app_main_swift(void); // shared entry point (Sources/smk/Main.swift)

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

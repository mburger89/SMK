// Embedded-Swift runtime glue shared by every ARM port (rp2040 family,
// nrf52840, stm32f4, stm32wb). These used to be duplicated blocks at the
// bottom of each port's platform/platform_glue.c; the per-port files keep
// only what genuinely differs per target (main(), the delay shim, config,
// and — for the -nostartfiles STM32 builds — _init).
//
// The ESP32-C6 build has its own copy of the stdlib stubs in
// Sources/components/kb_main.c (ESP-IDF component, different include/link
// world) and gets posix_memalign from ESP-IDF's libc, so it does not use
// this file.

#include <errno.h>
#include <malloc.h>
#include <stddef.h>
#include <stdint.h>

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
// only uses ASCII JSON, so stubs are sufficient (mirrors ESP32's kb_main.c).
void _swift_stdlib_getNormData(void) {}
void _swift_stdlib_getComposition(void) {}
void _swift_stdlib_getDecompositionEntry(void) {}
uint8_t *_swift_stdlib_nfd_decompositions = 0;
void _swift_stdlib_isExtendedPictographic(void) {}
void _swift_stdlib_isInCB_Consonant(void) {}
void _swift_stdlib_getGraphemeBreakProperty(void) {}

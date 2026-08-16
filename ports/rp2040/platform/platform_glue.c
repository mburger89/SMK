// Misc platform glue for the RP2040 build: the C entry point. Logging, the
// cooperative delay shim, and connection-mode config were ported to Swift —
// see ports/rp2040/PlatformConfig.swift; posix_memalign and the
// Embedded-Swift linker stubs live in the shared
// ports/common/embedded_swift_glue.c.
//
// Counterpart to the relevant bits of Sources/components/kb_main.c (ESP32).

#include "pico/stdlib.h"

extern void app_main_swift(void); // shared entry point (Sources/smk/Main.swift)

// --- Entry point -----------------------------------------------------------
int main(void) {
    stdio_init_all();
    app_main_swift(); // never returns (infinite scan loop)
    return 0;
}

// posix_memalign and the Embedded-Swift Unicode linker stubs moved to the
// shared ports/common/embedded_swift_glue.c (identical across all ARM ports).

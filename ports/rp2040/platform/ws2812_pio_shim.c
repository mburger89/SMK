// Narrow C remainder for the RP2040 LED strip driver (see
// LedStripDriverPIO.swift for why): ws2812_program is a build-generated
// global (pico_generate_pio_header compiles ports/rp2040/platform/
// ws2812.pio into a C header defining `const pio_program_t
// ws2812_program`) whose exact struct layout would be fragile to hand-
// replicate in Swift for zero real benefit — verified layout (see
// hardware/pio.h's `pio_program_t`) is actually
// `{ const uint16_t *instructions; uint8_t length; int8_t origin;
// uint8_t pio_version; uint8_t used_gpio_ranges (RP2350 only); }`, one
// field longer than a first glance at the .pio-generated header would
// suggest. This shim is the only place that touches it; everything else
// about this driver is Swift.
//
// pio_sm_put_blocking is also wrapped here: it's `static inline` in
// hardware/pio.h with no non-static instantiation anywhere in the SDK, so
// (like pio_can_add_program's siblings would be if called directly) it is
// NOT a linkable C symbol `@_extern(c, "pio_sm_put_blocking")` could bind
// to from Swift — same unlinkable-inline trap flagged in Tasks 8/9's
// reviews. Calling it from here, where it's included and inlined normally,
// sidesteps that; the Swift side calls this shim's own (real, exported)
// smk_ws2812_put_blocking instead.

#include "hardware/pio.h"
#include "ws2812.pio.h"

// Claims a PIO block (pio0, falling back to pio1 if pio0 has no room),
// loads the ws2812 program into it, claims a state machine, and starts
// it. Returns 0 on success. Out-params receive the chosen PIO instance
// pointer and state machine number for the caller (Swift) to drive
// directly via smk_ws2812_put_blocking below.
int smk_ws2812_pio_start(uint32_t gpio_num, PIO *out_pio, uint *out_sm) {
    PIO pio = pio0;
    if (!pio_can_add_program(pio, &ws2812_program)) {
        pio = pio1;
    }
    uint offset = pio_add_program(pio, &ws2812_program);
    uint sm = pio_claim_unused_sm(pio, true);
    ws2812_program_init(pio, sm, offset, gpio_num, 800000.0f, false);
    *out_pio = pio;
    *out_sm = sm;
    return 0;
}

// Thin wrapper around pio_sm_put_blocking (static inline in hardware/pio.h,
// not directly linkable from Swift — see file header comment above).
void smk_ws2812_put_blocking(PIO pio, uint sm, uint32_t data) {
    pio_sm_put_blocking(pio, sm, data);
}

// Non-inline wrappers for the Cortex-M core intrinsics
// ports/stm32wb/HwIpcc.swift and ports/stm32wb/ClockInit.swift need but
// Embedded Swift cannot express.
//
// Why this file exists: Swift has no inline assembly and no equivalent of
// CMSIS's `__disable_irq()` / `__get_PRIMASK()` / `__set_PRIMASK()` /
// `__SEV()` / `__WFE()`, all of which are `__STATIC_INLINE` functions built
// on `asm volatile` in cmsis_gcc.h — there is no real symbol for
// `@_extern(c, ...)` to bind to. This is the exact same problem (and the
// exact same solution) as ports/rp2040/platform/flash_irq_wrappers.c, which
// wraps pico-sdk's `static inline` interrupt-disable functions for
// KeymapStoreFlash.swift, and ports/rp2040/platform/gpio_init_wrappers.c.
//
// Everything else in the IPCC hardware layer — every register poke, the
// channel dispatch, the NVIC enables, both IRQ vectors — is Swift
// (ports/stm32wb/HwIpcc.swift), per this project's Swift-first preference.
// This file is deliberately as small as that preference allows.

#include <stdint.h>
#include "stm32wbxx.h"

// Critical section around read-modify-write of IPCC->C1MR, which is touched
// from both thread context (HW_IPCC_*_Init / *_SendCmd) and from the IPCC
// ISR (HW_IPCC_*_Handler). ST's own hw_ipcc.c wraps exactly the same writes
// in UTILS_ENTER_CRITICAL_SECTION()/UTILS_EXIT_CRITICAL_SECTION(), which
// expand to this PRIMASK save/disable/restore pair.
uint32_t smk_irq_disable_save(void) {
    uint32_t primask = __get_PRIMASK();
    __disable_irq();
    return primask;
}

void smk_irq_restore(uint32_t primask) {
    __set_PRIMASK(primask);
}

// Send-event / wait-for-event pair used by HW_IPCC_Enable() to wake CPU2:
// __SEV() sets this CPU's internal event flag *and* signals the other core;
// the immediately-following __WFE() consumes (clears) the local flag so it
// doesn't make a later WFE fall straight through. Copied in intent from
// ST's own hw_ipcc.c HW_IPCC_Enable().
void smk_cpu_sev(void) {
    __SEV();
}

void smk_cpu_wfe(void) {
    __WFE();
}

// Opaque no-op called from inside every hardware-polling busy-wait loop in
// ports/stm32wb/ClockInit.swift.
//
// Why it exists (a real bug this fixed, found by disassembling the built
// binary — not a theoretical concern): Swift's
// `UnsafeMutablePointer<UInt32>.pointee` is NOT a volatile access. A loop
// like `while (reg.pointee & bit) == 0 {}` therefore looks loop-invariant to
// LLVM, which deletes it outright under the forward-progress rule — leaving
// smk_clock_init() as straight-line register writes with zero actual
// waiting (SYSCLK switched before HSE is ready, flash latency applied before
// the regulator has reached the target voltage scale, ...).
//
// A call to an external C function the optimizer cannot see through defeats
// that: it may clobber arbitrary memory, so the register load must be
// re-issued on every iteration and the loop must be kept. Deliberately
// declared in the Swift side via @_extern(c, "smk_cpu_nop") — the whole
// point is that swiftc only sees the declaration, never the body.
void smk_cpu_nop(void) {
    __NOP();
}

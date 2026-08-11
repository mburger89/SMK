// Non-inline wrappers for the four Cortex-M core intrinsics
// ports/stm32wb/HwIpcc.swift needs but Embedded Swift cannot express.
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
